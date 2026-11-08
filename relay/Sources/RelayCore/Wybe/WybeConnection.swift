import Foundation

// Wybe Night Shift connection model: what is known, what the team supplies, and the four
// separate readiness facts (key saved, connection verified, protocol discovered, live runner
// ready). Pure and platform independent; the HTTP client lives in RelayAdapters.
//
// Evidence (organiser material only, nothing guessed):
// - https://nightshift-board.wybe.me/join, read 2026-11-07 and again 2026-11-08 without submitting:
//   the form takes a team name, the event code from the screen at the venue, 1–6 member names and
//   an optional e-mail. On success it shows a team key once (keys start with "ns_") and a key card:
//   "Endpoint: https://nightshift.wybe.me/", "Send it as: Authorization: Bearer <key>".
// - Unauthenticated GET https://nightshift.wybe.me/ (2026-11-07 and 2026-11-08) answered
//   HTTP 200, content-type application/json:
//   {"ok":true,"result":"Hotel Wybe night shift terminal. Speak JSON. Most things start with help."}
// Nothing else about the protocol has been observed. In particular the exact form of a help
// request, the command list, the observation format, retry safety and scoring are unresolved.

public enum WybeIntegration {
    public enum Status: String, Sendable, Equatable {
        /// Confirmed from organiser material or an observed response.
        case known
        /// Comes from registration; only the team has it.
        case teamProvided
        /// Not known yet; must be discovered with a team key.
        case unknown
        /// Built in Relay, but it can only be exercised with a team key and the live server.
        case implementedUntested
        /// Work Relay itself still has to do once the protocol is known.
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
    /// Organiser registration page. The event code is typed there, never into Relay.
    public static let registrationPage = "https://nightshift-board.wybe.me/join"
    /// Prefix of team keys, as shown on the registration page.
    public static let teamKeyPrefix = "ns_"
    /// The `result` text the endpoint returned to an unauthenticated GET / (2026-11-07, 2026-11-08).
    public static let anonymousGreeting = "Hotel Wybe night shift terminal. Speak JSON. Most things start with help."

    /// Event code versus team key, in plain words. Shown in Settings and printed by relay-runner.
    public static let credentialsExplained: [String] = [
        "The event code is shown on the screen at the venue. It is typed once, into the organisers' registration page, to register the team. Relay never asks for it, stores it or sends it.",
        "Registration then shows the team key once (it starts with “ns_”). That key is a separate credential: it is what Relay sends to the endpoint, as “Authorization: Bearer <key>”.",
        "The key belongs to the whole team. Keep it secret. If it is lost, an organiser at the venue can issue a new one.",
    ]

    public static let registrationSteps: [String] = [
        "Open the registration page and enter a team name (it is public on the leaderboard), the event code shown on the screen at the venue, and 1–6 member names. A contact e-mail is optional.",
        "Copy the team key straight away. It is shown once and only there (it starts with “ns_”). Use Download to save the key card. If it is lost, an organiser at the venue can issue a new one.",
        "Paste the team key below and choose Save to Keychain. Saving does not test it: use Check connection.",
        "If the page says registration is closed, talk to an organiser at the venue.",
    ]

    public static let requirements: [Requirement] = [
        Requirement(id: "endpoint", title: "Challenge endpoint", status: .known,
                    detail: "\(endpoint) — from the organiser's key card. Without a key, GET / answers: “\(anonymousGreeting)”"),
        Requirement(id: "auth", title: "How to authenticate", status: .known,
                    detail: "Send the team key as “Authorization: Bearer <key>” (from the key card)."),
        Requirement(id: "team-key", title: "Team key", status: .teamProvided,
                    detail: "Issued once at registration, which needs the event code. Save it in Settings › Wybe; it is kept in the macOS Keychain."),
        Requirement(id: "connection", title: "Connection check", status: .implementedUntested,
                    detail: "Check connection sends one authenticated GET / — the only request whose form has been observed. It never starts a shift. Not yet run with a real key."),
        Requirement(id: "help-format", title: "How to send a help request", status: .unknown,
                    detail: "Only “Speak JSON. Most things start with help.” is public. Relay does not guess the request: record the exact form the service describes, then Discover protocol sends it once."),
        Requirement(id: "commands", title: "Robot command list", status: .unknown,
                    detail: "Expected in the help answer. Relay shows that answer verbatim; it does not turn it into commands by itself."),
        Requirement(id: "observations", title: "Task and observation format", status: .unknown,
                    detail: "How towels, lost items and room checks, deadlines and room state are reported."),
        Requirement(id: "safety", title: "Retry safety for lost responses", status: .unknown,
                    detail: "Whether an action can be safely retried or its outcome checked after a timeout. Until this is known, Relay never repeats an action whose outcome is unknown."),
        Requirement(id: "limits", title: "Rate limits and scoring", status: .unknown,
                    detail: "Request limits, which actions lose points, and how practice and final shifts are scored. Relay sends at most one request per second meanwhile."),
        Requirement(id: "mapping", title: "Reviewed command mapping and live policy", status: .needsDevelopment,
                    detail: "The live adapter, its error handling and safety limits are written. What is missing is the mapping from the real help answer to commands and observations, and a policy for those commands. Until both exist the live runner refuses to start."),
    ]

