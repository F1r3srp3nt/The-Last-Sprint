import Foundation

/// Warns before writing files that appear to contain credentials. Findings name the location and the
/// kind of pattern only; the matched value is never echoed.
public struct SecretFinding: Equatable, Hashable, Sendable {
    public var location: String
    public var kind: String
}

public enum SecretScanner {
    static let patterns: [(kind: String, regex: NSRegularExpression)] = rawPatterns.map {
        (kind: $0.kind, regex: try! NSRegularExpression(pattern: $0.pattern))
    }

    private static let rawPatterns: [(kind: String, pattern: String)] = [
        ("private key block", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        ("“sk-” style API key", #"\bsk-[A-Za-z0-9_\-]{20,}"#),
        ("cloud access key ID", #"\bAKIA[0-9A-Z]{16}\b"#),
        ("source-hosting access token", #"\bgh[pousr]_[A-Za-z0-9]{30,}"#),
        ("chat workspace token", #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#),
        ("“AIza” style API key", #"\bAIza[0-9A-Za-z_\-]{35}"#),
        ("bearer authorization header", #"(?i)authorization:\s*bearer\s+[A-Za-z0-9._\-]{20,}"#)
    ]

    public static func kinds(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let range = NSRange(location: 0, length: NSString(string: text).length)
        return patterns.filter { $0.regex.firstMatch(in: text, range: range) != nil }.map(\.kind)
    }

    public static func scan(_ document: ProjectDocument) -> [SecretFinding] {
        var findings: [SecretFinding] = []
        func check(_ text: String, _ location: String) {
            findings += kinds(in: text).map { SecretFinding(location: location, kind: $0) }
        }
        check(document.draft.instructions, "Workspace instructions")
        for block in document.draft.blocks { check(block.text, "Workspace block “\(block.title)”") }
        for block in document.library { check(block.text, "Library item “\(block.title)”") }
        for experiment in document.experiments {
            findings += scan(experiment.snapshot).map { SecretFinding(location: "Experiment “\(experiment.name)”: \($0.location)", kind: $0.kind) }
            check(experiment.evaluation.fullContextRun.responseText, "Experiment “\(experiment.name)”: full-context answer")
            check(experiment.evaluation.selectedContextRun.responseText, "Experiment “\(experiment.name)”: selected-context answer")
            check(experiment.evaluation.reviewerNotes, "Experiment “\(experiment.name)”: reviewer notes")
        }
        return Array(Set(findings)).sorted { ($0.location, $0.kind) < ($1.location, $1.kind) }
    }

    public static func scan(_ report: SelectionReport) -> [SecretFinding] {
        // The original prompt contains every non-empty block, so it covers the selected prompt too.
        kinds(in: report.originalPrompt).map { SecretFinding(location: "prompt text", kind: $0) }
    }
}
