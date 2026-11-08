import Foundation

/// Removes credentials from text before it is logged, displayed in the activity view or exported.
///
/// Two layers:
/// 1. Exact values registered at runtime (e.g. the API key the user just saved) are always replaced.
/// 2. Pattern rules catch credential-shaped text that was never registered.
public final class Redactor: @unchecked Sendable {
    public static let placeholder = "[REDACTED]"

    private let lock = NSLock()
    private var secrets: Set<String> = []

    public init() {}

    /// Shared instance used by the default event log.
    public static let shared = Redactor()

    /// Register a secret value so that any later occurrence is replaced. Values shorter than
    /// 6 characters are ignored to avoid redacting ordinary words.
    public func register(secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else { return }
        lock.lock(); secrets.insert(trimmed); lock.unlock()
    }

    public func unregister(secret: String) {
        lock.lock(); secrets.remove(secret.trimmingCharacters(in: .whitespacesAndNewlines)); lock.unlock()
    }

    public func redact(_ text: String) -> String {
        lock.lock(); let known = secrets; lock.unlock()
        var output = text
        // Longest first so overlapping secrets are fully removed.
        for secret in known.sorted(by: { $0.count > $1.count }) {
            output = output.replacingOccurrences(of: secret, with: Self.placeholder)
        }
        for rule in Self.rules {
            output = rule.apply(to: output)
        }
        return output
    }

    public func redact(_ dictionary: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in dictionary {
            if Self.isSensitiveKey(key) {
                result[key] = Self.placeholder
            } else {
                result[key] = redact(value)
            }
        }
        return result
    }

    /// Header / field names whose values are always secret.
    public static func isSensitiveKey(_ key: String) -> Bool {
        let k = key.lowercased()
        return k == "xi-api-key" || k == "authorization" || k.contains("api_key") || k.contains("apikey")
            || k.contains("api-key") || k.contains("token") || k.contains("secret") || k.contains("password")
            || k.contains("team-key") || k.contains("team_key") || k.contains("teamkey")
    }

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
        func apply(to text: String) -> String {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
        }
    }

    private static let rules: [Rule] = {
        func rule(_ pattern: String, _ template: String) -> Rule {
            // Patterns are static and tested; a failure here is a programming error.
            let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            return Rule(regex: regex, template: template)
        }
        return [
            // HTTP header style: "xi-api-key: value", "Authorization: Bearer value"
            rule(#"(xi-api-key\s*[:=]\s*)["']?[^\s"',}]+"#, "$1" + placeholder),
            rule(#"(authorization\s*[:=]\s*)(bearer\s+)?["']?[^\s"',}]+"#, "$1$2" + placeholder),
            rule(#"(bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#, "$1" + placeholder),
            // key=value / "key": "value" for common credential names
            rule(#"((?:api[_-]?key|access[_-]?token|secret|password|token)["']?\s*[:=]\s*["']?)[^\s"',}&]{6,}"#,
                 "$1" + placeholder),
            // ElevenLabs-style keys ("sk_" prefix followed by a long token)
            rule(#"\bsk_[A-Za-z0-9]{16,}\b"#, placeholder),
            // Wybe Night Shift team keys ("ns_" prefix, shown on the organisers' registration page)
            rule(#"\bns_[A-Za-z0-9_-]{8,}"#, placeholder),
        ]
    }()
}
