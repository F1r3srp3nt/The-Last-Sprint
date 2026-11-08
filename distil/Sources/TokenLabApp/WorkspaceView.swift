import SwiftUI
import TokenLabCore

struct WorkspaceView: View {
    @EnvironmentObject private var store: AppStore
    @State private var pendingDeletion: ContextBlock?
    @State private var showingPaste = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var draft: Draft { store.document.draft }

    var body: some View {
        HSplitView {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        StepHeader(number: 1, title: "Describe your task",
                                   detail: "The task and the protected instructions are always sent exactly as written.",
                                   done: !draft.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        TaskEditor()
                        InstructionsEditor()
                        StepHeader(number: 2, title: "Add supporting context",
                                   detail: "Paste documents, notes, requirements or code, or add blocks one at a time. Optional blocks may be left out; mark essentials Required.",
                                   done: draft.blocks.contains { !$0.text.isEmpty })
                            .id("step2")
                        contextSection
                        StepHeader(number: 3, title: "Choose a strategy and budget",
                                   detail: "The budget applies to the whole prepared prompt. Steps 4 and 5 are in the panel on the right.")
                        SelectionSettingsPanel()
                        ReviewTemplateEditor()
                    }
                    .padding(20)
                }
                .onChange(of: store.revealedBlockID) { _, id in
                    guard let id else { return }
                    withAnimation(DS.motion(reduceMotion)) { proxy.scrollTo(id, anchor: .top) }
                    store.revealedBlockID = nil
                }
            }
            .frame(minWidth: 300, idealWidth: 600, maxWidth: .infinity, maxHeight: .infinity)

            PreviewPanel()
                .frame(minWidth: 250, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showingPaste = true } label: { Label("Paste Context", systemImage: "doc.on.clipboard") }
                    .buttonStyle(.automatic)  // native toolbar look
                    .help("Paste text and split it into context blocks")
                Button { store.addWorkspaceBlock() } label: { Label("Add Context", systemImage: "plus.rectangle") }
                    .buttonStyle(.automatic)  // native toolbar look
                    .help("Add a context block (⌥⌘N)")
                LibraryInsertMenu()
                    .buttonStyle(.automatic)  // native toolbar look
                Button { store.preview() } label: { Label("Update Preview", systemImage: "arrow.clockwise") }
                    .buttonStyle(.automatic)  // native toolbar look
                    .help("Run the selection on the current inputs (⌘↩)")
            }
        }
        .sheet(isPresented: $showingPaste) { PasteContextSheet().dsSheetContent() }
        .confirmationDialog("Delete “\(pendingDeletion?.title ?? "")”?",
                            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("Delete Block", role: .destructive) {
                if let block = pendingDeletion { store.removeWorkspaceBlock(block.id) }
                pendingDeletion = nil
            }
        } message: {
            Text("The block’s text will be removed from the workspace. Saved experiments keep their own copies.")
        }
    }

    private var contextSection: some View {
        // Look up the current report once per render rather than once per block.
        let decisions = Dictionary(uniqueKeysWithValues: (store.currentReport?.decisions ?? []).map { ($0.id, $0) })
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Context").font(.title3.weight(.semibold))
                Text("\(store.document.draft.blocks.count) block\(store.document.draft.blocks.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Spacer()
                Button { showingPaste = true } label: { Label("Paste Context…", systemImage: "doc.on.clipboard") }
                Button { store.addWorkspaceBlock() } label: { Label("Add Block", systemImage: "plus") }
                    .disabled(store.document.draft.blocks.count >= SelectionEngine.maxBlocks)
            }
            Text("Blocks appear in the prompt in this order. Optional blocks may be removed by the selected strategy; required blocks never are.")
                .font(.caption).foregroundStyle(.secondary)
            if store.document.draft.blocks.isEmpty {
                ContentUnavailableView {
                    Label("No context yet", systemImage: "text.badge.plus")
                } description: {
                    Text("Add reference text, conversation, code or tool output — or insert a reusable item from the Context Library.")
                } actions: {
                    Button("Paste Context…") { showingPaste = true }.buttonStyle(.dsPrimary)
                    Button("Add Block") { store.addWorkspaceBlock() }
                }
                .frame(minHeight: 200)
            }
            PastedOriginalsView()
            ForEach($store.document.draft.blocks) { $block in
                let decision = decisions[block.id]
                ContextBlockEditor(
                    block: $block,
                    tokenLabel: store.liveCountLabel(block.text, known: decision?.standaloneTokens),
                    decision: decision,
                    actions: workspaceActions(for: block))
                .id(block.id)
            }
        }
    }

    private func workspaceActions(for block: ContextBlock) -> [BlockAction] {
        [
            BlockAction(title: "Move Up", symbol: "arrow.up", enabled: store.canMoveWorkspaceBlock(block.id, by: -1)) {
                store.moveWorkspaceBlock(block.id, by: -1)
            },
            BlockAction(title: "Move Down", symbol: "arrow.down", enabled: store.canMoveWorkspaceBlock(block.id, by: 1)) {
                store.moveWorkspaceBlock(block.id, by: 1)
            },
            BlockAction(title: "Duplicate", symbol: "plus.square.on.square") { store.duplicateWorkspaceBlock(block.id) },
            BlockAction(title: "Copy to Library", symbol: "books.vertical") { store.copyToLibrary(block.id) },
            BlockAction(title: "Delete…", symbol: "trash", destructive: true) {
                if block.text.isEmpty { store.removeWorkspaceBlock(block.id) } else { pendingDeletion = block }
            }
        ]
    }
}

