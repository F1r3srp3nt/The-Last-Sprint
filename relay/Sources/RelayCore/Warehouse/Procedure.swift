import Foundation

/// Text supplied by the procedure author in one or more languages.
/// Relay never machine-translates procedure text in this milestone; it only shows what the
/// document contains, falling back to the source language when a translation is missing.
public struct LocalizedText: Codable, Sendable, Equatable {
    public var values: [String: String]

    public init(_ values: [String: String]) { self.values = values }

    public func resolve(_ language: String, source: String) -> ResolvedText {
        if let text = values[language], !text.isEmpty {
            return ResolvedText(text: text, language: language, isFallback: false)
        }
        return ResolvedText(text: values[source] ?? values.values.sorted().first ?? "", language: source,
                            isFallback: language != source)
    }
}

public struct ResolvedText: Sendable, Equatable {
    public let text: String
    public let language: String
    /// True when the requested language was missing and the source text is shown instead.
    public let isFallback: Bool
}

public enum WarningSeverity: String, Codable, Sendable {
    /// Safety-critical: always shown, must be acknowledged before moving on.
    case critical
    case caution
}

public struct ProcedureWarning: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let severity: WarningSeverity
    public let text: LocalizedText
}

public struct ProcedureStep: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: LocalizedText
    public let instruction: LocalizedText
    public let warnings: [ProcedureWarning]

    public var criticalWarnings: [ProcedureWarning] { warnings.filter { $0.severity == .critical } }
}

/// A question the procedure author anticipated, tied to the step that supports the answer.
public struct ProcedureFact: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// The procedure answers this question.
        case answer
        /// The procedure explicitly does NOT cover this; the worker must ask a person.
        case outOfScope
    }

    public let id: String
    public let kind: Kind
    /// Lower-case keywords or short phrases (any supported language) that indicate this topic.
    public let keywords: [String]
    public let answer: LocalizedText
    /// Step that supports the answer (`nil` for out-of-scope facts).
    public let supportingStepID: String?
}

/// A training procedure document. Loaded from JSON or built in code (see `DemoProcedure`).
public struct Procedure: Codable, Sendable, Equatable {
    public let id: String
    public let title: LocalizedText
    public let version: String
    public let sourceLanguage: String
    /// Languages the author provided text for.
    public let languages: [String]
    /// Shown at the top of every training session (e.g. "demonstration material").
    public let disclaimer: LocalizedText
    public let escalationContact: LocalizedText
    public let steps: [ProcedureStep]
    public let facts: [ProcedureFact]

    public func step(_ id: String) -> ProcedureStep? { steps.first { $0.id == id } }

    public static func load(from data: Data) throws -> Procedure {
        let procedure = try JSONDecoder().decode(Procedure.self, from: data)
        try procedure.validate()
        return procedure
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case noSteps
        case duplicateStepID(String)
        case unknownSupportingStep(fact: String, step: String)
        case missingSourceText(String)

        public var description: String {
            switch self {
            case .noSteps: return "Procedure has no steps"
            case let .duplicateStepID(id): return "Duplicate step id \(id)"
            case let .unknownSupportingStep(fact, step): return "Fact \(fact) cites unknown step \(step)"
            case let .missingSourceText(where_): return "Missing source-language text in \(where_)"
            }
        }
    }

    /// Rejects documents Relay could not present faithfully.
    public func validate() throws {
        guard !steps.isEmpty else { throw ValidationError.noSteps }
        var seen = Set<String>()
        for step in steps {
            guard seen.insert(step.id).inserted else { throw ValidationError.duplicateStepID(step.id) }
            if step.instruction.values[sourceLanguage]?.isEmpty ?? true {
                throw ValidationError.missingSourceText("step \(step.id) instruction")
            }
            for warning in step.warnings where warning.text.values[sourceLanguage]?.isEmpty ?? true {
                throw ValidationError.missingSourceText("warning \(warning.id)")
            }
        }
        for fact in facts {
            if let stepID = fact.supportingStepID, step(stepID) == nil {
                throw ValidationError.unknownSupportingStep(fact: fact.id, step: stepID)
            }
        }
    }
}

public enum SupportedLanguage {
    public static let names: [String: String] = ["en": "English", "nb": "Norsk bokmål", "pl": "Polski"]
    public static func name(_ code: String) -> String { names[code] ?? code }
}