    public static var missing: [Requirement] { requirements.filter { $0.status != .known } }
}

// MARK: - JSON values

/// A decoded JSON value, used to read the observed `{"ok": …, "result": …}` envelope without
/// assuming anything about the shape of `result`.
public indirect enum WybeJSON: Equatable, Sendable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: WybeJSON])
    case array([WybeJSON])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([WybeJSON].self) { self = .array(value) }
        else if let value = try? container.decode([String: WybeJSON].self) { self = .object(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public static func parse(_ data: Data) -> WybeJSON? {
        try? JSONDecoder().decode(WybeJSON.self, from: data)
    }

    /// Compact text: strings as they are, everything else as sorted-key JSON.
    public var text: String {
        if case let .string(value) = self { return value }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// The only response shape that has been observed: a JSON object with a boolean `ok` and a
/// `result`. Any other fields are kept but not interpreted.
public struct WybeEnvelope: Equatable, Sendable {
    public let ok: Bool
    public let result: WybeJSON?
    public let otherFields: [String: WybeJSON]

    /// Returns nil when the body is not a JSON object with a boolean `ok`.
    public init?(data: Data) {
        guard case let .object(fields)? = WybeJSON.parse(data), case let .bool(ok)? = fields["ok"] else { return nil }
        self.ok = ok
        result = fields["result"]
        otherFields = fields.filter { $0.key != "ok" && $0.key != "result" }
    }

    /// Human-readable text of `result`, or of any other fields when there is no result.
    public var text: String {
        if let result { return result.text }
        return otherFields.isEmpty ? "" : WybeJSON.object(otherFields).text
    }
}

// MARK: - Requests

/// A request to the Wybe endpoint. Paths are relative to the official endpoint.
public struct WybeRequest: Equatable, Sendable {
    public enum Method: String, Codable, Sendable, CaseIterable { case get = "GET", post = "POST" }

    public let method: Method
    public let path: String
    public let body: Data?

    public init(method: Method, path: String, body: Data? = nil) {
        self.method = method
        self.path = path
        self.body = body
    }

    /// The single request whose form has been observed: GET of the endpoint root.
    public static let root = WybeRequest(method: .get, path: "/")

    public var summary: String {
        guard let body, !body.isEmpty else { return "\(method.rawValue) \(path)" }
        return "\(method.rawValue) \(path) \(String(decoding: body.prefix(200), as: UTF8.self))"
    }
}

/// The help request exactly as the service (or the organisers) describe it, recorded by the
/// team. Relay ships with none, because the form has not been observed.
public struct WybeHelpRequest: Codable, Equatable, Sendable {
    public var method: WybeRequest.Method
    public var path: String
    /// Exact JSON body for POST, as text. Empty for GET.
    public var body: String
    /// Where the team saw this form, e.g. "Result text of Check connection on 2026-11-08".
    public var source: String

    public init(method: WybeRequest.Method, path: String, body: String, source: String) {
        self.method = method
        self.path = path
        self.body = body
        self.source = source
    }

    static let maxPathLength = 200
    static let maxBodyBytes = 4_096
    /// Words that suggest a request could start or change something. Discovery only reads help.
    static let consequentialWords = ["start", "begin", "shift", "move", "pick", "deliver", "drop", "go", "reset", "submit"]

    /// Returns a problem, or nil if the request may be sent as a discovery request.
    public func problem() -> String? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPath.hasPrefix("/"), !trimmedPath.hasPrefix("//") else {
            return "The path must start with a single “/” (it is relative to \(WybeIntegration.endpoint))."
        }
        guard trimmedPath.count <= Self.maxPathLength,
              trimmedPath.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/-_.".contains($0)) }) else {
            return "The path may contain only letters, digits and / - _ . (no host, query or spaces)."
        }
        if trimmedPath.split(separator: "/").contains("..") { return "The path may not contain “..”." }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        switch method {
        case .get:
            if !trimmedBody.isEmpty { return "A GET request has no body. Choose POST if the service expects JSON." }
        case .post:
            if trimmedBody.isEmpty { return "Paste the JSON body exactly as the service describes it." }
            if trimmedBody.utf8.count > Self.maxBodyBytes { return "The body is longer than \(Self.maxBodyBytes) bytes." }
            if WybeJSON.parse(Data(trimmedBody.utf8)) == nil { return "The body is not valid JSON." }
        }
        let combined = (trimmedPath + " " + trimmedBody).lowercased()
        if combined.contains(WybeIntegration.teamKeyPrefix) {
            return "The request contains something that looks like a team key. The key is sent only in the Authorization header."
        }
        guard combined.contains("help") else {
            return "Discovery sends only a help request, and this request does not mention “help”."
        }
        let words = combined.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        if let word = words.first(where: { Self.consequentialWords.contains($0) }) {
            return "The request contains “\(word)”, which could start or change something. Discovery only reads help; it never starts a shift."
        }
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Say where this form comes from (for example the text Check connection showed), so it can be traced."
        }
        return nil
    }

    /// The request to send, or nil when `problem()` reports one.
    public var request: WybeRequest? {
        guard problem() == nil else { return nil }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return WybeRequest(method: method, path: path.trimmingCharacters(in: .whitespacesAndNewlines),
                           body: method == .post ? Data(trimmedBody.utf8) : nil)
    }
}

