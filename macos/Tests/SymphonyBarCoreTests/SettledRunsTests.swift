import Foundation
@testable import SymphonyBarCore
import XCTest

/// A shipped or cancelled ticket's runs (TP-1477): whatever the feed says, no run of it is drawn as working, pinned
/// on top or unfolded, and its timeline reads newest first.
final class SettledRunsTests: XCTestCase {
    private let reference = ISO8601DateFormatter().date(from: "2026-11-12T13:00:00Z")!

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func event(_ id: String, _ at: String, _ type: String, title: String, runID: String? = nil) -> String {
        let run = runID.map { #", "run_id": "\#($0)""# } ?? ""
        return #"{"id": "\#(id)", "at": "2026-11-12T\#(at)Z", "type": "\#(type)"\#(run), "actor": {"kind": "machine"}, "payload": {}, "summary": {"title": "\#(title)"}}"#
    }

    /// TP-1463's history as an older Symphony served it: Implementation run 1 still reads as running, hours after the
    /// ticket entered Done.
    private func history() throws -> TicketEventsPayload {
        let run = #"""
        {"kind": "run", "run_id": "run-1", "run_kind": "implementation", "run_number": 1, "status": "running",
         "started_at": "2026-11-12T09:38:40Z", "events": [
           \#(event("e1", "09:38:40", "run.started", title: "Implementation run 1 started", runID: "run-1")),
           \#(event("e2", "10:00:09", "step.completed", title: "Tests and coverage passed", runID: "run-1"))
         ]}
        """#
        let done = event("e3", "12:07:58", "phase.entered", title: "Entered Done")
        return try XCTUnwrap(TicketEventsPayload.decode(Data(#"{"timeline": [\#(run), \#(done)]}"#.utf8)))
    }

    private func page(situation kind: String, events: TicketEventsPayload) -> TicketPage {
        let issue = Data(#"{"issue_identifier": "TP-1463", "situation": {"kind": "\#(kind)", "cause": "Merged."}}"#.utf8)
        return TicketPage(identifier: "TP-1463", sources: TicketPage.Sources(issue: issue, events: events), now: reference)
    }

    func testOnAShippedTicketTheRunIsFoldedInItsPlaceWithAFixedDurationAndNothingSaysRunning() throws {
        let page = page(situation: "done", events: try history())
        let run = try XCTUnwrap(page.history?.runs["run-1"])
        XCTAssertEqual(run.status, "ended")
        XCTAssertEqual(run.endedAt, "2026-11-12T10:00:09Z")
        XCTAssertEqual(run.exit, TicketEventsPayload.unrecordedExit)

        let model = TimelineModel.build(try XCTUnwrap(page.history), reference: reference, calendar: utc)
        // Newest first: Entered Done, then the run, in its place in time.
        XCTAssertEqual(model.items.map(\.id), ["entry-e3", "run-run-1"])
        XCTAssertNil(model.runNow)
        let group = try XCTUnwrap(model.run("run-1"))
        XCTAssertFalse(group.isLive)
        XCTAssertFalse(group.opensByDefault)
        XCTAssertEqual(group.duration, "21 min")
        XCTAssertEqual(group.word, "Ended; no end was recorded")
        // The older step list reads the same history.
        XCTAssertFalse(page.timeline.contains { $0.resultWord == "running" })
    }

    func testOnACancelledTicketTheRunIsClosedToo() throws {
        let page = page(situation: "cancelled", events: try history())
        XCTAssertEqual(page.history?.runs["run-1"]?.status, "ended")
    }

    func testOnATicketStillMovingTheFeedSaysWhichRunWorks() throws {
        let page = page(situation: "working", events: try history())
        XCTAssertEqual(page.history?.runs["run-1"]?.status, "running")
        XCTAssertTrue(try XCTUnwrap(TimelineModel.build(try XCTUnwrap(page.history), reference: reference, calendar: utc).runNow).isLive)
    }

    func testARunWithNoEventsEndsAtItsStartAndKeepsAnEndItRecorded() {
        var history = TicketEventsPayload()
        history.merge(TicketEventsPayload.decode(Data(#"""
        {"timeline": [
          {"kind": "run", "run_id": "a", "status": "running", "started_at": "2026-11-12T09:00:00Z", "events": []},
          {"kind": "run", "run_id": "b", "status": "running", "started_at": "2026-11-12T09:00:00Z",
           "ended_at": "2026-11-12T09:05:00Z", "exit": "handoff", "events": []},
          {"kind": "run", "run_id": "c", "status": "ended", "exit": "handoff", "events": []}
        ]}
        """#.utf8))!)
        let closed = history.closingLiveRuns()
        XCTAssertEqual(closed.runs["a"]?.endedAt, "2026-11-12T09:00:00Z")
        XCTAssertEqual(closed.runs["a"]?.exit, TicketEventsPayload.unrecordedExit)
        XCTAssertEqual(closed.runs["b"]?.endedAt, "2026-11-12T09:05:00Z")
        XCTAssertEqual(closed.runs["b"]?.exit, "handoff")
        XCTAssertEqual(closed.runs["c"], history.runs["c"])
    }
}
