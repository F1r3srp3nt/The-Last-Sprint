import XCTest
@testable import RelayCore

/// Proposes a fixed list of actions, then finishes.
final class ScriptedPolicy: ShiftPolicy, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [(String, [String: String], String?)]
    init(_ actions: [(String, [String: String], String?)]) { queue = actions }

    func decide(observation: Observation, usable: [String: ActionSpec], excludedTasks: Set<String>) -> PolicyDecision {
        lock.lock(); defer { lock.unlock() }
        guard !queue.isEmpty else { return .finish(reason: "script done") }
        let (name, args, task) = queue.removeFirst()
        return .act(name: name, arguments: args, taskID: task, rationale: "scripted")
    }

    func reconcile(_ request: ActionRequest, before: Observation, after: Observation) -> ReconcileVerdict {
        SimulatedShiftPolicy().reconcile(request, before: before, after: after)
    }
}

final class AutonomousRunnerTests: XCTestCase {
    typealias Cmd = SimulatedNightShift.Command

    func config(_ change: (inout RunnerConfiguration) -> Void = { _ in }) -> RunnerConfiguration {
        var c = RunnerConfiguration.simulation()
        c.actionTimeout = 0.1
        c.readTimeout = 0.5
        change(&c)
        return c
    }

    func run(_ sim: SimulatedNightShift, policy: ShiftPolicy = SimulatedShiftPolicy(),
             config: RunnerConfiguration? = nil, clock: RelayClock = ManualClock(), stop: StopSignal = StopSignal(),
             log: InMemoryEventLog = InMemoryEventLog(redactor: Redactor()),
             onEvent: (@Sendable (RunnerEvent) -> Void)? = nil) async -> RunReport {
        let runner = AutonomousRunner(adapter: sim, policy: policy, configuration: config ?? self.config(),
                                      clock: clock, log: log, stop: stop, onEvent: onEvent)
        return await runner.run()
    }

    /// Finds the first open task of a kind and the observation, for building scripted actions.
    func firstTask(_ sim: SimulatedNightShift, kind: String) async throws -> ChallengeTask {
        let obs = try await sim.observe()
        return try XCTUnwrap(obs.tasks.first { $0.kind == kind && obs.locationFlags[$0.destination] == nil })
    }

    // MARK: Headless operation & determinism

    func testHeadlessShiftRunsWithoutSpeechOrApprovalAndIsDeterministic() async {
        let logA = InMemoryEventLog(redactor: Redactor())
        let a = await run(SimulatedNightShift(configuration: .init(seed: 42)), log: logA)
        let b = await run(SimulatedNightShift(configuration: .init(seed: 42)))
        XCTAssertGreaterThan(a.actions.count, 5)
        XCTAssertEqual(a.actions.map(\.request.displayText), b.actions.map(\.request.displayText))
        XCTAssertEqual(a.score, b.score)
        XCTAssertTrue(a.actions.allSatisfy { $0.status == .succeeded })
        XCTAssertFalse(logA.entries().contains { $0.channel == .speech || $0.channel == .assistant })
        XCTAssertTrue(logA.entries().filter { $0.channel == .wybe }.allSatisfy { $0.mode == .simulation })
    }

    func testPolicyNeverEntersDoNotDisturbRooms() async {
        for seed in UInt64(1)...20 {
            let sim = SimulatedNightShift(configuration: .init(seed: seed))
            _ = await run(sim)
            let ledger = await sim.ledger
            XCTAssertFalse(ledger.contains { $0.reason.contains("do-not-disturb room") }, "seed \(seed)")
            XCTAssertFalse(ledger.contains { $0.delta < 0 }, "careless penalty on seed \(seed): \(ledger.filter { $0.delta < 0 })")
        }
    }

    func testMoreTasksThanTimeAllowsAreTriaged() async {
        let sim = SimulatedNightShift(configuration: .init(seed: 3, taskCount: 14))
        let report = await run(sim)
        let obs = try! await sim.observe()
        XCTAssertFalse(obs.openTasks.isEmpty, "the simulator should offer more work than one shift allows")
        XCTAssertTrue(report.stopReason.contains("No remaining task") || report.stopReason.contains("Shift over"))
    }

    // MARK: Capability boundaries

    func testUnknownCommandIsNeverSent() async {
        let sim = SimulatedNightShift(configuration: .init(seed: 1))
        let report = await run(sim, policy: ScriptedPolicy([("sim.teleport", ["to": "101"], "T1")]))
        XCTAssertEqual(report.actions.first?.status, .blockedUnknownCommand)
        let received = await sim.received
        XCTAssertTrue(received.isEmpty)
    }

