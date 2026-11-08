import SwiftUI
import TokenLabCore

/// Runs the same input through four fixed configurations and shows them side by side.
struct ComparisonView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedBlock: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { store.runComparison() } label: { Label("Run Comparison", systemImage: "arrow.clockwise") }
                    .buttonStyle(.automatic)  // native toolbar look
                    .help("Run all four configurations on the current input (⇧⌘R)")
                Button { store.saveComparison() } label: { Label("Save as Experiments", systemImage: "flask") }
                    .buttonStyle(.automatic)  // native toolbar look
                    .disabled(store.currentComparison == nil)
                    .help("Save four linked, reproducible experiment snapshots")
            }
        }
        .onAppear {
            if store.currentComparison == nil && !store.isComparing && !store.workspaceIsEmpty { store.runComparison() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Same input, four configurations").font(DS.Typeface.sectionTitle).foregroundStyle(DS.textPrimary)
                if store.isComparing { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text("Budget \(store.document.settings.budget) · counter: \(store.activeCounterDescriptor?.displayName ?? store.document.settings.counter.shortName) · exact dedupe before budget: \(store.document.settings.deduplicateBeforeBudget ? "on" : "off"). Only the strategy differs between columns.")
                .font(.caption).foregroundStyle(.secondary)
            Label("Token counts are input estimates, not measured cost. Keyword matches do not show that a block is useful or an answer correct. Answer quality is “Not evaluated” until answers are recorded and reviewed in Experiments.",
                  systemImage: "exclamationmark.shield")
                .font(.caption).foregroundStyle(DS.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    @ViewBuilder private var content: some View {
        if let entries = store.currentComparison {
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 18) {
                    summaryGrid(entries)
                    matrix(entries)
                    if let id = selectedBlock { reasons(for: id, entries) }
                    savedGroups
                }
                .padding(14)
            }
        } else if let error = store.comparisonError {
            ContentUnavailableView {
                Label("Comparison unavailable", systemImage: "exclamationmark.triangle")
            } description: { Text(error) } actions: {
                Button("Open Settings") { store.selectedSection = .settings }
                Button("Try Again") { store.runComparison() }
            }
        } else if store.workspaceIsEmpty {
            ContentUnavailableView {
                Label("Nothing to compare", systemImage: "rectangle.split.3x1")
            } description: {
                Text("Write a task and add context in the Prompt Workspace, or load a demonstration.")
            } actions: {
                Menu("Load Demonstration") {
                    ForEach(DemoDataset.ID.allCases) { id in Button(id.title) { store.loadDemo(id) } }
                }
                .fixedSize()
            }
        } else {
            ContentUnavailableView {
                Label(store.hasStaleComparison ? "Comparison out of date" : "Not run yet", systemImage: "arrow.clockwise")
            } description: {
                Text(store.hasStaleComparison
                     ? "The input, settings or counter changed. Old results are hidden so they cannot be mistaken for the current input."
                     : "Run all four configurations on the current input.")
            } actions: {
                Button("Run Comparison") { store.runComparison() }.buttonStyle(.dsPrimary).disabled(store.isComparing)
            }
        }
    }

    // MARK: Summary

    private func summaryGrid(_ entries: [ComparisonEntry]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("")
                ForEach(entries) { Text($0.variant.label).font(.subheadline.weight(.semibold)).foregroundStyle(DS.textPrimary).frame(minWidth: 150, alignment: .leading) }
            }
            Divider()
            row("Input tokens", entries) { "\($0.selectedTokens)" }
            row("Counter", entries) { $0.counter.kind == .approximation ? "\($0.counter.encoding) (estimate)" : $0.counter.encoding }
            row("Est. change vs full", entries) { report in
                TokenChange.describe(baseline: report.originalTokens, candidate: report.selectedTokens)
            }
            row("Retained / excluded", entries) { "\($0.keptCount) / \($0.removedCount)" }
            row("Budget", entries) { report in
                if !report.budgetEnforced { return report.overBudget ? "not applied · over by \(report.overBudgetBy)" : "not applied · within" }
                return report.overBudget ? "over by \(report.overBudgetBy) (protected content)" : "within \(report.budget)"
            }
            GridRow {
                Text("Answer quality").dsColumnHeader()
                ForEach(entries) { _ in DSBadge(text: "Quality not evaluated", systemImage: "questionmark.circle", tone: .neutral) }
            }
        }
        .font(.callout)
        .dsPanel(padding: DS.Space.l)
    }

    private func row(_ title: String, _ entries: [ComparisonEntry], _ value: @escaping (SelectionReport) -> String) -> some View {
        GridRow {
            Text(title).dsColumnHeader()
            ForEach(entries) { Text(value($0.report)).font(DS.Typeface.mono).monospacedDigit().foregroundStyle(DS.textPrimary).textSelection(.enabled) }
        }
    }

    // MARK: Block × variant matrix

    private func matrix(_ entries: [ComparisonEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Decisions by block").font(.headline)
            Text("Select a block to read each configuration’s reason. Keyword scores come from the task-relevance column.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Block").dsColumnHeader()
                    Text("Priority").dsColumnHeader()
                    Text("Keyword score").dsColumnHeader()
                    ForEach(entries) { Text($0.variant.strategy.shortName).dsColumnHeader() }
                }
                Divider()
                ForEach(Array(store.document.draft.blocks.enumerated()), id: \.element.id) { index, block in
                    let relevance = relevanceEntry(entries)?.report.decisions.first(where: { $0.id == block.id })?.relevance
                    GridRow {
                        Button {
                            selectedBlock = selectedBlock == block.id ? nil : block.id
                        } label: {
                            HStack(spacing: 4) {
                                if block.required { Image(systemName: "lock.fill").foregroundStyle(DS.accent).font(.caption) }
                                Text("\(index + 1). \(block.title.isEmpty ? "Untitled context" : block.title)").lineLimit(1)
                            }
                            .frame(minWidth: 200, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selectedBlock == block.id ? DS.accent : DS.textPrimary)
                        .accessibilityHint("Shows the reasons for this block")
                        Text(block.required ? "Required" : ContextPriority.label(block.priority)).font(.caption).foregroundStyle(.secondary)
                        Text(relevance.map { String(format: "%.2f", $0.score) } ?? "—").font(.caption.monospacedDigit())
                            .help(relevance.map { $0.matchedTerms.isEmpty ? "No task terms found" : $0.matchedTerms.map(\.term).joined(separator: ", ") } ?? "")
                        ForEach(entries) { entry in
                            if let decision = entry.report.decisions.first(where: { $0.id == block.id }) {
                                Label(decision.kind.label, systemImage: decision.kind.symbol)
                                    .font(.caption).foregroundStyle(decision.kind.color)
                                    .help(decision.reason)
                            }
                        }
                    }
                }
            }
        }
        .dsPanel(padding: DS.Space.l)
    }

    private func reasons(for id: UUID, _ entries: [ComparisonEntry]) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(entries) { entry in
                    if let decision = entry.report.decisions.first(where: { $0.id == id }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.variant.label).font(.caption.weight(.semibold))
                            DecisionRow(decision: decision, tokenUnit: entry.report.counter.kind == .approximation ? "est." : "tok.")
                        }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Reasons for “\(store.document.draft.blocks.first(where: { $0.id == id })?.title ?? "")”")
        }
    }

    // MARK: Saved comparisons

    private func relevanceEntry(_ entries: [ComparisonEntry]) -> ComparisonEntry? {
        entries.first(where: { $0.variant == .relevanceBudget })
    }

    /// Saved comparison groups, newest first.
    private var savedGroupList: (groups: [UUID: [Experiment]], order: [UUID]) {
        let linked = store.document.experiments.filter { $0.comparison != nil }
        let groups = Dictionary(grouping: linked) { (experiment: Experiment) -> UUID in experiment.comparison!.groupID }
        var newest: [UUID: Date] = [:]
        for (key, members) in groups { newest[key] = members.map(\.createdAt).max() ?? .distantPast }
        let order = groups.keys.sorted { (a: UUID, b: UUID) -> Bool in newest[a, default: .distantPast] > newest[b, default: .distantPast] }
        return (groups, order)
    }

    @ViewBuilder private var savedGroups: some View {
        let list = savedGroupList
        let groups = list.groups
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Saved comparisons").font(.headline)
                ForEach(list.order, id: \.self) { key in
                    let members = groups[key] ?? []
                    Button {
                        store.selectedExperimentID = members.first?.id
                        store.selectedSection = .experiments
                    } label: {
                        HStack {
                            Text(members.first?.comparison?.groupName ?? "Comparison")
                            Spacer()
                            Text("\(members.filter { $0.evaluation.isEvaluated }.count) of \(members.count) evaluated")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
