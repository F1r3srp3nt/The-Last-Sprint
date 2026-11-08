import Foundation

/// Overall human judgement of the selected-context answer. Stays `.notEvaluated` until a review happens.
public enum QualityVerdict: String, Codable, CaseIterable, Identifiable, Sendable {
    case notEvaluated
    case equivalent
    case acceptableWithLosses
    case degraded
    case unusable

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .notEvaluated: return "Not evaluated"
        case .equivalent: return "Equivalent to full-context answer"
        case .acceptableWithLosses: return "Acceptable, minor losses"
        case .degraded: return "Degraded"
        case .unusable: return "Unusable"
        }
    }
}

public enum CheckResult: String, Codable, CaseIterable, Identifiable, Sendable {
    case notChecked, pass, fail
    public var id: String { rawValue }
    public var label: String {
        switch self { case .notChecked: return "Not checked"; case .pass: return "Pass"; case .fail: return "Fail" }
    }
}

/// An expected fact or correctness check, judged separately for each answer.
public struct ReviewCheck: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var fullContext: CheckResult
    public var selectedContext: CheckResult
    public init(id: UUID = UUID(), text: String = "", fullContext: CheckResult = .notChecked, selectedContext: CheckResult = .notChecked) {
        self.id = id; self.text = text; self.fullContext = fullContext; self.selectedContext = selectedContext
    }
}

/// Usage numbers copied from a provider's response by the reviewer. Kept apart from local estimates.
public struct ProviderUsage: Codable, Equatable, Hashable, Sendable {
    public var provider: String
    public var model: String
    public var inputTokens: Int?
    public var outputTokens: Int?
    public init(provider: String = "", model: String = "", inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.provider = provider; self.model = model; self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
    public var isEmpty: Bool { provider.isEmpty && model.isEmpty && inputTokens == nil && outputTokens == nil }
}

/// Which answer slot of an evaluation: the full-context reference or the selected-context candidate.
public enum AnswerSlot: String, Codable, CaseIterable, Identifiable, Sendable {
    case fullContext, selectedContext
    public var id: String { rawValue }
    public var label: String { self == .fullContext ? "full-context" : "selected-context" }
}

/// Which list of review criteria.
public enum ReviewCheckList: Sendable {
    case expectedFacts, correctnessChecks
}

/// Where a recorded answer came from. It links the answer to a saved prompt by content hash; it is
/// not evidence that any provider actually received that prompt.
public struct AnswerProvenance: Codable, Equatable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// Typed or pasted by a person in this app.
        case manualEntry
    }
    public var source: Source
    /// The saved prompt the answer was entered for.
    public var promptRole: AnswerSlot
    /// SHA-256 of the saved prompt's UTF-8 bytes at the time of entry.
    public var promptSHA256: String
    public var lastEditedAt: Date
    /// Set when the answer was copied from another experiment's full-context reference.
    public var copiedFromExperimentID: UUID?

    public static let caveat = "This records which saved prompt the answer was entered for. It does not prove that a provider received that prompt."

    public func matches(prompt: String) -> Bool { promptSHA256 == Self.hash(prompt) }

    static func hash(_ prompt: String) -> String { SHA256Digest.hex(Data(prompt.utf8)) }
}

/// One model answer for one prompt variant, recorded manually (no live calls in this version).
public struct ModelRun: Codable, Equatable, Hashable, Sendable {
    public var responseText: String
    public var usage: ProviderUsage
    /// `nil` for answers recorded before provenance existed: shown as “Source not recorded”.
    public var provenance: AnswerProvenance?

    public init(responseText: String = "", usage: ProviderUsage = ProviderUsage(), provenance: AnswerProvenance? = nil) {
        self.responseText = responseText; self.usage = usage; self.provenance = provenance
    }
    public var hasResponse: Bool { !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Nothing at all has been entered: no text, no usage, no provider/model, no provenance.
    public var isBlank: Bool { responseText.isEmpty && usage.isEmpty && provenance == nil }
}

/// Signed change from a baseline count to a candidate count, formatted without double negatives.
public enum TokenChange {
    public static func describe(baseline: Int, candidate: Int, unit: String = "tokens") -> String {
        let change = candidate - baseline
        if change == 0 { return "No change" }
        let magnitude = "\(abs(change)) \(change < 0 ? "fewer" : "more") \(unit)"
        guard baseline != 0 else { return "\(magnitude) (no percentage: baseline is 0)" }
        let percent = Double(abs(change)) / Double(baseline) * 100
        return "\(magnitude) (\(change < 0 ? "\u{2212}" : "+")\(String(format: "%.1f", percent))%)"
    }
}

/// Whether the two provider-reported input counts can be compared, and why not if they can't.
public enum ProviderInputComparison: Equatable, Sendable {
    case comparable(provider: String, model: String, fullContext: Int, selectedContext: Int)
    case unavailable(reason: String)

