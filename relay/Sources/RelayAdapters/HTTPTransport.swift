import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP seam so adapters can be tested without a network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public enum TransportError: Error, Equatable, CustomStringConvertible {
    case notHTTP
    case network(String)

    public var description: String {
        switch self {
        case .notHTTP: return "Response was not HTTP"
        case let .network(message): return "Network error: \(message)"
        }
    }
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse?)
        do {
            #if canImport(FoundationNetworking)
            (data, response) = try await withCheckedThrowingContinuation { continuation in
                session.dataTask(with: request) { data, response, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: (data ?? Data(), response)) }
                }.resume()
            }
            #else
            (data, response) = try await session.data(for: request)
            #endif
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TransportError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw TransportError.notHTTP }
        return (data, http)
    }
}

/// Testing aid: waits before forwarding each request to the real transport. Used by Settings ›
/// Advanced so that "change settings while a request is pending" can be tested by hand. It only
/// delays real requests; it never fabricates a response. Cancelling during the wait sends nothing.
public struct DelayedTransport: HTTPTransport {
    public let base: HTTPTransport
    public let seconds: Double

    public init(base: HTTPTransport, seconds: Double) {
        self.base = base
        self.seconds = max(0, seconds)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return try await base.send(request)
    }
}
