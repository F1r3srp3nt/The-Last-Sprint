import SwiftUI
import TokenLabCore

/// Metric summary tile (design-system measurement panel).
struct MetricTile: View {
    let title: String
    let value: String
    var caption: String? = nil
    var systemImage: String? = nil
    var body: some View {
        DSMetric(title: title, value: value, caption: caption, systemImage: systemImage)
    }
}

/// Compact status label. Text always carries the meaning; the colour only reinforces it.
struct Pill: View {
    let text: String
    var color: Color = DS.textSecondary
    var systemImage: String? = nil
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.13), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(contrast == .increased ? 0.85 : 0.32)))
        .accessibilityElement(children: .combine)
    }
}

extension DecisionKind {
    var label: String {
        switch self {
        case .required: return "Required"
        case .retained: return "Kept"
        case .emptySkipped: return "Empty"
        case .duplicateRemoved: return "Duplicate"
        case .excludedByBudget: return "Over budget"
        }
    }
    var symbol: String {
        switch self {
        case .required: return "lock.fill"
        case .retained: return "checkmark.circle.fill"
        case .emptySkipped: return "circle.dashed"
        case .duplicateRemoved: return "doc.on.doc"
        case .excludedByBudget: return "minus.circle"
        }
    }
    /// Retention is a selection outcome, not a quality judgement: kept blocks use the accent,
    /// never the success green that is reserved for evaluated, passing answers.
    var color: Color {
        switch self {
        case .required: return DS.accent
        case .retained: return DS.accent
        case .emptySkipped: return DS.textTertiary
        case .duplicateRemoved: return DS.simulation
        case .excludedByBudget: return DS.warning
        }
    }
}

extension QualityVerdict {
    /// Not evaluated is always neutral: an unevaluated result is never styled as a success.
    var tone: DSTone {
        switch self {
        case .notEvaluated: return .neutral
        case .equivalent: return .success
        case .acceptableWithLosses, .degraded: return .warning
        case .unusable: return .danger
        }
    }
    var symbol: String {
        switch self {
        case .notEvaluated: return "questionmark.circle"
        case .equivalent: return "checkmark.seal"
        case .acceptableWithLosses: return "exclamationmark.circle"
        case .degraded: return "arrow.down.circle"
        case .unusable: return "xmark.octagon"
        }
    }
}

/// Answer-quality status. Visually distinct from token measurements.
struct VerdictBadge: View {
    let evaluation: Evaluation
    var body: some View {
        DSBadge(text: evaluation.isEvaluated ? evaluation.verdict.label : "Quality not evaluated",
                systemImage: evaluation.verdict.symbol, tone: evaluation.verdict.tone)
            .help(evaluation.statusLabel)
    }
}

extension ContextCategory {
    var symbol: String {
        switch self {
        case .reference: return "book"
        case .conversation: return "bubble.left.and.bubble.right"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .toolOutput: return "terminal"
        }
    }
}

