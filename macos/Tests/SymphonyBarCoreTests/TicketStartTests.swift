import XCTest
@testable import SymphonyBarCore

/// Start now (TP-1330): the ticket's `start` read from the ticket and state payloads, the button's tooltip, the request
/// it sends and Symphony's refusal in its words.
final class TicketStartTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:4010")!

    private static func fixture(_ dir: String, _ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/\(dir)/api/v1/\(name).json"))
    }

    // MARK: - The payloads

    func testTheTicketPayloadsStartWinsOverItsStateEntry() {
        let issue = Data(#"{"start":{"allowed":false,"reason":"a Question is waiting for an answer"}}"#.utf8)
        let state = Data(#"{"slot_waiting":[{"issue_identifier":"SHOP-320","start":{"allowed":true,"reason":null}}]}"#.utf8)

        XCTAssertEqual(
            TicketStart.of("SHOP-320", issue: issue, state: state),
            TicketStart(allowed: false, reason: "a Question is waiting for an answer")
        )
        // A ticket payload without `start` falls back to the state's entry.
        XCTAssertEqual(TicketStart.of("SHOP-320", issue: Data("{}".utf8), state: state), TicketStart(allowed: true))
        XCTAssertEqual(TicketStart.of("SHOP-320", issue: nil, state: state), TicketStart(allowed: true))
    }

    func testEachStateListCarriesItsTicketsStartTheFirstEntryWinning() {
        let state = Data(#"""
        {"running":[{"issue_identifier":"A-1","start":{"allowed":false,"reason":"a run is already working on the ticket"}}],
         "retrying":[{"issue_identifier":"A-2","start":{"allowed":true}}],
         "watching":[{"issue_identifier":"A-3","start":{"allowed":true,"reason":"  "}},
                     {"issue_identifier":"A-1","start":{"allowed":true}}],
         "slot_waiting":[{"issue_identifier":"A-4","start":{"allowed":true}}, {"start":{"allowed":true}},
                         {"issue_identifier":"A-6","start":{"reason":"no allowed"}}],
         "dispatch_skipped":[{"issue_identifier":"A-5","start":{"allowed":false,"reason":"the ticket is in Backlog; move it first"}},
                             {"issue_identifier":"A-7"}]}
        """#.utf8)

        XCTAssertEqual(TicketStart.byIdentifier(inState: state), [
            "A-1": TicketStart(allowed: false, reason: "a run is already working on the ticket"),
            "A-2": TicketStart(allowed: true),
            // A blank reason reads as none.
            "A-3": TicketStart(allowed: true),
            "A-4": TicketStart(allowed: true),
            "A-5": TicketStart(allowed: false, reason: "the ticket is in Backlog; move it first"),
        ])
    }

    func testASymphonyWithoutStartOffersNone() {
        // One that predates TP-1329, no state yet, and one that doesn't read.
        XCTAssertEqual(TicketStart.byIdentifier(inState: Data(#"{"running":[{"issue_identifier":"A-1"}]}"#.utf8)), [:])
        XCTAssertEqual(TicketStart.byIdentifier(inState: nil), [:])
        XCTAssertEqual(TicketStart.byIdentifier(inState: Data("not json".utf8)), [:])
        XCTAssertNil(TicketStart.of("A-1", issue: Data("not json".utf8), state: nil))
    }

    func testTheFixtureWithEverySlotBusyLetsTheWaitingTodoTicketStart() throws {
        let state = try Self.fixture("start-now", "state")
        let page = TicketPage(
            identifier: "SHOP-320",
            sources: TicketPage.Sources(state: state, issue: try Self.fixture("start-now", "SHOP-320"))
        )

        XCTAssertEqual(page.start, TicketStart(allowed: true))
        XCTAssertFalse(page.isRunning)
        let starts = TicketStart.byIdentifier(inState: state)
        // Every slot is busy: each running ticket already has its run.
        for identifier in ["SHOP-305", "API-131", "SHOP-298"] {
            XCTAssertEqual(starts[identifier], TicketStart(allowed: false, reason: "a run is already working on the ticket"))
        }
    }

    func testOnAPausedSymphonyEveryTicketsStartNamesThePause() throws {
        let state = try Self.fixture("start-now-paused", "state")
        let page = TicketPage(
            identifier: "SHOP-320",
            sources: TicketPage.Sources(state: state, issue: try Self.fixture("start-now-paused", "SHOP-320"))
        )
        let start = try XCTUnwrap(page.start)

        XCTAssertFalse(start.allowed)
        XCTAssertEqual(start.help("SHOP-320"), "Dispatch is paused by the operator: Deploy freeze")
        XCTAssertTrue(TicketStart.byIdentifier(inState: state).values.allSatisfy { !$0.allowed })
    }

    // MARK: - The button

    func testTheTooltipSaysWhatItDoesOrSymphonysReason() {
        XCTAssertEqual(
            TicketStart(allowed: true).help("SHOP-320"),
            "Start SHOP-320's run now, ahead of the queue; the other tickets keep their order"
        )
        XCTAssertEqual(TicketStart(allowed: true).accessibilityLabel("SHOP-320"), "Start SHOP-320 now")

        // Each reason Symphony refuses with, capitalized.
        let reasons = [
            "dispatch is paused by the operator: Deploy freeze": "Dispatch is paused by the operator: Deploy freeze",
            "the repository is paused by you": "The repository is paused by you",
            "a Question is waiting for an answer": "A Question is waiting for an answer",
            "a run is already working on the ticket": "A run is already working on the ticket",
            "the ticket is in Backlog; move it first": "The ticket is in Backlog; move it first",
        ]
        for (reason, help) in reasons {
            let start = TicketStart(allowed: false, reason: reason)
            XCTAssertEqual(start.help("SHOP-320"), help)
            XCTAssertEqual(start.accessibilityLabel("SHOP-320"), "Start SHOP-320 now, unavailable: \(help)")
        }
        XCTAssertEqual(TicketStart(allowed: false).help("SHOP-320"), "Symphony won't start SHOP-320 now")
    }

    // MARK: - The request and the answer

    func testTheButtonPostsTheStartForTheTicket() throws {
        let action = TicketStart.action("SHOP-320")
        let request = ControlAPI.request(action, base: base, token: "t")

        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:4010/api/v1/control/start")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]),
            ["issue_identifier": "SHOP-320"]
        )
        XCTAssertEqual(ControlAction.start("SHOP-320", note: "unblock").body as? [String: String], ["issue_identifier": "SHOP-320", "note": "unblock"])
        // Not a move: Symphony's answer carries no `moved`.
        XCTAssertNil(action.moveIdentifier)
    }

    func testSymphonysAnswerIsDoneOrItsRefusalInItsWords() {
        let action = TicketStart.action("SHOP-320")

        XCTAssertEqual(
            ControlAPI.result(action, statusCode: 200, data: Data(#"{"started":true,"run_id":"run-320","session_id":null}"#.utf8)),
            .done
        )
        XCTAssertEqual(
            ControlAPI.result(
                action, statusCode: 409,
                data: Data(#"{"error":{"code":"start_not_allowed","message":"dispatch is paused by the operator"}}"#.utf8)
            ),
            .failed("Couldn't start SHOP-320 now: dispatch is paused by the operator (HTTP 409)")
        )
    }
}
