import Foundation
import RelayCore

// ElevenLabs error handling.
//
// Source: https://elevenlabs.io/docs/eleven-api/resources/errors and the help-center pages for
// 400/401, 422 and 429 (read 2026-11-07). Error bodies carry `detail.type`, `detail.code`,
// `detail.message`, `detail.request_id`, and the legacy `detail.status` (older responses use
// `status` instead of `code`, e.g. `quota_exceeded`).
//
// Relay classifies by documented code first, then by documented type, then by HTTP status.
// When none of those is specific, the kind stays general (for example `accessDenied` for a
// bare 403) and the provider's own message is shown, rather than guessing a cause.

/// A request ElevenLabs answered with a non-2xx status.
public struct ElevenLabsRejection: Equatable, Sendable {
    public enum Kind: String, Sendable, Equatable {
        /// 401 / `authentication_error`: the key is invalid, missing, expired, deleted or disabled.
        case invalidCredentials
        /// Explicit `insufficient_permissions` (or legacy `missing_permissions`) code. Says nothing
        /// about which permission unless the message names one.
        case missingPermission
        /// 403 without a more specific code. Inconclusive: does not show whether the key is valid.
        case accessDenied
        /// `feature_not_available` / `subscription_required`.
        case planRestriction
        /// `voice_not_found` / `voice_access_denied`.
        case voiceUnavailable
        /// `model_not_found` / `unsupported_model` / `model_access_denied`.
        case modelUnavailable
        /// 402 / `insufficient_credits` / legacy `quota_exceeded`.
        case creditsExhausted
        /// 429 / `rate_limit_error` (rate, concurrency or `system_busy`).
        case rateLimited
        /// 400 / 422 / `validation_error` / `invalid_request`.
        case invalidRequest
        /// 5xx.
        case serverError
        /// Anything else (including a 404 without a code: the target is ambiguous).
        case unrecognised
    }

    public let kind: Kind
    public let httpStatus: Int
    /// `detail.code`, or the legacy `detail.status`.
    public let code: String?
    public let type: String?
    /// Provider message, redacted and truncated. May be empty.
    public let message: String
    public let requestID: String?

    public init(kind: Kind, httpStatus: Int, code: String?, type: String?, message: String, requestID: String?) {
        self.kind = kind
        self.httpStatus = httpStatus
        self.code = code
        self.type = type
        self.message = message
        self.requestID = requestID
    }

    private static let codeKinds: [String: Kind] = [
        "invalid_api_key": .invalidCredentials, "missing_api_key": .invalidCredentials,
        "invalid_authorization_header": .invalidCredentials, "unauthorized": .invalidCredentials,
        "sign_in_required": .invalidCredentials,
        "insufficient_permissions": .missingPermission, "missing_permissions": .missingPermission,
        "forbidden": .accessDenied, "workspace_access_denied": .accessDenied,
        "feature_not_available": .planRestriction, "subscription_required": .planRestriction,
        "voice_not_found": .voiceUnavailable, "voice_access_denied": .voiceUnavailable,
        "model_not_found": .modelUnavailable, "unsupported_model": .modelUnavailable,
        "model_access_denied": .modelUnavailable,
        "insufficient_credits": .creditsExhausted, "quota_exceeded": .creditsExhausted,
        "rate_limit_exceeded": .rateLimited, "concurrent_limit_exceeded": .rateLimited,
        "too_many_concurrent_requests": .rateLimited, "system_busy": .rateLimited,
    ]

    private static let typeKinds: [String: Kind] = [
        "authentication_error": .invalidCredentials,
        "authorization_error": .accessDenied,
        "payment_required": .creditsExhausted,
        "rate_limit_error": .rateLimited,
        "validation_error": .invalidRequest,
        "invalid_request": .invalidRequest,
        "internal_error": .serverError,
        "service_unavailable": .serverError,
    ]

    /// Classifies a non-2xx response. Pure; the message is passed through `redactor`.
    public static func classify(status: Int, body: Data, redactor: Redactor) -> ElevenLabsRejection {
        var code: String?
        var type: String?
        var message = ""
        var requestID: String?
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let detail = json["detail"] as? [String: Any] {
                code = (detail["code"] as? String) ?? (detail["status"] as? String)
                type = detail["type"] as? String
                message = detail["message"] as? String ?? ""
                requestID = detail["request_id"] as? String
            } else if let detail = json["detail"] as? String {
                message = detail
            } else if let list = json["detail"] as? [[String: Any]] {
                // FastAPI-style validation list (422).
                message = list.compactMap { $0["msg"] as? String }.joined(separator: "; ")
            } else if let m = json["message"] as? String {
                message = m
            }
        } else if !body.isEmpty {
            message = String(decoding: body.prefix(200), as: UTF8.self)
        }

        let kind: Kind
        if let code, let known = codeKinds[code] {
            kind = known
        } else if let type, let known = typeKinds[type] {
            kind = known
        } else {
            switch status {
            case 401: kind = .invalidCredentials
            case 402: kind = .creditsExhausted
            case 403: kind = .accessDenied
            case 429: kind = .rateLimited
            case 400, 422: kind = .invalidRequest
            case 500..<600: kind = .serverError
            default: kind = .unrecognised
            }
        }
        let clean = String(redactor.redact(message).trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        return ElevenLabsRejection(kind: kind, httpStatus: status, code: code.map(redactor.redact), type: type,
                                   message: clean, requestID: requestID.map(redactor.redact))
    }
}

public enum ElevenLabsError: Error, Equatable, CustomStringConvertible {
    case missingAPIKey
    case missingVoiceID
    /// The voice ID field does not contain a voice ID (wrong characters, or it looks like an API key).
    case invalidVoiceID(String)
    case rejected(ElevenLabsRejection)
    case decoding(String)
    /// The request did not complete (offline, DNS, TLS, timeout). Whether it reached ElevenLabs is unknown.
    case network(String)

    public var description: String {
        switch self {
        case .missingAPIKey: return "No ElevenLabs API key saved (Settings)"
        case .missingVoiceID: return "No ElevenLabs voice ID set (Settings)"
        case let .invalidVoiceID(reason): return "Voice ID not usable: \(reason)"
        case let .rejected(r):
            let detail = r.message.isEmpty ? "" : ": \(r.message)"
            let code = r.code.map { " [\($0)]" } ?? ""
            return "ElevenLabs HTTP \(r.httpStatus)\(code)\(detail)"
        case let .decoding(message): return "Could not read ElevenLabs response: \(message)"
        case let .network(message): return "Could not reach ElevenLabs: \(message)"
        }
    }

    public var rejection: ElevenLabsRejection? {
        if case let .rejected(r) = self { return r }
        return nil
    }
}

/// Checks the voice ID field before it is stored or put into a request path.
public enum VoiceIDValidation {
    /// `nil` when the value can be used as a voice ID; otherwise the reason it cannot.
    public static func problem(with raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil } // empty means "not set", handled separately
        if value.lowercased().hasPrefix("sk_") || value.count > 40 {
            return "this looks like an API key, not a voice ID. Paste API keys in step 1 only."
        }
        guard value.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) }) else {
            return "voice IDs contain only letters and digits."
        }
        if value.count < 10 { return "this is too short to be a voice ID." }
        return nil
    }
}
