import RelayAdapters
import RelayCore
import SwiftUI

/// Guided setup. For each item it shows: what is missing, what it enables, where to get it,
/// where to paste it, how to test it, and what still works without it.
///
/// Network tests run only from explicit buttons. Instructions and links were checked against
/// elevenlabs.io and the Wybe registration page on 2026-11-07 (see ProviderLinks).
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: "Settings",
                              subtitle: "Set up speech step by step. Everything except voice works without any setup.")
                AppearancePanel()
                ReadinessPanel()
                SetupGroupHeader(title: "ElevenLabs speech", detail: "Speech to text for push-to-talk, text to speech for spoken replies.")
                APIKeyStep()
                VoiceStep()
                SpeechInputStep()
                ModelsStep()
                ReasoningPanel()
                WybePanel()
                AboutBuildPanel()
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.refreshMicrophone() }
    }
}

// MARK: - Appearance and build

private struct AppearancePanel: View {
    @AppStorage(DSAppearance.storageKey) private var appearance = DSAppearance.futuristic.rawValue

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance").font(.headline)
                Picker("Appearance", selection: $appearance) {
                    ForEach(DSAppearance.allCases) { option in Text(option.title).tag(option.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 460)
                Text(DSAppearance.resolve(appearance).detail)
                    .font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct AboutBuildPanel: View {
    var body: some View {
        let build = BuildInfo.current
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                Text("About this build").font(.headline)
                LabeledRow(label: "Version") { Text("\(build.version) (build \(build.build)) · \(build.configuration)") }
                LabeledRow(label: "Commit") { Text(build.commit ?? "Not recorded (built without scripts/build-app.sh)") }
                LabeledRow(label: "Built") {
                    Text(build.builtAt ?? build.executableModified.map { "Executable modified \($0.formatted(date: .abbreviated, time: .standard))" } ?? "Unknown")
                }
                LabeledRow(label: "Running from") {
                    Text(build.launchMode).font(.caption.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
        }
    }
}

// MARK: - Readiness

private struct ReadinessPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("Readiness").font(.headline)
                Text("Each line is checked separately. A saved key is not a verified connection, and a passed account check does not prove that speech works.")
                    .font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                ReadinessRow(title: "Key saved",
                             value: model.keySaved ? "Yes — in the Keychain (\(model.apiKeyDisplay)), not verified by saving" : "No",
                             color: model.keySaved ? Theme.success : Theme.textSecondary)
                ReadinessRow(title: "Account / credential check", value: Theme.label(model.readiness.account),
                             color: Theme.color(model.readiness.account))
                ReadinessRow(title: "Speech input tested", value: Theme.label(model.readiness.speechInput),
                             color: Theme.color(model.readiness.speechInput))
                ReadinessRow(title: "Speech output tested",
                             value: model.readiness.voiceIDSet ? Theme.label(model.readiness.speechOutput) : "No voice ID set",
                             color: model.readiness.voiceIDSet ? Theme.color(model.readiness.speechOutput) : Theme.textSecondary)
                ReadinessRow(title: "Microphone permission", value: model.readiness.microphone.label,
                             color: Theme.color(model.readiness.microphone))
                Divider()
                Text("Works without any setup").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                ForEach(ReasoningCapability.worksWithoutSetup, id: \.self) { item in
                    Label(item, systemImage: "checkmark").font(.caption).foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }
}

private struct ReadinessRow: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).frame(width: 210, alignment: .leading)
                Text(value).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) { Circle().fill(color).frame(width: 8, height: 8); Text(title) }
                Text(value).foregroundStyle(Theme.textSecondary).padding(.leading, 16)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared building blocks

private struct SetupGroupHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(Theme.accent)
            Text(detail).font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 6)
    }
}

/// A numbered setup step with its status and an always-visible explanation of what it enables.
private struct SetupStep<Content: View>: View {
    let number: Int
    let title: String
    let enables: String
    let status: String
    let statusColor: Color
    @ViewBuilder var content: Content

