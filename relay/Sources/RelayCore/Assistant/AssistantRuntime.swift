import Foundation

public enum InputSource: Sendable, Equatable {
    case typed
    /// A button in the UI issued the command (e.g. "Next" in Warehouse Training).
    case control
    /// `edited` is true when the user changed the transcript before sending.
    case transcribed(provider: String, edited: Bool)

    public var label: String {
        switch self {
        case .typed: return "Typed"
        case .control: return "Button"
        case let .transcribed(provider, edited): return "Transcribed by \(provider)" + (edited ? " (edited)" : "")
        }
    }
}

public struct HeardInput: Sendable, Equatable {
    public let text: String
    public let source: InputSource
    public init(text: String, source: InputSource) {
        self.text = text
        self.source = source
    }
}

public enum InteractionStatus: String, Sendable, Equatable {
    case completed, awaitingApproval, needsAttention, failed, declined, notUnderstood
}

/// One request through the pipeline: heard → understood → planned → attempted → result.
public struct Interaction: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let heard: HeardInput
    public let understanding: Understanding
    public let plan: Plan
    public var attempts: [ToolAttempt]
    public var reply: String
    public var status: InteractionStatus
    public var taskID: UUID?
    public let createdAt: Date
}

public struct TrainingSnapshot: Sendable, Equatable {
    public let procedureTitle: String
    public let disclaimer: String
    public let language: String
    public let languages: [String]
    public let current: RenderedStep?
    public let pendingAcknowledgement: Bool
    public let isFinished: Bool
    public let lastAnswer: TrainingAnswer?
}

