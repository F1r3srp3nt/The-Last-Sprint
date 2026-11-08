import XCTest
@testable import TokenLabCore

private let ranker = KeywordOverlapRanker()

private func relevance(budget: Int = 1000, dedupe: Bool = false) -> SelectionSettings {
    SelectionSettings(strategy: .taskRelevance, budget: budget, deduplicateBeforeBudget: dedupe, counter: .approximate(bytesPerToken: 1))
}

final class RankingTests: XCTestCase {

    func testTermExtraction() {
        XCTAssertEqual(KeywordOverlapRanker.terms(in: "Fix parseDueDate for the 2026-3-07 case!"),
                       ["fix", "parse", "due", "date", "2026", "07", "case"])
        XCTAssertEqual(KeywordOverlapRanker.terms(in: "HTTPServer snake_case_name"), ["httpserver", "snake", "case", "name"])
        XCTAssertEqual(KeywordOverlapRanker.terms(in: "caf\u{e9} cafe\u{301}"), ["café", "café"], "Canonical forms compare equal for ranking only")
        XCTAssertEqual(ranker.taskTerms("date Date DATE dates"), ["date", "dates"], "No stemming: plural is a different term")
        XCTAssertTrue(ranker.taskTerms("What is the and of it?").isEmpty)
    }

    func testRareTermsWeighMoreAndRepetitionDoesNotCount() {
        let a = ContextBlock(text: "invoice invoice invoice invoice")
        let b = ContextBlock(text: "invoice refund")
        let c = ContextBlock(text: "invoice shipping")
        let scores = ranker.scores(task: "refund invoice", blocks: [a, b, c])
        // N = 3; df(invoice) = 3 → weight 1; df(refund) = 1 → weight 1 + ln(4/2).
        XCTAssertEqual(scores[a.id]?.score, 1.0)
        XCTAssertEqual(scores[a.id]?.matchedTerms.first?.occurrences, 4)
        XCTAssertEqual(scores[b.id]?.score ?? 0, KeywordOverlapRanker.round3(2 + log(2.0)), accuracy: 0.0005)
        XCTAssertEqual(scores[b.id]?.matchedTerms.map(\.term), ["refund", "invoice"], "Contributions follow task-term order")
        XCTAssertEqual(scores[c.id]?.score, 1.0)
    }

    func testRankingIsDeterministic() {
        let blocks = DemoDataset.make(.codingTask).draft.blocks
        let task = DemoDataset.make(.codingTask).draft.task
        XCTAssertEqual(ranker.scores(task: task, blocks: blocks), ranker.scores(task: task, blocks: blocks))
    }
}

final class TaskRelevanceSelectionTests: XCTestCase {

    func testRelevanceChoosesButOriginalOrderIsKept() throws {
        let draft = Draft(task: "alpha beta", instructions: "INSTR", blocks: [
            ContextBlock(title: "noise", text: "gamma"),
            ContextBlock(title: "one match", text: "alpha"),
            ContextBlock(title: "two matches", text: "alpha beta")
        ])
        // Protected: "INSTR\n\nalpha beta" = 17 bytes. +two matches (12) = 29. +one match (7) = 36. +noise (7) = 43.
        let report = try SelectionEngine.run(draft, settings: relevance(budget: 36), counter: bytes1)
        XCTAssertEqual(report.decisions.map(\.considerationRank), [3, 2, 1])
        XCTAssertEqual(report.decisions.map(\.kept), [false, true, true])
        XCTAssertEqual(report.selectedPrompt, "INSTR\n\nalpha\n\nalpha beta\n\nalpha beta", "Instructions first, retained blocks in original order, task last")
        XCTAssertEqual(report.selectedTokens, 36, "Budget covers the complete assembled prompt")
        XCTAssertEqual(report.taskTerms, ["alpha", "beta"])
        XCTAssertEqual(report.ranker?.id, "keyword-overlap-idf")
    }