    public static let caveat = "Matching provider and model labels do not establish identical generation settings, answer correctness or monetary savings."

    public var isComparable: Bool {
        if case .comparable = self { return true }
        return false
    }

    public var summary: String {
        switch self {
        case .comparable(_, _, let full, let selected): return TokenChange.describe(baseline: full, candidate: selected)
        case .unavailable(let reason): return reason
        }
    }
}

/// Side-by-side evaluation of the full-context and selected-context prompts for the same task.
///
/// All changes that affect a review go through the mutating methods below, which apply one rule set:
/// changing an answer clears the verdict and that answer's check results; changing a criterion's
/// wording resets that criterion for both answers and clears the verdict; changing a check result,
/// or adding or removing a criterion, clears the verdict. Reviewer name and notes never do.
public struct Evaluation: Codable, Equatable, Sendable {
    public internal(set) var fullContextRun: ModelRun
    public internal(set) var selectedContextRun: ModelRun
    public internal(set) var expectedFacts: [ReviewCheck]
    public internal(set) var correctnessChecks: [ReviewCheck]
    public internal(set) var verdict: QualityVerdict
    public var reviewer: String
    public var reviewerNotes: String
    public internal(set) var evaluatedAt: Date?

    public init() {
        fullContextRun = ModelRun(); selectedContextRun = ModelRun()
        expectedFacts = []; correctnessChecks = []
        verdict = .notEvaluated; reviewer = ""; reviewerNotes = ""; evaluatedAt = nil
    }

    /// A fresh, unevaluated record with the task's review criteria as unchecked items.
    public init(template: ReviewTemplate) {
        self.init()
        expectedFacts = template.expectedFacts.map { ReviewCheck(text: $0) }
        correctnessChecks = template.correctnessChecks.map { ReviewCheck(text: $0) }
    }

    public func run(_ slot: AnswerSlot) -> ModelRun { slot == .fullContext ? fullContextRun : selectedContextRun }

    /// A verdict can only be recorded once there is a selected-context answer to judge.
    public var canRecordVerdict: Bool { selectedContextRun.hasResponse }

    public var isEvaluated: Bool { verdict != .notEvaluated }

    /// True for older records marked equivalent without a full-context answer to compare against.
    public var equivalenceLacksReference: Bool { verdict == .equivalent && !fullContextRun.hasResponse }

    public var statusLabel: String {
        if equivalenceLacksReference { return "Equivalent (recorded without a full-context answer)" }
        if isEvaluated { return verdict.label }
        if fullContextRun.hasResponse || selectedContextRun.hasResponse { return "Not evaluated (answers recorded)" }
        return "Not evaluated"
    }

    /// Provider-reported input counts are compared only when both exist and both runs carry the same,
    /// non-empty provider and model labels.
    public var providerInputComparison: ProviderInputComparison {
        let full = fullContextRun.usage, selected = selectedContextRun.usage
        guard let fullTokens = full.inputTokens, let selectedTokens = selected.inputTokens else {
            return .unavailable(reason: "Needs provider-reported input tokens for both answers.")
        }
        let labels = [full.provider, full.model, selected.provider, selected.model].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard labels.allSatisfy({ !$0.isEmpty }) else {
            return .unavailable(reason: "Needs provider and model labels for both answers.")
        }
        guard labels[0] == labels[2], labels[1] == labels[3] else {
            return .unavailable(reason: "Not compared: provider/model labels differ (\(labels[0]) · \(labels[1]) vs \(labels[2]) · \(labels[3])).")
        }
        return .comparable(provider: labels[0], model: labels[1], fullContext: fullTokens, selectedContext: selectedTokens)
    }

