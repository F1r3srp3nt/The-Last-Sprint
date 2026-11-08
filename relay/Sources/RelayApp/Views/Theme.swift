import RelayAdapters
import RelayCore
import SwiftUI

/// Relay's palette, defined by the shared design tokens in `DesignSystem.swift`.
/// Colour always comes with a text label, never alone.
enum Theme {
    static let background = DS.canvas
    static let panel = DS.surface
    static let panelRaised = DS.surfaceRaised
    static let stroke = DS.accent.opacity(0.16)
    static let textPrimary = DS.textPrimary
    static let textSecondary = DS.textSecondary
    static let accent = DS.accent
    static let success = DS.success
    static let warning = DS.warning
    static let danger = DS.danger
    static let simulation = DS.simulation

    static func color(_ kind: LogKind) -> Color {
        switch kind {
        case .succeeded: return success
        case .failed, .rejected: return danger
        case .needsAttention: return warning
        case .heard, .understood, .planned, .attempted: return accent
        case .info: return textSecondary
        }
    }

    static func color(_ state: TaskState) -> Color {
        switch state {
        case .succeeded: return success
        case .failed: return danger
        case .needsAttention, .awaitingApproval: return warning
        case .inProgress: return accent
        case .queued, .cancelled: return textSecondary
        }
    }

    static func color(_ status: ActionResultStatus) -> Color {
        switch status {
        case .succeeded, .ambiguousConfirmedApplied: return success
        case .failed, .rejectedByEnvironment: return danger
        case .ambiguousUnresolved, .blockedPrecondition, .blockedNotAllowed, .blockedUnknownCommand: return warning
        case .stopped: return textSecondary
        }
    }

    static func color(_ status: InteractionStatus) -> Color {
        switch status {
        case .completed: return success
        case .awaitingApproval, .needsAttention: return warning
        case .failed: return danger
        case .declined, .notUnderstood: return textSecondary
        }
    }

    static func color(_ status: ToolAttemptStatus) -> Color {
        switch status {
        case .succeeded: return success
        case .failed, .unknownTool: return danger
        case .needsAttention, .awaitingApproval: return warning
        case .declined: return textSecondary
        }
    }

    static func color(_ state: CheckState) -> Color {
        switch state {
        case .passed: return success
        case .failed: return danger
        case .attention: return warning
        case .checking: return accent
        case .notChecked: return textSecondary
        }
    }

    static func label(_ state: CheckState) -> String {
        switch state {
        case let .passed(at, _): return "Passed \(at.formatted(date: .omitted, time: .shortened))"
        case .failed: return "Failed"
        case .attention: return "Needs attention"
        case .checking: return "Checking…"
        case .notChecked: return "Not tested"
        }
    }

    static func color(_ permission: MicrophonePermission) -> Color {
        switch permission {
        case .granted: return success
        case .denied, .restricted: return danger
        case .notDetermined, .unknown: return textSecondary
        }
    }

    static func color(_ readiness: ElevenLabsReadiness) -> Color {
        if !readiness.keySaved { return textSecondary }
        if readiness.speechInput.problem != nil || readiness.speechOutput.problem != nil { return warning }
        if readiness.speechInput.isPassed && (readiness.speechOutput.isPassed || !readiness.voiceIDSet) { return success }
        return warning
    }

    static func color(_ status: SpeechServiceStatus) -> Color {
        switch status {
        case .connected: return success
        case .failed: return danger
        case .checking, .configuredUnverified: return warning
        case .unconfigured: return textSecondary
        }
    }
}

struct Panel<Content: View>: View {
    var padding: CGFloat = 14
    var highlighted = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsPanel(padding: padding, highlighted: highlighted)
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var filled = false
    var systemImage: String? = nil
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small).foregroundStyle(filled ? Theme.background : color)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(text).font(.caption.weight(.medium)).foregroundStyle(filled ? Theme.background : Theme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(filled ? color : color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(contrast == .increased ? 0.85 : 0.35)))
        .accessibilityElement(children: .combine)
    }
}

/// Always-visible mode marker. Simulation uses a dashed violet frame and a test-tube symbol; live
/// uses a solid amber frame and an antenna symbol, so the two never look alike.
struct ModeBanner: View {
    let mode: ExecutionMode
    let detail: String

    var body: some View {
        let simulated = mode == .simulation
        let tint = simulated ? Theme.simulation : Theme.warning
        HStack(spacing: 10) {
            Image(systemName: simulated ? "testtube.2" : "antenna.radiowaves.left.and.right")
            Text(mode.label).font(.caption.weight(.bold)).tracking(1.2)
            Text(detail).font(.caption).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.Radius.control + 2))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control + 2)
            .strokeBorder(tint.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: simulated ? [4, 3] : [])))
        .accessibilityElement(children: .combine)
    }
}

/// Page title and description, using the shared page-header typography.
struct SectionHeader: View {
    let title: String
    let subtitle: String
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("RELAY  /  \(title.uppercased())").font(DS.Typeface.eyebrow).tracking(1.4).foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(title).font(DS.Typeface.pageTitle).foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.callout).foregroundStyle(DS.secondaryText(contrast))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).dsColumnHeader()
                .frame(width: 92, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct WarningBox: View {
    let warning: RenderedWarning

    var body: some View {
        let critical = warning.severity == .critical
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle")
                .foregroundStyle(critical ? Theme.danger : Theme.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text(critical ? "SAFETY" : "NOTE").font(.caption2.weight(.bold)).tracking(1)
                    .foregroundStyle(critical ? Theme.danger : Theme.warning)
                Text(warning.text).font(.body.weight(critical ? .semibold : .regular)).foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                if warning.isFallback {
                    Text("Shown in the original language: no translation was supplied.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background((critical ? Theme.danger : Theme.warning).opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke((critical ? Theme.danger : Theme.warning).opacity(0.45)))
    }
}