/// Validation of a pasted team key. The value itself is never echoed back.
public enum WybeTeamKeyValidation {
    public static func problem(with raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return "Paste the team key first." }
        if key.contains(where: { $0.isWhitespace }) {
            return "The pasted text contains spaces or line breaks, so it is not a single key. Copy just the key."
        }
        if key.lowercased().hasPrefix("bearer") {
            return "Paste only the key, without “Bearer”. Relay adds the header itself."
        }
        guard key.hasPrefix(WybeIntegration.teamKeyPrefix) else {
            return "Team keys start with “ns_”. This looks like something else — the event code from the venue screen is only for the registration page, not for Relay."
        }
        guard key.count >= 12 else { return "This is too short to be a team key. Copy the whole key." }
        guard key.allSatisfy({ $0.isASCII && !$0.isNewline }) else { return "The key contains unexpected characters." }
        return nil
    }

    /// Display form: shows the documented prefix only, never any characters of the key itself.
    public static func display(_ key: String?) -> String {
        guard let key, !key.isEmpty else { return "Not set" }
        return key.hasPrefix(WybeIntegration.teamKeyPrefix) ? "ns_•••••••• (hidden)" : "•••••••• (hidden)"
    }
}

// MARK: - Failures and problems

/// Everything that can go wrong talking to the endpoint, without transport details.
public enum WybeFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case missingKey
    /// HTTP 401.
    case keyRefused(detail: String?)
    /// HTTP 403: the service refused access but did not say why.
    case forbidden(detail: String?)
    case rateLimited(retryAfter: Double?, detail: String?)
    case serverError(status: Int, detail: String?)
    case unexpectedStatus(status: Int, detail: String?)
    /// The body is not the observed `{"ok": bool, …}` JSON envelope.
    case malformed(String)
    /// The service answered `ok: false`.
    case notOK(detail: String)
    case responseTooLarge(limit: Int)
    case timedOut(seconds: Double)
    /// Could not reach the service. Whether the request arrived is unknown.
    case network(String)
    case cancelled
    /// The key or connection settings changed while the request was pending; its result was discarded.
    case settingsChanged
    /// The request was refused locally before anything was sent.
    case invalidRequest(String)

    public var description: String {
        switch self {
        case .missingKey: return "No team key saved"
        case let .keyRefused(detail): return "HTTP 401: the key was refused" + Self.suffix(detail)
        case let .forbidden(detail): return "HTTP 403: access refused" + Self.suffix(detail)
        case let .rateLimited(after, detail):
            return "HTTP 429: rate limited" + (after.map { " (retry after \($0)s)" } ?? "") + Self.suffix(detail)
        case let .serverError(status, detail): return "HTTP \(status): server error" + Self.suffix(detail)
        case let .unexpectedStatus(status, detail): return "HTTP \(status)" + Self.suffix(detail)
        case let .malformed(why): return "Unexpected response format: \(why)"
        case let .notOK(detail): return "The service answered ok:false" + Self.suffix(detail)
        case let .responseTooLarge(limit): return "Response larger than \(limit) bytes; not read"
        case let .timedOut(seconds): return "No answer within \(seconds)s"
        case let .network(message): return "Network error: \(message)"
        case .cancelled: return "Cancelled"
        case .settingsChanged: return "Settings changed while the request was pending; result discarded"
        case let .invalidRequest(why): return "Not sent: \(why)"
        }
    }

    private static func suffix(_ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return "" }
        return " — “\(detail)”"
    }

    /// True when the request certainly did not reach the service.
    public var certainlyNotSent: Bool {
        switch self {
        case .missingKey, .invalidRequest: return true
        default: return false
        }
    }
}

