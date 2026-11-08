import SwiftUI
import TokenLabCore

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var search = ""
    @State private var category: ContextCategory?
    @State private var pendingDeletion: ContextBlock?

    private var filtered: [ContextBlock] {
        store.document.library.filter { block in
            (category == nil || block.category == category) &&
            (search.isEmpty || block.title.localizedCaseInsensitiveContains(search) || block.text.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                Picker("Category", selection: $category) {
                    Text("All categories").tag(ContextCategory?.none)
                    Divider()
                    ForEach(ContextCategory.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag(ContextCategory?.some($0)) }
                }
                .labelsHidden()
                .padding(10)
                .accessibilityLabel("Filter by category")
                Divider()
                List(filtered, selection: $store.selectedLibraryID) { item in
                    LibraryRow(item: item, uses: store.workspaceUses(ofLibraryItem: item.id))
                        .tag(item.id)
                        .contextMenu { rowMenu(item) }
                }
                .scrollContentBackground(.hidden)
                .overlay { emptyState }
            }
            .background(DS.surface.opacity(0.45))
            .frame(minWidth: 220, idealWidth: 290, maxWidth: 420, maxHeight: .infinity)

            Group {
                if let id = store.selectedLibraryID, let binding = store.libraryBinding(id) {
                    LibraryDetail(item: binding, uses: store.workspaceUses(ofLibraryItem: id),
                                  onDelete: { pendingDeletion = binding.wrappedValue })
                } else {
                    ContentUnavailableView("Select a library item", systemImage: "books.vertical",
                                           description: Text("Library items are reusable context. Inserting one into the workspace creates an independent copy."))
                }
            }
            .frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search titles and text")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { store.newLibraryItem() } label: { Label("New Item", systemImage: "plus") }
                    .buttonStyle(.automatic)  // native toolbar look
                    .help("Create a library item")
                    .disabled(store.document.library.count >= ProjectDocument.maxLibraryItems)
            }
        }
        .confirmationDialog("Delete “\(pendingDeletion?.title ?? "")” from the library?",
                            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("Delete Item", role: .destructive) {
                if let item = pendingDeletion { store.deleteLibraryItem(item.id) }
                pendingDeletion = nil
            }
        } message: {
            Text("Copies already inserted into the workspace and saved experiments are not affected.")
        }
    }

    @ViewBuilder private var emptyState: some View {
        if store.document.library.isEmpty {
            ContentUnavailableView {
                Label("Library is empty", systemImage: "books.vertical")
            } description: {
                Text("Create an item, or use “Copy to Library” on a workspace block.")
            } actions: {
                Button("New Item") { store.newLibraryItem() }
            }
        } else if filtered.isEmpty {
            if search.isEmpty {
                ContentUnavailableView("No items in this category", systemImage: "line.3.horizontal.decrease.circle")
            } else {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    @ViewBuilder private func rowMenu(_ item: ContextBlock) -> some View {
        Button("Insert into Workspace") { store.useLibraryItem(item.id) }
        Button("Duplicate") { store.duplicateLibraryItem(item.id) }
        Divider()
        Button("Delete…", role: .destructive) { pendingDeletion = item }
    }
}

struct LibraryRow: View {
    let item: ContextBlock
    let uses: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: item.category.symbol).foregroundStyle(.secondary).frame(width: 16).accessibilityHidden(true)
                Text(item.title.isEmpty ? "Untitled context" : item.title).fontWeight(.medium).lineLimit(1)
            }
            Text(item.text.isEmpty ? "No text" : item.text)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 6) {
                Text(item.category.rawValue)
                Text("·")
                Text(ContextPriority.label(item.priority))
                if uses > 0 { Text("·"); Text("In workspace ×\(uses)") }
            }
            .font(.caption2).foregroundStyle(DS.textTertiary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

struct LibraryDetail: View {
    @EnvironmentObject private var store: AppStore
    @Binding var item: ContextBlock
    let uses: Int
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button { store.useLibraryItem(item.id) } label: { Label("Insert into Workspace", systemImage: "arrow.down.doc") }
                        .buttonStyle(.dsPrimary)
                        .disabled(item.text.isEmpty)
                    Button { store.duplicateLibraryItem(item.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Spacer()
                    Button(role: .destructive, action: onDelete) { Label("Delete…", systemImage: "trash") }
                }
                ContextBlockEditor(block: $item, tokenLabel: store.liveCountLabel(item.text), decision: nil, actions: [])
                Text(uses == 0
                     ? "Not currently used in the workspace."
                     : "Used \(uses) time\(uses == 1 ? "" : "s") in the workspace. Those copies are independent: edits here do not change them.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("The required flag and priority are copied with the item and can be changed on each workspace copy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }
}