    func testZeroMatchBlocksComeLastButAreKeptWhenTheyFit() throws {
        let draft = Draft(task: "alpha", blocks: [
            ContextBlock(title: "zero, high priority", text: "zzz", priority: 3),
            ContextBlock(title: "match, low priority", text: "alpha", priority: 1)
        ])
        let fits = try SelectionEngine.run(draft, settings: relevance(budget: 100), counter: bytes1)
        XCTAssertEqual(fits.decisions.map(\.considerationRank), [2, 1])
        XCTAssertEqual(fits.decisions.map(\.kept), [true, true], "Zero-match blocks are not removed for scoring 0")
        XCTAssertTrue(fits.decisions[0].reason.contains("no task terms found"))
        XCTAssertTrue(fits.decisions[0].relevance?.isZeroMatch ?? false)

        // "alpha\n\nalpha" = 12; adding "zzz" → 17.
        let tight = try SelectionEngine.run(draft, settings: relevance(budget: 12), counter: bytes1)
        XCTAssertEqual(tight.decisions.map(\.kept), [false, true])
        XCTAssertTrue(tight.decisions[0].reason.contains("not shortened"))
    }

    func testTiesAreBrokenByPriorityThenPromptOrderAndExplained() throws {
        let draft = Draft(task: "alpha", blocks: [
            ContextBlock(title: "A", text: "alpha 1", priority: 2),
            ContextBlock(title: "B", text: "alpha 2", priority: 3),
            ContextBlock(title: "C", text: "alpha 3", priority: 2)
        ])
        let report = try SelectionEngine.run(draft, settings: relevance(), counter: bytes1)
        XCTAssertEqual(report.decisions.map(\.considerationRank), [2, 1, 3])
        XCTAssertTrue(report.decisions.allSatisfy { $0.reason.contains("tied with 2 other blocks") })
    }

    func testRequiredBlocksAlwaysRemainEvenWithZeroRelevanceAndOverflow() throws {
        let code = "func f() {\n\treturn 1   \r\n}"
        let draft = Draft(task: "alpha", instructions: "Keep   spacing.\n", blocks: [
            ContextBlock(title: "Required code", text: code, category: .code, required: true),
            ContextBlock(title: "Relevant", text: "alpha")
        ])
        let report = try SelectionEngine.run(draft, settings: relevance(budget: 1), counter: bytes1)
        XCTAssertEqual(report.decisions[0].kind, .required)
        XCTAssertTrue(report.decisions[0].relevance?.isZeroMatch ?? false, "Relevance is still reported for required blocks")
        XCTAssertEqual(report.decisions[1].kind, .excludedByBudget)
        XCTAssertEqual(Array(report.selectedPrompt.utf8), Array(("Keep   spacing.\n" + "\n\n" + code + "\n\n" + "alpha").utf8))
        XCTAssertTrue(report.protectedExceedsBudget)
        XCTAssertTrue(report.budgetSummary.contains("not truncated"))
    }

    func testTaskIsProtectedUnderEveryStrategy() throws {
        let task = "Explain\tthis   exactly.\r\n"
        let draft = Draft(task: task, blocks: [ContextBlock(text: "context")])
        for strategy in SelectionStrategy.allCases {
            var s = relevance(budget: 1); s.strategy = strategy
            let report = try SelectionEngine.run(draft, settings: s, counter: bytes1)
            XCTAssertTrue(Array(report.selectedPrompt.utf8).suffix(task.utf8.count).elementsEqual(task.utf8), "\(strategy)")
        }
    }

    func testDeduplicationAlsoRemovesCopiesOfTheTask() throws {
        let draft = Draft(task: "Same words", blocks: [ContextBlock(text: "Same words")])
        let report = try SelectionEngine.run(draft, settings: relevance(dedupe: true), counter: bytes1)
        XCTAssertEqual(report.decisions[0].kind, .duplicateRemoved)
        XCTAssertTrue(report.decisions[0].reason.contains("task"))
    }

    func testEmptyTaskFallsBackToPriorityOrderAndSaysSo() throws {
        let draft = Draft(blocks: [ContextBlock(text: "low", priority: 1), ContextBlock(text: "high", priority: 3)])
        let report = try SelectionEngine.run(draft, settings: relevance(), counter: bytes1)
        XCTAssertEqual(report.decisions.map(\.considerationRank), [2, 1])
        XCTAssertNotNil(report.relevanceNote)
    }