    func testDisallowedCommandIsNeverSent() async {
        let sim = SimulatedNightShift(configuration: .init(seed: 1))
        let cfg = config { $0.allowedActions = [Cmd.move] }
        let report = await run(sim, policy: ScriptedPolicy([(Cmd.defer_, ["task": "T1"], "T1")]), config: cfg)
        XCTAssertEqual(report.actions.first?.status, .blockedNotAllowed)
        let received = await sim.received
        XCTAssertTrue(received.isEmpty)
    }

    func testRealPolicyRespectsAllowList() async {
        let sim = SimulatedNightShift(configuration: .init(seed: 5))
        let cfg = config { $0.allowedActions = [Cmd.move, Cmd.pickup, Cmd.deliver] }
        _ = await run(sim, config: cfg)
        let names = Set(await sim.received.map(\.name))
        XCTAssertTrue(names.isSubset(of: [Cmd.move, Cmd.pickup, Cmd.deliver]))
    }

    func testPreconditionFailureBlocksSending() async {
        let sim = SimulatedNightShift(configuration: .init(seed: 1))
        let towel = try! await firstTask(sim, kind: SimulatedNightShift.Kind.towels)
        let report = await run(sim, policy: ScriptedPolicy([(Cmd.deliver, ["task": towel.id], towel.id)]))
        XCTAssertEqual(report.actions.first?.status, .blockedPrecondition)
        XCTAssertEqual(report.setAsideTasks.keys.sorted(), [towel.id])
        let received = await sim.received
        XCTAssertTrue(received.isEmpty)
    }

    // MARK: Retries, timeouts, backoff

    func testTransientFailuresAreRetriedWithinBound() async {
        let sim = SimulatedNightShift(configuration: .init(seed: 1, scriptedFaults: [1: .transient, 2: .transient, 3: .transient]))
        let clock = ManualClock()
        let report = await run(sim, policy: ScriptedPolicy([(Cmd.move, ["to": "101"], nil)]), clock: clock)
        XCTAssertEqual(report.actions.first?.status, .failed)
        XCTAssertEqual(report.actions.first?.attempts, 3)
        let performCallCount1 = await sim.performCallCount
        XCTAssertEqual(performCallCount1, 3, "maxAttempts bounds the number of sends")
        XCTAssertEqual(clock.sleeps.filter { $0 > 0 }, [0.01, 0.02], "exponential backoff between attempts")
    }

    func testRetrySucceedsAfterTransientFailure() async {
        let sim = SimulatedNightShift(configuration: .init(seed: 1, scriptedFaults: [1: .transient]))
        let report = await run(sim, policy: ScriptedPolicy([(Cmd.move, ["to": "101"], nil)]))
        XCTAssertEqual(report.actions.first?.status, .succeeded)
        XCTAssertEqual(report.actions.first?.attempts, 2)
    }

    func testRateLimitResponsePausesThenRetries() async {
        let sim = SimulatedNightShift(configuration: .init(seed: 1, scriptedFaults: [1: .rateLimited]))
        let clock = ManualClock()
        let report = await run(sim, policy: ScriptedPolicy([(Cmd.move, ["to": "101"], nil)]), clock: clock)
        XCTAssertEqual(report.actions.first?.status, .succeeded)
        XCTAssertGreaterThanOrEqual(clock.sleeps.reduce(0, +), 0.05 - 1e-6, "waits at least the server's retry-after")
    }

    func testTimeoutHelper() async throws {
        let fast = try await withTimeout(seconds: 1) { 7 }
        XCTAssertEqual(fast, 7)
        do {
            _ = try await withTimeout(seconds: 0.05) { try await Task.sleep(nanoseconds: 2_000_000_000); return 1 }
            XCTFail("expected timeout")
        } catch let error as RelayTimeoutError {
            XCTAssertEqual(error.seconds, 0.05)
        }
    }

    func testRetryPolicyAndRateLimiter() async throws {
        let policy = RetryPolicy(maxAttempts: 10, baseDelay: 1, multiplier: 2, maxDelay: 5)
        XCTAssertEqual((1...6).map { policy.delay(beforeAttempt: $0) }, [0, 1, 2, 4, 5, 5])
        XCTAssertEqual(RetryPolicy(maxAttempts: 0).maxAttempts, 1)
        let clock = ManualClock()
        let limiter = RateLimiter(minInterval: 1, clock: clock)
        for _ in 0..<3 { try await limiter.acquire() }
        XCTAssertEqual(clock.sleeps, [1, 1])
    }

