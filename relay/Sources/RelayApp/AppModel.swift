import AppKit
import Foundation
import RelayAdapters
import RelayCore
import SwiftUI

/// Holds the current Wybe stop signal so non-isolated code (the assistant's stop tool) can trip it.
final class StopController: @unchecked Sendable {
    private let lock = NSLock()
    private var signal = StopSignal()

    func fresh() -> StopSignal {
        lock.lock(); defer { lock.unlock() }
        signal = StopSignal()
        return signal
    }

    func stop(reason: String) {
        lock.lock(); let current = signal; lock.unlock()
        current.stop(reason: reason)
    }
}

/// UI state for the whole app. All behaviour lives in RelayCore / RelayAdapters; this class
/// only wires them to SwiftUI, the microphone and the speaker.
@MainActor
final class AppModel: ObservableObject {
    // MARK: Core
    let log = InMemoryEventLog()
    private(set) var runtime: AssistantRuntime!
    @Published var interactions: [Interaction] = []
    @Published var tasks: [RelayTask] = []
    @Published var training: TrainingSnapshot?
    @Published var logEntries: [LogEvent] = []
    @Published var notice: String?
    @Published var reasonerName = ""

    // MARK: Voice
    @Published private(set) var voice = VoiceSession()
    @Published var transcriptDraft = ""
    @Published var recordingStartedAt: Date?
    @Published var autoSpeak: Bool { didSet { UserDefaults.standard.set(autoSpeak, forKey: Keys.autoSpeak) } }
    @Published var sendLanguageHint: Bool { didSet { UserDefaults.standard.set(sendLanguageHint, forKey: Keys.languageHint) } }
    @Published var microphoneDenied = false
    private let recorder = AudioRecorder()
    private let player = AudioPlayer()
    private var speechTask: Task<Void, Never>?
    private var talkHeld = false

    // MARK: ElevenLabs
    private let credentials: CredentialStore = KeychainCredentialStore()
    @Published var elevenLabs: ElevenLabsConfiguration {
        didSet { persistConfiguration(); configurationChanged(from: oldValue) }
    }
    @Published var apiKeyDisplay = "Not set"
    /// Five separate facts: key saved, account check, speech input, speech output, microphone.
    @Published private(set) var readiness = ElevenLabsReadiness(keySaved: false, voiceIDSet: false) {
        didSet { refreshSpeechStatus() }
    }

    // MARK: Wybe connection (live). Separate Keychain entry from ElevenLabs.
    private let wybeCredentials: CredentialStore = KeychainCredentialStore(service: CredentialService.wybe)
    @Published private(set) var wybeKeyDisplay = "Not set"
    /// Four separate facts: key saved, connection verified, protocol discovered, live runner ready.
    @Published private(set) var wybeReadiness = WybeReadiness(keySaved: false, helpRequestRecorded: false,
                                                               reviewedMappingAvailable: WybeProtocolMappings.reviewed != nil)
    /// The help request exactly as the service describes it, recorded by the team. Not a secret.
    @Published private(set) var wybeHelpRequest: WybeHelpRequest?
    private var wybeCheckTask: Task<Void, Never>?
    /// One client per saved key, so its rate limiter spans all checks made with that key.
    private var wybeClientCache: (keyGeneration: Int, client: WybeClient)?
    private var wybeKeyGeneration = 0

    // MARK: Wybe simulation
    @Published var wybeRunning = false
    @Published var wybeObservation: RelayCore.Observation?
    @Published var wybeDecision = ""
    @Published var wybeRecords: [ActionRecord] = []
    @Published var wybeReports: [RunReport] = []
    @Published var wybeSeed = 1
    @Published var wybeShifts = 3
    @Published var wybeFaults = "typical"
    @Published var wybePacing = 0.15
    private let stopController = StopController()
    private var wybeTask: Task<Void, Never>?

    private enum Keys {
        static let config = "relay.elevenlabs.configuration"
        static let autoSpeak = "relay.speech.autoSpeak"
        static let languageHint = "relay.speech.languageHint"
        static let wybeHelpRequest = "relay.wybe.helpRequest"
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.config),
           let saved = try? JSONDecoder().decode(ElevenLabsConfiguration.self, from: data) {
            elevenLabs = saved
        } else {
            elevenLabs = ElevenLabsConfiguration()
        }
        autoSpeak = defaults.object(forKey: Keys.autoSpeak) as? Bool ?? true
        sendLanguageHint = defaults.object(forKey: Keys.languageHint) as? Bool ?? false

