import Foundation

/// Identifies how relevance was computed. Stored in reports so rankings can be reproduced.
public struct RankerDescriptor: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var version: String
    /// Plain-language description of the method.
    public var method: String
    /// Known weaknesses, shown to the user next to rankings.
    public var limitations: [String]
}

/// One task term found in a block, and how much it added to the block's score.
public struct TermContribution: Codable, Equatable, Hashable, Sendable {
    public var term: String
    /// Added to the score once per block, however often the term occurs.
    public var weight: Double
    /// How many times the term occurs in the block (shown for information; not scored).
    public var occurrences: Int
}

public struct RelevanceScore: Codable, Equatable, Hashable, Sendable {
    /// Sum of the weights of distinct task terms found in the block, rounded to 3 decimals.
    public var score: Double
    public var matchedTerms: [TermContribution]
    public var isZeroMatch: Bool { matchedTerms.isEmpty }
}

/// Replaceable ranking interface. Rankers only score; they never select, count tokens or edit text.
public protocol RelevanceRanker: Sendable {
    var descriptor: RankerDescriptor { get }
    /// The distinct terms extracted from the task, in first-appearance order.
    func taskTerms(_ task: String) -> [String]
    /// Scores for every block, keyed by block id. Must be deterministic.
    func scores(task: String, blocks: [ContextBlock]) -> [UUID: RelevanceScore]
}

/// Deterministic keyword-overlap ranking with inverse-document-frequency weights.
///
/// - Terms: text is canonically normalised for comparison only, lower-cased, and split into runs of
///   letters and digits; runs are also split at lower→upper case changes (`parseDueDate` → `parse`,
///   `due`, `date`). Terms shorter than 2 characters and a short list of common English words are ignored.
/// - Weight of a task term = 1 + ln((N + 1) / (df + 1)), where N is the number of non-empty blocks
///   and df the number of those blocks containing the term. Rare terms count more than common ones.
/// - Score of a block = sum of the weights of the distinct task terms it contains. Repeating a term
///   does not raise the score.
public struct KeywordOverlapRanker: RelevanceRanker {
    public init() {}

    public static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "do", "does", "for", "from", "has", "have",
        "how", "if", "in", "into", "is", "it", "its", "of", "on", "or", "our", "so", "such", "that", "the", "their",
        "them", "then", "there", "these", "they", "this", "to", "was", "we", "were", "what", "when", "where", "which",
        "who", "why", "will", "with", "would", "you", "your", "me", "my", "i", "all", "any", "some", "not", "no",
        "please", "should", "could", "about", "also", "than", "too", "very", "just", "only", "use", "using"
    ]

    public var descriptor: RankerDescriptor {
        RankerDescriptor(
            id: "keyword-overlap-idf",
            displayName: "Keyword overlap (local, deterministic)",
            version: "keyword-overlap-1",
            method: "Each block scores the sum of weights of the distinct task terms it contains. A term's weight is 1 + ln((N+1)/(df+1)), so terms that appear in fewer blocks count more. Terms are lower-cased words and identifier parts; common English words and one-character terms are ignored.",
            limitations: [
                "Matches exact words only: no synonyms, paraphrases, stemming or translation (“refund” ≠ “money back”, “parse” ≠ “parsing”).",
                "A block can match many task words and still be irrelevant, or match none and be essential.",
                "Repetition does not raise a score, but keyword-heavy filler can still outrank useful text.",
                "Blocks with no matching terms score 0. They are not removed for that reason: they are considered after every matching block and kept if the budget allows.",
                "Equal scores are ordered by manual priority, then by position in the prompt."
            ])
    }

    public func taskTerms(_ task: String) -> [String] {
        var seen = Set<String>()
        return Self.terms(in: task).filter { seen.insert($0).inserted }
    }

    public func scores(task: String, blocks: [ContextBlock]) -> [UUID: RelevanceScore] {
        let queryTerms = taskTerms(task)
        let scored = blocks.filter { !$0.text.isEmpty }
        let counts: [UUID: [String: Int]] = Dictionary(uniqueKeysWithValues: scored.map { block in
            (block.id, Self.terms(in: block.text).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 })
        })
        let n = Double(scored.count)
        var weights: [String: Double] = [:]
        for term in queryTerms {
            let df = Double(scored.filter { counts[$0.id]?[term] != nil }.count)
            weights[term] = 1 + log((n + 1) / (df + 1))
        }
        var result: [UUID: RelevanceScore] = [:]
        for block in blocks {
            let blockCounts = counts[block.id] ?? [:]
            var contributions: [TermContribution] = []
            var total = 0.0
            for term in queryTerms {
                guard let occurrences = blockCounts[term], let weight = weights[term] else { continue }
                total += weight
                contributions.append(TermContribution(term: term, weight: Self.round3(weight), occurrences: occurrences))
            }
            result[block.id] = RelevanceScore(score: Self.round3(total), matchedTerms: contributions)
        }
        return result
    }

    static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    /// Lower-cased terms in reading order (with repeats). The source text is never modified.
    public static func terms(in text: String) -> [String] {
        var terms: [String] = []
        var current = ""
        var previousWasLower = false
        func flush() {
            if !current.isEmpty {
                let term = current.lowercased()
                if term.count >= 2 && !stopWords.contains(term) { terms.append(term) }
            }
            current = ""
        }
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            let isAlnum = CharacterSet.alphanumerics.contains(scalar)
            guard isAlnum else { flush(); previousWasLower = false; continue }
            let isUpper = CharacterSet.uppercaseLetters.contains(scalar)
            if isUpper && previousWasLower { flush() }
            current.unicodeScalars.append(scalar)
            previousWasLower = CharacterSet.lowercaseLetters.contains(scalar)
        }
        flush()
        return terms
    }
}
