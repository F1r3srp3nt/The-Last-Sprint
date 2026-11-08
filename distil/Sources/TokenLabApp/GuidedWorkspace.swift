import SwiftUI
import TokenLabCore

// MARK: - Step headers

/// Numbered workflow step: 1 Describe → 2 Context → 3 Strategy → 4 Review → 5 Copy.
struct StepHeader: View {
    let number: Int
    let title: String
    let detail: String
    var done = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ZStack {
                Circle().fill(done ? DS.accent.opacity(0.22) : DS.surfaceRaised)
                Circle().strokeBorder(DS.accent.opacity(done ? 0.8 : 0.4))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.accent)
                } else {
                    Text("\(number)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(DS.accent)
                }
            }
            .frame(width: 22, height: 22)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold)).foregroundStyle(DS.textPrimary)
                Text(detail).font(.caption).foregroundStyle(DS.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(title)\(done ? ", done" : "")")
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Paste Context

struct PasteContextSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case split = "Split into blocks", single = "Keep as one block"
        var id: String { rawValue }
    }

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = "Pasted context"
    @State private var text = ""
    @State private var mode: Mode = .split
    @State private var proposals: [ProposedBlock]? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("PASTE CONTEXT").font(DS.Typeface.eyebrow).tracking(1.4).foregroundStyle(DS.accent)
                Text(proposals == nil ? "Paste documentation, notes, requirements or code" : "Review the proposed blocks")
                    .font(DS.Typeface.pageTitle).foregroundStyle(DS.textPrimary)
            }
            if let proposals {
                review(proposals)
            } else {
                edit
            }
        }
        .padding(22)
        .frame(minWidth: 620, idealWidth: 760, minHeight: 520, idealHeight: 660)
        .background(DS.canvas)
        .groupBoxStyle(DSPanelGroupBoxStyle())
        .tint(DS.accent)
    }

    // Step A: paste and choose how to split.
    private var edit: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name of the source", text: $title).textFieldStyle(.ds).frame(maxWidth: 360)
            CodeEditor(text: $text, minHeight: 260, maxHeight: .infinity, accessibilityLabel: "Pasted text")
            Picker("How to add it", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).frame(maxWidth: 420)
            Text(verbatim: mode == .split
                 ? "Splits at Markdown headings when there are any, otherwise at blank lines between paragraphs. Fenced code blocks (``` or ~~~) are never split. Block text is copied exactly: nothing is rewritten, summarised or shortened."
                 : "Adds the whole paste as a single block, exactly as pasted.")
                .font(.caption).foregroundStyle(DS.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("\(text.utf8.count.formatted()) bytes").font(.caption.monospacedDigit()).foregroundStyle(DS.textTertiary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Preview Blocks") {
                    proposals = mode == .split ? ContextSplitter.split(text)
                                               : ContextSplitter.keepAsOneBlock(text, title: title.isEmpty ? "Pasted context" : title)
                }
                .buttonStyle(.dsPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // Step B: preview, name, mark required, confirm.
    private func review(_ blocks: [ProposedBlock]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(blocks.count) block\(blocks.count == 1 ? "" : "s") from “\(title)”. Optional blocks may be left out by the selected strategy; mark anything the task cannot do without as Required. The complete original paste is kept in the project.",
                  systemImage: "info.circle")
                .font(.callout).foregroundStyle(DS.textSecondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("\(index + 1)").font(.caption.monospacedDigit().weight(.bold)).foregroundStyle(DS.textTertiary)
                                    TextField("Block name", text: binding(index, \.title)).textFieldStyle(.ds)
                                    Picker("Category", selection: binding(index, \.category)) {
                                        ForEach(ContextCategory.allCases) { Text($0.rawValue).tag($0) }
                                    }
                                    .labelsHidden().fixedSize()
                                    Toggle("Required", isOn: binding(index, \.required)).toggleStyle(.checkbox)
                                }
                                PromptTextView(title: "\(block.text.utf8.count.formatted()) bytes", text: block.text, minHeight: 40, maxHeight: 140)
                            }
                        }
                    }
                }
            }
            HStack {
                Button("Back") { proposals = nil }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(blocks.count) Block\(blocks.count == 1 ? "" : "s")") {
                    if store.addPastedContext(title: title.isEmpty ? "Pasted context" : title, original: text, blocks: blocks) { dismiss() }
                }
                .buttonStyle(.dsPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(blocks.isEmpty)
            }
        }
    }

    private func binding<Value>(_ index: Int, _ keyPath: WritableKeyPath<ProposedBlock, Value>) -> Binding<Value> {
        Binding(get: { proposals?[index][keyPath: keyPath] ?? ProposedBlock(title: "", text: "", category: .reference)[keyPath: keyPath] },
                set: { newValue in
                    guard var current = proposals, current.indices.contains(index) else { return }
                    current[index][keyPath: keyPath] = newValue
                    proposals = current
                })
    }
}

