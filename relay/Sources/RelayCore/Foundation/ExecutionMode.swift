import Foundation

/// Whether something happened against a simulation or a real external service.
///
/// Every score, run report and challenge log entry carries a mode so a simulated
/// result can never be presented as a live one.
public enum ExecutionMode: String, Codable, Sendable, CaseIterable {
    case simulation
    case live

    /// Short label that must accompany any number derived in this mode.
    public var label: String {
        switch self {
        case .simulation: return "SIMULATED"
        case .live: return "LIVE"
        }
    }
}

/// A score that cannot be displayed without its provenance.
public struct LabeledScore: Codable, Sendable, Equatable {
    public let mode: ExecutionMode
    public let value: Double
    /// Who produced the number, e.g. "Relay simulator (seed 7)". Live scores must come from
    /// the challenge service itself; Relay never computes a "live" score locally.
    public let source: String

    public init(mode: ExecutionMode, value: Double, source: String) {
        self.mode = mode
        self.value = value
        self.source = source
    }

    /// The only sanctioned way to render a score as text.
    public var displayText: String {
        let number = value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
        switch mode {
        case .simulation:
            return "\(number) (SIMULATED — \(source); not a challenge result)"
        case .live:
            return "\(number) (LIVE — reported by \(source))"
        }
    }
}
