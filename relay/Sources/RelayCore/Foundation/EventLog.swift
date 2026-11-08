import Foundation

/// Which part of Relay produced an event.
public enum LogChannel: String, Codable, Sendable, CaseIterable {
    case assistant, tasks, warehouse, wybe, speech, settings
}

/// What kind of fact the event records. The assistant UI is organised around
/// heard → understood → planned → attempted → result.
public enum LogKind: String, Codable, Sendable, CaseIterable {
    case heard, understood, planned, attempted, succeeded, failed, needsAttention, rejected, info
}

/// One immutable, already-redacted log entry.
public struct LogEvent: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let channel: LogChannel
    public let kind: LogKind
    /// Set for challenge events. `nil` means "not applicable" (e.g. warehouse training).
    public let mode: ExecutionMode?
    public let message: String
    public let details: [String: String]

    public init(id: UUID = UUID(), timestamp: Date = Date(), channel: LogChannel, kind: LogKind,
                mode: ExecutionMode? = nil, message: String, details: [String: String] = [:]) {
        self.id = id
        self.timestamp = timestamp
        self.channel = channel
        self.kind = kind
        self.mode = mode
        self.message = message
        self.details = details
    }

    func redacted(by redactor: Redactor) -> LogEvent {
        LogEvent(id: id, timestamp: timestamp, channel: channel, kind: kind, mode: mode,
                 message: redactor.redact(message), details: redactor.redact(details))
    }
}

/// Event logging interface. Implementations must redact before storing.
public protocol EventLogging: Sendable {
    func record(_ event: LogEvent)
    func entries() -> [LogEvent]
}

/// Append-only, thread-safe in-memory log. Entries are redacted on the way in, so nothing
/// downstream (UI, export) ever sees an unredacted credential.
public final class InMemoryEventLog: EventLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LogEvent] = []
    private let redactor: Redactor
    private let capacity: Int
    private var observers: [@Sendable (LogEvent) -> Void] = []

    public init(redactor: Redactor = .shared, capacity: Int = 5_000) {
        self.redactor = redactor
        self.capacity = capacity
    }

    public func record(_ event: LogEvent) {
        let clean = event.redacted(by: redactor)
        lock.lock()
        storage.append(clean)
        if storage.count > capacity { storage.removeFirst(storage.count - capacity) }
        let currentObservers = observers
        lock.unlock()
        for observer in currentObservers { observer(clean) }
    }

    public func entries() -> [LogEvent] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    /// Observer is called on the recording thread; UI code must hop to the main actor itself.
    public func addObserver(_ observer: @escaping @Sendable (LogEvent) -> Void) {
        lock.lock(); observers.append(observer); lock.unlock()
    }

    /// JSON Lines export. Entries are already redacted; the export is redacted again as a
    /// second line of defence in case a secret was registered after the event was recorded.
    public func exportJSONLines() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return entries().compactMap { event in
            guard let data = try? encoder.encode(event.redacted(by: redactor)) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n")
    }
}

public extension EventLogging {
    func record(_ channel: LogChannel, _ kind: LogKind, _ message: String,
                mode: ExecutionMode? = nil, details: [String: String] = [:]) {
        record(LogEvent(channel: channel, kind: kind, mode: mode, message: message, details: details))
    }
}
