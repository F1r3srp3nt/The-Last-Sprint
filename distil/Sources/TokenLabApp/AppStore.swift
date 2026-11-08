import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import TokenLabCore

/// UserDefaults keys. Kept outside the main-actor store so views can use them in property wrappers.
enum StoredPreference {
    static let autoPreview = "autoPreview"
    static let appearance = "appearance"
}

enum AppSection: String, CaseIterable, Identifiable {
    case overview, workspace, comparison, library, experiments, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .workspace: return "Prompt Workspace"
        case .comparison: return "Comparison"
        case .library: return "Context Library"
        case .experiments: return "Experiments"
        case .settings: return "Settings"
        }
    }
    /// One-line description shown in the page header.
    var subtitle: String {
        switch self {
        case .overview: return "Project status, current settings and entry points."
        case .workspace: return "Task, protected instructions and context — and exactly what would be sent."
        case .comparison: return "The same input through four configurations, side by side."
        case .library: return "Reusable context. Inserted copies are independent."
        case .experiments: return "Saved snapshots, recorded answers and manual quality review."
        case .settings: return "Appearance, token counting, ranking and local data."
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .workspace: return "text.alignleft"
        case .comparison: return "rectangle.split.3x1"
        case .library: return "books.vertical"
        case .experiments: return "flask"
        case .settings: return "gearshape"
        }
    }
    var shortcutKey: Character {
        switch self {
        case .overview: return "1"
        case .workspace: return "2"
        case .comparison: return "3"
        case .library: return "4"
        case .experiments: return "5"
        case .settings: return "6"
        }
    }
}

/// UI state and actions. All persistence and selection rules live in TokenLabCore.
@MainActor final class AppStore: ObservableObject {
    @Published var session = ProjectSession() {
        didSet {
            if session.document.draft != oldValue.document.draft || session.document.settings != oldValue.document.settings {
                previewInputsChanged()
            }
        }
    }
    @Published var selectedSection: AppSection? = .overview
    @Published var selectedLibraryID: UUID?
    @Published var selectedExperimentID: UUID?
    @Published private(set) var report: SelectionReport?
    @Published private(set) var previewError: String?
    @Published private(set) var isPreviewing = false
    @Published private(set) var comparison: [ComparisonEntry]?
    @Published private(set) var comparisonError: String?
    @Published private(set) var isComparing = false
    @Published var errorMessage: String?
    @Published var status = "Local session. Nothing is saved until you choose Save Project."

    let encodings: EncodingStore
    /// Set once the user has already confirmed discarding changes while closing the window.
    var allowTerminationWithoutPrompt = false

    // Background work: every run gets a ticket; only the latest ticket may publish a result, and
    // superseded runs are cancelled so they stop consuming CPU.
    private var previewGate = LatestResultGate()
    private var comparisonGate = LatestResultGate()
    private var previewWork: Task<Void, Never>?
    private var comparisonWork: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    static let debounceNanoseconds: UInt64 = 400_000_000
    private var cancellables: Set<AnyCancellable> = []

