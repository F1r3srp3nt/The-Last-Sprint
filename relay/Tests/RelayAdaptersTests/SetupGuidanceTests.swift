import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RelayAdapters
@testable import RelayCore

final class ErrorClassificationTests: XCTestCase {
    func classify(_ status: Int, _ body: String, redactor: Redactor = Redactor()) -> ElevenLabsRejection {
        ElevenLabsRejection.classify(status: status, body: Data(body.utf8), redactor: redactor)
    }

    func testDocumentedCodesMapToSpecificKinds() {
        let cases: [(Int, String, ElevenLabsRejection.Kind)] = [
            (401, #"{"detail":{"type":"authentication_error","code":"invalid_api_key","message":"Invalid API key"}}"#, .invalidCredentials),
            (401, #"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#, .invalidCredentials),
            (403, #"{"detail":{"type":"authorization_error","code":"insufficient_permissions","message":"missing user_read"}}"#, .missingPermission),
            (404, #"{"detail":{"type":"not_found","code":"voice_not_found","message":"Voice not found"}}"#, .voiceUnavailable),
            (403, #"{"detail":{"type":"authorization_error","code":"voice_access_denied"}}"#, .voiceUnavailable),
            (404, #"{"detail":{"type":"not_found","code":"model_not_found"}}"#, .modelUnavailable),
            (400, #"{"detail":{"type":"validation_error","code":"unsupported_model"}}"#, .modelUnavailable),
            (402, #"{"detail":{"type":"payment_required","code":"insufficient_credits"}}"#, .creditsExhausted),
            (401, #"{"detail":{"status":"quota_exceeded","message":"insufficient quota"}}"#, .creditsExhausted),
            (403, #"{"detail":{"type":"authorization_error","code":"subscription_required"}}"#, .planRestriction),
            (429, #"{"detail":{"status":"system_busy"}}"#, .rateLimited),
            (429, #"{"detail":{"type":"rate_limit_error","code":"concurrent_limit_exceeded"}}"#, .rateLimited),
            (500, #"{"detail":{"type":"internal_error"}}"#, .serverError),
        ]
        for (status, body, expected) in cases {
            XCTAssertEqual(classify(status, body).kind, expected, body)
        }
    }

    func testAmbiguousResponsesAreNotGivenASpecificCause() {
        // A bare 403 might be a permission, an IP allowlist or workspace access: stay general.
        XCTAssertEqual(classify(403, #"{"detail":{"type":"authorization_error","code":"forbidden","message":"nope"}}"#).kind, .accessDenied)
        XCTAssertEqual(classify(403, "").kind, .accessDenied)
        // A 404 without a code could be the voice or the model: unrecognised, message shown.
        XCTAssertEqual(classify(404, #"{"detail":"Not Found"}"#).kind, .unrecognised)
        let problem = SetupProblem(.rejected(classify(403, #"{"detail":{"message":"Request blocked"}}"#)), context: .speechOutput)
        XCTAssertTrue(problem.nextStep.contains("does not show whether the key is valid"))
        XCTAssertTrue(problem.providerDetail?.contains("Request blocked") == true)
    }

    func testMessagesAndRequestIDsAreRedactedAndKept() {
        let redactor = Redactor()
        let key = "sk_0123456789abcdef0123456789abcdef"
        redactor.register(secret: key)
        let r = classify(401, "{\"detail\":{\"code\":\"invalid_api_key\",\"message\":\"bad key \(key)\",\"request_id\":\"req123\"}}",
                         redactor: redactor)
        XCTAssertFalse(r.message.contains(key))
        XCTAssertEqual(r.requestID, "req123")
        let problem = SetupProblem(.rejected(r), context: .accountCheck)
        XCTAssertFalse("\(problem.title) \(problem.nextStep) \(problem.providerDetail ?? "")".contains(key))
        XCTAssertTrue(problem.providerDetail!.contains("req123"))
    }

    func testPermissionIsNamedOnlyWhenTheProviderNamesIt() {
        // Code present, no permission in the message: no specific permission is claimed as missing.
        let unnamed = classify(403, #"{"detail":{"type":"authorization_error","code":"insufficient_permissions","message":"You do not have the required permissions"}}"#)
        let p1 = SetupProblem(.rejected(unnamed), context: .accountCheck)
        XCTAssertEqual(p1.title, "ElevenLabs reports insufficient permissions for this request")
        XCTAssertFalse(p1.title.contains("user_read"))
        XCTAssertFalse(p1.title.lowercased().contains("valid"), "never claims the key is valid")
        // The next step states what Relay's request uses (a requirement, not a diagnosis).
        XCTAssertTrue(p1.nextStep.contains("This request needs User (read) (user_read)"))
        XCTAssertTrue(SetupProblem(.rejected(unnamed), context: .speechInput).nextStep.contains("speech_to_text"))
        XCTAssertTrue(SetupProblem(.rejected(unnamed), context: .speechOutput).nextStep.contains("text_to_speech"))

        // The provider names the permission: it may be repeated.
        let named = classify(403, #"{"detail":{"code":"insufficient_permissions","message":"The API key is missing the permission user_read"}}"#)
        XCTAssertEqual(SetupProblem(.rejected(named), context: .accountCheck).title,
                       "ElevenLabs reports a missing permission: user_read")
        XCTAssertNil(ElevenLabsPermissionNames.mentioned(in: "user reading is fun"), "whole identifiers only")

        // A permission code wins over the HTTP status: a 401 carrying it is not "invalid key".
        let legacy = classify(401, #"{"detail":{"status":"missing_permissions","message":"The API key you used is missing the permission user_read to execute this operation."}}"#)
        XCTAssertEqual(legacy.kind, .missingPermission)
        XCTAssertEqual(SetupProblem(.rejected(legacy), context: .accountCheck).title,
                       "ElevenLabs reports a missing permission: user_read")
    }

    func testBare403IsInconclusive() {
        for body in ["", #"{"detail":{"message":"Forbidden"}}"#, #"{"detail":{"type":"authorization_error","code":"forbidden"}}"#] {
            let r = classify(403, body)
            XCTAssertEqual(r.kind, .accessDenied, body)
            let p = SetupProblem(.rejected(r), context: .accountCheck)
            XCTAssertTrue(p.title.contains("cause is not stated"))
            XCTAssertTrue(p.nextStep.contains("does not show whether the key is valid"))
            XCTAssertFalse(p.title.contains("user_read"))
            XCTAssertFalse(p.title.lowercased().contains("permission"), "no specific permission diagnosis in the title")
            var readiness = ElevenLabsReadiness(keySaved: true, voiceIDSet: false)
            readiness.apply(.accountCheckStarted)
            readiness.apply(.accountCheckFinished(.failure(.rejected(r)), at: Date()))
            guard case .failed = readiness.account else { return XCTFail("a bare 403 is a failure, not 'needs attention'") }
        }
    }

    func testInvalidKeyAndMissingPermissionAreDistinguishedOnAccountCheck() {
        var readiness = ElevenLabsReadiness(keySaved: true, voiceIDSet: false)
        readiness.apply(.accountCheckStarted)
        readiness.apply(.accountCheckFinished(.failure(.rejected(classify(401, #"{"detail":{"code":"invalid_api_key"}}"#))), at: Date()))
        guard case let .failed(invalid) = readiness.account else { return XCTFail("invalid key must fail") }
        XCTAssertTrue(invalid.title.contains("did not accept"))

        readiness.apply(.accountCheckStarted)
        readiness.apply(.accountCheckFinished(.failure(.rejected(classify(403, #"{"detail":{"code":"insufficient_permissions"}}"#))), at: Date()))
        guard case let .attention(limited) = readiness.account else {
            return XCTFail("an explicit insufficient_permissions code is attention, not failure")
        }
        XCTAssertTrue(limited.title.contains("insufficient permissions"))
        XCTAssertTrue(limited.nextStep.contains("account check is optional"))
    }

    func testEveryKindHasActionableGuidanceAndNoEmptyText() {
        let kinds: [ElevenLabsRejection.Kind] = [.invalidCredentials, .missingPermission, .accessDenied, .planRestriction,
                                                 .voiceUnavailable, .modelUnavailable, .creditsExhausted, .rateLimited,
                                                 .invalidRequest, .serverError, .unrecognised]
        for kind in kinds {
            let r = ElevenLabsRejection(kind: kind, httpStatus: 400, code: nil, type: nil, message: "", requestID: nil)
            for context in [SetupContext.accountCheck, .speechInput, .speechOutput] {
                let p = SetupProblem(.rejected(r), context: context)
                XCTAssertFalse(p.title.isEmpty)
                XCTAssertGreaterThan(p.nextStep.count, 20, "\(kind)")
            }
        }
        XCTAssertTrue(SetupProblem(.network("offline"), context: .speechInput).nextStep.contains("cannot tell"))
    }
}

final class ReadinessTests: XCTestCase {
    func testSavedKeyIsNotAVerifiedConnection() {
        var r = ElevenLabsReadiness(keySaved: false, voiceIDSet: true)
        XCTAssertEqual(r.transcriberStatus, .unconfigured)
        r.apply(.keySaved)
        XCTAssertEqual(r.account, .notChecked)
        XCTAssertEqual(r.transcriberStatus, .configuredUnverified)
        XCTAssertEqual(r.synthesizerStatus, .configuredUnverified)
    }

    func testAccountCheckDoesNotProveSpeech() {
        var r = ElevenLabsReadiness(keySaved: true, voiceIDSet: true)
        r.apply(.accountCheckStarted)
        r.apply(.accountCheckFinished(.success(()), at: Date()))
        XCTAssertTrue(r.account.isPassed)
        XCTAssertEqual(r.speechInput, .notChecked)
        XCTAssertEqual(r.speechOutput, .notChecked)
        XCTAssertEqual(r.transcriberStatus, .configuredUnverified)
        XCTAssertEqual(r.synthesizerStatus, .configuredUnverified)
    }

    func testSpeechChecksPassOnlyFromTheirOwnRequests() {
        var r = ElevenLabsReadiness(keySaved: true, voiceIDSet: true)
        let t = Date(timeIntervalSince1970: 5)
        r.apply(.speechInputFinished(.success("hello"), at: t))
        XCTAssertEqual(r.transcriberStatus, .connected(verifiedAt: t))
        XCTAssertEqual(r.synthesizerStatus, .configuredUnverified)
        r.apply(.speechOutputFinished(.success(()), at: t))
        XCTAssertEqual(r.synthesizerStatus, .connected(verifiedAt: t))
        XCTAssertEqual(r.account, .notChecked, "speech success says nothing about the account endpoint")
    }

    func testChangesResetOnlyWhatTheyAffect() {
        var r = ElevenLabsReadiness(keySaved: true, voiceIDSet: true)
        r.apply(.accountCheckStarted)
        r.apply(.accountCheckFinished(.success(()), at: Date()))
        r.apply(.speechInputFinished(.success("a"), at: Date()))
        r.apply(.speechOutputFinished(.success(()), at: Date()))

        r.apply(.voiceIDChanged(isSet: true))
        XCTAssertEqual(r.speechOutput, .notChecked)
        XCTAssertTrue(r.speechInput.isPassed)
        XCTAssertTrue(r.account.isPassed)

        r.apply(.speechInputSettingsChanged)
        XCTAssertEqual(r.speechInput, .notChecked)
        XCTAssertTrue(r.account.isPassed)

        r.apply(.keySaved) // a replaced key verifies nothing
        XCTAssertEqual(r.account, .notChecked)

        r.apply(.speechOutputFinished(.success(()), at: Date()))
        r.apply(.keyRemoved)
        XCTAssertEqual(r.speechOutput, .notChecked)
        XCTAssertEqual(r.synthesizerStatus, .unconfigured)
        XCTAssertEqual(r.summary, "Speech not set up — typing works")
    }

    func testStaleAccountCheckCannotVerifyAReplacedKey() {
        var r = ElevenLabsReadiness(keySaved: true, voiceIDSet: false)
        r.apply(.accountCheckStarted)
        r.apply(.keySaved) // key replaced while the old check is in flight
        r.apply(.accountCheckFinished(.success(()), at: Date()))
        XCTAssertEqual(r.account, .notChecked, "the old key's result must not count for the new key")
        r.apply(.accountCheckFinished(.success(()), at: Date()))
        XCTAssertEqual(r.account, .notChecked, "a result for a check that was never started is ignored")
    }

    func testGrantingMicrophoneClearsTheDeniedResult() {
        var r = ElevenLabsReadiness(keySaved: true, voiceIDSet: false)
        r.apply(.speechInputBlocked(.microphoneDenied))
        r.apply(.microphone(.granted))
        XCTAssertEqual(r.speechInput, .notChecked)
        let credits = ElevenLabsRejection(kind: .creditsExhausted, httpStatus: 402, code: nil, type: nil, message: "", requestID: nil)
        r.apply(.speechInputFinished(.failure(.rejected(credits)), at: Date()))
        r.apply(.microphone(.granted))
        XCTAssertNotNil(r.speechInput.problem, "other failures are kept")
    }

    func testMicrophoneIsTrackedSeparatelyAndBlocksInputTest() {
        var r = ElevenLabsReadiness(keySaved: true, voiceIDSet: false)
        r.apply(.microphone(.denied))
        XCTAssertEqual(r.microphone, .denied)
        r.apply(.speechInputBlocked(.microphoneDenied))
        XCTAssertEqual(r.speechInput.problem, .microphoneDenied)
        XCTAssertEqual(r.synthesizerStatus, .unconfigured, "no voice ID: speech output stays unconfigured")
    }

    func testFailuresSurfaceInStatusesWithoutClaimingConnection() {
        var r = ElevenLabsReadiness(keySaved: true, voiceIDSet: true)
        let credits = ElevenLabsRejection(kind: .creditsExhausted, httpStatus: 402, code: "insufficient_credits", type: nil,
                                          message: "", requestID: nil)
        r.apply(.speechOutputFinished(.failure(.rejected(credits)), at: Date()))
        XCTAssertEqual(r.synthesizerStatus, .failed("Not enough ElevenLabs credits"))
        XCTAssertEqual(r.summary, "Speech: needs attention")
    }
}

final class LinksAndInputSafetyTests: XCTestCase {
    func testLinksAreOfficialHTTPSAndCarryNoParameters() {
        let allowedHosts: Set<String> = ["elevenlabs.io", "nightshift-board.wybe.me"]
        for url in ProviderLinks.all {
            XCTAssertEqual(url.scheme, "https", url.absoluteString)
            XCTAssertTrue(allowedHosts.contains(url.host ?? ""), url.absoluteString)
            XCTAssertNil(url.query, "links never carry parameters (and never a key)")
        }
        XCTAssertEqual(ProviderLinks.wybeRegistration.absoluteString, "https://nightshift-board.wybe.me/join")
    }

    func testVoiceIDValidationRejectsKeysAndJunk() {
        XCTAssertNil(VoiceIDValidation.problem(with: "JBFqnCBsd6RMkjVDRZzb"))
        XCTAssertNil(VoiceIDValidation.problem(with: ""), "empty means not set")
        XCTAssertNotNil(VoiceIDValidation.problem(with: "sk_0123456789abcdef0123456789abcdef"))
        XCTAssertNotNil(VoiceIDValidation.problem(with: "../v1/user"))
        XCTAssertNotNil(VoiceIDValidation.problem(with: "abc"))
        XCTAssertNotNil(VoiceIDValidation.problem(with: "voice id with spaces"))
    }

    func testKeyPastedIntoVoiceFieldIsNeverSent() async {
        let transport = FakeTransport()
        let secret = "sk_0123456789abcdef0123456789abcdef"
        let client = ElevenLabsClient(configuration: ElevenLabsConfiguration(voiceID: secret), transport: transport,
                                      redactor: Redactor(), apiKey: { "sk_realkeyrealkeyrealkey000000" })
        do {
            _ = try await ElevenLabsSynthesizer(client: client).synthesize(text: "x", languageCode: nil)
            XCTFail("expected invalid voice ID")
        } catch let error as ElevenLabsError {
            guard case .invalidVoiceID = error else { return XCTFail("\(error)") }
            XCTAssertFalse(error.description.contains(secret))
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testModelAndFormatOverridesCannotInjectIntoRequests() async {
        let transport = FakeTransport()
        let client = ElevenLabsClient(configuration: ElevenLabsConfiguration(voiceID: "VoiceABC123",
                                                                             outputFormat: "mp3_44100_128&x=1"),
                                      transport: transport, redactor: Redactor(), apiKey: { "sk_realkeyrealkeyrealkey000000" })
        do { _ = try await ElevenLabsSynthesizer(client: client).synthesize(text: "x", languageCode: nil); XCTFail() }
        catch { XCTAssertEqual((error as? ElevenLabsError)?.rejection?.kind, .modelUnavailable) }
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testSavedModelChoicesSurviveTheNewDefault() throws {
        // Exactly the JSON an earlier build stored in UserDefaults (default model at the time).
        let saved = Data(#"{"baseURL":"https:\/\/api.elevenlabs.io","speechToTextModel":"scribe_v2","textToSpeechModel":"eleven_multilingual_v2","voiceID":"VoiceABC123","outputFormat":"mp3_44100_128"}"#.utf8)
        let restored = try JSONDecoder().decode(ElevenLabsConfiguration.self, from: saved)
        XCTAssertEqual(restored.textToSpeechModel, "eleven_multilingual_v2", "a saved choice is never replaced by the new default")
        XCTAssertEqual(restored.voiceID, "VoiceABC123")
        let roundTrip = try JSONDecoder().decode(ElevenLabsConfiguration.self, from: JSONEncoder().encode(restored))
        XCTAssertEqual(roundTrip, restored)
    }

    func testDefaultsAreTheDocumentedRecommendations() {
        let config = ElevenLabsConfiguration()
        XCTAssertEqual(config.speechToTextModel, "scribe_v2")
        XCTAssertEqual(config.textToSpeechModel, "eleven_flash_v2_5")
        XCTAssertEqual(config.outputFormat, "mp3_44100_128")
        XCTAssertEqual(config.voiceID, "", "no voice is chosen for the user")
        XCTAssertTrue(ModelChoice.speechRecognition.contains { $0.id == config.speechToTextModel })
        XCTAssertTrue(ModelChoice.speechGeneration.contains { $0.id == config.textToSpeechModel })
        XCTAssertTrue(ModelChoice.outputFormats.allSatisfy { $0.id.hasPrefix("mp3_") }, "playback decodes MP3 only")
        XCTAssertEqual(Set(ElevenLabsPermission.allCases.filter(\.required).map(\.rawValue)), ["speech_to_text", "text_to_speech"])
    }
}

final class CapabilityTextTests: XCTestCase {
    func testReasoningStatementIsHonest() {
        XCTAssertEqual(ReasoningCapability.statement,
                       "Relay currently uses built-in rules and keyword matching. ElevenLabs provides speech input/output; it does not supply Relay’s decision-making in this implementation.")
        XCTAssertEqual(ReasoningCapability.languageModel, .notImplemented)
        XCTAssertNotEqual(ReasoningCapability.LanguageModelStatus.notImplemented.label,
                          ReasoningCapability.LanguageModelStatus.notConfigured.label)
    }

    func testWybeChecklistOnlyClaimsWhatOrganisersPublished() async {
        let known = WybeIntegration.requirements.filter { $0.status == .known }.map(\.id)
        XCTAssertEqual(known, ["endpoint", "auth"])
        XCTAssertTrue(WybeIntegration.requirements.contains { $0.id == "mapping" && $0.status == .needsDevelopment })
        XCTAssertTrue(WybeIntegration.requirements.contains { $0.id == "help-format" && $0.status == .unknown })
        XCTAssertTrue(LiveNightShiftAdapter.missingContract(clientAvailable: false, mappingAvailable: false).contains("will not send anything"))
        // Without a key and a reviewed mapping the live adapter still sends nothing.
        do { _ = try await LiveNightShiftAdapter().observe(); XCTFail() }
        catch { guard case ChallengeError.contractUnavailable = error else { return XCTFail("\(error)") } }
    }
}

final class DelayedTransportTests: XCTestCase {
    func testDelaysThenForwardsTheRealRequest() async throws {
        let base = FakeTransport()
        let delayed = DelayedTransport(base: base, seconds: 0.05)
        let start = Date()
        _ = try await delayed.send(URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/user")!))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.04)
        XCTAssertEqual(base.sent.count, 1)
    }

    func testCancellingDuringTheDelaySendsNothing() async {
        let base = FakeTransport()
        let delayed = DelayedTransport(base: base, seconds: 5)
        let task = Task { try await delayed.send(URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/user")!)) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let result = await task.result
        if case .success = result { XCTFail("expected cancellation") }
        XCTAssertTrue(base.sent.isEmpty)
    }
}
