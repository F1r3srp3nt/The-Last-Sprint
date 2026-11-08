import Foundation
import RelayCore

/// Translation between Relay's runner contract and the real Wybe commands.
///
/// This is the part that can only be written after reading the service's help answer with a team
/// key. Relay ships with NO implementation (`WybeProtocolMappings.reviewed` is nil), so the live
/// adapter refuses to act. An implementation must use only names, fields and request forms the
/// service itself documented, and must mark every command that changes the world as
/// `consequential`.
public protocol WybeProtocolMapping: Sendable {
    /// Where the mapping came from, e.g. "help answer read 2026-11-08 with team key; reviewed by …".
    var provenance: String { get }
    /// True only if the service documents a way to ask whether a given action was applied.
    var supportsStatusQuery: Bool { get }

    /// Read-only request whose answer lists the commands.
    var capabilitiesRequest: WybeRequest { get }
    func capabilities(from response: WybeResponse) throws -> [ActionSpec]
    /// Read-only request for the current state. Must not start a shift.
    var observeRequest: WybeRequest { get }
    func observation(from response: WybeResponse) throws -> Observation
    func request(for action: ActionRequest) throws -> WybeRequest
    func outcome(from response: WybeResponse, for action: ActionRequest) throws -> ActionOutcome
    func statusRequest(for idempotencyKey: String) -> WybeRequest?
    func status(from response: WybeResponse) throws -> ActionStatusAnswer
    /// Read-only request for the score the service reports, if it offers one.
    var scoreRequest: WybeRequest? { get }
    func score(from response: WybeResponse) throws -> Double?
}

public enum WybeProtocolMappings {
    /// The reviewed mapping for the real service. Deliberately nil: the help answer has not been
    /// obtained, and Relay does not invent commands, endpoints or request schemas.
    public static let reviewed: WybeProtocolMapping? = nil
}

/// The real Wybe Night Shift connection, for the autonomous runner.
///
/// Without a client (no key) or without a reviewed mapping, every call throws
/// `ChallengeError.contractUnavailable` before anything is sent, so a live run stops before acting.
///
/// Error mapping is conservative, because the service's retry semantics are unknown:
/// - Reads (capabilities, observe, status, score) are mapped to `.transient` on timeouts and
///   network/server problems, so the runner may retry them within its bounds.
/// - Actions: a timeout, network error, server error, malformed answer, rate limit (whether it
///   was applied is not documented) or a response that arrives after the settings changed are all
///   `.ambiguous`. The runner never blindly repeats a consequential action after that.
/// - A refused key (401/403) is `.contractUnavailable`: the run stops.
/// - `ok:false` is the service declining the action: `ActionOutcome(accepted: false)`.
public struct LiveNightShiftAdapter: ChallengeAdapter {
    public let mode: ExecutionMode = .live
    public let name: String
    public var supportsStatusQuery: Bool { mapping?.supportsStatusQuery ?? false }

    private let client: WybeClient?
    private let mapping: WybeProtocolMapping?
    /// Returns false once the key or connection settings changed after this adapter was made.
    private let isCurrent: @Sendable () -> Bool

    public static func missingContract(clientAvailable: Bool, mappingAvailable: Bool) -> String {
        var missing: [String] = []
        if !clientAvailable { missing.append("no team key saved") }
        if !mappingAvailable {
            missing.append("no reviewed mapping from the service's help answer to commands and observations")
        }
        return "The live Wybe Night Shift adapter will not send anything: " + missing.joined(separator: "; ")
            + ". Known: endpoint \(WybeIntegration.endpoint) with Bearer team-key authentication. "
            + "Unresolved: the help request form, command list, observation format, retry safety, rate limits and scoring."
    }

    public init(client: WybeClient? = nil, mapping: WybeProtocolMapping? = WybeProtocolMappings.reviewed,
                isCurrent: @escaping @Sendable () -> Bool = { true }) {
        self.client = client
        self.mapping = mapping
        self.isCurrent = isCurrent
        name = mapping == nil ? "Wybe Night Shift (live — no reviewed command mapping)" : "Wybe Night Shift (live)"
    }