    init(encodings: EncodingStore? = nil) {
        self.encodings = encodings ?? EncodingStore()
        self.encodings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    // MARK: Derived state

    var document: ProjectDocument {
        get { session.document }
        set { session.document = newValue }
    }
    var hasUnsavedChanges: Bool { session.hasUnsavedChanges }
    var windowSubtitle: String { session.displayName + (hasUnsavedChanges ? " — Edited" : "") }

    var autoPreviewEnabled: Bool { UserDefaults.standard.object(forKey: StoredPreference.autoPreview) as? Bool ?? true }

    /// Descriptor of the project's counter, if it is available right now.
    var activeCounterDescriptor: TokenCounterDescriptor? {
        try? encodings.resolver().counter(for: document.settings.counter).descriptor
    }

    /// The last preview, only if it was produced from exactly the current inputs, settings and counter.
    var currentReport: SelectionReport? {
        guard let report, let counter = activeCounterDescriptor,
              report.isCurrent(draft: document.draft, settings: document.settings, counter: counter) else { return nil }
        return report
    }
    var hasStaleReport: Bool { report != nil && currentReport == nil }

    /// The last comparison, only if all four variants match the current inputs and counter.
    var currentComparison: [ComparisonEntry]? {
        guard let comparison, let counter = activeCounterDescriptor,
              Comparison.isCurrent(comparison, draft: document.draft, base: document.settings, counter: counter) else { return nil }
        return comparison
    }
    var hasStaleComparison: Bool { comparison != nil && currentComparison == nil }

    var workspaceIsEmpty: Bool {
        document.draft.task.isEmpty && document.draft.instructions.isEmpty && document.draft.blocks.allSatisfy { $0.text.isEmpty }
    }

    /// Token hint for an editor. Only the cheap approximate counter runs on the main thread; model
    /// tokenizer counts come from the latest background preview (`known`) or are shown as pending.
    func liveCountLabel(_ text: String, known: Int? = nil) -> String {
        switch document.settings.counter {
        case .approximate(let n):
            return "≈ \(ApproximateCounter(bytesPerToken: n).count(text)) est. tokens"
        case .bpe(let id):
            if let known { return "\(known) \(id.rawValue) tokens" }
            return "– \(id.rawValue) tokens (after preview)"
        }
    }

    // MARK: Background preview and comparison

    /// Run `work` on a background thread. Cancelling the calling task cancels the work too.
    nonisolated static func background<T: Sendable>(_ work: @escaping @Sendable (() -> Bool) throws -> T) async -> Result<T, Error> {
        let worker = Task.detached(priority: .userInitiated) { () -> Result<T, Error> in
            Result { try work({ Task.isCancelled }) }
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    func preview() {
        debounceTask?.cancel()
        previewWork?.cancel()
        let draft = document.draft, settings = document.settings
        let ticket = previewGate.begin()
        isPreviewing = true
        previewWork = Task { [weak self] in
            guard let self else { return }
            let result: Result<SelectionReport, Error>
            do {
                let counter = try await self.encodings.counter(for: settings.counter)
                result = await Self.background { isCancelled in
                    try SelectionEngine.run(draft, settings: settings, counter: counter, isCancelled: isCancelled)
                }
            } catch {
                result = .failure(error)
            }
            // An older or cancelled calculation never replaces a newer preview.
            guard self.previewGate.isLatest(ticket), !Task.isCancelled else { return }
            self.isPreviewing = false
            switch result {
            case .success(let report): self.report = report; self.previewError = nil
            case .failure(let error) where error is CancellationError: break
            case .failure(let error): self.report = nil; self.previewError = error.localizedDescription
            }
        }
    }

    func runComparison() {
        comparisonWork?.cancel()
        let draft = document.draft, settings = document.settings
        let ticket = comparisonGate.begin()
        isComparing = true
        comparisonWork = Task { [weak self] in
            guard let self else { return }
            let result: Result<[ComparisonEntry], Error>
            do {
                let counter = try await self.encodings.counter(for: settings.counter)
                result = await Self.background { isCancelled in
                    try Comparison.run(draft, base: settings, counter: counter, isCancelled: isCancelled)
                }
            } catch {
                result = .failure(error)
            }
            guard self.comparisonGate.isLatest(ticket), !Task.isCancelled else { return }
            self.isComparing = false
            switch result {
            case .success(let entries): self.comparison = entries; self.comparisonError = nil
            case .failure(let error) where error is CancellationError: break
            case .failure(let error): self.comparison = nil; self.comparisonError = error.localizedDescription
            }
        }
    }

    /// Inputs changed: stop and discard in-flight work, then (if enabled) recompute after a pause in typing.
    private func previewInputsChanged() {
        previewError = nil
        comparisonError = nil
        previewWork?.cancel(); comparisonWork?.cancel()
        previewGate.invalidate(); comparisonGate.invalidate()
        isPreviewing = false; isComparing = false
        debounceTask?.cancel()
        guard autoPreviewEnabled else { return }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled, let self else { return }
            switch self.selectedSection {
            case .comparison: self.runComparison()
            case .workspace, .overview: self.preview()
            default: break
            }
        }
    }

    // MARK: Workspace

    func addWorkspaceBlock() {
        guard document.draft.blocks.count < SelectionEngine.maxBlocks else { return fail("The workspace is limited to \(SelectionEngine.maxBlocks) blocks.") }
        document.draft.blocks.append(ContextBlock())
        selectedSection = .workspace
    }

    func removeWorkspaceBlock(_ id: UUID) {
        document.draft.blocks.removeAll { $0.id == id }
    }

    func duplicateWorkspaceBlock(_ id: UUID) {
        guard let index = document.draft.blocks.firstIndex(where: { $0.id == id }) else { return }
        guard document.draft.blocks.count < SelectionEngine.maxBlocks else { return fail("The workspace is limited to \(SelectionEngine.maxBlocks) blocks.") }
        var copy = document.draft.blocks[index].independentCopy(origin: document.draft.blocks[index].libraryOrigin)
        copy.title += " (copy)"
        document.draft.blocks.insert(copy, at: index + 1)
    }

    func moveWorkspaceBlock(_ id: UUID, by offset: Int) {
        guard let index = document.draft.blocks.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard document.draft.blocks.indices.contains(target) else { return }
        document.draft.blocks.swapAt(index, target)
    }

    func canMoveWorkspaceBlock(_ id: UUID, by offset: Int) -> Bool {
        guard let index = document.draft.blocks.firstIndex(where: { $0.id == id }) else { return false }
        return document.draft.blocks.indices.contains(index + offset)
    }

    /// Add blocks proposed from a paste, keeping the exact original in the project. Returns false
    /// (with an explanation) when the workspace limits would be exceeded; nothing is added then.
    @discardableResult
    func addPastedContext(title: String, original: String, blocks proposals: [ProposedBlock]) -> Bool {
        guard !proposals.isEmpty else { return false }
        let source = PastedSource(title: title, text: original)
        let blocks = proposals.map {
            ContextBlock(title: $0.title, text: $0.text, category: $0.category, priority: ContextPriority.medium,
                         required: $0.required, pastedSourceID: source.id)
        }
        var draft = document.draft
        draft.blocks += blocks
        do { try SelectionEngine.validate(draft) }
        catch { fail("The pasted context was not added. \(error.localizedDescription)"); return false }
        document.pastedSources.append(source)
        document.draft = draft
        selectedSection = .workspace
        status = "Added \(blocks.count) block\(blocks.count == 1 ? "" : "s") from “\(title)”. The original is kept in the project."
        return true
    }

    func removePastedSource(_ id: UUID) {
        guard let source = document.pastedSources.first(where: { $0.id == id }) else { return }
        guard Dialogs.confirm(title: "Remove the original “\(source.title)”?",
                              message: "The exact pasted text will no longer be kept in this project. Blocks already made from it stay in the workspace.",
                              confirmTitle: "Remove Original") else { return }
        document.pastedSources.removeAll { $0.id == id }
        for index in document.draft.blocks.indices where document.draft.blocks[index].pastedSourceID == id {
            document.draft.blocks[index].pastedSourceID = nil
        }
        status = "Removed the original “\(source.title)”."
    }

    /// Make a block Required and run the selection again straight away.
    func markRequired(_ id: UUID) {
        guard let index = document.draft.blocks.firstIndex(where: { $0.id == id }) else { return }
        document.draft.blocks[index].required = true
        status = "“\(document.draft.blocks[index].title)” is now Required and will always be kept."
        preview()
    }

    /// Ask the workspace editor to scroll to a block.
    @Published var revealedBlockID: UUID?
    /// The decision whose details are open in the review panel (kept across re-runs).
    @Published var inspectedBlockID: UUID?

    func revealBlock(_ id: UUID) {
        selectedSection = .workspace
        revealedBlockID = id
    }

    func copyToLibrary(_ id: UUID) {
        guard let block = document.draft.blocks.first(where: { $0.id == id }) else { return }
        guard document.library.count < ProjectDocument.maxLibraryItems else { return fail("The library is limited to \(ProjectDocument.maxLibraryItems) items.") }
        var copy = block.independentCopy()
        copy.required = false
        document.library.append(copy)
        status = "Copied “\(block.title)” to the Context Library."
    }

    // MARK: Library

    func newLibraryItem() {
        guard document.library.count < ProjectDocument.maxLibraryItems else { return fail("The library is limited to \(ProjectDocument.maxLibraryItems) items.") }
        let item = ContextBlock(title: "New context")
        document.library.append(item)
        selectedLibraryID = item.id
    }

    func duplicateLibraryItem(_ id: UUID) {
        guard let index = document.library.firstIndex(where: { $0.id == id }) else { return }
        guard document.library.count < ProjectDocument.maxLibraryItems else { return fail("The library is limited to \(ProjectDocument.maxLibraryItems) items.") }
        var copy = document.library[index].independentCopy()
        copy.title += " (copy)"
        document.library.insert(copy, at: index + 1)
        selectedLibraryID = copy.id
    }

    func deleteLibraryItem(_ id: UUID) {
        document.library.removeAll { $0.id == id }
        if selectedLibraryID == id { selectedLibraryID = nil }
    }

    /// Insert an independent copy of a library item into the workspace.
    func useLibraryItem(_ id: UUID) {
        guard let item = document.library.first(where: { $0.id == id }) else { return }
        guard document.draft.blocks.count < SelectionEngine.maxBlocks else { return fail("The workspace is limited to \(SelectionEngine.maxBlocks) blocks.") }
        document.draft.blocks.append(item.independentCopy(origin: item.id))
        status = "Added a copy of “\(item.title)” to the workspace. Editing it will not change the library item."
    }

    func workspaceUses(ofLibraryItem id: UUID) -> Int {
        document.draft.blocks.filter { $0.libraryOrigin == id }.count
    }

    func libraryBinding(_ id: UUID) -> Binding<ContextBlock>? {
        guard let initial = document.library.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.document.library.first { $0.id == id } ?? initial },
            set: { [weak self] newValue in
                guard let self, let index = self.document.library.firstIndex(where: { $0.id == id }) else { return }
                self.document.library[index] = newValue
            })
    }

