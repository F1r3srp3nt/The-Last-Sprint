import XCTest
@testable import TokenLabCore

/// An evaluation with both answers, judged checks and a verdict, built through the public editing API.
private func reviewedEvaluation(fullPrompt: String = "FULL", selectedPrompt: String = "SELECTED") throws -> Evaluation {
    var evaluation = Evaluation(template: ReviewTemplate(expectedFacts: ["Fact A"], correctnessChecks: ["No invented dates"]))
    evaluation.setAnswer("Full answer", for: .fullContext, prompt: fullPrompt, at: Date(timeIntervalSinceReferenceDate: 1_000))
    evaluation.setAnswer("Selected answer", for: .selectedContext, prompt: selectedPrompt, at: Date(timeIntervalSinceReferenceDate: 2_000))
    for check in evaluation.expectedFacts + evaluation.correctnessChecks {
        evaluation.setCheckResult(id: check.id, slot: .fullContext, .pass)
        evaluation.setCheckResult(id: check.id, slot: .selectedContext, .fail)
    }
    evaluation.reviewer = "Reviewer A"
    evaluation.reviewerNotes = "Selected answer invents a date."
    try evaluation.setVerdict(.degraded, at: Date(timeIntervalSinceReferenceDate: 3_000))
    return evaluation
}

private func allResults(_ e: Evaluation, _ slot: AnswerSlot) -> [CheckResult] {
    (e.expectedFacts + e.correctnessChecks).map { slot == .fullContext ? $0.fullContext : $0.selectedContext }
}

final class ReviewInvalidationTests: XCTestCase {

    func testEditingAnAnswerClearsVerdictAndOnlyThatAnswersChecks() throws {
        var e = try reviewedEvaluation()
        e.setAnswer("Selected answer, revised", for: .selectedContext, prompt: "SELECTED")
        XCTAssertEqual(e.verdict, .notEvaluated)
        XCTAssertNil(e.evaluatedAt)
        XCTAssertEqual(allResults(e, .selectedContext), [.notChecked, .notChecked])
        XCTAssertEqual(allResults(e, .fullContext), [.pass, .pass], "The other answer's checks are preserved")
        XCTAssertEqual(e.reviewerNotes, "Selected answer invents a date.", "Notes are preserved")
        XCTAssertEqual(e.reviewer, "Reviewer A")

        var f = try reviewedEvaluation()
        f.setAnswer("Full answer, revised", for: .fullContext, prompt: "FULL")
        XCTAssertEqual(f.verdict, .notEvaluated)
        XCTAssertEqual(allResults(f, .fullContext), [.notChecked, .notChecked])
        XCTAssertEqual(allResults(f, .selectedContext), [.fail, .fail])
    }

    func testClearingAnAnswerInvalidatesAndRemovesProvenance() throws {
        var e = try reviewedEvaluation()
        e.setAnswer("", for: .selectedContext, prompt: "SELECTED")
        XCTAssertEqual(e.verdict, .notEvaluated)
        XCTAssertNil(e.selectedContextRun.provenance)
        XCTAssertEqual(allResults(e, .selectedContext), [.notChecked, .notChecked])
        XCTAssertNoThrow(try e.validate())
    }

    func testUnchangedTextKeepsTheReview() throws {
        var e = try reviewedEvaluation()
        e.setAnswer("Selected answer", for: .selectedContext, prompt: "SELECTED")
        XCTAssertEqual(e.verdict, .degraded)
    }

    func testCriterionWordingResetsBothAnswersForThatCriterionOnly() throws {
        var e = try reviewedEvaluation()
        let fact = e.expectedFacts[0].id
        e.setCheckText(id: fact, "Fact A, reworded")
        XCTAssertEqual(e.verdict, .notEvaluated)
        XCTAssertEqual(e.expectedFacts[0].fullContext, .notChecked)
        XCTAssertEqual(e.expectedFacts[0].selectedContext, .notChecked)
        XCTAssertEqual(e.correctnessChecks[0].fullContext, .pass, "Other criteria keep their results")
        XCTAssertEqual(e.correctnessChecks[0].selectedContext, .fail)
    }

    func testCheckResultChangesClearVerdictButNotesDoNot() throws {
        var e = try reviewedEvaluation()
        e.reviewerNotes += " Second thought."
        e.reviewer = "Reviewer B"
        XCTAssertEqual(e.verdict, .degraded, "Editing notes or reviewer alone preserves the verdict")

        e.setCheckResult(id: e.correctnessChecks[0].id, slot: .selectedContext, .fail) // same value
        XCTAssertEqual(e.verdict, .degraded, "Re-selecting the same result is not a change")

        e.setCheckResult(id: e.correctnessChecks[0].id, slot: .selectedContext, .pass)
        XCTAssertEqual(e.verdict, .notEvaluated)
    }

