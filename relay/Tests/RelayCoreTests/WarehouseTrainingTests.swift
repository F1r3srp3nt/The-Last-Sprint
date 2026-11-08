import XCTest
@testable import RelayCore

final class WarehouseTrainingTests: XCTestCase {
    let procedure = DemoProcedure.procedure

    func testDemoProcedureIsValidAndLabelledAsDemonstration() throws {
        try procedure.validate()
        for language in procedure.languages {
            XCTAssertFalse(procedure.disclaimer.resolve(language, source: "en").isFallback)
        }
        XCTAssertTrue(procedure.disclaimer.values["en"]!.contains("Not official Holio documentation"))
    }

    func testOneStepAtATimeWithSafetyAcknowledgement() {
        var session = TrainingSession(procedure: procedure, language: "en")
        guard case let .step(first) = session.start() else { return XCTFail("expected step 1") }
        XCTAssertEqual(first.stepID, "S1")
        XCTAssertEqual(first.position, 1)
        // S1 has a critical warning: cannot advance until acknowledged.
        guard case .needsAcknowledgement = session.next() else { return XCTFail("must block on critical warning") }
        XCTAssertEqual(session.currentStep?.id, "S1")
        session.acknowledgeCurrentWarnings()
        guard case let .step(second) = session.next() else { return XCTFail("expected step 2") }
        XCTAssertEqual(second.stepID, "S2")
        // S2 has only a caution: advancing is allowed.
        guard case let .step(third) = session.next() else { return XCTFail("expected step 3") }
        XCTAssertEqual(third.stepID, "S3")
        guard case let .step(back) = session.previous() else { return XCTFail("expected back") }
        XCTAssertEqual(back.stepID, "S2")
        XCTAssertEqual(session.repeatCurrent(), .step(back))
    }

    func testWalkingToTheEndFinishes() {
        var session = TrainingSession(procedure: procedure, language: "nb")
        _ = session.start()
        var guardCounter = 0
        while !session.isFinished && guardCounter < 50 {
            session.acknowledgeCurrentWarnings()
            _ = session.next()
            guardCounter += 1
        }
        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(session.currentStep?.id, "S7")
    }

    func testAnswerCitesSupportingInstruction() {
        let answerer = ProcedureAnswerer(procedure: procedure)
        guard case let .answer(text, citation, warnings) = answerer.answer("Which gloves do I need?", language: "en") else {
            return XCTFail("expected an answer")
        }
        XCTAssertTrue(text.contains("cut-resistant gloves"))
        XCTAssertEqual(citation.stepID, "S1")
        XCTAssertEqual(citation.quote, procedure.step("S1")!.instruction.values["en"])
        XCTAssertTrue(warnings.contains { $0.id == "W1" && $0.severity == .critical },
                      "answers must carry the supporting step's critical warnings")
    }

    func testAnswerInWorkersLanguage() {
        let answerer = ProcedureAnswerer(procedure: procedure)
        guard case let .answer(text, citation, warnings) = answerer.answer("Co zrobić, gdy widzę wyciek?", language: "pl") else {
            return XCTFail("expected an answer")
        }
        XCTAssertEqual(citation.stepID, "S3")
        XCTAssertTrue(text.contains("Nie dotykaj cieczy"))
        XCTAssertTrue(warnings.first!.text.contains("Nie dotykaj cieczy"))
        XCTAssertFalse(citation.isFallback)
    }

    func testVagueQuestionAsksForClarification() {
        let answerer = ProcedureAnswerer(procedure: procedure)
        guard case let .clarification(prompt, options) = answerer.answer("What about it?", language: "en") else {
            return XCTFail("expected clarification")
        }
        XCTAssertTrue(prompt.contains("which"))
        XCTAssertTrue(options.isEmpty)
    }

    func testAmbiguousQuestionOffersBothSteps() {
        // "damage" (S3) and "count" (S6) each match one keyword: ambiguous.
        let answerer = ProcedureAnswerer(procedure: procedure)
        guard case let .clarification(_, options) = answerer.answer("damage or count?", language: "en") else {
            return XCTFail("expected clarification")
        }
        XCTAssertEqual(Set(options.map(\.stepID)), ["S3", "S6"])
    }

