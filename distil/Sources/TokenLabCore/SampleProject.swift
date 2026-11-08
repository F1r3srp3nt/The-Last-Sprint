import Foundation

/// Synthetic example written for this project. Contains no real business data.
public enum SampleProject {
    public static func make() -> ProjectDocument {
        let task = "Write a five-sentence handover note for a new team member joining the \"Harbour Lights\" volunteer project."
        let instructions = "Use only the facts in the supplied context. Do not invent dates, names or numbers."
        let code = """
        func nextShift(after hour: Int) -> Int {
            // Shifts start every four hours, beginning at 06:00.
            let starts = [6, 10, 14, 18]
        \treturn starts.first { $0 > hour } ?? starts[0]
        }
        """
        let status = "Lamps on the north pier were replaced last month. Two volunteers check the timers each Saturday."
        let blocks = [
            ContextBlock(title: "Safety rules", text: "Volunteers must work in pairs on the pier. Hi-vis vests are required after sunset.",
                         category: .reference, priority: ContextPriority.high, required: true),
            ContextBlock(title: "Shift helper (code)", text: code, category: .code, priority: ContextPriority.high, required: true),
            ContextBlock(title: "Current status", text: status, category: .reference, priority: ContextPriority.high),
            ContextBlock(title: "Status (pasted again)", text: status, category: .conversation, priority: ContextPriority.medium),
            ContextBlock(title: "Volunteer chat", text: "Someone asked about the café opening hours. Another person shared photos of the sunset and a recipe for fish soup.",
                         category: .conversation, priority: ContextPriority.low),
            ContextBlock(title: "Timer log", text: (1...6).map { "2026-03-0\($0) 18:0\($0) timer-check ok battery=9\($0)%" }.joined(separator: "\n"),
                         category: .toolOutput, priority: ContextPriority.medium)
        ]
        let library = [
            ContextBlock(title: "Tone guide", text: "Write in plain, friendly language. Prefer short sentences and avoid jargon.",
                         category: .reference, priority: ContextPriority.medium),
            ContextBlock(title: "Contact rota", text: "Questions go to the duty coordinator listed on the noticeboard.",
                         category: .reference, priority: ContextPriority.low)
        ]
        return ProjectDocument(
            notes: "Basic example — synthetic data written for this project.",
            draft: Draft(task: task, instructions: instructions, blocks: blocks),
            settings: SelectionSettings(strategy: .budgetSelection, budget: 170, deduplicateBeforeBudget: true,
                                        counter: .approximate(bytesPerToken: 4)),
            reviewTemplate: ReviewTemplate(expectedFacts: ["Volunteers work in pairs on the pier", "Hi-vis vests after sunset"],
                                           correctnessChecks: ["No invented dates, names or numbers"]),
            library: library)
    }
}
