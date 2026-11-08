import Foundation

public struct ProjectDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3
    public static let maxLibraryItems = 500
    public static let maxExperiments = 500

    public var schemaVersion: Int
    /// Free-text description of the project (for example a demonstration label).
    public var notes: String
    public var draft: Draft
    public var settings: SelectionSettings
    /// Expected facts and checks for the current task, copied into new experiments.
    public var reviewTemplate: ReviewTemplate
    public var library: [ContextBlock]
    public var experiments: [Experiment]
    /// Original pasted material, kept exactly so it can be recovered after splitting into blocks.
    /// Added after schema 3 was introduced; files without it load with an empty list.
    public var pastedSources: [PastedSource]

    public init(notes: String = "", draft: Draft = Draft(), settings: SelectionSettings = SelectionSettings(),
                reviewTemplate: ReviewTemplate = ReviewTemplate(),
                library: [ContextBlock] = [], experiments: [Experiment] = [], pastedSources: [PastedSource] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.notes = notes; self.draft = draft; self.settings = settings; self.reviewTemplate = reviewTemplate
        self.library = library; self.experiments = experiments; self.pastedSources = pastedSources
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        notes = try c.decode(String.self, forKey: .notes)
        draft = try c.decode(Draft.self, forKey: .draft)
        settings = try c.decode(SelectionSettings.self, forKey: .settings)
        reviewTemplate = try c.decode(ReviewTemplate.self, forKey: .reviewTemplate)
        library = try c.decode([ContextBlock].self, forKey: .library)
        experiments = try c.decode([Experiment].self, forKey: .experiments)
        pastedSources = try c.decodeIfPresent([PastedSource].self, forKey: .pastedSources) ?? []
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw LabError.unsupportedSchema(found: schemaVersion, supported: Self.currentSchemaVersion)
        }
        try SelectionEngine.validate(draft)
        try settings.validate()
        guard library.count <= Self.maxLibraryItems else { throw LabError.invalid("The library is limited to \(Self.maxLibraryItems) items.") }
        guard experiments.count <= Self.maxExperiments else { throw LabError.invalid("A project is limited to \(Self.maxExperiments) experiments.") }
        guard Set(library.map(\.id)).count == library.count else { throw LabError.invalid("Library items contain duplicate identifiers.") }
        guard Set(experiments.map(\.id)).count == experiments.count else { throw LabError.invalid("Experiments contain duplicate identifiers.") }
        if let bad = library.first(where: { !ContextPriority.range.contains($0.priority) }) {
            throw LabError.invalid("Priority must be between 1 and 3 (library item “\(bad.title)” has \(bad.priority)).")
        }
        let libraryBytes = library.reduce(0) { $0 + $1.text.utf8.count }
        guard libraryBytes <= SelectionEngine.maxTextBytes * 2 else { throw LabError.invalid("Library text is limited to 4 MB in this prototype.") }
        for experiment in experiments { try experiment.validate() }
        guard Set(pastedSources.map(\.id)).count == pastedSources.count else {
            throw LabError.invalid("Pasted originals contain duplicate identifiers.")
        }
        guard pastedSources.reduce(0, { $0 + $1.text.utf8.count }) <= SelectionEngine.maxTextBytes * 2 else {
            throw LabError.invalid("Pasted originals are limited to 4 MB in this prototype.")
        }
    }
}

/// Reads and writes project files. Decoding never mutates anything: callers replace their state only
/// after this returns successfully.
public enum ProjectCodec {
    public static let maxFileBytes = 20_000_000

