import Foundation
import RelayCore

/// Where Relay keeps user-supplied secrets. Relay only reads items it wrote itself under its
/// own service name; it never searches for credentials belonging to other applications.
public protocol CredentialStore: Sendable {
    func read(_ account: String) throws -> String?
    func save(_ secret: String, for account: String) throws
    func delete(_ account: String) throws
}

public enum CredentialAccount {
    /// ElevenLabs API key (sent as the `xi-api-key` header).
    public static let elevenLabsAPIKey = "elevenlabs.api-key"
}

public enum CredentialError: Error, Equatable, CustomStringConvertible {
    case empty
    case keychain(Int32)
    case unavailable

    public var description: String {
        switch self {
        case .empty: return "The key is empty"
        case let .keychain(status): return "Keychain error \(status)"
        case .unavailable: return "Secure credential storage is not available on this platform"
        }
    }
}

/// For tests and previews only. Holds secrets in memory for the life of the process.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init() {}
    public func read(_ account: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return values[account] }
    public func save(_ secret: String, for account: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CredentialError.empty }
        lock.lock(); values[account] = trimmed; lock.unlock()
    }
    public func delete(_ account: String) throws { lock.lock(); values[account] = nil; lock.unlock() }
}

/// Loads a secret and registers it with the redactor so it can never appear in logs or exports.
public enum CredentialAccess {
    public static func load(_ account: String, from store: CredentialStore, redactor: Redactor = .shared) -> String? {
        guard let value = try? store.read(account), !value.isEmpty else { return nil }
        redactor.register(secret: value)
        return value
    }

    public static func save(_ secret: String, account: String, to store: CredentialStore,
                            redactor: Redactor = .shared) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CredentialError.empty }
        redactor.register(secret: trimmed)
        try store.save(trimmed, for: account)
    }

    /// Display form: never more than the last 4 characters.
    public static func masked(_ secret: String?) -> String {
        guard let secret, secret.count >= 8 else { return secret == nil ? "Not set" : "••••" }
        return "••••••••" + secret.suffix(4)
    }
}