struct LibraryInsertMenu: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Menu {
            if store.document.library.isEmpty {
                Text("The library is empty")
            }
            ForEach(ContextCategory.allCases) { category in
                let items = store.document.library.filter { $0.category == category }
                if !items.isEmpty {
                    Section(category.rawValue) {
                        ForEach(items) { item in
                            Button(item.title.isEmpty ? "Untitled context" : item.title) { store.useLibraryItem(item.id) }
                        }
                    }
                }
            }
            Divider()
            Button("Open Context Library") { store.selectedSection = .library }
        } label: {
            Label("Insert from Library", systemImage: "books.vertical")
        }
        .help("Insert an independent copy of a library item")
    }
}

struct TaskEditor: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Current task or question", systemImage: "questionmark.bubble.fill")
                        .font(.headline)
                    Spacer()
                    Text(store.liveCountLabel(store.document.draft.task, known: store.currentReport?.taskTokens))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text("Always kept verbatim and placed last in the prompt. Task-relevance ranking compares context against these words.")
                    .font(.caption).foregroundStyle(.secondary)
                CodeEditor(text: $store.document.draft.task, minHeight: 60, maxHeight: 200,
                           accessibilityLabel: "Current task or question")
            }
            .padding(6)
        }
    }
}

struct InstructionsEditor: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Protected instructions and constraints", systemImage: "lock.fill")
                        .font(.headline)
                    Spacer()
                    Text(store.liveCountLabel(store.document.draft.instructions, known: store.currentReport?.instructionsTokens))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text("Always kept verbatim and placed first. Never shortened or removed to meet a budget.")
                    .font(.caption).foregroundStyle(.secondary)
                CodeEditor(text: $store.document.draft.instructions, minHeight: 90,
                           accessibilityLabel: "Protected instructions and constraints")
            }
            .padding(6)
        }
    }
}

/// Expected facts and checks for this task; copied as unchecked items into each new experiment.
struct ReviewTemplateEditor: View {
    @EnvironmentObject private var store: AppStore
    @State private var expanded = false

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Copied into each new experiment as unchecked items, so answers can be reviewed against the same criteria. They do not affect selection.")
                        .font(.caption).foregroundStyle(.secondary)
                    LinesEditor(title: "Expected facts", placeholder: "A fact a correct answer must contain",
                                lines: $store.document.reviewTemplate.expectedFacts)
                    LinesEditor(title: "Correctness checks", placeholder: "A check, e.g. “No invented dates”",
                                lines: $store.document.reviewTemplate.correctnessChecks)
                }
                .padding(.top, 6)
            } label: {
                Label("Review criteria (\(store.document.reviewTemplate.expectedFacts.count + store.document.reviewTemplate.correctnessChecks.count))",
                      systemImage: "checklist")
                    .font(.headline)
            }
            .padding(6)
        }
    }
}

