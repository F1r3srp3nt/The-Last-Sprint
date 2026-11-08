import AppKit
import Foundation

/// `--self-check <report.json>`: used by CI (.github/scripts/self-check.sh) to confirm that the packaged
/// app really started. About three seconds after launch it writes what the running process sees
/// (bundle identity, Info.plist values, visible windows, bundled resources) to the given file, then
/// quits. It reads nothing else and changes nothing. Ordinary launches never pass the option.
@MainActor enum LaunchSelfCheck {
    static func runIfRequested() {
        guard let path = LaunchOptions.selfCheckReport else { return }
        Task { @MainActor in
            // Give SwiftUI time to create and lay out the first window.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            write(report(), to: path)
            NSApp.terminate(nil)
        }
    }

    private static func report() -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        let resourceFiles = Bundle.main.resourcePath
            .flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0) } ?? []
        let windows = NSApp.windows.filter { $0.isVisible }
        return [
            "app": "Relay",
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "bundlePath": Bundle.main.bundlePath,
            "executable": info["CFBundleExecutable"] as? String ?? "",
            "version": info["CFBundleShortVersionString"] as? String ?? "",
            "build": info["CFBundleVersion"] as? String ?? "",
            "commit": BuildInfo.current.commit ?? "",
            "builtAt": BuildInfo.current.builtAt ?? "",
            "microphoneUsageDescription": info["NSMicrophoneUsageDescription"] != nil,
            "visibleWindows": windows.count,
            "windows": windows.map { "\($0.title) \(Int($0.frame.width))x\(Int($0.frame.height))" },
            "resourceFiles": resourceFiles.sorted(),
            "appearance": NSApp.effectiveAppearance.name.rawValue,
        ]
    }

    private static func write(_ report: [String: Any], to path: String) {
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("self-check: cannot write \(path): \(error)\n".utf8))
        }
    }
}
