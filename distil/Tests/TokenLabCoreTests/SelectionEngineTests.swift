import XCTest
@testable import TokenLabCore

/// UTF-8 byte-level containment (avoids Swift's canonical-equivalence string comparison).
func bytesContain(_ haystack: String, _ needle: String) -> Bool {
    let h = Array(haystack.utf8), n = Array(needle.utf8)
    guard !n.isEmpty else { return true }
    guard h.count >= n.count else { return false }
    for i in 0...(h.count - n.count) where h[i] == n[0] && Array(h[i..<(i + n.count)]) == n { return true }
    return false
}

func settings(_ strategy: SelectionStrategy, budget: Int = 1000, dedupe: Bool = false, bytesPerToken: Int = 1) -> SelectionSettings {
    SelectionSettings(strategy: strategy, budget: budget, deduplicateBeforeBudget: dedupe, counter: .approximate(bytesPerToken: bytesPerToken))
}

let bytes1 = ApproximateCounter(bytesPerToken: 1)

final class SelectionEngineTests: XCTestCase {

    // MARK: Protected content and budget honesty

    func testProtectedInstructionsAndRequiredCodeAreVerbatimWhenOverBudget() throws {
        let instructions = "Explain this function.\r\nKeep\ttabs, trailing spaces   \nand é/e\u{301} exactly.  "
        let code = "func f() {\n\tlet x = 1   \n    return x // ✓\n}\n"
        let draft = Draft(instructions: instructions, blocks: [
            ContextBlock(title: "Code", text: code, category: .code, required: true),
            ContextBlock(title: "Optional", text: "nice to have", priority: ContextPriority.high)
        ])
        let report = try SelectionEngine.run(draft, settings: settings(.budgetSelection, budget: 1), counter: bytes1)

        XCTAssertEqual(Array(report.selectedPrompt.utf8), Array((instructions + "\n\n" + code).utf8))
        XCTAssertTrue(bytesContain(report.selectedPrompt, code))
        XCTAssertTrue(report.protectedExceedsBudget)
        XCTAssertTrue(report.overBudget)
        XCTAssertEqual(report.overBudgetBy, report.selectedTokens - 1)
        XCTAssertEqual(report.decisions[0].kind, .required)
        XCTAssertEqual(report.decisions[1].kind, .excludedByBudget)
        XCTAssertTrue(report.decisions[1].reason.contains("already exceeds"))
        XCTAssertTrue(report.budgetSummary.contains("not truncated"), report.budgetSummary)
    }

    func testRequiredContentIsVerbatimUnderEveryStrategy() throws {
        let code = "  if a {\n\t\tb()\r\n  }  "
        let draft = Draft(instructions: "Task", blocks: [
            ContextBlock(text: code, required: true), ContextBlock(text: code, required: true), ContextBlock(text: code)
        ])
        for strategy in SelectionStrategy.allCases {
            let report = try SelectionEngine.run(draft, settings: settings(strategy, budget: 1, dedupe: true), counter: bytes1)
            XCTAssertTrue(report.decisions[0].kept && report.decisions[1].kept, "\(strategy)")
            XCTAssertTrue(bytesContain(report.selectedPrompt, "Task\n\n" + code + "\n\n" + code), "\(strategy)")
        }
    }

    func testNonEnforcingStrategiesReportOverflowWithoutClaimingCompliance() throws {
        let draft = Draft(instructions: "Instructions", blocks: [ContextBlock(text: "A long optional block")])
        for strategy in [SelectionStrategy.baseline, .exactDeduplication] {
            let report = try SelectionEngine.run(draft, settings: settings(strategy, budget: 5), counter: bytes1)
            XCTAssertFalse(report.budgetEnforced)
            XCTAssertTrue(report.overBudget)
            XCTAssertEqual(report.overBudgetBy, report.selectedTokens - 5)
            XCTAssertTrue(report.budgetSummary.contains("does not apply the budget"))
            XCTAssertTrue(report.decisions[0].kept)
        }
    }

