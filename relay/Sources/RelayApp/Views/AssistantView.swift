import RelayCore
import SwiftUI

struct AssistantView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.interactions.isEmpty { SuggestionCards() }
                        ForEach(model.interactions) { interaction in
                            ConversationTurn(interaction: interaction).id(interaction.id)
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .padding(20)
                    .animation(DS.motion(reduceMotion, .easeOut(duration: 0.2)), value: model.interactions.count)
                }
                .onChange(of: model.interactions.count) { _, _ in
                    if let last = model.interactions.last?.id {
                        withAnimation(DS.motion(reduceMotion, .easeOut(duration: 0.25))) { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            // Composer and voice bars stay anchored at the bottom.
            VStack(spacing: 0) {
                if case .reviewing = model.voice.state { TranscriptReviewBar() }
                if case let .failed(reason) = model.voice.state { voiceErrorBar(reason) }
                InputBar(draft: $draft)
            }
        }
    }

    private var speechConfigured: Bool {
        if case .unconfigured = model.voice.transcriberStatus { return false }
        return true
    }

    private var header: some View {
        DSPageHeader(title: "Assistant", subtitle: "What Relay heard, understood, planned, attempted — and what happened.",
                     eyebrow: "RELAY  /  ASSISTANT") {
            VStack(alignment: .trailing, spacing: 6) {
                if speechConfigured {
                    HStack(spacing: 6) {
                        StatusPill(text: "Speech in: \(model.voice.transcriberStatus.label)", color: Theme.color(model.voice.transcriberStatus))
                        StatusPill(text: "Speech out: \(model.speechOutputLabel)", color: Theme.color(model.voice.synthesizerStatus))
                    }
                } else {
                    DSBadge(text: "Speech not configured — text only", systemImage: "keyboard", tone: .neutral)
                }
                StatusPill(text: "Reasoning: \(model.reasonerName)", color: Theme.accent, systemImage: "list.bullet.indent")
            }
        }
    }

    private func voiceErrorBar(_ reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
            Text("Voice input failed:").font(.callout.weight(.semibold)).foregroundStyle(Theme.danger)
            Text(reason).font(.callout).foregroundStyle(Theme.textPrimary).lineLimit(2)
            Spacer()
            Button("Dismiss") { model.dismissVoiceError() }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Theme.danger.opacity(0.10))
        .overlay(alignment: .top) { Rectangle().fill(Theme.danger.opacity(0.35)).frame(height: 1) }
    }
}

// MARK: - Suggested requests

/// Example requests as compact action cards. Clicking one sends it exactly as if typed.
struct SuggestionCards: View {
    @EnvironmentObject private var model: AppModel

    private struct Suggestion: Identifiable {
        let text: String
        let title: String
        let detail: String
        let symbol: String
        var id: String { text }
    }

    private let suggestions = [
        Suggestion(text: "start", title: "Start training", detail: "Begin the warehouse procedure, one step at a time.", symbol: "shippingbox"),
        Suggestion(text: "Which gloves do I need?", title: "Ask about the procedure", detail: "Answers quote the step they come from.", symbol: "questionmark.bubble"),
        Suggestion(text: "add task Check dock B lights", title: "Add a task", detail: "Creates a task in the queue.", symbol: "plus.square"),
        Suggestion(text: "run the simulation", title: "Run the Wybe simulation", detail: "Simulated shift only; nothing live is contacted.", symbol: "testtube.2"),
        Suggestion(text: "help", title: "What can Relay do?", detail: "Lists the supported requests.", symbol: "list.bullet")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggested requests").dsColumnHeader()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(suggestions) { suggestion in
                    SuggestionCard(title: suggestion.title, detail: suggestion.detail, command: suggestion.text, symbol: suggestion.symbol) {
                        model.send(suggestion.text, source: .typed)
                    }
                }
            }
            Label("Speech is optional. Everything works by typing.", systemImage: "keyboard")
                .font(.callout).foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct SuggestionCard: View {
    let title: String
    let detail: String
    let command: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                DSIconTile(systemImage: symbol)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    Text(detail).font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Text("“\(command)”").font(DS.Typeface.monoSmall).foregroundStyle(DS.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsPanel(padding: 12, raised: hovering, highlighted: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Sends “\(command)”")
        .accessibilityLabel("\(title). Sends \(command).")
    }
}

// MARK: - Conversation

/// One exchange: the user's request, then Relay's response with proposed actions and execution results.
struct ConversationTurn: View {
    let interaction: Interaction

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            UserRequestBubble(interaction: interaction)
            InteractionCard(interaction: interaction)
        }
    }
}

struct UserRequestBubble: View {
    let interaction: Interaction