    /// Tally of checks for one variant: (passed, failed, notChecked).
    public func tally(selected: Bool) -> (pass: Int, fail: Int, notChecked: Int) {
        let results = (expectedFacts + correctnessChecks).map { selected ? $0.selectedContext : $0.fullContext }
        return (results.filter { $0 == .pass }.count, results.filter { $0 == .fail }.count, results.filter { $0 == .notChecked }.count)
    }

    // MARK: Editing (the only paths that change review-relevant data)

    /// Enter or edit an answer for the saved `prompt` it belongs to. Records manual-entry provenance,
    /// clears the verdict and resets that answer's check results. Clearing the text removes provenance.
    public mutating func setAnswer(_ text: String, for slot: AnswerSlot, prompt: String, at date: Date = Date()) {
        guard run(slot).responseText != text else { return }
        modifyRun(slot) { run in
            let copiedFrom = run.provenance?.copiedFromExperimentID
            run.responseText = text
            run.provenance = text.isEmpty ? nil : AnswerProvenance(
                source: .manualEntry, promptRole: slot, promptSHA256: AnswerProvenance.hash(prompt),
                lastEditedAt: ProjectCodec.wholeSeconds(date), copiedFromExperimentID: copiedFrom)
        }
        answerChanged(slot)
    }

    /// Provider usage labels and counts. They do not change the review.
    public mutating func setUsage(_ usage: ProviderUsage, for slot: AnswerSlot) {
        modifyRun(slot) { $0.usage = usage }
    }

    @discardableResult
    public mutating func addCheck(to list: ReviewCheckList, text: String = "") -> UUID {
        let check = ReviewCheck(text: text)
        switch list {
        case .expectedFacts: expectedFacts.append(check)
        case .correctnessChecks: correctnessChecks.append(check)
        }
        clearVerdict()
        return check.id
    }

    public mutating func removeCheck(id: UUID) {
        let before = expectedFacts.count + correctnessChecks.count
        expectedFacts.removeAll { $0.id == id }
        correctnessChecks.removeAll { $0.id == id }
        if expectedFacts.count + correctnessChecks.count != before { clearVerdict() }
    }

    /// Changing a criterion's wording resets its results for both answers and clears the verdict.
    public mutating func setCheckText(id: UUID, _ text: String) {
        modifyCheck(id) { check, changed in
            guard check.text != text else { return }
            check.text = text; check.fullContext = .notChecked; check.selectedContext = .notChecked
            changed = true
        }
    }

    public mutating func setCheckResult(id: UUID, slot: AnswerSlot, _ result: CheckResult) {
        modifyCheck(id) { check, changed in
            if slot == .fullContext, check.fullContext != result { check.fullContext = result; changed = true }
            if slot == .selectedContext, check.selectedContext != result { check.selectedContext = result; changed = true }
        }
    }

    /// Record a verdict. Moving back to `.notEvaluated` clears the timestamp.
    public mutating func setVerdict(_ verdict: QualityVerdict, at date: Date = Date()) throws {
        if verdict != .notEvaluated && !canRecordVerdict {
            throw LabError.invalid("Record the selected-context answer before giving a quality verdict.")
        }
        if verdict == .equivalent && !fullContextRun.hasResponse {
            throw LabError.invalid("Record the full-context answer before marking the answers equivalent.")
        }
        self.verdict = verdict
        evaluatedAt = verdict == .notEvaluated ? nil : ProjectCodec.wholeSeconds(date)
    }

    /// Place a shared full-context reference into a blank slot (see `ReferenceSharing`).
    mutating func receiveReference(_ reference: ModelRun, from sourceID: UUID) {
        var copy = reference
        copy.provenance?.copiedFromExperimentID = sourceID
        fullContextRun = copy
        answerChanged(.fullContext)
    }

    private mutating func modifyRun(_ slot: AnswerSlot, _ body: (inout ModelRun) -> Void) {
        if slot == .fullContext { body(&fullContextRun) } else { body(&selectedContextRun) }
    }

