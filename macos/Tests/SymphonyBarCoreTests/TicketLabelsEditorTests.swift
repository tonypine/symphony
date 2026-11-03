import Foundation
import XCTest
@testable import SymphonyBarCore

/// TP-1356: the ticket page's Labels card, from Symphony's labels endpoint to the control it sends.
@MainActor
final class TicketLabelsEditorTests: XCTestCase {
    private final class Calls {
        var sent: [ControlAction] = []
        var reads: [String] = []
    }

    private static let rows: [(String, String, String)] = [
        ("plan", "Plan", "Groom into sub-tickets before any work starts"),
        ("type:bug", "Bug", "The bug steps, and back to Backlog without its sections"),
        ("qa:skip", "Skip QA", "Once approved, it goes on without a QA pass"),
    ]

    private func body(on: [String] = []) -> Data {
        let labels = Self.rows.map { ["label": $0.0, "title": $0.1, "effect": $0.2, "on": on.contains($0.0)] as [String: Any] }
        return try! JSONSerialization.data(withJSONObject: ["issue_identifier": "SHOP-1", "labels": labels])
    }

    private func loaded(on: [String] = []) -> TicketLabelsEditor {
        let editor = TicketLabelsEditor()
        editor.show("SHOP-1")
        editor.apply(body(on: on), for: "SHOP-1")
        return editor
    }

    func testReadsTheTogglesWithTheirEffects() {
        let editor = loaded(on: ["type:bug"])
        XCTAssertEqual(editor.load, .loaded)
        XCTAssertEqual(editor.toggles.map(\.title), ["Plan", "Bug", "Skip QA"])
        XCTAssertEqual(editor.toggles.map(\.on), [false, true, false])
        XCTAssertEqual(editor.toggles[0].effect, "Groom into sub-tickets before any work starts")
        XCTAssertEqual(editor.toggles[0].id, "plan")
        XCTAssertEqual(TicketLabelsEditor.path("SHOP-1"), "api/v1/tickets/SHOP-1/labels")
        XCTAssertEqual(
            TicketLabelsEditor.toggleLabel("SHOP-1", editor.toggles[2]),
            "Skip QA on SHOP-1: Once approved, it goes on without a QA pass"
        )
        XCTAssertEqual(TicketLabelsEditor.sendingTitle(editor.toggles[0]), "Turning on Plan…")
        XCTAssertEqual(TicketLabelsEditor.sendingTitle(editor.toggles[1]), "Turning off Bug…")
        XCTAssertTrue(editor.canToggle("plan"))
        XCTAssertFalse(editor.canToggle("frontend"))
    }

