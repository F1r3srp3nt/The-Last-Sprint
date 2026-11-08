import XCTest
@testable import TokenLabCore

/// Every proposed block must be an exact, in-order run of the original, and nothing but whitespace-only
/// lines and line breaks between blocks may be missing.
private func assertExactAndComplete(_ blocks: [ProposedBlock], from original: String, file: StaticString = #filePath, line: UInt = #line) {
    var cursor = original.startIndex
    for block in blocks {
        guard let range = original.range(of: block.text, range: cursor..<original.endIndex) else {
            return XCTFail("Block is not an exact substring after the previous block: \(block.text.debugDescription)", file: file, line: line)
        }
        let gap = original[cursor..<range.lowerBound]
        XCTAssertTrue(gap.allSatisfy { $0.isWhitespace }, "Non-whitespace text skipped before block: \(gap.debugDescription)", file: file, line: line)
        cursor = range.upperBound
    }
    XCTAssertTrue(original[cursor...].allSatisfy { $0.isWhitespace }, "Text lost after the last block", file: file, line: line)
}

final class ContextSplitterTests: XCTestCase {

    func testHeadingsStartBlocksAndTextBeforeFirstHeadingIsKept() {
        let text = "Intro line.\n\n# First\nAlpha.\n\nMore alpha.\n\n## Second\nBeta.\n"
        let blocks = ContextSplitter.split(text)
        XCTAssertEqual(blocks.map(\.text), ["Intro line.", "# First\nAlpha.\n\nMore alpha.", "## Second\nBeta."])
        XCTAssertEqual(blocks.map(\.title), ["Intro line.", "First", "Second"])
        assertExactAndComplete(blocks, from: text)
    }

    func testWithoutHeadingsParagraphsBecomeBlocksInOrder() {
        let text = "  First paragraph,\nline two.  \n\n\n\tSecond\twith tabs.\n\nThird."
        let blocks = ContextSplitter.split(text)
        XCTAssertEqual(blocks.map(\.text), ["  First paragraph,\nline two.  ", "\tSecond\twith tabs.", "Third."],
                       "Indentation, tabs and trailing spaces inside blocks are preserved")
        assertExactAndComplete(blocks, from: text)
    }

    func testFencedCodeIsNeverSplitEvenAcrossBlankLines() {
        let code = "```swift\nlet a = 1\n\n\n# not a heading\nlet b = 2\n```"
        let text = "Before.\n\n\(code)\n\nAfter."
        let blocks = ContextSplitter.split(text)
        XCTAssertEqual(blocks.map(\.text), ["Before.", code, "After."])
        XCTAssertEqual(blocks[1].category, .code)
        XCTAssertEqual(blocks[1].title, "Code (swift)")
        assertExactAndComplete(blocks, from: text)
    }

    func testHeadingInsideFenceDoesNotSplitSections() {
        let text = "# Section\n~~~\n# inside code\n~~~\nTail.\n# Next\nX"
        let blocks = ContextSplitter.split(text)
        XCTAssertEqual(blocks.map(\.text), ["# Section\n~~~\n# inside code\n~~~\nTail.", "# Next\nX"])
    }

    func testUnclosedFenceRunsToTheEnd() {
        let text = "Para.\n\n```\ncode\n\nmore code"
        let blocks = ContextSplitter.split(text)
        XCTAssertEqual(blocks.map(\.text), ["Para.", "```\ncode\n\nmore code"])
    }

    func testClosingFenceMustMatchCharacterAndLength() {
        let text = "````\na\n```\nstill code\n````\n\nAfter."
        XCTAssertEqual(ContextSplitter.split(text).map(\.text), ["````\na\n```\nstill code\n````", "After."])
    }

    func testSetextHeadings() {
        let text = "Title\n=====\nBody.\n\nSub\n---\nMore."
        let blocks = ContextSplitter.split(text)
        XCTAssertEqual(blocks.map(\.text), ["Title\n=====\nBody.", "Sub\n---\nMore."])
        XCTAssertEqual(blocks.map(\.title), ["Title", "Sub"])
    }

