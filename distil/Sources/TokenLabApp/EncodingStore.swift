import SwiftUI
import AppKit
import TokenLabCore

/// Manages tokenizer vocabulary files the user has imported. Files are verified by SHA-256,
/// copied to Application Support, and loaded lazily. Nothing is downloaded by the app.
@MainActor final class EncodingStore: ObservableObject {
    enum State: Equatable {
        case notInstalled
        case installed
        case loading
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .notInstalled: return "Not imported"
            case .installed: return "Imported (loads when first used)"
            case .loading: return "Loading…"
            case .ready: return "Ready"
            case .failed(let message): return "Unavailable: \(message)"
            }
        }
    }

    @Published private(set) var states: [BPEEncodingID: State] = [:]
    private var tokenizers: [BPEEncodingID: BPETokenizer] = [:]
    private var loadTasks: [BPEEncodingID: Task<BPETokenizer, Error>] = [:]

    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.directory = support.appendingPathComponent("TokenLab/Encodings", isDirectory: true)
        }
        refresh()
    }

    func fileURL(_ id: BPEEncodingID) -> URL { directory.appendingPathComponent(id.spec.fileName) }

    func state(_ id: BPEEncodingID) -> State { states[id] ?? .notInstalled }

    func refresh() {
        for id in BPEEncodingID.allCases {
            if tokenizers[id] != nil { states[id] = .ready }
            else if loadTasks[id] != nil { states[id] = .loading }
            else if case .failed = states[id] { continue }
            else { states[id] = FileManager.default.fileExists(atPath: fileURL(id).path) ? .installed : .notInstalled }
        }
    }

    /// Resolver over the tokenizers loaded so far. Approximate counters are always available.
    func resolver() -> StaticCounterResolver { StaticCounterResolver(tokenizers: tokenizers) }

    func counter(for choice: CounterChoice) async throws -> any TokenCounter {
        switch choice {
        case .approximate:
            return try resolver().counter(for: choice)
        case .bpe(let id):
            try choice.validate()
            return try await load(id)
        }
    }

    func load(_ id: BPEEncodingID) async throws -> BPETokenizer {
        if let tokenizer = tokenizers[id] { return tokenizer }
        if let task = loadTasks[id] { return try await task.value }
        let url = fileURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LabError.counterUnavailable("The \(id.rawValue) encoding file has not been imported. Import it in Settings → Token counting, or switch this project to the approximate counter.")
        }
        let spec = id.spec
        let task = Task.detached(priority: .userInitiated) { try BPETokenizer(spec: spec, fileData: Data(contentsOf: url)) }
        loadTasks[id] = task
        states[id] = .loading
        do {
            let tokenizer = try await task.value
            tokenizers[id] = tokenizer
            loadTasks[id] = nil
            states[id] = .ready
            return tokenizer
        } catch {
            loadTasks[id] = nil
            states[id] = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Verify and copy a user-chosen file. The existing import is kept if verification fails.
    func importFile(_ id: BPEEncodingID, from source: URL) async throws {
        let spec = id.spec
        let (tokenizer, data) = try await Task.detached(priority: .userInitiated) { () throws -> (BPETokenizer, Data) in
            let data = try Data(contentsOf: source)
            return (try BPETokenizer(spec: spec, fileData: data), data)
        }.value
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(id), options: .atomic)
        tokenizers[id] = tokenizer
        states[id] = .ready
    }

    func remove(_ id: BPEEncodingID) throws {
        let url = fileURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        tokenizers[id] = nil
        states[id] = nil
        refresh()
    }

    func removeAll() throws {
        for id in BPEEncodingID.allCases { try remove(id) }
    }
}
