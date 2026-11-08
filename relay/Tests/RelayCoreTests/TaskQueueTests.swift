import XCTest
@testable import RelayCore

final class TaskQueueTests: XCTestCase {
    func testValidLifecycleIsRecorded() throws {
        let log = InMemoryEventLog(redactor: Redactor())
        var queue = TaskQueue(log: log)
        let task = try queue.add(title: "Restock gloves", source: .assistant)
        try queue.transition(task.id, to: .awaitingApproval)
        try queue.transition(task.id, to: .inProgress, note: "approved")
        try queue.transition(task.id, to: .succeeded)
        let stored = try XCTUnwrap(queue.task(task.id))
        XCTAssertEqual(stored.state, .succeeded)
        XCTAssertEqual(stored.history.map(\.to), [.awaitingApproval, .inProgress, .succeeded])
        XCTAssertTrue(log.entries().contains { $0.kind == .succeeded && $0.channel == .tasks })
    }

    func testInvalidTransitionsAreRejected() throws {
        var queue = TaskQueue()
        let task = try queue.add(title: "Check dock", source: .warehouse)
        XCTAssertThrowsError(try queue.transition(task.id, to: .succeeded)) { error in
            XCTAssertEqual(error as? TaskQueueError, .invalidTransition(from: .queued, to: .succeeded))
        }
        XCTAssertEqual(queue.task(task.id)?.state, .queued, "a rejected transition must not change state")
    }

    func testTerminalTasksCannotBeRevived() throws {
        var queue = TaskQueue()
        let task = try queue.add(title: "One-off", source: .assistant)
        try queue.transition(task.id, to: .cancelled)
        for state in TaskState.allCases {
            XCTAssertThrowsError(try queue.transition(task.id, to: state))
        }
    }

    func testNeedsAttentionCanBeResolved() throws {
        var queue = TaskQueue()
        let task = try queue.add(title: "Escalation", source: .warehouse, initialState: .needsAttention)
        XCTAssertEqual(queue.attentionCount, 1)
        try queue.transition(task.id, to: .succeeded, note: "answered by shift lead")
        XCTAssertEqual(queue.attentionCount, 0)
    }

    func testEmptyTitleAndUnknownTask() {
        var queue = TaskQueue()
        XCTAssertThrowsError(try queue.add(title: "   ", source: .assistant)) { XCTAssertEqual($0 as? TaskQueueError, .emptyTitle) }
        let id = UUID()
        XCTAssertThrowsError(try queue.transition(id, to: .inProgress)) { XCTAssertEqual($0 as? TaskQueueError, .unknownTask(id)) }
    }
}