/// Headless assistant: owns the training session and task queue and runs the pipeline.
/// The macOS app and the command-line demo are both thin shells around it.
public actor AssistantRuntime {
    public private(set) var training: TrainingSession
    public private(set) var tasks: TaskQueue
    public private(set) var interactions: [Interaction] = []
    private var lastAnswer: TrainingAnswer?
    private let reasoner: Reasoner
    private let planner: TaskPlanner
    private var registry = ToolRegistry([])
    private let log: EventLogging
    private let simulate: (@Sendable () async -> String)?
    private let stopRunner: (@Sendable () -> String)?

    public init(procedure: Procedure = DemoProcedure.procedure, language: String = "en", log: EventLogging,
                reasoner: Reasoner = RuleBasedReasoner(), planner: TaskPlanner = DefaultTaskPlanner(),
                simulate: (@Sendable () async -> String)? = nil, stopRunner: (@Sendable () -> String)? = nil) {
        training = TrainingSession(procedure: procedure, language: language)
        tasks = TaskQueue(log: log)
        self.log = log
        self.reasoner = reasoner
        self.planner = planner
        self.simulate = simulate
        self.stopRunner = stopRunner
    }

    public var reasonerName: String { reasoner.engineName }

    public func toolDescriptors() -> [ToolDescriptor] {
        ensureTools()
        return registry.descriptors
    }

    public func trainingSnapshot() -> TrainingSnapshot {
        let p = training.procedure
        return TrainingSnapshot(
            procedureTitle: p.title.resolve(training.language, source: p.sourceLanguage).text,
            disclaimer: p.disclaimer.resolve(training.language, source: p.sourceLanguage).text,
            language: training.language, languages: p.languages, current: training.currentRendered,
            pendingAcknowledgement: !training.unacknowledgedCritical.isEmpty, isFinished: training.isFinished,
            lastAnswer: lastAnswer)
    }

    /// Replaces the procedure (e.g. a user-supplied JSON document) and resets training.
    public func load(procedure: Procedure) {
        training = TrainingSession(procedure: procedure, language: procedure.languages.contains(training.language)
                                   ? training.language : procedure.sourceLanguage)
        lastAnswer = nil
        log.record(.warehouse, .info, "Loaded procedure \(procedure.id) v\(procedure.version)")
    }

    // MARK: Task queue passthrough (user actions from the Tasks view)

    @discardableResult
    public func addTask(title: String, detail: String = "", source: TaskSource = .assistant) throws -> RelayTask {
        try tasks.add(title: title, detail: detail, source: source)
    }

    public func transitionTask(_ id: UUID, to state: TaskState, note: String = "") throws {
        try tasks.transition(id, to: state, note: note)
    }

    // MARK: Pipeline

    public func handle(_ input: HeardInput) async -> Interaction {
        ensureTools()
        log.record(.assistant, .heard, input.text, details: ["source": input.source.label])
        let understanding = await reasoner.interpret(input.text, context: ReasoningContext(
            trainingActive: training.currentIndex != nil, language: training.language))
        log.record(.assistant, .understood, understanding.intent.label,
                   details: ["confidence": String(format: "%.2f", understanding.confidence),
                             "why": understanding.explanation, "engine": understanding.engine])
        let plan = planner.plan(for: understanding)
        log.record(.assistant, .planned, plan.summary,
                   details: ["steps": plan.steps.map(\.toolName).joined(separator: ", ")])

        var interaction = Interaction(id: UUID(), heard: input, understanding: understanding, plan: plan, attempts: [],
                                      reply: "", status: .completed, taskID: nil, createdAt: Date())
        if plan.steps.isEmpty {
            interaction.status = .notUnderstood
            interaction.reply = "I did not understand that, so I did nothing. Say \u{201C}help\u{201D} to hear what I can do."
            log.record(.assistant, .info, "No action taken: request not understood")
        } else {
            for step in plan.steps where registry.descriptor(for: step.toolName)?.requiresApproval == true {
                let task = try? tasks.add(title: step.rationale, detail: input.text, source: .assistant,
                                          initialState: .awaitingApproval)
                interaction.taskID = task?.id
            }
            await run(&interaction, approved: false)
        }
        interactions.append(interaction)
        return interaction
    }

    /// Approves a pending interaction and runs its remaining steps.
    public func approve(_ id: UUID) async -> Interaction? {
        guard let index = interactions.firstIndex(where: { $0.id == id }),
              interactions[index].status == .awaitingApproval else { return nil }
        var interaction = interactions[index]
        log.record(.assistant, .info, "Approved: \(interaction.plan.summary)")
        if let taskID = interaction.taskID { try? tasks.transition(taskID, to: .inProgress, note: "Approved by user") }
        interaction.attempts.removeAll { $0.status == .awaitingApproval }
        await run(&interaction, approved: true)
        interactions[index] = interaction
        return interaction
    }

    public func decline(_ id: UUID) -> Interaction? {
        guard let index = interactions.firstIndex(where: { $0.id == id }),
              interactions[index].status == .awaitingApproval else { return nil }
        interactions[index].status = .declined
        interactions[index].reply = "Declined. Nothing was done."
        interactions[index].attempts = interactions[index].attempts.map {
            $0.status == .awaitingApproval ? ToolAttempt(step: $0.step, status: .declined, output: "Declined by user") : $0
        }
        if let taskID = interactions[index].taskID { try? tasks.transition(taskID, to: .cancelled, note: "Declined by user") }
        log.record(.assistant, .info, "Declined: \(interactions[index].plan.summary)")
        return interactions[index]
    }

    private func run(_ interaction: inout Interaction, approved: Bool) async {
        var replies: [String] = []
        let alreadyDone = Set(interaction.attempts.filter { $0.status != .awaitingApproval }.map(\.step))
        for step in interaction.plan.steps where !alreadyDone.contains(step) {
            let attempt = await registry.execute(step, approved: approved)
            interaction.attempts.append(attempt)
            replies.append(attempt.output)
            let kind: LogKind
            switch attempt.status {
            case .succeeded: kind = .succeeded
            case .failed, .unknownTool: kind = .failed
            case .needsAttention: kind = .needsAttention
            case .awaitingApproval, .declined: kind = .info
            }
            log.record(.assistant, .attempted, "\(step.toolName): \(attempt.status.rawValue)")
            log.record(.assistant, kind, attempt.output, details: ["tool": step.toolName])
            if attempt.status == .awaitingApproval {
                interaction.status = .awaitingApproval
                interaction.reply = "This needs your approval: \(step.rationale)."
                return
            }
            if attempt.status == .failed || attempt.status == .unknownTool { interaction.status = .failed; break }
            if attempt.status == .needsAttention { interaction.status = .needsAttention }
        }
        if interaction.status == .awaitingApproval { interaction.status = .completed }
        if let taskID = interaction.taskID, let task = tasks.task(taskID), !task.state.isTerminal {
            let target: TaskState = interaction.status == .failed ? .failed : .succeeded
            if task.state == .awaitingApproval { try? tasks.transition(taskID, to: .inProgress) }
            try? tasks.transition(taskID, to: target, note: replies.last ?? "")
        }
        interaction.reply = replies.joined(separator: "\n")
    }

    // MARK: Tools

    private func ensureTools() {
        guard registry.descriptors.isEmpty else { return }
        registry = ToolRegistry(makeTools())
    }

    private func makeTools() -> [Tool] {
        [
            ClosureTool(name: "warehouse.start", summary: "Start the training procedure at step 1") { [weak self] _ in
                guard let self else { return ToolOutput(reply: "Unavailable") }
                return await self.navigate { $0.start() }
            },
            ClosureTool(name: "warehouse.next", summary: "Next step (blocked until safety warnings are acknowledged)") { [weak self] _ in
                guard let self else { return ToolOutput(reply: "Unavailable") }
                return await self.navigate { $0.next() }
            },
            ClosureTool(name: "warehouse.previous", summary: "Previous step") { [weak self] _ in
                guard let self else { return ToolOutput(reply: "Unavailable") }
                return await self.navigate { $0.previous() }
            },
            ClosureTool(name: "warehouse.repeat", summary: "Repeat the current step") { [weak self] _ in
                guard let self else { return ToolOutput(reply: "Unavailable") }
                return await self.navigate { $0.repeatCurrent() }
            },
            ClosureTool(name: "warehouse.acknowledge", summary: "Acknowledge the current step's safety warnings") { [weak self] _ in
                guard let self else { return ToolOutput(reply: "Unavailable") }
                return await self.acknowledge()
            },
            ClosureTool(name: "warehouse.ask", summary: "Answer from the procedure with a citation, or escalate") { [weak self] args in
                guard let self else { return ToolOutput(reply: "Unavailable") }
                return await self.ask(args["question"] ?? "")
            },
            ClosureTool(name: "warehouse.language", summary: "Change the training language") { [weak self] args in
                guard let self else { return ToolOutput(reply: "Unavailable") }
                return await self.setLanguage(args["code"] ?? "en")
            },
            ClosureTool(name: "tasks.add", summary: "Add a task to the visible queue") { [weak self] args in
                guard let self else { return ToolOutput(reply: "Unavailable") }
                return try await self.addTaskTool(args["title"] ?? "")
            },
            ClosureTool(name: "wybe.simulate", summary: "Run one simulated Night Shift (simulation only)",
                        requiresApproval: true) { [simulate] _ in
                guard let simulate else {
                    return ToolOutput(reply: "The simulation runner is not connected in this context.", needsAttention: true)
                }
                return ToolOutput(reply: await simulate())
            },
            ClosureTool(name: "wybe.stop", summary: "Stop the Wybe runner") { [stopRunner] _ in
                ToolOutput(reply: stopRunner?() ?? "No runner is active.")
            },
            ClosureTool(name: "assistant.help", summary: "List capabilities") { _ in
                ToolOutput(reply: """
                    I can guide warehouse training one step at a time (start, next, back, repeat, \u{201C}understood\u{201D}), \
                    answer questions only from the loaded procedure with the step that supports the answer, switch \
                    language (English, norsk, polski), add tasks, and run the Wybe simulation after you approve it. \
                    I cannot control your computer, run programs or browse files.
                    """)
            },
        ]
    }

    private func navigate(_ action: (inout TrainingSession) -> NavigationResult) -> ToolOutput {
        let result = action(&training)
        lastAnswer = nil
        switch result {
        case let .step(rendered):
            log.record(.warehouse, .info, "Showing \(rendered.stepID) in \(rendered.language)")
            return ToolOutput(reply: ProcedureRenderer.plainText(rendered))
        case let .needsAcknowledgement(rendered):
            let warnings = rendered.warnings.filter { $0.severity == .critical }.map(\.text).joined(separator: " ")
            return ToolOutput(reply: TrainingPhrases.text(.acknowledgeFirst, training.language) + " " + warnings,
                              needsAttention: true)
        case let .finished(text), let .notice(text):
            return ToolOutput(reply: text)
        }
    }

    private func acknowledge() -> ToolOutput {
        guard training.currentStep != nil else { return ToolOutput(reply: TrainingPhrases.text(.notStarted, training.language)) }
        let ids = training.unacknowledgedCritical.map(\.id)
        training.acknowledgeCurrentWarnings()
        log.record(.warehouse, .info, ids.isEmpty ? "Nothing to acknowledge" : "Acknowledged \(ids.joined(separator: ", "))")
        return ToolOutput(reply: ids.isEmpty ? "No safety warning is waiting for confirmation."
                                             : "Thanks. Say \u{201C}next\u{201D} to continue.")
    }

    private func ask(_ question: String) -> ToolOutput {
        let answer = training.ask(question)
        lastAnswer = answer
        switch answer {
        case let .answer(_, citation, _):
            log.record(.warehouse, .succeeded, "Answered from \(citation.stepID)", details: ["question": question])
            return ToolOutput(reply: answer.spokenText)
        case let .clarification(_, options):
            log.record(.warehouse, .needsAttention, "Asked for clarification",
                       details: ["question": question, "options": options.map(\.stepID).joined(separator: ",")])
            return ToolOutput(reply: answer.spokenText, needsAttention: true)
        case let .escalation(message, topic):
            let task = try? tasks.add(title: "Escalation: \(topic)", detail: message, source: .warehouse,
                                      initialState: .needsAttention)
            log.record(.warehouse, .needsAttention, "Escalated: procedure does not answer this",
                       details: ["question": topic, "task": task?.id.uuidString ?? "-"])
            return ToolOutput(reply: message, needsAttention: true)
        }
    }

    private func setLanguage(_ code: String) -> ToolOutput {
        guard training.procedure.languages.contains(code) else {
            return ToolOutput(reply: "The procedure has no \(SupportedLanguage.name(code)) text. Available: "
                              + training.procedure.languages.map(SupportedLanguage.name).joined(separator: ", "),
                              needsAttention: true)
        }
        training.setLanguage(code)
        log.record(.warehouse, .info, "Language set to \(code)")
        if let rendered = training.currentRendered { return ToolOutput(reply: ProcedureRenderer.plainText(rendered)) }
        return ToolOutput(reply: "Language: \(SupportedLanguage.name(code)).")
    }

    private func addTaskTool(_ title: String) throws -> ToolOutput {
        let task = try tasks.add(title: title, source: .assistant)
        return ToolOutput(reply: "Added to the task queue: \(task.title)")
    }
}
