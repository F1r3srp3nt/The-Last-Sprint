import XCTest
@testable import TokenLabCore

func sampleWithExperiment() throws -> ProjectDocument {
    var project = SampleProject.make()
    let report = try SelectionEngine.run(project.draft, settings: project.settings, counter: ApproximateCounter())
    var evaluation = Evaluation()
    evaluation.fullContextRun = ModelRun(responseText: "Full answer.", usage: ProviderUsage(provider: "Manual", model: "test-model", inputTokens: 300, outputTokens: 80))
    evaluation.selectedContextRun = ModelRun(responseText: "Selected answer.", usage: ProviderUsage(provider: "Manual", model: "test-model", inputTokens: 200, outputTokens: 75))
    evaluation.expectedFacts = [ReviewCheck(text: "Mentions working in pairs", fullContext: .pass, selectedContext: .pass)]
    evaluation.correctnessChecks = [ReviewCheck(text: "No invented dates", fullContext: .pass, selectedContext: .fail)]
    evaluation.reviewer = "Reviewer A"
    evaluation.reviewerNotes = "Selected answer added a date."
    try evaluation.setVerdict(.degraded, at: Date(timeIntervalSinceReferenceDate: 800_000_000.75))
    project.experiments = [Experiment(name: "Sample run", createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000.5), snapshot: report, evaluation: evaluation)]
    return project
}

final class ProjectFileTests: XCTestCase {

    func testSaveOpenRoundTripIsExactAndStable() throws {
        let project = try sampleWithExperiment()
        let data = try ProjectCodec.encode(project)
        let decoded = try ProjectCodec.decode(data)
        XCTAssertEqual(decoded, project)
        XCTAssertEqual(try ProjectCodec.encode(decoded), data, "Re-saving an unchanged project must produce identical bytes")
        XCTAssertEqual(decoded.experiments[0].evaluation.verdict, .degraded)
        XCTAssertEqual(decoded.settings.counter, .approximate(bytesPerToken: 4))
    }

