import Foundation
import XCTest
@testable import SymphonyBarCore

/// TP-1357: the ticket page's Decisions card, from Symphony's decisions endpoint to the ruling it sends.
@MainActor
final class TicketDecisionsEditorTests: XCTestCase {
    private final class Calls {
        var sent: [ControlAction] = []
        var reads: [String] = []
    }

    private static let answer: [String: Any] = [
        "id": "D1", "date": "2026-11-01", "title": "Scope", "question": "Ship CSV too?", "answer": "Yes, ship CSV", "scope": "In scope",
    ]

    private func body(_ answers: [String] = []) -> Data {
        var decisions = [Self.answer]
        for (index, answer) in answers.enumerated() {
            decisions.append([
                "id": "D\(index + 2)", "date": "2026-11-03", "title": "Ruling by the Director",
                "question": "No question asked: the Director recorded this ruling on the ticket page.", "answer": answer, "scope": "As answered",
            ])
        }
        return try! JSONSerialization.data(withJSONObject: ["issue_identifier": "SHOP-1", "decisions": decisions])
    }

    private func loaded() -> TicketDecisionsEditor {
        let editor = TicketDecisionsEditor()
        editor.show("SHOP-1")
        editor.apply(body(), for: "SHOP-1")
        return editor
    }

    func testReadsTheDecisions() {
        let editor = loaded()
        XCTAssertEqual(editor.load, .loaded)
        XCTAssertEqual(editor.decisions, [
            TicketDecision(id: "D1", date: "2026-11-01", title: "Scope", question: "Ship CSV too?", answer: "Yes, ship CSV", scope: "In scope"),
        ])
        XCTAssertEqual(TicketDecisionsEditor.path("SHOP-1"), "api/v1/tickets/SHOP-1/decisions")
        XCTAssertEqual(TicketDecisionsEditor.path("SHOP 1/x"), "api/v1/tickets/SHOP%201%2Fx/decisions")
        XCTAssertEqual(TicketDecisionsEditor.rowLabel(editor.decisions[0]), "D1, 2026-11-01: Yes, ship CSV")
        XCTAssertEqual(TicketDecisionsEditor.rowLabel(TicketDecision(id: "D2", answer: "Keep it")), "D2: Keep it")
        XCTAssertEqual(TicketDecisionsEditor.fieldLabel("SHOP-1"), "Decision on SHOP-1")
        XCTAssertEqual(TicketDecisionsEditor.buttonLabel("SHOP-1"), "Record a decision on SHOP-1")
        XCTAssertEqual(TicketDecisionsEditor.refusalLabel("No."), "Decision not recorded: No.")
        XCTAssertEqual(TicketDecisionsEditor.buttonTitle, "Record a decision")
    }