    public static func encode(_ document: ProjectDocument) throws -> Data {
        try document.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    /// The result of reading a file: the validated document and the schema version it was written with.
    public struct Loaded: Sendable {
        public var document: ProjectDocument
        public var sourceSchemaVersion: Int
        public var wasMigrated: Bool { sourceSchemaVersion != ProjectDocument.currentSchemaVersion }
    }

    public static func decode(_ data: Data) throws -> ProjectDocument { try load(data).document }

    public static func load(_ data: Data) throws -> Loaded {
        guard data.count <= maxFileBytes else { throw LabError.invalid("Project files are limited to 20 MB.") }
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw LabError.malformed("it is not a JSON project object.")
        }
        struct Probe: Decodable { var schemaVersion: Int? }
        let probe: Probe
        do { probe = try decoder().decode(Probe.self, from: data) }
        catch { throw LabError.malformed("schemaVersion must be a whole number.") }
        guard let version = probe.schemaVersion else {
            throw LabError.malformed("it has no schemaVersion, so it is not a project file from this app.")
        }
        let document: ProjectDocument
        switch version {
        case ProjectDocument.currentSchemaVersion:
            do { document = try decoder().decode(ProjectDocument.self, from: data) }
            catch { throw LabError.malformed(describe(error)) }
        case 2:
            // Schema 2 had no separate task. Nothing is guessed: the task starts empty everywhere and the
            // previous instructions (which may contain the request) are kept exactly as they were.
            let migrated: Data
            do { migrated = try LegacyV2.upgrade(data) }
            catch { throw LabError.malformed("schema 2 file could not be upgraded: \(error.localizedDescription)") }
            do { document = try decoder().decode(ProjectDocument.self, from: migrated) }
            catch { throw LabError.malformed(describe(error)) }
        case 1:
            let legacy: LegacyV1.Project
            // Schema 1 used JSONEncoder's default date format (seconds since 2001-01-01).
            do { legacy = try JSONDecoder().decode(LegacyV1.Project.self, from: data) }
            catch { throw LabError.malformed(describe(error)) }
            document = try LegacyV1.migrate(legacy)
        default:
            throw LabError.unsupportedSchema(found: version, supported: ProjectDocument.currentSchemaVersion)
        }
        try document.validate()
        return Loaded(document: document, sourceSchemaVersion: version)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Dates are stored to whole seconds so files round-trip exactly.
    public static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down))
    }

    static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            let p = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return p.isEmpty ? "the top level" : p
        }
        switch error {
        case .keyNotFound(let key, let context): return "missing “\(key.stringValue)” at \(path(context))."
        case .typeMismatch(_, let context): return "unexpected value type at \(path(context))."
        case .valueNotFound(_, let context): return "missing value at \(path(context))."
        case .dataCorrupted(let context): return "invalid value at \(path(context)): \(context.debugDescription)"
        @unknown default: return error.localizedDescription
        }
    }
}

/// Schema 2 → 3: add an empty `task` to the workspace draft and to every experiment's saved input, and
/// empty `notes` and `reviewTemplate`. Everything else, including snapshots and evaluations, is unchanged.
enum LegacyV2 {
    static func upgrade(_ data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LabError.malformed("not a JSON object.")
        }
        func addTask(_ value: Any?) -> Any? {
            guard var draft = value as? [String: Any] else { return value }
            if draft["task"] == nil { draft["task"] = "" }
            return draft
        }
        root["draft"] = addTask(root["draft"])
        if let experiments = root["experiments"] as? [[String: Any]] {
            root["experiments"] = experiments.map { experiment -> [String: Any] in
                var experiment = experiment
                if var snapshot = experiment["snapshot"] as? [String: Any] {
                    snapshot["input"] = addTask(snapshot["input"])
                    experiment["snapshot"] = snapshot
                }
                return experiment
            }
        }
        if root["notes"] == nil { root["notes"] = "" }
        if root["reviewTemplate"] == nil { root["reviewTemplate"] = ["expectedFacts": [String](), "correctnessChecks": [String]()] }
        root["schemaVersion"] = ProjectDocument.currentSchemaVersion
        return try JSONSerialization.data(withJSONObject: root)
    }
}

/// Schema 1, written by the unverified 0.2 skeleton. Workspace, budget and library migrate directly.
/// Experiments are re-run with the equivalent settings (approximate ÷4 counter, budget selection with
/// deduplication); the old manual label and notes are preserved in the reviewer notes.
enum LegacyV1 {
    struct V1Draft: Decodable { var instructions: String; var blocks: [ContextBlock]; var budget: Int }
    struct V1Report: Decodable { var input: V1Draft; var optimized: String }
    struct V1Experiment: Decodable { var id: UUID; var name: String; var createdAt: Date; var report: V1Report; var review: String; var notes: String }
    struct Project: Decodable { var draft: V1Draft; var library: [ContextBlock]; var experiments: [V1Experiment] }

    static func settings(budget: Int) -> SelectionSettings {
        SelectionSettings(strategy: .budgetSelection, budget: budget, deduplicateBeforeBudget: true, counter: .approximate(bytesPerToken: 4))
    }

    static func migrate(_ old: Project) throws -> ProjectDocument {
        let draft = Draft(instructions: old.draft.instructions, blocks: old.draft.blocks)
        var document = ProjectDocument(draft: draft, settings: settings(budget: old.draft.budget), library: old.library)
        for experiment in old.experiments {
            let input = Draft(instructions: experiment.report.input.instructions, blocks: experiment.report.input.blocks)
            let report = try SelectionEngine.run(input, settings: settings(budget: experiment.report.input.budget), counter: ApproximateCounter(bytesPerToken: 4))
            var evaluation = Evaluation()
            var notes = ["Migrated from schema 1. Previous manual label: \(experiment.review)."]
            if report.selectedPrompt != experiment.report.optimized {
                notes.append("The selected prompt was recomputed and differs from the schema 1 file.")
            }
            if !experiment.notes.isEmpty { notes.append("Previous notes: \(experiment.notes)") }
            evaluation.reviewerNotes = notes.joined(separator: "\n")
            document.experiments.append(Experiment(id: experiment.id, name: experiment.name, createdAt: experiment.createdAt,
                                                   snapshot: report, evaluation: evaluation))
        }
        return document
    }
}