struct LinesEditor: View {
    let title: String
    let placeholder: String
    @Binding var lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Button { lines.append("") } label: { Label("Add", systemImage: "plus") }.controlSize(.small)
            }
            ForEach(lines.indices, id: \.self) { index in
                HStack {
                    TextField(placeholder, text: Binding(
                        get: { lines.indices.contains(index) ? lines[index] : "" },
                        set: { if lines.indices.contains(index) { lines[index] = $0 } }))
                        .textFieldStyle(.ds)
                    Button(role: .destructive) { if lines.indices.contains(index) { lines.remove(at: index) } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(title.lowercased()) item")
                }
            }
        }
    }
}

struct SelectionSettingsPanel: View {
    @EnvironmentObject private var store: AppStore

    private var budget: Binding<Int> {
        Binding(get: { store.document.settings.budget },
                set: { store.document.settings.budget = min(max($0, SelectionSettings.budgetRange.lowerBound), SelectionSettings.budgetRange.upperBound) })
    }

    var body: some View {
        let settings = store.document.settings
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Strategy", selection: $store.document.settings.strategy) {
                    ForEach(SelectionStrategy.allCases) { Text($0.shortName).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Selection strategy")
                Text("\(settings.strategy.displayName): \(settings.strategy.summary)")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.strategy == .taskRelevance {
                    DisclosureGroup("How task relevance works and where it fails") {
                        RankingMethodView(taskTerms: KeywordOverlapRanker().taskTerms(store.document.draft.task))
                            .padding(.top, 4)
                    }
                    .font(.caption)
                }
                // Wraps the status pill onto its own line when the editor column is narrow.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { budgetControls; budgetPill(settings); Spacer(minLength: 0) }
                    VStack(alignment: .leading, spacing: 6) { HStack(spacing: 8) { budgetControls }; budgetPill(settings) }
                }
                if settings.enforcesBudget {
                    Toggle("Remove exact duplicates before applying the budget", isOn: $store.document.settings.deduplicateBeforeBudget)
                        .toggleStyle(.checkbox)
                }
                HStack(spacing: 6) {
                    Image(systemName: "number").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("Counter: \(settings.counter.shortName)").font(.callout)
                    Button("Change…") { store.selectedSection = .settings }
                        .buttonStyle(.link)
                }
            }
            .padding(6)
        } label: {
            Label("Selection settings", systemImage: "slider.horizontal.3")
        }
    }
}

extension SelectionSettingsPanel {
    @ViewBuilder var budgetControls: some View {
        Text("Token budget").fixedSize()
        TextField("Budget", value: budget, format: .number.grouping(.never))
            .textFieldStyle(.ds).frame(width: 90)
            .multilineTextAlignment(.trailing)
            .accessibilityLabel("Token budget")
        Stepper("Token budget", value: budget, in: SelectionSettings.budgetRange, step: 50).labelsHidden()
    }

    func budgetPill(_ settings: SelectionSettings) -> some View {
        Pill(text: settings.enforcesBudget ? "Enforced" : "Reported only",
             color: settings.enforcesBudget ? DS.accent : DS.textSecondary,
             systemImage: settings.enforcesBudget ? "gauge.with.dots.needle.33percent" : "info.circle")
            .fixedSize()
    }
}

struct BlockAction: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    var enabled = true
    var destructive = false
    let perform: () -> Void
}