    func testBudgetIncludesSeparators() throws {
        let draft = Draft(instructions: "X", blocks: [ContextBlock(text: "abcd")])
        // "X\n\nabcd" is 7 bytes.
        XCTAssertFalse(try SelectionEngine.run(draft, settings: settings(.budgetSelection, budget: 6), counter: bytes1).decisions[0].kept)
        let fits = try SelectionEngine.run(draft, settings: settings(.budgetSelection, budget: 7), counter: bytes1)
        XCTAssertTrue(fits.decisions[0].kept)
        XCTAssertEqual(fits.selectedTokens, 7)
        XCTAssertFalse(fits.overBudget)
    }

    // MARK: Strategies

    func testBaselineRetainsEverything() throws {
        let draft = Draft(instructions: "I", blocks: [
            ContextBlock(text: "same", priority: 1), ContextBlock(text: "same", priority: 3), ContextBlock(text: "other")
        ])
        let report = try SelectionEngine.run(draft, settings: settings(.baseline, budget: 1), counter: bytes1)
        XCTAssertEqual(report.selectedPrompt, report.originalPrompt)
        XCTAssertEqual(report.estimatedReduction, 0)
        XCTAssertTrue(report.decisions.allSatisfy { $0.kind == .retained })
    }

    func testExactDeduplicationRemovesOnlyRedundantOptionalContext() throws {
        let required = ContextBlock(title: "Req", text: "shared fact", required: true)
        let draft = Draft(instructions: "Do the task.", blocks: [
            ContextBlock(title: "Low copy", text: "repeat", priority: 1),             // 0: removed, lower priority
            ContextBlock(title: "Optional copy of req", text: "shared fact", priority: 3), // 1: removed, duplicates required
            required,                                                                  // 2: required
            ContextBlock(title: "High copy", text: "repeat", priority: 3),            // 3: kept (highest priority)
            ContextBlock(title: "Same-priority copy", text: "repeat", priority: 3),   // 4: removed, later tie
            ContextBlock(title: "Copy of instructions", text: "Do the task."),        // 5: removed
            ContextBlock(title: "Unique", text: "unique text", priority: 1)           // 6: kept
        ])
        let report = try SelectionEngine.run(draft, settings: settings(.exactDeduplication, budget: 1), counter: bytes1)
        let kinds = report.decisions.map(\.kind)
        XCTAssertEqual(kinds, [.duplicateRemoved, .duplicateRemoved, .required, .retained, .duplicateRemoved, .duplicateRemoved, .retained])
        XCTAssertEqual(report.decisions[0].duplicateOf, draft.blocks[3].id)
        XCTAssertEqual(report.decisions[1].duplicateOf, required.id)
        XCTAssertEqual(report.decisions[4].duplicateOf, draft.blocks[3].id)
        XCTAssertNil(report.decisions[5].duplicateOf)
        XCTAssertTrue(report.decisions[4].reason.contains("earlier"))
        XCTAssertTrue(report.decisions[0].reason.contains("higher priority"))
        XCTAssertTrue(report.decisions[5].reason.contains("instructions"))
        // The budget of 1 is not applied by this strategy.
        XCTAssertEqual(report.selectedPrompt, "Do the task.\n\nshared fact\n\nrepeat\n\nunique text")
    }

    func testDeduplicationIsByteExactNotCanonical() throws {
        let draft = Draft(blocks: [ContextBlock(text: "caf\u{00e9}"), ContextBlock(text: "cafe\u{0301}")])
        let report = try SelectionEngine.run(draft, settings: settings(.exactDeduplication), counter: bytes1)
        XCTAssertEqual(report.keptCount, 2)
    }

    func testBudgetSelectionDeduplicatesOnlyWhenEnabled() throws {
        let draft = Draft(blocks: [ContextBlock(text: "dup"), ContextBlock(text: "dup")])
        let off = try SelectionEngine.run(draft, settings: settings(.budgetSelection, budget: 100, dedupe: false), counter: bytes1)
        XCTAssertEqual(off.keptCount, 2)
        let on = try SelectionEngine.run(draft, settings: settings(.budgetSelection, budget: 100, dedupe: true), counter: bytes1)
        XCTAssertEqual(on.decisions.map(\.kind), [.retained, .duplicateRemoved])
    }