    func testAnUnreadableOrMissingAnswerMakesTheCardUnavailableAndAnotherTicketsAnswerChangesNothing() {
        let editor = loaded()
        editor.apply(body(["Other"]), for: "SHOP-7")
        XCTAssertEqual(editor.decisions.count, 1)

        editor.apply(Data(#"{"decisions": "D1"}"#.utf8), for: "SHOP-1")
        XCTAssertEqual(editor.load, .unavailable)
        XCTAssertEqual(editor.decisions, [])
        editor.text = "Keep it"
        XCTAssertFalse(editor.canRecord)

        editor.apply(nil, for: "SHOP-1")
        XCTAssertEqual(editor.load, .unavailable)
    }

    func testShowingAnotherTicketStartsItsCardUnreadAndEmpty() {
        let editor = loaded()
        editor.text = "Keep it"
        editor.show("SHOP-1")
        XCTAssertEqual(editor.text, "Keep it")
        editor.show("SHOP-2")
        XCTAssertEqual(editor.identifier, "SHOP-2")
        XCTAssertEqual(editor.load, .unread)
        XCTAssertEqual(editor.decisions, [])
        XCTAssertEqual(editor.text, "")
    }

    /// Walkthrough step 1: "Record a decision" with the ruling; the card's Decisions list shows it.
    func testRecordingARulingSendsItClearsTheFieldAndShowsIt() async {
        let editor = loaded()
        let calls = Calls()
        let ruling = "Keep the old endpoint until TP-1400 lands"
        editor.text = "  \(ruling)\n"
        XCTAssertTrue(editor.canRecord)

        let recorded = await editor.record(send: { calls.sent.append($0); return .done }, read: { path in
            calls.reads.append(path)
            return self.body([ruling])
        })

        XCTAssertTrue(recorded)
        XCTAssertEqual(calls.sent, [.decision("SHOP-1", text: ruling)])
        XCTAssertEqual(calls.reads, ["api/v1/tickets/SHOP-1/decisions"])
        XCTAssertEqual(editor.text, "")
        XCTAssertFalse(editor.sending)
        XCTAssertNil(editor.refusal)
        XCTAssertEqual(editor.decisions.map(\.answer), ["Yes, ship CSV", ruling])
        XCTAssertEqual(editor.decisions.last?.id, "D2")
    }

    func testABlankRulingSendsNothing() async {
        let editor = loaded()
        let calls = Calls()
        editor.text = "  \n "
        XCTAssertFalse(editor.canRecord)

        let recorded = await editor.record(send: { calls.sent.append($0); return .done }, read: { _ in nil })
        XCTAssertFalse(recorded)
        XCTAssertEqual(calls.sent, [])
    }

    func testATooLongRulingIsRefusedHere() async {
        let editor = loaded()
        let calls = Calls()
        editor.text = String(repeating: "a", count: TicketDecisionsEditor.maxLength + 1)

        let recorded = await editor.record(send: { calls.sent.append($0); return .done }, read: { _ in nil })
        XCTAssertFalse(recorded)
        XCTAssertEqual(calls.sent, [])
        XCTAssertEqual(editor.refusal, "A decision holds at most 600 characters; this one has 601")
        XCTAssertNil(TicketDecisionsEditor.tooLong("short"))
    }

    func testARefusalKeepsTheTextAndSaysWhy() async {
        let editor = loaded()
        editor.text = "Yes, ship CSV"
        let reason = "Couldn't record the decision on SHOP-1: SHOP-1 already has this decision (D1)."

        let recorded = await editor.record(send: { _ in .failed(reason) }, read: { _ in XCTFail("no read after a refusal"); return nil })
        XCTAssertFalse(recorded)
        XCTAssertEqual(editor.refusal, reason)
        XCTAssertEqual(editor.text, "Yes, ship CSV")
        XCTAssertFalse(editor.sending)
    }

    func testTextTypedWhileTheRulingWasOnItsWayStays() async {
        let editor = loaded()
        editor.text = "Keep it"

        let recorded = await editor.record(send: { _ in editor.text = "Keep it, and drop CSV"; return .done }, read: { _ in self.body(["Keep it"]) })
        XCTAssertTrue(recorded)
        XCTAssertEqual(editor.text, "Keep it, and drop CSV")
    }

    func testAnAnswerForATicketNoLongerShownChangesNothingThere() async {
        let editor = loaded()
        editor.text = "Keep it"

        let done = await editor.record(send: { _ in editor.show("SHOP-2"); return .done }, read: { _ in XCTFail("no read for another ticket"); return nil })
        XCTAssertTrue(done)
        XCTAssertEqual(editor.identifier, "SHOP-2")
        XCTAssertEqual(editor.load, .unread)

        let other = loaded()
        other.text = "Keep it"
        let failed = await other.record(send: { _ in other.show("SHOP-3"); return .failed("No") }, read: { _ in nil })
        XCTAssertFalse(failed)
        XCTAssertNil(other.refusal)
    }

    /// The QA fixtures read as the card's decisions, before and after the ruling.
    func testTheQAFixturesReadAsTheCard() throws {
        let api = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/ticket-decisions/api/v1", isDirectory: true)
        let editor = TicketDecisionsEditor()
        editor.show("SHOP-320")
        editor.apply(try Data(contentsOf: api.appendingPathComponent("tickets/SHOP-320/decisions.json")), for: "SHOP-320")
        XCTAssertEqual(editor.decisions.map(\.id), ["D1"])
        editor.apply(try Data(contentsOf: api.appendingPathComponent("control/decision.json")), for: "SHOP-320")
        XCTAssertEqual(editor.decisions.map(\.answer).last, "Keep the old endpoint until TP-1400 lands")
    }

    func testTheControlActionPostsTheRuling() {
        let action = ControlAction.decision("SHOP-1", text: "Keep it")
        XCTAssertEqual(action.path, "api/v1/control/decision")
        XCTAssertEqual(action.body as? [String: String], ["issue_identifier": "SHOP-1", "text": "Keep it"])
        XCTAssertEqual(action.failurePrefix, "Couldn't record the decision on SHOP-1")
        XCTAssertNil(action.moveIdentifier)
    }
}
