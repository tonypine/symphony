@testable import SymphonyBarCore
import XCTest

/// Symphony's own wait and status notes between runs (`Tests/Fixtures/timeline/wait-notes.json`): a note whose `status`
/// says it is one folds behind "Show all events"; a person's note, and one recorded before notes carried the field, are
/// drawn as they were.
final class StatusNoteTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/timeline/wait-notes.json")

    private let reference = ISO8601DateFormatter().date(from: "2026-10-08T10:27:00Z")!

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func history() throws -> TicketEventsPayload { try XCTUnwrap(TicketEventsPayload.decode(Data(contentsOf: Self.fixture))) }

    private func note(_ payload: String, actor: String?) throws -> (TicketEventsPayload.Event, TicketEventsPayload) {
        let who = actor.map { #","actor":{"kind":"\#($0)"}"# } ?? ""
        let page = #"{"timeline":[{"id":"n1","at":"2026-10-08T09:01:00Z","type":"note"\#(who),"payload":\#(payload),"artifacts":[],"children":[]}]}"#
        let history = try XCTUnwrap(TicketEventsPayload.decode(Data(page.utf8)))
        return (history.events[0], history)
    }

    func testAWaitNoteFoldsAndShowAllEventsListsIt() throws {
        let model = TimelineModel.build(try history(), reference: reference, calendar: utc)
        let folded = model.showing(allEvents: false).items.map(\.id)
        XCTAssertFalse(folded.contains("entry-w2"), "the PR head sync's wait")
        XCTAssertFalse(folded.contains("entry-w3"), "the CI wait")
        XCTAssertTrue(folded.contains("entry-w1"))
        XCTAssertTrue(folded.contains("entry-w4"), "a person's note")
        let all = model.showing(allEvents: true).items.map(\.id)
        XCTAssertTrue(all.contains("entry-w2"))
        XCTAssertTrue(all.contains("entry-w3"))
        XCTAssertEqual(model.mechanicalCount, 2)
    }

    /// The Director QA fixture `director-app/ticket-waiting-ci`: SHOP-410's pull request waits on CI, with Symphony's two
    /// marked wait notes, an older unmarked one and a person's note.
    func testTheWaitingForCIFixtureFoldsItsWaitNotesAndSaysItWaitsForCI() throws {
        let api = Self.fixture.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("director-app/ticket-waiting-ci/api/v1")
        let feed = try Data(contentsOf: api.appendingPathComponent("repos/web-shop/tickets/SHOP-410/events.json"))
        let page = TicketPage(
            identifier: "SHOP-410",
            sources: TicketPage.Sources(
                state: try Data(contentsOf: api.appendingPathComponent("state.json")),
                issue: try Data(contentsOf: api.appendingPathComponent("SHOP-410.json")),
                events: try XCTUnwrap(TicketEventsPayload.decode(feed))
            ),
            timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertEqual(page.situation?.kind, .ci)
        XCTAssertEqual(page.situation?.word, "Waiting for CI")
        XCTAssertTrue(page.acceptsNotes)

        let model = page.timelineModel(calendar: utc)
        let folded = model.showing(allEvents: false).items.map(\.id)
        XCTAssertFalse(folded.contains("entry-ev-31"), "the PR head sync's wait")
        XCTAssertFalse(folded.contains("entry-ev-32"), "the CI wait")
        XCTAssertTrue(folded.contains("entry-ev-30"), "a wait note recorded before notes carried status")
        XCTAssertTrue(folded.contains("entry-ev-12"), "a person's note")
        let all = model.showing(allEvents: true).items.map(\.id)
        XCTAssertTrue(all.contains("entry-ev-31"))
        XCTAssertTrue(all.contains("entry-ev-32"))
    }

    func testTheFieldDecidesNeverTheWords() throws {
        let (status, statusHistory) = try note(#"{"text":"Anything at all","status":true}"#, actor: "machine")
        XCTAssertTrue(status.payload.isStatus)
        XCTAssertTrue(TimelineModel.isMachineNote(status, history: statusHistory))

        let (unmarked, unmarkedHistory) = try note(#"{"text":"Waiting for CI · sha 1a2b3c4d (ci_wait_started)","signal":"ci_wait_started"}"#, actor: "machine")
        XCTAssertFalse(unmarked.payload.isStatus)
        XCTAssertFalse(TimelineModel.isMachineNote(unmarked, history: unmarkedHistory), "a wait note recorded before notes carried status")

        let (no, noHistory) = try note(#"{"text":"Waiting for CI","status":false}"#, actor: "machine")
        XCTAssertFalse(TimelineModel.isMachineNote(no, history: noHistory))
    }

    func testAPersonsNoteIsNeverFolded() throws {
        let (person, history) = try note(#"{"text":"Waiting for CI","status":true}"#, actor: "person")
        XCTAssertFalse(TimelineModel.isMachineNote(person, history: history))
        let (agent, agentHistory) = try note(#"{"text":"I waited for CI and it passed."}"#, actor: "agent")
        XCTAssertFalse(TimelineModel.isMachineNote(agent, history: agentHistory))
    }
}