    func testBudgetSelectionUsesPriorityAndPreservesOriginalOrder() throws {
        let draft = Draft(instructions: "I", blocks: [
            ContextBlock(title: "A", text: "aaaa", priority: 1),
            ContextBlock(title: "B", text: "bbbb", priority: 3),
            ContextBlock(title: "C", text: "cccc", priority: 2),
            ContextBlock(title: "D", text: "dddd", priority: 3)
        ])
        // Each block adds 6 bytes (separator + 4). Protected = 1; +B = 7; +D = 13; +C = 19; +A = 25.
        let report = try SelectionEngine.run(draft, settings: settings(.budgetSelection, budget: 19), counter: bytes1)
        XCTAssertEqual(report.decisions.map(\.kept), [false, true, true, true])
        XCTAssertEqual(report.selectedPrompt, "I\n\nbbbb\n\ncccc\n\ndddd")
        XCTAssertEqual(report.selectedTokens, 19)
        XCTAssertTrue(report.decisions[0].reason.contains("over the budget"))
    }

    func testTiesAreBrokenByOriginalOrder() throws {
        let draft = Draft(blocks: [ContextBlock(title: "first", text: "1111"), ContextBlock(title: "second", text: "2222")])
        let report = try SelectionEngine.run(draft, settings: settings(.budgetSelection, budget: 4), counter: bytes1)
        XCTAssertEqual(report.decisions.map(\.kept), [true, false])
    }

    func testGreedySelectionCanKeepSmallerLowerPriorityBlockAndExplainsIt() throws {
        let draft = Draft(instructions: "I", blocks: [
            ContextBlock(title: "Big", text: String(repeating: "x", count: 10), priority: 3),
            ContextBlock(title: "Small", text: "yy", priority: 1)
        ])
        let report = try SelectionEngine.run(draft, settings: settings(.budgetSelection, budget: 6), counter: bytes1)
        XCTAssertEqual(report.decisions.map(\.kind), [.excludedByBudget, .retained])
        XCTAssertTrue(report.decisions[0].reason.contains("13"))
        XCTAssertTrue(report.decisions[1].reason.contains("5 of 6"))
    }