struct DecisionRow: View {
    let decision: BlockDecision
    let tokenUnit: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: decision.kind.symbol).foregroundStyle(decision.kind.color).frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(decision.title).fontWeight(.medium).lineLimit(1)
                    Pill(text: decision.kind.label, color: decision.kind.color, systemImage: decision.kind.symbol)
                    Spacer(minLength: 4)
                    Text("\(decision.standaloneTokens) \(tokenUnit)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let relevance = decision.relevance {
                    RelevanceTermsView(relevance: relevance)
                }
                Text(decision.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// Shows a keyword score and exactly which task terms produced it.
struct RelevanceTermsView: View {
    let relevance: RelevanceScore
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Keyword score \(String(format: "%.2f", relevance.score))")
                .font(.caption.monospacedDigit().weight(.medium))
            if relevance.matchedTerms.isEmpty {
                Text("· no task terms found").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("·").font(.caption).foregroundStyle(DS.textTertiary)
                Text(Self.termsText(relevance.matchedTerms))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityLabel(relevance.matchedTerms.isEmpty
                            ? "Keyword score 0, no task terms found"
                            : "Keyword score \(String(format: "%.2f", relevance.score)) from \(relevance.matchedTerms.map(\.term).joined(separator: ", "))")
    }
}

extension RelevanceTermsView {
    static func termsText(_ terms: [TermContribution]) -> String {
        var parts: [String] = []
        for term in terms {
            var part = term.term + " +" + String(format: "%.2f", term.weight)
            if term.occurrences > 1 { part += " (×\(term.occurrences))" }
            parts.append(part)
        }
        return parts.joined(separator: ", ")
    }
}

/// Plain-language description of the ranking method and its limits.
struct RankingMethodView: View {
    var descriptor: RankerDescriptor = KeywordOverlapRanker().descriptor
    var taskTerms: [String]? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(descriptor.displayName) · \(descriptor.version)").font(.caption.weight(.semibold))
            if let taskTerms {
                Text(taskTerms.isEmpty ? "Task terms: none usable" : "Task terms: \(taskTerms.joined(separator: ", "))")
                    .font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(descriptor.method).font(.caption).fixedSize(horizontal: false, vertical: true)
            Text("How it combines with other settings: required blocks are always kept, whatever their score. Optional blocks are considered by keyword score, then manual priority, then prompt order, and added while the whole assembled prompt fits the budget. Retained blocks keep their original order.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            ForEach(descriptor.limitations, id: \.self) { limitation in
                Label(limitation, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("A keyword match is not evidence that a block is useful or that an answer will be correct.")
                .font(.caption.weight(.medium)).foregroundStyle(DS.warning)
        }
    }
}

/// Monospaced, selectable prompt text. Very long text is shown in part, with an explicit note;
/// the copy button always copies the complete text.
struct PromptTextView: View {
    let title: String
    let text: String
    var minHeight: CGFloat = 80
    var maxHeight: CGFloat = 320
    var onCopy: (() -> Void)? = nil
    static let displayLimit = 30_000

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).dsColumnHeader()
                Spacer()
                if let onCopy {
                    Button(action: onCopy) { Label("Copy", systemImage: "doc.on.doc") }
                        .buttonStyle(.borderless).controlSize(.small)
                        .help("Copy the complete text")
                }
            }
            ScrollView {
                Text(text.isEmpty ? "(empty)" : displayed)
                    .font(DS.Typeface.editor)
                    .lineSpacing(2)
                    .foregroundStyle(text.isEmpty ? DS.textTertiary : DS.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .dsFieldChrome()
            if text.count > Self.displayLimit {
                Text("Showing the first \(Self.displayLimit.formatted()) of \(text.count.formatted()) characters. Copy gets the complete text.")
                    .font(.caption).foregroundStyle(DS.warning)
            }
        }
    }

    private var displayed: String {
        text.count > Self.displayLimit ? String(text.prefix(Self.displayLimit)) : text
    }
}

/// Bordered multi-line editor for long text and code: monospaced, comfortable line spacing,
/// sunken background, cyan border while focused.
struct CodeEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 90
    var maxHeight: CGFloat = 320
    var accessibilityLabel: String
    @FocusState private var focused: Bool
    var body: some View {
        TextEditor(text: $text)
            .font(DS.Typeface.editor)
            .lineSpacing(2)
            .foregroundStyle(DS.textPrimary)
            .focused($focused)
            .padding(8)
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .dsFieldChrome(focused: focused)
            .accessibilityLabel(accessibilityLabel)
    }
}

func percentString(_ value: Double?) -> String {
    guard let value else { return "—" }
    return String(format: "%.1f%%", value)
}

/// Text-field binding for optional whole numbers (empty means "not recorded").
func optionalIntText(_ binding: Binding<Int?>) -> Binding<String> {
    Binding(
        get: { binding.wrappedValue.map(String.init) ?? "" },
        set: { newValue in
            let digits = newValue.filter { $0.isASCII && $0.isNumber }
            binding.wrappedValue = digits.isEmpty ? nil : Int(digits.prefix(12))
        })
}
