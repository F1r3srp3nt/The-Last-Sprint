import SwiftUI
import TokenLabCore

struct ExperimentsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var pendingDeletion: Experiment?

    var body: some View {
        HSplitView {
            List(store.document.experiments, selection: $store.selectedExperimentID) { experiment in
                ExperimentRow(experiment: experiment)
                    .tag(experiment.id)
                    .contextMenu {
                        Button("Export…") { store.exportExperiment(experiment.id) }
                        Button("Restore Inputs to Workspace…") { store.restoreInputs(from: experiment.id) }
                        Divider()
                        Button("Delete…", role: .destructive) { pendingDeletion = experiment }
                    }
            }
            .overlay {
                if store.document.experiments.isEmpty {
                    ContentUnavailableView {
                        Label("No experiments yet", systemImage: "flask")
                    } description: {
                        Text("In the Prompt Workspace, update the preview and choose Save as Experiment. Each experiment is a complete snapshot of inputs, settings, counter and both prompts.")
                    } actions: {
                        Button("Open Prompt Workspace") { store.selectedSection = .workspace }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.surface.opacity(0.45))
            .frame(minWidth: 220, idealWidth: 270, maxWidth: 380, maxHeight: .infinity)

            Group {
                if let id = store.selectedExperimentID, let binding = store.experimentBinding(id) {
                    ExperimentDetail(experiment: binding, onDelete: { pendingDeletion = binding.wrappedValue })
                        .id(id)
                } else if !store.document.experiments.isEmpty {
                    ContentUnavailableView("Select an experiment", systemImage: "flask",
                                           description: Text("Compare the full-context and selected prompts, record answers and review them."))
                } else {
                    Color.clear
                }
            }
            .frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog("Delete “\(pendingDeletion?.name ?? "")”?",
                            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("Delete Experiment", role: .destructive) {
                if let experiment = pendingDeletion { store.deleteExperiment(experiment.id) }
                pendingDeletion = nil
            }
        } message: {
            Text("This removes the snapshot and its evaluation from the project. Files on disk change only when you save.")
        }
    }
}

struct ExperimentRow: View {
    let experiment: Experiment
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(experiment.name.isEmpty ? "Untitled experiment" : experiment.name).fontWeight(.medium).lineLimit(1)
            Text("\(experiment.snapshot.settings.strategy.displayName) · \(experiment.snapshot.originalTokens) → \(experiment.snapshot.selectedTokens) \(experiment.snapshot.counter.kind == .approximation ? "est." : experiment.snapshot.counter.encoding)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 6) {
                if experiment.comparison != nil { Image(systemName: "rectangle.split.3x1").font(.caption2).foregroundStyle(.secondary).help("Part of a saved comparison") }
                VerdictBadge(evaluation: experiment.evaluation)
                Text(experiment.createdAt, style: .date).font(.caption2).foregroundStyle(DS.textTertiary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

struct ExperimentDetail: View {
    enum Tab: String, CaseIterable, Identifiable {
        case snapshot = "Snapshot", evaluation = "Evaluation", reproduce = "Reproducibility"
        var id: String { rawValue }
    }

    @EnvironmentObject private var store: AppStore
    @Binding var experiment: Experiment
    let onDelete: () -> Void
    @State private var tab: Tab = .snapshot

    private var createdLabel: some View {
        Text("Created \(experiment.createdAt.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption).foregroundStyle(DS.textSecondary).fixedSize()
    }

    private var tabPicker: some View {
        Picker("View", selection: $tab) {
            ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Experiment name", text: $experiment.name)
                        .textFieldStyle(.ds).font(.title3)
                        .accessibilityLabel("Experiment name")
                    Menu {
                        Button("Export Experiment…") { store.exportExperiment(experiment.id) }
                        Button("Restore Inputs to Workspace…") { store.restoreInputs(from: experiment.id) }
                        Divider()
                        Button("Delete…", role: .destructive, action: onDelete)
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                    .buttonStyle(.automatic)  // native menu button
                    .fixedSize()
                }
                // The date moves above the tabs when the detail pane is narrow.
                ViewThatFits(in: .horizontal) {
                    HStack { createdLabel; Spacer(); tabPicker }
                    VStack(alignment: .leading, spacing: 6) { createdLabel; tabPicker }
                }
            }
            .padding(16)
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .snapshot: SnapshotTab(experiment: experiment)
                    case .evaluation: EvaluationTab(experiment: $experiment)
                    case .reproduce: ReproduceTab(experiment: experiment)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: Snapshot

struct SnapshotTab: View {
    @EnvironmentObject private var store: AppStore
    let experiment: Experiment
    private var report: SelectionReport { experiment.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if experiment.comparison != nil { ComparisonGroupPanel(experiment: experiment) }
            ReportMetrics(report: report)
            Label(report.budgetSummary, systemImage: report.overBudget ? "exclamationmark.triangle.fill" : "checkmark.seal")
                .font(.callout)
                .foregroundStyle(report.overBudget ? DS.warning : DS.textPrimary)
            GroupBox("Recorded settings") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    Group {
                    row("Strategy", report.settings.strategy.displayName)
                    row("Budget", "\(report.settings.budget) (\(report.budgetEnforced ? "enforced" : "reported only"))")
                    row("Deduplication", report.settings.deduplicates ? "Exact, byte-for-byte" : "Off")
                    row("Counter", report.counter.displayName)
                    row("Encoding", report.counter.encoding)
                    row("Counter version", report.counter.version)
                    }
                    Group {
                    row("Counter type", report.counter.kind == .approximation ? "Approximation" : "Model tokenizer (text only)")
                    row("Engine", report.engineVersion)
                    row("Ranker", report.ranker.map { "\($0.displayName) (\($0.version))" } ?? "Not used")
                    row("Task terms", report.taskTerms.map { $0.isEmpty ? "none usable" : $0.joined(separator: ", ") } ?? "—")
                    row("Protected tokens", "\(report.protectedTokens)")
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Decisions") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(report.decisions) { DecisionRow(decision: $0, tokenUnit: report.counter.kind == .approximation ? "est." : "tok.") }
                    if report.decisions.isEmpty { Text("No context blocks.").foregroundStyle(.secondary) }
                }
                .padding(8)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { prompts }
                VStack(alignment: .leading, spacing: 12) { prompts }
            }
        }
    }

    @ViewBuilder private var prompts: some View {
        PromptTextView(title: "Full-context prompt", text: report.originalPrompt, minHeight: 120, maxHeight: 400) {
            store.copyToPasteboard(report.originalPrompt, what: "the full-context prompt")
        }
        .frame(minWidth: 260)
        PromptTextView(title: "Selected prompt", text: report.selectedPrompt, minHeight: 120, maxHeight: 400) {
            store.copyToPasteboard(report.selectedPrompt, what: "the selected prompt")
        }
        .frame(minWidth: 260)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

// MARK: Evaluation

struct EvaluationTab: View {
    @EnvironmentObject private var store: AppStore
    @Binding var experiment: Experiment

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Run both prompts with the same model and settings outside this app, then paste each answer and the provider’s usage figures here. This app does not call any model. Editing an answer or a criterion clears the verdict and the affected check results.",
                  systemImage: "info.circle")
                .font(.callout).foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if experiment.comparison != nil && experiment.evaluation.fullContextRun.hasResponse {
                Button { store.shareFullContextAnswer(from: experiment.id) } label: {
                    Label("Copy Full-Context Reference to Linked Experiments", systemImage: "arrow.triangle.branch")
                }
                .help("Copies only into linked experiments with the same saved full-context prompt and an empty reference. Candidate answers, checks and verdicts are never copied.")
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { runEditors }
                VStack(alignment: .leading, spacing: 12) { runEditors }
            }

            comparison

            ChecksEditor(title: "Expected facts", placeholder: "A fact the answer must contain",
                         help: "Facts a correct answer must include. Judge each answer separately.",
                         list: .expectedFacts, evaluation: $experiment.evaluation)
            ChecksEditor(title: "Correctness checks", placeholder: "A check, e.g. “No invented dates”",
                         help: "Other requirements: accuracy, format, no fabricated details.",
                         list: .correctnessChecks, evaluation: $experiment.evaluation)

            GroupBox("Review") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Reviewer", text: $experiment.evaluation.reviewer)
                        .textFieldStyle(.ds).frame(maxWidth: 280)
                    Text("Reviewer notes (editing notes keeps the verdict)").font(.caption).foregroundStyle(DS.textSecondary)
                    CodeEditor(text: $experiment.evaluation.reviewerNotes, minHeight: 70, maxHeight: 200, accessibilityLabel: "Reviewer notes")
                    Picker("Quality verdict", selection: verdict) {
                        ForEach(QualityVerdict.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(maxWidth: 420)
                    .disabled(!experiment.evaluation.canRecordVerdict && !experiment.evaluation.isEvaluated)
                    verdictCaption
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder private var verdictCaption: some View {
        let evaluation = experiment.evaluation
        if evaluation.equivalenceLacksReference {
            Label("This older verdict says “equivalent” but there is no full-context answer to compare with.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(DS.warning)
        } else if !evaluation.canRecordVerdict {
            Text("Paste the selected-context answer before recording a verdict. Until then this experiment stays “Not evaluated”.")
                .font(.caption).foregroundStyle(DS.textSecondary)
        } else if !evaluation.fullContextRun.hasResponse {
            Text("“Equivalent to full-context answer” needs the full-context answer as well.")
                .font(.caption).foregroundStyle(DS.textSecondary)
        } else if let date = evaluation.evaluatedAt {
            Text("Verdict recorded \(date.formatted(date: .abbreviated, time: .shortened)).")
                .font(.caption).foregroundStyle(DS.textSecondary)
        }
    }

    @ViewBuilder private var runEditors: some View {
        RunEditor(title: "Full-context answer (reference)", slot: .fullContext, prompt: experiment.snapshot.originalPrompt,
                  evaluation: $experiment.evaluation)
            .frame(minWidth: 260)
        RunEditor(title: "Selected-context answer (candidate)", slot: .selectedContext, prompt: experiment.snapshot.selectedPrompt,
                  evaluation: $experiment.evaluation)
            .frame(minWidth: 260)
    }

    private var verdict: Binding<QualityVerdict> {
        Binding(get: { experiment.evaluation.verdict }, set: { newValue in
            do { try experiment.evaluation.setVerdict(newValue) }
            catch { store.errorMessage = error.localizedDescription }
        })
    }

    private func count(_ value: Int?) -> String { value.map(String.init) ?? "not recorded" }

    private var comparison: some View {
        let evaluation = experiment.evaluation
        let snapshot = experiment.snapshot
        let full = evaluation.tally(selected: false), selected = evaluation.tally(selected: true)
        let provider = evaluation.providerInputComparison
        return GroupBox("Comparison") {
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("Full context").dsColumnHeader()
                        Text("Selected").dsColumnHeader()
                        Text("Change").dsColumnHeader()
                    }
                    Divider()
                    GridRow {
                        Text("Estimated input (\(snapshot.counter.encoding))")
                        Text("\(snapshot.originalTokens)").monospacedDigit()
                        Text("\(snapshot.selectedTokens)").monospacedDigit()
                        Text(TokenChange.describe(baseline: snapshot.originalTokens, candidate: snapshot.selectedTokens)).monospacedDigit()
                    }
                    GridRow {
                        Text("Provider-reported input")
                        Text(count(evaluation.fullContextRun.usage.inputTokens)).monospacedDigit()
                        Text(count(evaluation.selectedContextRun.usage.inputTokens)).monospacedDigit()
                        Text(provider.summary).monospacedDigit()
                            .foregroundStyle(provider.isComparable ? DS.textPrimary : DS.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    GridRow {
                        Text("Checks passed / failed / unchecked")
                        Text("\(full.pass) / \(full.fail) / \(full.notChecked)").monospacedDigit()
                        Text("\(selected.pass) / \(selected.fail) / \(selected.notChecked)").monospacedDigit()
                        Text("")
                    }
                    GridRow {
                        Text("Status")
                        Text(evaluation.statusLabel).gridCellColumns(3)
                    }
                }
                Text("Estimated counts come from the saved counter. Provider counts are compared only with matching provider and model labels. \(ProviderInputComparison.caveat)")
                    .font(.caption).foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Editor for one recorded answer. All edits go through `Evaluation`, which applies the
/// invalidation rules and records provenance.
struct RunEditor: View {
    @EnvironmentObject private var store: AppStore
    let title: String
    let slot: AnswerSlot
    let prompt: String
    @Binding var evaluation: Evaluation

    private var run: ModelRun { evaluation.run(slot) }

    private var answer: Binding<String> {
        Binding(get: { evaluation.run(slot).responseText },
                set: { evaluation.setAnswer($0, for: slot, prompt: prompt) })
    }

    private func usage<Value>(_ keyPath: WritableKeyPath<ProviderUsage, Value>) -> Binding<Value> {
        Binding(get: { evaluation.run(slot).usage[keyPath: keyPath] },
                set: { newValue in
                    var usage = evaluation.run(slot).usage
                    usage[keyPath: keyPath] = newValue
                    evaluation.setUsage(usage, for: slot)
                })
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Button { store.copyToPasteboard(prompt, what: "the prompt for “\(title)”") } label: {
                        Label("Copy Prompt", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                }
                CodeEditor(text: answer, minHeight: 110, maxHeight: 300, accessibilityLabel: "\(title) text")
                provenance
                Text("Provider-reported usage (copied manually; optional)").font(.caption).foregroundStyle(DS.textSecondary)
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        TextField("Provider", text: usage(\.provider)).textFieldStyle(.ds)
                        TextField("Model", text: usage(\.model)).textFieldStyle(.ds)
                    }
                    GridRow {
                        TextField("Input tokens", text: optionalIntText(usage(\.inputTokens))).textFieldStyle(.ds)
                            .accessibilityLabel("\(title): provider-reported input tokens")
                        TextField("Output tokens", text: optionalIntText(usage(\.outputTokens))).textFieldStyle(.ds)
                            .accessibilityLabel("\(title): provider-reported output tokens")
                    }
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder private var provenance: some View {
        if let record = run.provenance {
            VStack(alignment: .leading, spacing: 3) {
                Label("Entered manually for the saved \(record.promptRole.label) prompt · last edited \(record.lastEditedAt.formatted(date: .abbreviated, time: .shortened))",
                      systemImage: "person.crop.square")
                    .foregroundStyle(DS.textSecondary)
                if let source = record.copiedFromExperimentID {
                    Text("Copied from linked experiment “\(store.document.experiments.first(where: { $0.id == source })?.name ?? "no longer in this project")”.")
                        .foregroundStyle(DS.textSecondary)
                }
                if !record.matches(prompt: prompt) {
                    Label("Recorded for a different prompt than this experiment’s saved \(slot.label) prompt.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(DS.warning)
                }
                Text(AnswerProvenance.caveat).foregroundStyle(DS.textTertiary)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        } else if run.hasResponse || !run.usage.isEmpty {
            Label("Source not recorded", systemImage: "questionmark.circle")
                .font(.caption).foregroundStyle(DS.textSecondary)
                .help("Recorded before Distil stored answer provenance. Nothing has been inferred.")
        }
    }
}

/// Editor for one list of review criteria. All edits go through `Evaluation`.
struct ChecksEditor: View {
    let title: String
    let placeholder: String
    let help: String
    let list: ReviewCheckList
    @Binding var evaluation: Evaluation

    private var checks: [ReviewCheck] {
        list == .expectedFacts ? evaluation.expectedFacts : evaluation.correctnessChecks
    }

    private func current(_ id: UUID) -> ReviewCheck? { checks.first(where: { $0.id == id }) }

    private func text(_ id: UUID) -> Binding<String> {
        Binding(get: { current(id)?.text ?? "" }, set: { evaluation.setCheckText(id: id, $0) })
    }

    private func result(_ id: UUID, _ slot: AnswerSlot) -> Binding<CheckResult> {
        Binding(get: { (slot == .fullContext ? current(id)?.fullContext : current(id)?.selectedContext) ?? .notChecked },
                set: { evaluation.setCheckResult(id: id, slot: slot, $0) })
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Button { _ = evaluation.addCheck(to: list) } label: { Label("Add", systemImage: "plus") }
                        .controlSize(.small)
                }
                Text("\(help) Rewording a criterion resets its results.").font(.caption).foregroundStyle(DS.textSecondary)
                if checks.isEmpty {
                    Text("None yet.").font(.callout).foregroundStyle(DS.textTertiary)
                }
                ForEach(checks) { check in
                    HStack(spacing: 8) {
                        TextField(placeholder, text: text(check.id)).textFieldStyle(.ds)
                        resultPicker("Full", result(check.id, .fullContext))
                        resultPicker("Selected", result(check.id, .selectedContext))
                        Button(role: .destructive) { evaluation.removeCheck(id: check.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Remove this check")
                            .accessibilityLabel("Remove check")
                    }
                }
            }
            .padding(6)
        }
    }

    private func resultPicker(_ label: String, _ value: Binding<CheckResult>) -> some View {
        Picker(label, selection: value) {
            ForEach(CheckResult.allCases) { Text($0.label).tag($0) }
        }
        .fixedSize()
        .accessibilityLabel("\(label)-context result")
    }
}

// MARK: Reproducibility

struct ReproduceTab: View {
    @EnvironmentObject private var store: AppStore
    let experiment: Experiment
    @State private var result: ReproductionResult?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Re-run this snapshot’s saved inputs and settings with the current engine and counter, and compare with what was recorded. The saved snapshot itself is never modified.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    running = true
                    Task {
                        result = await store.reproduce(experiment.id)
                        running = false
                    }
                } label: { Label("Re-run and Compare", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(running)
                if running { ProgressView().controlSize(.small) }
            }
            if let result {
                switch result {
                case .identical:
                    Label("Reproduced exactly: same selected prompt, decisions, counts and counter version.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(DS.success)
                case .differs(let reasons):
                    VStack(alignment: .leading, spacing: 4) {
                        Label("The result differs from the saved snapshot:", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(DS.warning)
                        ForEach(reasons, id: \.self) { Text("• \($0)") }
                    }
                case .counterUnavailable(let message):
                    Label(message, systemImage: "questionmark.circle").foregroundStyle(.secondary)
                }
            }
            GroupBox("Saved for reproduction") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Inputs: instructions and \(experiment.snapshot.input.blocks.count) context block(s), verbatim")
                    Text("Settings: \(experiment.snapshot.settings.strategy.displayName), budget \(experiment.snapshot.settings.budget), deduplication \(experiment.snapshot.settings.deduplicates ? "on" : "off")")
                    Text("Counter: \(experiment.snapshot.counter.id) — \(experiment.snapshot.counter.version)")
                    Text("Engine: \(experiment.snapshot.engineVersion)")
                }
                .font(.callout).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: experiment.id) { result = nil }
    }
}

/// Linked variants of a saved comparison, with their evaluation status.
struct ComparisonGroupPanel: View {
    @EnvironmentObject private var store: AppStore
    let experiment: Experiment

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("Saved together from the same input. Only the strategy differs.")
                    .font(.caption).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(store.groupMembers(of: experiment.id)) { member in
                        GridRow {
                            Button(member.comparison?.variant.label ?? member.name) { store.selectedExperimentID = member.id }
                                .buttonStyle(.link)
                                .fontWeight(member.id == experiment.id ? .semibold : .regular)
                            Text("\(member.snapshot.selectedTokens) \(member.snapshot.counter.kind == .approximation ? "est." : member.snapshot.counter.encoding)")
                                .monospacedDigit().foregroundStyle(.secondary)
                            Text("\(member.snapshot.keptCount) kept · \(member.snapshot.removedCount) removed").foregroundStyle(.secondary)
                            VerdictBadge(evaluation: member.evaluation)
                        }
                    }
                }
                .font(.callout)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(experiment.comparison?.groupName ?? "Comparison", systemImage: "rectangle.split.3x1")
        }
    }
}
