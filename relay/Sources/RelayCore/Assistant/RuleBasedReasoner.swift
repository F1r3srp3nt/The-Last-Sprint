import Foundation

/// Deterministic phrase matching. Not a language model.
///
/// Recognises a small fixed command set in English, Norwegian (bokmål) and Polish. Anything
/// else during training is treated as a question for the procedure answerer; outside training
/// it is reported as not understood.
public struct RuleBasedReasoner: Reasoner {
    public let engineName = "Relay rules (deterministic, no language model)"

    public init() {}

    private static let exact: [(Intent, [String])] = [
        (.startTraining, ["start", "begin", "start training", "begin training", "start the training", "start opplæring",
                          "start opplæringen", "begynn", "zacznij", "start szkolenia", "zacznij szkolenie"]),
        (.nextStep, ["next", "next step", "continue", "go on", "neste", "neste trinn", "fortsett", "dalej",
                     "następny", "następny krok", "kontynuuj"]),
        (.previousStep, ["back", "previous", "previous step", "go back", "tilbake", "forrige", "forrige trinn",
                         "wstecz", "poprzedni", "poprzedni krok", "cofnij"]),
        (.repeatStep, ["repeat", "again", "say again", "repeat that", "repeat step", "gjenta", "si igjen", "powtórz",
                       "jeszcze raz"]),
        (.acknowledgeWarning, ["understood", "i understand", "confirm", "confirmed", "ok understood", "got it",
                               "forstått", "jeg forstår", "bekreftet", "rozumiem", "potwierdzam", "zrozumiałem",
                               "zrozumiałam"]),
        (.stopRunner, ["stop", "stop runner", "stop the runner", "stop simulation", "stop the simulation", "stopp",
                       "zatrzymaj"]),
        (.help, ["help", "what can you do", "hjelp", "pomoc"]),
    ]

    private static let languages: [(String, [String])] = [
        ("en", ["english", "engelsk", "angielski", "in english", "po angielsku"]),
        ("nb", ["norwegian", "norsk", "bokmål", "på norsk", "norweski", "po norwesku"]),
        ("pl", ["polish", "polsk", "polski", "på polsk", "po polsku"]),
    ]

    private static let questionStarters: Set<String> = [
        "what", "how", "where", "when", "why", "who", "which", "can", "should", "do", "does", "is", "are", "must",
        "hva", "hvordan", "hvor", "når", "hvorfor", "hvem", "kan", "skal", "må", "er",
        "co", "jak", "gdzie", "kiedy", "dlaczego", "kto", "czy", "mogę", "muszę",
    ]

    static func normalize(_ text: String) -> String {
        let trimmed = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:\u{201D}\u{201C}\"'"))
        return stripped.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
    }

    public func interpret(_ utterance: String, context: ReasoningContext) async -> Understanding {
        let raw = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = Self.normalize(raw)
        func understood(_ intent: Intent, _ confidence: Double, _ why: String) -> Understanding {
            Understanding(intent: intent, confidence: confidence, explanation: why, engine: engineName)
        }
        guard !text.isEmpty else { return understood(.unknown(raw), 0, "Empty input") }

        for (intent, phrases) in Self.exact where phrases.contains(text) {
            return understood(intent, 0.95, "Matched the command phrase \u{201C}\(text)\u{201D}")
        }

        // Language switch: "switch to polish", "language: norsk", "po polsku".
        let languageCue = ["language", "switch to", "speak", "språk", "bytt til", "język", "zmień na"].contains { text.contains($0) }
        for (code, names) in Self.languages {
            if names.contains(text) || (languageCue && names.contains(where: { text.contains($0) })) {
                return understood(.setLanguage(code), 0.9, "Asked for \(SupportedLanguage.name(code))")
            }
        }

        for prefix in ["add task ", "add a task ", "new task ", "remind me to ", "todo ", "legg til oppgave ", "dodaj zadanie "]
        where text.hasPrefix(prefix) {
            let title = String(raw.dropFirst(min(prefix.count, raw.count))).trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { return understood(.unknown(raw), 0.3, "Task request without a title") }
            return understood(.addTask(title), 0.9, "Starts with \u{201C}\(prefix.trimmingCharacters(in: .whitespaces))\u{201D}")
        }

        let simulationWords = ["simulation", "simulate", "simulering", "symulacj"]
        if (text.contains("run") || text.contains("start") || text.contains("kjør") || text.contains("uruchom"))
            && simulationWords.contains(where: { text.contains($0) }) {
            return understood(.runSimulation, 0.85, "Asked to run the simulation")
        }

        let firstWord = text.split(separator: " ").first.map(String.init) ?? ""
        if raw.hasSuffix("?") || Self.questionStarters.contains(firstWord) {
            return understood(.askProcedure(raw), 0.7, "Phrased as a question; will look it up in the procedure")
        }
        if context.trainingActive {
            return understood(.askProcedure(raw), 0.5, "Training is active, so treating this as a question about the procedure")
        }
        return understood(.unknown(raw), 0.2, "No rule matched")
    }
}

/// Maps intents to tool steps. One intent → at most one step in this milestone.
public struct DefaultTaskPlanner: TaskPlanner {
    public init() {}

    public func plan(for understanding: Understanding) -> Plan {
        func one(_ tool: String, _ args: [String: String] = [:], _ why: String) -> Plan {
            Plan(summary: why, steps: [PlannedStep(toolName: tool, arguments: args, rationale: why)])
        }
        switch understanding.intent {
        case .startTraining: return one("warehouse.start", [:], "Show step 1 of the procedure")
        case .nextStep: return one("warehouse.next", [:], "Move to the next step if safety warnings are acknowledged")
        case .previousStep: return one("warehouse.previous", [:], "Go back one step")
        case .repeatStep: return one("warehouse.repeat", [:], "Repeat the current step")
        case .acknowledgeWarning: return one("warehouse.acknowledge", [:], "Record that the safety warning was acknowledged")
        case let .askProcedure(q): return one("warehouse.ask", ["question": q], "Answer only from the procedure, with a citation, or escalate")
        case let .setLanguage(code): return one("warehouse.language", ["code": code], "Present the procedure in \(SupportedLanguage.name(code))")
        case let .addTask(title): return one("tasks.add", ["title": title], "Add a task to the queue")
        case .runSimulation: return one("wybe.simulate", [:], "Run one simulated Night Shift (needs approval)")
        case .stopRunner: return one("wybe.stop", [:], "Stop the Wybe runner before its next action")
        case .help: return one("assistant.help", [:], "List what Relay can do")
        case .unknown: return Plan(summary: "Nothing will be done because the request was not understood.", steps: [])
        }
    }
}
