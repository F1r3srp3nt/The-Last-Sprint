import Foundation

/// Command-line options used by CI to open a known screen for screenshots, for example
/// `Relay --screenshot-section tasks`. Ordinary launches pass none, so nothing changes. Unknown
/// values are ignored.
enum LaunchOptions {
    static var section: AppSection? { value("--screenshot-section").flatMap(AppSection.init(rawValue:)) }
    /// Where `--self-check` writes its launch report (see `LaunchSelfCheck`).
    static var selfCheckReport: String? { value("--self-check") }

    private static func value(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