    func testFilesAreReadableJSONWithSchemaVersion() throws {
        let data = try ProjectCodec.encode(SampleProject.make())
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["schemaVersion"] as? Int, 3)
    }

    func testMalformedFilesAreRejectedWithReadableErrors() {
        let cases: [String] = [
            "not json",
            "[]",
            "{}",
            #"{"schemaVersion": "two"}"#,
            #"{"schemaVersion": 2}"#,
            #"{"schemaVersion": 2, "draft": {"instructions": "x", "blocks": []}, "library": [], "experiments": []}"#
        ]
        for text in cases {
            XCTAssertThrowsError(try ProjectCodec.decode(Data(text.utf8)), text) { error in
                guard case .malformed = error as? LabError else { return XCTFail("\(text): \(error)") }
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
    }

    func testMissingFieldErrorNamesTheField() throws {
        var object = try JSONSerialization.jsonObject(with: ProjectCodec.encode(SampleProject.make())) as! [String: Any]
        object.removeValue(forKey: "settings")
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try ProjectCodec.decode(data)) { error in
            XCTAssertTrue(error.localizedDescription.contains("settings"), error.localizedDescription)
        }
    }

    func testUnsupportedSchemaVersionsAreRejected() {
        for version in [0, 4, 99] {
            let data = Data(#"{"schemaVersion": \#(version)}"#.utf8)
            XCTAssertThrowsError(try ProjectCodec.decode(data)) { error in
                XCTAssertEqual(error as? LabError, .unsupportedSchema(found: version, supported: 3))
            }
        }
        XCTAssertTrue(LabError.unsupportedSchema(found: 4, supported: 3).localizedDescription.contains("newer"))
    }

    func testOversizedFilesAreRejected() {
        XCTAssertThrowsError(try ProjectCodec.decode(Data(count: ProjectCodec.maxFileBytes + 1)))
    }

    func testInvalidContentInFilesIsRejected() throws {
        func mutated(_ change: (inout ProjectDocument) -> Void) throws -> Data {
            var project = try sampleWithExperiment()
            change(&project)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(project) // bypasses ProjectCodec.encode validation on purpose
        }
        let block = ContextBlock(text: "dup")
        let bad: [(String, Data)] = [
            ("zero budget", try mutated { $0.settings.budget = 0 }),
            ("duplicate workspace IDs", try mutated { $0.draft.blocks.append($0.draft.blocks[0]) }),
            ("duplicate library IDs", try mutated { $0.library = [block, block] }),
            ("duplicate experiment IDs", try mutated { $0.experiments.append($0.experiments[0]) }),
            ("bad library priority", try mutated { $0.library[0].priority = 7 }),
            ("tampered selected prompt", try mutated { $0.experiments[0].snapshot.selectedPrompt += " extra" }),
            ("tampered original prompt", try mutated { $0.experiments[0].snapshot.originalPrompt = "" }),
            ("decisions not matching inputs", try mutated { $0.experiments[0].snapshot.decisions.removeLast() }),
            ("negative counts", try mutated { $0.experiments[0].snapshot.selectedTokens = -1 }),
            ("verdict without answer", try mutated { $0.experiments[0].evaluation.selectedContextRun.responseText = "" }),
            ("negative provider usage", try mutated { $0.experiments[0].evaluation.fullContextRun.usage.inputTokens = -5 })
        ]
        for (label, data) in bad {
            XCTAssertThrowsError(try ProjectCodec.decode(data), label)
        }
        XCTAssertThrowsError(try ProjectCodec.encode({ var p = SampleProject.make(); p.settings.budget = 0; return p }()))
    }

    func testOlderEngineVersionSnapshotsStillLoad() throws {
        var project = try sampleWithExperiment()
        project.experiments[0].snapshot.engineVersion = "selection-engine-1"
        project.experiments[0].snapshot.counter.version = "older"
        let decoded = try ProjectCodec.decode(ProjectCodec.encode(project))
        XCTAssertEqual(decoded.experiments[0].snapshot.engineVersion, "selection-engine-1")
    }

    func testSchemaOneProjectsMigrate() throws {
        let a = UUID(), b = UUID(), e = UUID()
        let draft = """
        {"instructions": "Keep this.", "budget": 50, "blocks": [
          {"id": "\(a)", "title": "A", "text": "same", "category": "Reference", "priority": 3, "required": false},
          {"id": "\(b)", "title": "B", "text": "same", "category": "Code", "priority": 2, "required": false}]}
        """
        let json = """
        {"schemaVersion": 1, "draft": \(draft), "library": [], "experiments": [
          {"id": "\(e)", "name": "Old", "createdAt": 700000000, "review": "Manually reviewed: pass", "notes": "Looked fine.",
           "report": {"input": \(draft), "original": "Keep this.\\n\\nsame\\n\\nsame", "optimized": "Keep this.\\n\\nsame",
                      "before": 7, "after": 5, "overBudget": false, "decisions": [], "counter": "UTF-8 bytes / 4"}}]}
        """
        let loaded = try ProjectCodec.load(Data(json.utf8))
        XCTAssertTrue(loaded.wasMigrated)
        let doc = loaded.document
        XCTAssertEqual(doc.schemaVersion, 3)
        XCTAssertEqual(doc.draft.task, "", "No task is guessed from the old instructions")
        XCTAssertEqual(doc.draft.instructions, "Keep this.")
        XCTAssertEqual(doc.settings.budget, 50)
        XCTAssertTrue(doc.settings.deduplicateBeforeBudget)
        XCTAssertEqual(doc.draft.blocks.map(\.id), [a, b])
        let experiment = doc.experiments[0]
        XCTAssertEqual(experiment.id, e)
        XCTAssertEqual(experiment.snapshot.selectedPrompt, "Keep this.\n\nsame")
        XCTAssertEqual(experiment.evaluation.verdict, .notEvaluated)
        XCTAssertTrue(experiment.evaluation.reviewerNotes.contains("Manually reviewed: pass"))
        XCTAssertTrue(experiment.evaluation.reviewerNotes.contains("Looked fine."))
        XCTAssertFalse(experiment.evaluation.reviewerNotes.contains("differs"))
    }

    func testExperimentSnapshotsAreIndependentOfLaterEdits() throws {
        var session = ProjectSession.untitled(SampleProject.make())
        let report = try SelectionEngine.run(session.document.draft, settings: session.document.settings, counter: ApproximateCounter())
        session.document.experiments.append(Experiment(name: "Before edits", snapshot: report))
        let saved = session.document.experiments[0]

        session.document.draft.instructions = "Completely different task."
        session.document.draft.blocks[0].text = "Changed text"
        session.document.draft.blocks.removeLast()
        session.document.settings.budget = 5
        session.document.settings.strategy = .baseline

        XCTAssertEqual(session.document.experiments[0], saved)
        XCTAssertEqual(session.document.experiments[0].snapshot.input, SampleProject.make().draft.withIDs(of: saved.snapshot.input))
        XCTAssertNoThrow(try session.document.validate())
        XCTAssertEqual(try ProjectCodec.decode(ProjectCodec.encode(session.document)).experiments[0], saved)
    }

    func testReproductionCheck() throws {
        let project = try sampleWithExperiment()
        let resolver = StaticCounterResolver()
        XCTAssertEqual(ReproductionCheck.run(project.experiments[0], resolver: resolver), .identical)

        var changed = project.experiments[0]
        changed.snapshot.counter.version = "approx-0"
        guard case .differs(let reasons) = ReproductionCheck.run(changed, resolver: resolver) else { return XCTFail() }
        XCTAssertTrue(reasons.contains { $0.hasPrefix("Counter") })

        var needsBPE = project.experiments[0]
        needsBPE.snapshot.settings.counter = .bpe(encoding: .cl100k_base)
        guard case .counterUnavailable = ReproductionCheck.run(needsBPE, resolver: resolver) else { return XCTFail() }
    }
}

extension Draft {
    /// Test helper: the same draft but with block IDs taken from `other` (for comparing fresh samples).
    func withIDs(of other: Draft) -> Draft {
        var copy = self
        for i in copy.blocks.indices where i < other.blocks.count { copy.blocks[i].id = other.blocks[i].id }
        return copy
    }
}