    var body: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        badge
                        Text(title).font(.headline)
                        Spacer(minLength: 8)
                        StatusPill(text: status, color: statusColor)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) { badge; Text(title).font(.headline) }
                        StatusPill(text: status, color: statusColor)
                    }
                }
                Text(enables).font(.callout).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                content
            }
        }
    }

    private var badge: some View {
        Text("\(number)")
            .font(.caption.weight(.bold).monospacedDigit())
            .frame(width: 22, height: 22)
            .background(Theme.accent.opacity(0.18), in: Circle())
            .overlay(Circle().stroke(Theme.accent.opacity(0.6)))
            .foregroundStyle(Theme.accent)
    }
}

/// Numbered instructions that stay visible.
private struct Instructions: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).").font(.callout.monospacedDigit()).foregroundStyle(Theme.accent)
                    Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Lays buttons out in a row, or stacked when the window is narrow.
private struct AdaptiveRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 8) { content }
        }
    }
}

/// Expandable longer guidance.
private struct HelpDisclosure<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) { content }
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(title, systemImage: symbol).font(.callout.weight(.medium)).foregroundStyle(Theme.textPrimary)
        }
    }
}

private struct LinkButton: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let url: URL

    var body: some View {
        Button { model.open(url) } label: { Label(title, systemImage: "arrow.up.right.square") }
            .help(url.absoluteString)
    }
}

/// Result of a check: passed detail, or the problem with its next step.
private struct CheckResultView: View {
    let state: CheckState

    var body: some View {
        switch state {
        case let .passed(_, detail):
            Label(detail, systemImage: "checkmark.seal").font(.callout).foregroundStyle(Theme.success)
                .fixedSize(horizontal: false, vertical: true)
        case let .attention(problem), let .failed(problem):
            ProblemView(problem: problem, color: Theme.color(state))
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…").font(.callout) }
        case .notChecked:
            EmptyView()
        }
    }
}

private struct ProblemView: View {
    @EnvironmentObject private var model: AppModel
    let problem: SetupProblem
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(problem.title, systemImage: "exclamationmark.triangle.fill").font(.callout.weight(.semibold))
                .foregroundStyle(color)
            Text(problem.nextStep).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let detail = problem.providerDetail {
                Text(detail).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let link = problem.link {
                LinkButton(title: "Open \(link.host ?? "link")\(link.path)", url: link).buttonStyle(.link)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.4)))
    }
}

private struct CreditNote: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "creditcard").font(.caption).foregroundStyle(Theme.warning)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Step 1: API key

private struct APIKeyStep: View {
    @EnvironmentObject private var model: AppModel
    @State private var keyEntry = ""
    @State private var replacing = false
    @State private var keyError: String?
    @State private var confirmRemove = false

    private var status: (String, Color) {
        if !model.keySaved { return ("Missing", Theme.textSecondary) }
        switch model.readiness.account {
        case .passed: return ("Saved · account check passed", Theme.success)
        case .attention: return ("Saved · check needs attention", Theme.warning)
        case .failed: return ("Saved · check failed", Theme.danger)
        default: return ("Saved · not verified", Theme.warning)
        }
    }