    func testAddingOrRemovingCriteriaClearsVerdict() throws {
        var e = try reviewedEvaluation()
        e.addCheck(to: .expectedFacts, text: "Fact B")
        XCTAssertEqual(e.verdict, .notEvaluated)

        var f = try reviewedEvaluation()
        f.removeCheck(id: f.expectedFacts[0].id)
        XCTAssertEqual(f.verdict, .notEvaluated)
        f.removeCheck(id: UUID())
        XCTAssertEqual(f.verdict, .notEvaluated)
    }

    func testUsageEditsDoNotChangeTheReview() throws {
        var e = try reviewedEvaluation()
        e.setUsage(ProviderUsage(provider: "P", model: "M", inputTokens: 10), for: .selectedContext)
        XCTAssertEqual(e.verdict, .degraded)
        XCTAssertEqual(e.selectedContextRun.usage.inputTokens, 10)
    }

    func testEquivalentRequiresBothAnswers() throws {
        var e = Evaluation()
        e.setAnswer("Selected only", for: .selectedContext, prompt: "S")
        XCTAssertThrowsError(try e.setVerdict(.equivalent))
        XCTAssertNoThrow(try e.setVerdict(.acceptableWithLosses))
        e.setAnswer("Full", for: .fullContext, prompt: "F")
        XCTAssertNoThrow(try e.setVerdict(.equivalent))
    }

    func testHistoricalEquivalentWithoutReferenceStillLoads() throws {
        var project = try sampleWithExperiment()
        project.experiments[0].evaluation.fullContextRun = ModelRun()   // legacy state, set directly
        project.experiments[0].evaluation.verdict = .equivalent
        let reopened = try ProjectCodec.decode(ProjectCodec.encode(project))
        XCTAssertTrue(reopened.experiments[0].evaluation.equivalenceLacksReference)
        XCTAssertTrue(reopened.experiments[0].evaluation.statusLabel.contains("without a full-context answer"))
    }
}

final class AnswerProvenanceTests: XCTestCase {

    func testManualEntryRecordsSourcePromptAndTimestamp() {
        var e = Evaluation()
        e.setAnswer("Answer", for: .selectedContext, prompt: "The saved prompt", at: Date(timeIntervalSinceReferenceDate: 500.7))
        let provenance = try! XCTUnwrap(e.selectedContextRun.provenance)
        XCTAssertEqual(provenance.source, .manualEntry)
        XCTAssertEqual(provenance.promptRole, .selectedContext)
        XCTAssertTrue(provenance.matches(prompt: "The saved prompt"))
        XCTAssertFalse(provenance.matches(prompt: "The saved prompt "), "Association is byte-exact")
        XCTAssertEqual(provenance.lastEditedAt, Date(timeIntervalSinceReferenceDate: 500))
        XCTAssertTrue(AnswerProvenance.caveat.contains("does not prove"))

        e.setAnswer("Answer, edited", for: .selectedContext, prompt: "The saved prompt", at: Date(timeIntervalSinceReferenceDate: 900))
        XCTAssertEqual(e.selectedContextRun.provenance?.lastEditedAt, Date(timeIntervalSinceReferenceDate: 900))
    }

    func testLegacyAnswersLoadWithoutInventedProvenance() throws {
        // A project saved before provenance existed: answers present, no provenance keys.
        var project = try sampleWithExperiment()
        project.experiments[0].evaluation.fullContextRun.provenance = nil
        project.experiments[0].evaluation.selectedContextRun.provenance = nil
        var root = try JSONSerialization.jsonObject(with: ProjectCodec.encode(project)) as! [String: Any]
        var experiments = root["experiments"] as! [[String: Any]]
        var evaluation = experiments[0]["evaluation"] as! [String: Any]
        for key in ["fullContextRun", "selectedContextRun"] {
            var run = evaluation[key] as! [String: Any]
            XCTAssertNil(run["provenance"])
            run.removeValue(forKey: "provenance")
            evaluation[key] = run
        }
        experiments[0]["evaluation"] = evaluation; root["experiments"] = experiments
        let loaded = try ProjectCodec.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertNil(loaded.experiments[0].evaluation.selectedContextRun.provenance)
        XCTAssertEqual(loaded.experiments[0].evaluation.selectedContextRun.responseText, "Selected answer.")
        XCTAssertEqual(loaded.experiments[0].evaluation.verdict, .degraded, "Loading does not clear older reviews")
    }

