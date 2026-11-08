import XCTest
@testable import RelayCore

final class VoiceSessionTests: XCTestCase {
    func testUnconfiguredSpeechFallsBackToText() {
        var session = VoiceSession()
        XCTAssertFalse(session.canRecord)
        XCTAssertFalse(session.canSpeak)
        XCTAssertTrue(session.textInputAvailable)
        XCTAssertThrowsError(try session.handle(.pressTalk(at: Date())))
        XCTAssertThrowsError(try session.handle(.startSpeaking))
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(SpeechServiceStatus.unconfigured.label, "Not configured — text only")
    }

    func testPushToTalkReviewCycle() throws {
        var session = VoiceSession(transcriberStatus: .configuredUnverified, synthesizerStatus: .connected(verifiedAt: Date()))
        try session.handle(.pressTalk(at: Date()))
        guard case .recording = session.state else { return XCTFail() }
        try session.handle(.releaseTalk)
        XCTAssertEqual(session.state, .transcribing)
        try session.handle(.transcriptReady(text: "next", provider: "p"))
        XCTAssertEqual(session.state, .reviewing(original: "next", provider: "p"))
        try session.handle(.submitReview)
        XCTAssertEqual(session.state, .idle)
        try session.handle(.startSpeaking)
        try session.handle(.stopSpeaking)
        XCTAssertEqual(session.state, .idle)
    }

    func testFailuresAreVisibleAndRecoverable() throws {
        var session = VoiceSession(transcriberStatus: .failed("401"), synthesizerStatus: .unconfigured)
        XCTAssertTrue(session.canRecord, "a failed check still lets the user retry")
        try session.handle(.pressTalk(at: Date()))
        try session.handle(.releaseTalk)
        try session.handle(.transcriptionFailed("ElevenLabs rejected the API key (401)"))
        XCTAssertEqual(session.state, .failed("ElevenLabs rejected the API key (401)"))
        try session.handle(.dismissError)
        XCTAssertEqual(session.state, .idle)
    }

    func testInvalidEventsAreRejected() {
        var session = VoiceSession(transcriberStatus: .configuredUnverified)
        XCTAssertThrowsError(try session.handle(.releaseTalk))
        XCTAssertThrowsError(try session.handle(.transcriptReady(text: "x", provider: "p")))
        XCTAssertNoThrow(try session.handle(.stopSpeaking), "stopping when nothing plays is harmless")
    }
}
