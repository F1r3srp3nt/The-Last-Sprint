import Foundation

public enum UnsavedChangesChoice: Sendable {
    case save, discard, cancel
}

/// The open project plus what is needed to detect unsaved work. Contains no UI code so the
/// replace/open/close rules can be tested without AppKit.
public struct ProjectSession: Equatable {
    public var document: ProjectDocument
    /// The state last written to or read from `fileURL`. For untitled work this is an empty project,
    /// so any content counts as unsaved.
    public private(set) var savedDocument: ProjectDocument
    public private(set) var fileURL: URL?

    public init() {
        document = ProjectDocument(); savedDocument = document; fileURL = nil
    }

    public var hasUnsavedChanges: Bool { document != savedDocument }

    public var displayName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled project"
    }

    /// A new untitled session holding `document` (for example the sample project).
    public static func untitled(_ document: ProjectDocument) -> ProjectSession {
        var session = ProjectSession()
        session.document = document
        return session
    }

    /// Decode and validate a file into a new session without touching any existing state.
    /// Migrated files are opened as untitled, so saving never silently overwrites the old-format file.
    public static func opening(data: Data, url: URL) throws -> (session: ProjectSession, loaded: ProjectCodec.Loaded) {
        let loaded = try ProjectCodec.load(data)
        var session = ProjectSession()
        session.document = loaded.document
        if !loaded.wasMigrated {
            session.savedDocument = loaded.document
            session.fileURL = url
        }
        return (session, loaded)
    }

    /// Record a successful write of `written` to `url`. Edits made after `written` was encoded stay unsaved.
    public mutating func didSave(_ written: ProjectDocument, to url: URL) {
        savedDocument = written
        fileURL = url
    }

    /// Decide whether an action that would replace or close the current project may proceed.
    /// - `ask` is called only when there are unsaved changes.
    /// - `save` is called only when the user chose to save; proceeding requires it to succeed.
    public static func mayProceed(hasUnsavedChanges: Bool, ask: () -> UnsavedChangesChoice, save: () -> Bool) -> Bool {
        guard hasUnsavedChanges else { return true }
        switch ask() {
        case .cancel: return false
        case .discard: return true
        case .save: return save()
        }
    }
}
