import SwiftUI
import AppKit
import TokenLabCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: AppStore?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Apply the stored appearance before the first window draws (Futuristic by default).
        DSAppearance.apply(.stored)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run`, which starts a bare executable rather than an app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        LaunchSelfCheck.runIfRequested()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, !store.allowTerminationWithoutPrompt else { return .terminateNow }
        return store.confirmUnsavedChanges(before: "quitting") ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct TokenLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore()

    init() {
        PreferenceMigration.run()
        // Existing installations on "Match System" (the earlier default) move to Futuristic once;
        // an explicit Dark or Light choice is kept.
        DSAppearance.migrateStoredPreference()
    }
    @AppStorage(StoredPreference.appearance) private var appearance = DSAppearance.futuristic.rawValue

    var body: some Scene {
        Window("Distil", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(store.encodings)
                .dsAppearance(DSAppearance.resolve(appearance))
                .onAppear {
                    delegate.store = store
                    LaunchOptions.apply(to: store)
                }
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { store.newProject() }
                    .keyboardShortcut("n")
                Button("Open Project…") { store.openProject() }
                    .keyboardShortcut("o")
                Divider()
                Button("Load Example Project") { store.loadExample() }
                Menu("Load Demonstration") {
                    ForEach(DemoDataset.ID.allCases) { id in
                        Button(id.title) { store.loadDemo(id) }
                    }
                }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Window") { store.requestCloseWindow(NSApp.keyWindow ?? NSApp.mainWindow) }
                    .keyboardShortcut("w")
                Button("Save Project") { _ = store.save() }
                    .keyboardShortcut("s")
                Button("Save Project As…") { _ = store.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Export Current Report…") { store.exportReport() }
                    .keyboardShortcut("e")
                    .disabled(store.currentReport == nil)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { store.selectedSection = .settings }
                    .keyboardShortcut(",")
            }
            CommandMenu("Prompt") {
                Button("Update Preview") { store.preview() }
                    .keyboardShortcut(.return)
                Button("Save Preview as Experiment") { store.saveExperiment() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(store.currentReport == nil)
                Button("Copy Selected Prompt") { store.copySelectedPrompt() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(store.currentReport == nil)
                Divider()
                Button("Run Comparison") { store.selectedSection = .comparison; store.runComparison() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Save Comparison as Experiments") { store.saveComparison() }
                    .disabled(store.currentComparison == nil)
                Divider()
                Button("Add Context Block") { store.addWorkspaceBlock() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("New Library Item") { store.selectedSection = .library; store.newLibraryItem() }
            }
            CommandGroup(after: .sidebar) {
                Divider()
                ForEach(AppSection.allCases) { section in
                    Button(section.title) { store.selectedSection = section }
                        .keyboardShortcut(KeyEquivalent(section.shortcutKey), modifiers: .command)
                }
            }
        }
    }
}
