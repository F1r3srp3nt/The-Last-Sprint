import Foundation

// MARK: - Rendering (warning preservation)

public struct RenderedWarning: Sendable, Equatable, Identifiable {
    public let id: String
    public let severity: WarningSeverity
    public let text: String
    /// True when the worker's language was missing and the source-language warning is shown.
    public let isFallback: Bool
}

public struct RenderedStep: Sendable, Equatable {
    public let stepID: String
    public let position: Int
    public let total: Int
    public let title: String
    public let instruction: String
    public let warnings: [RenderedWarning]
    public let language: String
    public let usedFallback: Bool
}

/// Presents procedure steps in a worker's language.
///
/// Invariant (tested): every warning in the source document appears in every rendering,
/// in every language. A missing translation never drops a warning — the source text is
/// shown instead, clearly marked.
public enum ProcedureRenderer {
    public static func render(_ step: ProcedureStep, in procedure: Procedure, language: String) -> RenderedStep {
        let source = procedure.sourceLanguage
        let title = step.title.resolve(language, source: source)
        let instruction = step.instruction.resolve(language, source: source)
        // Critical warnings first, then cautions, preserving document order within each group.
        let ordered = step.warnings.filter { $0.severity == .critical } + step.warnings.filter { $0.severity != .critical }
        let warnings = ordered.map { warning -> RenderedWarning in
            let resolved = warning.text.resolve(language, source: source)
            return RenderedWarning(id: warning.id, severity: warning.severity, text: resolved.text,
                                   isFallback: resolved.isFallback)
        }
        let index = procedure.steps.firstIndex(where: { $0.id == step.id }) ?? 0
        return RenderedStep(stepID: step.id, position: index + 1, total: procedure.steps.count,
                            title: title.text, instruction: instruction.text, warnings: warnings,
                            language: language,
                            usedFallback: title.isFallback || instruction.isFallback || warnings.contains { $0.isFallback })
    }

