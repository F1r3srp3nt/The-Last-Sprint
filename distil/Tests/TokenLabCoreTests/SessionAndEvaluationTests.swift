import XCTest
@testable import TokenLabCore

final class SessionTests: XCTestCase {
    let url = URL(fileURLWithPath: "/tmp/tokenlab-test-project.json")

    func testDirtyTracking() throws {
        var session = ProjectSession()
        XCTAssertFalse(session.hasUnsavedChanges, "A new empty project has nothing to lose")
        session.document.draft.instructions = "Hello"
        XCTAssertTrue(session.hasUnsavedChanges)
        session.didSave(session.document, to: url)
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertEqual(session.displayName, "tokenlab-test-project")
        session.document.settings.budget += 1
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertTrue(ProjectSession.untitled(SampleProject.make()).hasUnsavedChanges, "Unsaved sample content counts as unsaved work")
    }

    func testEditsAfterEncodingStayUnsaved() {
        var session = ProjectSession()
        session.document.draft.instructions = "v1"
        let written = session.document
        session.document.draft.instructions = "v2" // edited while the save panel was open
        session.didSave(written, to: url)
        XCTAssertTrue(session.hasUnsavedChanges)
    }

    func testUnsavedChangesDecision() {
        var asked = 0, saved = 0
        func run(dirty: Bool, choice: UnsavedChangesChoice, saveSucceeds: Bool = true) -> Bool {
            ProjectSession.mayProceed(hasUnsavedChanges: dirty, ask: { asked += 1; return choice }, save: { saved += 1; return saveSucceeds })
        }
        XCTAssertTrue(run(dirty: false, choice: .cancel)); XCTAssertEqual(asked, 0)
        XCTAssertFalse(run(dirty: true, choice: .cancel)); XCTAssertEqual(saved, 0)
        XCTAssertTrue(run(dirty: true, choice: .discard)); XCTAssertEqual(saved, 0)
        XCTAssertTrue(run(dirty: true, choice: .save, saveSucceeds: true)); XCTAssertEqual(saved, 1)
        XCTAssertFalse(run(dirty: true, choice: .save, saveSucceeds: false), "A cancelled or failed save must not discard work")
        XCTAssertEqual(asked, 4)
    }

    func testOpeningMalformedDataDoesNotProduceASession() {
        XCTAssertThrowsError(try ProjectSession.opening(data: Data("{oops".utf8), url: url))
        XCTAssertThrowsError(try ProjectSession.opening(data: Data(#"{"schemaVersion": 9}"#.utf8), url: url))
    }

    func testOpeningValidDataIsCleanAndRemembersLocation() throws {
        let data = try ProjectCodec.encode(SampleProject.make())
        let (session, loaded) = try ProjectSession.opening(data: data, url: url)
        XCTAssertFalse(loaded.wasMigrated)
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertEqual(session.fileURL, url)
    }

    func testMigratedFilesOpenAsUntitledSoTheyAreNotOverwritten() throws {
        let json = #"{"schemaVersion": 1, "draft": {"instructions": "x", "blocks": [], "budget": 10}, "library": [], "experiments": []}"#
        let (session, loaded) = try ProjectSession.opening(data: Data(json.utf8), url: url)
        XCTAssertTrue(loaded.wasMigrated)
        XCTAssertNil(session.fileURL)
        XCTAssertTrue(session.hasUnsavedChanges)
    }
}

final class EvaluationTests: XCTestCase {

    func testNewExperimentsAreNotEvaluated() throws {
        let report = try SelectionEngine.run(Draft(instructions: "x"), settings: SelectionSettings(), counter: ApproximateCounter())
        let experiment = Experiment(name: "e", snapshot: report)
        XCTAssertEqual(experiment.evaluation.verdict, .notEvaluated)
        XCTAssertFalse(experiment.evaluation.isEvaluated)
        XCTAssertEqual(experiment.evaluation.statusLabel, "Not evaluated")
        XCTAssertNil(experiment.evaluation.evaluatedAt)
    }

    func testVerdictRequiresSelectedAnswer() throws {
        var evaluation = Evaluation()
        XCTAssertThrowsError(try evaluation.setVerdict(.equivalent))
        XCTAssertEqual(evaluation.verdict, .notEvaluated)

        evaluation.selectedContextRun.responseText = "   \n"
        XCTAssertThrowsError(try evaluation.setVerdict(.equivalent), "Whitespace is not an answer")

        evaluation.selectedContextRun.responseText = "An answer"
        XCTAssertEqual(evaluation.statusLabel, "Not evaluated (answers recorded)")
        try evaluation.setVerdict(.acceptableWithLosses)
        XCTAssertTrue(evaluation.isEvaluated)
        XCTAssertNotNil(evaluation.evaluatedAt)

        try evaluation.setVerdict(.notEvaluated)
        XCTAssertNil(evaluation.evaluatedAt)
    }

    func testProviderUsageIsSeparateFromEstimates() throws {
        var project = try sampleWithExperiment()
        let experiment = project.experiments[0]
        guard case .comparable(let provider, let model, let full, let selected) = experiment.evaluation.providerInputComparison else {
            return XCTFail("Matching labels and both counts should be comparable")
        }
        XCTAssertEqual([provider, model], ["Manual", "test-model"])
        XCTAssertEqual(full - selected, 100)
        XCTAssertNotEqual(full - selected, experiment.snapshot.estimatedReduction, "Estimates and provider usage are independent numbers")

        project.experiments[0].evaluation.selectedContextRun.usage.inputTokens = nil
        guard case .unavailable = project.experiments[0].evaluation.providerInputComparison else {
            return XCTFail("No provider comparison without both measurements")
        }
    }

    func testCheckTallies() throws {
        let evaluation = try sampleWithExperiment().experiments[0].evaluation
        XCTAssertEqual(evaluation.tally(selected: false).pass, 2)
        XCTAssertEqual(evaluation.tally(selected: true).pass, 1)
        XCTAssertEqual(evaluation.tally(selected: true).fail, 1)
    }

    func testProviderRegistryHasNoLiveAdapters() {
        XCTAssertTrue(ProviderRegistry.adapters.isEmpty)
    }
}

final class SecretScannerTests: XCTestCase {
    // Fake values assembled at runtime so no credential-shaped literal exists in the source.
    let fakeKey = "sk-" + String(repeating: "x", count: 24)
    let fakeAccessID = "AKIA" + String(repeating: "Q", count: 16)
    let fakePEM = "-----BEGIN " + "PRIVATE KEY-----"

    func testDetectsCredentialShapes() {
        XCTAssertEqual(SecretScanner.kinds(in: "token: \(fakeKey)").count, 1)
        XCTAssertEqual(SecretScanner.kinds(in: fakeAccessID).count, 1)
        XCTAssertEqual(SecretScanner.kinds(in: fakePEM).count, 1)
        XCTAssertTrue(SecretScanner.kinds(in: "An ordinary sentence about skiing and sk-ills.").isEmpty)
    }

    func testFindingsNameLocationButNotValue() {
        var project = SampleProject.make()
        project.library[0].text += "\n\(fakeKey)"
        let findings = SecretScanner.scan(project)
        XCTAssertEqual(findings.count, 1)
        XCTAssertTrue(findings[0].location.contains("Tone guide"))
        XCTAssertFalse(findings[0].location.contains(fakeKey) || findings[0].kind.contains(fakeKey))
        XCTAssertTrue(SecretScanner.scan(SampleProject.make()).isEmpty)
    }
}
