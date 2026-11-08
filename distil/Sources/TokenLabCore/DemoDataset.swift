import Foundation

/// Small synthetic demonstrations written for this project. They illustrate behaviour, including a
/// case where keyword ranking does badly. They are not a benchmark and prove nothing about answer quality.
public enum DemoDataset {
    public enum ID: String, CaseIterable, Identifiable, Sendable {
        case codingTask, requiredConstraint, paraphrasedTask, pastedNotes
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .codingTask: return "Coding task with duplicates and noise"
            case .requiredConstraint: return "Constraint that must be marked required"
            case .paraphrasedTask: return "Paraphrased task (keyword-ranking weakness)"
            case .pastedNotes: return "Pasted notes: a useful reduction, and a loss"
            }
        }
        public var summary: String {
            switch self {
            case .codingTask:
                return "A bug fix with relevant requirements, a pasted-twice discussion, a high-priority but unrelated checklist and chat that shares a keyword with the task."
            case .requiredConstraint:
                return "A refund reply where the approval rule shares only one word (“customer”) with the task. Marked required, it stays at any budget. Untick Required and it must compete: it still fits at the demo budget of 120, but at 110 it is dropped while an unrelated carrier notice is kept."
            case .paraphrasedTask:
                return "The task and the useful notes use different words, while an unhelpful newsletter repeats the task’s words. Task relevance keeps the wrong block here."
            case .pastedNotes:
                return "Team notes pasted and split into blocks. At the demo budget the duplicate meeting notes and the changelog are left out while every expected fact stays. Lower the budget to 150 and the error-code section is dropped, losing the rule that 400 and 413 must never be retried."
            }
        }
    }

    public static let label = "DEMONSTRATION — synthetic data written for this project. It shows how the strategies behave; it is not benchmark evidence and says nothing about answer quality until you record and review real answers."

    public static func make(_ id: ID) -> ProjectDocument {
        switch id {
        case .codingTask: return codingTask()
        case .requiredConstraint: return requiredConstraint()
        case .paraphrasedTask: return paraphrasedTask()
        case .pastedNotes: return pastedNotes()
        }
    }

    static func notes(_ id: ID) -> String { "\(label)\n\n\(id.title): \(id.summary)" }

    // MARK: 1. Coding task

    static func codingTask() -> ProjectDocument {
        let source = """
        import Foundation

        /// Parses a due date written as year-month-day.
        func parseDueDate(_ text: String) -> Date? {
            let pattern = #"^\\d{4}-\\d{2}-\\d{2}$"#
            guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
        \tformatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.date(from: text)
        }
        """
        let discussion = "Ida: Users say 2026-3-07 is rejected, but 2026-03-07 works. Ola: The regex in parseDueDate expects two digits for the month and the day. Ida: Let's allow one or two digits and keep returning nil for impossible dates like 2026-02-30."
        let blocks = [
            ContextBlock(title: "Date parser source", text: source, category: .code, priority: ContextPriority.medium),
            ContextBlock(title: "Parser requirements", text: "Due dates are entered as year-month-day. Months and days may have one or two digits. Impossible dates must return nil instead of crashing. Keep the existing function signature.",
                         category: .reference, priority: ContextPriority.medium),
            ContextBlock(title: "Bug discussion", text: discussion, category: .conversation, priority: ContextPriority.low),
            ContextBlock(title: "Bug discussion (pasted again)", text: discussion, category: .conversation, priority: ContextPriority.low),
            ContextBlock(title: "Release checklist", text: "Before each release: update the changelog, bump the build number, run the UI smoke tests on the oldest supported macOS version and archive the build logs.",
                         category: .reference, priority: ContextPriority.high),
            ContextBlock(title: "Team lunch thread", text: "Can we move the lunch date to Friday? The usual place is closed on Thursday. Bring a test batch of the new cookies if you can.",
                         category: .conversation, priority: ContextPriority.medium),
            ContextBlock(title: "CI log excerpt", text: (1...8).map { "[build \(400 + $0)] Compiling module DueDates (\($0) of 8) … ok" }.joined(separator: "\n") + "\nAll 212 tests passed.",
                         category: .toolOutput, priority: ContextPriority.low)
        ]
        return ProjectDocument(
            notes: notes(.codingTask),
            draft: Draft(task: "Fix the bug where parseDueDate rejects dates with a single-digit month or day, such as 2026-3-07, and add a unit test for that date.",
                         instructions: "Reply with a unified diff followed by one sentence explaining the cause. Keep the public function signature unchanged. Do not add dependencies.",
                         blocks: blocks),
            settings: SelectionSettings(strategy: .taskRelevance, budget: 260, deduplicateBeforeBudget: true, counter: .approximate(bytesPerToken: 4)),
            reviewTemplate: ReviewTemplate(
                expectedFacts: ["The month and day patterns accept one or two digits",
                                "parseDueDate keeps its signature",
                                "A unit test covers 2026-3-07",
                                "Impossible dates such as 2026-02-30 still return nil"],
                correctnessChecks: ["The diff applies to the shown source", "No new dependencies", "No invented helper functions or files"]))
    }

    // MARK: 2. Required constraint

    static func requiredConstraint() -> ProjectDocument {
        let blocks = [
            ContextBlock(title: "Approval rule", text: "Any payment returned to a customer above 500 NOK must first be approved by a team lead. Never promise an amount before approval.",
                         category: .reference, priority: ContextPriority.high, required: true),
            ContextBlock(title: "Order 4471", text: "order=4471 items=2 total=820 NOK delivered=2026-02-10 status=complaint reason=\"lamp arrived broken\"",
                         category: .toolOutput, priority: ContextPriority.medium),
            ContextBlock(title: "Customer email", text: "Hello, the lamp in order 4471 arrived broken. I would like a refund please. — Kari",
                         category: .conversation, priority: ContextPriority.medium),
            ContextBlock(title: "Refund page copy", text: "Refunds made easy! Our refund promise: fast refund handling, friendly refund staff, refund updates by email. Refund, refund, refund — we love happy customers.",
                         category: .reference, priority: ContextPriority.low),
            ContextBlock(title: "Carrier notice", text: "From March, parcels to northern regions may take one extra day because of a new sorting centre.",
                         category: .reference, priority: ContextPriority.low)
        ]
        return ProjectDocument(
            notes: notes(.requiredConstraint),
            draft: Draft(task: "Draft a reply to the customer who asked for a refund for order 4471.",
                         instructions: "Be polite and concise. Do not make commitments the policy does not allow.",
                         blocks: blocks),
            settings: SelectionSettings(strategy: .taskRelevance, budget: 120, deduplicateBeforeBudget: false, counter: .approximate(bytesPerToken: 4)),
            reviewTemplate: ReviewTemplate(
                expectedFacts: ["Refers to order 4471 and the broken lamp",
                                "Says the request needs team-lead approval because 820 NOK is above 500 NOK"],
                correctnessChecks: ["Does not promise a refund amount", "Polite and concise"]))
    }

    // MARK: 3. Paraphrased task

    static func paraphrasedTask() -> ProjectDocument {
        let blocks = [
            ContextBlock(title: "Exit interviews", text: "People who left said the rota felt unpredictable, and newcomers rarely had a buddy during their early weeks.",
                         category: .conversation, priority: ContextPriority.medium),
            ContextBlock(title: "Survey summary", text: "Leavers survey (n=27): 41% cited scheduling; 33% felt unsupported early on; 15% moved away.",
                         category: .toolOutput, priority: ContextPriority.medium),
            ContextBlock(title: "Newsletter", text: "Volunteer of the month: Sam, who has been showing up every Saturday since the first month! This month we also welcome twelve new volunteers. Thank you, volunteers!",
                         category: .reference, priority: ContextPriority.medium),
            ContextBlock(title: "Photo credits", text: "Photos on the noticeboard by Lena and Tomas. Please ask before sharing them online.",
                         category: .reference, priority: ContextPriority.low)
        ]
        return ProjectDocument(
            notes: notes(.paraphrasedTask),
            draft: Draft(task: "Why do some volunteers stop showing up after their first month?",
                         instructions: "Answer in three bullet points using only the provided notes. Say so if the notes do not answer the question.",
                         blocks: blocks),
            settings: SelectionSettings(strategy: .taskRelevance, budget: 95, deduplicateBeforeBudget: false, counter: .approximate(bytesPerToken: 4)),
            reviewTemplate: ReviewTemplate(
                expectedFacts: ["Mentions the unpredictable rota or scheduling",
                                "Mentions newcomers lacking a buddy or support early on"],
                correctnessChecks: ["Does not present the newsletter as a cause", "Uses only the provided notes"]))
    }
}

