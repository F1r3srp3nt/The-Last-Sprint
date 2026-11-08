import Foundation

/// What the policy wants to do next.
public enum PolicyDecision: Sendable, Equatable {
    case act(name: String, arguments: [String: String], taskID: String?, rationale: String)
    case finish(reason: String)
}

public enum ReconcileVerdict: Sendable, Equatable {
    case applied
    case notApplied
    case unknown
}

/// Decides actions for a specific environment vocabulary.
public protocol ShiftPolicy: Sendable {
    /// - Parameters:
    ///   - usable: discovered capabilities that are also allowed by the runner configuration.
    ///   - excludedTasks: tasks the runner has set aside (ambiguous outcome, repeated failure).
    func decide(observation: Observation, usable: [String: ActionSpec], excludedTasks: Set<String>) -> PolicyDecision

    /// After an ambiguous failure, decide from observations whether the action took effect.
    /// Must return `.unknown` rather than guess.
    func reconcile(_ request: ActionRequest, before: Observation, after: Observation) -> ReconcileVerdict
}

/// Value-per-minute prioritisation for the simulator's `sim.` vocabulary.
///
/// Uses only what the observation shows (kind, priority, deadline, flags) plus its own value
/// estimates; it never sees the simulator's hidden point values.
public struct SimulatedShiftPolicy: ShiftPolicy {
    public struct Estimates: Sendable {
        public var towels: Double = 10
        public var lostItem: Double = 14
        public var roomCheck: Double = 8
        public var deferUnsafeCheck: Double = 2
        public var urgentMultiplier: Double = 1.4
        public init() {}
    }

    public var estimates = Estimates()

    public init() {}

    typealias Cmd = SimulatedNightShift.Command
    typealias Kind = SimulatedNightShift.Kind

    struct Candidate {
        let task: ChallengeTask
        let steps: [(name: String, arguments: [String: String])]
        let cost: Int
        let value: Double
        var ratio: Double { value / Double(max(1, cost)) }
    }

    public func decide(observation: Observation, usable: [String: ActionSpec], excludedTasks: Set<String>) -> PolicyDecision {
        guard !observation.isShiftOver else { return .finish(reason: "Shift is over") }
        guard let here = observation.robotLocation else { return .finish(reason: "Robot location unknown") }
        let shiftEnd = observation.shiftEndsAt ?? Int.max
        var candidates: [Candidate] = []
        var skipped: [String] = []

        for task in observation.openTasks {
            if excludedTasks.contains(task.id) { skipped.append("\(task.id) set aside"); continue }
            let flagged = observation.locationFlags[task.destination]?.contains(SimulatedNightShift.doNotDisturb) == true
            var steps: [(String, [String: String])] = []
            var cost = 0
            var location = here
            func go(_ target: String) {
                if location != target {
                    steps.append((Cmd.move, ["to": target]))
                    cost += SimulatedNightShift.travelTime(from: location, to: target)
                    location = target
                }
            }
            var value: Double
            switch task.kind {
            case Kind.towels:
                if !observation.carrying.contains(Kind.towels) {
                    go(SimulatedNightShift.linen)
                    steps.append((Cmd.pickup, ["task": task.id])); cost += 1
                }
                go(task.destination)
                steps.append((Cmd.deliver, ["task": task.id])); cost += 1
                value = estimates.towels
            case Kind.lostItem:
                if let item = task.item, !observation.carrying.contains(item) {
                    go(task.pickupLocation ?? task.destination)
                    steps.append((Cmd.pickup, ["task": task.id])); cost += 1
                }
                go(task.destination)
                steps.append((Cmd.deliver, ["task": task.id])); cost += 1
                value = estimates.lostItem
            case Kind.roomCheck where flagged:
                // Judgement: never enter a do-not-disturb room; report it instead.
                steps.append((Cmd.defer_, ["task": task.id])); cost += 1
                value = estimates.deferUnsafeCheck
            case Kind.roomCheck:
                go(task.destination)
                steps.append((Cmd.inspect, ["task": task.id])); cost += 3
                value = estimates.roomCheck
            default:
                skipped.append("\(task.id) unknown kind \(task.kind)")
                continue
            }
            if let missing = steps.first(where: { usable[$0.0] == nil }) {
                skipped.append("\(task.id) needs unavailable command \(missing.0)")
                continue
            }
            let deadline = min(task.deadline ?? shiftEnd, shiftEnd)
            if observation.time + cost > deadline {
                skipped.append("\(task.id) cannot finish by \(deadline)")
                continue
            }
            if task.priority == "urgent" { value *= estimates.urgentMultiplier }
            candidates.append(Candidate(task: task, steps: steps, cost: cost, value: value))
        }

        // Finish what is already in hand first: a carried lost item belongs to exactly one task.
        let inHand = candidates.filter { $0.task.kind == Kind.lostItem && observation.carrying.contains($0.task.item ?? "") }
        let pool = inHand.isEmpty ? candidates : inHand
        guard let best = pool.max(by: { a, b in
            a.ratio == b.ratio ? a.task.id > b.task.id : a.ratio < b.ratio
        }), let first = best.steps.first else {
            let detail = skipped.isEmpty ? "" : " (\(skipped.joined(separator: "; ")))"
            return .finish(reason: "No remaining task can be completed in time" + detail)
        }
        var rationale = "\(best.task.id) [\(best.task.kind)\(best.task.priority == "urgent" ? ", urgent" : "")]: "
            + "est. value \(Int(best.value.rounded())) for \(best.cost) min "
            + "(ratio \(String(format: "%.2f", best.ratio)); best of \(candidates.count) feasible)"
        if !skipped.isEmpty { rationale += "; skipped: " + skipped.prefix(4).joined(separator: "; ") }
        return .act(name: first.0, arguments: first.1, taskID: best.task.id, rationale: rationale)
    }

    public func reconcile(_ request: ActionRequest, before: Observation, after: Observation) -> ReconcileVerdict {
        switch request.name {
        case Cmd.move:
            guard let target = request.arguments["to"] else { return .unknown }
            return after.robotLocation == target ? .applied : .notApplied
        case Cmd.pickup:
            guard let taskID = request.arguments["task"], let item = before.task(taskID)?.item else { return .unknown }
            let beforeCount = before.carrying.filter { $0 == item }.count
            let afterCount = after.carrying.filter { $0 == item }.count
            return afterCount > beforeCount ? .applied : .unknown
        case Cmd.deliver, Cmd.inspect, Cmd.defer_:
            guard let taskID = request.arguments["task"], let task = after.task(taskID) else { return .unknown }
            return task.status != .open ? .applied : .unknown
        default:
            return .unknown
        }
    }
}
