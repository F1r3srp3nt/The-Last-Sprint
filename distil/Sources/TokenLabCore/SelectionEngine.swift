import Foundation

public enum DecisionKind: String, Codable, Sendable {
    /// Required context: always kept verbatim.
    case required
    /// Optional context kept by the strategy.
    case retained
    /// Empty text contributes nothing to the prompt.
    case emptySkipped
    /// Optional context byte-identical to retained text (only when deduplication is active).
    case duplicateRemoved
    /// Optional context that did not fit the budget.
    case excludedByBudget

    public var kept: Bool { self == .required || self == .retained }
}

public struct BlockDecision: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var category: ContextCategory
    public var priority: Int
    public var required: Bool
    public var kind: DecisionKind
    /// Human-readable explanation of why the block was kept or removed.
    public var reason: String
    /// Tokens of this block's text on its own, with the report's counter.
    public var standaloneTokens: Int
    /// For removed duplicates: the block whose identical text was kept (nil if it matched the task or instructions).
    public var duplicateOf: UUID?
    /// Keyword relevance (task-relevance strategy only).
    public var relevance: RelevanceScore?
    /// 1-based position in which the strategy considered this optional block (budget strategies only).
    public var considerationRank: Int?

    public var kept: Bool { kind.kept }
}

/// A complete, reproducible record of one selection run.
public struct SelectionReport: Codable, Equatable, Sendable {
    public static let currentEngineVersion = "selection-engine-3"
    public static let separator = "\n\n"

    public var engineVersion: String
    public var input: Draft
    public var settings: SelectionSettings
    public var counter: TokenCounterDescriptor
    /// Instructions, all non-empty context and the task: the full-context prompt.
    public var originalPrompt: String
    /// Instructions, retained context in original order, and the task.
    public var selectedPrompt: String
    public var originalTokens: Int
    public var selectedTokens: Int
    /// Tokens for instructions, task and required context alone (assembled).
    public var protectedTokens: Int
    public var decisions: [BlockDecision]
    /// Tokens of the task and the instructions on their own (absent in reports from engine 2).
    public var taskTokens: Int?
    public var instructionsTokens: Int?
    /// Ranking details (task-relevance strategy only).
    public var ranker: RankerDescriptor?
    public var taskTerms: [String]?
    public var relevanceNote: String?

    public var budget: Int { settings.budget }
    public var budgetEnforced: Bool { settings.enforcesBudget }
    /// How far the selected prompt exceeds the budget (0 when within it).
    public var overBudgetBy: Int { max(0, selectedTokens - settings.budget) }
    public var overBudget: Bool { overBudgetBy > 0 }
    /// True when protected content alone is larger than the budget.
    public var protectedExceedsBudget: Bool { protectedTokens > settings.budget }

    /// Estimated reduction with this report's counter. Not provider usage and not a cost saving.
    public var estimatedReduction: Int { originalTokens - selectedTokens }
    public var estimatedReductionPercent: Double? {
        originalTokens == 0 ? nil : Double(estimatedReduction) / Double(originalTokens) * 100
    }

    public var keptCount: Int { decisions.filter(\.kept).count }
    public var removedCount: Int { decisions.filter { !$0.kept && $0.kind != .emptySkipped }.count }

    /// Whether this report was produced from exactly these inputs and counter. Used to hide stale previews.
    public func isCurrent(draft: Draft, settings: SelectionSettings, counter: TokenCounterDescriptor) -> Bool {
        engineVersion == Self.currentEngineVersion && input == draft && self.settings == settings && self.counter == counter
    }

    /// One-sentence honest summary of the budget situation.
    public var budgetSummary: String {
        let unit = counter.kind == .approximation ? "estimated tokens" : "\(counter.encoding) tokens"
        if budgetEnforced {
            if protectedExceedsBudget {
                return "Protected content alone (task, instructions and required blocks) is \(protectedTokens) \(unit), \(protectedTokens - budget) over the budget of \(budget). It was kept intact and not truncated; all optional context was excluded."
            }
            return "The whole assembled prompt is \(selectedTokens) of \(budget) \(unit)."
        }
        if overBudget {
            return "This strategy does not apply the budget. The assembled prompt is \(selectedTokens) \(unit), \(overBudgetBy) over the budget of \(budget)."
        }
        return "This strategy does not apply the budget. The assembled prompt is \(selectedTokens) \(unit), within the budget of \(budget)."
    }
}

/// Deterministic, explainable context selection. Pure: same inputs, counter and ranker always give the
/// same report. Ranking (`RelevanceRanker`) and counting (`TokenCounter`) are injected, not built in.
public enum SelectionEngine {
    public static let maxBlocks = 500
    public static let maxTextBytes = 2_000_000