    func testOutOfScopeAndUnknownQuestionsEscalate() {
        let answerer = ProcedureAnswerer(procedure: procedure)
        guard case let .escalation(message, _) = answerer.answer("How do I handle frozen goods?", language: "en") else {
            return XCTFail("frozen goods are explicitly out of scope")
        }
        XCTAssertTrue(message.contains("does not cover"))
        XCTAssertTrue(message.contains("shift lead"))
        guard case .escalation = answerer.answer("When is the lunch break?", language: "en") else {
            return XCTFail("the procedure says nothing about breaks")
        }
        guard case let .escalation(nb, _) = answerer.answer("Når er lunsjpausen?", language: "nb") else {
            return XCTFail("expected escalation in Norwegian")
        }
        XCTAssertTrue(nb.contains("skiftlederen"))
    }

    func testEveryWarningIsPresentInEveryLanguage() {
        for language in procedure.languages + ["uk"] { // "uk" has no translation at all
            for step in procedure.steps {
                let rendered = ProcedureRenderer.render(step, in: procedure, language: language)
                XCTAssertEqual(Set(rendered.warnings.map(\.id)), Set(step.warnings.map(\.id)),
                               "warning dropped in \(language) \(step.id)")
                let text = ProcedureRenderer.plainText(rendered)
                for warning in rendered.warnings { XCTAssertTrue(text.contains(warning.text)) }
                if let critical = rendered.warnings.first(where: { $0.severity == .critical }) {
                    XCTAssertTrue(text.hasPrefix(TrainingPhrases.text(.criticalPrefix, language)),
                                  "critical warnings are presented first")
                    XCTAssertTrue(text.contains(critical.text))
                }
            }
        }
    }

    func testMissingTranslationFallsBackToSourceAndIsMarked() throws {
        let step = ProcedureStep(
            id: "A", title: LocalizedText(["en": "Lift", "nb": "Løft"]),
            instruction: LocalizedText(["en": "Lift with your legs.", "nb": "Løft med beina."]),
            warnings: [ProcedureWarning(id: "WX", severity: .critical,
                                        text: LocalizedText(["en": "Never lift more than 25 kg alone."]))])
        let p = Procedure(id: "t", title: LocalizedText(["en": "T"]), version: "1", sourceLanguage: "en",
                          languages: ["en", "nb"], disclaimer: LocalizedText(["en": "test"]),
                          escalationContact: LocalizedText(["en": "a supervisor"]), steps: [step], facts: [])
        try p.validate()
        let rendered = ProcedureRenderer.render(step, in: p, language: "nb")
        XCTAssertEqual(rendered.instruction, "Løft med beina.")
        XCTAssertEqual(rendered.warnings.first?.text, "Never lift more than 25 kg alone.")
        XCTAssertTrue(rendered.warnings.first!.isFallback)
        XCTAssertTrue(rendered.usedFallback)
        XCTAssertTrue(ProcedureRenderer.plainText(rendered).contains(TrainingPhrases.text(.fallbackNotice, "nb")))
    }

    func testProcedureJSONRoundTripAndValidation() throws {
        let data = try procedure.jsonData()
        XCTAssertEqual(try Procedure.load(from: data), procedure)
        let broken = Procedure(id: "b", title: LocalizedText(["en": "B"]), version: "1", sourceLanguage: "en",
                               languages: ["en"], disclaimer: LocalizedText(["en": "x"]),
                               escalationContact: LocalizedText(["en": "x"]), steps: procedure.steps,
                               facts: [ProcedureFact(id: "F", kind: .answer, keywords: ["x"],
                                                     answer: LocalizedText(["en": "x"]), supportingStepID: "S99")])
        XCTAssertThrowsError(try broken.validate()) {
            XCTAssertEqual($0 as? Procedure.ValidationError, .unknownSupportingStep(fact: "F", step: "S99"))
        }
    }
}