    // MARK: Ambiguous failures must not duplicate consequential actions

    /// Script: move to linen, pick up towels, move to room, deliver (the deliver's response is lost).
    func towelScript(_ towel: ChallengeTask) -> [(String, [String: String], String?)] {
        [(Cmd.move, ["to": SimulatedNightShift.linen], towel.id), (Cmd.pickup, ["task": towel.id], towel.id),
         (Cmd.move, ["to": towel.destination], towel.id), (Cmd.deliver, ["task": towel.id], towel.id),
         (Cmd.deliver, ["task": towel.id], towel.id)] // a naive second deliver must be blocked by preconditions
    }

    func testAppliedButLostResponseIsConfirmedNotRepeated() async {
        let sim = SimulatedNightShift(configuration: .init(seed: 1, scriptedFaults: [4: .appliedThenLost]))
        let towel = try! await firstTask(sim, kind: SimulatedNightShift.Kind.towels)
        let report = await run(sim, policy: ScriptedPolicy(towelScript(towel)))
        XCTAssertEqual(report.actions[3].status, .ambiguousConfirmedApplied)
        XCTAssertEqual(report.actions[3].attempts, 1)
        XCTAssertEqual(report.actions[4].status, .blockedPrecondition, "task is complete; nothing re-sent")
        let completionAttempts2 = await sim.completionAttempts
        XCTAssertEqual(completionAttempts2[towel.id], 1)
        let ledger3 = await sim.ledger
        XCTAssertFalse(ledger3.contains { $0.delta < 0 })
    }

    func testWithoutStatusQueryObservationConfirmsApplied() async {
        let sim = SimulatedNightShift(configuration: .init(seed: 1, scriptedFaults: [4: .appliedThenLost],
                                                           statusQueryAvailable: false))
        let towel = try! await firstTask(sim, kind: SimulatedNightShift.Kind.towels)
        let report = await run(sim, policy: ScriptedPolicy(towelScript(towel)))
        XCTAssertEqual(report.actions[3].status, .ambiguousConfirmedApplied)
        let completionAttempts4 = await sim.completionAttempts
        XCTAssertEqual(completionAttempts4[towel.id], 1)
    }

    func testConfirmedNotAppliedMayBeRetried() async {
        let sim = SimulatedNightShift(configuration: .init(seed: 1, scriptedFaults: [4: .hangNotApplied]))
        let towel = try! await firstTask(sim, kind: SimulatedNightShift.Kind.towels)
        let report = await run(sim, policy: ScriptedPolicy(Array(towelScript(towel).prefix(4))))
        XCTAssertEqual(report.actions[3].status, .succeeded)
        XCTAssertEqual(report.actions[3].attempts, 2)
        let delivers = await sim.received.filter { $0.name == Cmd.deliver }
        XCTAssertEqual(delivers.count, 2)
        XCTAssertEqual(Set(delivers.map(\.idempotencyKey)).count, 1, "the retry reuses the same idempotency key")
        let completionAttempts5 = await sim.completionAttempts
        XCTAssertEqual(completionAttempts5[towel.id], 1, "applied exactly once")
    }

    func testUnresolvableAmbiguitySetsTaskAsideWithoutRepeating() async {
        // No status query, and the observation cannot prove the pickup did not happen: the
        // runner must not send it again.
        let sim = SimulatedNightShift(configuration: .init(seed: 1, scriptedFaults: [2: .hangNotApplied],
                                                           statusQueryAvailable: false))
        let towel = try! await firstTask(sim, kind: SimulatedNightShift.Kind.towels)
        let report = await run(sim, policy: ScriptedPolicy(Array(towelScript(towel).prefix(2))))
        XCTAssertEqual(report.actions[1].status, .ambiguousUnresolved)
        XCTAssertEqual(report.setAsideTasks[towel.id], "outcome of sim.pickup unknown; not repeated")
        let received6 = await sim.received
        XCTAssertEqual(received6.filter { $0.name == Cmd.pickup }.count, 1)
    }