    public static func validate(_ draft: Draft) throws {
        guard draft.blocks.count <= maxBlocks else {
            throw LabError.invalid("A workspace supports up to \(maxBlocks) context blocks.")
        }
        guard Set(draft.blocks.map(\.id)).count == draft.blocks.count else {
            throw LabError.invalid("Context block identifiers must be unique.")
        }
        if let bad = draft.blocks.first(where: { !ContextPriority.range.contains($0.priority) }) {
            throw LabError.invalid("Priority must be between 1 and 3 (block “\(bad.title)” has \(bad.priority)).")
        }
        let bytes = draft.task.utf8.count + draft.instructions.utf8.count + draft.blocks.reduce(0) { $0 + $1.text.utf8.count }
        guard bytes <= maxTextBytes else {
            throw LabError.invalid("Workspace text is limited to 2 MB in this prototype.")
        }
    }

    /// Assemble a prompt: protected instructions, then the kept blocks in their original order, then the task.
    /// Parts are joined with a blank line; no text is added, removed or reformatted.
    public static func assemble(_ draft: Draft, keeping kept: Set<UUID>? = nil) -> String {
        parts(draft, keeping: kept).joined(separator: SelectionReport.separator)
    }

    static func parts(_ draft: Draft, keeping kept: Set<UUID>?) -> [String] {
        ([draft.instructions] + draft.blocks.filter { kept?.contains($0.id) ?? true }.map(\.text) + [draft.task])
            .filter { !$0.isEmpty }
    }