extension DemoDataset {
    /// Synthetic notes, pasted as one document and split with `ContextSplitter`.
    public static let pastedNotesText = """
    # Upload service notes

    These notes collect what the team knows about the photo upload service.

    ## Rate limits

    The upload endpoint accepts at most 30 requests per minute per device. Requests over the limit get HTTP 429 with a Retry-After header, in seconds.

    ## Error codes

    - 429: too many requests; wait for Retry-After before retrying.
    - 503: service temporarily unavailable; safe to retry with exponential backoff.
    - 400 and 413: the request itself is wrong; never retry these.

    ## Current client

    ```swift
    func upload(_ data: Data) async throws -> Receipt {
        let request = makeRequest(data)

        let (body, response) = try await session.data(for: request)
        return try decodeReceipt(body, response)
    }
    ```

    ## Meeting notes (week 12)

    Agreed to look at retries after the release. The lunch rota and the office move were also discussed.

    ## Meeting notes (week 12)

    Agreed to look at retries after the release. The lunch rota and the office move were also discussed.

    ## Changelog

    1.4.2: fixed thumbnail colours on dark backgrounds.
    1.4.1: updated Norwegian and Polish translations.
    1.4.0: new onboarding screens.
    """

    static func pastedNotes() -> ProjectDocument {
        let source = PastedSource(title: "Upload service notes", text: pastedNotesText,
                                  importedAt: Date(timeIntervalSinceReferenceDate: 815_000_000))
        let blocks = ContextSplitter.split(pastedNotesText).map {
            ContextBlock(title: $0.title, text: $0.text, category: $0.category, pastedSourceID: source.id)
        }
        return ProjectDocument(
            notes: notes(.pastedNotes),
            draft: Draft(task: "Add retry handling to the upload client so that temporary failures are retried safely.",
                         instructions: "Reply with the Swift changes only. Keep the upload(_:) signature unchanged.",
                         blocks: blocks),
            settings: SelectionSettings(strategy: .taskRelevance, budget: 230, deduplicateBeforeBudget: true,
                                        counter: .approximate(bytesPerToken: 4)),
            reviewTemplate: ReviewTemplate(
                expectedFacts: ["Waits for Retry-After before retrying a 429",
                                "Retries 503 with exponential backoff",
                                "Never retries 400 or 413",
                                "Keeps the upload(_:) signature"],
                correctnessChecks: ["Changes compile against the shown client", "No invented endpoints or headers"]),
            pastedSources: [source])
    }
}
