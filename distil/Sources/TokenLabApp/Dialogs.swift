import AppKit
import TokenLabCore

/// Modal confirmations using standard macOS alert conventions.
@MainActor enum Dialogs {
    /// Save / Don't Save / Cancel, matching the system document prompt.
    static func askAboutUnsavedChanges(projectName: String, action: String) -> UnsavedChangesChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Do you want to save the changes to “\(projectName)” before \(action)?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don’t Save")
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = [.command]
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    static func confirm(title: String, message: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Warn before writing text that looks like it contains credentials. Values are never shown.
    static func confirmPossibleSecrets(_ findings: [SecretFinding], action: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This may contain credentials"
        let lines = findings.prefix(8).map { "• \($0.location): \($0.kind)" }
        let more = findings.count > 8 ? "\n• …and \(findings.count - 8) more" : ""
        alert.informativeText = "Files are written as plain JSON. Remove secrets before sharing.\n\n" + lines.joined(separator: "\n") + more
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "\(action) Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