    func testProvenanceRoundTrips() throws {
        var project = try sampleWithExperiment()
        let prompt = project.experiments[0].snapshot.selectedPrompt
        project.experiments[0].evaluation.setAnswer("New answer", for: .selectedContext, prompt: prompt, at: Date(timeIntervalSinceReferenceDate: 42))
        let reopened = try ProjectCodec.decode(ProjectCodec.encode(project))
        XCTAssertEqual(reopened, project)
        XCTAssertTrue(reopened.experiments[0].evaluation.selectedContextRun.provenance?.matches(prompt: prompt) ?? false)
    }
}

final class ReferenceSharingTests: XCTestCase {

    /// Four linked experiments from one comparison, plus one unrelated experiment.
    private func linkedProject() throws -> ProjectDocument {
        var project = DemoDataset.make(.paraphrasedTask)
        let entries = try Comparison.run(project.draft, base: project.settings, counter: ApproximateCounter())
        project.experiments = Comparison.experiments(from: entries, groupName: "G", template: project.reviewTemplate)
        let other = try Comparison.run(project.draft, base: project.settings, counter: ApproximateCounter())
        project.experiments.append(Comparison.experiments(from: other, groupName: "Other", template: ReviewTemplate())[0])
        let prompt = project.experiments[0].snapshot.originalPrompt
        project.experiments[0].evaluation.setAnswer("Reference answer", for: .fullContext, prompt: prompt)
        project.experiments[0].evaluation.setUsage(ProviderUsage(provider: "P", model: "M", inputTokens: 300), for: .fullContext)
        return project
    }

    func testCopiesOnlyIntoBlankReferencesInTheSameGroup() throws {
        var project = try linkedProject()
        // Destination 1: candidate answer already present (reference blank) → receives the reference.
        project.experiments[1].evaluation.setAnswer("Candidate", for: .selectedContext, prompt: project.experiments[1].snapshot.selectedPrompt)
        // Destination 2: only usage entered for the reference → partially populated, must be skipped.
        project.experiments[2].evaluation.setUsage(ProviderUsage(provider: "P"), for: .fullContext)
        let sourceID = project.experiments[0].id

        let (updated, outcome) = ReferenceSharing.share(from: sourceID, in: project.experiments)
        XCTAssertEqual(outcome.copied, 2)                                  // experiments 1 and 3
        XCTAssertEqual(outcome.skipped[.destinationNotBlank], 1)          // experiment 2
        XCTAssertTrue(outcome.summary.contains("Candidate answers, checks and verdicts were not copied"))

        let reference = updated[1].evaluation.fullContextRun
        XCTAssertEqual(reference.responseText, "Reference answer")
        XCTAssertEqual(reference.usage.inputTokens, 300)
        XCTAssertEqual(reference.provenance?.copiedFromExperimentID, sourceID)
        XCTAssertEqual(reference.provenance?.source, .manualEntry, "The copied reference keeps its provenance")
        XCTAssertEqual(updated[1].evaluation.selectedContextRun.responseText, "Candidate", "Candidate preserved")
        XCTAssertEqual(updated[2].evaluation.fullContextRun.usage.provider, "P", "Partial record not overwritten")
        XCTAssertEqual(updated[2].evaluation.fullContextRun.responseText, "")
        XCTAssertTrue(updated[4].evaluation.fullContextRun.isBlank, "Other comparison groups are untouched")
        XCTAssertEqual(updated[0], project.experiments[0], "Source unchanged")
    }

    func testNeverCopiesIntoCandidatesOrTransfersReviews() throws {
        var project = try linkedProject()
        let selectedPrompt = project.experiments[0].snapshot.selectedPrompt
        project.experiments[0].evaluation.setAnswer("Source candidate", for: .selectedContext, prompt: selectedPrompt)
        let check = project.experiments[0].evaluation.expectedFacts[0].id
        project.experiments[0].evaluation.setCheckResult(id: check, slot: .fullContext, .pass)
        try project.experiments[0].evaluation.setVerdict(.equivalent)

        let (updated, _) = ReferenceSharing.share(from: project.experiments[0].id, in: project.experiments)
        let destination = updated[1].evaluation
        XCTAssertEqual(destination.selectedContextRun, ModelRun(), "Nothing is copied into the candidate")
        XCTAssertEqual(destination.verdict, .notEvaluated)
        XCTAssertTrue((destination.expectedFacts + destination.correctnessChecks).allSatisfy { $0.fullContext == .notChecked && $0.selectedContext == .notChecked })
    }

