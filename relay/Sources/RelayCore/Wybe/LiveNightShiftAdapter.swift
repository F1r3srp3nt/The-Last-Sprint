import Foundation

/// What is known and what is missing for a live Wybe Night Shift connection.
///
/// Known facts come only from organiser-published material, read on 2026-11-07:
/// - https://nightshift-board.wybe.me/join (registration form and the team key card it shows)
/// - A single unauthenticated GET of https://nightshift.wybe.me/, which answered
///   {"ok":true,"result":"Hotel Wybe night shift terminal. Speak JSON. Most things start with help."}
/// Nothing else about the protocol has been observed, so nothing else is assumed.
public enum WybeIntegration {
    public enum Status: String, Sendable, Equatable {
        /// Confirmed from organiser material.
        case known
        /// Comes from registration; only the team has it.
        case teamProvided
        /// Not known yet; must be discovered with a team key.
        case unknown
        /// Work Relay itself still has to do.
        case needsDevelopment
    }

    public struct Requirement: Identifiable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let status: Status
        public let detail: String
    }

    /// Organiser-published endpoint, from the team key card on the registration page.
    public static let endpoint = "https://nightshift.wybe.me/"

    public static let registrationSteps: [String] = [
        "Open the registration page and enter a team name (it is public on the leaderboard), the event code shown on the screen at the venue, and 1–6 member names. A contact e-mail is optional.",
        "Copy the team key straight away. It is shown once and only there (it starts with “ns_”). Use Download to save the key card. If it is lost, an organiser at the venue can issue a new one. Keep it secret: one key per team.",
        "The key card names the endpoint and how to send the key. A team can practise right away; organisers approve teams before the final.",
        "If the page says registration is closed, talk to an organiser at the venue.",
    ]

    public static let requirements: [Requirement] = [
        Requirement(id: "endpoint", title: "Challenge endpoint", status: .known,
                    detail: "\(endpoint) — from the organiser's key card. It answers: “Speak JSON. Most things start with help.”"),
        Requirement(id: "auth", title: "How to authenticate", status: .known,
                    detail: "Send the team key as “Authorization: Bearer <key>” (from the key card)."),
        Requirement(id: "team-key", title: "Team key", status: .teamProvided,
                    detail: "Issued once at registration. Relay has no field for it yet, because nothing in Relay can use it until the live adapter exists."),
        Requirement(id: "message-format", title: "Exact JSON request and response format", status: .unknown,
                    detail: "Only “Speak JSON” is public. The shape of requests and replies must be discovered with the team key."),
        Requirement(id: "commands", title: "Robot command list", status: .unknown,
                    detail: "The endpoint says most things start with help. Discovering commands needs the team key."),
        Requirement(id: "observations", title: "Task and observation format", status: .unknown,
                    detail: "How towels, lost items and room checks, deadlines and room state are reported."),
        Requirement(id: "safety", title: "Retry safety for lost responses", status: .unknown,
                    detail: "Whether an action can be safely retried or its outcome checked after a timeout."),
        Requirement(id: "limits", title: "Rate limits and scoring", status: .unknown,
                    detail: "Request limits, which actions lose points, and how practice and final shifts are scored."),
        Requirement(id: "adapter", title: "Relay live adapter", status: .needsDevelopment,
                    detail: "LiveNightShiftAdapter is a placeholder that sends nothing. Entering a key will not connect Relay; the adapter and a policy for the real commands still have to be written."),
    ]

    public static var missing: [Requirement] { requirements.filter { $0.status != .known } }
}

/// Placeholder for the real Wybe Night Shift connection.
///
/// It intentionally sends nothing. Only the endpoint and authentication scheme are known (see
/// `WybeIntegration`). The JSON message format, commands, observations and scoring are not, and
/// Relay must not guess them. Every call throws `ChallengeError.contractUnavailable`, so a runner
/// started in live mode stops before acting.
public struct LiveNightShiftAdapter: ChallengeAdapter {
    public let mode: ExecutionMode = .live
    public let name = "Wybe Night Shift (live — not implemented)"
    public let supportsStatusQuery = false

    public static let missingContract: String = {
        let missing = WybeIntegration.missing.map { "\($0.title) (\($0.status.rawValue))" }.joined(separator: "; ")
        return "The live Wybe Night Shift adapter is not implemented. Known: endpoint \(WybeIntegration.endpoint) "
            + "with Bearer team-key authentication (organiser key card). Still missing: \(missing). "
            + "Register at https://nightshift-board.wybe.me/join to obtain a team key."
    }()

    public init() {}

    public func discoverCapabilities() async throws -> [ActionSpec] {
        throw ChallengeError.contractUnavailable(Self.missingContract)
    }

    public func observe() async throws -> Observation {
        throw ChallengeError.contractUnavailable(Self.missingContract)
    }

    public func perform(_ request: ActionRequest) async throws -> ActionOutcome {
        throw ChallengeError.contractUnavailable(Self.missingContract)
    }

    public func status(of idempotencyKey: String) async throws -> ActionStatusAnswer { .unknown }

    /// No live score exists unless the real service reports one.
    public func scoreReport() async -> LabeledScore? { nil }
}
