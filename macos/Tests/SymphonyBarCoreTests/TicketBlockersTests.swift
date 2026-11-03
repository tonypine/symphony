import Foundation
import XCTest
@testable import SymphonyBarCore

/// TP-1354: the ticket page's Blocked by card, from Symphony's blockers endpoint to the control it sends.
@MainActor
final class TicketBlockersTests: XCTestCase {
    private final class Calls {
        var sent: [ControlAction] = []
        var reads: [String] = []
    }

    private func body(blockers: [(String, String?, String?)], candidates: [(String, String?, String?)] = []) -> Data {
        func item(_ ticket: (String, String?, String?)) -> [String: Any] {
            var item: [String: Any] = ["issue_identifier": ticket.0]
            if let title = ticket.1 { item["title"] = title }
            if let state = ticket.2 { item["state"] = state }
            return item
        }
        let payload: [String: Any] = ["issue_identifier": "SHOP-1", "blockers": blockers.map(item), "candidates": candidates.map(item)]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func loaded(_ data: Data? = nil) -> TicketBlockersEditor {
        let editor = TicketBlockersEditor()
        editor.show("SHOP-1")
        editor.apply(data ?? body(blockers: [], candidates: [("SHOP-2", "Fix the exporter", "In Progress"), ("SHOP-3", "Rename", "Todo")]), for: "SHOP-1")
        return editor
    }

    func testReadsTheBlockersAndTheTicketsItCanTake() {
        let editor = loaded(body(blockers: [("SHOP-2", "Fix the exporter", "In Progress"), ("EXT-9", nil, nil)], candidates: [("SHOP-3", "Rename", "Todo")]))

        XCTAssertEqual(editor.load, .loaded)
        XCTAssertEqual(editor.blockers, [
            .init(identifier: "SHOP-2", title: "Fix the exporter", state: "In Progress"),
            .init(identifier: "EXT-9"),
        ])
        XCTAssertEqual(editor.candidates, [.init(identifier: "SHOP-3", title: "Rename", state: "Todo")])
        XCTAssertEqual(editor.blockers[0].accessibilityLabel, "SHOP-2 Fix the exporter, In Progress")
        XCTAssertEqual(editor.blockers[1].accessibilityLabel, "EXT-9")
        XCTAssertEqual(TicketBlockersEditor.path("SHOP-1"), "api/v1/tickets/SHOP-1/blockers")
    }

    func testAnUnreadableOrMissingAnswerMakesTheCardUnavailableAndAnotherTicketsAnswerChangesNothing() {
        let editor = loaded()
        editor.apply(body(blockers: [("SHOP-9", nil, nil)]), for: "SHOP-7")
        XCTAssertEqual(editor.blockers, [])
        XCTAssertEqual(editor.load, .loaded)

        editor.apply(nil, for: "SHOP-1")
        XCTAssertEqual(editor.load, .unavailable)
        XCTAssertEqual(editor.candidates, [])

        editor.apply(Data("not json".utf8), for: "SHOP-1")
        XCTAssertEqual(editor.load, .unavailable)
    }

    func testShowingAnotherTicketStartsItsCardUnread() {
        let editor = loaded()
        editor.entry = "SHOP-2"
        editor.show("SHOP-1")
        XCTAssertEqual(editor.entry, "SHOP-2")

        editor.show("SHOP-5")
        XCTAssertEqual(editor.identifier, "SHOP-5")
        XCTAssertEqual(editor.load, .unread)
        XCTAssertEqual(editor.entry, "")
        XCTAssertEqual(editor.candidates, [])
    }

    func testSuggestionsMatchTheIdentifierOrTitleTyped() {
        let editor = loaded()
        XCTAssertEqual(editor.suggestions.map(\.identifier), ["SHOP-2", "SHOP-3"])
        editor.entry = "export"
        XCTAssertEqual(editor.suggestions.map(\.identifier), ["SHOP-2"])
        editor.entry = " shop-3 "
        XCTAssertEqual(editor.suggestions.map(\.identifier), ["SHOP-3"])
    }

    func testAddingABlockerSendsTheLinkThenReadsTheCardAgain() async {
        let editor = loaded()
        let calls = Calls()
        editor.entry = " SHOP-2 "
        XCTAssertTrue(editor.canAdd)

        let made = await editor.add(send: { action in
            calls.sent.append(action)
            return .done
        }, read: { path in
            calls.reads.append(path)
            return self.body(blockers: [("SHOP-2", "Fix the exporter", "In Progress")], candidates: [("SHOP-3", "Rename", "Todo")])
        })

        XCTAssertTrue(made)
        XCTAssertEqual(calls.sent, [.blocker("SHOP-1", blocker: "SHOP-2", add: true)])
        XCTAssertEqual(calls.reads, ["api/v1/tickets/SHOP-1/blockers"])
        XCTAssertEqual(editor.blockers.map(\.identifier), ["SHOP-2"])
        XCTAssertEqual(editor.entry, "")
        XCTAssertFalse(editor.sending)
        XCTAssertNil(editor.refusal)
    }

    func testAPickFromTheMenuAddsItAndKeepsWhatIsTyped() async {
        let editor = loaded()
        let calls = Calls()
        editor.entry = "SHOP-9"
        let made = await editor.add("SHOP-3", send: { calls.sent.append($0); return .done }, read: { _ in nil })
        XCTAssertTrue(made)
        XCTAssertEqual(calls.sent, [.blocker("SHOP-1", blocker: "SHOP-3", add: true)])
        XCTAssertEqual(editor.entry, "SHOP-9")
    }

    func testRemovingABlockerSendsTheUnlink() async {
        let editor = loaded(body(blockers: [("SHOP-2", nil, nil)]))
        let calls = Calls()
        let made = await editor.remove("SHOP-2", send: { calls.sent.append($0); return .done }, read: { _ in self.body(blockers: []) })
        XCTAssertTrue(made)
        XCTAssertEqual(calls.sent, [.blocker("SHOP-1", blocker: "SHOP-2", add: false)])
        XCTAssertEqual(editor.blockers, [])
    }

    /// Walkthrough step 3: the ticket as its own blocker is refused, and the card says why.
    func testARefusalSaysWhyAndKeepsTheField() async {
        let editor = loaded()
        editor.entry = "SHOP-1"
        let action = ControlAction.blocker("SHOP-1", blocker: "SHOP-1", add: true)
        let answer = ControlAPI.result(
            action, statusCode: 409, data: Data(#"{"error":{"code":"move_not_allowed","message":"SHOP-1 can't block itself."}}"#.utf8)
        )

        let made = await editor.add(send: { _ in answer }, read: { _ in XCTFail("no read after a refusal"); return nil })

        XCTAssertFalse(made)
        XCTAssertEqual(editor.refusal, "Couldn't add SHOP-1 as a blocker of SHOP-1: SHOP-1 can't block itself. (HTTP 409)")
        XCTAssertEqual(
            TicketBlockersEditor.refusalLabel(editor.refusal!),
            "Blocker not saved: Couldn't add SHOP-1 as a blocker of SHOP-1: SHOP-1 can't block itself. (HTTP 409)"
        )
        XCTAssertEqual(editor.entry, "SHOP-1")
        XCTAssertFalse(editor.sending)
    }

    func testNothingIsSentBeforeTheCardIsReadOrWithNothingTyped() async {
        let unread = TicketBlockersEditor()
        unread.show("SHOP-1")
        unread.entry = "SHOP-2"
        XCTAssertFalse(unread.canAdd)
        let sent = await unread.add(send: { _ in XCTFail("sent"); return .done }, read: { _ in nil })
        XCTAssertFalse(sent)
        let removed = await unread.remove("SHOP-2", send: { _ in XCTFail("sent"); return .done }, read: { _ in nil })
        XCTAssertFalse(removed)

        let editor = loaded()
        editor.entry = "  "
        XCTAssertFalse(editor.canAdd)
        let blank = await editor.add(send: { _ in XCTFail("sent"); return .done }, read: { _ in nil })
        XCTAssertFalse(blank)
    }

    func testAnAnswerAfterThePageMovedOnLeavesTheNewCardAlone() async {
        let editor = loaded()
        let made = await editor.add("SHOP-2", send: { _ in
            editor.show("SHOP-8")
            return .failed("refused")
        }, read: { _ in XCTFail("read"); return nil })
        XCTAssertFalse(made)
        XCTAssertNil(editor.refusal)
        XCTAssertEqual(editor.identifier, "SHOP-8")

        let other = loaded()
        let done = await other.add("SHOP-2", send: { _ in other.show("SHOP-8"); return .done }, read: { _ in nil })
        XCTAssertTrue(done)
    }

    func testTheControlRequest() throws {
        let add = ControlAction.blocker("SHOP-1", blocker: "SHOP-2", add: true)
        let remove = ControlAction.blocker("SHOP-1", blocker: "SHOP-2", add: false)
        XCTAssertEqual(add.path, "api/v1/control/blocker")
        XCTAssertNil(add.moveIdentifier)
        XCTAssertEqual(add.body as? [String: String], ["issue_identifier": "SHOP-1", "blocker": "SHOP-2", "action": "add"])
        XCTAssertEqual(remove.body as? [String: String], ["issue_identifier": "SHOP-1", "blocker": "SHOP-2", "action": "remove"])
        XCTAssertEqual(remove.failurePrefix, "Couldn't remove SHOP-2 as a blocker of SHOP-1")
        XCTAssertEqual(ControlAPI.result(add, statusCode: 200, data: Data(#"{"action":"add","blockers":[]}"#.utf8)), .done)
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

    func testTheTicketBlockersFixtureShowsABlockerAndTicketsToPick() async {
        let calls = fixtureCalls("ticket-blockers")
        let editor = TicketBlockersEditor()
        editor.show("SHOP-320")
        editor.apply(await calls.read(TicketBlockersEditor.path("SHOP-320")), for: "SHOP-320")

        XCTAssertEqual(editor.load, .loaded)
        XCTAssertEqual(editor.blockers, [.init(identifier: "SHOP-305", title: "Checkout total rounding", state: "In Progress")])
        XCTAssertEqual(editor.suggestions.map(\.identifier), ["API-131", "API-133", "API-127", "SHOP-301", "SHOP-290", "DOCS-40"])

        editor.entry = "API-133"
        let made = await editor.add(send: calls.send, read: calls.read)
        XCTAssertTrue(made)
        XCTAssertNil(editor.refusal)
        XCTAssertEqual(editor.entry, "")
        let removed = await editor.remove("SHOP-305", send: calls.send, read: calls.read)
        XCTAssertTrue(removed)
    }

    func testTheRefusedFixtureAnswersTheAddWithSymphonysReason() async {
        let calls = fixtureCalls("ticket-blockers-refused")
        let editor = TicketBlockersEditor()
        editor.show("SHOP-320")
        editor.apply(await calls.read(TicketBlockersEditor.path("SHOP-320")), for: "SHOP-320")
        editor.entry = "SHOP-320"

        let made = await editor.add(send: calls.send, read: calls.read)

        XCTAssertFalse(made)
        XCTAssertEqual(editor.refusal, "Couldn't add SHOP-320 as a blocker of SHOP-320: SHOP-320 can't block itself. (HTTP 409)")
        XCTAssertEqual(editor.entry, "SHOP-320")
    }
}
