import Foundation
import XCTest
@testable import SymphonyBarCore

/// TP-1355: the ticket page's Priority card, from Symphony's priority endpoint to the control it sends.
@MainActor
final class TicketPriorityEditorTests: XCTestCase {
    private final class Calls {
        var sent: [ControlAction] = []
        var reads: [String] = []
    }

    private func body(_ priority: String) -> Data {
        let payload: [String: Any] = [
            "issue_identifier": "SHOP-1", "priority": priority, "priority_value": 4, "priorities": ["none", "urgent", "high", "medium", "low"],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func loaded(_ priority: String = "low") -> TicketPriorityEditor {
        let editor = TicketPriorityEditor()
        editor.show("SHOP-1")
        editor.apply(body(priority), for: "SHOP-1")
        return editor
    }

    func testReadsThePriorityAndOffersLinearsFive() {
        let editor = loaded()
        XCTAssertEqual(editor.load, .loaded)
        XCTAssertEqual(editor.priority, .low)
        XCTAssertEqual(TicketPriorityEditor.choices.map(\.title), ["Urgent", "High", "Medium", "Low", "No priority"])
        XCTAssertEqual(TicketPriorityEditor.path("SHOP-1"), "api/v1/tickets/SHOP-1/priority")
        XCTAssertEqual(TicketPriorityEditor.menuLabel("SHOP-1", .low), "Priority of SHOP-1: Low")
        XCTAssertEqual(TicketPriorityEditor.menuLabel("SHOP-1", nil), "Priority of SHOP-1: unknown")
        XCTAssertFalse(editor.canSet(.low))
        XCTAssertTrue(editor.canSet(.urgent))
    }

    func testAnUnreadableOrMissingAnswerMakesTheCardUnavailableAndAnotherTicketsAnswerChangesNothing() {
        let editor = loaded()
        editor.apply(body("urgent"), for: "SHOP-7")
        XCTAssertEqual(editor.priority, .low)

        editor.apply(body("critical"), for: "SHOP-1")
        XCTAssertEqual(editor.load, .unavailable)
        XCTAssertNil(editor.priority)
        XCTAssertFalse(editor.canSet(.urgent))

        editor.apply(nil, for: "SHOP-1")
        XCTAssertEqual(editor.load, .unavailable)
        editor.apply(Data("not json".utf8), for: "SHOP-1")
        XCTAssertEqual(editor.load, .unavailable)
    }

    func testShowingAnotherTicketStartsItsCardUnread() {
        let editor = loaded()
        editor.show("SHOP-1")
        XCTAssertEqual(editor.load, .loaded)
        editor.show("SHOP-2")
        XCTAssertEqual(editor.identifier, "SHOP-2")
        XCTAssertEqual(editor.load, .unread)
        XCTAssertNil(editor.priority)
    }

    /// Walkthrough steps 1 and 2: Low to Urgent, then back to Low; the card shows each.
    func testSettingUrgentThenLowSendsEachAndShowsIt() async {
        let editor = loaded()
        let calls = Calls()

        let urgent = await editor.set(.urgent, send: { calls.sent.append($0); return .done }, read: { path in
            calls.reads.append(path)
            return self.body("urgent")
        })
        XCTAssertTrue(urgent)
        XCTAssertEqual(editor.priority, .urgent)
        XCTAssertFalse(editor.sending)
        XCTAssertNil(editor.refusal)

        let low = await editor.set(.low, send: { calls.sent.append($0); return .done }, read: { _ in self.body("low") })
        XCTAssertTrue(low)
        XCTAssertEqual(editor.priority, .low)
        XCTAssertEqual(calls.sent, [.priority("SHOP-1", priority: .urgent), .priority("SHOP-1", priority: .low)])
        XCTAssertEqual(calls.reads, ["api/v1/tickets/SHOP-1/priority"])
    }

    func testTheSameOrAnUnreadCardSendsNothing() async {
        let editor = loaded()
        let none = await editor.set(.low, send: { _ in XCTFail("nothing sent"); return .done }, read: { _ in nil })
        XCTAssertFalse(none)

        let unread = TicketPriorityEditor()
        unread.show("SHOP-1")
        let sent = await unread.set(.urgent, send: { _ in XCTFail("nothing sent"); return .done }, read: { _ in nil })
        XCTAssertFalse(sent)
    }

    func testARefusalSaysWhyAndKeepsThePriority() async {
        let editor = loaded()
        let action = ControlAction.priority("SHOP-1", priority: .urgent)
        let answer = ControlAPI.result(
            action, statusCode: 409,
            data: Data(#"{"error":{"code":"move_not_allowed","message":"Symphony doesn't track SHOP-1, so it can't set its priority."}}"#.utf8)
        )

        let made = await editor.set(.urgent, send: { _ in answer }, read: { _ in XCTFail("no read after a refusal"); return nil })

        XCTAssertFalse(made)
        XCTAssertEqual(editor.priority, .low)
        XCTAssertEqual(editor.refusal, "Couldn't set SHOP-1 to Urgent: Symphony doesn't track SHOP-1, so it can't set its priority. (HTTP 409)")
        XCTAssertEqual(TicketPriorityEditor.refusalLabel("x"), "Priority not saved: x")
        XCTAssertFalse(editor.sending)
    }

    func testAnAnswerAfterThePageMovedOnLeavesTheOtherTicketsCard() async {
        let editor = loaded()
        let made = await editor.set(.urgent, send: { _ in editor.show("SHOP-2"); return .done }, read: { _ in XCTFail("no read"); return nil })
        XCTAssertTrue(made)
        XCTAssertEqual(editor.identifier, "SHOP-2")
        XCTAssertNil(editor.priority)

        let other = loaded()
        let failed = await other.set(.urgent, send: { _ in other.show("SHOP-3"); return .failed("no") }, read: { _ in nil })
        XCTAssertFalse(failed)
        XCTAssertNil(other.refusal)
    }

    func testTheControlActionPostsTheTicketAndThePriority() {
        let action = ControlAction.priority("SHOP-1", priority: .none)
        XCTAssertEqual(action.path, "api/v1/control/priority")
        XCTAssertEqual(action.body as? [String: String], ["issue_identifier": "SHOP-1", "priority": "none"])
        XCTAssertNil(action.moveIdentifier)
        XCTAssertEqual(action.failurePrefix, "Couldn't set SHOP-1 to No priority")
    }

    // MARK: The committed QA fixtures

    private static func director(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/\(name)", isDirectory: true)
    }

    /// Answers the card's send and read from fixture `name`, as the app does in QA mode.
    private func fixtureCalls(_ name: String) -> (
        fixtures: APIFixtures, send: (ControlAction) async -> ControlResult, read: (String) async -> Data?
    ) {
        let fixtures = APIFixtures(directory: Self.director(name), requestLog: uniqueTemporaryDirectory(name).appendingPathComponent("api-requests.jsonl"))
        let send: (ControlAction) async -> ControlResult = { action in
            var request = URLRequest(url: APIFixtures.baseURL.appendingPathComponent(action.path))
            request.httpMethod = "POST"
            request.httpBody = try? JSONSerialization.data(withJSONObject: action.body)
            let (data, response) = fixtures.answer(request)
            return ControlAPI.result(action, statusCode: response.statusCode, data: data)
        }
        let read: (String) async -> Data? = { path in
            let (data, response) = fixtures.answer(URLRequest(url: APIFixtures.baseURL.appendingPathComponent(path)))
            return response.statusCode == 200 ? data : nil
        }
        return (fixtures, send, read)
    }

    func testTheTicketPriorityFixtureShowsLowAndTakesAPick() async {
        let calls = fixtureCalls("ticket-priority")
        let editor = TicketPriorityEditor()
        editor.show("SHOP-320")
        editor.apply(await calls.read(TicketPriorityEditor.path("SHOP-320")), for: "SHOP-320")
        XCTAssertEqual(editor.load, .loaded)
        XCTAssertEqual(editor.priority, .low)

        let made = await editor.set(.urgent, send: calls.send, read: calls.read)
        XCTAssertTrue(made)
        XCTAssertNil(editor.refusal)
        XCTAssertEqual(calls.fixtures.postCount("/api/v1/control/priority"), 1)
    }

    func testTheRefusedFixtureAnswersThePickWithSymphonysReason() async {
        let calls = fixtureCalls("ticket-priority-refused")
        let editor = TicketPriorityEditor()
        editor.show("SHOP-320")
        editor.apply(await calls.read(TicketPriorityEditor.path("SHOP-320")), for: "SHOP-320")

        let made = await editor.set(.urgent, send: calls.send, read: calls.read)

        XCTAssertFalse(made)
        XCTAssertEqual(editor.priority, .low)
        XCTAssertEqual(editor.refusal, "Couldn't set SHOP-320 to Urgent: Symphony doesn't track SHOP-320, so it can't set its priority. (HTTP 409)")
    }
}
