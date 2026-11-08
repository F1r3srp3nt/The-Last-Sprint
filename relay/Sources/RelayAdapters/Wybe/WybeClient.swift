import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RelayCore

/// Bounds for every request to the Wybe endpoint. The service's own rate limits are unknown, so
/// the defaults are deliberately conservative.
public struct WybeLimits: Sendable, Equatable {
    public var timeout: Double
    public var maxResponseBytes: Int
    /// Minimum seconds between any two requests from one client.
    public var minRequestInterval: Double
    /// Pause after HTTP 429 when the service gives no Retry-After.
    public var defaultRateLimitPause: Double

    public init(timeout: Double = 10, maxResponseBytes: Int = 256 * 1024, minRequestInterval: Double = 1.0,
                defaultRateLimitPause: Double = 10) {
        self.timeout = max(0.01, timeout)
        self.maxResponseBytes = max(1, maxResponseBytes)
        self.minRequestInterval = max(0, minRequestInterval)
        self.defaultRateLimitPause = max(0, defaultRateLimitPause)
    }
}

/// A response that matched the observed envelope.
public struct WybeResponse: Equatable, Sendable {
    public let httpStatus: Int
    public let envelope: WybeEnvelope
    /// The `result` text, redacted.
    public let text: String
}

/// HTTP client for the organiser endpoint.
///
/// - Sends the team key only as `Authorization: Bearer <key>` (from the key card), never in a URL
///   or body, and registers it with the redactor before anything is logged.
/// - Every request is rate limited, time bounded and size bounded, and honours cancellation.
/// - Requests can only go to the configured endpoint host; relative paths only.
/// - The client never retries by itself. Callers decide, based on whether the request was
///   read-only (see `LiveNightShiftAdapter`).
public final class WybeClient: Sendable {
    public static let officialEndpoint = URL(string: WybeIntegration.endpoint)!

    public let endpoint: URL
    public let limits: WybeLimits
    private let transport: HTTPTransport
    private let redactor: Redactor
    private let teamKey: @Sendable () -> String?
    private let limiter: RateLimiter

    public init(endpoint: URL = WybeClient.officialEndpoint, transport: HTTPTransport = URLSessionTransport(),
                limits: WybeLimits = WybeLimits(), clock: RelayClock = SystemClock(), redactor: Redactor = .shared,
                teamKey: @escaping @Sendable () -> String?) {
        self.endpoint = endpoint
        self.transport = transport
        self.limits = limits
        self.redactor = redactor
        self.teamKey = teamKey
        limiter = RateLimiter(minInterval: limits.minRequestInterval, clock: clock)
    }

    // MARK: Read-only checks

    /// Authenticated GET / — the only request whose form has been observed. It never starts a shift.
    public func checkConnection() async -> Result<WybeConnectionReport, WybeFailure> {
        do {
            let response = try await send(.root)
            return .success(WybeConnectionReport(httpStatus: response.httpStatus, resultText: String(response.text.prefix(2_000))))
        } catch let failure as WybeFailure {
            return .failure(failure)
        } catch {
            return .failure(.network(redactor.redact(String(describing: error))))
        }
    }

    /// Sends the help request the team recorded, once. Never retried automatically.
    public func discover(with help: WybeHelpRequest) async -> Result<WybeHelpTranscript, WybeFailure> {
        if let problem = help.problem() { return .failure(.invalidRequest(problem)) }
        guard let request = help.request else { return .failure(.invalidRequest("help request is incomplete")) }
        do {
            let response = try await send(request)
            return .success(WybeHelpTranscript(request: redactor.redact(request.summary), httpStatus: response.httpStatus,
                                               answer: String(response.text.prefix(20_000))))
        } catch let failure as WybeFailure {
            return .failure(failure)
        } catch {
            return .failure(.network(redactor.redact(String(describing: error))))
        }
    }

    // MARK: Generic request

    /// Sends one request and classifies the answer. Throws only `WybeFailure`.
    public func send(_ request: WybeRequest) async throws -> WybeResponse {
        let urlRequest = try build(request)
        do { try await limiter.acquire() } catch { throw WybeFailure.cancelled }
        if Task.isCancelled { throw WybeFailure.cancelled }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await withTimeout(seconds: limits.timeout) { [transport] in
                try await transport.send(urlRequest)
            }
        } catch is RelayTimeoutError {
            throw WybeFailure.timedOut(seconds: limits.timeout)
        } catch is CancellationError {
            throw WybeFailure.cancelled
        } catch {
            if Task.isCancelled { throw WybeFailure.cancelled }
            throw WybeFailure.network(redactor.redact(String(describing: error)))
        }
        return try await classify(status: response.statusCode, body: data, headers: response)
    }

    func build(_ request: WybeRequest) throws -> URLRequest {
        guard let key = teamKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw WybeFailure.missingKey
        }
        redactor.register(secret: key)
        guard request.path.hasPrefix("/"), !request.path.hasPrefix("//"), !request.path.contains("?"),
              !request.path.contains("#"), !request.path.contains("..") else {
            throw WybeFailure.invalidRequest("path must be relative to \(endpoint.absoluteString)")
        }
        guard let url = URL(string: String(request.path.dropFirst()), relativeTo: endpoint)?.absoluteURL,
              url.scheme == "https", url.host == endpoint.host else {
            throw WybeFailure.invalidRequest("requests may only go to \(endpoint.host ?? "the endpoint")")
        }
        if let body = request.body, String(decoding: body, as: UTF8.self).contains(key) {
            throw WybeFailure.invalidRequest("the body contains the team key; it is sent only in the Authorization header")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = limits.timeout
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return urlRequest
    }

    private func classify(status: Int, body: Data, headers: HTTPURLResponse) async throws -> WybeResponse {
        if body.count > limits.maxResponseBytes { throw WybeFailure.responseTooLarge(limit: limits.maxResponseBytes) }
        let envelope = WybeEnvelope(data: body)
        let detail = envelope.map { redactor.redact(String($0.text.prefix(300))) }
            ?? Self.excerpt(body).map(redactor.redact)
        switch status {
        case 200..<300:
            guard let envelope else {
                let why = WybeJSON.parse(body) == nil ? "not JSON" : "JSON without a boolean “ok”"
                throw WybeFailure.malformed(why + (Self.excerpt(body).map { ": " + redactor.redact($0) } ?? ""))
            }
            guard envelope.ok else { throw WybeFailure.notOK(detail: detail ?? "") }
            return WybeResponse(httpStatus: status, envelope: envelope, text: redactor.redact(envelope.text))
        case 401:
            throw WybeFailure.keyRefused(detail: detail)
        case 403:
            throw WybeFailure.forbidden(detail: detail)
        case 429:
            let after = headers.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            await limiter.pause(seconds: min(300, after ?? limits.defaultRateLimitPause))
            throw WybeFailure.rateLimited(retryAfter: after, detail: detail)
        case 500..<600:
            throw WybeFailure.serverError(status: status, detail: detail)
        default:
            throw WybeFailure.unexpectedStatus(status: status, detail: detail)
        }
    }

    private static func excerpt(_ body: Data) -> String? {
        guard !body.isEmpty else { return nil }
        let text = String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