/// A user-facing explanation of a Wybe failure.
public struct WybeProblem: Equatable, Sendable {
    public let title: String
    public let nextStep: String
    /// The service's own words, already redacted.
    public let serviceDetail: String?

    public init(title: String, nextStep: String, serviceDetail: String? = nil) {
        self.title = title
        self.nextStep = nextStep
        self.serviceDetail = serviceDetail
    }

    public init(_ failure: WybeFailure) {
        switch failure {
        case .missingKey:
            self.init(title: "No team key saved", nextStep: "Paste the team key from the registration page and choose Save to Keychain.")
        case let .keyRefused(detail):
            self.init(title: "The endpoint refused this team key (HTTP 401)",
                      nextStep: "Check that the whole key was pasted (it starts with “ns_”). The event code from the venue screen is not the key. If the key is lost, an organiser at the venue can issue a new one; then use Replace.",
                      serviceDetail: detail)
        case let .forbidden(detail):
            self.init(title: "The endpoint refused access (HTTP 403); the cause is not stated",
                      nextStep: "This does not show whether the key is wrong or the team is not allowed yet (organisers approve teams before the final). Ask an organiser, using the service message below.",
                      serviceDetail: detail)
        case let .rateLimited(after, detail):
            self.init(title: "The endpoint asked Relay to slow down (HTTP 429)",
                      nextStep: "Wait" + (after.map { " at least \(Int($0.rounded(.up))) seconds" } ?? " a while") + " before trying again. Relay pauses its own requests too.",
                      serviceDetail: detail)
        case let .serverError(status, detail):
            self.init(title: "The endpoint had a server problem (HTTP \(status))",
                      nextStep: "This is on the service's side. Try again later.", serviceDetail: detail)
        case let .unexpectedStatus(status, detail):
            self.init(title: "Unexpected answer (HTTP \(status))",
                      nextStep: "Relay cannot tell the cause from this response. The service's message is below.", serviceDetail: detail)
        case let .malformed(why):
            self.init(title: "The endpoint answered in an unexpected format",
                      nextStep: "Relay expects JSON with a boolean “ok”, the only format observed so far. Nothing was assumed from this answer.",
                      serviceDetail: why)
        case let .notOK(detail):
            self.init(title: "The service answered ok:false",
                      nextStep: "The service received the request and declined it. Its message is below; it may say how the request should be formed.",
                      serviceDetail: detail)
        case let .responseTooLarge(limit):
            self.init(title: "The answer was too large to read",
                      nextStep: "Relay reads at most \(limit / 1024) KB per answer to stay bounded. Nothing was assumed from it.")
        case let .timedOut(seconds):
            self.init(title: "No answer within \(Int(seconds)) seconds",
                      nextStep: "Relay cannot tell whether the request reached the service. Try again later; the check is read-only.")
        case let .network(message):
            self.init(title: "Could not reach the endpoint",
                      nextStep: "Check the internet connection and try again.", serviceDetail: message)
        case .cancelled:
            self.init(title: "Cancelled", nextStep: "Nothing further was sent.")
        case .settingsChanged:
            self.init(title: "Settings changed during the check",
                      nextStep: "The answer belonged to the previous key or settings, so it was discarded. Check again.")
        case let .invalidRequest(why):
            self.init(title: "Not sent", nextStep: why)
        }
    }
}

// MARK: - Results of the two read-only checks

public struct WybeConnectionReport: Equatable, Sendable {
    public let httpStatus: Int
    /// The `result` text, redacted and shortened.
    public let resultText: String
    /// True when the authenticated answer is the same text the endpoint gives without a key.
    public var matchesAnonymousGreeting: Bool { resultText == WybeIntegration.anonymousGreeting }