    func testWindowsLineBreaksArePreservedInsideBlocks() {
        let text = "One\r\nline two\r\n\r\nTwo\r\n"
        let blocks = ContextSplitter.split(text)
        XCTAssertEqual(blocks.map(\.text), ["One\r\nline two", "Two"])
        assertExactAndComplete(blocks, from: text)
    }

    func testEmptyAndWhitespaceOnlyInput() {
        XCTAssertTrue(ContextSplitter.split("").isEmpty)
        XCTAssertTrue(ContextSplitter.split(" \n\t\n").isEmpty)
        XCTAssertTrue(ContextSplitter.keepAsOneBlock("", title: "x").isEmpty)
    }

    func testKeepAsOneBlockIsTheExactOriginal() {
        let text = "\n  # A\n\nbody\t \n"
        let blocks = ContextSplitter.keepAsOneBlock(text, title: "Pasted")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(Array(blocks[0].text.utf8), Array(text.utf8))
        XCTAssertEqual(ContextSplitter.keepAsOneBlock("```\ncode\n```", title: "c")[0].category, .code)
    }

    func testSplittingIsDeterministic() {
        let a = ContextSplitter.split(DemoDataset.pastedNotesText).map { [$0.title, $0.text] }
        let b = ContextSplitter.split(DemoDataset.pastedNotesText).map { [$0.title, $0.text] }
        XCTAssertEqual(a, b)
    }

    func testLongTitlesAreShortenedButTextIsNot() {
        let line = String(repeating: "word ", count: 40)
        let block = ContextSplitter.split(line)[0]
        XCTAssertLessThanOrEqual(block.title.count, 60)
        XCTAssertEqual(block.text, line)
    }
}

final class PastedSourcePersistenceTests: XCTestCase {

    func testPastedOriginalsRoundTripAndBlocksKeepTheirSource() throws {
        let project = DemoDataset.make(.pastedNotes)
        XCTAssertEqual(project.pastedSources.count, 1)
        XCTAssertEqual(project.pastedSources[0].text, DemoDataset.pastedNotesText, "The original is kept exactly")
        XCTAssertTrue(project.draft.blocks.allSatisfy { $0.pastedSourceID == project.pastedSources[0].id })
        let reopened = try ProjectCodec.decode(ProjectCodec.encode(project))
        XCTAssertEqual(reopened, project)
    }

    func testProjectsWithoutPastedOriginalsStillLoad() throws {
        var root = try JSONSerialization.jsonObject(with: ProjectCodec.encode(SampleProject.make())) as! [String: Any]
        root.removeValue(forKey: "pastedSources")
        var draft = root["draft"] as! [String: Any]
        draft["blocks"] = (draft["blocks"] as! [[String: Any]]).map { var b = $0; b.removeValue(forKey: "pastedSourceID"); return b }
        root["draft"] = draft
        let loaded = try ProjectCodec.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertTrue(loaded.pastedSources.isEmpty)
        XCTAssertTrue(loaded.draft.blocks.allSatisfy { $0.pastedSourceID == nil })
    }

    func testDuplicatePastedSourceIDsAreRejected() throws {
        var project = DemoDataset.make(.pastedNotes)
        project.pastedSources.append(project.pastedSources[0])
        XCTAssertThrowsError(try project.validate())
    }
}

final class SelectionOutcomeTests: XCTestCase {
    private func run(_ draft: Draft, _ strategy: SelectionStrategy, budget: Int = 1000, dedupe: Bool = true) throws -> SelectionReport {
        try SelectionEngine.run(draft, settings: SelectionSettings(strategy: strategy, budget: budget, deduplicateBeforeBudget: dedupe,
                                                                  counter: .approximate(bytesPerToken: 1)), counter: bytes1)
    }