    var body: some View {
        HStack {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 4) {
                Label("You · \(interaction.heard.source.label)", systemImage: "person.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                Text(interaction.heard.text)
                    .foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).strokeBorder(Theme.accent.opacity(0.35)))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You said: \(interaction.heard.text)")
    }
}

extension InteractionStatus {
    var displayLabel: String {
        switch self {
        case .completed: return "Completed"
        case .awaitingApproval: return "Awaiting approval"
        case .needsAttention: return "Needs attention"
        case .failed: return "Failed"
        case .declined: return "Declined"
        case .notUnderstood: return "Not understood"
        }
    }
    var symbol: String {
        switch self {
        case .completed: return "checkmark.circle"
        case .awaitingApproval: return "hand.raised"
        case .needsAttention: return "exclamationmark.triangle"
        case .failed: return "xmark.octagon"
        case .declined: return "minus.circle"
        case .notUnderstood: return "questionmark.circle"
        }
    }
}

extension ToolAttemptStatus {
    var displayLabel: String {
        switch self {
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .needsAttention: return "Needs attention"
        case .awaitingApproval: return "Awaiting approval — not run"
        case .declined: return "Declined — not run"
        case .unknownTool: return "Unknown tool — not run"
        }
    }
    var symbol: String {
        switch self {
        case .succeeded: return "checkmark.circle"
        case .failed: return "xmark.octagon"
        case .needsAttention: return "exclamationmark.triangle"
        case .awaitingApproval: return "hand.raised"
        case .declined: return "minus.circle"
        case .unknownTool: return "questionmark.diamond"
        }
    }
}

/// Relay's response. Proposed actions and execution results are shown separately, and an action is
/// only shown as succeeded when its attempt reported success.
struct InteractionCard: View {
    @EnvironmentObject private var model: AppModel
    let interaction: Interaction

    var body: some View {
        Panel(highlighted: interaction.status == .awaitingApproval) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Label("Relay", systemImage: "waveform").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                    Spacer()
                    StatusPill(text: interaction.status.displayLabel, color: Theme.color(interaction.status), systemImage: interaction.status.symbol)
                }
                LabeledRow(label: "Understood") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(interaction.understanding.intent.label).foregroundStyle(Theme.textPrimary)
                        Text("\(interaction.understanding.explanation) · confidence \(Int(interaction.understanding.confidence * 100))%")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                if !interaction.reply.isEmpty {
                    Text(interaction.reply).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledRow(label: "Proposed") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(interaction.plan.summary).font(.callout).foregroundStyle(Theme.textSecondary)
                        if !interaction.plan.steps.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(Array(interaction.plan.steps.enumerated()), id: \.offset) { index, step in
                                    ProposedActionChip(index: index + 1, toolName: step.toolName)
                                }
                            }
                        }
                    }
                }
                LabeledRow(label: "Attempted") {
                    if interaction.attempts.isEmpty {
                        DSBadge(text: interaction.plan.steps.isEmpty ? "Nothing to run" : "Not attempted", systemImage: "circle.dashed", tone: .neutral)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(interaction.attempts.enumerated()), id: \.offset) { _, attempt in
                                HStack(spacing: 6) {
                                    Text(attempt.step.toolName).font(DS.Typeface.monoSmall).foregroundStyle(Theme.textPrimary)
                                    StatusPill(text: attempt.status.displayLabel, color: Theme.color(attempt.status), systemImage: attempt.status.symbol)
                                }
                            }
                        }
                    }
                }
                HStack(spacing: 8) {
                    if interaction.status == .awaitingApproval {
                        Button("Approve") { model.approve(interaction) }.buttonStyle(.dsPrimary)
                        Button("Decline", role: .cancel) { model.decline(interaction) }
                    }
                    Spacer(minLength: 0)
                    if model.voice.canSpeak && !interaction.reply.isEmpty {
                        Button { model.speak(interaction.reply) } label: { Label("Speak", systemImage: "speaker.wave.2") }
                            .buttonStyle(.borderless)
                            .disabled(model.isSpeaking || model.isRecording)
                    }
                }
            }
        }
        .padding(.trailing, 60)
    }
}

/// A planned step that has not necessarily run. Dashed outline, never a success colour.
private struct ProposedActionChip: View {
    let index: Int
    let toolName: String

