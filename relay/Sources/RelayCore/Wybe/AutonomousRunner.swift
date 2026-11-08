import Foundation

public struct RunnerConfiguration: Sendable {
    /// The runner refuses to start if the adapter's mode differs. Prevents a simulation
    /// configuration from accidentally driving a live service and vice versa.
    public var expectedMode: ExecutionMode
    /// Explicit capability allow-list. Commands outside it are never sent, even if discovered.
    public var allowedActions: Set<String>
    public var maxActions: Int
    public var actionTimeout: Double
    public var readTimeout: Double
    public var retry: RetryPolicy
    public var minRequestInterval: Double
    public var maxConsecutiveFailures: Int
    /// Wall-clock budget measured on the runner's clock. `nil` = unlimited.
    public var maxRunSeconds: Double?
    /// A task is set aside after this many failed actions.
    public var maxFailuresPerTask: Int

    public init(expectedMode: ExecutionMode, allowedActions: Set<String>, maxActions: Int = 200,
                actionTimeout: Double = 5, readTimeout: Double = 5, retry: RetryPolicy = RetryPolicy(),
                minRequestInterval: Double = 1.0, maxConsecutiveFailures: Int = 5, maxRunSeconds: Double? = nil,
                maxFailuresPerTask: Int = 2) {
        self.expectedMode = expectedMode
        self.allowedActions = allowedActions
        self.maxActions = maxActions
        self.actionTimeout = actionTimeout
        self.readTimeout = readTimeout
        self.retry = retry
        self.minRequestInterval = minRequestInterval
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.maxRunSeconds = maxRunSeconds
        self.maxFailuresPerTask = maxFailuresPerTask
    }

    /// Defaults for the offline simulator: fast, but still exercising timeouts and retries.
    public static func simulation(allowed: Set<String> = Set(SimulatedNightShift.Command.all)) -> RunnerConfiguration {
        RunnerConfiguration(expectedMode: .simulation, allowedActions: allowed, maxActions: 200, actionTimeout: 0.15,
                            readTimeout: 0.5, retry: RetryPolicy(maxAttempts: 3, baseDelay: 0.01, multiplier: 2, maxDelay: 0.1),
                            minRequestInterval: 0, maxConsecutiveFailures: 6)
    }
}

public enum ActionResultStatus: String, Codable, Sendable {
    case succeeded
    /// The environment received the action and refused it.
    case rejectedByEnvironment
    /// Gave up (retries exhausted or permanent error).
    case failed
    /// Outcome was ambiguous; reconciliation showed it was applied.
    case ambiguousConfirmedApplied
    /// Outcome is unknown; the action was NOT repeated and the task was set aside.
    case ambiguousUnresolved
    /// Never sent: command not in the discovered capabilities.
    case blockedUnknownCommand
    /// Never sent: command not in the configured allow-list.
    case blockedNotAllowed
    /// Never sent: a precondition failed against the latest observation.
    case blockedPrecondition
    /// Never sent (or not retried) because stop was requested.
    case stopped

    public var wasSent: Bool {
        switch self {
        case .blockedUnknownCommand, .blockedNotAllowed, .blockedPrecondition: return false
        default: return true
        }
    }
}

public struct ActionRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let sequence: Int
    public let mode: ExecutionMode
    public let taskID: String?
    public let request: ActionRequest
    public let rationale: String
    public let attempts: Int
    public let status: ActionResultStatus
    public let message: String
    public let startedAt: Date
    public let endedAt: Date
}

public struct RunReport: Codable, Sendable {
    public let mode: ExecutionMode
    public let adapterName: String
    public let startedAt: Date
    public let endedAt: Date
    public let stopReason: String
    public let discoveredCommands: [String]
    public let actions: [ActionRecord]
    /// Task → reason it was set aside.
    public let setAsideTasks: [String: String]
    public let score: LabeledScore?

    public var sentActionCount: Int { actions.filter { $0.status.wasSent && $0.status != .stopped }.count }

    public var summary: String {
        var lines = ["[\(mode.label)] \(adapterName)", "Stopped: \(stopReason)",
                     "Actions recorded: \(actions.count) (sent: \(sentActionCount))"]
        let grouped = Dictionary(grouping: actions, by: \.status).mapValues(\.count)
        for (status, count) in grouped.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            lines.append("  \(status.rawValue): \(count)")
        }
        if !setAsideTasks.isEmpty {
            lines.append("Set aside: " + setAsideTasks.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }.joined(separator: ", "))
        }
        lines.append("Score: " + (score?.displayText ?? "not available"))
        return lines.joined(separator: "\n")
    }
}

