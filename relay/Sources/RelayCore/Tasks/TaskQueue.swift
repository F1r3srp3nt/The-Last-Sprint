import Foundation

/// Lifecycle of a visible Relay task.
public enum TaskState: String, Codable, Sendable, CaseIterable {
    case queued
    case awaitingApproval
    case inProgress
    /// Stopped and needs a human to look at it (ambiguous result, escalation, missing info).
    case needsAttention
    case succeeded
    case failed
    case cancelled

    public var isTerminal: Bool { self == .succeeded || self == .failed || self == .cancelled }

    /// Allowed next states. Terminal states have none: a finished task is never silently revived.
    public var allowedNext: Set<TaskState> {
        switch self {
        case .queued: return [.awaitingApproval, .inProgress, .needsAttention, .cancelled]
        case .awaitingApproval: return [.inProgress, .cancelled, .needsAttention]
        case .inProgress: return [.succeeded, .failed, .needsAttention, .cancelled]
        case .needsAttention: return [.queued, .inProgress, .failed, .cancelled, .succeeded]
        case .succeeded, .failed, .cancelled: return []
        }
    }

    public var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .awaitingApproval: return "Awaiting approval"
        case .inProgress: return "In progress"
        case .needsAttention: return "Needs attention"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

public enum TaskSource: String, Codable, Sendable, CaseIterable {
    case assistant, warehouse, wybe
}

public struct TaskTransition: Codable, Sendable, Equatable {
    public let from: TaskState
    public let to: TaskState
    public let at: Date
    public let note: String
}

public struct RelayTask: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var title: String
    public var detail: String
    public let source: TaskSource
    public private(set) var state: TaskState
    public private(set) var history: [TaskTransition]
    public let createdAt: Date

    public init(id: UUID = UUID(), title: String, detail: String = "", source: TaskSource,
                state: TaskState = .queued, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.detail = detail
        self.source = source
        self.state = state
        self.history = []
        self.createdAt = createdAt
    }

    mutating func apply(_ next: TaskState, note: String, at date: Date) throws {
        guard state.allowedNext.contains(next) else {
            throw TaskQueueError.invalidTransition(from: state, to: next)
        }
        history.append(TaskTransition(from: state, to: next, at: date, note: note))
        state = next
    }
}

public enum TaskQueueError: Error, Equatable, CustomStringConvertible {
    case invalidTransition(from: TaskState, to: TaskState)
    case unknownTask(UUID)
    case emptyTitle

    public var description: String {
        switch self {
        case let .invalidTransition(from, to): return "Cannot move a task from \(from.displayName) to \(to.displayName)"
        case let .unknownTask(id): return "No task with id \(id)"
        case .emptyTitle: return "A task needs a title"
        }
    }
}

/// Ordered task list with validated transitions. Every change is logged.
public struct TaskQueue: Sendable {
    public private(set) var tasks: [RelayTask] = []
    private let log: EventLogging?

    public init(log: EventLogging? = nil) { self.log = log }

    @discardableResult
    public mutating func add(title: String, detail: String = "", source: TaskSource,
                             initialState: TaskState = .queued) throws -> RelayTask {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw TaskQueueError.emptyTitle }
        let task = RelayTask(title: clean, detail: detail, source: source, state: initialState)
        tasks.append(task)
        log?.record(.tasks, .info, "Task added: \(clean)",
                    details: ["state": initialState.rawValue, "source": source.rawValue])
        return task
    }

    public mutating func transition(_ id: UUID, to next: TaskState, note: String = "", at date: Date = Date()) throws {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw TaskQueueError.unknownTask(id) }
        let previous = tasks[index].state
        do {
            try tasks[index].apply(next, note: note, at: date)
        } catch {
            log?.record(.tasks, .rejected, "Rejected task change for \(tasks[index].title): \(error)")
            throw error
        }
        let kind: LogKind
        switch next {
        case .succeeded: kind = .succeeded
        case .failed: kind = .failed
        case .needsAttention: kind = .needsAttention
        default: kind = .info
        }
        log?.record(.tasks, kind, "\(tasks[index].title): \(previous.displayName) → \(next.displayName)",
                    details: note.isEmpty ? [:] : ["note": note])
    }

    public func task(_ id: UUID) -> RelayTask? { tasks.first { $0.id == id } }

    public var open: [RelayTask] { tasks.filter { !$0.state.isTerminal } }
    public var attentionCount: Int { tasks.filter { $0.state == .needsAttention || $0.state == .awaitingApproval }.count }
}
