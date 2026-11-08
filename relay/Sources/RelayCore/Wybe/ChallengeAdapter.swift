import Foundation

// Generic contract between the autonomous runner and a Night Shift environment.
//
// IMPORTANT: these types describe what Relay's runner needs, not the Wybe protocol. The real
// Wybe command names, endpoints, payloads and scoring are unknown until the official contract
// is obtained (see docs/WYBE.md). The simulator implements this contract with its own,
// clearly prefixed "sim." vocabulary.

/// A condition the runner checks against the latest observation before sending an action.
public enum Precondition: Codable, Sendable, Equatable {
    /// The named argument must be present and non-empty.
    case argumentPresent(String)
    /// The task named by the argument must be open.
    case taskOpen(taskArgument: String)
    /// The robot must be at the task's pickup location.
    case robotAtTaskPickup(taskArgument: String)
    /// The robot must be at the task's destination.
    case robotAtTaskDestination(taskArgument: String)
    /// The robot must be carrying the task's item.
    case carryingTaskItem(taskArgument: String)
    /// The robot must not already be at the destination given by the argument.
    case robotNotAt(locationArgument: String)
}

/// A command the environment reports it understands.
public struct ActionSpec: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let summary: String
    public let arguments: [String]
    /// True when repeating the action could change the outcome (score, world state) a second time.
    /// Consequential actions are never blindly repeated after an ambiguous failure.
    public let consequential: Bool
    public let preconditions: [Precondition]

    public init(name: String, summary: String, arguments: [String], consequential: Bool, preconditions: [Precondition]) {
        self.name = name
        self.summary = summary
        self.arguments = arguments
        self.consequential = consequential
        self.preconditions = preconditions
    }
}

public enum ChallengeTaskStatus: String, Codable, Sendable {
    case open, completed, deferred
}

public struct ChallengeTask: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    /// Environment-defined kind, e.g. "towels". Not interpreted by the runner engine.
    public let kind: String
    public let summary: String
    public let item: String?
    public let pickupLocation: String?
    public let destination: String
    /// Time (environment minutes) by which the task should be done, if any.
    public let deadline: Int?
    public let priority: String?
    public var status: ChallengeTaskStatus

    public init(id: String, kind: String, summary: String, item: String?, pickupLocation: String?,
                destination: String, deadline: Int?, priority: String?, status: ChallengeTaskStatus) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.item = item
        self.pickupLocation = pickupLocation
        self.destination = destination
        self.deadline = deadline
        self.priority = priority
        self.status = status
    }
}

public struct Observation: Codable, Sendable, Equatable {
    public let time: Int
    public let shiftEndsAt: Int?
    public let robotLocation: String?
    public let carrying: [String]
    public let tasks: [ChallengeTask]
    /// Location → flags, e.g. "105": ["do_not_disturb"].
    public let locationFlags: [String: [String]]
    public let isShiftOver: Bool

    public init(time: Int, shiftEndsAt: Int?, robotLocation: String?, carrying: [String], tasks: [ChallengeTask],
                locationFlags: [String: [String]], isShiftOver: Bool) {
        self.time = time
        self.shiftEndsAt = shiftEndsAt
        self.robotLocation = robotLocation
        self.carrying = carrying
        self.tasks = tasks
        self.locationFlags = locationFlags
        self.isShiftOver = isShiftOver
    }

    public func task(_ id: String) -> ChallengeTask? { tasks.first { $0.id == id } }
    public var openTasks: [ChallengeTask] { tasks.filter { $0.status == .open } }
}

public struct ActionRequest: Codable, Sendable, Equatable {
    public let name: String
    public let arguments: [String: String]
    /// Unique per logical action. Reused only when re-sending an action that is known NOT to
    /// have been applied; used to ask the environment about the outcome of an ambiguous call.
    public let idempotencyKey: String

