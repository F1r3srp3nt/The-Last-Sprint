import RelayCore
import SwiftUI
import UniformTypeIdentifiers

struct TrainingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var question = ""
    @State private var importing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let snapshot = model.training {
                    disclaimer(snapshot)
                    languagePicker(snapshot)
                    stepCard(snapshot)
                    controls(snapshot)
                    questionBox
                    if let answer = snapshot.lastAnswer { AnswerCard(answer: answer) }
                } else {
                    ProgressView()
                }
            }
            .padding(18)
            .animation(.easeOut(duration: 0.2), value: model.training?.current?.stepID)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case let .success(url) = result { model.loadProcedure(from: url) }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            SectionHeader(title: "Warehouse Training",
                          subtitle: "One step at a time, in the worker's language. Answers come only from the procedure.")
            Menu("Procedure") {
                Button("Load procedure JSON…") { importing = true }
                Button("Use built-in demo procedure") { model.restoreDemoProcedure() }
            }
            .fixedSize()
        }
    }

    private func disclaimer(_ snapshot: TrainingSnapshot) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("DEMONSTRATION MATERIAL").font(.caption2.weight(.bold)).tracking(1)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Theme.simulation.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(Theme.simulation)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.procedureTitle).font(.headline)
                Text(snapshot.disclaimer).font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func languagePicker(_ snapshot: TrainingSnapshot) -> some View {
        Picker("Language", selection: Binding(
            get: { snapshot.language },
            set: { code in model.send("language \(SupportedLanguage.name(code).lowercased())", source: .control) })) {
            ForEach(snapshot.languages, id: \.self) { code in Text(SupportedLanguage.name(code)).tag(code) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 420)
    }

    @ViewBuilder
    private func stepCard(_ snapshot: TrainingSnapshot) -> some View {
        Panel(padding: 18) {
            if let step = snapshot.current {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Step \(step.position) of \(step.total)").font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                        Text(step.stepID).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        ProgressView(value: Double(step.position), total: Double(step.total)).frame(width: 140)
                    }
                    ForEach(step.warnings.filter { $0.severity == .critical }) { WarningBox(warning: $0) }
                    Text(step.title).font(.title3.weight(.semibold))
                    Text(step.instruction).font(.title3).foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    ForEach(step.warnings.filter { $0.severity == .caution }) { WarningBox(warning: $0) }
                    if step.usedFallback {
                        Text("Some text is shown in the original language because the procedure has no translation for it.")
                            .font(.caption).foregroundStyle(Theme.warning)
                    }
                }
            } else if snapshot.isFinished {
                Text("Training complete.").font(.title3)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ready to start.").font(.title3)
                    Text("Relay will show one step at a time. Safety warnings must be confirmed before moving on.")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func controls(_ snapshot: TrainingSnapshot) -> some View {
        HStack(spacing: 10) {
            if snapshot.current == nil {
                Button("Start training") { model.send("start", source: .control) }.buttonStyle(.dsPrimary)
            } else {
                Button { model.send("back", source: .control) } label: { Label("Back", systemImage: "chevron.left") }
                Button { model.send("repeat", source: .control) } label: { Label("Repeat", systemImage: "arrow.counterclockwise") }
                if snapshot.pendingAcknowledgement {
                    Button { model.send("understood", source: .control) } label: {
                        Label("I understand the safety warning", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(DSPrimaryButtonStyle(tone: .warning))
                }
                Button { model.send("next", source: .control) } label: { Label("Next", systemImage: "chevron.right") }
                    .buttonStyle(.dsPrimary)
                    .disabled(snapshot.pendingAcknowledgement)
                if model.voice.canSpeak, let step = snapshot.current {
                    Button { model.speak(ProcedureRenderer.plainText(step)) } label: { Label("Read aloud", systemImage: "speaker.wave.2") }
                        .disabled(model.isSpeaking || model.isRecording)
                }
                if model.isSpeaking {
                    Button { model.stopSpeaking() } label: { Label("Stop", systemImage: "stop.fill") }
                }
            }
        }
    }

    private var questionBox: some View {
        HStack {
            TextField("Ask about this procedure (e.g. \u{201C}What if a label is unreadable?\u{201D})", text: $question)
                .textFieldStyle(.ds)
                .onSubmit(ask)
            Button("Ask", action: ask).disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        // Explicit "?" so the reasoner always routes this to the procedure answerer.
        model.send(text.hasSuffix("?") ? text : text + "?", source: .typed)
        question = ""
    }
}

struct AnswerCard: View {
    let answer: TrainingAnswer

    var body: some View {
        Panel {
            switch answer {
            case let .answer(text, citation, warnings):
                VStack(alignment: .leading, spacing: 10) {
                    StatusPill(text: "Answered from the procedure", color: Theme.success)
                    Text(text).font(.body.weight(.medium)).textSelection(.enabled)
                    ForEach(warnings.filter { $0.severity == .critical }) { WarningBox(warning: $0) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SUPPORTING INSTRUCTION · \(citation.stepID) — \(citation.stepTitle)")
                            .font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(Theme.textSecondary)
                        Text("\u{201C}\(citation.quote)\u{201D}").font(.callout).foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 2) }
                }
            case let .clarification(prompt, options):
                VStack(alignment: .leading, spacing: 8) {
                    StatusPill(text: "Needs clarification", color: Theme.warning)
                    Text(prompt).font(.body.weight(.medium))
                    ForEach(options, id: \.stepID) { option in
                        Text("• \(option.stepID): \(option.stepTitle)").foregroundStyle(Theme.textSecondary)
                    }
                }
            case let .escalation(message, topic):
                VStack(alignment: .leading, spacing: 8) {
                    StatusPill(text: "Escalated — not in the procedure", color: Theme.warning)
                    Text(message).font(.body.weight(.medium))
                    Text("Added to Tasks for a person to answer: \u{201C}\(topic)\u{201D}")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}