    // MARK: Experiments

    func saveExperiment() {
        guard let report = currentReport else { return fail("Update the preview first. Only a current preview can be saved as an experiment.") }
        guard document.experiments.count < ProjectDocument.maxExperiments else { return fail("A project is limited to \(ProjectDocument.maxExperiments) experiments.") }
        let formatter = DateFormatter(); formatter.dateStyle = .short; formatter.timeStyle = .short
        let experiment = Experiment(name: "\(report.settings.strategy.displayName) — \(formatter.string(from: Date()))",
                                    snapshot: report, evaluation: Evaluation(template: document.reviewTemplate))
        document.experiments.insert(experiment, at: 0)
        selectedExperimentID = experiment.id
        status = "Saved experiment “\(experiment.name)”. Save the project to keep it."
    }

    /// Save the current four-way comparison as four linked experiment snapshots.
    func saveComparison() {
        guard let entries = currentComparison else { return fail("Run the comparison first. Only a current comparison can be saved.") }
        guard document.experiments.count + entries.count <= ProjectDocument.maxExperiments else {
            return fail("A project is limited to \(ProjectDocument.maxExperiments) experiments.")
        }
        let formatter = DateFormatter(); formatter.dateStyle = .short; formatter.timeStyle = .short
        let experiments = Comparison.experiments(from: entries, groupName: "Comparison \(formatter.string(from: Date()))",
                                                 template: document.reviewTemplate)
        document.experiments.insert(contentsOf: experiments, at: 0)
        selectedExperimentID = experiments.first?.id
        status = "Saved \(experiments.count) linked experiments. Answer quality is not evaluated until you record and review answers."
    }

