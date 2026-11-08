import XCTest
@testable import TokenLabCore

final class TokenizerTests: XCTestCase {

    // MARK: Approximate counter

    func testApproximateCounterRoundsUpUTF8Bytes() {
        let c = ApproximateCounter(bytesPerToken: 4)
        XCTAssertEqual(c.count(""), 0)
        XCTAssertEqual(c.count("abcd"), 1)
        XCTAssertEqual(c.count("abcde"), 2)
        XCTAssertEqual(c.count("ø"), 1) // 2 bytes
        XCTAssertEqual(ApproximateCounter(bytesPerToken: 1).count("ø"), 2)
        XCTAssertEqual(c.descriptor.kind, .approximation)
        XCTAssertTrue(c.descriptor.scope.contains("Not a model tokenizer"))
    }

    func testApproximateFastPathMatchesJoinedCount() {
        let parts = ["Instructions", "Block with ünïcödé", "x", "last\n"]
        for n in 1...8 {
            let c = ApproximateCounter(bytesPerToken: n)
            XCTAssertEqual(c.countJoined(parts, separator: "\n\n"), c.count(parts.joined(separator: "\n\n")), "bytesPerToken \(n)")
        }
        XCTAssertEqual(ApproximateCounter().countJoined([], separator: "\n\n"), 0)
    }

    func testResolverRequiresLoadedEncoding() {
        let resolver = StaticCounterResolver()
        XCTAssertNoThrow(try resolver.counter(for: .approximate(bytesPerToken: 3)))
        XCTAssertThrowsError(try resolver.counter(for: .bpe(encoding: .o200k_base))) { error in
            XCTAssertEqual(error as? LabError, .counterUnavailable(
                "The o200k_base encoding file is not loaded. Import it in Settings → Token counting, or switch this project to the approximate counter."))
        }
    }