    public init(httpStatus: Int, resultText: String) {
        self.httpStatus = httpStatus
        self.resultText = resultText
    }

    public var detail: String {
        if matchesAnonymousGreeting {
            return "The endpoint answered GET / with the team key attached (HTTP \(httpStatus), ok:true) and did not refuse it. Its reply is the same one it gives without a key, so this does not prove the key is accepted; the help request will."
        }
        return "The endpoint answered GET / with the team key attached (HTTP \(httpStatus), ok:true). Its reply differs from the anonymous one and is shown below."
    }
}

/// The help request that was sent and the service's answer, verbatim but redacted.
public struct WybeHelpTranscript: Equatable, Sendable {
    public let request: String
    public let httpStatus: Int
    public let answer: String

    public init(request: String, httpStatus: Int, answer: String) {
        self.request = request
        self.httpStatus = httpStatus
        self.answer = answer
    }
}

// MARK: - Readiness

public enum WybeCheckState<Value: Equatable & Sendable>: Equatable, Sendable {
    case notChecked
    /// Running under the given settings generation.
    case checking(generation: Int)
    case passed(Value, at: Date)
    case failed(WybeProblem, at: Date)

    public var isPassed: Bool { if case .passed = self { return true } else { return false } }
    public var isChecking: Bool { if case .checking = self { return true } else { return false } }
    public var value: Value? { if case let .passed(value, _) = self { return value } else { return nil } }
    public var problem: WybeProblem? { if case let .failed(problem, _) = self { return problem } else { return nil } }
}

public enum WybeSetupEvent: Sendable {
    case keySaved
    case keyRemoved
    case helpRequestChanged(recorded: Bool)
    case connectionFinished(generation: Int, Result<WybeConnectionReport, WybeFailure>, at: Date)
    case discoveryFinished(generation: Int, Result<WybeHelpTranscript, WybeFailure>, at: Date)
    case checkCancelled
}

/// The four Wybe readiness facts shown in Settings, kept strictly apart.
///
/// Invariants (tested):
/// - Saving or replacing a key verifies nothing: connection and discovery go back to "not checked".
/// - Any settings change bumps the generation and drops checks that were running; a result that
///   arrives for an older generation is ignored and never marks the new settings as working.
/// - Discovery needs a verified connection under the current settings.
/// - The live runner is ready only when all earlier facts hold AND a reviewed command mapping is
///   built into Relay. None is, so in this build it is never ready.
public struct WybeReadiness: Equatable, Sendable {
    public private(set) var keySaved: Bool
    public private(set) var helpRequestRecorded: Bool
    public private(set) var generation = 0
    public private(set) var connection: WybeCheckState<WybeConnectionReport> = .notChecked
    public private(set) var discovery: WybeCheckState<WybeHelpTranscript> = .notChecked
    /// Whether a reviewed mapping from the real help answer to commands exists in this build.
    public let reviewedMappingAvailable: Bool

    public init(keySaved: Bool, helpRequestRecorded: Bool, reviewedMappingAvailable: Bool) {
        self.keySaved = keySaved
        self.helpRequestRecorded = helpRequestRecorded
        self.reviewedMappingAvailable = reviewedMappingAvailable
    }

    /// Starts a connection check. Returns the generation to report back with, or nil if it can't start.
    public mutating func beginConnectionCheck() -> Int? {
        guard keySaved, !connection.isChecking, !discovery.isChecking else { return nil }
        connection = .checking(generation: generation)
        return generation
    }

    /// Starts protocol discovery. Returns the generation, or nil if it can't start now.
    public mutating func beginDiscovery() -> Int? {
        guard keySaved, helpRequestRecorded, connection.isPassed, !discovery.isChecking, !connection.isChecking else { return nil }
        discovery = .checking(generation: generation)
        return generation
    }