        let stopController = self.stopController
        runtime = AssistantRuntime(
            log: log,
            simulate: { [weak self] in
                guard let self else { return "Relay is closing." }
                return await self.runOneShiftForAssistant()
            },
            stopRunner: {
                stopController.stop(reason: "Stop requested from the assistant")
                return "Stop requested. The Wybe runner will not send any further actions."
            })

        log.addObserver { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.logEntries.append(event)
                    if self.logEntries.count > 3_000 { self.logEntries.removeFirst(self.logEntries.count - 3_000) }
                }
            }
        }

        let savedKey = CredentialAccess.load(CredentialAccount.elevenLabsAPIKey, from: credentials)
        if let savedKey { apiKeyDisplay = CredentialAccess.masked(savedKey) }
        readiness = ElevenLabsReadiness(keySaved: savedKey != nil, voiceIDSet: !elevenLabs.voiceID.isEmpty)
        let savedWybeKey = CredentialAccess.load(CredentialAccount.wybeTeamKey, from: wybeCredentials)
        wybeKeyDisplay = WybeTeamKeyValidation.display(savedWybeKey)
        if let data = defaults.data(forKey: Keys.wybeHelpRequest),
           let saved = try? JSONDecoder().decode(WybeHelpRequest.self, from: data), saved.problem() == nil {
            wybeHelpRequest = saved
        }
        wybeReadiness = WybeReadiness(keySaved: savedWybeKey != nil, helpRequestRecorded: wybeHelpRequest != nil,
                                      reviewedMappingAvailable: WybeProtocolMappings.reviewed != nil)
        refreshMicrophone()
        refreshSpeechStatus()
        log.record(.settings, .info, "Relay started. \(readiness.summary)")
        Task { await refresh() }
    }

    // MARK: Refresh

    func refresh() async {
        interactions = await runtime.interactions
        tasks = await runtime.tasks.tasks
        training = await runtime.trainingSnapshot()
        reasonerName = await runtime.reasonerName
    }

    var attentionCount: Int { tasks.filter { $0.state == .needsAttention || $0.state == .awaitingApproval }.count }

    // MARK: Assistant

    func send(_ text: String, source: InputSource) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        stopSpeaking()
        Task {
            let interaction = await runtime.handle(HeardInput(text: clean, source: source))
            await refresh()
            if autoSpeak && source != .control { speak(interaction.reply) }
        }
    }

    func approve(_ interaction: Interaction) {
        Task {
            let result = await runtime.approve(interaction.id)
            await refresh()
            if autoSpeak, let reply = result?.reply { speak(reply) }
        }
    }

    func decline(_ interaction: Interaction) {
        Task {
            _ = await runtime.decline(interaction.id)
            await refresh()
        }
    }

    // MARK: Tasks

    func addTask(_ title: String) {
        Task {
            do { try await runtime.addTask(title: title) } catch { notice = String(describing: error) }
            await refresh()
        }
    }

    func transition(_ task: RelayTask, to state: TaskState) {
        Task {
            do { try await runtime.transitionTask(task.id, to: state, note: "Changed in Tasks view") }
            catch { notice = String(describing: error) }
            await refresh()
        }
    }

    // MARK: Training

    func loadProcedure(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let procedure = try Procedure.load(from: Data(contentsOf: url))
            Task {
                await runtime.load(procedure: procedure)
                await refresh()
            }
        } catch {
            notice = "Could not load procedure: \(error)"
            log.record(.warehouse, .failed, "Procedure load failed: \(error)")
        }
    }

    func restoreDemoProcedure() {
        Task {
            await runtime.load(procedure: DemoProcedure.procedure)
            await refresh()
        }
    }

    // MARK: Speech — setup and readiness

    /// Bumped whenever the key, voice, model or format changes. Results of requests started under
    /// an older generation are discarded, so they can't mark the new settings as tested.
    private var settingsGeneration = 0

    /// Testing aid (Settings › Models › Advanced): wait 5 s before each ElevenLabs request so a
    /// setting can be changed while a request is pending. Session only; never saved.
    @Published var delayRequestsForTesting = false {
        didSet {
            if oldValue != delayRequestsForTesting {
                log.record(.settings, .info, delayRequestsForTesting
                           ? "Testing aid ON: ElevenLabs requests wait 5 seconds before being sent"
                           : "Testing aid OFF: ElevenLabs requests are sent immediately")
            }
        }
    }

    private var client: ElevenLabsClient {
        let store = credentials
        let transport: HTTPTransport = delayRequestsForTesting
            ? DelayedTransport(base: URLSessionTransport(), seconds: 5) : URLSessionTransport()
        return ElevenLabsClient(configuration: elevenLabs, transport: transport, apiKey: {
            CredentialAccess.load(CredentialAccount.elevenLabsAPIKey, from: store)
        })
    }

    private func refreshSpeechStatus() {
        voice.transcriberStatus = readiness.transcriberStatus
        voice.synthesizerStatus = readiness.synthesizerStatus
    }

    var speechOutputLabel: String {
        if !readiness.keySaved { return SpeechServiceStatus.unconfigured.label }
        if !readiness.voiceIDSet { return "No voice ID — text only" }
        return readiness.synthesizerStatus.label
    }

    var keySaved: Bool { readiness.keySaved }

    /// Saves (or replaces) the key. Saving verifies nothing: every request-based check resets.
    /// Returns an error message to show next to the field, or nil on success.
    @discardableResult
    func saveAPIKey(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Paste the key first." }
        guard !trimmed.contains(where: { $0.isWhitespace }) else {
            return "The pasted text contains spaces or line breaks, so it is not a single key. Copy just the key."
        }
        let replacing = readiness.keySaved
        do {
            try CredentialAccess.save(trimmed, account: CredentialAccount.elevenLabsAPIKey, to: credentials)
            apiKeyDisplay = CredentialAccess.masked(trimmed)
            settingsGeneration += 1
            readiness.apply(.keySaved)
            log.record(.settings, .info, replacing ? "ElevenLabs API key replaced in the Keychain (not verified yet)"
                                                   : "ElevenLabs API key saved to the Keychain (not verified yet)")
            return nil
        } catch {
            log.record(.settings, .failed, "Saving the ElevenLabs key failed: \(error)")
            return "Could not save to the Keychain: \(error)"
        }
    }

    func removeAPIKey() {
        do {
            try credentials.delete(CredentialAccount.elevenLabsAPIKey)
            apiKeyDisplay = "Not set"
            settingsGeneration += 1
            readiness.apply(.keyRemoved)
            log.record(.settings, .info, "ElevenLabs API key removed from the Keychain")
        } catch {
            notice = "Could not remove the key: \(error)"
        }
    }

    /// Explicit user action: GET /v1/user. Uses no credits.
    func checkAccount() {
        guard readiness.keySaved, readiness.account != .checking else { return }
        readiness.apply(.accountCheckStarted)
        log.record(.speech, .attempted, "Account check: GET /v1/user")
        let speechClient = client
        let generation = settingsGeneration
        Task {
            let result = await speechClient.checkAccount()
            guard generation == settingsGeneration else {
                // The key changed meanwhile; the core also ignores results for checks no longer running.
                log.record(.speech, .info, "Discarded an account-check result: the key changed while the request was pending")
                return
            }
            readiness.apply(.accountCheckFinished(result, at: Date()))
            switch readiness.account {
            case .passed: log.record(.speech, .succeeded, "Account check passed (this does not test speech)")
            case let .attention(p): log.record(.speech, .needsAttention, "Account check: \(p.title)")
            case let .failed(p): log.record(.speech, .failed, "Account check failed: \(p.title)")
            default: break
            }
        }
    }

    /// Validates and stores the voice ID. Returns an error message, or nil on success.
    @discardableResult
    func saveVoiceID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = VoiceIDValidation.problem(with: value) {
            // Never store or log the rejected text: it may be an API key pasted in the wrong field.
            log.record(.settings, .rejected, "Voice ID not saved: \(problem)")
            return "Not saved: \(problem)"
        }
        elevenLabs.voiceID = value
        log.record(.settings, .info, value.isEmpty ? "Voice ID cleared" : "Voice ID set to \(value)")
        return nil
    }

    func useExampleVoice() { saveVoiceID(ElevenLabsConfiguration.documentationExampleVoiceID) }

    func resetModelsToRecommended() {
        elevenLabs.speechToTextModel = ElevenLabsConfiguration.recommendedSpeechToTextModel
        elevenLabs.textToSpeechModel = ElevenLabsConfiguration.recommendedTextToSpeechModel
        elevenLabs.outputFormat = ElevenLabsConfiguration.recommendedOutputFormat
        log.record(.settings, .info, "Speech models reset to the recommended defaults")
    }

    private func configurationChanged(from old: ElevenLabsConfiguration) {
        if old != elevenLabs { settingsGeneration += 1 }
        if old.voiceID != elevenLabs.voiceID {
            readiness.apply(.voiceIDChanged(isSet: !elevenLabs.voiceID.isEmpty))
        }
        if old.speechToTextModel != elevenLabs.speechToTextModel { readiness.apply(.speechInputSettingsChanged) }
        if old.textToSpeechModel != elevenLabs.textToSpeechModel || old.outputFormat != elevenLabs.outputFormat {
            readiness.apply(.speechOutputSettingsChanged)
        }
    }

    func isPlainIdentifier(_ value: String) -> Bool { ElevenLabsClient.isPlainIdentifier(value) }

    // MARK: Microphone

    func refreshMicrophone() {
        readiness.apply(.microphone(AudioRecorder.permission))
    }

    func requestMicrophone() {
        Task {
            _ = await AudioRecorder.requestPermission()
            refreshMicrophone()
            log.record(.speech, .info, "Microphone permission: \(readiness.microphone.label)")
        }
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
        log.record(.settings, .info, "Opened \(url.host ?? "")\(url.path) in the browser")
    }

    // MARK: Explicit speech tests (use ElevenLabs credits)

    enum InputTestPhase: Equatable {
        case idle
        /// Waiting for microphone permission / starting the recorder.
        case preparing
        case recording(until: Date)
        case transcribing
    }

    @Published private(set) var inputTestPhase: InputTestPhase = .idle
    private var inputTestTask: Task<Void, Never>?
    private var inputTestToken = UUID()
    static let voiceTestSample = "Hello. This is Relay's voice test."
    static let inputTestSeconds: Double = 3

    /// Records a few seconds and sends them to speech-to-text. Explicit user action only.
    func testSpeechInput() {
        guard readiness.keySaved, canStartSpeechTest else { return }
        if case .failed = voice.state { dismissVoiceError() }
        stopSpeaking()
        let token = UUID()
        inputTestToken = token
        inputTestPhase = .preparing
        let generation = settingsGeneration
        inputTestTask = Task {
            // Every write below first checks that this test is still the current one.
            guard await AudioRecorder.requestPermission() else {
                refreshMicrophone()
                if isCurrentInputTest(token) {
                    readiness.apply(.speechInputBlocked(.microphoneDenied))
                    log.record(.speech, .failed, "Speech input test: microphone access denied")
                }
                finishInputTest(token)
                return
            }
            refreshMicrophone()
            guard isCurrentInputTest(token), !isRecording else { finishInputTest(token); return }
            do { try recorder.start() } catch {
                readiness.apply(.speechInputBlocked(.recording(String(describing: error))))
                finishInputTest(token)
                return
            }
            inputTestPhase = .recording(until: Date().addingTimeInterval(Self.inputTestSeconds))
            log.record(.speech, .info, "Speech input test: recording \(Int(Self.inputTestSeconds)) seconds")
            try? await Task.sleep(nanoseconds: UInt64(Self.inputTestSeconds * 1_000_000_000))
            guard isCurrentInputTest(token), let recording = recorder.stop() else {
                finishInputTest(token)
                return
            }
            defer { try? FileManager.default.removeItem(at: recording.url) }
            inputTestPhase = .transcribing
            readiness.apply(.speechInputStarted)
            let transcriber = ElevenLabsTranscriber(client: client)
            log.record(.speech, .attempted, "Speech input test: sending audio to \(transcriber.providerName)")
            let outcome: Result<String, ElevenLabsError>
            do {
                let audio = try Data(contentsOf: recording.url)
                let transcript = try await transcriber.transcribe(audio: audio, filename: "relay-input-test.m4a",
                                                                  mimeType: "audio/mp4", languageHint: languageHint)
                outcome = .success(transcript.text)
            } catch {
                outcome = .failure(Self.asElevenLabsError(error))
            }
            guard isCurrentInputTest(token), generation == settingsGeneration else {
                // Cancelled, superseded, or the settings changed meanwhile: the result no longer applies.
                if readiness.speechInput == .checking, inputTestToken == token { readiness.apply(.speechInputSettingsChanged) }
                log.record(.speech, .info, generation != settingsGeneration
                           ? "Discarded a speech-input test result: settings changed while the request was pending"
                           : "Discarded a speech-input test result: the test was cancelled or replaced")
                finishInputTest(token)
                return
            }
            readiness.apply(.speechInputFinished(outcome, at: Date()))
            switch outcome {
            case .success: log.record(.speech, .succeeded, "Speech input test passed")
            case .failure: log.record(.speech, .failed, "Speech input test failed: \(readiness.speechInput.problem?.title ?? "")")
            }
            finishInputTest(token)
        }
    }

    private func isCurrentInputTest(_ token: UUID) -> Bool { inputTestToken == token && !Task.isCancelled }

    private func finishInputTest(_ token: UUID) { if inputTestToken == token { inputTestPhase = .idle } }

    func cancelSpeechInputTest() {
        inputTestToken = UUID() // the running task stops writing state
        inputTestTask?.cancel()
        inputTestTask = nil
        if case .recording = inputTestPhase { recorder.cancel() }
        if readiness.speechInput == .checking { readiness.apply(.speechInputSettingsChanged) }
        inputTestPhase = .idle
    }

    /// Speaks a short fixed sample with the chosen voice. Explicit user action only.
    func testVoice() {
        speak(Self.voiceTestSample, isTest: true)
    }

    static func asElevenLabsError(_ error: Error) -> ElevenLabsError {
        (error as? ElevenLabsError) ?? .network(String(describing: error))
    }

    // MARK: Speech — push to talk

    var isRecording: Bool { if case .recording = voice.state { return true } else { return false } }

    /// Tests may start only when nothing else is using the microphone or speaker, and no transcript
    /// is waiting for review.
    var canStartSpeechTest: Bool {
        guard inputTestPhase == .idle else { return false }
        if case .failed = voice.state { return true }
        return voice.state == .idle
    }
    var isSpeaking: Bool { voice.state == .speaking }

    /// ElevenLabs takes ISO 639 codes; Relay's Norwegian training text is bokmål ("nb"), sent as "no".
    private func providerLanguage(_ code: String?) -> String? {
        guard let code else { return nil }
        return code == "nb" ? "no" : code
    }

    private var languageHint: String? {
        guard sendLanguageHint else { return nil }
        return providerLanguage(training?.language)
    }

    func pressTalk() {
        guard voice.canRecord, !isRecording, inputTestPhase == .idle else { return }
        talkHeld = true
        stopSpeaking()
        Task {
            guard await AudioRecorder.requestPermission() else {
                microphoneDenied = true
                refreshMicrophone()
                log.record(.speech, .failed, "Microphone permission denied — use text input or allow Relay in System Settings › Privacy & Security › Microphone")
                return
            }
            microphoneDenied = false
            refreshMicrophone()
            guard talkHeld else { return } // released before permission resolved
            do {
                try recorder.start()
                try voice.handle(.pressTalk(at: Date()))
                recordingStartedAt = Date()
                log.record(.speech, .info, "Recording (push-to-talk)")
            } catch {
                recorder.cancel()
                log.record(.speech, .failed, "Could not start recording: \(error)")
                notice = "Could not start recording: \(error)"
            }
        }
    }

    func releaseTalk() {
        talkHeld = false
        guard isRecording else { return }
        recordingStartedAt = nil
        guard let recording = recorder.stop() else { return }
        try? voice.handle(.releaseTalk)
        guard recording.duration >= 0.3 else {
            try? FileManager.default.removeItem(at: recording.url)
            try? voice.handle(.transcriptionFailed("Recording too short — hold the button while speaking"))
            return
        }
        let transcriber = ElevenLabsTranscriber(client: client)
        let hint = languageHint
        let generation = settingsGeneration
        log.record(.speech, .attempted, String(format: "Sending %.1fs of audio to %@", recording.duration, transcriber.providerName))
        Task {
            defer { try? FileManager.default.removeItem(at: recording.url) }
            do {
                let audio = try Data(contentsOf: recording.url)
                let transcript = try await transcriber.transcribe(audio: audio, filename: "push-to-talk.m4a",
                                                                  mimeType: "audio/mp4", languageHint: hint)
                if generation == settingsGeneration {
                    readiness.apply(.speechInputFinished(.success(transcript.text), at: Date()))
                } else {
                    log.record(.speech, .info, "Transcript kept, but not counted as a test: settings changed while the request was pending")
                }
                transcriptDraft = transcript.text
                log.record(.speech, .succeeded, "Transcript ready for review", details: ["provider": transcript.provider])
                try? voice.handle(.transcriptReady(text: transcript.text, provider: transcript.provider))
            } catch {
                let failure = Self.asElevenLabsError(error)
                let title = SetupProblem(failure, context: .speechInput).title
                if generation == settingsGeneration {
                    readiness.apply(.speechInputFinished(.failure(failure), at: Date()))
                }
                log.record(.speech, .failed, "Transcription failed: \(title)")
                try? voice.handle(.transcriptionFailed(title))
            }
        }
    }

    func submitTranscript() {
        guard case let .reviewing(original, provider) = voice.state else { return }
        let text = transcriptDraft
        try? voice.handle(.submitReview)
        transcriptDraft = ""
        send(text, source: .transcribed(provider: provider, edited: text != original))
    }

    func discardTranscript() {
        try? voice.handle(.discardReview)
        transcriptDraft = ""
        log.record(.speech, .info, "Transcript discarded")
    }

    func dismissVoiceError() { try? voice.handle(.dismissError) }

    // MARK: Speech — replies

    func speak(_ text: String, isTest: Bool = false) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, voice.canSpeak, inputTestPhase == .idle else { return }
        // Only start from idle or after an error; never interrupt recording or transcript review.
        do { try voice.handle(.startSpeaking) } catch { return }
        if isTest { readiness.apply(.speechOutputStarted) }
        let generation = settingsGeneration
        let synthesizer = ElevenLabsSynthesizer(client: client)
        let language = providerLanguage(training?.language)
        // Keep requests short; long replies are truncated for speech only (the text stays complete).
        let spoken = clean.count > 1_200 ? String(clean.prefix(1_200)) + "…" : clean
        log.record(.speech, .attempted, isTest ? "Voice test: requesting a short sample from \(synthesizer.providerName)"
                                               : "Requesting speech from \(synthesizer.providerName)",
                   details: ["characters": String(spoken.count)])
        speechTask = Task {
            do {
                let audio = try await synthesizer.synthesize(text: spoken, languageCode: language)
                if generation == settingsGeneration {
                    readiness.apply(.speechOutputFinished(.success(()), at: Date()))
                } else {
                    if isTest, readiness.speechOutput == .checking { readiness.apply(.speechOutputSettingsChanged) }
                    log.record(.speech, .info, "Discarded a speech-output result: settings changed while the request was pending")
                }
                guard !Task.isCancelled, voice.state == .speaking else { return }
                try player.play(audio.data) { [weak self] in
                    guard let self else { return }
                    try? self.voice.handle(.finishedSpeaking)
                }
                log.record(.speech, .succeeded, isTest ? "Voice test passed: playing sample" : "Playing spoken reply")
            } catch {
                // Stop playback cancels the request; that is not a failure.
                if Task.isCancelled || error is CancellationError {
                    if isTest, readiness.speechOutput == .checking { readiness.apply(.speechOutputSettingsChanged) }
                    return
                }
                let title: String
                if let ell = error as? ElevenLabsError {
                    title = SetupProblem(ell, context: .speechOutput).title
                    if generation == settingsGeneration {
                        readiness.apply(.speechOutputFinished(.failure(ell), at: Date()))
                    } else if isTest, readiness.speechOutput == .checking {
                        readiness.apply(.speechOutputSettingsChanged)
                    }
                } else {
                    // Audio arrived but could not be played: a local problem, not a provider failure.
                    title = "Playback failed: \(error)"
                    if isTest, generation == settingsGeneration {
                        readiness.apply(.speechOutputFinished(.success(()), at: Date()))
                    }
                }
                log.record(.speech, .failed, "Speech output failed: \(title)")
                try? voice.handle(.speakingFailed(title))
            }
        }
    }

    func stopSpeaking() {
        speechTask?.cancel()
        speechTask = nil
        let wasSpeaking = isSpeaking
        player.stop()
        try? voice.handle(.stopSpeaking)
        if wasSpeaking { log.record(.speech, .info, "Playback stopped") }
    }

    // MARK: Wybe connection

    /// Saves (or replaces) the team key in its own Keychain entry. Saving verifies nothing.
    /// Returns an error message to show next to the field, or nil on success.
    @discardableResult
    func saveWybeKey(_ raw: String) -> String? {
        if let problem = WybeTeamKeyValidation.problem(with: raw) {
            // Never store or log the rejected text: it may be another credential.
            log.record(.settings, .rejected, "Wybe team key not saved: \(problem)")
            return problem
        }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacing = wybeReadiness.keySaved
        do {
            try CredentialAccess.save(key, account: CredentialAccount.wybeTeamKey, to: wybeCredentials)
        } catch {
            log.record(.settings, .failed, "Saving the Wybe team key failed: \(error)")
            return "Could not save to the Keychain: \(error)"
        }
        stopPendingWybeCheck()
        wybeKeyGeneration += 1
        wybeClientCache = nil
        wybeKeyDisplay = WybeTeamKeyValidation.display(key)
        wybeReadiness.apply(.keySaved)
        log.record(.settings, .info, replacing ? "Wybe team key replaced in the Keychain (not verified yet)"
                                               : "Wybe team key saved to the Keychain (not verified yet)")
        return nil
    }

    func removeWybeKey() {
        do {
            try wybeCredentials.delete(CredentialAccount.wybeTeamKey)
        } catch {
            notice = "Could not remove the Wybe team key: \(error)"
            return
        }
        stopPendingWybeCheck()
        wybeKeyGeneration += 1
        wybeClientCache = nil
        wybeKeyDisplay = "Not set"
        wybeReadiness.apply(.keyRemoved)
        log.record(.settings, .info, "Wybe team key removed from the Keychain")
    }

    /// Records the help request form the service describes. Returns a problem, or nil on success.
    @discardableResult
    func saveWybeHelpRequest(_ request: WybeHelpRequest) -> String? {
        if let problem = request.problem() {
            log.record(.settings, .rejected, "Wybe help request not recorded: \(problem)")
            return problem
        }
        stopPendingWybeCheck()
        wybeHelpRequest = request
        if let data = try? JSONEncoder().encode(request) { UserDefaults.standard.set(data, forKey: Keys.wybeHelpRequest) }
        wybeReadiness.apply(.helpRequestChanged(recorded: true))
        log.record(.settings, .info, "Wybe help request recorded: \(request.request?.summary ?? "") (source: \(request.source))")
        return nil
    }

    func clearWybeHelpRequest() {
        stopPendingWybeCheck()
        wybeHelpRequest = nil
        UserDefaults.standard.removeObject(forKey: Keys.wybeHelpRequest)
        wybeReadiness.apply(.helpRequestChanged(recorded: false))
        log.record(.settings, .info, "Wybe help request cleared")
    }

    private func currentWybeClient() -> WybeClient? {
        if let cache = wybeClientCache, cache.keyGeneration == wybeKeyGeneration { return cache.client }
        // Snapshot of the key: a later replacement gets a new client and the old one's results are discarded.
        guard let key = CredentialAccess.load(CredentialAccount.wybeTeamKey, from: wybeCredentials) else { return nil }
        let client = WybeClient(teamKey: { key })
        wybeClientCache = (keyGeneration: wybeKeyGeneration, client: client)
        return client
    }

    /// Explicit user action: one authenticated GET / (read-only). Never starts a shift.
    func checkWybeConnection() {
        guard let client = currentWybeClient(), let generation = wybeReadiness.beginConnectionCheck() else { return }
        log.record(.wybe, .attempted, "Connection check: GET \(WybeIntegration.endpoint) with the team key (read-only)", mode: .live)
        wybeCheckTask = Task { [weak self] in
            let result = await client.checkConnection()
            guard let self else { return }
            guard self.wybeReadiness.apply(.connectionFinished(generation: generation, result, at: Date())) else {
                self.log.record(.wybe, .info, "Discarded a connection result: the key or settings changed while it was pending", mode: .live)
                return
            }
            switch result {
            case let .success(report):
                self.log.record(.wybe, .succeeded, "Connection verified (HTTP \(report.httpStatus)). Service said: \(report.resultText)", mode: .live)
            case .failure(.cancelled):
                self.log.record(.wybe, .info, "Connection check cancelled", mode: .live)
            case let .failure(failure):
                self.log.record(.wybe, .failed, "Connection check failed: \(failure)", mode: .live)
            }
        }
    }

    /// Explicit user action: sends the recorded help request once. Never retried automatically.
    func discoverWybeProtocol() {
        guard let help = wybeHelpRequest, let client = currentWybeClient(),
              let generation = wybeReadiness.beginDiscovery() else { return }
        log.record(.wybe, .attempted, "Protocol discovery: \(help.request?.summary ?? "") (sent once)", mode: .live)
        wybeCheckTask = Task { [weak self] in
            let result = await client.discover(with: help)
            guard let self else { return }
            guard self.wybeReadiness.apply(.discoveryFinished(generation: generation, result, at: Date())) else {
                self.log.record(.wybe, .info, "Discarded a help answer: the key or settings changed while it was pending", mode: .live)
                return
            }
            switch result {
            case let .success(transcript):
                self.log.record(.wybe, .succeeded, "Help answered (HTTP \(transcript.httpStatus)); commands are not mapped automatically",
                                mode: .live, details: ["answer": String(transcript.answer.prefix(2_000))])
            case .failure(.cancelled):
                self.log.record(.wybe, .info, "Protocol discovery cancelled", mode: .live)
            case let .failure(failure):
                self.log.record(.wybe, .failed, "Protocol discovery failed: \(failure)", mode: .live)
            }
        }
    }

    func cancelWybeCheck() {
        guard wybeReadiness.connection.isChecking || wybeReadiness.discovery.isChecking else { return }
        stopPendingWybeCheck()
        log.record(.wybe, .info, "Wybe check cancelled; an answer that still arrives will be ignored", mode: .live)
    }

    private func stopPendingWybeCheck() {
        wybeCheckTask?.cancel()
        wybeCheckTask = nil
        wybeReadiness.apply(.checkCancelled)
    }

    // MARK: Wybe simulation

    private var selectedFaults: SimulatedNightShift.Faults {
        switch wybeFaults {
        case "none": return .none
        case "harsh": return .harsh
        default: return .typical
        }
    }

    func startSimulation() {
        guard !wybeRunning else { return }
        let stop = stopController.fresh()
        wybeRunning = true
        wybeRecords = []
        wybeReports = []
        wybeObservation = nil
        wybeDecision = ""
        let seed = UInt64(max(0, wybeSeed))
        let shifts = max(1, wybeShifts)
        let faults = selectedFaults
        let pacing = wybePacing
        wybeTask = Task { [weak self] in
            for index in 0..<shifts {
                if stop.isStopped { break }
                guard let self else { return }
                _ = await self.runShift(seed: seed + UInt64(index), faults: faults, pacing: pacing, stop: stop)
            }
            self?.wybeRunning = false
        }
    }

    func stopSimulation() {
        stopController.stop(reason: "Stop pressed in Wybe Runner")
        log.record(.wybe, .info, "Stop requested — no further actions will be sent", mode: .simulation)
    }

    private func runShift(seed: UInt64, faults: SimulatedNightShift.Faults, pacing: Double, stop: StopSignal) async -> RunReport {
        let simulator = SimulatedNightShift(configuration: .init(seed: seed, faults: faults))
        var configuration = RunnerConfiguration.simulation()
        configuration.minRequestInterval = pacing // visible pacing in the UI; the CLI runs unpaced
        let runner = AutonomousRunner(adapter: simulator, policy: SimulatedShiftPolicy(), configuration: configuration,
                                      log: log, stop: stop) { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.apply(event) }
            }
        }
        return await runner.run()
    }

    private func apply(_ event: RunnerEvent) {
        switch event {
        case let .observed(observation): wybeObservation = observation
        case let .decided(text): wybeDecision = text
        case let .recorded(record):
            wybeRecords.append(record)
            if wybeRecords.count > 1_000 { wybeRecords.removeFirst(wybeRecords.count - 1_000) }
        case let .finished(report): wybeReports.append(report)
        }
    }

    /// Used by the assistant's approved "run the simulation" request: one shift, unpaced.
    private func runOneShiftForAssistant() async -> String {
        guard !wybeRunning else { return "A Wybe run is already active; not starting another." }
        wybeRunning = true
        defer { wybeRunning = false }
        let stop = stopController.fresh()
        let report = await runShift(seed: UInt64(max(0, wybeSeed)), faults: selectedFaults, pacing: 0, stop: stop)
        return report.summary
    }

    var simulatedAverage: LabeledScore? {
        let scores = wybeReports.compactMap(\.score).filter { $0.mode == .simulation }
        guard !scores.isEmpty else { return nil }
        return LabeledScore(mode: .simulation, value: scores.map(\.value).reduce(0, +) / Double(scores.count),
                            source: "Relay simulator, \(scores.count) shift(s)")
    }

    // MARK: Activity export

    func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "relay-activity.jsonl"
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(log.exportJSONLines().utf8).write(to: url)
            log.record(.settings, .info, "Exported redacted activity log (\(log.entries().count) entries)")
        } catch {
            notice = "Export failed: \(error)"
        }
    }

    private func persistConfiguration() {
        if let data = try? JSONEncoder().encode(elevenLabs) { UserDefaults.standard.set(data, forKey: Keys.config) }
    }
}
