import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RelayAdapters
@testable import RelayCore

// All tests use a scripted transport. Nothing here talks to the real Wybe service, and every key
// is a fake that only has the documented "ns_" prefix.

/// Scripted HTTP transport: each request gets the next scripted reply.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    enum Reply {
        case status(Int, String, headers: [String: String] = [:])
        case hang
        case fail(Error)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var requests: [URLRequest] = []
    /// Called after the request is recorded and before the reply is produced.
    var onSend: (@Sendable (URLRequest) -> Void)?

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply = {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            return replies.isEmpty ? .status(500, "no scripted reply") : replies.removeFirst()
        }()
        onSend?(request)
        switch reply {
        case let .status(code, body, headers):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (Data(body.utf8), response)
        case .hang:
            try await Task.sleep(nanoseconds: 30_000_000_000)
            throw CancellationError()
        case let .fail(error):
            throw error
        }
    }

    var sent: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

let fakeTeamKey = "ns_FAKEtestKEY0123456789abcd"
let greetingBody = #"{"ok":true,"result":"Hotel Wybe night shift terminal. Speak JSON. Most things start with help."}"#

func wybeClient(_ transport: ScriptedTransport, key: String? = fakeTeamKey, limits: WybeLimits = WybeLimits(minRequestInterval: 0),
                clock: RelayClock = ManualClock(), redactor: Redactor = Redactor()) -> WybeClient {
    WybeClient(transport: transport, limits: limits, clock: clock, redactor: redactor, teamKey: { key })
}

let validHelp = WybeHelpRequest(method: .post, path: "/", body: #"{"note":"help"}"#,
                                source: "test fixture (not the real form)")

// MARK: - Credentials: event code versus team key

final class WybeCredentialTests: XCTestCase {
    func testEventCodeAndTeamKeyAreExplainedAsSeparateCredentials() {
        let text = WybeIntegration.credentialsExplained.joined(separator: " ")
        XCTAssertTrue(text.contains("event code"))
        XCTAssertTrue(text.contains("registration page"))
        XCTAssertTrue(text.contains("separate credential"))
        XCTAssertTrue(text.contains("Authorization: Bearer"))
        XCTAssertEqual(ProviderLinks.wybeRegistration.absoluteString, WybeIntegration.registrationPage)
    }

    func testTeamKeyValidationRejectsEventCodesAndPastingMistakes() {
        XCTAssertNil(WybeTeamKeyValidation.problem(with: fakeTeamKey))
        XCTAssertNil(WybeTeamKeyValidation.problem(with: "  \(fakeTeamKey)\n"), "surrounding whitespace is trimmed")
        let eventCodeLike = WybeTeamKeyValidation.problem(with: "OSLO2026")
        XCTAssertNotNil(eventCodeLike)
        XCTAssertTrue(eventCodeLike!.contains("event code"), "an event code is explained, not accepted")
        XCTAssertNotNil(WybeTeamKeyValidation.problem(with: "Bearer \(fakeTeamKey)"))
        XCTAssertNotNil(WybeTeamKeyValidation.problem(with: "ns_abc def"))
        XCTAssertNotNil(WybeTeamKeyValidation.problem(with: "ns_short"))
        XCTAssertNotNil(WybeTeamKeyValidation.problem(with: ""))
        for problem in [eventCodeLike, WybeTeamKeyValidation.problem(with: "ns_abc def")].compactMap({ $0 }) {
            XCTAssertFalse(problem.contains("OSLO2026") || problem.contains("abc def"), "the rejected text is never echoed")
        }
    }

    func testDisplayNeverShowsAnyCharacterOfTheKey() {
        let shown = WybeTeamKeyValidation.display(fakeTeamKey)
        XCTAssertFalse(shown.contains(String(fakeTeamKey.dropFirst(3).prefix(4))))
        XCTAssertFalse(shown.contains(String(fakeTeamKey.suffix(4))))
        XCTAssertEqual(WybeTeamKeyValidation.display(nil), "Not set")
    }

