import Foundation

/// Identifies the running copy of Distil, so it is clear which build is open.
struct BuildInfo {
    let version: String
    let build: String
    let commit: String?
    let builtAt: String?
    let launchMode: String
    let configuration: String
    let executablePath: String
    let executableModified: Date?

    static let current: BuildInfo = {
        let info = Bundle.main.infoDictionary ?? [:]
        let bundled = Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        let modified = (try? FileManager.default.attributesOfItem(atPath: executable.path)[.modificationDate]) as? Date
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        return BuildInfo(
            version: info["CFBundleShortVersionString"] as? String ?? "0.5.0 (unbundled)",
            build: info["CFBundleVersion"] as? String ?? "development",
            commit: info["DistilGitCommit"] as? String,
            builtAt: info["DistilBuildDate"] as? String,
            launchMode: bundled ? "App bundle: \(Bundle.main.bundleURL.path)" : "Unbundled executable (swift run or Xcode)",
            configuration: configuration,
            executablePath: executable.path,
            executableModified: modified)
    }()
}

/// Preferences of an unbundled executable are stored under its process name. The executable was
/// renamed from TokenLab to Distil, so copy the two app preferences across once, without overwriting.
enum PreferenceMigration {
    static func run() {
        guard Bundle.main.bundleIdentifier == nil,
              let legacy = UserDefaults.standard.persistentDomain(forName: "TokenLab") else { return }
        for key in [StoredPreference.appearance, StoredPreference.autoPreview]
        where UserDefaults.standard.object(forKey: key) == nil {
            if let value = legacy[key] { UserDefaults.standard.set(value, forKey: key) }
        }
    }
}