    func testEachOutcomeIsReportedAccurately() throws {
        XCTAssertEqual(try run(Draft(task: "T", blocks: [ContextBlock(text: "")]), .budgetSelection).outcome, .noContext)

        let two = Draft(task: "T", blocks: [ContextBlock(text: "aaaa"), ContextBlock(text: "bbbb")])
        XCTAssertEqual(try run(two, .baseline).outcome, .fullContextRetained)
        XCTAssertEqual(try run(two, .budgetSelection).outcome, .nothingRemoved)
        XCTAssertEqual(try run(two, .exactDeduplication).outcome, .nothingRemoved)

        let dup = Draft(task: "T", blocks: [ContextBlock(text: "same"), ContextBlock(text: "same")])
        XCTAssertEqual(try run(dup, .exactDeduplication).outcome, .duplicatesRemoved(count: 1))

        // "aaaa\n\nT" = 7 fits; adding "bbbb" would make 13.
        XCTAssertEqual(try run(two, .budgetSelection, budget: 7).outcome, .excludedForBudget(excluded: 1, duplicates: 0))

        let protected = Draft(task: "A long protected task", blocks: [ContextBlock(text: "x")])
        XCTAssertEqual(try run(protected, .taskRelevance, budget: 3).outcome, .protectedExceedsBudget(overBy: 18, excluded: 1))
    }

    func testUnchangedPromptsAreNeverDescribedAsOptimised() throws {
        let two = Draft(task: "T", blocks: [ContextBlock(text: "aaaa"), ContextBlock(text: "bbbb")])
        for strategy in SelectionStrategy.allCases {
            let report = try run(two, strategy)
            XCTAssertEqual(report.selectedPrompt, report.originalPrompt)
            XCTAssertFalse(report.outcome.removedContext, "\(strategy)")
            XCTAssertFalse(report.outcome.title.lowercased().contains("optimised") && report.outcome != .noContext)
        }
    }

    func testMarkingAnExcludedBlockRequiredKeepsItOnRerun() throws {
        var draft = Draft(task: "T", blocks: [ContextBlock(title: "keep", text: "aaaa"), ContextBlock(title: "lost", text: "bbbbbbbb")])
        XCTAssertEqual(try run(draft, .budgetSelection, budget: 7).decisions[1].kind, .excludedByBudget)
        draft.blocks[1].required = true
        let rerun = try run(draft, .budgetSelection, budget: 7)
        XCTAssertEqual(rerun.decisions[1].kind, .required)
        XCTAssertTrue(bytesContain(rerun.selectedPrompt, "bbbbbbbb"))
        XCTAssertTrue(rerun.overBudget, "Required text is kept even when it no longer fits, and the overflow is reported")
    }
}

final class PastedNotesDemonstrationTests: XCTestCase {
    /// Recorded behaviour of the synthetic demonstration (not benchmark evidence).
    private func kept(budget: Int) throws -> [String: Bool] {
        var project = DemoDataset.make(.pastedNotes)
        project.settings.budget = budget
        let report = try SelectionEngine.run(project.draft, settings: project.settings, counter: ApproximateCounter())
        return Dictionary(report.decisions.map { ($0.title, $0.kept) }, uniquingKeysWith: { $0 || $1 })
    }

    func testDemoSplitsIntoSections() {
        let blocks = DemoDataset.make(.pastedNotes).draft.blocks
        XCTAssertEqual(blocks.map(\.title), ["Upload service notes", "Rate limits", "Error codes", "Current client",
                                             "Meeting notes (week 12)", "Meeting notes (week 12)", "Changelog"])
        XCTAssertTrue(blocks[3].text.contains("let request = makeRequest(data)\n\n    let (body, response)"),
                      "The fenced code keeps its internal blank line and indentation")
    }

    func testUsefulReductionKeepsEveryFactBlock() throws {
        let k = try kept(budget: 230)
        XCTAssertEqual(k["Rate limits"], true)
        XCTAssertEqual(k["Error codes"], true)
        XCTAssertEqual(k["Current client"], true)
        XCTAssertEqual(k["Changelog"], false)
        XCTAssertEqual(k["Meeting notes (week 12)"], false)
    }

    func testTighterBudgetLosesTheErrorCodeRules() throws {
        let k = try kept(budget: 150)
        XCTAssertEqual(k["Error codes"], false, "The block stating that 400 and 413 must never be retried is excluded")
    }
}
