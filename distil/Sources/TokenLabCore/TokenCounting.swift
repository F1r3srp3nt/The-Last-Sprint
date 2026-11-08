import Foundation

public enum CounterKind: String, Codable, Sendable {
    /// A heuristic. Never presented as a model's token count.
    case approximation
    /// A model-family tokenizer applied to plain text only.
    case modelTokenizer
}

/// Identifies exactly how a count was produced. Stored with every preview and experiment.
public struct TokenCounterDescriptor: Codable, Equatable, Hashable, Sendable {
    /// Stable identifier, e.g. `approx-utf8-bytes-div-4` or `bpe:o200k_base`.
    public var id: String
    public var displayName: String
    public var kind: CounterKind
    /// Encoding name, e.g. `utf8-bytes/4` or `o200k_base`.
    public var encoding: String
    /// Implementation and data version, e.g. `tokenlab-bpe-1; ranks-sha256=446a95…`.
    public var version: String
    /// What the count covers and what it excludes.
    public var scope: String

    public init(id: String, displayName: String, kind: CounterKind, encoding: String, version: String, scope: String) {
        self.id = id; self.displayName = displayName; self.kind = kind
        self.encoding = encoding; self.version = version; self.scope = scope
    }

    /// Short label for metrics. Model tokenizer counts are still not provider usage.
    public var metricLabel: String {
        kind == .approximation ? "estimated (\(encoding))" : "\(encoding) text tokens"
    }
}

/// Replaceable token-counting interface. Implementations must be deterministic and thread-safe.
public protocol TokenCounter: Sendable {
    var descriptor: TokenCounterDescriptor { get }
    func count(_ text: String) -> Int
    /// Count the text produced by joining `parts` with `separator`.
    /// The default joins and counts; implementations may override with an equivalent faster path.
    func countJoined(_ parts: [String], separator: String) -> Int
}

public extension TokenCounter {
    func countJoined(_ parts: [String], separator: String) -> Int {
        count(parts.joined(separator: separator))
    }
}

/// UTF-8 bytes divided by N, rounded up. Clearly a heuristic.
public struct ApproximateCounter: TokenCounter {
    public static let engineVersion = "approx-1"
    public let bytesPerToken: Int

    public init(bytesPerToken: Int = 4) {
        precondition(CounterChoice.bytesPerTokenRange.contains(bytesPerToken))
        self.bytesPerToken = bytesPerToken
    }

    public var descriptor: TokenCounterDescriptor {
        TokenCounterDescriptor(
            id: "approx-utf8-bytes-div-\(bytesPerToken)",
            displayName: "Approximate: UTF-8 bytes ÷ \(bytesPerToken)",
            kind: .approximation,
            encoding: "utf8-bytes/\(bytesPerToken)",
            version: Self.engineVersion,
            scope: "Heuristic estimate of prompt text only. Not a model tokenizer; excludes message formatting and provider overhead.")
    }

    public func count(_ text: String) -> Int { Self.ceilDiv(text.utf8.count, bytesPerToken) }

    public func countJoined(_ parts: [String], separator: String) -> Int {
        guard !parts.isEmpty else { return 0 }
        let bytes = parts.reduce(0) { $0 + $1.utf8.count } + separator.utf8.count * (parts.count - 1)
        return Self.ceilDiv(bytes, bytesPerToken)
    }

    static func ceilDiv(_ a: Int, _ b: Int) -> Int { (a + b - 1) / b }
}

/// Resolves a project's `CounterChoice` to a concrete counter.
public protocol TokenCounterResolver {
    func counter(for choice: CounterChoice) throws -> any TokenCounter
}

/// Resolver backed by already-loaded tokenizers. Approximate counters are always available.
public struct StaticCounterResolver: TokenCounterResolver, Sendable {
    public var tokenizers: [BPEEncodingID: BPETokenizer]
    public init(tokenizers: [BPEEncodingID: BPETokenizer] = [:]) { self.tokenizers = tokenizers }

    public func counter(for choice: CounterChoice) throws -> any TokenCounter {
        try choice.validate()
        switch choice {
        case .approximate(let n):
            return ApproximateCounter(bytesPerToken: n)
        case .bpe(let id):
            guard let tokenizer = tokenizers[id] else {
                throw LabError.counterUnavailable("The \(id.rawValue) encoding file is not loaded. Import it in Settings → Token counting, or switch this project to the approximate counter.")
            }
            return tokenizer
        }
    }
}