    public static func run(_ draft: Draft, settings: SelectionSettings, counter: any TokenCounter,
                           ranker: any RelevanceRanker = KeywordOverlapRanker(),
                           isCancelled: () -> Bool = { false }) throws -> SelectionReport {
        try validate(draft)
        try settings.validate()

        let blocks = draft.blocks
        let title: (ContextBlock) -> String = { $0.title.isEmpty ? "Untitled context" : $0.title }
        var kinds: [UUID: DecisionKind] = [:]
        var reasons: [UUID: String] = [:]
        var duplicateOf: [UUID: UUID] = [:]
        var ranks: [UUID: Int] = [:]

        // 1. Empty and required blocks are decided the same way under every strategy.
        for block in blocks {
            if block.text.isEmpty {
                kinds[block.id] = .emptySkipped
                reasons[block.id] = "Skipped: the block is empty and adds no text."
            } else if block.required {
                kinds[block.id] = .required
                reasons[block.id] = settings.strategy == .taskRelevance
                    ? "Kept: marked required, preserved verbatim. Relevance is shown for information only."
                    : "Kept: marked required, preserved verbatim."
            }
        }
        let optional = blocks.enumerated().filter { kinds[$0.element.id] == nil }

        // 2. Optional exact deduplication (byte comparison; no Unicode normalisation).
        if settings.deduplicates {
            let taskBytes = Array(draft.task.utf8), instructionBytes = Array(draft.instructions.utf8)
            var requiredByText: [[UInt8]: ContextBlock] = [:]
            for block in blocks where block.required && !block.text.isEmpty {
                let key = Array(block.text.utf8)
                if requiredByText[key] == nil { requiredByText[key] = block }
            }
            // Keep the highest-priority optional copy; ties keep the earliest.
            let ordered = optional.sorted { a, b in
                a.element.priority != b.element.priority ? a.element.priority > b.element.priority : a.offset < b.offset
            }
            var keptCopy: [[UInt8]: ContextBlock] = [:]
            for (_, block) in ordered {
                let key = Array(block.text.utf8)
                if !draft.task.isEmpty && key == taskBytes {
                    kinds[block.id] = .duplicateRemoved
                    reasons[block.id] = "Removed: exact duplicate of the task."
                } else if !draft.instructions.isEmpty && key == instructionBytes {
                    kinds[block.id] = .duplicateRemoved
                    reasons[block.id] = "Removed: exact duplicate of the protected instructions."
                } else if let original = requiredByText[key] {
                    kinds[block.id] = .duplicateRemoved; duplicateOf[block.id] = original.id
                    reasons[block.id] = "Removed: exact duplicate of required block “\(title(original))”."
                } else if let original = keptCopy[key] {
                    kinds[block.id] = .duplicateRemoved; duplicateOf[block.id] = original.id
                    let why = original.priority > block.priority ? "higher priority" : "same priority, earlier in the prompt"
                    reasons[block.id] = "Removed: exact duplicate of “\(title(original))”, which was kept (\(why))."
                } else {
                    keptCopy[key] = block
                }
            }
        }

        // 3. Relevance scores (task-relevance strategy only). Ranking never edits or selects text itself.
        var relevance: [UUID: RelevanceScore] = [:]
        var taskTerms: [String]? = nil
        var relevanceNote: String? = nil
        if settings.strategy == .taskRelevance {
            relevance = ranker.scores(task: draft.task, blocks: blocks)
            let terms = ranker.taskTerms(draft.task)
            taskTerms = terms
            if terms.isEmpty {
                relevanceNote = "The task has no usable terms, so every block scores 0. Optional blocks were considered in manual-priority order, then prompt order."
            } else if optional.allSatisfy({ (relevance[$0.element.id]?.score ?? 0) == 0 }) {
                relevanceNote = "No optional block contains any task term. Optional blocks were considered in manual-priority order, then prompt order."
            }
        }

        // 4. Strategy-specific selection of the remaining optional blocks.
        let remaining = optional.filter { kinds[$0.element.id] == nil }
        switch settings.strategy {
        case .baseline:
            for (_, block) in remaining {
                kinds[block.id] = .retained; reasons[block.id] = "Kept: the full-context strategy retains all context."
            }
        case .exactDeduplication:
            for (_, block) in remaining {
                kinds[block.id] = .retained; reasons[block.id] = "Kept: no exact duplicate of this text is retained elsewhere."
            }
        case .budgetSelection, .taskRelevance:
            let byRelevance = settings.strategy == .taskRelevance
            let score: (ContextBlock) -> Double = { relevance[$0.id]?.score ?? 0 }
            let candidates = remaining.sorted { a, b in
                if byRelevance && score(a.element) != score(b.element) { return score(a.element) > score(b.element) }
                if a.element.priority != b.element.priority { return a.element.priority > b.element.priority }
                return a.offset < b.offset
            }
            var kept = Set(blocks.filter { kinds[$0.id] == .required }.map(\.id))
            let protectedTokens = counter.countJoined(parts(draft, keeping: kept), separator: SelectionReport.separator)
            for (position, (_, block)) in candidates.enumerated() {
                if isCancelled() { throw CancellationError() }
                ranks[block.id] = position + 1
                let because = byRelevance
                    ? relevanceExplanation(block, score: relevance[block.id], rank: position + 1, of: candidates.count,
                                           tiedWith: candidates.filter { $0.element.id != block.id && score($0.element) == score(block) }.count)
                    : "\(ContextPriority.label(block.priority).lowercased()) priority"
                if protectedTokens > settings.budget {
                    kinds[block.id] = .excludedByBudget
                    reasons[block.id] = "Excluded: \(because); protected content alone (\(protectedTokens)) already exceeds the budget of \(settings.budget)."
                    continue
                }
                kept.insert(block.id)
                let total = counter.countJoined(parts(draft, keeping: kept), separator: SelectionReport.separator)
                if total <= settings.budget {
                    kinds[block.id] = .retained
                    reasons[block.id] = "Kept: \(because); assembled prompt \(total) of \(settings.budget) after adding it."
                } else {
                    kept.remove(block.id)
                    kinds[block.id] = .excludedByBudget
                    reasons[block.id] = "Excluded: \(because); adding it would make the assembled prompt \(total), over the budget of \(settings.budget). The block was not shortened."
                }
            }
        }

        if isCancelled() { throw CancellationError() }
        let keptIDs = Set(blocks.filter { kinds[$0.id]?.kept == true }.map(\.id))
        let requiredIDs = Set(blocks.filter { kinds[$0.id] == .required }.map(\.id))
        let originalParts = parts(draft, keeping: nil)
        let selectedParts = parts(draft, keeping: keptIDs)
        let decisions = blocks.map { block in
            BlockDecision(id: block.id, title: title(block), category: block.category, priority: block.priority,
                          required: block.required, kind: kinds[block.id]!, reason: reasons[block.id]!,
                          standaloneTokens: counter.count(block.text), duplicateOf: duplicateOf[block.id],
                          relevance: relevance[block.id], considerationRank: ranks[block.id])
        }
        return SelectionReport(
            engineVersion: SelectionReport.currentEngineVersion,
            input: draft, settings: settings, counter: counter.descriptor,
            originalPrompt: originalParts.joined(separator: SelectionReport.separator),
            selectedPrompt: selectedParts.joined(separator: SelectionReport.separator),
            originalTokens: counter.countJoined(originalParts, separator: SelectionReport.separator),
            selectedTokens: counter.countJoined(selectedParts, separator: SelectionReport.separator),
            protectedTokens: counter.countJoined(parts(draft, keeping: requiredIDs), separator: SelectionReport.separator),
            decisions: decisions,
            taskTokens: counter.count(draft.task),
            instructionsTokens: counter.count(draft.instructions),
            ranker: settings.strategy == .taskRelevance ? ranker.descriptor : nil,
            taskTerms: taskTerms,
            relevanceNote: relevanceNote)
    }