    func testDifferentSavedPromptsAreSkipped() throws {
        var project = try linkedProject()
        project.experiments[3].snapshot.originalPrompt += " "  // simulate a different saved prompt
        let (updated, outcome) = ReferenceSharing.share(from: project.experiments[0].id, in: project.experiments)
        XCTAssertEqual(outcome.skipped[.differentPrompt], 1)
        XCTAssertTrue(updated[3].evaluation.fullContextRun.isBlank)
    }

    func testSourceRequirements() throws {
        var project = try linkedProject()
        project.experiments[0].evaluation.setAnswer("", for: .fullContext, prompt: "")
        XCTAssertNotNil(ReferenceSharing.share(from: project.experiments[0].id, in: project.experiments).1.sourceUnavailable)
        XCTAssertNotNil(ReferenceSharing.share(from: project.experiments[4].id, in: [project.experiments[4]]).1.sourceUnavailable)
        XCTAssertNotNil(ReferenceSharing.share(from: UUID(), in: project.experiments).1.sourceUnavailable)
    }

    func testSharedReferencesSurviveSaveAndReopen() throws {
        var project = try linkedProject()
        project.experiments = ReferenceSharing.share(from: project.experiments[0].id, in: project.experiments).0
        let reopened = try ProjectCodec.decode(ProjectCodec.encode(project))
        XCTAssertEqual(reopened.experiments, project.experiments)
    }
}

final class ProviderComparisonTests: XCTestCase {

    private func evaluation(_ full: ProviderUsage, _ selected: ProviderUsage) -> Evaluation {
        var e = Evaluation()
        e.setUsage(full, for: .fullContext)
        e.setUsage(selected, for: .selectedContext)
        return e
    }

    func testRequiresBothCountsAndMatchingNonEmptyLabels() {
        let ok = evaluation(ProviderUsage(provider: "P", model: "M", inputTokens: 200), ProviderUsage(provider: " P ", model: "M", inputTokens: 150))
        XCTAssertEqual(ok.providerInputComparison, .comparable(provider: "P", model: "M", fullContext: 200, selectedContext: 150))
        XCTAssertTrue(ok.providerInputComparison.isComparable)

        let cases: [(ProviderUsage, ProviderUsage, String)] = [
            (ProviderUsage(provider: "P", model: "M", inputTokens: 200), ProviderUsage(provider: "P", model: "M"), "both answers"),
            (ProviderUsage(provider: "", model: "M", inputTokens: 200), ProviderUsage(provider: "P", model: "M", inputTokens: 150), "labels for both"),
            (ProviderUsage(provider: "P", model: "", inputTokens: 200), ProviderUsage(provider: "P", model: "", inputTokens: 150), "labels for both"),
            (ProviderUsage(provider: "P", model: "M1", inputTokens: 200), ProviderUsage(provider: "P", model: "M2", inputTokens: 150), "differ"),
            (ProviderUsage(provider: "P1", model: "M", inputTokens: 200), ProviderUsage(provider: "P2", model: "M", inputTokens: 150), "differ")
        ]
        for (full, selected, expected) in cases {
            guard case .unavailable(let reason) = evaluation(full, selected).providerInputComparison else {
                return XCTFail("Should not compare: \(full) vs \(selected)")
            }
            XCTAssertTrue(reason.contains(expected), reason)
        }
        XCTAssertTrue(ProviderInputComparison.caveat.contains("do not establish identical generation settings"))
    }

    func testChangeFormatting() {
        XCTAssertEqual(TokenChange.describe(baseline: 200, candidate: 150), "50 fewer tokens (\u{2212}25.0%)")
        XCTAssertEqual(TokenChange.describe(baseline: 200, candidate: 230), "30 more tokens (+15.0%)", "Increases are shown as increases")
        XCTAssertEqual(TokenChange.describe(baseline: 200, candidate: 200), "No change")
        XCTAssertEqual(TokenChange.describe(baseline: 0, candidate: 40), "40 more tokens (no percentage: baseline is 0)")
        XCTAssertEqual(TokenChange.describe(baseline: 0, candidate: 0), "No change")
        XCTAssertFalse(TokenChange.describe(baseline: 10, candidate: 20).contains("\u{2212}-"))
    }

    func testIncreasedProviderUsageIsReportedAsIncrease() {
        let e = evaluation(ProviderUsage(provider: "P", model: "M", inputTokens: 100), ProviderUsage(provider: "P", model: "M", inputTokens: 120))
        XCTAssertEqual(e.providerInputComparison.summary, "20 more tokens (+20.0%)")
        let zero = evaluation(ProviderUsage(provider: "P", model: "M", inputTokens: 0), ProviderUsage(provider: "P", model: "M", inputTokens: 5))
        XCTAssertEqual(zero.providerInputComparison.summary, "5 more tokens (no percentage: baseline is 0)")
    }
}
