import Foundation

/// Deterministic stand-in for the Night Shift environment.
///
/// SIMULATION ONLY. Everything here — the `sim.` command vocabulary, the hotel layout, task
/// values, penalties and faults — was invented for Relay's offline testing. It is NOT the Wybe
/// protocol and its scores say nothing about challenge performance.
public actor SimulatedNightShift: ChallengeAdapter {
    // MARK: Configuration

    public struct Faults: Sendable, Equatable {
        /// Refused before processing (not applied).
        public var transientRate: Double
        /// Applied, but the response is lost (caller times out).
        public var appliedThenLostRate: Double
        /// Hangs without applying (caller times out).
        public var hangNotAppliedRate: Double
        /// Responds with "slow down" (not applied).
        public var rateLimitRate: Double
        /// How long a hanging request stalls (wall-clock seconds).
        public var hangSeconds: Double

        public init(transientRate: Double = 0, appliedThenLostRate: Double = 0, hangNotAppliedRate: Double = 0,
                    rateLimitRate: Double = 0, hangSeconds: Double = 0.4) {
            self.transientRate = transientRate
            self.appliedThenLostRate = appliedThenLostRate
            self.hangNotAppliedRate = hangNotAppliedRate
            self.rateLimitRate = rateLimitRate
            self.hangSeconds = hangSeconds
        }

        public static let none = Faults()
        public static let typical = Faults(transientRate: 0.05, appliedThenLostRate: 0.03, hangNotAppliedRate: 0.02,
                                           rateLimitRate: 0.02)
        public static let harsh = Faults(transientRate: 0.15, appliedThenLostRate: 0.08, hangNotAppliedRate: 0.05,
                                         rateLimitRate: 0.05)
    }

    public enum Fault: Sendable, Equatable {
        case transient, appliedThenLost, hangNotApplied, rateLimited
    }

    public struct Configuration: Sendable {
        public var seed: UInt64
        public var shiftLength: Int
        public var taskCount: Int
        public var faults: Faults
        /// Forces a fault on a specific `perform` call (1-based). Overrides random faults.
        public var scriptedFaults: [Int: Fault]
        /// When false, `status(of:)` is unavailable and the runner must reconcile by observation.
        public var statusQueryAvailable: Bool

        public init(seed: UInt64 = 1, shiftLength: Int = 60, taskCount: Int = 12, faults: Faults = .none,
                    scriptedFaults: [Int: Fault] = [:], statusQueryAvailable: Bool = true) {
            self.seed = seed
            self.shiftLength = shiftLength
            self.taskCount = taskCount
            self.faults = faults
            self.scriptedFaults = scriptedFaults
            self.statusQueryAvailable = statusQueryAvailable
        }
    }

    // MARK: Vocabulary (simulation-only)

    public enum Command {
        public static let move = "sim.move"
        public static let pickup = "sim.pickup"
        public static let deliver = "sim.deliver"
        public static let inspect = "sim.inspect"
        public static let defer_ = "sim.defer"
        public static let all: [String] = [move, pickup, deliver, inspect, defer_]
    }

    public enum Kind {
        public static let towels = "towels"
        public static let lostItem = "lost_item"
        public static let roomCheck = "room_check"
    }

    public static let frontDesk = "front_desk"
    public static let linen = "linen_room"
    public static let doNotDisturb = "do_not_disturb"
    static let rooms: [String] = (101...112).map(String.init)
    static let lostItems = ["wallet", "phone", "umbrella", "scarf", "charger", "glasses", "keycard", "book"]

    public static let capabilities: [ActionSpec] = [
        ActionSpec(name: Command.move, summary: "Move the robot to a location (front_desk, linen_room or a room number).",
                   arguments: ["to"], consequential: false,
                   preconditions: [.argumentPresent("to"), .robotNotAt(locationArgument: "to")]),
        ActionSpec(name: Command.pickup, summary: "Pick up the item needed for a task at its pickup location.",
                   arguments: ["task"], consequential: true,
                   preconditions: [.taskOpen(taskArgument: "task"), .robotAtTaskPickup(taskArgument: "task")]),
        ActionSpec(name: Command.deliver, summary: "Deliver the task's item at its destination, completing the task.",
                   arguments: ["task"], consequential: true,
                   preconditions: [.taskOpen(taskArgument: "task"), .robotAtTaskDestination(taskArgument: "task"),
                                   .carryingTaskItem(taskArgument: "task")]),
        ActionSpec(name: Command.inspect, summary: "Inspect a room for a room-check task.",
                   arguments: ["task"], consequential: true,
                   preconditions: [.taskOpen(taskArgument: "task"), .robotAtTaskDestination(taskArgument: "task")]),
        ActionSpec(name: Command.defer_, summary: "Flag a task as not appropriate to do now (reported to staff).",
                   arguments: ["task"], consequential: true,
                   preconditions: [.taskOpen(taskArgument: "task")]),
    ]

    // MARK: State

    public nonisolated let mode: ExecutionMode = .simulation
    public nonisolated let name: String
    public nonisolated let supportsStatusQuery: Bool

    private let config: Configuration
    private var faultRNG: SeededGenerator
    private var time = 0
    private var location = SimulatedNightShift.frontDesk
    private var carrying: [String] = []
    private var tasks: [ChallengeTask]
    private var flags: [String: [String]]
    private var values: [String: Int]
    private var score = 0
    private var performCalls = 0
    private var applied: [String: ActionOutcome] = [:]
    /// Count of state-changing applications per task (for duplicate-action tests).
    public private(set) var completionAttempts: [String: Int] = [:]
    public private(set) var ledger: [(time: Int, delta: Int, reason: String)] = []
    /// Every request that reached the simulator, in order (for tests and transparency).
    public private(set) var received: [ActionRequest] = []

    public init(configuration: Configuration = Configuration()) {
        config = configuration
        name = "Relay simulator (seed \(configuration.seed))"
        supportsStatusQuery = configuration.statusQueryAvailable
        faultRNG = SeededGenerator(seed: configuration.seed ^ 0xFA17)
        var rng = SeededGenerator(seed: configuration.seed)
        var generated: [ChallengeTask] = []
        var flags: [String: [String]] = [:]
        var values: [String: Int] = [:]
        var items = Self.lostItems
        for index in 1...max(1, configuration.taskCount) {
            let id = "T\(index)"
            let room = Self.rooms[rng.int(in: 0...(Self.rooms.count - 1))]
            let roll = rng.unit()
            let urgent = rng.unit() < 0.3
            let deadline = urgent ? rng.int(in: 12...30) : configuration.shiftLength
            let priority = urgent ? "urgent" : "normal"
            if roll < 0.4 {
                generated.append(ChallengeTask(id: id, kind: Kind.towels, summary: "Bring fresh towels to room \(room)",
                                               item: Kind.towels, pickupLocation: Self.linen, destination: room,
                                               deadline: deadline, priority: priority, status: .open))
                values[id] = urgent ? 14 : 10
            } else if roll < 0.7, !items.isEmpty {
                let item = items.remove(at: rng.int(in: 0...(items.count - 1)))
                generated.append(ChallengeTask(id: id, kind: Kind.lostItem,
                                               summary: "Return the \(item) found in room \(room) to the front desk",
                                               item: item, pickupLocation: room, destination: Self.frontDesk,
                                               deadline: deadline, priority: priority, status: .open))
                values[id] = urgent ? 20 : 15
            } else {
                generated.append(ChallengeTask(id: id, kind: Kind.roomCheck, summary: "Check room \(room)",
                                               item: nil, pickupLocation: nil, destination: room,
                                               deadline: deadline, priority: priority, status: .open))
                values[id] = urgent ? 11 : 8
                if rng.unit() < 0.35 { flags[room, default: []].append(Self.doNotDisturb) }
            }
        }
        tasks = generated
        self.flags = flags
        self.values = values
    }

    // MARK: ChallengeAdapter

    public func discoverCapabilities() async throws -> [ActionSpec] { Self.capabilities }

    public func observe() async throws -> Observation {
        Observation(time: time, shiftEndsAt: config.shiftLength, robotLocation: location, carrying: carrying,
                    tasks: tasks, locationFlags: flags, isShiftOver: time >= config.shiftLength)
    }

    public func perform(_ request: ActionRequest) async throws -> ActionOutcome {
        performCalls += 1
        received.append(request)
        switch nextFault() {
        case .transient?:
            throw ChallengeError.transient("simulated: service busy, request not processed")
        case .rateLimited?:
            throw ChallengeError.rateLimited(retryAfter: 0.05)
        case .hangNotApplied?:
            try await Task.sleep(nanoseconds: UInt64(config.faults.hangSeconds * 1_000_000_000))
            throw ChallengeError.ambiguous("simulated: no response")
        case .appliedThenLost?:
            let outcome = apply(request)
            applied[request.idempotencyKey] = outcome
            try await Task.sleep(nanoseconds: UInt64(config.faults.hangSeconds * 1_000_000_000))
            throw ChallengeError.ambiguous("simulated: response lost")
        case nil:
            let outcome = apply(request)
            applied[request.idempotencyKey] = outcome
            return outcome
        }
    }

    public func status(of idempotencyKey: String) async throws -> ActionStatusAnswer {
        guard config.statusQueryAvailable else { return .unknown }
        if let outcome = applied[idempotencyKey] { return .applied(outcome) }
        return .notApplied
    }

    public func scoreReport() async -> LabeledScore? {
        LabeledScore(mode: .simulation, value: Double(score), source: name)
    }

    public var performCallCount: Int { performCalls }

    // MARK: Simulation rules

    private func nextFault() -> Fault? {
        if let scripted = config.scriptedFaults[performCalls] { return scripted }
        guard config.scriptedFaults.isEmpty else { return nil }
        let f = config.faults
        let roll = faultRNG.unit()
        var threshold = f.transientRate
        if roll < threshold { return .transient }
        threshold += f.rateLimitRate
        if roll < threshold { return .rateLimited }
        threshold += f.hangNotAppliedRate
        if roll < threshold { return .hangNotApplied }
        threshold += f.appliedThenLostRate
        if roll < threshold { return .appliedThenLost }
        return nil
    }

    private func position(_ place: String) -> Int? {
        if place == Self.frontDesk { return 0 }
        if place == Self.linen { return 1 }
        if let index = Self.rooms.firstIndex(of: place) { return index + 2 }
        return nil
    }

    /// Travel time in simulated minutes between two places.
    public static func travelTime(from: String, to: String) -> Int {
        func pos(_ p: String) -> Int {
            if p == frontDesk { return 0 }
            if p == linen { return 1 }
            return (rooms.firstIndex(of: p) ?? 0) + 2
        }
        return max(1, abs(pos(from) - pos(to)))
    }

    private func adjust(_ delta: Int, _ reason: String) {
        score += delta
        ledger.append((time, delta, reason))
    }

    private func refuse(_ message: String, penalty: Int) -> ActionOutcome {
        if penalty != 0 { adjust(-penalty, message) }
        time += 1
        return ActionOutcome(accepted: false, message: message)
    }

    private func apply(_ request: ActionRequest) -> ActionOutcome {
        guard time < config.shiftLength else { return ActionOutcome(accepted: false, message: "Shift is over") }
        guard Self.Command.all.contains(request.name) else {
            return refuse("Unknown command \(request.name)", penalty: 3)
        }
        if request.name == Command.move {
            guard let target = request.arguments["to"], position(target) != nil else {
                return refuse("Unknown location", penalty: 2)
            }
            time += Self.travelTime(from: location, to: target)
            location = target
            return ActionOutcome(accepted: true, message: "Moved to \(target)")
        }
        guard let taskID = request.arguments["task"], let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            return refuse("Unknown task", penalty: 2)
        }
        let task = tasks[index]
        if request.name != Command.pickup { completionAttempts[taskID, default: 0] += 1 }
        guard task.status == .open else {
            return refuse("Task \(taskID) is already \(task.status.rawValue)", penalty: 5)
        }
        let onTime = time <= (task.deadline ?? config.shiftLength)
        switch request.name {
        case Command.pickup:
            guard let pickup = task.pickupLocation, let item = task.item else { return refuse("Nothing to pick up", penalty: 2) }
            guard location == pickup else { return refuse("Not at \(pickup)", penalty: 2) }
            if task.kind == Kind.lostItem && carrying.contains(item) { return refuse("Already carrying \(item)", penalty: 2) }
            carrying.append(item)
            time += 1
            return ActionOutcome(accepted: true, message: "Picked up \(item)")
        case Command.deliver:
            guard task.kind != Kind.roomCheck, let item = task.item else { return refuse("Nothing to deliver", penalty: 2) }
            guard location == task.destination else { return refuse("Not at \(task.destination)", penalty: 2) }
            guard let carried = carrying.firstIndex(of: item) else { return refuse("Not carrying \(item)", penalty: 2) }
            carrying.remove(at: carried)
            tasks[index].status = .completed
            time += 1
            adjust(onTime ? values[taskID] ?? 0 : 0, onTime ? "\(taskID) delivered" : "\(taskID) delivered late")
            return ActionOutcome(accepted: true, message: "Delivered \(item) for \(taskID)" + (onTime ? "" : " (late)"))
        case Command.inspect:
            guard task.kind == Kind.roomCheck else { return refuse("Not a room check", penalty: 2) }
            guard location == task.destination else { return refuse("Not at \(task.destination)", penalty: 2) }
            time += 3
            tasks[index].status = .completed
            if flags[task.destination]?.contains(Self.doNotDisturb) == true {
                adjust(-12, "\(taskID) inspected a do-not-disturb room")
                return ActionOutcome(accepted: true, message: "Entered room \(task.destination) despite do-not-disturb")
            }
            adjust(onTime ? values[taskID] ?? 0 : 0, onTime ? "\(taskID) checked" : "\(taskID) checked late")
            return ActionOutcome(accepted: true, message: "Checked room \(task.destination)")
        case Command.defer_:
            tasks[index].status = .deferred
            time += 1
            if flags[task.destination]?.contains(Self.doNotDisturb) == true, task.kind == Kind.roomCheck {
                adjust(2, "\(taskID) correctly deferred (do-not-disturb)")
            } else {
                adjust(-1, "\(taskID) deferred without reason")
            }
            return ActionOutcome(accepted: true, message: "Deferred \(taskID)")
        default:
            return refuse("Unknown command \(request.name)", penalty: 3)
        }
    }
}
