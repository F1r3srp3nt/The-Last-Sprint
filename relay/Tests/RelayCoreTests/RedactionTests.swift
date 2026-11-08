import XCTest
@testable import RelayCore

final class RedactionTests: XCTestCase {
    func testRegisteredSecretIsRemovedEverywhere() {
        let redactor = Redactor()
        redactor.register(secret: "my-very-secret-value-123")
        let out = redactor.redact("key was my-very-secret-value-123 and again my-very-secret-value-123")
        XCTAssertFalse(out.contains("my-very-secret-value-123"))
        XCTAssertEqual(out.components(separatedBy: Redactor.placeholder).count - 1, 2)
    }

    func testCredentialShapedTextIsRemovedWithoutRegistration() {
        let redactor = Redactor()
        let samples = [
            "xi-api-key: abcdef1234567890abcdef",
            "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig",
            "api_key=zzzzzzzzzzzzzzzz&x=1",
            "{\"apiKey\": \"qwertyuiopasdfgh\"}",
            "token=0123456789abcdef",
            "sk_0123456789abcdef0123456789abcdef",
        ]
        let secrets = ["abcdef1234567890abcdef", "eyJhbGciOiJIUzI1NiJ9.payload.sig", "zzzzzzzzzzzzzzzz",
                       "qwertyuiopasdfgh", "0123456789abcdef", "sk_0123456789abcdef0123456789abcdef"]
        for (sample, secret) in zip(samples, secrets) {
            let out = redactor.redact(sample)
            XCTAssertFalse(out.contains(secret), "leaked in: \(out)")
            XCTAssertTrue(out.contains(Redactor.placeholder), "no placeholder in: \(out)")
        }
    }

    func testOrdinaryTextIsUntouched() {
        let redactor = Redactor()
        let text = "Move pallet to zone B, then scan the SSCC label."
        XCTAssertEqual(redactor.redact(text), text)
    }

    func testSensitiveDictionaryKeys() {
        let redactor = Redactor()
        let out = redactor.redact(["xi-api-key": "short", "Authorization": "x", "room": "105"])
        XCTAssertEqual(out["xi-api-key"], Redactor.placeholder)
        XCTAssertEqual(out["Authorization"], Redactor.placeholder)
        XCTAssertEqual(out["room"], "105")
    }

    func testEventLogStoresAndExportsOnlyRedactedText() {
        let redactor = Redactor()
        let log = InMemoryEventLog(redactor: redactor)
        redactor.register(secret: "registered-before-123")
        log.record(.settings, .info, "saved registered-before-123", details: ["api_key": "raw"])
        log.record(.settings, .info, "later-registered-456 appeared")
        redactor.register(secret: "later-registered-456")
        XCTAssertFalse(log.entries().map(\.message).joined().contains("registered-before-123"))
        XCTAssertEqual(log.entries().first?.details["api_key"], Redactor.placeholder)
        let export = log.exportJSONLines()
        XCTAssertFalse(export.contains("later-registered-456"), "export must re-redact")
        XCTAssertFalse(export.contains("registered-before-123"))
    }
}
