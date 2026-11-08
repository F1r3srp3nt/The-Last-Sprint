import Foundation

/// Configuration state of a speech service, as shown in the UI. Never reports "connected"
/// unless a real request to the provider succeeded.
public enum SpeechServiceStatus: Sendable, Equatable {
    /// No credential saved. Voice features are disabled; text works.
    case unconfigured
    /// A credential is saved but has not been verified against the provider yet.
    case configuredUnverified
    case checking
    /// A real request succeeded at this time.
    case connected(verifiedAt: Date)
    case failed(String)

    public var label: String {
        switch self {
        case .unconfigured: return "Not configured — text only"
        case .configuredUnverified: return "Key saved — not verified"
        case .checking: return "Checking…"
        case .connected: return "Connected (verified)"
        case let .failed(reason): return "Failed: \(reason)"
        }
    }

    /// Whether voice requests may be attempted. A failed check still allows trying again.
    public var allowsRequests: Bool {
        switch self {
        case .unconfigured, .checking: return false
        case .configuredUnverified, .connected, .failed: return true
        }
    }
}

/// Push-to-talk / playback state machine, independent of any UI or audio framework.
public enum VoiceState: Sendable, Equatable {
    case idle
    case recording(startedAt: Date)
    case transcribing
    /// Transcript ready for review/editing before it is sent to reasoning.
    case reviewing(original: String, provider: String)
    case speaking
    case failed(String)

    public var label: String {
        switch self {
        case .idle: return "Ready"
        case .recording: return "Recording — release to stop"
        case .transcribing: return "Transcribing…"
        case .reviewing: return "Review the transcript, then send"
        case .speaking: return "Speaking"
        case let .failed(reason): return "Problem: \(reason)"
        }
    }
}

public enum VoiceEvent: Sendable, Equatable {
    case pressTalk(at: Date)
    case releaseTalk
    case transcriptReady(text: String, provider: String)
    case transcriptionFailed(String)
    case submitReview
    case discardReview
    case startSpeaking
    case stopSpeaking
    case finishedSpeaking
    case speakingFailed(String)
    case dismissError
}

public struct VoiceStateMachineError: Error, Equatable, CustomStringConvertible {
    public let state: VoiceState
    public let event: VoiceEvent
    public var description: String { "Event \(event) is not valid while \(state.label)" }
}

public struct VoiceSession: Sendable, Equatable {
    public private(set) var state: VoiceState = .idle
    public var transcriberStatus: SpeechServiceStatus
    public var synthesizerStatus: SpeechServiceStatus

    public init(transcriberStatus: SpeechServiceStatus = .unconfigured,
                synthesizerStatus: SpeechServiceStatus = .unconfigured) {
        self.transcriberStatus = transcriberStatus
        self.synthesizerStatus = synthesizerStatus
    }

    public var canRecord: Bool { transcriberStatus.allowsRequests && (state == .idle || isFailed) }
    public var canSpeak: Bool { synthesizerStatus.allowsRequests }
    /// Text input is always available — the fallback when speech is unconfigured or failing.
    public var textInputAvailable: Bool { true }

    private var isFailed: Bool { if case .failed = state { return true } else { return false } }

    public mutating func handle(_ event: VoiceEvent) throws {
        switch (state, event) {
        case (_, .pressTalk(let at)) where canRecord:
            state = .recording(startedAt: at)
        case (.recording, .releaseTalk):
            state = .transcribing
        case (.transcribing, .transcriptReady(let text, let provider)):
            state = .reviewing(original: text, provider: provider)
        case (.transcribing, .transcriptionFailed(let reason)):
            state = .failed(reason)
        case (.reviewing, .submitReview), (.reviewing, .discardReview):
            state = .idle
        case (.idle, .startSpeaking) where canSpeak, (.failed, .startSpeaking) where canSpeak:
            state = .speaking
        case (.speaking, .stopSpeaking), (.speaking, .finishedSpeaking):
            state = .idle
        case (.speaking, .speakingFailed(let reason)):
            state = .failed(reason)
        case (.failed, .dismissError):
            state = .idle
        case (_, .stopSpeaking):
            break // harmless no-op: nothing is playing
        default:
            throw VoiceStateMachineError(state: state, event: event)
        }
    }
}