    static func relevanceExplanation(_ block: ContextBlock, score: RelevanceScore?, rank: Int, of total: Int, tiedWith ties: Int) -> String {
        let value = score?.score ?? 0
        var text: String
        if let score, !score.matchedTerms.isEmpty {
            text = "relevance \(format(value)) from \(score.matchedTerms.map(\.term).joined(separator: ", ")); considered \(rank) of \(total)"
        } else {
            text = "relevance 0 (no task terms found; considered after every matching block, \(rank) of \(total))"
        }
        if ties > 0 {
            text += "; tied with \(ties) other block\(ties == 1 ? "" : "s"), so manual priority (\(ContextPriority.label(block.priority).lowercased())) then prompt order decided"
        }
        return text
    }

    static func format(_ value: Double) -> String { String(format: "%.2f", value) }
}

/// Tracks which background calculation is the latest, so an older result can never replace a newer one.
public struct LatestResultGate: Sendable {
    public private(set) var generation = 0
    public init() {}
    /// Start a calculation; returns its ticket.
    public mutating func begin() -> Int { generation += 1; return generation }
    /// Make every outstanding ticket stale (for example when inputs change).
    public mutating func invalidate() { generation += 1 }
    public func isLatest(_ ticket: Int) -> Bool { ticket == generation }
}

/// What a selection run actually did, in plain terms. An unchanged prompt is never described as optimised.
public enum SelectionOutcome: Equatable, Sendable {
    /// No context block has text: the prompt is only the task and instructions.
    case noContext
    /// The full-context strategy kept everything by design.
    case fullContextRetained
    /// A reducing strategy ran but removed nothing.
    case nothingRemoved
    /// Only exact duplicates were removed.
    case duplicatesRemoved(count: Int)
    /// Optional blocks were left out because of the budget (plus any duplicates removed).
    case excludedForBudget(excluded: Int, duplicates: Int)
    /// Task, instructions and required blocks alone are over the budget; they were kept intact.
    case protectedExceedsBudget(overBy: Int, excluded: Int)

    public var title: String {
        switch self {
        case .noContext: return "No context to optimise"
        case .fullContextRetained: return "Full context: everything retained"
        case .nothingRemoved: return "Nothing removed by this strategy"
        case .duplicatesRemoved: return "Exact duplicates removed"
        case .excludedForBudget: return "Optional context excluded for the budget"
        case .protectedExceedsBudget: return "Protected content exceeds the budget"
        }
    }

    public var explanation: String {
        func blocks(_ n: Int) -> String { "\(n) optional block\(n == 1 ? "" : "s")" }
        switch self {
        case .noContext:
            return "There are no context blocks with text, so the prompt is just the task and instructions."
        case .fullContextRetained:
            return "This strategy keeps every block. Use it as the reference when comparing answers."
        case .nothingRemoved:
            return "Every context block was kept, so the prepared prompt is the same as the full-context prompt."
        case .duplicatesRemoved(let n):
            return "\(blocks(n).capitalizedFirst) \(n == 1 ? "was a byte-for-byte copy" : "were byte-for-byte copies") of kept text. Nothing else was removed."
        case .excludedForBudget(let excluded, let duplicates):
            let dup = duplicates > 0 ? " \(duplicates) exact duplicate\(duplicates == 1 ? " was" : "s were") also removed." : ""
            return "\(blocks(excluded).capitalizedFirst) did not fit the budget and \(excluded == 1 ? "was" : "were") left out whole, not shortened.\(dup) Check them for information the task needs."
        case .protectedExceedsBudget(let overBy, _):
            return "The task, instructions and required blocks alone are \(overBy) over the budget. They were kept intact and all optional context was left out."
        }
    }

    /// True when the prepared prompt differs from the full-context prompt.
    public var removedContext: Bool {
        switch self {
        case .noContext, .fullContextRetained, .nothingRemoved: return false
        case .duplicatesRemoved, .excludedForBudget: return true
        case .protectedExceedsBudget(_, let excluded): return excluded > 0
        }
    }
}

extension SelectionReport {
    public var outcome: SelectionOutcome {
        let excluded = decisions.filter { $0.kind == .excludedByBudget }.count
        let duplicates = decisions.filter { $0.kind == .duplicateRemoved }.count
        if budgetEnforced && protectedExceedsBudget {
            return .protectedExceedsBudget(overBy: protectedTokens - budget, excluded: excluded)
        }
        if decisions.allSatisfy({ $0.kind == .emptySkipped }) { return .noContext }
        if settings.strategy == .baseline { return .fullContextRetained }
        if excluded > 0 { return .excludedForBudget(excluded: excluded, duplicates: duplicates) }
        if duplicates > 0 { return .duplicatesRemoved(count: duplicates) }
        return .nothingRemoved
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