/// The exact pasted originals, recoverable at any time.
struct PastedOriginalsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var viewing: PastedSource?

    var body: some View {
        if !store.document.pastedSources.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.document.pastedSources) { source in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(source.title).font(.callout.weight(.medium)).foregroundStyle(DS.textPrimary)
                                Text("\(source.text.utf8.count.formatted()) bytes · pasted \(source.importedAt.formatted(date: .abbreviated, time: .shortened)) · \(store.document.draft.blocks.filter { $0.pastedSourceID == source.id }.count) block(s) in the workspace")
                                    .font(.caption).foregroundStyle(DS.textSecondary)
                            }
                            Spacer()
                            Button("View") { viewing = source }
                            Button("Copy") { store.copyToPasteboard(source.text, what: "the original “\(source.title)”") }
                            Button("Remove…", role: .destructive) { store.removePastedSource(source.id) }
                        }
                        .controlSize(.small)
                    }
                    Text("Originals are stored exactly as pasted. Removing one does not remove blocks made from it.")
                        .font(.caption).foregroundStyle(DS.textTertiary)
                }
                .padding(.top, 4)
            } label: {
                Label("Pasted originals (\(store.document.pastedSources.count))", systemImage: "doc.on.clipboard")
                    .font(.callout)
            }
            .sheet(item: $viewing) { source in
                VStack(alignment: .leading, spacing: 12) {
                    Text(source.title).font(DS.Typeface.pageTitle).foregroundStyle(DS.textPrimary)
                    PromptTextView(title: "Original, exactly as pasted", text: source.text, minHeight: 300, maxHeight: .infinity) {
                        store.copyToPasteboard(source.text, what: "the original “\(source.title)”")
                    }
                    HStack { Spacer(); Button("Done") { viewing = nil }.buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction) }
                }
                .padding(22)
                .frame(minWidth: 560, idealWidth: 720, minHeight: 420, idealHeight: 600)
                .dsSheetContent()
            }
        }
    }
}

// MARK: - Result review

extension SelectionOutcome {
    var tone: DSTone {
        switch self {
        case .noContext, .fullContextRetained, .nothingRemoved: return .neutral
        case .duplicatesRemoved, .excludedForBudget: return .accent
        case .protectedExceedsBudget: return .warning
        }
    }
    var symbol: String {
        switch self {
        case .noContext: return "tray"
        case .fullContextRetained: return "square.stack.3d.up"
        case .nothingRemoved: return "equal.circle"
        case .duplicatesRemoved: return "doc.on.doc"
        case .excludedForBudget: return "line.3.horizontal.decrease.circle"
        case .protectedExceedsBudget: return "exclamationmark.triangle.fill"
        }
    }
}

/// Plain statement of what the selection did. Never claims optimisation or preserved quality.
struct OutcomeBanner: View {
    let outcome: SelectionOutcome
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            DSIconTile(systemImage: outcome.symbol, tone: outcome.tone, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(outcome.title).font(.headline).foregroundStyle(DS.textPrimary)
                Text(outcome.explanation).font(.callout).foregroundStyle(DS.secondaryText(contrast))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Answer quality has not been evaluated.").font(.caption).foregroundStyle(DS.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .dsPanel(padding: 12, raised: true, highlighted: outcome.tone == .warning)
        .accessibilityElement(children: .combine)
    }
}

/// Full text of one block and why it was kept or left out, with a way to make it Required.
struct BlockInspector: View {
    @EnvironmentObject private var store: AppStore
    let decision: BlockDecision

    private var block: ContextBlock? { store.document.draft.blocks.first(where: { $0.id == decision.id }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(decision.reason).font(.callout).foregroundStyle(DS.textPrimary).fixedSize(horizontal: false, vertical: true)
            if let relevance = decision.relevance { RelevanceTermsView(relevance: relevance) }
            if let block {
                PromptTextView(title: "Full text · \(block.category.rawValue) · \(ContextPriority.label(block.priority)) priority", text: block.text,
                               minHeight: 60, maxHeight: 260) {
                    store.copyToPasteboard(block.text, what: "“\(decision.title)”")
                }
            }
            HStack {
                if decision.required {
                    Label("Required: always kept verbatim", systemImage: "lock.fill").font(.caption).foregroundStyle(DS.accent)
                } else {
                    Button { store.markRequired(decision.id) } label: {
                        Label(decision.kept ? "Mark Required" : "Mark Required and Update", systemImage: "lock")
                    }
                    .help("Required blocks are always kept, even over budget. The selection runs again.")
                }
                Spacer()
                Button { store.revealBlock(decision.id) } label: { Label("Edit in Workspace", systemImage: "pencil") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(DS.surfaceSunken.opacity(0.6), in: RoundedRectangle(cornerRadius: DS.Radius.control))
    }
}
