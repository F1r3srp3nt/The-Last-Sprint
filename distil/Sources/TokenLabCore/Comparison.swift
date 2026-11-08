import Foundation

/// The four fixed configurations compared side by side for the same input.
public enum ComparisonVariant: String, Codable, CaseIterable, Identifiable, Sendable {
    case fullContext, exactDeduplication, priorityBudget, relevanceBudget

    public var id: String { rawValue }
    public var strategy: SelectionStrategy {
        switch self {
        case .fullContext: return .baseline
        case .exactDeduplication: return .exactDeduplication
        case .priorityBudget: return .budgetSelection
        case .relevanceBudget: return .taskRelevance
        }
    }
    public var label: String { strategy.displayName }
}

public struct ComparisonEntry: Identifiable, Equatable, Sendable {
    public var variant: ComparisonVariant
    public var report: SelectionReport
    public var id: ComparisonVariant { variant }
}

/// Records that an experiment was saved as one variant of a comparison.
public struct ComparisonMembership: Codable, Equatable, Hashable, Sendable {
    public var groupID: UUID
    public var groupName: String
    public var variant: ComparisonVariant
    public init(groupID: UUID, groupName: String, variant: ComparisonVariant) {
        self.groupID = groupID; self.groupName = groupName; self.variant = variant
    }
}

public enum Comparison {
    /// Settings for one variant: the project's budget, counter and dedupe-before-budget flag, with the
    /// variant's strategy. Only the strategy differs between variants.
    public static func settings(for variant: ComparisonVariant, base: SelectionSettings) -> SelectionSettings {
        var settings = base
        settings.strategy = variant.strategy
        return settings
    }

    public static func run(_ draft: Draft, base: SelectionSettings, counter: any TokenCounter,
                           ranker: any RelevanceRanker = KeywordOverlapRanker(),
                           isCancelled: () -> Bool = { false }) throws -> [ComparisonEntry] {
        try ComparisonVariant.allCases.map { variant in
            if isCancelled() { throw CancellationError() }
            return ComparisonEntry(variant: variant,
                                   report: try SelectionEngine.run(draft, settings: settings(for: variant, base: base),
                                                                   counter: counter, ranker: ranker, isCancelled: isCancelled))
        }
    }

    public static func isCurrent(_ entries: [ComparisonEntry], draft: Draft, base: SelectionSettings, counter: TokenCounterDescriptor) -> Bool {
        entries.count == ComparisonVariant.allCases.count && entries.allSatisfy {
            $0.report.isCurrent(draft: draft, settings: settings(for: $0.variant, base: base), counter: counter)
        }
    }

    /// One experiment per variant, sharing a group, each with its own copy of the review criteria.
    public static func experiments(from entries: [ComparisonEntry], groupName: String, template: ReviewTemplate,
                                   createdAt: Date = Date()) -> [Experiment] {
        let groupID = UUID()
        return entries.map { entry in
            Experiment(name: "\(groupName) — \(entry.variant.label)", createdAt: createdAt, snapshot: entry.report,
                       evaluation: Evaluation(template: template),
                       comparison: ComparisonMembership(groupID: groupID, groupName: groupName, variant: entry.variant))
        }
    }
}