    public init(name: String, arguments: [String: String], idempotencyKey: String = UUID().uuidString) {
        self.name = name
        self.arguments = arguments
        self.idempotencyKey = idempotencyKey
    }

    public var displayText: String {
        let args = arguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return args.isEmpty ? name : "\(name) \(args)"
    }
}

public struct ActionOutcome: Codable, Sendable, Equatable {
    /// False when the environment received the action and refused it.
    public let accepted: Bool
    public let message: String

    public init(accepted: Bool, message: String) {
        self.accepted = accepted
        self.message = message
    }
}

public enum ActionStatusAnswer: Sendable, Equatable {
    case applied(ActionOutcome)
    case notApplied
    case unknown
}

public enum ChallengeError: Error, Equatable, CustomStringConvertible {
    /// The real protocol or credentials are not available. Nothing was sent.
    case contractUnavailable(String)
    /// Definitely not applied (e.g. refused before processing). Safe to retry.
    case transient(String)
    /// The service asked us to slow down. Not applied.
    case rateLimited(retryAfter: Double?)
    /// The request may or may not have been applied (lost response, connection dropped after send).
    case ambiguous(String)
    /// Permanently refused. Do not retry.
    case rejected(String)

    public var description: String {
        switch self {
        case let .contractUnavailable(m): return "Contract unavailable: \(m)"
        case let .transient(m): return "Transient failure (not applied): \(m)"
        case let .rateLimited(after): return "Rate limited" + (after.map { " (retry after \($0)s)" } ?? "")
        case let .ambiguous(m): return "Ambiguous outcome: \(m)"
        case let .rejected(m): return "Rejected: \(m)"
        }
    }
}

/// An environment the autonomous runner can act in.
public protocol ChallengeAdapter: Sendable {
    var mode: ExecutionMode { get }
    var name: String { get }
    /// Whether `status(of:)` can authoritatively answer "was this action applied?".
    var supportsStatusQuery: Bool { get }

    func discoverCapabilities() async throws -> [ActionSpec]
    func observe() async throws -> Observation
    func perform(_ request: ActionRequest) async throws -> ActionOutcome
    func status(of idempotencyKey: String) async throws -> ActionStatusAnswer
    /// Score as reported by the environment, labelled with its mode. `nil` when unknown.
    func scoreReport() async -> LabeledScore?
}

/// Evaluates preconditions against an observation. Pure and shared by policies and the runner.
public enum PreconditionChecker {
    /// Returns a human-readable description of the first unmet precondition, or `nil`.
    public static func firstUnmet(_ spec: ActionSpec, _ request: ActionRequest, _ observation: Observation) -> String? {
        func task(_ argument: String) -> ChallengeTask? {
            request.arguments[argument].flatMap { observation.task($0) }
        }
        for condition in spec.preconditions {
            switch condition {
            case let .argumentPresent(name):
                if (request.arguments[name] ?? "").isEmpty { return "missing argument '\(name)'" }
            case let .taskOpen(argument):
                guard let t = task(argument) else { return "unknown task '\(request.arguments[argument] ?? "")'" }
                if t.status != .open { return "task \(t.id) is \(t.status.rawValue)" }
            case let .robotAtTaskPickup(argument):
                guard let t = task(argument), let pickup = t.pickupLocation else { return "task has no pickup location" }
                if observation.robotLocation != pickup { return "robot is not at \(pickup)" }
            case let .robotAtTaskDestination(argument):
                guard let t = task(argument) else { return "unknown task" }
                if observation.robotLocation != t.destination { return "robot is not at \(t.destination)" }
            case let .carryingTaskItem(argument):
                guard let t = task(argument), let item = t.item else { return "task has no item" }
                if !observation.carrying.contains(item) { return "robot is not carrying \(item)" }
            case let .robotNotAt(argument):
                if let target = request.arguments[argument], observation.robotLocation == target {
                    return "robot is already at \(target)"
                }
            }
        }
        return nil
    }
}