    /// Plain-text form used for speech and the command-line demo. Critical warnings are spoken first.
    public static func plainText(_ rendered: RenderedStep) -> String {
        let p = TrainingPhrases.self
        var lines: [String] = []
        for warning in rendered.warnings where warning.severity == .critical {
            lines.append("\(p.text(.criticalPrefix, rendered.language)) \(warning.text)")
        }
        lines.append("\(p.text(.stepWord, rendered.language)) \(rendered.position)/\(rendered.total): \(rendered.title).")
        lines.append(rendered.instruction)
        for warning in rendered.warnings where warning.severity == .caution {
            lines.append("\(p.text(.cautionPrefix, rendered.language)) \(warning.text)")
        }
        if rendered.usedFallback {
            lines.append(p.text(.fallbackNotice, rendered.language))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Fixed phrases used around procedure text

public enum TrainingPhrases {
    public enum Key: Sendable {
        case criticalPrefix, cautionPrefix, stepWord, fallbackNotice, notCovered, askContact, clarify, clarifyVague
        case finished, acknowledgeFirst, notStarted, atFirstStep, source
    }

    private static let table: [Key: [String: String]] = [
        .criticalPrefix: ["en": "SAFETY:", "nb": "SIKKERHET:", "pl": "BEZPIECZEŃSTWO:"],
        .cautionPrefix: ["en": "Note:", "nb": "Merk:", "pl": "Uwaga:"],
        .stepWord: ["en": "Step", "nb": "Trinn", "pl": "Krok"],
        .fallbackNotice: ["en": "Some text is shown in the original language because no translation was supplied.",
                          "nb": "Noe tekst vises på originalspråket fordi ingen oversettelse er levert.",
                          "pl": "Część tekstu jest w języku oryginalnym, ponieważ nie dostarczono tłumaczenia."],
        .notCovered: ["en": "The procedure does not answer this.", "nb": "Prosedyren svarer ikke på dette.",
                      "pl": "Procedura nie odpowiada na to pytanie."],
        .askContact: ["en": "Please ask", "nb": "Spør", "pl": "Zapytaj"],
        .clarify: ["en": "Do you mean one of these steps?", "nb": "Mener du ett av disse trinnene?",
                   "pl": "Czy chodzi ci o jeden z tych kroków?"],
        .clarifyVague: ["en": "Could you say which item or step you are asking about?",
                        "nb": "Kan du si hvilken del eller hvilket trinn du spør om?",
                        "pl": "Czy możesz powiedzieć, o który element lub krok pytasz?"],
        .finished: ["en": "That was the last step. Training complete.", "nb": "Det var siste trinn. Opplæringen er fullført.",
                    "pl": "To był ostatni krok. Szkolenie zakończone."],
        .acknowledgeFirst: ["en": "Please confirm you understood the safety warning before we continue.",
                            "nb": "Bekreft at du har forstått sikkerhetsadvarselen før vi fortsetter.",
                            "pl": "Potwierdź, że rozumiesz ostrzeżenie bezpieczeństwa, zanim przejdziemy dalej."],
        .notStarted: ["en": "Training has not started yet.", "nb": "Opplæringen har ikke startet ennå.",
                      "pl": "Szkolenie jeszcze się nie rozpoczęło."],
        .atFirstStep: ["en": "This is already the first step.", "nb": "Dette er allerede første trinn.",
                       "pl": "To już jest pierwszy krok."],
        .source: ["en": "Source", "nb": "Kilde", "pl": "Źródło"],
    ]

    public static func text(_ key: Key, _ language: String) -> String {
        table[key]?[language] ?? table[key]?["en"] ?? ""
    }
}

// MARK: - Question answering (deterministic, procedure-grounded)

public struct Citation: Sendable, Equatable {
    public let stepID: String
    public let stepTitle: String
    /// The instruction text of the cited step, in the displayed language.
    public let quote: String
    public let isFallback: Bool
}

public enum TrainingAnswer: Sendable, Equatable {
    /// The procedure answers the question. `warnings` are the supporting step's warnings,
    /// always included so an answer never strips safety context.
    case answer(text: String, citation: Citation, warnings: [RenderedWarning])
    /// The question matches several parts of the procedure, or is too vague.
    case clarification(prompt: String, options: [Citation])
    /// The procedure does not cover this. A person must answer.
    case escalation(message: String, topic: String)

    public var spokenText: String {
        switch self {
        case let .answer(text, citation, warnings):
            let critical = warnings.filter { $0.severity == .critical }.map(\.text)
            return ([text] + critical).joined(separator: " ") + " (\(citation.stepID))"
        case let .clarification(prompt, options):
            return ([prompt] + options.map { "\($0.stepID): \($0.stepTitle)" }).joined(separator: " ")
        case let .escalation(message, _):
            return message
        }
    }
}

/// Answers worker questions strictly from the supplied procedure using keyword matching.
///
/// This is deliberately not a language model. It can only return text the procedure author
/// wrote; anything it cannot ground in the document is escalated to a person.
public struct ProcedureAnswerer: Sendable {
    public let procedure: Procedure

    public init(procedure: Procedure) { self.procedure = procedure }

    private static let stopwords: Set<String> = Set([
        // en
        "a", "an", "the", "i", "we", "you", "it", "is", "are", "do", "does", "did", "what", "how", "when", "why",
        "who", "which", "should", "can", "could", "would", "to", "of", "in", "on", "at", "for", "with", "and", "or",
        "if", "my", "me", "this", "that", "there", "about", "be", "have", "has", "need", "so", "then", "now", "please",
        "tell", "say", "again", "any", "some", "from", "by", "as", "was", "will", "not", "no", "yes", "ok", "okay",
        // nb
        "jeg", "du", "vi", "det", "er", "hva", "hvordan", "hvor", "når", "hvorfor", "skal", "kan", "må", "en", "et",
        "ei", "og", "eller", "i", "på", "til", "med", "om", "av", "for", "den", "de", "som", "ikke", "meg", "har",
        // pl
        "co", "jak", "gdzie", "kiedy", "dlaczego", "czy", "mam", "mogę", "trzeba", "się", "to", "jest", "na", "w",
        "z", "do", "i", "lub", "ja", "ty", "nie", "tak", "o", "po", "ten", "ta", "jeśli",
    ])

    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || scalar == "-"
                ? Character(scalar) : " "
        }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    static func contentTokens(_ normalized: String) -> [String] {
        normalized.split(separator: " ").map(String.init).filter { !stopwords.contains($0) }
    }

    /// Weighted match of one keyword (word or phrase) against a normalized question.
    static func matches(keyword: String, normalizedQuestion: String, tokens: [String]) -> Int {
        let kw = normalize(keyword)
        guard !kw.isEmpty else { return 0 }
        let words = kw.split(separator: " ")
        if words.count > 1 {
            return " \(normalizedQuestion) ".contains(" \(kw) ") ? words.count : 0
        }
        // Single word: exact token, or prefix (stem) match for keywords of 4+ characters.
        let hit = tokens.contains { $0 == kw || (kw.count >= 4 && $0.hasPrefix(kw)) }
        return hit ? 1 : 0
    }

    public func answer(_ question: String, language: String) -> TrainingAnswer {
        let normalized = Self.normalize(question)
        let allTokens = normalized.split(separator: " ").map(String.init)
        let content = Self.contentTokens(normalized)
        let p = TrainingPhrases.self
        let contact = procedure.escalationContact.resolve(language, source: procedure.sourceLanguage).text

        guard !content.isEmpty else {
            return .clarification(prompt: p.text(.clarifyVague, language), options: [])
        }

        // Score anticipated facts.
        let scored: [(fact: ProcedureFact, score: Int)] = procedure.facts.map { fact in
            let score = fact.keywords.reduce(0) { $0 + Self.matches(keyword: $1, normalizedQuestion: normalized, tokens: allTokens) }
            return (fact, score)
        }.filter { $0.score > 0 }.sorted { $0.score > $1.score }

        if let best = scored.first {
            let rivals = scored.dropFirst().filter { $0.score == best.score && $0.fact.supportingStepID != best.fact.supportingStepID }
            if !rivals.isEmpty {
                let options = ([best] + Array(rivals)).compactMap { $0.fact.supportingStepID }
                    .compactMap { citation(for: $0, language: language) }
                if options.isEmpty || rivals.contains(where: { $0.fact.kind == .outOfScope }) || best.fact.kind == .outOfScope {
                    // A tie involving an out-of-scope topic: do not guess, escalate.
                    return escalation(topic: question, language: language, contact: contact, detail: nil)
                }
                return .clarification(prompt: p.text(.clarify, language), options: options)
            }
            if best.fact.kind == .outOfScope {
                let detail = best.fact.answer.resolve(language, source: procedure.sourceLanguage).text
                return escalation(topic: question, language: language, contact: contact, detail: detail)
            }
            if let stepID = best.fact.supportingStepID, let step = procedure.step(stepID),
               let citation = citation(for: stepID, language: language) {
                let text = best.fact.answer.resolve(language, source: procedure.sourceLanguage).text
                let rendered = ProcedureRenderer.render(step, in: procedure, language: language)
                return .answer(text: text, citation: citation, warnings: rendered.warnings)
            }
        }

        // No anticipated fact: fall back to strong word overlap with a single step.
        let questionWords = Set(content.filter { $0.count >= 4 })
        let stepScores: [(ProcedureStep, Int)] = procedure.steps.map { step in
            let corpus = [step.title.resolve(language, source: procedure.sourceLanguage).text,
                          step.instruction.resolve(language, source: procedure.sourceLanguage).text,
                          step.title.values[procedure.sourceLanguage] ?? "",
                          step.instruction.values[procedure.sourceLanguage] ?? ""].joined(separator: " ")
            let words = Set(Self.contentTokens(Self.normalize(corpus)))
            return (step, questionWords.intersection(words).count)
        }.sorted { $0.1 > $1.1 }
        if let top = stepScores.first, top.1 >= 2 {
            if stepScores.count > 1, stepScores[1].1 == top.1 {
                let options = stepScores.prefix(while: { $0.1 == top.1 }).compactMap { citation(for: $0.0.id, language: language) }
                return .clarification(prompt: p.text(.clarify, language), options: Array(options))
            }
            if let citation = citation(for: top.0.id, language: language) {
                let rendered = ProcedureRenderer.render(top.0, in: procedure, language: language)
                return .answer(text: rendered.instruction, citation: citation, warnings: rendered.warnings)
            }
        }
        return escalation(topic: question, language: language, contact: contact, detail: nil)
    }

    private func escalation(topic: String, language: String, contact: String, detail: String?) -> TrainingAnswer {
        let p = TrainingPhrases.self
        var parts: [String] = []
        if let detail { parts.append(detail) } else { parts.append(p.text(.notCovered, language)) }
        parts.append("\(p.text(.askContact, language)) \(contact).")
        return .escalation(message: parts.joined(separator: " "), topic: topic)
    }

    func citation(for stepID: String, language: String) -> Citation? {
        guard let step = procedure.step(stepID) else { return nil }
        let title = step.title.resolve(language, source: procedure.sourceLanguage)
        let quote = step.instruction.resolve(language, source: procedure.sourceLanguage)
        return Citation(stepID: step.id, stepTitle: title.text, quote: quote.text,
                        isFallback: title.isFallback || quote.isFallback)
    }
}

// MARK: - Step-by-step session

public enum NavigationResult: Sendable, Equatable {
    case step(RenderedStep)
    /// Safety warnings on the current step must be acknowledged before advancing.
    case needsAcknowledgement(RenderedStep)
    case finished(String)
    case notice(String)
}

/// Deterministic, one-step-at-a-time navigation through a procedure.
public struct TrainingSession: Sendable {
    public let procedure: Procedure
    public private(set) var language: String
    /// `nil` before the first step is shown.
    public private(set) var currentIndex: Int?
    public private(set) var acknowledgedWarnings: Set<String> = []
    public private(set) var isFinished = false

    public init(procedure: Procedure, language: String) {
        self.procedure = procedure
        self.language = language
    }

    public var answerer: ProcedureAnswerer { ProcedureAnswerer(procedure: procedure) }

    public var currentStep: ProcedureStep? { currentIndex.map { procedure.steps[$0] } }

    public var currentRendered: RenderedStep? {
        currentStep.map { ProcedureRenderer.render($0, in: procedure, language: language) }
    }

    public var unacknowledgedCritical: [ProcedureWarning] {
        currentStep?.criticalWarnings.filter { !acknowledgedWarnings.contains($0.id) } ?? []
    }

    public mutating func setLanguage(_ code: String) { language = code }

    public mutating func start() -> NavigationResult {
        currentIndex = 0
        isFinished = false
        acknowledgedWarnings = []
        return .step(currentRendered!)
    }

    public mutating func acknowledgeCurrentWarnings() {
        for warning in currentStep?.criticalWarnings ?? [] { acknowledgedWarnings.insert(warning.id) }
    }

    public mutating func next() -> NavigationResult {
        guard let index = currentIndex else { return start() }
        if !unacknowledgedCritical.isEmpty, let rendered = currentRendered {
            return .needsAcknowledgement(rendered)
        }
        if index + 1 >= procedure.steps.count {
            isFinished = true
            return .finished(TrainingPhrases.text(.finished, language))
        }
        currentIndex = index + 1
        return .step(currentRendered!)
    }

    public mutating func previous() -> NavigationResult {
        guard let index = currentIndex else { return .notice(TrainingPhrases.text(.notStarted, language)) }
        guard index > 0 else { return .notice(TrainingPhrases.text(.atFirstStep, language)) }
        currentIndex = index - 1
        isFinished = false
        return .step(currentRendered!)
    }

    public func repeatCurrent() -> NavigationResult {
        guard let rendered = currentRendered else { return .notice(TrainingPhrases.text(.notStarted, language)) }
        return .step(rendered)
    }

    public func ask(_ question: String) -> TrainingAnswer {
        answerer.answer(question, language: language)
    }
}