public enum RunnerEvent: Sendable {
    case observed(Observation)
    case decided(String)
    case recorded(ActionRecord)
    case finished(RunReport)
}

/// Headless, autonomous executor for a challenge environment.
///
/// Independent of any window, speech service or human confirmation. Safety properties:
/// - Only discovered ∩ allowed commands are sent; preconditions are checked first.
/// - Every request goes through a rate limiter and a timeout.
/// - Retries are bounded. Consequential actions are only retried when the runner knows they
///   were not applied; after an unresolvable ambiguous failure the task is set aside instead.
/// - The stop signal is checked before every request; once stopped, nothing more is sent.
public actor AutonomousRunner {
    private let adapter: ChallengeAdapter
    private let policy: ShiftPolicy
    private let config: RunnerConfiguration
    private let clock: RelayClock
    private let log: EventLogging
    private let stopSignal: StopSignal
    private let limiter: RateLimiter
    private let onEvent: (@Sendable (RunnerEvent) -> Void)?
    private var startedAt = Date()

    public init(adapter: ChallengeAdapter, policy: ShiftPolicy, configuration: RunnerConfiguration,
                clock: RelayClock = SystemClock(), log: EventLogging, stop: StopSignal,
                onEvent: (@Sendable (RunnerEvent) -> Void)? = nil) {
        self.adapter = adapter
        self.policy = policy
        self.config = configuration
        self.clock = clock
        self.log = log
        self.stopSignal = stop
        self.limiter = RateLimiter(minInterval: configuration.minRequestInterval, clock: clock)
        self.onEvent = onEvent
    }

    private enum StopRequested: Error { case stopped(String) }

    private var mode: ExecutionMode { adapter.mode }

    private func note(_ kind: LogKind, _ message: String, _ details: [String: String] = [:]) {
        log.record(.wybe, kind, message, mode: mode, details: details)
    }

    private func haltReason() -> String? {
        if let reason = stopSignal.stopReason { return reason }
        if Task.isCancelled { return "Cancelled" }
        if let budget = config.maxRunSeconds, clock.now().timeIntervalSince(startedAt) >= budget {
            return "Run time budget reached"
        }
        return nil
    }

    public func run() async -> RunReport {
        startedAt = clock.now()
        var records: [ActionRecord] = []
        var setAside: [String: String] = [:]
        var failuresPerTask: [String: Int] = [:]
        var discovered: [String] = []

        func finish(_ reason: String) async -> RunReport {
            let score = await adapter.scoreReport()
            let report = RunReport(mode: mode, adapterName: adapter.name, startedAt: startedAt, endedAt: clock.now(),
                                   stopReason: reason, discoveredCommands: discovered, actions: records,
                                   setAsideTasks: setAside, score: score)
            note(.info, "Run finished: \(reason)", ["actions": String(records.count)])
            onEvent?(.finished(report))
            return report
        }

        guard adapter.mode == config.expectedMode else {
            note(.rejected, "Refused to start: runner is configured for \(config.expectedMode.label) but the adapter is \(adapter.mode.label)")
            return await finish("Refused: mode mismatch (configured \(config.expectedMode.rawValue), adapter \(adapter.mode.rawValue))")
        }
        note(.info, "Run started against \(adapter.name)")

        let capabilities: [ActionSpec]
        do {
            capabilities = try await read("discover capabilities") { [adapter] in try await adapter.discoverCapabilities() }
        } catch StopRequested.stopped(let reason) {
            return await finish(reason)
        } catch {
            note(.failed, "Could not discover capabilities: \(describe(error))")
            return await finish("Could not discover capabilities: \(describe(error))")
        }
        discovered = capabilities.map(\.name).sorted()
        let known = Dictionary(capabilities.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let usable = known.filter { config.allowedActions.contains($0.key) }
        note(.info, "Discovered commands: \(discovered.joined(separator: ", "))",
             ["usable": usable.keys.sorted().joined(separator: ","),
              "not allowed by configuration": known.keys.filter { usable[$0] == nil }.sorted().joined(separator: ",")])

        var consecutiveFailures = 0
        var sequence = 0

        while true {
            if let reason = haltReason() { return await finish(reason) }
            if sequence >= config.maxActions { return await finish("Action budget (\(config.maxActions)) reached") }
            if consecutiveFailures >= config.maxConsecutiveFailures {
                return await finish("Stopped after \(consecutiveFailures) consecutive failures")
            }

            let observation: Observation
            do {
                observation = try await read("observe") { [adapter] in try await adapter.observe() }
            } catch StopRequested.stopped(let reason) {
                return await finish(reason)
            } catch let error as ChallengeError {
                if case .contractUnavailable = error {
                    // Key refused or settings changed: nothing more may be sent.
                    note(.failed, "Observation impossible: \(describe(error))")
                    return await finish(describe(error))
                }
                consecutiveFailures += 1
                note(.failed, "Observation failed: \(describe(error))")
                continue
            } catch {
                consecutiveFailures += 1
                note(.failed, "Observation failed: \(describe(error))")
                continue
            }
            onEvent?(.observed(observation))
            if observation.isShiftOver { return await finish("Shift over") }

            let decision = policy.decide(observation: observation, usable: usable, excludedTasks: Set(setAside.keys))
            guard case let .act(name, arguments, taskID, rationale) = decision else {
                if case let .finish(reason) = decision { return await finish(reason) }
                return await finish("No decision")
            }
            sequence += 1
            let request = ActionRequest(name: name, arguments: arguments)
            note(.planned, "Plan: \(request.displayText)", ["why": rationale, "task": taskID ?? "-"])
            onEvent?(.decided("\(request.displayText) — \(rationale)"))

            let begin = clock.now()
            func blocked(_ status: ActionResultStatus, _ message: String) -> ActionRecord {
                ActionRecord(id: UUID(), sequence: sequence, mode: mode, taskID: taskID, request: request,
                             rationale: rationale, attempts: 0, status: status, message: message,
                             startedAt: begin, endedAt: clock.now())
            }

            var record: ActionRecord
            if let spec = known[name] {
                if usable[name] == nil {
                    record = blocked(.blockedNotAllowed, "\(name) is not in the configured allow-list; not sent")
                } else if let unmet = PreconditionChecker.firstUnmet(spec, request, observation) {
                    record = blocked(.blockedPrecondition, "Precondition failed: \(unmet); not sent")
                } else {
                    record = await execute(request, spec: spec, taskID: taskID, rationale: rationale,
                                           sequence: sequence, before: observation)
                }
            } else {
                record = blocked(.blockedUnknownCommand, "\(name) was not among the discovered commands; not sent")
            }

            records.append(record)
            onEvent?(.recorded(record))
            let kind: LogKind
            switch record.status {
            case .succeeded, .ambiguousConfirmedApplied: kind = .succeeded
            case .ambiguousUnresolved: kind = .needsAttention
            case .blockedNotAllowed, .blockedUnknownCommand, .blockedPrecondition: kind = .rejected
            case .stopped: kind = .info
            case .failed, .rejectedByEnvironment: kind = .failed
            }
            note(kind, "\(record.status.rawValue): \(request.displayText) — \(record.message)",
                 ["attempts": String(record.attempts), "task": taskID ?? "-"])

            switch record.status {
            case .succeeded, .ambiguousConfirmedApplied:
                consecutiveFailures = 0
            case .stopped:
                return await finish(haltReason() ?? "Stopped")
            case .ambiguousUnresolved:
                consecutiveFailures += 1
                if let taskID { setAside[taskID] = "outcome of \(name) unknown; not repeated" }
            case .blockedNotAllowed, .blockedUnknownCommand, .blockedPrecondition, .failed, .rejectedByEnvironment:
                consecutiveFailures += 1
                if let taskID {
                    failuresPerTask[taskID, default: 0] += 1
                    if record.status != .failed && record.status != .rejectedByEnvironment || failuresPerTask[taskID]! >= config.maxFailuresPerTask {
                        setAside[taskID] = record.message
                    }
                }
            }
        }
    }

    // MARK: Execution

    private func execute(_ request: ActionRequest, spec: ActionSpec, taskID: String?, rationale: String,
                         sequence: Int, before: Observation) async -> ActionRecord {
        let begin = clock.now()
        var attempts = 0
        var lastProblem = "no attempt made"

        func record(_ status: ActionResultStatus, _ message: String) -> ActionRecord {
            ActionRecord(id: UUID(), sequence: sequence, mode: mode, taskID: taskID, request: request,
                         rationale: rationale, attempts: attempts, status: status, message: message,
                         startedAt: begin, endedAt: clock.now())
        }

        while attempts < config.retry.maxAttempts {
            if attempts > 0 {
                do { try await clock.sleep(seconds: config.retry.delay(beforeAttempt: attempts + 1)) } catch {
                    return record(.stopped, "Cancelled before retry; last problem: \(lastProblem)")
                }
            }
            if let reason = haltReason() {
                return record(.stopped, attempts == 0 ? "\(reason); action not sent" : "\(reason); not retried after: \(lastProblem)")
            }
            do { try await limiter.acquire() } catch {
                return record(.stopped, "Cancelled while waiting for rate limiter")
            }
            if let reason = haltReason() {
                return record(.stopped, attempts == 0 ? "\(reason); action not sent" : "\(reason); not retried after: \(lastProblem)")
            }

            attempts += 1
            note(.attempted, "Attempt \(attempts): \(request.displayText)", ["key": request.idempotencyKey])
            do {
                let outcome = try await withTimeout(seconds: config.actionTimeout) { [adapter] in
                    try await adapter.perform(request)
                }
                return record(outcome.accepted ? .succeeded : .rejectedByEnvironment, outcome.message)
            } catch let error as ChallengeError {
                switch error {
                case let .transient(message):
                    lastProblem = message
                    continue
                case let .rateLimited(after):
                    lastProblem = "rate limited"
                    await limiter.pause(seconds: after ?? config.retry.delay(beforeAttempt: attempts + 1))
                    continue
                case let .rejected(message):
                    return record(.rejectedByEnvironment, message)
                case let .contractUnavailable(message):
                    return record(.failed, message)
                case let .ambiguous(message):
                    lastProblem = message
                }
            } catch is RelayTimeoutError {
                lastProblem = "timed out after \(config.actionTimeout)s"
            } catch is CancellationError {
                // We cannot know whether the in-flight request was applied.
                return record(spec.consequential ? .ambiguousUnresolved : .stopped,
                              "Interrupted while in flight; outcome unknown and not repeated")
            } catch {
                lastProblem = describe(error)
            }

            // Ambiguous outcome (timeout, lost response, unknown transport error).
            if !spec.consequential {
                note(.info, "Ambiguous result for non-consequential \(request.name); safe to retry", ["problem": lastProblem])
                continue
            }
            switch await reconcile(request, before: before) {
            case .applied:
                return record(.ambiguousConfirmedApplied, "\(lastProblem); confirmed applied, not repeated")
            case .notApplied:
                note(.info, "Ambiguous result for \(request.name) confirmed NOT applied; retry permitted", ["problem": lastProblem])
                continue
            case .unknown:
                return record(.ambiguousUnresolved, "\(lastProblem); could not confirm outcome, so it was not repeated")
            }
        }
        return record(.failed, "Gave up after \(attempts) attempt(s): \(lastProblem)")
    }

    private func reconcile(_ request: ActionRequest, before: Observation) async -> ReconcileVerdict {
        if adapter.supportsStatusQuery {
            if let answer = try? await read("status query", { [adapter] in try await adapter.status(of: request.idempotencyKey) }) {
                switch answer {
                case .applied: return .applied
                case .notApplied: return .notApplied
                case .unknown: break
                }
            }
        }
        guard let after = try? await read("observe for reconciliation", { [adapter] in try await adapter.observe() }) else {
            return .unknown
        }
        return policy.reconcile(request, before: before, after: after)
    }

    /// Read-only requests: safe to retry on any failure, still rate-limited, time-bounded and stoppable.
    private func read<T: Sendable>(_ label: String, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        var lastError: Error = ChallengeError.transient("no attempt")
        while attempt < config.retry.maxAttempts {
            attempt += 1
            if attempt > 1 { try await clock.sleep(seconds: config.retry.delay(beforeAttempt: attempt)) }
            if let reason = haltReason() { throw StopRequested.stopped(reason) }
            try await limiter.acquire()
            do {
                return try await withTimeout(seconds: config.readTimeout, operation)
            } catch let error as ChallengeError {
                if case .contractUnavailable = error { throw error }
                if case .rejected = error { throw error }
                if case let .rateLimited(after) = error { await limiter.pause(seconds: after ?? 1) }
                lastError = error
            } catch is CancellationError {
                throw StopRequested.stopped("Cancelled")
            } catch {
                lastError = error
            }
            note(.info, "\(label) attempt \(attempt) failed: \(describe(lastError))")
        }
        throw lastError
    }

    private func describe(_ error: Error) -> String {
        String(describing: error)
    }
}