    var body: some View {
        HStack(spacing: 4) {
            Text("\(index)").font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(DS.textTertiary)
            Text(toolName).font(DS.Typeface.monoSmall).foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .accessibilityLabel("Proposed step \(index): \(toolName)")
    }
}

// MARK: - Composer

struct InputBar: View {
    @EnvironmentObject private var model: AppModel
    @Binding var draft: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                PushToTalkButton()
                Group {
                    if model.isRecording, let start = model.recordingStartedAt {
                        TimelineView(.periodic(from: start, by: 0.5)) { context in
                            let seconds = Int(context.date.timeIntervalSince(start))
                            Label("Recording \(seconds / 60):\(String(format: "%02d", seconds % 60)) — release to stop", systemImage: "record.circle")
                                .font(.callout.weight(.semibold)).foregroundStyle(Theme.danger)
                        }
                    } else if model.voice.state == .transcribing {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Transcribing…").font(.callout).foregroundStyle(Theme.textPrimary) }
                    } else {
                        TextField("Type a request or a question about the procedure", text: $draft)
                            .textFieldStyle(.plain)
                            .font(.body)
                            .focused($focused)
                            .onSubmit(send)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsFieldChrome(focused: focused)
                if model.isSpeaking {
                    Button { model.stopSpeaking() } label: { Label("Stop playback", systemImage: "stop.fill") }
                        .buttonStyle(.dsSecondary)
                        .keyboardShortcut(".", modifiers: .command)
                }
                Button(action: send) { Label("Send", systemImage: "arrow.up.circle.fill") }
                    .buttonStyle(.dsPrimary)
                    .controlSize(.large)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !model.voice.canRecord && !model.isRecording && model.voice.state == .idle {
                Text(model.microphoneDenied ? "Microphone access denied — text input still works."
                                            : "Speech not configured — text only. Set up ElevenLabs in Settings to talk to Relay.")
                    .font(.caption).foregroundStyle(DS.textTertiary)
                    .padding(.leading, 68)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.panel.opacity(0.92))
        .overlay(alignment: .top) { Rectangle().fill(Theme.accent.opacity(0.30)).frame(height: 1) }
        .onAppear { focused = true }
    }

    private func send() {
        let text = draft
        draft = ""
        model.send(text, source: .typed)
    }
}

struct PushToTalkButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var pressing = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let recording = model.isRecording
        let enabled = model.voice.canRecord || recording
        ZStack {
            // The pulse is shown only while actually recording, and not at all with Reduce Motion.
            if recording && !reduceMotion {
                Circle()
                    .stroke(Theme.danger.opacity(0.6), lineWidth: 2)
                    .frame(width: 54, height: 54)
                    .scaleEffect(pulse ? 1.2 : 0.9)
                    .opacity(pulse ? 0 : 1)
                    .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: pulse)
            }
            Circle()
                .fill(recording ? Theme.danger : Theme.panelRaised)
                .frame(width: 42, height: 42)
                .overlay(Circle().strokeBorder(recording ? Theme.danger : Theme.stroke, lineWidth: recording ? 2 : 1))
            Image(systemName: recording ? "waveform" : (enabled ? "mic.fill" : "mic.slash"))
                .foregroundStyle(recording ? Color.white : (enabled ? Theme.textPrimary : Theme.textSecondary))
        }
        .frame(width: 56, height: 56)
        .contentShape(Circle())
        .opacity(enabled ? 1 : 0.5)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard enabled, !pressing else { return }
                    pressing = true
                    model.pressTalk()
                }
                .onEnded { _ in
                    guard pressing else { return }
                    pressing = false
                    model.releaseTalk()
                }
        )
        .onChange(of: recording) { _, isRecording in pulse = isRecording }
        .help(enabled ? "Hold to talk (push-to-talk)" : "Configure ElevenLabs in Settings to enable voice")
        .accessibilityLabel(recording ? "Recording. Release to stop." : (enabled ? "Push to talk" : "Push to talk unavailable: speech not configured"))
        .accessibilityAddTraits(.isButton)
    }
}

struct TranscriptReviewBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case let .reviewing(original, provider) = model.voice.state {
                HStack {
                    Label("Review transcript", systemImage: "text.quote").font(.headline).foregroundStyle(Theme.textPrimary)
                    Text("from \(provider)\(model.transcriptDraft != original ? " · edited" : "")")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                TextEditor(text: $model.transcriptDraft)
                    .font(.body)
                    .padding(6)
                    .frame(height: 64)
                    .dsFieldChrome()
                HStack {
                    Text("Nothing is done until you send it.").font(.caption).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Discard", role: .cancel) { model.discardTranscript() }
                    Button("Send transcript") { model.submitTranscript() }
                        .buttonStyle(.dsPrimary)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.transcriptDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(14)
        .background(Theme.panelRaised.opacity(0.85))
        .overlay(alignment: .top) { Rectangle().fill(Theme.accent.opacity(0.30)).frame(height: 1) }
    }
}