    private mutating func modifyCheck(_ id: UUID, _ body: (inout ReviewCheck, inout Bool) -> Void) {
        var changed = false
        if let i = expectedFacts.firstIndex(where: { $0.id == id }) { body(&expectedFacts[i], &changed) }
        else if let i = correctnessChecks.firstIndex(where: { $0.id == id }) { body(&correctnessChecks[i], &changed) }
        if changed { clearVerdict() }
    }

    private mutating func answerChanged(_ slot: AnswerSlot) {
        for i in expectedFacts.indices { reset(&expectedFacts[i], slot) }
        for i in correctnessChecks.indices { reset(&correctnessChecks[i], slot) }
        clearVerdict()
    }

    private func reset(_ check: inout ReviewCheck, _ slot: AnswerSlot) {
        if slot == .fullContext { check.fullContext = .notChecked } else { check.selectedContext = .notChecked }
    }

    private mutating func clearVerdict() {
        verdict = .notEvaluated
        evaluatedAt = nil
    }

    /// Loading stays permissive for older records (for example an “equivalent” verdict saved without a
    /// full-context answer is shown as such, not rejected).
    public func validate() throws {
        if isEvaluated && !canRecordVerdict {
            throw LabError.invalid("An experiment has a quality verdict but no selected-context answer.")
        }
        let ids = (expectedFacts + correctnessChecks).map(\.id)
        guard Set(ids).count == ids.count else { throw LabError.invalid("Review checks contain duplicate identifiers.") }
        for usage in [fullContextRun.usage, selectedContextRun.usage] {
            for value in [usage.inputTokens, usage.outputTokens].compactMap({ $0 }) where value < 0 {
                throw LabError.invalid("Provider-reported token counts cannot be negative.")
            }
        }
    }
}

/// Copies a full-context reference answer between linked comparison experiments, only into blank slots.
public enum ReferenceSharing {
    public enum SkipReason: String, CaseIterable, Sendable {
        case differentPrompt, destinationNotBlank

        public var explanation: String {
            switch self {
            case .differentPrompt: return "its saved full-context prompt is different"
            case .destinationNotBlank: return "it already has a full-context answer, usage, labels or provenance"
            }
        }
    }

    public struct Outcome: Equatable, Sendable {
        public var copied: Int = 0
        public var skipped: [SkipReason: Int] = [:]
        public var sourceUnavailable: String?

        public var summary: String {
            if let sourceUnavailable { return sourceUnavailable }
            var parts = ["Copied the full-context reference to \(copied) experiment\(copied == 1 ? "" : "s")."]
            for reason in SkipReason.allCases {
                if let n = skipped[reason], n > 0 { parts.append("Skipped \(n): \(reason.explanation).") }
            }
            parts.append("Candidate answers, checks and verdicts were not copied.")
            return parts.joined(separator: " ")
        }
    }

