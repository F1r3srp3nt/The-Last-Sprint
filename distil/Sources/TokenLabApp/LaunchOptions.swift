import Foundation
import TokenLabCore

/// Command-line options used by CI to open a known screen for screenshots, for example
/// `Distil --screenshot-demo pastedNotes --screenshot-section workspace`. Ordinary launches pass
/// none, so nothing changes. Unknown values are ignored.
enum LaunchOptions {
    static var demo: DemoDataset.ID? { value("--screenshot-demo").flatMap(DemoDataset.ID.init(rawValue:)) }
    static var section: AppSection? { value("--screenshot-section").flatMap(AppSection.init(rawValue:)) }
    /// Where `--self-check` writes its launch report (see `LaunchSelfCheck`).
    static var selfCheckReport: String? { value("--self-check") }

    @MainActor private static var applied = false

    /// Loads the requested demonstration, then opens the requested section. Runs once per launch.
    @MainActor static func apply(to store: AppStore) {
        guard !applied else { return }
        applied = true
        if let demo { store.loadDemo(demo) }
        if let section { store.selectedSection = section }
    }

    private static func value(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