    var body: some View {
        SetupStep(number: 1, title: "API key",
                  enables: "Authorises Relay's requests to ElevenLabs speech services. Without it, push-to-talk and spoken replies stay off; typing still works.",
                  status: status.0, statusColor: status.1) {
            Instructions(lines: [
                "Open ElevenLabs › Developers › API Keys and create a key (name it e.g. “Relay”).",
                "New keys are restricted: enable Speech to Text and Text to Speech. Enable User (read) only if you want the account check below.",
                "Copy the key straight away. ElevenLabs shows it in full only when it is created; later you see only its last four characters.",
                "Paste it below and choose Save to Keychain.",
            ])
            AdaptiveRow { LinkButton(title: "Open API Keys", url: ProviderLinks.elevenLabsAPIKeys) }

            PermissionTable()

            keyEntryArea

            if model.keySaved {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    AdaptiveRow {
                        Button("Check account") { model.checkAccount() }
                            .disabled(model.readiness.account == .checking)
                        Text("Free. Calls GET /v1/user to confirm ElevenLabs accepts the key. It does not test speech, and it needs User (read).")
                            .font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    CheckResultView(state: model.readiness.account)
                }
            }

            HelpDisclosure(title: "Where do I find this?", symbol: "questionmark.circle") {
                Text("In the ElevenLabs dashboard, click Developers in the left sidebar, then the API Keys tab. Create a key there.")
                Text("To change an existing key's permissions: open More actions (…) next to the key › Edit.")
                Text("A key can also have a credit limit and an IP allowlist. Both can make requests fail even when the key is correct.")
                Text("Relay stores the key only in your macOS Keychain (this Mac only). It is sent only in the xi-api-key header, never in a URL, and is removed from logs and exports.")
                LinkButton(title: "ElevenLabs authentication docs", url: ProviderLinks.elevenLabsAuthenticationDocs).buttonStyle(.link)
            }
            HelpDisclosure(title: "Troubleshooting", symbol: "wrench.and.screwdriver") {
                Text("“Did not accept this API key” (HTTP 401): the key is wrong, incomplete, deleted, disabled or expired. Create a new key and use Replace.")
                Text("“Reports insufficient permissions” (HTTP 403 with code insufficient_permissions): ElevenLabs says this request isn't allowed for the key. Relay names a permission only if ElevenLabs' message names it. The account check uses User (read); you can enable it or skip the check and use Test voice / Test speech input.")
                Text("“Refused access; the cause is not stated” (HTTP 403 without a specific code): this does not show whether the key is valid or which permission is missing. Possible causes include key permissions, an IP allowlist or workspace access. Relay shows ElevenLabs' message instead of guessing.")
                Text("“Could not reach ElevenLabs”: network problem. Check the connection and try again.")
            }
        }
        .confirmationDialog("Remove the ElevenLabs key from the Keychain?", isPresented: $confirmRemove) {
            Button("Remove key", role: .destructive) { model.removeAPIKey(); replacing = false }
        } message: {
            Text("Voice features turn off until a key is saved again. Typing keeps working.")
        }
    }