    func testRankerIsReplaceable() throws {
        struct ReverseRanker: RelevanceRanker {
            var descriptor: RankerDescriptor { RankerDescriptor(id: "reverse", displayName: "Reverse", version: "1", method: "test", limitations: []) }
            func taskTerms(_ task: String) -> [String] { ["x"] }
            func scores(task: String, blocks: [ContextBlock]) -> [UUID: RelevanceScore] {
                Dictionary(uniqueKeysWithValues: blocks.enumerated().map {
                    ($0.element.id, RelevanceScore(score: Double($0.offset), matchedTerms: [TermContribution(term: "x", weight: 1, occurrences: 1)]))
                })
            }
        }
        let draft = Draft(task: "t", blocks: [ContextBlock(text: "aaaa"), ContextBlock(text: "bbbb")])
        // "bbbb\n\nt" = 7 bytes fits; adding "aaaa" would make 13.
        let report = try SelectionEngine.run(draft, settings: relevance(budget: 7), counter: bytes1, ranker: ReverseRanker())
        XCTAssertEqual(report.decisions.map(\.kept), [false, true])
        XCTAssertEqual(report.ranker?.id, "reverse")
    }

    func testPriorityStrategyIgnoresRelevance() throws {
        let draft = Draft(task: "alpha", blocks: [ContextBlock(text: "alpha", priority: 1), ContextBlock(text: "zzzzz", priority: 3)])
        var s = relevance(budget: 5); s.strategy = .budgetSelection
        let report = try SelectionEngine.run(draft, settings: s, counter: bytes1)
        XCTAssertEqual(report.decisions.map(\.kept), [false, false], "Neither fits beside the 5-byte task")
        XCTAssertNil(report.decisions[0].relevance)
        XCTAssertNil(report.ranker)
    }
}

final class StaleResultTests: XCTestCase {

    func testOlderCalculationCannotReplaceNewerOne() {
        var gate = LatestResultGate()
        let first = gate.begin()
        let second = gate.begin()
        XCTAssertFalse(gate.isLatest(first), "A slow, older result must be discarded")
        XCTAssertTrue(gate.isLatest(second))
        gate.invalidate()
        XCTAssertFalse(gate.isLatest(second), "Editing inputs makes in-flight results stale")
    }

    func testEngineStopsWhenCancelled() {
        let draft = Draft(task: "a", blocks: [ContextBlock(text: "a"), ContextBlock(text: "b")])
        XCTAssertThrowsError(try SelectionEngine.run(draft, settings: relevance(), counter: bytes1, isCancelled: { true })) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertThrowsError(try Comparison.run(draft, base: relevance(), counter: bytes1, isCancelled: { true }))
    }

    func testTaskEditsMakePreviewsStale() throws {
        let draft = Draft(task: "one", blocks: [ContextBlock(text: "x")])
        let report = try SelectionEngine.run(draft, settings: relevance(), counter: bytes1)
        var edited = draft; edited.task = "one "
        XCTAssertTrue(report.isCurrent(draft: draft, settings: relevance(), counter: bytes1.descriptor))
        XCTAssertFalse(report.isCurrent(draft: edited, settings: relevance(), counter: bytes1.descriptor))
    }
}

final class ComparisonTests: XCTestCase {

    func testFourVariantsShareInputsAndDifferOnlyInStrategy() throws {
        let project = DemoDataset.make(.codingTask)
        let entries = try Comparison.run(project.draft, base: project.settings, counter: ApproximateCounter())
        XCTAssertEqual(entries.map(\.variant), ComparisonVariant.allCases)
        XCTAssertEqual(entries.map(\.report.settings.strategy), [.baseline, .exactDeduplication, .budgetSelection, .taskRelevance])
        for entry in entries {
            XCTAssertEqual(entry.report.input, project.draft)
            XCTAssertEqual(entry.report.settings.budget, project.settings.budget)
            XCTAssertEqual(entry.report.counter, ApproximateCounter().descriptor)
            XCTAssertEqual(entry.report.originalTokens, entries[0].report.originalTokens)
        }
        XCTAssertEqual(entries[0].report.selectedPrompt, entries[0].report.originalPrompt)
        XCTAssertTrue(Comparison.isCurrent(entries, draft: project.draft, base: project.settings, counter: ApproximateCounter().descriptor))
        var edited = project.draft; edited.blocks[0].priority = 3
        XCTAssertFalse(Comparison.isCurrent(entries, draft: edited, base: project.settings, counter: ApproximateCounter().descriptor))
    }