    // MARK: SHA-256

    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256Digest.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Digest.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Digest.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(SHA256Digest.hex(Data(repeating: 0x61, count: 1000)),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    // MARK: BPE with a synthetic vocabulary

    /// Every single byte has rank 1000 + byte, plus a few merges written for this test.
    private func syntheticTokenizer(extra: [String: Int]) throws -> BPETokenizer {
        var ranks: [[UInt8]: Int] = [:]
        for b in 0...255 { ranks[[UInt8(b)]] = 1000 + b }
        for (text, rank) in extra { ranks[Array(text.utf8)] = rank }
        let descriptor = TokenCounterDescriptor(id: "test", displayName: "test", kind: .modelTokenizer, encoding: "test", version: "1", scope: "test")
        return try BPETokenizer(ranks: ranks, pattern: #"\p{White_Space}+|\P{White_Space}+"#, descriptor: descriptor)
    }

    func testMergesLowestRankFirst() throws {
        let t = try syntheticTokenizer(extra: ["ab": 1, "bc": 2, "abc": 3, "cd": 4])
        // ab(1) merges first, then abc(3); "abcd" has no rank, so d stays alone.
        XCTAssertEqual(t.encode("abcd"), [3, 1000 + 100])
        XCTAssertEqual(t.count("abcd"), 2)
    }

    func testTiesMergeLeftmostPair() throws {
        let t = try syntheticTokenizer(extra: ["aa": 5])
        XCTAssertEqual(t.encode("aaa"), [5, 1000 + 97])
    }

    func testWholePieceRankWins() throws {
        let t = try syntheticTokenizer(extra: ["ab": 1, "abcd": 7])
        XCTAssertEqual(t.encode("abcd"), [7])
        XCTAssertEqual(t.encode("abcd abcd"), [7, 1000 + 32, 7])
    }

    func testUnknownBytesFallBackToSingleByteTokens() throws {
        let t = try syntheticTokenizer(extra: [:])
        XCTAssertEqual(t.count("é"), 2)
        XCTAssertEqual(t.count(""), 0)
    }

    func testCountCacheDistinguishesCanonicallyEquivalentText() throws {
        // "é" (1 scalar, 2 bytes) and "e" + combining acute (2 scalars, 3 bytes) are equal as Swift Strings.
        let t = try syntheticTokenizer(extra: [:])
        XCTAssertEqual(t.count("\u{e9}"), 2)
        XCTAssertEqual(t.count("e\u{301}"), 3)
        XCTAssertEqual(t.count("\u{e9}"), 2)
    }

    func testIncompleteVocabularyIsRejected() {
        let descriptor = TokenCounterDescriptor(id: "t", displayName: "t", kind: .modelTokenizer, encoding: "t", version: "1", scope: "t")
        XCTAssertThrowsError(try BPETokenizer(ranks: [[97]: 0], pattern: ".", descriptor: descriptor))
    }

    func testEncodingFileParsing() throws {
        let ranks = try BPETokenizer.parseRanks(Data("YQ== 0\nYg== 1\nYWI= 2\n".utf8))
        XCTAssertEqual(ranks[[97, 98]], 2)
        XCTAssertThrowsError(try BPETokenizer.parseRanks(Data("not-a-line\n".utf8)))
        XCTAssertThrowsError(try BPETokenizer.parseRanks(Data("YQ== 0\nYQ== 1\n".utf8)), "duplicate token")
        XCTAssertThrowsError(try BPETokenizer.parseRanks(Data("YQ== 0\nYg== 0\n".utf8)), "duplicate rank")
        XCTAssertThrowsError(try BPETokenizer.parseRanks(Data()))
    }

    func testUnofficialEncodingFileIsRejectedByHash() {
        XCTAssertThrowsError(try BPETokenizer(spec: BPEEncodingID.o200k_base.spec, fileData: Data("YQ== 0\n".utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("not the official o200k_base"))
        }
    }

    func testPatternsCompileWithPlatformRegex() throws {
        for id in BPEEncodingID.allCases {
            XCTAssertNoThrow(try NSRegularExpression(pattern: id.spec.pattern), id.rawValue)
        }
    }

    // MARK: Official encodings (only when the user has supplied the files)

    /// Looks for official encoding files in $TOKENLAB_ENCODINGS_DIR, then in the app's import folder.
    private func officialTokenizer(_ id: BPEEncodingID) throws -> BPETokenizer {
        var candidates: [URL] = []
        if let dir = ProcessInfo.processInfo.environment["TOKENLAB_ENCODINGS_DIR"] {
            candidates.append(URL(fileURLWithPath: dir).appendingPathComponent(id.spec.fileName))
        }
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(support.appendingPathComponent("TokenLab/Encodings").appendingPathComponent(id.spec.fileName))
        }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("\(id.spec.fileName) not available. Import it in the app or set TOKENLAB_ENCODINGS_DIR to run reference tests.")
        }
        return try BPETokenizer(spec: id.spec, fileData: Data(contentsOf: url))
    }

    func testCl100kMatchesReferenceImplementation() throws {
        let t = try officialTokenizer(.cl100k_base)
        for (i, text) in ReferenceVectors.cases.enumerated() {
            XCTAssertEqual(t.encode(text), ReferenceVectors.cl100k[i], "case \(i): \(text.debugDescription)")
            XCTAssertEqual(t.count(text), ReferenceVectors.cl100k[i].count, "case \(i)")
        }
        XCTAssertEqual(t.descriptor.kind, .modelTokenizer)
        XCTAssertTrue(t.descriptor.version.contains("ranks-sha256=223921b76ee99bde"))
    }

    func testO200kMatchesReferenceImplementation() throws {
        let t = try officialTokenizer(.o200k_base)
        for (i, text) in ReferenceVectors.cases.enumerated() {
            XCTAssertEqual(t.encode(text), ReferenceVectors.o200k[i], "case \(i): \(text.debugDescription)")
            XCTAssertEqual(t.count(text), ReferenceVectors.o200k[i].count, "case \(i)")
        }
        XCTAssertTrue(t.descriptor.scope.contains("not provider-reported usage"))
    }

    func testEngineRecordsTokenizerInReport() throws {
        let t = try officialTokenizer(.o200k_base)
        let sample = SampleProject.make()
        var s = sample.settings; s.counter = .bpe(encoding: .o200k_base)
        let report = try SelectionEngine.run(sample.draft, settings: s, counter: t)
        XCTAssertEqual(report.counter.encoding, "o200k_base")
        XCTAssertEqual(report.selectedTokens, t.count(report.selectedPrompt))
        XCTAssertEqual(report.originalTokens, t.count(report.originalPrompt))
    }
}