    func testFullPolicyUnderHarshFaultsNeverDuplicatesCompletions() async {
        for seed in UInt64(1)...6 {
            let sim = SimulatedNightShift(configuration: .init(seed: seed, faults: .harsh))
            let report = await run(sim)
            let attempts = await sim.completionAttempts
            XCTAssertTrue(attempts.values.allSatisfy { $0 == 1 }, "seed \(seed): \(attempts)")
            let ledger7 = await sim.ledger
            XCTAssertFalse(ledger7.contains { $0.reason.contains("already") })
            XCTAssertLessThanOrEqual(report.actions.map(\.attempts).max() ?? 0, 3)
        }
    }

    // MARK: Stop control

    func testStopPreventsAllSubsequentActions() async {
        let sim = SimulatedNightShift(configuration: .init(seed: 9))
        let stop = StopSignal()
        let report = await run(sim, stop: stop) { event in
            if case let .recorded(record) = event, record.sequence == 3 { stop.stop(reason: "operator stop") }
        }
        XCTAssertEqual(report.stopReason, "operator stop")
        XCTAssertEqual(report.actions.count, 3)
        let performCallCount8 = await sim.performCallCount
        XCTAssertEqual(performCallCount8, 3, "nothing is sent after stop")
    }

    func testStopBeforeStartSendsNothing() async {
        let sim = SimulatedNightShift(configuration: .init(seed: 9))
        let stop = StopSignal()
        stop.stop(reason: "pre-stopped")
        let report = await run(sim, stop: stop)
        XCTAssertEqual(report.stopReason, "pre-stopped")
        let performCallCount9 = await sim.performCallCount
        XCTAssertEqual(performCallCount9, 0)
    }

    func testStopDuringBackoffPreventsRetry() async {
        let sim = SimulatedNightShift(configuration: .init(seed: 1, scriptedFaults: [1: .transient, 2: .transient]))
        let stop = StopSignal()
        let log = InMemoryEventLog(redactor: Redactor())
        log.addObserver { event in if event.message.hasPrefix("Attempt 1") { stop.stop(reason: "stop mid-retry") } }
        let report = await run(sim, policy: ScriptedPolicy([(Cmd.move, ["to": "101"], nil)]), stop: stop, log: log)
        XCTAssertEqual(report.actions.first?.status, .stopped)
        let performCallCount10 = await sim.performCallCount
        XCTAssertEqual(performCallCount10, 1)
    }

    func testTaskCancellationStopsRunner() async {
        let sim = SimulatedNightShift(configuration: .init(seed: 2))
        let runner = AutonomousRunner(adapter: sim, policy: SimulatedShiftPolicy(),
                                      configuration: config { $0.minRequestInterval = 0.05 }, clock: SystemClock(),
                                      log: InMemoryEventLog(redactor: Redactor()), stop: StopSignal())
        let task = Task { await runner.run() }
        try? await Task.sleep(nanoseconds: 120_000_000)
        task.cancel()
        let report = await task.value
        let sentAtStop = await sim.performCallCount
        XCTAssertTrue(report.stopReason.contains("Cancel"), report.stopReason)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let performCallCount11 = await sim.performCallCount
        XCTAssertEqual(performCallCount11, sentAtStop)
    }

    func testActionBudget() async {
        let report = await run(SimulatedNightShift(configuration: .init(seed: 4)), config: config { $0.maxActions = 4 })
        XCTAssertEqual(report.actions.count, 4)
        XCTAssertTrue(report.stopReason.contains("budget"))
    }

    // MARK: Simulation vs live separation

    func testSimulatedScoresAreAlwaysLabelled() async {
        let report = await run(SimulatedNightShift(configuration: .init(seed: 1)))
        let score = try! XCTUnwrap(report.score)
        XCTAssertEqual(score.mode, .simulation)
        XCTAssertTrue(score.displayText.contains("SIMULATED"))
        XCTAssertTrue(score.displayText.contains("not a challenge result"))
        XCTAssertTrue(report.summary.hasPrefix("[SIMULATED]"))
        XCTAssertFalse(report.summary.contains("LIVE"))
        XCTAssertTrue(report.actions.allSatisfy { $0.mode == .simulation })
    }

    func testModeMismatchIsRefused() async {
        let sim = SimulatedNightShift(configuration: .init(seed: 1))
        let report = await run(sim, config: config { $0.expectedMode = .live })
        XCTAssertTrue(report.stopReason.hasPrefix("Refused: mode mismatch"))
        XCTAssertTrue(report.actions.isEmpty)
        let performCallCount12 = await sim.performCallCount
        XCTAssertEqual(performCallCount12, 0)
    }
}