    private func ready() throws -> (WybeClient, WybeProtocolMapping) {
        guard let client, let mapping else {
            throw ChallengeError.contractUnavailable(Self.missingContract(clientAvailable: client != nil, mappingAvailable: mapping != nil))
        }
        guard isCurrent() else {
            throw ChallengeError.contractUnavailable("The team key or connection settings changed; the live run stops.")
        }
        return (client, mapping)
    }

    // MARK: Reads

    private func read<T>(_ request: WybeRequest, _ parse: (WybeResponse) throws -> T) async throws -> T {
        let (client, _) = try ready()
        let response: WybeResponse
        do {
            response = try await client.send(request)
        } catch let failure as WybeFailure {
            throw Self.readError(failure)
        }
        guard isCurrent() else {
            throw ChallengeError.contractUnavailable("A response arrived after the settings changed; it was discarded and the run stops.")
        }
        do { return try parse(response) } catch {
            throw ChallengeError.transient("Could not read the service's answer: \(error)")
        }
    }

    static func readError(_ failure: WybeFailure) -> Error {
        switch failure {
        case .cancelled: return CancellationError()
        case .missingKey, .keyRefused, .forbidden, .settingsChanged, .invalidRequest:
            return ChallengeError.contractUnavailable(failure.description)
        case let .rateLimited(after, _): return ChallengeError.rateLimited(retryAfter: after)
        case .notOK: return ChallengeError.rejected(failure.description)
        case .timedOut, .network, .serverError, .unexpectedStatus, .malformed, .responseTooLarge:
            return ChallengeError.transient(failure.description)
        }
    }

    public func discoverCapabilities() async throws -> [ActionSpec] {
        let (_, mapping) = try ready()
        let specs = try await read(mapping.capabilitiesRequest) { try mapping.capabilities(from: $0) }
        // Simulator vocabulary must never reach the live service.
        if let leaked = specs.first(where: { $0.name.hasPrefix("sim.") }) {
            throw ChallengeError.contractUnavailable("Live capabilities may not use simulator commands (\(leaked.name)).")
        }
        return specs
    }

    public func observe() async throws -> Observation {
        let (_, mapping) = try ready()
        return try await read(mapping.observeRequest) { try mapping.observation(from: $0) }
    }

    public func status(of idempotencyKey: String) async throws -> ActionStatusAnswer {
        let (_, mapping) = try ready()
        guard mapping.supportsStatusQuery, let request = mapping.statusRequest(for: idempotencyKey) else { return .unknown }
        return try await read(request) { try mapping.status(from: $0) }
    }

    /// Only a score the service itself reports, labelled LIVE. Never computed locally.
    public func scoreReport() async -> LabeledScore? {
        guard let (_, mapping) = try? ready(), let request = mapping.scoreRequest,
              let value = try? await read(request, { try mapping.score(from: $0) }) else { return nil }
        return LabeledScore(mode: .live, value: value, source: "Wybe Night Shift service")
    }

    // MARK: Actions

    public func perform(_ action: ActionRequest) async throws -> ActionOutcome {
        let (client, mapping) = try ready()
        if action.name.hasPrefix("sim.") {
            throw ChallengeError.rejected("Simulator command \(action.name) is never sent to the live service; not sent.")
        }
        let request: WybeRequest
        do { request = try mapping.request(for: action) } catch {
            throw ChallengeError.rejected("Could not form the request for \(action.name): \(error); not sent.")
        }
        let response: WybeResponse
        do {
            response = try await client.send(request)
        } catch let failure as WybeFailure {
            switch failure {
            case .cancelled: throw CancellationError()
            case .missingKey, .invalidRequest: throw ChallengeError.contractUnavailable(failure.description + "; not sent")
            case .keyRefused, .forbidden: throw ChallengeError.contractUnavailable(failure.description)
            case let .notOK(detail): return ActionOutcome(accepted: false, message: detail.isEmpty ? "The service answered ok:false" : detail)
            case .rateLimited, .timedOut, .network, .serverError, .unexpectedStatus, .malformed, .responseTooLarge, .settingsChanged:
                throw ChallengeError.ambiguous(failure.description)
            }
        }
        guard isCurrent() else {
            throw ChallengeError.ambiguous("A response arrived after the settings changed; it was discarded, so the outcome is treated as unknown.")
        }
        do { return try mapping.outcome(from: response, for: action) } catch {
            throw ChallengeError.ambiguous("Could not read the service's answer to \(action.name): \(error)")
        }
    }
}