    /// Considers every other experiment; returns the updated list and what happened.
    public static func share(from sourceID: UUID, in experiments: [Experiment]) -> ([Experiment], Outcome) {
        var outcome = Outcome()
        guard let source = experiments.first(where: { $0.id == sourceID }) else {
            outcome.sourceUnavailable = "The source experiment no longer exists."
            return (experiments, outcome)
        }
        guard let group = source.comparison?.groupID else {
            outcome.sourceUnavailable = "Only experiments saved from a comparison can share a reference."
            return (experiments, outcome)
        }
        guard source.evaluation.fullContextRun.hasResponse else {
            outcome.sourceUnavailable = "Record a full-context answer before sharing it."
            return (experiments, outcome)
        }
        let sourcePrompt = Array(source.snapshot.originalPrompt.utf8)
        var updated = experiments
        for index in updated.indices where updated[index].id != sourceID {
            let destination = updated[index]
            guard destination.comparison?.groupID == group else { continue } // unrelated experiments are not counted
            if Array(destination.snapshot.originalPrompt.utf8) != sourcePrompt {
                outcome.skipped[.differentPrompt, default: 0] += 1
            } else if !destination.evaluation.fullContextRun.isBlank {
                outcome.skipped[.destinationNotBlank, default: 0] += 1
            } else {
                updated[index].evaluation.receiveReference(source.evaluation.fullContextRun, from: sourceID)
                outcome.copied += 1
            }
        }
        return (updated, outcome)
    }
}

/// A saved, self-contained snapshot of one selection run plus its manual evaluation.
/// Value semantics: later edits to the workspace never change a saved experiment.
public struct Experiment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var snapshot: SelectionReport
    public var evaluation: Evaluation
    /// Set when the experiment was saved as part of a four-way comparison.
    public var comparison: ComparisonMembership?

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), snapshot: SelectionReport,
                evaluation: Evaluation = Evaluation(), comparison: ComparisonMembership? = nil) {
        self.id = id; self.name = name; self.createdAt = ProjectCodec.wholeSeconds(createdAt)
        self.snapshot = snapshot; self.evaluation = evaluation; self.comparison = comparison
    }

    /// Structural checks for persisted experiments. Does not re-run the engine: snapshots stay
    /// loadable even when the engine or counters change; use `ReproductionCheck` to compare.
    public func validate() throws {
        try snapshot.settings.validate()
        try SelectionEngine.validate(snapshot.input)
        guard snapshot.decisions.map(\.id) == snapshot.input.blocks.map(\.id) else {
            throw LabError.invalid("Experiment “\(name)” has decisions that do not match its saved inputs.")
        }
        guard [snapshot.originalTokens, snapshot.selectedTokens, snapshot.protectedTokens].allSatisfy({ $0 >= 0 }) else {
            throw LabError.invalid("Experiment “\(name)” contains negative token counts.")
        }
        guard snapshot.originalPrompt == SelectionEngine.assemble(snapshot.input) else {
            throw LabError.invalid("Experiment “\(name)” has an original prompt that does not match its saved inputs.")
        }
        let kept = Set(snapshot.decisions.filter(\.kept).map(\.id))
        guard snapshot.selectedPrompt == SelectionEngine.assemble(snapshot.input, keeping: kept) else {
            throw LabError.invalid("Experiment “\(name)” has a selected prompt that does not match its recorded decisions.")
        }
        if let comparison, comparison.variant.strategy != snapshot.settings.strategy {
            throw LabError.invalid("Experiment “\(name)” is labelled \(comparison.variant.label) but used \(snapshot.settings.strategy.displayName).")
        }
        try evaluation.validate()
    }
}

/// Re-runs a snapshot with the current engine and counter and reports any difference.
public enum ReproductionResult: Equatable, Sendable {
    case identical
    case differs([String])
    case counterUnavailable(String)
}

public enum ReproductionCheck {
    public static func run(_ experiment: Experiment, resolver: TokenCounterResolver,
                           ranker: any RelevanceRanker = KeywordOverlapRanker()) -> ReproductionResult {
        let snapshot = experiment.snapshot
        let counter: any TokenCounter
        do { counter = try resolver.counter(for: snapshot.settings.counter) }
        catch { return .counterUnavailable(error.localizedDescription) }
        let rerun: SelectionReport
        do { rerun = try SelectionEngine.run(snapshot.input, settings: snapshot.settings, counter: counter, ranker: ranker) }
        catch { return .differs(["The saved inputs no longer pass validation: \(error.localizedDescription)"]) }
        var differences: [String] = []
        if rerun.engineVersion != snapshot.engineVersion { differences.append("Engine version: saved \(snapshot.engineVersion), now \(rerun.engineVersion).") }
        if rerun.counter != snapshot.counter { differences.append("Counter: saved “\(snapshot.counter.id) \(snapshot.counter.version)”, now “\(rerun.counter.id) \(rerun.counter.version)”.") }
        if let saved = snapshot.ranker, saved != rerun.ranker { differences.append("Ranker: saved “\(saved.version)”, now “\(rerun.ranker?.version ?? "none")”.") }
        if rerun.selectedPrompt != snapshot.selectedPrompt { differences.append("The selected prompt text differs.") }
        if rerun.decisions.map(\.kind) != snapshot.decisions.map(\.kind) { differences.append("Keep/remove decisions differ.") }
        if rerun.originalTokens != snapshot.originalTokens || rerun.selectedTokens != snapshot.selectedTokens {
            differences.append("Token counts differ: saved \(snapshot.originalTokens)→\(snapshot.selectedTokens), now \(rerun.originalTokens)→\(rerun.selectedTokens).")
        }
        return differences.isEmpty ? .identical : .differs(differences)
    }
}