    func testSavedComparisonIsReproducibleAndKeepsReviews() throws {
        var project = DemoDataset.make(.paraphrasedTask)
        let entries = try Comparison.run(project.draft, base: project.settings, counter: ApproximateCounter())
        let experiments = Comparison.experiments(from: entries, groupName: "Run 1", template: project.reviewTemplate)
        XCTAssertEqual(Set(experiments.compactMap { $0.comparison?.groupID }).count, 1)
        XCTAssertTrue(experiments.allSatisfy { !$0.evaluation.isEvaluated })
        XCTAssertEqual(experiments[0].evaluation.expectedFacts.map(\.text), project.reviewTemplate.expectedFacts)
        XCTAssertTrue(experiments[0].evaluation.expectedFacts.allSatisfy { $0.selectedContext == .notChecked })

        project.experiments = experiments
        project.experiments[3].evaluation.selectedContextRun.responseText = "Answer"
        project.experiments[3].evaluation.correctnessChecks[0].selectedContext = .fail
        project.experiments[3].evaluation.reviewerNotes = "Newsletter was treated as a cause."
        try project.experiments[3].evaluation.setVerdict(.unusable)

        let saved = project.experiments
        project.draft.task = "A different task"
        project.draft.blocks.removeAll()
        XCTAssertEqual(project.experiments, saved, "Later edits never change saved snapshots")

        let reopened = try ProjectCodec.decode(ProjectCodec.encode(project))
        XCTAssertEqual(reopened.experiments, saved)
        for experiment in reopened.experiments {
            XCTAssertEqual(ReproductionCheck.run(experiment, resolver: StaticCounterResolver()), .identical)
        }
    }

    func testMislabelledComparisonVariantIsRejected() throws {
        let project = DemoDataset.make(.codingTask)
        let entries = try Comparison.run(project.draft, base: project.settings, counter: ApproximateCounter())
        var experiments = Comparison.experiments(from: entries, groupName: "g", template: ReviewTemplate())
        experiments[0].comparison?.variant = .relevanceBudget
        XCTAssertThrowsError(try experiments[0].validate())
    }
}

final class SchemaThreeMigrationTests: XCTestCase {

    /// Build a schema 2 file from a current project by removing everything schema 3 added.
    private func schemaTwoData(from project: ProjectDocument) throws -> Data {
        var root = try JSONSerialization.jsonObject(with: ProjectCodec.encode(project)) as! [String: Any]
        root["schemaVersion"] = 2
        root.removeValue(forKey: "notes"); root.removeValue(forKey: "reviewTemplate")
        var draft = root["draft"] as! [String: Any]; draft.removeValue(forKey: "task"); root["draft"] = draft
        root["experiments"] = (root["experiments"] as! [[String: Any]]).map { experiment -> [String: Any] in
            var experiment = experiment
            experiment.removeValue(forKey: "comparison")
            var snapshot = experiment["snapshot"] as! [String: Any]
            var input = snapshot["input"] as! [String: Any]; input.removeValue(forKey: "task"); snapshot["input"] = input
            for key in ["taskTokens", "instructionsTokens", "ranker", "taskTerms", "relevanceNote"] { snapshot.removeValue(forKey: key) }
            snapshot["engineVersion"] = "selection-engine-2"
            snapshot["decisions"] = (snapshot["decisions"] as! [[String: Any]]).map { decision -> [String: Any] in
                var decision = decision
                decision.removeValue(forKey: "relevance"); decision.removeValue(forKey: "considerationRank")
                return decision
            }
            experiment["snapshot"] = snapshot
            return experiment
        }
        return try JSONSerialization.data(withJSONObject: root)
    }

    func testSchemaTwoFilesMigrateWithoutGuessingATask() throws {
        // A schema 2 project kept the request inside the instructions.
        var project = try sampleWithExperiment()
        project.draft.instructions = "Write the handover note. Use only the supplied facts."
        project.draft.task = ""
        project.experiments[0].snapshot = try SelectionEngine.run(project.draft, settings: project.settings, counter: ApproximateCounter())
        project.reviewTemplate = ReviewTemplate(); project.notes = ""

        let loaded = try ProjectCodec.load(schemaTwoData(from: project))
        XCTAssertTrue(loaded.wasMigrated)
        XCTAssertEqual(loaded.sourceSchemaVersion, 2)
        let doc = loaded.document
        XCTAssertEqual(doc.schemaVersion, 3)
        XCTAssertEqual(doc.draft.task, "")
        XCTAssertEqual(doc.draft.instructions, "Write the handover note. Use only the supplied facts.")
        XCTAssertEqual(doc.draft.blocks, project.draft.blocks)
        XCTAssertEqual(doc.library, project.library)

        let migrated = doc.experiments[0]
        XCTAssertEqual(migrated.snapshot.input.task, "")
        XCTAssertEqual(migrated.snapshot.selectedPrompt, project.experiments[0].snapshot.selectedPrompt)
        XCTAssertEqual(migrated.snapshot.engineVersion, "selection-engine-2", "The recorded engine version is preserved")
        XCTAssertEqual(migrated.evaluation, project.experiments[0].evaluation, "Answers, checks, notes and verdict are preserved")
        guard case .differs(let reasons) = ReproductionCheck.run(migrated, resolver: StaticCounterResolver()) else { return XCTFail() }
        XCTAssertEqual(reasons.count, 1, "Only the engine version differs: \(reasons)")
    }
}