    @ViewBuilder private var keyEntryArea: some View {
        if model.keySaved && !replacing {
            AdaptiveRow {
                Label("Stored in Keychain: \(model.apiKeyDisplay)", systemImage: "key.fill").font(.callout.monospaced())
                Button("Replace…") { replacing = true; keyError = nil }
                Button("Remove", role: .destructive) { confirmRemove = true }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                AdaptiveRow {
                    // Native secure field on purpose: secure entry, focus ring and password handling stay
                    // exactly the system's (it follows the dark appearance).
                    SecureField(model.keySaved ? "Paste the new key" : "Paste your ElevenLabs API key", text: $keyEntry)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220, maxWidth: 380)
                        .onSubmit(save)
                    Button("Save to Keychain", action: save)
                        .buttonStyle(.dsPrimary)
                        .disabled(keyEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                    if replacing {
                        Button("Cancel") { replacing = false; keyEntry = ""; keyError = nil }
                    }
                }
                if let keyError {
                    Text(keyError).font(.caption).foregroundStyle(Theme.danger)
                }
                Text("Saving stores the key; it does not check it. Use the tests below to verify.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func save() {
        keyError = model.saveAPIKey(keyEntry)
        if keyError == nil {
            keyEntry = ""
            replacing = false
        }
    }
}

private struct PermissionTable: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Minimum key permissions for Relay").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            ForEach(ElevenLabsPermission.allCases, id: \.rawValue) { permission in
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Image(systemName: permission.required ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(permission.required ? Theme.accent : Theme.textSecondary)
                        Text(permission.label).frame(width: 120, alignment: .leading)
                        Text(permission.rawValue).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                            .frame(width: 120, alignment: .leading)
                        Text(permission.required ? "Required — \(permission.usedFor)" : "Optional — \(permission.usedFor)")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(permission.label) (\(permission.rawValue))")
                        Text(permission.required ? "Required — \(permission.usedFor)" : "Optional — \(permission.usedFor)")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .font(.callout)
            }
        }
        .padding(10)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Step 2: Voice

private struct VoiceStep: View {
    @EnvironmentObject private var model: AppModel
    @State private var voiceDraft = ""
    @State private var voiceError: String?

    private var status: (String, Color) {
        if !model.readiness.voiceIDSet { return ("Missing — replies are text only", Theme.textSecondary) }
        switch model.readiness.speechOutput {
        case .passed: return ("Set · voice tested", Theme.success)
        case .failed, .attention: return ("Set · test failed", Theme.danger)
        case .checking: return ("Testing…", Theme.accent)
        case .notChecked: return ("Set · not tested", Theme.warning)
        }
    }

    var body: some View {
        SetupStep(number: 2, title: "Voice",
                  enables: "Chooses the voice that speaks Relay's replies. A voice ID only selects a voice; it is not a key or password. Without one, replies stay as text.",
                  status: status.0, statusColor: status.1) {
            Instructions(lines: [
                "Open My Voices in ElevenLabs. To find new voices, browse the Voice Library.",
                "Next to the voice you want, open More actions (three dots) › Copy voice ID.",
                "Paste it below and choose Save voice ID, then run Test voice.",
            ])
            AdaptiveRow {
                LinkButton(title: "Open My Voices", url: ProviderLinks.elevenLabsMyVoices)
                LinkButton(title: "Open Voice Library", url: ProviderLinks.elevenLabsVoiceLibrary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(model.elevenLabs.voiceID.isEmpty ? "Current voice ID: none" : "Current voice ID: \(model.elevenLabs.voiceID)")
                    .font(.callout.monospaced()).textSelection(.enabled)
                AdaptiveRow {
                    TextField("Paste a voice ID", text: $voiceDraft)
                        .textFieldStyle(.ds)
                        .frame(minWidth: 220, maxWidth: 320)
                        .onSubmit(save)
                    Button("Save voice ID", action: save)
                        .disabled(voiceDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !model.elevenLabs.voiceID.isEmpty {
                        Button("Clear") { model.saveVoiceID(""); voiceError = nil }
                    }
                }
                if let voiceError { Text(voiceError).font(.caption).foregroundStyle(Theme.danger) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Button("Use example voice") { model.useExampleVoice(); voiceError = nil }
                Text("Fills in \(ElevenLabsConfiguration.documentationExampleVoiceID), the voice ElevenLabs uses in its own API examples. Your account may not have access to it (for example, ElevenLabs' Default voices are only available to accounts created before March 2026), so run Test voice.")
                    .font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                AdaptiveRow {
                    Button { model.testVoice() } label: { Label("Test voice", systemImage: "speaker.wave.2") }
                        .disabled(!model.keySaved || !model.readiness.voiceIDSet || !model.canStartSpeechTest
                                  || model.readiness.speechOutput == .checking)
                    if model.isSpeaking {
                        Button { model.stopSpeaking() } label: { Label("Stop playback", systemImage: "stop.fill") }
                    }
                }
                CreditNote(text: "Uses ElevenLabs credits: one short sentence (\u{201C}\(AppModel.voiceTestSample)\u{201D}).")
                if !model.keySaved { Text("Save an API key first (step 1).").font(.caption).foregroundStyle(Theme.textSecondary) }
                CheckResultView(state: model.readiness.speechOutput)
            }
            HelpDisclosure(title: "Where do I find this?", symbol: "questionmark.circle") {
                Text("My Voices lists the voices your account can use. Each has a More actions (three dots) menu with Copy voice ID.")
                Text("Voice IDs are made of letters and digits, for example \(ElevenLabsConfiguration.documentationExampleVoiceID). Relay refuses anything that looks like an API key here, so a key is never stored or sent as a voice.")
            }
            HelpDisclosure(title: "Troubleshooting", symbol: "wrench.and.screwdriver") {
                Text("“This voice can't be used with your account” (voice_not_found / voice_access_denied): copy the ID again from My Voices.")
                Text("“Not enough ElevenLabs credits” (HTTP 402 or quota_exceeded): check usage on your subscription page; the key may also have its own credit limit.")
                Text("“Lacks the Text to Speech permission”: edit the key in Developers › API Keys and enable Text to Speech.")
                Text("“The selected model isn't available”: in step 4, go back to the recommended model.")
            }
        }
        .onAppear { if voiceDraft.isEmpty { voiceDraft = model.elevenLabs.voiceID } }
        .onChange(of: model.elevenLabs.voiceID) { _, newValue in voiceDraft = newValue }
    }

    private func save() {
        voiceError = model.saveVoiceID(voiceDraft)
    }
}

// MARK: - Step 3: Microphone and speech input

private struct SpeechInputStep: View {
    @EnvironmentObject private var model: AppModel

    private var status: (String, Color) {
        if model.readiness.microphone == .denied || model.readiness.microphone == .restricted {
            return ("Microphone blocked", Theme.danger)
        }
        switch model.readiness.speechInput {
        case .passed: return ("Tested", Theme.success)
        case .failed, .attention: return ("Test failed", Theme.danger)
        case .checking: return ("Testing…", Theme.accent)
        case .notChecked: return (model.keySaved ? "Not tested" : "Needs API key", Theme.textSecondary)
        }
    }

    var body: some View {
        SetupStep(number: 3, title: "Microphone and speech input",
                  enables: "Lets you talk to Relay with push-to-talk. Audio is recorded only while you hold the button (or during the 3-second test) and is sent to ElevenLabs Speech to Text. You always review the transcript before Relay acts on it.",
                  status: status.0, statusColor: status.1) {
            VStack(alignment: .leading, spacing: 6) {
                AdaptiveRow {
                    StatusPill(text: "Microphone: \(model.readiness.microphone.label)", color: Theme.color(model.readiness.microphone))
                    switch model.readiness.microphone {
                    case .notDetermined:
                        Button("Allow microphone…") { model.requestMicrophone() }
                    case .denied, .restricted:
                        Button("Open Privacy & Security › Microphone") { model.openMicrophoneSettings() }
                    case .granted, .unknown:
                        EmptyView()
                    }
                    Button("Recheck") { model.refreshMicrophone() }
                }
                if model.readiness.microphone == .denied {
                    Text("macOS blocks the microphone for Relay. Turn Relay on in System Settings › Privacy & Security › Microphone. Typing still works.")
                        .font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                AdaptiveRow {
                    testButton
                    if model.inputTestPhase != .idle {
                        Button("Cancel") { model.cancelSpeechInputTest() }
                    }
                }
                CreditNote(text: "Uses ElevenLabs credits: about 3 seconds of audio.")
                if !model.keySaved { Text("Save an API key first (step 1).").font(.caption).foregroundStyle(Theme.textSecondary) }
                CheckResultView(state: model.readiness.speechInput)
                Toggle("Send the training language as a transcription hint", isOn: $model.sendLanguageHint)
                    .font(.callout)
            }
            HelpDisclosure(title: "Troubleshooting", symbol: "wrench.and.screwdriver") {
                Text("No permission prompt appeared: run the packaged app (scripts/build-app.sh). A bare executable started from Xcode has no microphone usage description, and macOS may close it.")
                Text("“No words were detected”: the request worked but the recording was silent. Check the input device in System Settings › Sound and speak during the test.")
                Text("“Lacks the Speech to Text permission”: edit the key in Developers › API Keys and enable Speech to Text.")
                Text("Credits, rate limits and network problems show the same messages as in step 2.")
            }
        }
    }

    @ViewBuilder private var testButton: some View {
        switch model.inputTestPhase {
        case .idle:
            Button { model.testSpeechInput() } label: { Label("Test speech input (record 3 s)", systemImage: "mic") }
                .disabled(!model.keySaved || !model.canStartSpeechTest)
        case let .recording(until):
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let remaining = max(0, until.timeIntervalSince(context.date))
                Label(String(format: "Recording — speak now (%.0f s)", remaining.rounded(.up)), systemImage: "record.circle")
                    .foregroundStyle(Theme.danger)
            }
        case .preparing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Preparing microphone…") }
        case .transcribing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Transcribing…") }
        }
    }
}

// MARK: - Step 4: Models

private struct ModelsStep: View {
    @EnvironmentObject private var model: AppModel
    @State private var advanced = false

    var body: some View {
        SetupStep(number: 4, title: "Models", enables: "Which ElevenLabs models Relay uses. Most people never change them.",
                  status: isRecommended ? "Recommended defaults" : "Your saved choice", statusColor: isRecommended ? Theme.success : Theme.accent) {
            DefaultModelNote(savedGenerationModel: model.elevenLabs.textToSpeechModel)
            ModelPicker(title: "Speech recognition model", explanation: "Turns your recorded voice into text.",
                        choices: ModelChoice.speechRecognition, selection: $model.elevenLabs.speechToTextModel)
            ModelPicker(title: "Speech generation model", explanation: "Turns Relay's replies into spoken audio.",
                        choices: ModelChoice.speechGeneration, selection: $model.elevenLabs.textToSpeechModel)
            ModelPicker(title: "Audio output format", explanation: "The audio format of spoken replies.",
                        choices: ModelChoice.outputFormats, selection: $model.elevenLabs.outputFormat)
            Text("Changing a model resets the matching test, because earlier results no longer apply.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            DisclosureGroup(isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enter exact ElevenLabs model IDs. Relay does not check them; run the tests afterwards. Only MP3 output formats can be played.")
                        .font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    OverrideField(title: "Speech recognition model ID", text: $model.elevenLabs.speechToTextModel)
                    OverrideField(title: "Speech generation model ID", text: $model.elevenLabs.textToSpeechModel)
                    OverrideField(title: "Output format", text: $model.elevenLabs.outputFormat)
                    AdaptiveRow {
                        Button("Reset to recommended") { model.resetModelsToRecommended() }.disabled(isRecommended)
                        LinkButton(title: "ElevenLabs model list", url: ProviderLinks.elevenLabsModelDocs)
                    }
                    Divider()
                    Toggle("Testing aid: wait 5 seconds before each ElevenLabs request", isOn: $model.delayRequestsForTesting)
                        .font(.callout)
                    Text("For checking that results which arrive after you replace the key or change the voice or model are discarded. Real requests are still sent after the wait; nothing is simulated. Turns off when Relay restarts.")
                        .font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            } label: {
                Label("Advanced: custom model IDs", systemImage: "slider.horizontal.3").font(.callout.weight(.medium))
            }
            Divider()
            Toggle("Speak replies automatically when speech output is set up", isOn: $model.autoSpeak).font(.callout)
            CreditNote(text: "Each spoken reply uses ElevenLabs credits. Turn this off to speak only when you press Speak.")
        }
    }

    private var isRecommended: Bool {
        model.elevenLabs.speechToTextModel == ElevenLabsConfiguration.recommendedSpeechToTextModel
            && model.elevenLabs.textToSpeechModel == ElevenLabsConfiguration.recommendedTextToSpeechModel
            && model.elevenLabs.outputFormat == ElevenLabsConfiguration.recommendedOutputFormat
    }
}

/// Explains the speech-generation default and that Relay never changes a saved choice by itself.
private struct DefaultModelNote: View {
    let savedGenerationModel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("About the default", systemImage: "info.circle").font(.callout.weight(.semibold))
            Text("New setups use Flash v2.5 (\(ElevenLabsConfiguration.recommendedTextToSpeechModel)) for speech generation. Earlier Relay builds defaulted to Multilingual v2. The default changed because ElevenLabs' model list includes Norwegian for Flash v2.5 but not for Multilingual v2, and Relay's training includes Norwegian.")
            if savedGenerationModel == "eleven_multilingual_v2" {
                Text("You are using Multilingual v2 from an earlier setup. It is kept as saved; choose Flash v2.5 below if you want Norwegian speech.")
                    .foregroundStyle(Theme.accent)
            }
            Text("Relay never changes a saved model on its own, not even after a failed request. It shows the error and you decide. Whether a model is available, which languages it speaks and how many credits it uses depend on ElevenLabs and your account or plan (checked against ElevenLabs' model list on 7 November 2026).")
        }
        .font(.caption)
        .foregroundStyle(Theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ModelPicker: View {
    let title: String
    let explanation: String
    let choices: [ModelChoice]
    @Binding var selection: String

    private var note: String {
        choices.first(where: { $0.id == selection })?.note ?? "Custom value set under Advanced."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(title, selection: $selection) {
                ForEach(choices) { choice in Text(choice.name).tag(choice.id) }
                if !choices.contains(where: { $0.id == selection }) {
                    Text("Custom: \(selection)").tag(selection)
                }
            }
            .frame(maxWidth: 480)
            Text(explanation + " " + note)
                .font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OverrideField: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(title, text: $text)
                .textFieldStyle(.ds)
                .font(.callout.monospaced())
                .frame(maxWidth: 360)
            if !model.isPlainIdentifier(text) {
                Text("Use only letters, digits and underscores. Requests are blocked until this is fixed.")
                    .font(.caption).foregroundStyle(Theme.danger)
            }
        }
    }
}

// MARK: - Reasoning

private struct ReasoningPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reasoning").font(.headline)
                Text(ReasoningCapability.statement).fixedSize(horizontal: false, vertical: true)
                ReadinessRow(title: "Decision engine", value: model.reasonerName, color: Theme.accent)
                ReadinessRow(title: "Language model", value: ReasoningCapability.languageModel.label, color: Theme.textSecondary)
                Text("“Not implemented” is different from “not configured”: Relay has no language-model adapter, so there is no key or setting to enter. Answers come only from the loaded procedure, and anything else is escalated.")
                    .font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                Text("Relay cannot run programs, browse files or change system settings.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

// MARK: - Wybe Night Shift

private struct WybePanel: View {
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("Wybe Night Shift — live challenge").font(.headline)
                        Spacer(minLength: 8)
                        StatusPill(text: "Live adapter not implemented", color: Theme.warning)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Wybe Night Shift — live challenge").font(.headline)
                        StatusPill(text: "Live adapter not implemented", color: Theme.warning)
                    }
                }
                Text("Registering gives your team a key for the organisers' endpoint. Entering that key will not connect Relay: the live adapter still has to be written once the command format is known.")
                    .font(.callout).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                AdaptiveRow { LinkButton(title: "Open challenge registration", url: ProviderLinks.wybeRegistration) }
                Instructions(lines: WybeIntegration.registrationSteps)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Integration checklist").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    ForEach(WybeIntegration.requirements) { requirement in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: symbol(requirement.status)).foregroundStyle(color(requirement.status))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(requirement.title) — \(statusText(requirement.status))").font(.callout)
                                Text(requirement.detail).font(.caption).foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(10)
                .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Available now: simulation").font(.callout.weight(.semibold)).foregroundStyle(Theme.simulation)
                    Text("Wybe Runner and relay-runner wybe-sim run Relay's own simulator. It uses invented “sim.” commands to exercise the runner's safety features: prioritising tasks, timeouts, bounded retries, not repeating actions after lost responses, and stopping. Its scores are labelled SIMULATED and are not challenge results.")
                        .font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func symbol(_ status: WybeIntegration.Status) -> String {
        switch status {
        case .known: return "checkmark.circle.fill"
        case .teamProvided: return "person.badge.key"
        case .unknown: return "questionmark.circle"
        case .needsDevelopment: return "hammer"
        }
    }

    private func color(_ status: WybeIntegration.Status) -> Color {
        switch status {
        case .known: return Theme.success
        case .teamProvided: return Theme.accent
        case .unknown: return Theme.warning
        case .needsDevelopment: return Theme.danger
        }
    }

    private func statusText(_ status: WybeIntegration.Status) -> String {
        switch status {
        case .known: return "known"
        case .teamProvided: return "from registration"
        case .unknown: return "missing"
        case .needsDevelopment: return "needs development"
        }
    }
}
