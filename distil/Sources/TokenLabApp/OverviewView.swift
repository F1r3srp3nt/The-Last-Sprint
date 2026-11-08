import SwiftUI
import TokenLabCore

struct OverviewView: View {
    @EnvironmentObject private var store: AppStore

    private var document: ProjectDocument { store.document }
    private var isEmptyProject: Bool {
        store.workspaceIsEmpty && document.draft.blocks.isEmpty && document.library.isEmpty && document.experiments.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !document.notes.isEmpty {
                    Label(document.notes, systemImage: "info.circle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DS.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.panel))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel).strokeBorder(DS.warning.opacity(0.35)))
                }
                if isEmptyProject { gettingStarted }
                if !document.draft.task.isEmpty {
                    GroupBox("Current task") {
                        Text(document.draft.task).textSelection(.enabled)
                            .lineLimit(4)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        MetricTile(title: "Context blocks", value: "\(document.draft.blocks.count)",
                                   caption: "\(document.draft.blocks.filter(\.required).count) required")
                        MetricTile(title: "Library items", value: "\(document.library.count)",
                                   caption: "\(Set(document.draft.blocks.compactMap(\.libraryOrigin)).count) in use")
                        MetricTile(title: "Experiments", value: "\(document.experiments.count)",
                                   caption: "\(document.experiments.filter { $0.evaluation.isEvaluated }.count) evaluated")
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) { settingsBox; previewBox }
                    VStack(alignment: .leading, spacing: 14) { settingsBox; previewBox }
                }
                experimentsBox
                GroupBox("What the numbers mean") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Token counts come from the counter named next to them. The approximate counter is a heuristic; model tokenizers count prompt text only, without message formatting or provider overhead.", systemImage: "number")
                        Label("A reduction is an estimate of input size. It is not a measured cost saving.", systemImage: "chart.line.downtrend.xyaxis")
                        Label("A smaller prompt is not automatically better. Quality stays “Not evaluated” until you compare answers in Experiments.", systemImage: "checkmark.shield")
                        Label("Task relevance is keyword matching, not semantic understanding. A match does not show that a block is useful.", systemImage: "text.magnifyingglass")
                    }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.session.displayName).font(.title2.weight(.semibold)).foregroundStyle(DS.textPrimary).lineLimit(1)
            HStack(spacing: 8) {
                if let url = store.session.fileURL {
                    Label(url.path, systemImage: "doc").lineLimit(1).truncationMode(.middle)
                        .help(url.path)
                } else {
                    Label("Not saved to a file yet", systemImage: "doc.badge.ellipsis")
                }
                if store.hasUnsavedChanges { Pill(text: "Unsaved changes", color: DS.warning, systemImage: "pencil.circle") }
            }
            .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button { store.selectedSection = .workspace } label: { Label("Open Prompt Workspace", systemImage: "text.alignleft") }
                    .buttonStyle(.dsPrimary)
                Button { store.openProject() } label: { Label("Open Project…", systemImage: "folder") }
                Button { _ = store.save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .disabled(!store.hasUnsavedChanges && store.session.fileURL != nil)
            }
            .padding(.top, 6)
        }
    }

    private var gettingStarted: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Get started").font(.headline)
                Text("1. Write the task and the protected instructions.\n2. Add context blocks; mark essentials as required and set priorities.\n3. Choose a strategy and budget, then inspect every decision in the preview.\n4. Compare all four configurations, save them as experiments and review the answers each prompt produces.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Demonstrations (synthetic; not benchmark evidence):").font(.callout.weight(.medium))
                ForEach(DemoDataset.ID.allCases) { id in
                    Button { store.loadDemo(id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(id.title).fontWeight(.medium)
                            Text(id.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                HStack {
                    Button("Load Example Project") { store.loadExample() }
                    Button("Start in Workspace") { store.selectedSection = .workspace }
                    Button("Open Project…") { store.openProject() }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var settingsBox: some View {
        GroupBox("Selection settings") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Strategy", value: document.settings.strategy.displayName)
                LabeledContent("Budget", value: "\(document.settings.budget) (\(document.settings.enforcesBudget ? "enforced" : "reported only"))")
                LabeledContent("Deduplication", value: document.settings.deduplicates ? "Exact" : "Off")
                LabeledContent("Counter", value: document.settings.counter.shortName)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var previewBox: some View {
        GroupBox("Current preview") {
            VStack(alignment: .leading, spacing: 6) {
                if let report = store.currentReport {
                    LabeledContent("Full context", value: "\(report.originalTokens)")
                    LabeledContent("Selected", value: "\(report.selectedTokens)")
                    LabeledContent("Estimated reduction", value: percentString(report.estimatedReductionPercent))
                    LabeledContent("Kept / removed", value: "\(report.keptCount) / \(report.removedCount)")
                    if report.overBudget {
                        Label("Over budget by \(report.overBudgetBy)", systemImage: "exclamationmark.triangle").foregroundStyle(DS.warning)
                    }
                } else {
                    Text(store.hasStaleReport ? "The last preview is out of date." : "No current preview.")
                        .foregroundStyle(.secondary)
                    Button("Go to Prompt Workspace") { store.selectedSection = .workspace }
                        .buttonStyle(.link)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var experimentsBox: some View {
        GroupBox("Recent experiments") {
            VStack(alignment: .leading, spacing: 8) {
                if document.experiments.isEmpty {
                    Text("None yet. Save a preview as an experiment to compare full and selected context.")
                        .foregroundStyle(.secondary)
                }
                ForEach(document.experiments.prefix(4)) { experiment in
                    Button {
                        store.selectedExperimentID = experiment.id
                        store.selectedSection = .experiments
                    } label: {
                        HStack {
                            Text(experiment.name).lineLimit(1)
                            Spacer()
                            VerdictBadge(evaluation: experiment.evaluation)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