    func testSelectionIsDeterministic() throws {
        let draft = SampleProject.make().draft
        let s = SampleProject.make().settings
        let a = try SelectionEngine.run(draft, settings: s, counter: ApproximateCounter())
        let b = try SelectionEngine.run(draft, settings: s, counter: ApproximateCounter())
        XCTAssertEqual(a, b)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(a), try encoder.encode(b))
    }

    func testEmptyBlocksAreSkippedAndEveryDecisionIsExplained() throws {
        let draft = Draft(instructions: "I", blocks: [ContextBlock(text: ""), ContextBlock(text: "x"), ContextBlock(text: "", required: true)])
        for strategy in SelectionStrategy.allCases {
            let report = try SelectionEngine.run(draft, settings: settings(strategy, dedupe: true), counter: bytes1)
            XCTAssertEqual(report.decisions[0].kind, .emptySkipped)
            XCTAssertEqual(report.decisions[2].kind, .emptySkipped)
            XCTAssertTrue(report.decisions.allSatisfy { !$0.reason.isEmpty })
        }
    }

    func testEmptyWorkspaceHasNoReductionPercent() throws {
        let report = try SelectionEngine.run(Draft(), settings: settings(.budgetSelection), counter: bytes1)
        XCTAssertNil(report.estimatedReductionPercent)
        XCTAssertEqual(report.selectedPrompt, "")
    }

    func testSampleProjectDemonstratesEachOutcome() throws {
        let sample = SampleProject.make()
        XCTAssertNoThrow(try sample.validate())
        let report = try SelectionEngine.run(sample.draft, settings: sample.settings, counter: ApproximateCounter())
        let byTitle = Dictionary(uniqueKeysWithValues: report.decisions.map { ($0.title, $0.kind) })
        XCTAssertEqual(byTitle["Safety rules"], .required)
        XCTAssertEqual(byTitle["Shift helper (code)"], .required)
        XCTAssertEqual(byTitle["Current status"], .retained)
        XCTAssertEqual(byTitle["Status (pasted again)"], .duplicateRemoved)
        XCTAssertEqual(byTitle["Timer log"], .excludedByBudget)
        XCTAssertEqual(byTitle["Volunteer chat"], .retained)
        XCTAssertFalse(report.overBudget)
    }

    // MARK: Validation

    func testInvalidBudgetsAreRejected() {
        let draft = Draft(instructions: "x")
        for budget in [0, -1, 1_000_001] {
            XCTAssertThrowsError(try SelectionEngine.run(draft, settings: settings(.budgetSelection, budget: budget), counter: bytes1), "\(budget)")
            XCTAssertThrowsError(try SelectionEngine.run(draft, settings: settings(.baseline, budget: budget), counter: bytes1), "\(budget)")
        }
        XCTAssertNoThrow(try SelectionEngine.run(draft, settings: settings(.budgetSelection, budget: 1_000_000), counter: bytes1))
    }

    func testInvalidCounterSettingsAreRejected() {
        for n in [0, 9] {
            XCTAssertThrowsError(try SelectionSettings(counter: .approximate(bytesPerToken: n)).validate())
        }
    }

    func testDuplicateIDsAndInvalidPrioritiesAreRejected() {
        let block = ContextBlock(text: "x")
        XCTAssertThrowsError(try SelectionEngine.run(Draft(blocks: [block, block]), settings: settings(.baseline), counter: bytes1))
        for priority in [0, 4] {
            XCTAssertThrowsError(try SelectionEngine.run(Draft(blocks: [ContextBlock(text: "x", priority: priority)]), settings: settings(.baseline), counter: bytes1))
        }
    }

    func testSizeLimitsAreEnforced() {
        let many = Draft(blocks: (0...SelectionEngine.maxBlocks).map { _ in ContextBlock(text: "x") })
        XCTAssertThrowsError(try SelectionEngine.validate(many))
        let huge = Draft(instructions: String(repeating: "a", count: SelectionEngine.maxTextBytes + 1))
        XCTAssertThrowsError(try SelectionEngine.validate(huge))
    }

    // MARK: Stale previews

    func testReportIsStaleAfterAnyRelevantChange() throws {
        let draft = Draft(instructions: "I", blocks: [ContextBlock(text: "abc", priority: 2)])
        let s = settings(.budgetSelection, budget: 100)
        let report = try SelectionEngine.run(draft, settings: s, counter: bytes1)
        XCTAssertTrue(report.isCurrent(draft: draft, settings: s, counter: bytes1.descriptor))

        var changed = draft; changed.instructions += " "
        XCTAssertFalse(report.isCurrent(draft: changed, settings: s, counter: bytes1.descriptor))
        changed = draft; changed.blocks[0].text = "abd"
        XCTAssertFalse(report.isCurrent(draft: changed, settings: s, counter: bytes1.descriptor))
        changed = draft; changed.blocks[0].priority = 3
        XCTAssertFalse(report.isCurrent(draft: changed, settings: s, counter: bytes1.descriptor))
        changed = draft; changed.blocks[0].required = true
        XCTAssertFalse(report.isCurrent(draft: changed, settings: s, counter: bytes1.descriptor))
        changed = draft; changed.blocks.append(ContextBlock())
        XCTAssertFalse(report.isCurrent(draft: changed, settings: s, counter: bytes1.descriptor))
        changed = draft; changed.blocks[0].title = "renamed"
        XCTAssertFalse(report.isCurrent(draft: changed, settings: s, counter: bytes1.descriptor), "Titles appear in decisions, so they invalidate too")

        var other = s; other.budget = 99
        XCTAssertFalse(report.isCurrent(draft: draft, settings: other, counter: bytes1.descriptor))
        other = s; other.strategy = .baseline
        XCTAssertFalse(report.isCurrent(draft: draft, settings: other, counter: bytes1.descriptor))
        other = s; other.deduplicateBeforeBudget = true
        XCTAssertFalse(report.isCurrent(draft: draft, settings: other, counter: bytes1.descriptor))
        XCTAssertFalse(report.isCurrent(draft: draft, settings: s, counter: ApproximateCounter(bytesPerToken: 2).descriptor))
    }
}
