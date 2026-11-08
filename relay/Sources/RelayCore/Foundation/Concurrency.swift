import Foundation

// MARK: - Clock

/// Time source for rate limiting and backoff. Injected so tests run instantly and deterministically.
public protocol RelayClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
}

public struct SystemClock: RelayClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: Double) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Virtual clock: `sleep` advances time immediately and records the requested durations.
public final class ManualClock: RelayClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var recorded: [Double] = []

    public init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    public func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }

    public func sleep(seconds: Double) async throws {
        try Task.checkCancellation()
        record(seconds)
    }

    private func record(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(seconds)
        if seconds > 0 { current = current.addingTimeInterval(seconds) }
    }

    public func advance(by seconds: Double) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }

    public var sleeps: [Double] { lock.lock(); defer { lock.unlock() }; return recorded }
}

// MARK: - Timeout

public struct RelayTimeoutError: Error, Equatable, CustomStringConvertible {
    public let seconds: Double
    public var description: String { "Timed out after \(seconds)s" }
}

/// Runs `operation`, throwing `RelayTimeoutError` if it does not finish within `seconds`
/// (wall-clock). The operation is cancelled on timeout; it must honour cancellation.
public func withTimeout<T: Sendable>(seconds: Double,
                                     _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw RelayTimeoutError(seconds: seconds)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}

// MARK: - Retry policy

/// Bounded exponential backoff. Deterministic (no jitter) so behaviour is reproducible.
public struct RetryPolicy: Codable, Sendable, Equatable {
    /// Total attempts including the first one. Always ≥ 1.
    public let maxAttempts: Int
    public let baseDelay: Double
    public let multiplier: Double
    public let maxDelay: Double

    public init(maxAttempts: Int = 3, baseDelay: Double = 0.5, multiplier: Double = 2, maxDelay: Double = 8) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = max(0, baseDelay)
        self.multiplier = max(1, multiplier)
        self.maxDelay = max(0, maxDelay)
    }

    /// Delay before attempt number `attempt` (1-based). Attempt 1 has no delay.
    public func delay(beforeAttempt attempt: Int) -> Double {
        guard attempt > 1 else { return 0 }
        let raw = baseDelay * pow(multiplier, Double(attempt - 2))
        return min(maxDelay, raw)
    }

    public static let none = RetryPolicy(maxAttempts: 1)
}

// MARK: - Rate limiter

/// Enforces a minimum interval between outbound requests, plus an optional server-requested
/// pause (e.g. after HTTP 429 / Retry-After).
public actor RateLimiter {
    private let minInterval: Double
    private let clock: RelayClock
    private var nextAllowed: Date?

    public init(minInterval: Double, clock: RelayClock) {
        self.minInterval = max(0, minInterval)
        self.clock = clock
    }

    /// Waits until a request may be sent, then reserves the slot.
    public func acquire() async throws {
        let now = clock.now()
        if let next = nextAllowed, next > now {
            let wait = next.timeIntervalSince(now)
            nextAllowed = next.addingTimeInterval(minInterval)
            try await clock.sleep(seconds: wait)
        } else {
            nextAllowed = now.addingTimeInterval(minInterval)
        }
    }

    /// Pushes the next allowed request out by at least `seconds` from now.
    public func pause(seconds: Double) {
        let candidate = clock.now().addingTimeInterval(max(0, seconds))
        if let next = nextAllowed, next > candidate { return }
        nextAllowed = candidate
    }
}

// MARK: - Stop control

/// A latch that, once tripped, stays tripped. Checked before every outbound action.
public final class StopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: String?

    public init() {}

    public func stop(reason: String = "Stop requested") {
        lock.lock(); if self.reason == nil { self.reason = reason }; lock.unlock()
    }

    public var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return reason != nil }
    public var stopReason: String? { lock.lock(); defer { lock.unlock() }; return reason }
}

// MARK: - Deterministic random numbers

/// SplitMix64: tiny, fast, fully deterministic across platforms (unlike SystemRandomNumberGenerator).
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    public mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}