final class DemoDatasetTests: XCTestCase {
    private func run(_ id: DemoDataset.ID, _ strategy: SelectionStrategy, mutate: (inout ProjectDocument) -> Void = { _ in }) throws -> [String: Bool] {
        var project = DemoDataset.make(id); mutate(&project)
        var s = project.settings; s.strategy = strategy
        let report = try SelectionEngine.run(project.draft, settings: s, counter: ApproximateCounter(bytesPerToken: 4))
        return Dictionary(uniqueKeysWithValues: report.decisions.map { ($0.title, $0.kept) })
    }

    func testDemosAreValidAndLabelled() throws {
        for id in DemoDataset.ID.allCases {
            let project = DemoDataset.make(id)
            XCTAssertNoThrow(try project.validate(), id.rawValue)
            XCTAssertTrue(project.notes.contains("not benchmark evidence"))
            XCTAssertFalse(project.draft.task.isEmpty)
            XCTAssertFalse(project.reviewTemplate.expectedFacts.isEmpty)
        }
    }

    /// Recorded behaviour, favourable or not. If these change, update the demo descriptions too.
    func testCodingDemoOutcomesAreMixed() throws {
        let priority = try run(.codingTask, .budgetSelection)
        XCTAssertEqual(priority["Release checklist"], true, "High manual priority keeps an unrelated checklist")
        XCTAssertEqual(priority["Bug discussion"], false)
        let relevant = try run(.codingTask, .taskRelevance)
        XCTAssertEqual(relevant["Bug discussion"], true)
        XCTAssertEqual(relevant["Date parser source"], true)
        XCTAssertEqual(relevant["Parser requirements"], false, "Relevance drops the block that states three of the four expected facts")
        XCTAssertEqual(relevant["Release checklist"], false)
        XCTAssertEqual(relevant["Bug discussion (pasted again)"], false)
    }

    func testRequiredConstraintDemo() throws {
        for strategy in SelectionStrategy.allCases {
            XCTAssertEqual(try run(.requiredConstraint, strategy)["Approval rule"], true, "\(strategy)")
        }
        let optional = try run(.requiredConstraint, .taskRelevance) { $0.draft.blocks[0].required = false; $0.settings.budget = 110 }
        XCTAssertEqual(optional["Approval rule"], false)
        XCTAssertEqual(optional["Carrier notice"], true, "An unrelated zero-match block fills the space instead")
    }

    func testParaphrasedDemoExposesKeywordWeakness() throws {
        let relevant = try run(.paraphrasedTask, .taskRelevance)
        XCTAssertEqual(relevant["Newsletter"], true)
        XCTAssertEqual(relevant["Exit interviews"], false)
        XCTAssertEqual(relevant["Survey summary"], false)
        let priority = try run(.paraphrasedTask, .budgetSelection)
        XCTAssertEqual(priority["Exit interviews"], true)
        XCTAssertEqual(priority["Survey summary"], true)
    }
}

final class ReviewTemplateTests: XCTestCase {
    func testTemplateBecomesUncheckedItems() {
        let evaluation = Evaluation(template: ReviewTemplate(expectedFacts: ["a", "b"], correctnessChecks: ["c"]))
        XCTAssertEqual(evaluation.expectedFacts.map(\.text), ["a", "b"])
        XCTAssertEqual(evaluation.correctnessChecks.map(\.text), ["c"])
        XCTAssertEqual(evaluation.verdict, .notEvaluated)
        XCTAssertNotEqual(evaluation.expectedFacts[0].id, Evaluation(template: ReviewTemplate(expectedFacts: ["a"])).expectedFacts[0].id)
    }
}
