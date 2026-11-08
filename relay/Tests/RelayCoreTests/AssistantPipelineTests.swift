import XCTest
@testable import RelayCore

final class AssistantPipelineTests: XCTestCase {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var calls = 0
        func hit() { lock.lock(); calls += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    }

    func makeRuntime(_ flag: Flag = Flag()) -> (AssistantRuntime, InMemoryEventLog) {
        let log = InMemoryEventLog(redactor: Redactor())
        let runtime = AssistantRuntime(log: log, simulate: { flag.hit(); return "SIMULATED run finished" },
                                       stopRunner: { "Stop requested" })
        return (runtime, log)
    }

    func testPipelineRecordsHeardUnderstoodPlannedAttempted() async {
        let (runtime, log) = makeRuntime()
        let interaction = await runtime.handle(HeardInput(text: "start", source: .typed))
        XCTAssertEqual(interaction.understanding.intent, .startTraining)
        XCTAssertEqual(interaction.plan.steps.map(\.toolName), ["warehouse.start"])
        XCTAssertEqual(interaction.attempts.first?.status, .succeeded)
        XCTAssertTrue(interaction.reply.contains("Step 1/7"))
        let kinds = log.entries().filter { $0.channel == .assistant }.map(\.kind)
        XCTAssertEqual(Array(kinds.prefix(4)), [.heard, .understood, .planned, .attempted])
    }

    func testUnknownInputDoesNothing() async {
        let (runtime, _) = makeRuntime()
        let interaction = await runtime.handle(HeardInput(text: "reboot the server", source: .typed))
        XCTAssertEqual(interaction.status, .notUnderstood)
        XCTAssertTrue(interaction.attempts.isEmpty)
        let taskCount = await runtime.tasks.tasks.count
        XCTAssertEqual(taskCount, 0)
    }

    func testSimulationRequiresApprovalAndCanBeDeclined() async {
        let flag = Flag()
        let (runtime, _) = makeRuntime(flag)
        let pending = await runtime.handle(HeardInput(text: "run the simulation", source: .typed))
        XCTAssertEqual(pending.status, .awaitingApproval)
        XCTAssertEqual(flag.count, 0, "must not run before approval")
        let taskID = try! XCTUnwrap(pending.taskID)
        var task = await runtime.tasks.task(taskID)
        XCTAssertEqual(task?.state, .awaitingApproval)

        let declined = await runtime.decline(pending.id)
        XCTAssertEqual(declined?.status, .declined)
        XCTAssertEqual(flag.count, 0)
        task = await runtime.tasks.task(taskID)
        XCTAssertEqual(task?.state, .cancelled)
        let approveAfterDecline = await runtime.approve(pending.id)
        XCTAssertNil(approveAfterDecline, "a declined request cannot be approved later")
        XCTAssertEqual(flag.count, 0)
    }

    func testApprovedSimulationRunsOnce() async {
        let flag = Flag()
        let (runtime, _) = makeRuntime(flag)
        let pending = await runtime.handle(HeardInput(text: "run the simulation", source: .typed))
        let done = await runtime.approve(pending.id)
        XCTAssertEqual(done?.status, .completed)
        XCTAssertEqual(flag.count, 1)
        XCTAssertTrue(done!.reply.contains("SIMULATED"))
        let state = await runtime.tasks.task(pending.taskID!)?.state
        XCTAssertEqual(state, .succeeded)
        let again = await runtime.approve(pending.id)
        XCTAssertNil(again)
        XCTAssertEqual(flag.count, 1)
    }

    func testEscalationCreatesAttentionTask() async {
        let (runtime, _) = makeRuntime()
        _ = await runtime.handle(HeardInput(text: "start", source: .typed))
        let interaction = await runtime.handle(HeardInput(text: "What temperature should frozen pallets be?", source: .typed))
        XCTAssertEqual(interaction.status, .needsAttention)
        let tasks = await runtime.tasks.tasks
        XCTAssertEqual(tasks.filter { $0.state == .needsAttention }.count, 1)
        XCTAssertTrue(tasks.first!.title.hasPrefix("Escalation:"))
    }

    func testNextIsBlockedUntilUnderstoodByVoiceCommand() async {
        let (runtime, _) = makeRuntime()
        _ = await runtime.handle(HeardInput(text: "start", source: .transcribed(provider: "test", edited: false)))
        let blocked = await runtime.handle(HeardInput(text: "next", source: .typed))
        XCTAssertEqual(blocked.status, .needsAttention)
        _ = await runtime.handle(HeardInput(text: "rozumiem", source: .typed))
        let next = await runtime.handle(HeardInput(text: "dalej", source: .typed))
        XCTAssertEqual(next.status, .completed)
        XCTAssertTrue(next.reply.contains("2/7"))
    }

    func testLanguageSwitchKeepsWarnings() async {
        let (runtime, _) = makeRuntime()
        _ = await runtime.handle(HeardInput(text: "start", source: .typed))
        let polish = await runtime.handle(HeardInput(text: "po polsku", source: .typed))
        XCTAssertTrue(polish.reply.contains("BEZPIECZEŃSTWO:"))
        XCTAssertTrue(polish.reply.contains("Nigdy nie wchodź na rampę"))
    }

    func testRegistryRejectsUnknownToolsAndHasNoSystemTools() async {
        let registry = ToolRegistry([])
        let attempt = await registry.execute(PlannedStep(toolName: "shell.run", rationale: "x"), approved: true)
        XCTAssertEqual(attempt.status, .unknownTool)
        let (runtime, _) = makeRuntime()
        let names = await runtime.toolDescriptors().map(\.name)
        XCTAssertFalse(names.contains { $0.hasPrefix("shell") || $0.hasPrefix("file") || $0.hasPrefix("system") })
        let approvalTools = await runtime.toolDescriptors().filter(\.requiresApproval).map(\.name)
        XCTAssertEqual(approvalTools, ["wybe.simulate"])
    }

    func testReasonerIsNamedAndNotASpeechService() async {
        let understanding = await RuleBasedReasoner().interpret("neste", context: ReasoningContext(trainingActive: true, language: "nb"))
        XCTAssertEqual(understanding.intent, .nextStep)
        XCTAssertTrue(understanding.engine.contains("no language model"))
    }
}