/// Editor for one context block, shared by the workspace and the library.
struct ContextBlockEditor: View {
    @Binding var block: ContextBlock
    let tokenLabel: String
    var decision: BlockDecision?
    var actions: [BlockAction]
    var showsPriority = true

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Title", text: $block.title)
                        .textFieldStyle(.ds)
                        .font(.headline)
                        .accessibilityLabel("Context title")
                    Picker("Category", selection: $block.category) {
                        ForEach(ContextCategory.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityLabel("Context category")
                    if !actions.isEmpty {
                        Menu {
                            ForEach(actions) { action in
                                Button(role: action.destructive ? .destructive : nil, action: action.perform) {
                                    Label(action.title, systemImage: action.symbol)
                                }
                                .disabled(!action.enabled)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.borderless)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Block actions")
                        .accessibilityLabel("Actions for \(block.title)")
                    }
                }
                CodeEditor(text: $block.text, minHeight: 80, accessibilityLabel: "Text of \(block.title)")
                HStack(spacing: 12) {
                    Toggle("Required", isOn: $block.required)
                        .toggleStyle(.checkbox)
                        .help("Required context is always kept verbatim, even over budget.")
                    if showsPriority {
                        Picker("Priority", selection: $block.priority) {
                            ForEach(Array(ContextPriority.range), id: \.self) { Text(ContextPriority.label($0)).tag($0) }
                        }
                        .fixedSize()
                        .disabled(block.required)
                        .help(block.required ? "Priority does not apply to required context." : "Higher priority is considered first by budget selection.")
                    }
                    if block.libraryOrigin != nil {
                        Label("Copied from library", systemImage: "books.vertical")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let decision {
                        Pill(text: decision.kind.label, color: decision.kind.color, systemImage: decision.kind.symbol)
                            .help(decision.reason)
                    }
                    Text(tokenLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }
}

// MARK: - Preview

struct PreviewPanel: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage(StoredPreference.autoPreview) private var autoPreview = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                StepHeader(number: 4, title: "Review the proposed selection",
                           detail: "What is kept, what is left out, and why.", done: store.currentReport != nil)
                if store.isPreviewing { ProgressView().controlSize(.small).padding(.top, 6) }
                Spacer()
                Toggle("Auto-update", isOn: $autoPreview)
                    .toggleStyle(.switch).controlSize(.mini)
                    .help("Re-run the selection shortly after each edit.")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.surface.opacity(0.45))
        .overlay(alignment: .leading) { Rectangle().fill(DS.accent.opacity(0.16)).frame(width: 1) }
    }

    @ViewBuilder private var content: some View {
        if let report = store.currentReport {
            ReportView(report: report)
        } else if let error = store.previewError {
            ContentUnavailableView {
                Label("Preview unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Open Settings") { store.selectedSection = .settings }
                Button("Try Again") { store.preview() }
            }
        } else if store.workspaceIsEmpty {
            ContentUnavailableView("Nothing to preview", systemImage: "text.alignleft",
                                   description: Text("Write the task and instructions, and add context. The preview shows exactly what would be sent and why each block was kept or removed."))
        } else {
            ContentUnavailableView {
                Label(store.hasStaleReport ? "Preview out of date" : "No preview yet", systemImage: "arrow.clockwise")
            } description: {
                Text(store.hasStaleReport
                     ? "Inputs, settings or the counter changed since the last run. Old results are hidden so they cannot be mistaken for the current selection."
                     : "Run the selection to see which context is kept and why.")
            } actions: {
                Button("Update Preview") { store.preview() }
                    .buttonStyle(.dsPrimary)
                    .disabled(store.isPreviewing)
            }
        }
    }
}

struct ReportView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let report: SelectionReport

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                OutcomeBanner(outcome: report.outcome)
                StepHeader(number: 5, title: "Copy or export the prepared prompt",
                           detail: "It contains the instructions, the included context in its original order, and the task.")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { copyButton; secondaryActions }
                    VStack(alignment: .leading, spacing: 8) { copyButton; HStack(spacing: 8) { secondaryActions } }
                }
                ReportMetrics(report: report)
                budgetBanner
                if let ranker = report.ranker {
                    DisclosureGroup("Ranking: \(ranker.displayName)") {
                        RankingMethodView(descriptor: ranker, taskTerms: report.taskTerms).padding(.top, 4)
                    }
                    .font(.callout)
                    if let note = report.relevanceNote {
                        Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(DS.warning)
                    }
                }
                decisions
                PromptTextView(title: "Prepared prompt (complete)", text: report.selectedPrompt, maxHeight: 420) {
                    store.copySelectedPrompt()
                }
                DisclosureGroup("Full-context prompt (reference for comparison)") {
                    PromptTextView(title: "Full-context prompt", text: report.originalPrompt) {
                        store.copyToPasteboard(report.originalPrompt, what: "the full-context prompt")
                    }
                    .padding(.top, 6)
                }
                Text("Answer quality has not been evaluated. A smaller prompt can lose information the task needs: review what was left out, then save an experiment to compare answers.")
                    .font(.caption).foregroundStyle(DS.textSecondary)
            }
            .padding(14)
        }
    }

    private var decisions: some View {
        let empty = report.decisions.filter { $0.kind == .emptySkipped }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lock.fill").foregroundStyle(DS.accent).frame(width: 16).accessibilityHidden(true)
                Text("Protected instructions (first) and task (last) are always included verbatim.").font(.callout)
            }
            decisionList("Included", report.decisions.filter(\.kept))
            decisionList("Left out", report.decisions.filter { !$0.kept && $0.kind != .emptySkipped })
            if !empty.isEmpty {
                Text("\(empty.count) empty block\(empty.count == 1 ? "" : "s") skipped: \(empty.map(\.title).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(DS.textTertiary)
            }
        }
    }

    private var copyButton: some View {
        Button { store.copySelectedPrompt() } label: { Label("Copy Prepared Prompt", systemImage: "doc.on.doc") }
            .buttonStyle(.dsPrimary)
            .controlSize(.large)
            .help("Copy the complete prepared prompt (⇧⌘C)")
    }

    @ViewBuilder private var secondaryActions: some View {
        Button { store.exportReport() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
            .help("Export this report as JSON (⌘E)")
        Button { store.saveExperiment() } label: { Label("Save as Experiment", systemImage: "flask") }
            .help("Snapshot the inputs, settings, counter and both prompts (⇧⌘E)")
    }

    private func decisionList(_ title: String, _ items: [BlockDecision]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) (\(items.count))").dsColumnHeader()
            if items.isEmpty {
                Text("None.").font(.caption).foregroundStyle(DS.textTertiary)
            }
            ForEach(items) { decision in
                let open = store.inspectedBlockID == decision.id
                Button {
                    withAnimation(DS.motion(reduceMotion)) { store.inspectedBlockID = open ? nil : decision.id }
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        DecisionRow(decision: decision, tokenUnit: unit)
                        Image(systemName: open ? "chevron.up" : "chevron.down")
                            .font(.caption).foregroundStyle(DS.textTertiary).padding(.top, 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(open ? "Hides the details" : "Shows the full text and why it was \(decision.kept ? "included" : "left out")")
                if open { BlockInspector(decision: decision) }
            }
        }
    }

    private var unit: String { report.counter.kind == .approximation ? "est." : "tok." }

    private var budgetBanner: some View {
        // A budget fit is a measurement, so it uses the accent; amber only when over budget.
        Label(report.budgetSummary, systemImage: report.overBudget ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.33percent")
            .font(.callout)
            .foregroundStyle(report.overBudget ? DS.warning : DS.textPrimary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((report.overBudget ? DS.warning : DS.accent).opacity(0.09), in: RoundedRectangle(cornerRadius: DS.Radius.control + 2))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control + 2).strokeBorder((report.overBudget ? DS.warning : DS.accent).opacity(0.3)))
            .accessibilityLabel(report.budgetSummary)
    }
}

struct ReportMetrics: View {
    let report: SelectionReport

    private var changeValue: String {
        let change = report.selectedTokens - report.originalTokens
        guard change != 0 else { return "No change" }
        guard report.originalTokens != 0 else { return "+\(change)" }
        let percent = Double(abs(change)) / Double(report.originalTokens) * 100
        return "\(change < 0 ? "\u{2212}" : "+")\(String(format: "%.1f", percent))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Counted with \(report.counter.displayName)\(report.counter.kind == .approximation ? " (estimate)" : "")",
                  systemImage: "number")
                .font(.caption.weight(.semibold)).foregroundStyle(DS.textSecondary)
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    MetricTile(title: "Full context", value: "\(report.originalTokens)", systemImage: "text.alignleft")
                    MetricTile(title: "Prepared", value: "\(report.selectedTokens)", systemImage: "line.3.horizontal.decrease")
                    MetricTile(title: "Change", value: changeValue,
                               caption: "\(TokenChange.describe(baseline: report.originalTokens, candidate: report.selectedTokens)) · input size, not quality",
                               systemImage: "plusminus")
                }
            }
            Text("\(report.counter.scope) Not provider-reported usage and not a cost saving.")
                .font(.caption2).foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
