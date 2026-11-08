import Foundation

/// Honest description of how Relay decides what to do, shown in Settings.
public enum ReasoningCapability {
    public static let statement = "Relay currently uses built-in rules and keyword matching. ElevenLabs provides speech input/output; it does not supply Relay’s decision-making in this implementation."

    public enum LanguageModelStatus: String, Sendable, Equatable {
        /// No adapter exists in this build, so there is nothing to configure.
        case notImplemented
        /// An adapter exists but has no credentials (not used yet).
        case notConfigured
        case configured

        public var label: String {
            switch self {
            case .notImplemented: return "Not implemented in this build"
            case .notConfigured: return "Not configured"
            case .configured: return "Configured"
            }
        }
    }

    /// There is no language-model adapter, so Settings shows no field for one.
    public static let languageModel: LanguageModelStatus = .notImplemented

    public static let worksWithoutSetup: [String] = [
        "Typing requests in Assistant",
        "Warehouse training, step by step, with cited answers and escalation",
        "The task queue and the activity log",
        "The Wybe Night Shift simulation (Wybe Runner and relay-runner)",
    ]
}