    func testAnUnreadableOrMissingAnswerMakesTheCardUnavailableAndAnotherTicketsAnswerChangesNothing() {
        let editor = loaded()
        editor.apply(body(on: ["plan"]), for: "SHOP-7")
        XCTAssertEqual(editor.toggles.map(\.on), [false, false, false])

        editor.apply(Data(#"{"labels": "plan"}"#.utf8), for: "SHOP-1")
        XCTAssertEqual(editor.load, .unavailable)
        XCTAssertEqual(editor.toggles, [])
        XCTAssertFalse(editor.canToggle("plan"))

        editor.apply(nil, for: "SHOP-1")
        XCTAssertEqual(editor.load, .unavailable)
    }

    func testShowingAnotherTicketStartsItsCardUnread() {
        let editor = loaded()
        editor.show("SHOP-1")
        XCTAssertEqual(editor.load, .loaded)
        editor.show("SHOP-2")
        XCTAssertEqual(editor.identifier, "SHOP-2")
        XCTAssertEqual(editor.load, .unread)
        XCTAssertEqual(editor.toggles, [])
    }

    /// Walkthrough steps 1 and 3: Plan on, then off; the card shows each.
    func testTurningPlanOnThenOffSendsEachAndShowsIt() async {
        let editor = loaded()
        let calls = Calls()

        let on = await editor.set("plan", on: true, send: { calls.sent.append($0); return .done }, read: { path in
            calls.reads.append(path)
            return self.body(on: ["plan"])
        })
        XCTAssertTrue(on)
        XCTAssertTrue(editor.toggles[0].on)
        XCTAssertNil(editor.sending)
        XCTAssertNil(editor.refusal)

        let off = await editor.set("plan", on: false, send: { calls.sent.append($0); return .done }, read: { _ in self.body() })
        XCTAssertTrue(off)
        XCTAssertFalse(editor.toggles[0].on)
        XCTAssertEqual(calls.sent, [
            .label("SHOP-1", label: "plan", title: "Plan", on: true),
            .label("SHOP-1", label: "plan", title: "Plan", on: false),
        ])
        XCTAssertEqual(calls.reads, ["api/v1/tickets/SHOP-1/labels"])
    }

    /// Walkthrough step 2: Skip QA on.
    func testTurningSkipQAOnSendsIt() async {
        let editor = loaded()
        var sent: [ControlAction] = []
        let made = await editor.set("qa:skip", on: true, send: { sent.append($0); return .done }, read: { _ in self.body(on: ["qa:skip"]) })
        XCTAssertTrue(made)
        XCTAssertEqual(sent, [.label("SHOP-1", label: "qa:skip", title: "Skip QA", on: true)])
        XCTAssertTrue(editor.toggles[2].on)
    }

    func testTheSameStateAnUnknownLabelOrAnUnreadCardSendsNothing() async {
        let editor = loaded(on: ["plan"])
        let same = await editor.set("plan", on: true, send: { _ in XCTFail("nothing sent"); return .done }, read: { _ in nil })
        XCTAssertFalse(same)
        let unknown = await editor.set("frontend", on: true, send: { _ in XCTFail("nothing sent"); return .done }, read: { _ in nil })
        XCTAssertFalse(unknown)

        let unread = TicketLabelsEditor()
        unread.show("SHOP-1")
        let sent = await unread.set("plan", on: true, send: { _ in XCTFail("nothing sent"); return .done }, read: { _ in nil })
        XCTAssertFalse(sent)
    }

    func testARefusalSaysWhyAndKeepsTheToggle() async {
        let editor = loaded()
        let action = ControlAction.label("SHOP-1", label: "qa:skip", title: "Skip QA", on: true)
        let answer = ControlAPI.result(
            action, statusCode: 409,
            data: Data(#"{"error":{"code":"move_not_allowed","message":"Symphony doesn't track SHOP-1, so it can't change its labels."}}"#.utf8)
        )

        let made = await editor.set("qa:skip", on: true, send: { _ in answer }, read: { _ in XCTFail("no read after a refusal"); return nil })

        XCTAssertFalse(made)
        XCTAssertFalse(editor.toggles[2].on)
        XCTAssertEqual(editor.refusal, "Couldn't turn on Skip QA on SHOP-1: Symphony doesn't track SHOP-1, so it can't change its labels. (HTTP 409)")
        XCTAssertEqual(TicketLabelsEditor.refusalLabel("x"), "Label not saved: x")
        XCTAssertNil(editor.sending)
    }

    func testAnAnswerAfterThePageMovedOnLeavesTheOtherTicketsCard() async {
        let editor = loaded()
        let made = await editor.set("plan", on: true, send: { _ in editor.show("SHOP-2"); return .done }, read: { _ in XCTFail("no read"); return nil })
        XCTAssertTrue(made)
        XCTAssertEqual(editor.identifier, "SHOP-2")
        XCTAssertEqual(editor.toggles, [])

        let other = loaded()
        let failed = await other.set("plan", on: true, send: { _ in other.show("SHOP-3"); return .failed("no") }, read: { _ in nil })
        XCTAssertFalse(failed)
        XCTAssertNil(other.refusal)
    }

    func testTheControlActionPostsTheTicketTheLabelAndTheChange() {
        let on = ControlAction.label("SHOP-1", label: "qa:skip", title: "Skip QA", on: true)
        XCTAssertEqual(on.path, "api/v1/control/label")
        XCTAssertEqual(on.body as? [String: String], ["issue_identifier": "SHOP-1", "label": "qa:skip", "action": "add"])
        XCTAssertNil(on.moveIdentifier)
        XCTAssertEqual(on.failurePrefix, "Couldn't turn on Skip QA on SHOP-1")

        let off = ControlAction.label("SHOP-1", label: "plan", title: "Plan", on: false)
        XCTAssertEqual(off.body as? [String: String], ["issue_identifier": "SHOP-1", "label": "plan", "action": "remove"])
        XCTAssertEqual(off.failurePrefix, "Couldn't turn off Plan on SHOP-1")
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

    func testTheTicketLabelsFixtureShowsFeatureOnAndTakesPlan() async {
        let calls = fixtureCalls("ticket-labels")
        let editor = TicketLabelsEditor()
        editor.show("SHOP-320")
        editor.apply(await calls.read(TicketLabelsEditor.path("SHOP-320")), for: "SHOP-320")
        XCTAssertEqual(editor.load, .loaded)
        XCTAssertEqual(editor.toggles.map(\.title), [
            "Plan", "Bug", "Feature", "Skip QA", "Skip the app update wait", "QA on the live server", "QA on fixtures", "needs-human",
        ])
        XCTAssertEqual(editor.toggles.filter(\.on).map(\.label), ["type:feature"])

        let made = await editor.set("plan", on: true, send: calls.send, read: calls.read)
        XCTAssertTrue(made)
        XCTAssertNil(editor.refusal)
        XCTAssertEqual(calls.fixtures.postCount("/api/v1/control/label"), 1)
    }

    func testTheRefusedFixtureAnswersTheToggleWithSymphonysReason() async {
        let calls = fixtureCalls("ticket-labels-refused")
        let editor = TicketLabelsEditor()
        editor.show("SHOP-320")
        editor.apply(await calls.read(TicketLabelsEditor.path("SHOP-320")), for: "SHOP-320")

        let made = await editor.set("qa:skip", on: true, send: calls.send, read: calls.read)

        XCTAssertFalse(made)
        XCTAssertFalse(editor.toggles[3].on)
        XCTAssertEqual(editor.refusal, "Couldn't turn on Skip QA on SHOP-320: Symphony doesn't track SHOP-320, so it can't change its labels. (HTTP 409)")
    }
}
