import SwiftUI
import AppKit
import TokenLabCore

struct ContentView: View {
    @EnvironmentObject private var store: AppStore

    /// Non-optional selection for the sidebar, so the highlight can never be cleared.
    private var sectionSelection: Binding<AppSection> {
        Binding(get: { store.selectedSection ?? .overview },
                set: { store.selectedSection = $0 })
    }

    /// Sidebar width chosen by dragging the handle; clamped to what the window allows.
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 210

    var body: some View {
        // The sidebar is plain SwiftUI with a fixed width, laid out beside the detail pane in one
        // HStack. There is no AppKit split view or adaptive NavigationSplitView at the root, so no
        // section's layout, toolbar or minimum width can collapse the sidebar or blank its rows.
        GeometryReader { proxy in
            let width = Self.sidebarWidth(stored: sidebarWidth, windowWidth: proxy.size.width)
            HStack(spacing: 0) {
                sidebar
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                SidebarResizeHandle(width: $sidebarWidth, range: Self.sidebarMinWidth...Self.sidebarMaxWidth)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DSBackground())
        .groupBoxStyle(DSPanelGroupBoxStyle())
        .tint(DS.accent)
        // The canvas shows through the title bar and toolbar instead of the grey system material.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { store.openProject() } label: { Label("Open Project", systemImage: "folder") }
                    .buttonStyle(.automatic)  // native toolbar look
                    .help("Open a project file (⌘O)")
                Button { _ = store.save() } label: { Label("Save Project", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.automatic)  // native toolbar look
                    .help("Save the project (⌘S)")
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(WindowCloseGuard(isEdited: store.hasUnsavedChanges) { window in
            store.requestCloseWindow(window)
        })
        .alert("Unable to complete action",
               isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    /// Window minimum (760) ≥ sidebar minimum + divider + detail minimum. Each section's own panes
    /// must fit within `detailMinWidth`.
    static let sidebarMinWidth: CGFloat = 180
    static let sidebarMaxWidth: CGFloat = 280
    static let detailMinWidth: CGFloat = 560

    /// The stored width, clamped to 180–280 and to whatever leaves the detail pane its minimum.
    static func sidebarWidth(stored: Double, windowWidth: CGFloat) -> CGFloat {
        let upper = max(sidebarMinWidth, min(sidebarMaxWidth, windowWidth - detailMinWidth - SidebarResizeHandle.thickness))
        return min(max(CGFloat(stored), sidebarMinWidth), upper)
    }

    private var sidebar: some View {
        DSSidebar(groups: sidebarGroups, selection: sectionSelection, topInset: DS.Space.s,
                  brandName: "DISTIL", brandTagline: "Context selection lab") {
            DSStatusCard(rows: [
                DSStatusRow(label: "Project", value: store.hasUnsavedChanges ? "Unsaved changes" : "Saved",
                            systemImage: store.hasUnsavedChanges ? "pencil.circle" : "checkmark.circle",
                            tone: store.hasUnsavedChanges ? .warning : .neutral),
                DSStatusRow(label: "Environment", value: "Local only", systemImage: "desktopcomputer", tone: .accent),
                DSStatusRow(label: "Model connection", value: "None · no network use", systemImage: "bolt.horizontal.circle", tone: .neutral),
                DSStatusRow(label: "Build", value: buildSummary, systemImage: "shippingbox", tone: .neutral)
            ])
            .padding(DS.Space.s)
        }
    }

    /// Version and commit of the running copy (full details in Settings › About this build).
    private var buildSummary: String {
        let build = BuildInfo.current
        return "\(build.version)" + (build.commit.map { " · \($0)" } ?? " · dev")
    }

    private var sidebarGroups: [DSSidebarGroup<AppSection>] {
        let project: [AppSection] = [.overview, .workspace, .comparison, .library, .experiments]
        return [DSSidebarGroup(title: "Project", items: project.map { item($0) }),
                DSSidebarGroup(title: "App", items: [item(.settings)])]
    }

    private func item(_ section: AppSection) -> DSSidebarItem<AppSection> {
        let count = badge(for: section)
        let noun: String
        switch section {
        case .workspace: noun = "context blocks"
        case .library: noun = "library items"
        case .experiments: noun = "experiments"
        default: noun = ""
        }
        return DSSidebarItem(id: section, title: section.title, symbol: section.symbol, badge: count, badgeDescription: "\(count) \(noun)")
    }

    private var detail: some View {
        let section = store.selectedSection ?? .overview
        return VStack(spacing: 0) {
            DSPageHeader(title: section.title, subtitle: section.subtitle, eyebrow: "DISTIL  /  \(section.title.uppercased())")
            Group {
                switch section {
                case .overview: OverviewView()
                case .workspace: WorkspaceView()
                case .comparison: ComparisonView()
                case .library: LibraryView()
                case .experiments: ExperimentsView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Themed defaults for every screen; explicit styles (primary, link, plain, toolbar) win.
            .buttonStyle(.dsSecondary)
            .textFieldStyle(.ds)
        }
        .navigationTitle(section.title)
        .navigationSubtitle(store.windowSubtitle)
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
    }

    private func badge(for section: AppSection) -> Int {
        switch section {
        case .workspace: return store.document.draft.blocks.count
        case .library: return store.document.library.count
        case .experiments: return store.document.experiments.count
        default: return 0
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.hasUnsavedChanges ? DS.warning : DS.textTertiary)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(store.hasUnsavedChanges ? "Unsaved changes" : "Saved")
                .font(.caption.weight(.medium))
                .foregroundStyle(store.hasUnsavedChanges ? DS.warning : DS.textSecondary)
            Text("·").foregroundStyle(DS.textTertiary)
            Text(store.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(store.status)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(DS.surface.opacity(0.85))
        .overlay(alignment: .top) { Rectangle().fill(DS.accent.opacity(0.16)).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

/// Drag to resize the sidebar. Also adjustable with VoiceOver (increment/decrement).
struct SidebarResizeHandle: View {
    static let thickness: CGFloat = 5
    @Binding var width: Double
    let range: ClosedRange<CGFloat>
    @State private var dragStart: Double?
    @State private var hovering = false
    @State private var cursorPushed = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: Self.thickness)
            .frame(maxHeight: .infinity)
            .overlay(Rectangle().fill(DS.accent.opacity(hovering || dragStart != nil ? 0.45 : 0.16)).frame(width: 1))
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                updateCursor()
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? width
                        dragStart = start
                        width = clamp(start + Double(value.translation.width))
                    }
                    .onEnded { _ in dragStart = nil; updateCursor() }
            )
            .onDisappear { if cursorPushed { NSCursor.pop(); cursorPushed = false } }
            .accessibilityElement()
            .accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: width = clamp(width + 10)
                case .decrement: width = clamp(width - 10)
                @unknown default: break
                }
            }
            .help("Drag to resize the sidebar")
    }

    /// Keep the resize cursor while hovering or dragging; push and pop stay balanced.
    private func updateCursor() {
        let wanted = hovering || dragStart != nil
        if wanted && !cursorPushed { NSCursor.resizeLeftRight.push(); cursorPushed = true }
        if !wanted && cursorPushed { NSCursor.pop(); cursorPushed = false }
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, Double(range.lowerBound)), Double(range.upperBound))
    }
}