    func testWybeKeyHasItsOwnKeychainEntrySeparateFromElevenLabs() throws {
        XCTAssertNotEqual(CredentialService.wybe, CredentialService.relay)
        XCTAssertNotEqual(CredentialAccount.wybeTeamKey, CredentialAccount.elevenLabsAPIKey)
        let wybeStore = InMemoryCredentialStore()
        let speechStore = InMemoryCredentialStore()
        try CredentialAccess.save(fakeTeamKey, account: CredentialAccount.wybeTeamKey, to: wybeStore, redactor: Redactor())
        try CredentialAccess.save("sk_speechkey0123456789abcdef", account: CredentialAccount.elevenLabsAPIKey, to: speechStore,
                                  redactor: Redactor())
        try wybeStore.delete(CredentialAccount.wybeTeamKey)
        XCTAssertNil(try wybeStore.read(CredentialAccount.wybeTeamKey))
        XCTAssertNotNil(try speechStore.read(CredentialAccount.elevenLabsAPIKey), "removing the Wybe key leaves ElevenLabs alone")
    }
}

// MARK: - Client: request form, authentication errors, malformed answers

final class WybeClientTests: XCTestCase {
    func testConnectionCheckIsOneAuthenticatedGetOfTheOfficialEndpoint() async throws {
        let transport = ScriptedTransport([.status(200, greetingBody)])
        let result = await wybeClient(transport).checkConnection()
        let report = try result.get()
        XCTAssertTrue(report.matchesAnonymousGreeting)
        XCTAssertTrue(report.detail.contains("does not prove the key is accepted"),
                      "an answer identical to the anonymous one is not presented as proof")

        XCTAssertEqual(transport.sent.count, 1)
        let request = try XCTUnwrap(transport.sent.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://nightshift.wybe.me/")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(fakeTeamKey)")
        XCTAssertNil(request.httpBody)
        XCTAssertFalse(request.url!.absoluteString.contains(fakeTeamKey), "the key is never in the URL")
    }

    func testRequestURLsStayOnTheEndpoint() throws {
        let client = wybeClient(ScriptedTransport([]))
        XCTAssertEqual(try client.build(.root).url?.absoluteString, "https://nightshift.wybe.me/")
        XCTAssertEqual(try client.build(WybeRequest(method: .get, path: "/a/b-c_d.e")).url?.absoluteString,
                       "https://nightshift.wybe.me/a/b-c_d.e")
    }

    func testMissingKeySendsNothing() async {
        let transport = ScriptedTransport([])
        let result = await wybeClient(transport, key: nil).checkConnection()
        XCTAssertEqual(result.failure, .missingKey)
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testAuthenticationErrorsAreClassifiedWithoutGuessingTheCause() async {
        let refused = await wybeClient(ScriptedTransport([.status(401, #"{"ok":false,"result":"unknown key"}"#)])).checkConnection()
        XCTAssertEqual(refused.failure, .keyRefused(detail: "unknown key"))
        let refusedProblem = WybeProblem(refused.failure!)
        XCTAssertTrue(refusedProblem.nextStep.contains("event code"), "says the event code is not the key")

        let forbidden = await wybeClient(ScriptedTransport([.status(403, "")])).checkConnection()
        XCTAssertEqual(forbidden.failure, .forbidden(detail: nil))
        XCTAssertTrue(WybeProblem(forbidden.failure!).title.contains("cause is not stated"))
    }

    func testMalformedAnswersAreNeverTreatedAsSuccess() async {
        let cases: [(String, String)] = [
            ("<html>Bad gateway</html>", "not JSON"),
            (#"{"result":"no ok field"}"#, "without a boolean"),
            (#"{"ok":"true","result":"ok is a string"}"#, "without a boolean"),
            (#"["ok", true]"#, "without a boolean"),
            ("", "not JSON"),
        ]
        for (body, expected) in cases {
            let result = await wybeClient(ScriptedTransport([.status(200, body)])).checkConnection()
            guard case let .malformed(why)? = result.failure else { return XCTFail("\(body): \(result)") }
            XCTAssertTrue(why.contains(expected), "\(body): \(why)")
        }
        let notOK = await wybeClient(ScriptedTransport([.status(200, #"{"ok":false,"result":"say help first"}"#)])).checkConnection()
        XCTAssertEqual(notOK.failure, .notOK(detail: "say help first"))
    }

    func testOversizedAnswersAreNotRead() async {
        let big = #"{"ok":true,"result":""# + String(repeating: "x", count: 2_000) + #""}"#
        let limits = WybeLimits(maxResponseBytes: 1_000, minRequestInterval: 0)
        let result = await wybeClient(ScriptedTransport([.status(200, big)]), limits: limits).checkConnection()
        XCTAssertEqual(result.failure, .responseTooLarge(limit: 1_000))
    }

    func testServerAndUnexpectedStatuses() async {
        let server = await wybeClient(ScriptedTransport([.status(503, "down")])).checkConnection()
        XCTAssertEqual(server.failure, .serverError(status: 503, detail: "down"))
        let odd = await wybeClient(ScriptedTransport([.status(404, #"{"ok":false,"result":"no such thing"}"#)])).checkConnection()
        XCTAssertEqual(odd.failure, .unexpectedStatus(status: 404, detail: "no such thing"))
    }

    func testRequestsCannotLeaveTheEndpointHost() async {
        let transport = ScriptedTransport([])
        let client = wybeClient(transport)
        for path in ["//evil.example/help", "/../help", "/help?key=1", "help", "/a#b"] {
            do { _ = try await client.send(WybeRequest(method: .get, path: path)); XCTFail(path) }
            catch { guard case WybeFailure.invalidRequest = error else { return XCTFail("\(path): \(error)") } }
        }
        do { _ = try await client.send(WybeRequest(method: .post, path: "/", body: Data("{\"k\":\"\(fakeTeamKey)\"}".utf8))); XCTFail() }
        catch { guard case WybeFailure.invalidRequest = error else { return XCTFail("\(error)") } }
        XCTAssertTrue(transport.sent.isEmpty)
    }
}

// MARK: - Bounded requests: timeouts, cancellation, rate limiting

final class WybeBoundsTests: XCTestCase {
    func testTimeoutIsBoundedAndReportedAsUnknownOutcome() async {
        let transport = ScriptedTransport([.hang])
        let limits = WybeLimits(timeout: 0.05, minRequestInterval: 0)
        let start = Date()
        let result = await wybeClient(transport, limits: limits).checkConnection()
        XCTAssertEqual(result.failure, .timedOut(seconds: 0.05))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertTrue(WybeProblem(result.failure!).nextStep.contains("cannot tell whether the request reached"))
        XCTAssertEqual(transport.sent.count, 1, "the client never retries by itself")
    }

    func testCancellationStopsAPendingCheck() async {
        let transport = ScriptedTransport([.hang])
        let client = wybeClient(transport, limits: WybeLimits(timeout: 20, minRequestInterval: 0))
        let task = Task { await client.checkConnection() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.failure, .cancelled)
    }

    func testCancelledBeforeSendingSendsNothing() async {
        let transport = ScriptedTransport([.status(200, greetingBody)])
        let client = wybeClient(transport)
        let task = Task { () -> Result<WybeConnectionReport, WybeFailure> in
            withUnsafeCurrentTask { $0?.cancel() }
            return await client.checkConnection()
        }
        let result = await task.value
        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testMinimumIntervalBetweenRequests() async {
        let clock = ManualClock()
        let transport = ScriptedTransport([.status(200, greetingBody), .status(200, greetingBody)])
        let client = wybeClient(transport, limits: WybeLimits(minRequestInterval: 1.0), clock: clock)
        _ = await client.checkConnection()
        _ = await client.checkConnection()
        XCTAssertEqual(clock.sleeps, [1.0], "the second request waited one second")
    }

    func testRateLimitPausesFurtherRequests() async {
        let clock = ManualClock()
        let transport = ScriptedTransport([.status(429, #"{"ok":false,"result":"slow down"}"#, headers: ["Retry-After": "7"]),
                                           .status(200, greetingBody)])
        let client = wybeClient(transport, limits: WybeLimits(minRequestInterval: 0), clock: clock)
        let limited = await client.checkConnection()
        XCTAssertEqual(limited.failure, .rateLimited(retryAfter: 7, detail: "slow down"))
        _ = await client.checkConnection()
        XCTAssertEqual(clock.sleeps.first ?? 0, 7, accuracy: 0.001)
    }
}

// MARK: - Discovery through the help mechanism

final class WybeDiscoveryTests: XCTestCase {
    func testNoHelpRequestFormIsBuiltIn() {
        XCTAssertNil(WybeProtocolMappings.reviewed, "no command mapping is invented")
        XCTAssertTrue(WybeIntegration.requirements.contains { $0.id == "help-format" && $0.status == .unknown })
    }

    func testHelpRequestValidation() {
        XCTAssertNil(validHelp.problem())
        XCTAssertNil(WybeHelpRequest(method: .get, path: "/help", body: "", source: "seen in answer").problem())
        let bad: [WybeHelpRequest] = [
            WybeHelpRequest(method: .post, path: "/", body: #"{"note":"status"}"#, source: "x"),          // no help
            WybeHelpRequest(method: .post, path: "/", body: #"{"cmd":"start shift","then":"help"}"#, source: "x"), // could start
            WybeHelpRequest(method: .post, path: "/", body: "{help}", source: "x"),                        // not JSON
            WybeHelpRequest(method: .get, path: "/help", body: "{}", source: "x"),                         // GET with body
            WybeHelpRequest(method: .get, path: "https://evil.example/help", body: "", source: "x"),       // absolute
            WybeHelpRequest(method: .get, path: "//evil.example/help", body: "", source: "x"),
            WybeHelpRequest(method: .get, path: "/help?x=1", body: "", source: "x"),
            WybeHelpRequest(method: .get, path: "/../help", body: "", source: "x"),
            WybeHelpRequest(method: .post, path: "/", body: "{\"help\":\"\(fakeTeamKey)\"}", source: "x"), // key in body
            WybeHelpRequest(method: .post, path: "/", body: #"{"note":"help"}"#, source: " "),             // no provenance
        ]
        for request in bad { XCTAssertNotNil(request.problem(), "\(request)") }
        XCTAssertFalse(WybeHelpRequest(method: .post, path: "/", body: "{\"help\":\"\(fakeTeamKey)\"}", source: "x")
            .problem()!.contains(fakeTeamKey))
    }

    func testDiscoverySendsExactlyTheRecordedRequestOnce() async throws {
        let transport = ScriptedTransport([.status(200, #"{"ok":true,"result":"commands: (as the service lists them)"}"#)])
        let transcript = try await wybeClient(transport).discover(with: validHelp).get()
        XCTAssertEqual(transcript.answer, "commands: (as the service lists them)")
        XCTAssertEqual(transport.sent.count, 1)
        let request = try XCTUnwrap(transport.sent.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://nightshift.wybe.me/")
        XCTAssertEqual(String(decoding: request.httpBody ?? Data(), as: UTF8.self), #"{"note":"help"}"#)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(fakeTeamKey)")
    }

    func testInvalidHelpRequestIsNeverSent() async {
        let transport = ScriptedTransport([])
        let result = await wybeClient(transport).discover(with: WybeHelpRequest(method: .post, path: "/", body: #"{"x":"start"}"#, source: "x"))
        guard case .invalidRequest? = result.failure else { return XCTFail("\(result)") }
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testStructuredHelpAnswersAreShownVerbatimNotInterpreted() async throws {
        let transport = ScriptedTransport([.status(200, #"{"ok":true,"result":{"b":[1,2],"a":"x"}}"#)])
        let transcript = try await wybeClient(transport).discover(with: validHelp).get()
        XCTAssertTrue(transcript.answer.contains("\"a\" : \"x\""))
        XCTAssertTrue(transcript.answer.contains("\"b\""))
    }
}

// MARK: - Readiness: four separate facts, stale results rejected

final class WybeReadinessTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let report = WybeConnectionReport(httpStatus: 200, resultText: WybeIntegration.anonymousGreeting)
    let transcript = WybeHelpTranscript(request: "POST /", httpStatus: 200, answer: "help text")

    func fresh(key: Bool = true, help: Bool = true) -> WybeReadiness {
        WybeReadiness(keySaved: key, helpRequestRecorded: help, reviewedMappingAvailable: false)
    }

    func testSavingAKeyVerifiesNothing() {
        var r = fresh(key: false)
        r.apply(.keySaved)
        XCTAssertTrue(r.keySaved)
        XCTAssertFalse(r.connectionVerified)
        XCTAssertFalse(r.protocolDiscovered)
        XCTAssertFalse(r.liveRunnerReady)
        XCTAssertEqual(r.stages.map(\.state), [.done, .notYet, .notYet, .notYet])
        XCTAssertEqual(r.stages.map(\.title), ["Key saved", "Connection verified", "Protocol discovered", "Live runner ready"])
    }

    func testReplacingTheKeyResetsEarlierChecks() {
        var r = fresh()
        let token = r.beginConnectionCheck()!
        r.apply(.connectionFinished(generation: token, .success(report), at: now))
        XCTAssertTrue(r.connectionVerified)
        r.apply(.keySaved)
        XCTAssertFalse(r.connectionVerified, "a new key has not been checked")
        r.apply(.keyRemoved)
        XCTAssertFalse(r.keySaved)
        XCTAssertNil(r.beginConnectionCheck(), "nothing to check without a key")
    }

    func testStaleConnectionResultAfterKeyChangeIsIgnored() {
        var r = fresh()
        let token = r.beginConnectionCheck()!
        r.apply(.keySaved) // replaced while pending
        XCTAssertFalse(r.apply(.connectionFinished(generation: token, .success(report), at: now)))
        XCTAssertEqual(r.connection, .notChecked)
        XCTAssertFalse(r.connectionVerified)
        // A failure from the old key doesn't mark the new key as refused either.
        let next = r.beginConnectionCheck()!
        r.apply(.keySaved)
        XCTAssertFalse(r.apply(.connectionFinished(generation: next, .failure(.keyRefused(detail: nil)), at: now)))
        XCTAssertEqual(r.connection, .notChecked)
    }

    func testStaleDiscoveryResultAfterHelpRequestChangeIsIgnored() {
        var r = fresh()
        let c = r.beginConnectionCheck()!
        r.apply(.connectionFinished(generation: c, .success(report), at: now))
        let d = r.beginDiscovery()!
        r.apply(.helpRequestChanged(recorded: true))
        XCTAssertFalse(r.apply(.discoveryFinished(generation: d, .success(transcript), at: now)))
        XCTAssertFalse(r.protocolDiscovered)
        XCTAssertTrue(r.connectionVerified, "changing the help request does not change the key")
    }

    func testDiscoveryNeedsAVerifiedConnectionAndARecordedHelpRequest() {
        var r = fresh(help: false)
        XCTAssertNil(r.beginDiscovery())
        r.apply(.helpRequestChanged(recorded: true))
        XCTAssertNil(r.beginDiscovery(), "connection not verified yet")
        let c = r.beginConnectionCheck()!
        XCTAssertNil(r.beginDiscovery(), "not while a check is running")
        r.apply(.connectionFinished(generation: c, .failure(.keyRefused(detail: nil)), at: now))
        XCTAssertNil(r.beginDiscovery())
        XCTAssertTrue(r.stages[1].state == .attention)
    }

    func testLiveRunnerIsNeverReadyWithoutAReviewedMapping() {
        var r = fresh()
        let c = r.beginConnectionCheck()!
        r.apply(.connectionFinished(generation: c, .success(report), at: now))
        let d = r.beginDiscovery()!
        r.apply(.discoveryFinished(generation: d, .success(transcript), at: now))
        XCTAssertTrue(r.protocolDiscovered)
        XCTAssertFalse(r.liveRunnerReady)
        XCTAssertTrue(r.liveRunnerBlocker!.contains("No reviewed command mapping"))
        XCTAssertEqual(r.stages.map(\.state), [.done, .done, .done, .notYet])
    }

    func testCancelledChecksReturnToNotChecked() {
        var r = fresh()
        let c = r.beginConnectionCheck()!
        r.apply(.connectionFinished(generation: c, .failure(.cancelled), at: now))
        XCTAssertEqual(r.connection, .notChecked)
        _ = r.beginConnectionCheck()
        r.apply(.checkCancelled)
        XCTAssertEqual(r.connection, .notChecked)
    }

    func testRefusedKeyDuringDiscoveryAlsoInvalidatesTheConnection() {
        var r = fresh()
        let c = r.beginConnectionCheck()!
        r.apply(.connectionFinished(generation: c, .success(report), at: now))
        let d = r.beginDiscovery()!
        r.apply(.discoveryFinished(generation: d, .failure(.keyRefused(detail: nil)), at: now))
        XCTAssertFalse(r.connectionVerified)
    }
}

// MARK: - Secret redaction

final class WybeRedactionTests: XCTestCase {
    func testKeyEchoedByTheServiceIsRedactedEverywhere() async {
        let redactor = Redactor()
        let echo = "{\"ok\":false,\"result\":\"key \(fakeTeamKey) is unknown\"}"
        let result = await wybeClient(ScriptedTransport([.status(401, echo)]), redactor: redactor).checkConnection()
        let failure = result.failure!
        let problem = WybeProblem(failure)
        for text in [failure.description, problem.title, problem.nextStep, problem.serviceDetail ?? ""] {
            XCTAssertFalse(text.contains(fakeTeamKey), text)
        }
        XCTAssertTrue((problem.serviceDetail ?? "").contains(Redactor.placeholder))
    }

    func testKeyInAHelpAnswerIsRedacted() async throws {
        let redactor = Redactor()
        let body = "{\"ok\":true,\"result\":\"team key \(fakeTeamKey) ok\"}"
        let transcript = try await wybeClient(ScriptedTransport([.status(200, body)]), redactor: redactor).discover(with: validHelp).get()
        XCTAssertFalse(transcript.answer.contains(fakeTeamKey))
        XCTAssertFalse(transcript.request.contains(fakeTeamKey))
    }

    func testUnregisteredTeamKeysAndBearerHeadersAreRedactedInLogsAndExports() {
        let redactor = Redactor()
        let log = InMemoryEventLog(redactor: redactor)
        log.record(.wybe, .failed, "pasted \(fakeTeamKey) by mistake", mode: .live,
                   details: ["Authorization": "Bearer \(fakeTeamKey)", "team_key": fakeTeamKey, "room": "105"])
        let export = log.exportJSONLines()
        XCTAssertFalse(export.contains(fakeTeamKey))
        XCTAssertTrue(export.contains("105"))
        XCTAssertEqual(redactor.redact("Authorization: Bearer \(fakeTeamKey)"), "Authorization: Bearer \(Redactor.placeholder)")
    }

    func testNetworkErrorTextIsRedacted() async {
        let redactor = Redactor()
        let transport = ScriptedTransport([.fail(TransportError.network("lost while sending Bearer \(fakeTeamKey)"))])
        let result = await wybeClient(transport, redactor: redactor).checkConnection()
        guard case let .network(message)? = result.failure else { return XCTFail("\(result)") }
        XCTAssertFalse(message.contains(fakeTeamKey))
    }
}

// MARK: - Live adapter

/// Test-only mapping with an obviously fake "test." vocabulary. It is NOT the Wybe protocol.
struct FakeMapping: WybeProtocolMapping {
    var provenance = "unit-test fixture"
    var supportsStatusQuery = false
    var capabilitiesRequest = WybeRequest(method: .get, path: "/test-capabilities")
    var observeRequest = WybeRequest(method: .get, path: "/test-observe")
    var scoreRequest: WybeRequest? = WybeRequest(method: .get, path: "/test-score")
    var commandNames = ["test.deliver"]

    func capabilities(from response: WybeResponse) throws -> [ActionSpec] {
        commandNames.map { ActionSpec(name: $0, summary: "fake", arguments: ["task"], consequential: true,
                                      preconditions: [.argumentPresent("task")]) }
    }

    func observation(from response: WybeResponse) throws -> Observation {
        guard response.text == "one task" else { throw ChallengeError.transient("unexpected observation") }
        return Observation(time: 0, shiftEndsAt: 10, robotLocation: "lobby", carrying: [],
                           tasks: [ChallengeTask(id: "t1", kind: "test", summary: "fake", item: nil, pickupLocation: nil,
                                                 destination: "lobby", deadline: nil, priority: nil, status: .open)],
                           locationFlags: [:], isShiftOver: false)
    }

    func request(for action: ActionRequest) throws -> WybeRequest {
        WybeRequest(method: .post, path: "/test-act", body: Data(#"{"fake":true}"#.utf8))
    }

    func outcome(from response: WybeResponse, for action: ActionRequest) throws -> ActionOutcome {
        ActionOutcome(accepted: true, message: response.text)
    }

    func statusRequest(for idempotencyKey: String) -> WybeRequest? { nil }
    func status(from response: WybeResponse) throws -> ActionStatusAnswer { .unknown }
    func score(from response: WybeResponse) throws -> Double? { Double(response.text) }
}

/// Acts once on the first open task with the first usable command, then finishes.
struct OneShotPolicy: ShiftPolicy {
    func decide(observation: Observation, usable: [String: ActionSpec], excludedTasks: Set<String>) -> PolicyDecision {
        guard let task = observation.openTasks.first(where: { !excludedTasks.contains($0.id) }),
              let name = usable.keys.sorted().first else { return .finish(reason: "nothing to do") }
        return .act(name: name, arguments: ["task": task.id], taskID: task.id, rationale: "test")
    }

    func reconcile(_ request: ActionRequest, before: Observation, after: Observation) -> ReconcileVerdict { .unknown }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func clear() { lock.lock(); value = false; lock.unlock() }
}

final class LiveNightShiftAdapterTests: XCTestCase {
    func ok(_ text: String) -> ScriptedTransport.Reply { .status(200, "{\"ok\":true,\"result\":\"\(text)\"}") }

    func run(_ adapter: LiveNightShiftAdapter, allowed: Set<String> = ["test.deliver"]) async -> RunReport {
        var config = RunnerConfiguration(expectedMode: .live, allowedActions: allowed, maxActions: 5, actionTimeout: 5,
                                         readTimeout: 5, retry: RetryPolicy(maxAttempts: 3, baseDelay: 0, multiplier: 1, maxDelay: 0),
                                         minRequestInterval: 0, maxConsecutiveFailures: 3)
        config.maxFailuresPerTask = 1
        return await AutonomousRunner(adapter: adapter, policy: OneShotPolicy(), configuration: config, clock: ManualClock(),
                                      log: InMemoryEventLog(redactor: Redactor()), stop: StopSignal()).run()
    }

    func sentPaths(_ transport: ScriptedTransport) -> [String] { transport.sent.map { $0.url?.path ?? "" } }

    func testWithoutKeyOrMappingNothingIsSentAndNoScoreIsReported() async {
        for adapter in [LiveNightShiftAdapter(),
                        LiveNightShiftAdapter(client: wybeClient(ScriptedTransport([])), mapping: nil)] {
            let report = await run(adapter)
            XCTAssertEqual(report.mode, .live)
            XCTAssertTrue(report.actions.isEmpty)
            XCTAssertNil(report.score)
            XCTAssertTrue(report.stopReason.contains("Contract unavailable"), report.stopReason)
        }
        XCTAssertTrue(LiveNightShiftAdapter.missingContract(clientAvailable: true, mappingAvailable: false)
            .contains("no reviewed mapping"))
    }

    func testAmbiguousTimeoutOnAConsequentialActionIsNotRepeated() async {
        let transport = ScriptedTransport([ok("caps"), ok("one task"), .hang, ok("one task"), ok("one task"), ok("12")])
        let client = wybeClient(transport, limits: WybeLimits(timeout: 0.05, minRequestInterval: 0))
        let report = await run(LiveNightShiftAdapter(client: client, mapping: FakeMapping()))
        XCTAssertEqual(sentPaths(transport).filter { $0 == "/test-act" }.count, 1, "sent once, never repeated")
        XCTAssertEqual(report.actions.first?.status, .ambiguousUnresolved)
        XCTAssertEqual(report.setAsideTasks["t1"], "outcome of test.deliver unknown; not repeated")
        XCTAssertEqual(report.score?.mode, .live)
        XCTAssertEqual(report.score?.displayText, "12 (LIVE — reported by Wybe Night Shift service)")
    }

    func testRateLimitOnAnActionIsTreatedAsUnknownOutcome() async {
        let transport = ScriptedTransport([ok("caps"), ok("one task"), .status(429, #"{"ok":false,"result":"slow"}"#),
                                           ok("one task"), ok("one task")])
        let report = await run(LiveNightShiftAdapter(client: wybeClient(transport), mapping: FakeMapping()))
        XCTAssertEqual(sentPaths(transport).filter { $0 == "/test-act" }.count, 1)
        XCTAssertEqual(report.actions.first?.status, .ambiguousUnresolved)
    }

    func testRefusedKeyDuringARunStopsIt() async {
        let transport = ScriptedTransport([ok("caps"), .status(401, #"{"ok":false,"result":"bad key"}"#), ok("one task")])
        let report = await run(LiveNightShiftAdapter(client: wybeClient(transport), mapping: FakeMapping()))
        XCTAssertTrue(report.actions.isEmpty)
        XCTAssertTrue(report.stopReason.contains("key was refused"), report.stopReason)
        XCTAssertFalse(sentPaths(transport).contains("/test-act"))
    }

    func testStaleResponseAfterSettingsChangeIsDiscarded() async {
        let current = Flag()
        let transport = ScriptedTransport([ok("caps"), ok("one task"), ok("done"), ok("one task")])
        transport.onSend = { request in if request.url?.path == "/test-act" { current.clear() } }
        let adapter = LiveNightShiftAdapter(client: wybeClient(transport), mapping: FakeMapping(), isCurrent: { current.isSet })
        let report = await run(adapter)
        XCTAssertEqual(report.actions.first?.status, .ambiguousUnresolved,
                       "an answer that arrives after the key changed is not trusted as success")
        XCTAssertEqual(sentPaths(transport).filter { $0 == "/test-act" }.count, 1)
        XCTAssertTrue(report.stopReason.contains("settings changed"), report.stopReason)
    }

    func testCancellationDuringAnActionIsNotRepeated() async {
        let transport = ScriptedTransport([ok("caps"), ok("one task"), .hang])
        let client = wybeClient(transport, limits: WybeLimits(timeout: 20, minRequestInterval: 0))
        let adapter = LiveNightShiftAdapter(client: client, mapping: FakeMapping())
        let task = Task { await run(adapter) }
        while !sentPaths(transport).contains("/test-act") { try? await Task.sleep(nanoseconds: 5_000_000) }
        task.cancel()
        let report = await task.value
        XCTAssertEqual(sentPaths(transport).filter { $0 == "/test-act" }.count, 1)
        XCTAssertEqual(report.actions.first?.status, .ambiguousUnresolved)
    }

    func testServiceDecliningAnActionIsRecordedAsRejected() async {
        let transport = ScriptedTransport([ok("caps"), ok("one task"), .status(200, #"{"ok":false,"result":"not allowed now"}"#),
                                           ok("one task")])
        let report = await run(LiveNightShiftAdapter(client: wybeClient(transport), mapping: FakeMapping()))
        XCTAssertEqual(report.actions.first?.status, .rejectedByEnvironment)
        XCTAssertEqual(report.actions.first?.message, "not allowed now")
    }

    func testMalformedObservationIsRetriedAsARead() async {
        let transport = ScriptedTransport([ok("caps"), .status(200, "garbage"), ok("one task"), ok("done"), ok("one task")])
        let report = await run(LiveNightShiftAdapter(client: wybeClient(transport), mapping: FakeMapping()))
        XCTAssertEqual(report.actions.first?.status, .succeeded)
        XCTAssertEqual(sentPaths(transport).filter { $0 == "/test-observe" }.count >= 2, true)
    }

    func testSimulatorVocabularyNeverReachesTheLiveService() async {
        var mapping = FakeMapping()
        mapping.commandNames = ["sim.deliver"]
        let transport = ScriptedTransport([ok("caps")])
        let report = await run(LiveNightShiftAdapter(client: wybeClient(transport), mapping: mapping), allowed: ["sim.deliver"])
        XCTAssertTrue(report.actions.isEmpty)
        XCTAssertTrue(report.stopReason.contains("simulator commands"), report.stopReason)

        let adapter = LiveNightShiftAdapter(client: wybeClient(ScriptedTransport([])), mapping: FakeMapping())
        do { _ = try await adapter.perform(ActionRequest(name: "sim.move", arguments: [:])); XCTFail() }
        catch { guard case ChallengeError.rejected = error else { return XCTFail("\(error)") } }
    }
}
