import Foundation

/// Interface for future model-provider adapters. No adapter is implemented in this version:
/// the app makes no network requests and never asks for API keys.
///
/// Rules for future adapters:
/// - Credentials come from a `CredentialSource` at call time (for example the macOS Keychain).
///   They must never be stored in `ProjectDocument`, experiments, exports or log text.
/// - The adapter must return the provider's own usage numbers unmodified in `ProviderUsage`,
///   so they stay separate from local token estimates.
/// - Each call is explicit and user-initiated; nothing is sent in the background.
public protocol ModelProviderAdapter: Sendable {
    var id: String { get }
    var displayName: String { get }
    func complete(_ request: ProviderRequest, credentials: CredentialSource) async throws -> ProviderResponse
}

public struct ProviderRequest: Equatable, Sendable {
    public var model: String
    public var prompt: String
    public var maxOutputTokens: Int
    public init(model: String, prompt: String, maxOutputTokens: Int) {
        self.model = model; self.prompt = prompt; self.maxOutputTokens = maxOutputTokens
    }
}

public struct ProviderResponse: Equatable, Sendable {
    public var text: String
    /// Usage as reported by the provider. `nil` if the provider did not report it.
    public var usage: ProviderUsage?
    public init(text: String, usage: ProviderUsage?) { self.text = text; self.usage = usage }

    /// Convert into a run record for an experiment's evaluation.
    public var asModelRun: ModelRun { ModelRun(responseText: text, usage: usage ?? ProviderUsage()) }
}

/// Supplies a secret at call time. Implementations must not persist or log the value.
public protocol CredentialSource: Sendable {
    func secret(for providerID: String) async throws -> String
}

public enum ProviderRegistry {
    /// Intentionally empty: live model calls are out of scope for this iteration.
    public static let adapters: [any ModelProviderAdapter] = []
}