    /// Applies an event. Returns false when a result was ignored as stale.
    @discardableResult
    public mutating func apply(_ event: WybeSetupEvent) -> Bool {
        switch event {
        case .keySaved:
            keySaved = true
            settingsChanged(resetConnection: true)
        case .keyRemoved:
            keySaved = false
            settingsChanged(resetConnection: true)
        case let .helpRequestChanged(recorded):
            helpRequestRecorded = recorded
            settingsChanged(resetConnection: false)
        case .checkCancelled:
            if connection.isChecking { connection = .notChecked }
            if discovery.isChecking { discovery = .notChecked }
        case let .connectionFinished(token, result, at):
            guard token == generation, connection == .checking(generation: token) else { return false }
            switch result {
            case let .success(report): connection = .passed(report, at: at)
            case .failure(.cancelled): connection = .notChecked
            case let .failure(failure): connection = .failed(WybeProblem(failure), at: at)
            }
        case let .discoveryFinished(token, result, at):
            guard token == generation, discovery == .checking(generation: token) else { return false }
            switch result {
            case let .success(transcript): discovery = .passed(transcript, at: at)
            case .failure(.cancelled): discovery = .notChecked
            case let .failure(failure):
                discovery = .failed(WybeProblem(failure), at: at)
                // A refused key also invalidates the earlier connection result.
                if case .keyRefused = failure { connection = .failed(WybeProblem(failure), at: at) }
            }
        }
        return true
    }

    private mutating func settingsChanged(resetConnection: Bool) {
        generation += 1
        if resetConnection || connection.isChecking { connection = .notChecked }
        discovery = .notChecked
    }

    // MARK: Derived facts

    public var connectionVerified: Bool { keySaved && connection.isPassed }
    public var protocolDiscovered: Bool { connectionVerified && discovery.isPassed }

    public var liveRunnerReady: Bool { protocolDiscovered && reviewedMappingAvailable }

    /// Why the live runner cannot start, or nil when it can.
    public var liveRunnerBlocker: String? {
        if !keySaved { return "No team key saved." }
        if !connection.isPassed { return "Connection not verified." }
        if !discovery.isPassed { return "Protocol not discovered: the help request has not been answered." }
        if !reviewedMappingAvailable {
            return "No reviewed command mapping is built into Relay. The help answer must be turned into commands, observations and a policy by a developer before anything is sent."
        }
        return nil
    }

    public enum StageState: String, Sendable, Equatable { case done, inProgress, attention, notYet }

    public struct Stage: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let state: StageState
        public let detail: String
    }

    /// The four facts, in order, for Settings and relay-runner.
    public var stages: [Stage] {
        var result: [Stage] = []
        result.append(Stage(id: "key", title: "Key saved", state: keySaved ? .done : .notYet,
                            detail: keySaved ? "Stored in the Keychain. Saving does not test it." : "No team key saved."))
        let connectionStage: Stage
        switch connection {
        case .notChecked:
            connectionStage = Stage(id: "connection", title: "Connection verified", state: .notYet,
                                    detail: keySaved ? "Not checked with the current key." : "Needs a saved key.")
        case .checking:
            connectionStage = Stage(id: "connection", title: "Connection verified", state: .inProgress, detail: "Checking…")
        case let .passed(report, _):
            connectionStage = Stage(id: "connection", title: "Connection verified", state: .done, detail: report.detail)
        case let .failed(problem, _):
            connectionStage = Stage(id: "connection", title: "Connection verified", state: .attention, detail: problem.title)
        }
        result.append(connectionStage)
        let discoveryStage: Stage
        switch discovery {
        case .notChecked:
            let why = !helpRequestRecorded ? "The help request form is unresolved: record it as the service describes it."
                : connection.isPassed ? "Not discovered with the current settings." : "Needs a verified connection first."
            discoveryStage = Stage(id: "protocol", title: "Protocol discovered", state: .notYet, detail: why)
        case .checking:
            discoveryStage = Stage(id: "protocol", title: "Protocol discovered", state: .inProgress, detail: "Sending the help request…")
        case .passed:
            discoveryStage = Stage(id: "protocol", title: "Protocol discovered", state: .done,
                                   detail: "The service answered the help request. Its answer is shown verbatim; commands are not mapped automatically.")
        case let .failed(problem, _):
            discoveryStage = Stage(id: "protocol", title: "Protocol discovered", state: .attention, detail: problem.title)
        }
        result.append(discoveryStage)
        result.append(Stage(id: "runner", title: "Live runner ready", state: liveRunnerReady ? .done : .notYet,
                            detail: liveRunnerBlocker ?? "Ready. A live run still starts only when you start it."))
        return result
    }

    public var summary: String {
        if !keySaved { return "Wybe: no team key" }
        if liveRunnerReady { return "Wybe: live runner ready" }
        if protocolDiscovered { return "Wybe: protocol discovered, not mapped" }
        if connectionVerified { return "Wybe: connection verified" }
        return "Wybe: key saved, not verified"
    }
}