    func groupMembers(of id: UUID) -> [Experiment] {
        guard let group = document.experiments.first(where: { $0.id == id })?.comparison?.groupID else { return [] }
        let order = ComparisonVariant.allCases
        return document.experiments.filter { $0.comparison?.groupID == group }
            .sorted { order.firstIndex(of: $0.comparison!.variant)! < order.firstIndex(of: $1.comparison!.variant)! }
    }

    /// Copy this experiment's full-context reference to linked experiments that qualify (same comparison,
    /// byte-identical saved full-context prompt, completely blank reference). Never overwrites anything.
    func shareFullContextAnswer(from id: UUID) {
        let (updated, outcome) = ReferenceSharing.share(from: id, in: document.experiments)
        if outcome.sourceUnavailable == nil { document.experiments = updated }
        status = outcome.summary
    }

    func experimentBinding(_ id: UUID) -> Binding<Experiment>? {
        guard let initial = document.experiments.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.document.experiments.first { $0.id == id } ?? initial },
            set: { [weak self] newValue in
                guard let self, let index = self.document.experiments.firstIndex(where: { $0.id == id }) else { return }
                self.document.experiments[index] = newValue
            })
    }

    func deleteExperiment(_ id: UUID) {
        document.experiments.removeAll { $0.id == id }
        if selectedExperimentID == id { selectedExperimentID = nil }
    }

    /// Replace the workspace inputs and settings with an experiment's saved inputs.
    func restoreInputs(from id: UUID) {
        guard let experiment = document.experiments.first(where: { $0.id == id }) else { return }
        guard Dialogs.confirm(title: "Replace the workspace with this experiment’s inputs?",
                              message: "The current instructions, context blocks and selection settings will be replaced by the ones saved in “\(experiment.name)”. The library and other experiments are not changed.",
                              confirmTitle: "Replace Workspace") else { return }
        document.draft = experiment.snapshot.input
        document.settings = experiment.snapshot.settings
        selectedSection = .workspace
        status = "Workspace restored from “\(experiment.name)”."
    }

    func reproduce(_ id: UUID) async -> ReproductionResult {
        guard let experiment = document.experiments.first(where: { $0.id == id }) else { return .differs(["Experiment not found."]) }
        if case .bpe(let encoding) = experiment.snapshot.settings.counter {
            _ = try? await encodings.load(encoding)
        }
        let resolver = encodings.resolver()
        return await Task.detached(priority: .userInitiated) { ReproductionCheck.run(experiment, resolver: resolver) }.value
    }

    // MARK: Clipboard and exports

    func copyToPasteboard(_ text: String, what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "Copied \(what) to the clipboard."
    }

    func copySelectedPrompt() {
        guard let report = currentReport else { return }
        copyToPasteboard(report.selectedPrompt, what: "the selected prompt")
    }

    func exportReport() {
        guard let report = currentReport else { return fail("There is no current preview to export.") }
        export(report, suggestedName: "Selection-Report.json", findings: SecretScanner.scan(report), what: "Report")
    }

    func exportExperiment(_ id: UUID) {
        guard let experiment = document.experiments.first(where: { $0.id == id }) else { return }
        var project = ProjectDocument(); project.experiments = [experiment]
        let findings = SecretScanner.scan(project)
        export(experiment, suggestedName: "Experiment.json", findings: findings, what: "Experiment")
    }

    private func export<T: Encodable>(_ value: T, suggestedName: String, findings: [SecretFinding], what: String) {
        if !findings.isEmpty && !Dialogs.confirmPossibleSecrets(findings, action: "Export") { status = "Export cancelled."; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(value).write(to: url, options: .atomic)
            status = "\(what) exported to \(url.lastPathComponent). It contains prompt text in plain JSON."
        } catch {
            fail("Could not export: \(error.localizedDescription)")
        }
    }

    // MARK: Project files

    /// Ask about unsaved changes before replacing or closing the project. Returns true to proceed.
    func confirmUnsavedChanges(before action: String) -> Bool {
        ProjectSession.mayProceed(
            hasUnsavedChanges: hasUnsavedChanges,
            ask: { Dialogs.askAboutUnsavedChanges(projectName: session.displayName, action: action) },
            save: { save() })
    }

    func newProject() {
        guard confirmUnsavedChanges(before: "starting a new project") else { return }
        replaceSession(ProjectSession(), status: "New untitled project.")
    }

    func loadExample() {
        guard confirmUnsavedChanges(before: "loading the example project") else { return }
        replaceSession(.untitled(SampleProject.make()), status: "Example loaded. It is synthetic and untitled; save it to keep changes.")
        selectedSection = .workspace
    }

    func loadDemo(_ id: DemoDataset.ID) {
        guard confirmUnsavedChanges(before: "loading a demonstration") else { return }
        replaceSession(.untitled(DemoDataset.make(id)), status: "Demonstration loaded: synthetic data, not benchmark evidence.")
        selectedSection = .comparison
        runComparison()
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let opened: (session: ProjectSession, loaded: ProjectCodec.Loaded)
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= ProjectCodec.maxFileBytes else { throw LabError.invalid("Project files are limited to 20 MB.") }
            opened = try ProjectSession.opening(data: Data(contentsOf: url), url: url)
        } catch {
            return fail("“\(url.lastPathComponent)” could not be opened. Your current project was not changed.\n\n\(error.localizedDescription)")
        }
        // Validation happened first, so a bad file never costs the user their current work.
        guard confirmUnsavedChanges(before: "opening “\(url.lastPathComponent)”") else { return }
        if opened.loaded.wasMigrated {
            replaceSession(opened.session, status: "Converted “\(url.lastPathComponent)” from schema \(opened.loaded.sourceSchemaVersion). It is open as untitled so the original file is not overwritten.")
        } else {
            replaceSession(opened.session, status: "Opened \(url.lastPathComponent).")
        }
    }

    /// Save to the current file, or ask for a location. Returns true only if the project was written.
    @discardableResult func save() -> Bool {
        if let url = session.fileURL { return write(to: url) }
        return saveAs()
    }

    @discardableResult func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = (session.fileURL?.lastPathComponent) ?? "Untitled Project.json"
        guard panel.runModal() == .OK, let url = panel.url else { status = "Save cancelled."; return false }
        return write(to: url)
    }

    private func write(to url: URL) -> Bool {
        let snapshot = document
        let findings = SecretScanner.scan(snapshot)
        if !findings.isEmpty && !Dialogs.confirmPossibleSecrets(findings, action: "Save") {
            status = "Save cancelled."
            return false
        }
        do {
            let data = try ProjectCodec.encode(snapshot)
            try data.write(to: url, options: .atomic)
            session.didSave(snapshot, to: url)
            status = "Saved \(url.lastPathComponent)."
            return true
        } catch {
            fail("Could not save the project. Nothing was overwritten.\n\n\(error.localizedDescription)")
            return false
        }
    }

    private func replaceSession(_ newSession: ProjectSession, status: String) {
        session = newSession
        report = nil
        previewError = nil
        comparison = nil
        comparisonError = nil
        selectedLibraryID = nil
        selectedExperimentID = nil
        self.status = status
    }

    /// Close the main window after resolving unsaved changes (window close button and ⌘W).
    func requestCloseWindow(_ window: NSWindow?) {
        guard confirmUnsavedChanges(before: "closing the window") else { return }
        allowTerminationWithoutPrompt = true
        window?.close()
    }

    private func fail(_ message: String) {
        errorMessage = message
    }
}
