import Foundation
@testable import SymphonyBarCore
import XCTest

/// The quieter timeline: the entries that restate the runs and moves around them fold behind "Show all events", a
/// resolved finding says so on its card, and a note reads whole.
final class TimelineQuietTests: XCTestCase {
    private let reference = ISO8601DateFormatter().date(from: "2026-11-18T12:00:00Z")!
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func event(
        _ id: String, _ type: String, _ at: String, title: String, payload: String = "{}", run: String? = nil, actor: String = #"{"kind":"machine"}"#
    ) -> String {
        let runID = run.map { #","run_id":"\#($0)""# } ?? ""
        return #"{"id":"\#(id)","at":"2026-11-18T\#(at)Z","type":"\#(type)"\#(runID),"actor":\#(actor),"payload":\#(payload),"summary":{"title":"\#(title)"},"artifacts":[],"children":[]}"#
    }

    private func history(_ entries: [String]) -> TicketEventsPayload {
        let run = #"{"kind":"run","run_id":"qa-2","run_kind":"qa","run_number":2,"status":"ended","started_at":"2026-11-18T10:00:00Z","events":[]}"#
        let page = #"{"timeline":[\#((entries + [run]).joined(separator: ","))]}"#
        var history = TicketEventsPayload()
        history.merge(TicketEventsPayload.decode(Data(page.utf8))!)
        return history
    }

    private func model(_ entries: [String]) -> TimelineModel {
        TimelineModel.build(history(entries), reference: reference, calendar: calendar)
    }

    private func titles(_ model: TimelineModel) -> [String] {
        model.items.compactMap { item in
            if case let .entry(entry) = item { return entry.title }
            return nil
        }
    }

    func testTheMechanicalEntriesFoldBehindShowAllEvents() {
        let all = model([
            event("1", "phase.entered", "09:00:00", title: "Entered QA from Code Review", payload: #"{"from":"Code Review","to":"QA"}"#),
            event("2", "workspace.synced", "09:01:00", title: "Workspace reset to the PR head", payload: #"{"action":"reset"}"#),
            event("3", "workspace.rebuilt", "09:02:00", title: "Workspace made again"),
            event("4", "attempt.pushed", "09:03:00", title: "Attempt 2 pushed"),
            event("5", "rule.action", "09:04:00", title: "Updated the branch", payload: #"{"action":"updated_branch"}"#),
            event("6", "rule.action", "09:05:00", title: "Reran the failed checks", payload: #"{"action":"rerun"}"#),
            event("7", "phase.entered", "09:06:00", title: "Sent back to Rework by QA", payload: #"{"from":"QA","to":"Rework"}"#),
            event("8", "pause.set", "09:10:00", title: "Paused: waiting for a slot", payload: #"{"reason":"environment"}"#),
            event("9", "pause.cleared", "09:11:00", title: "Moving again"),
            event("10", "pause.set", "09:20:00", title: "Paused: waiting on your answer", payload: #"{"reason":"question"}"#),
            event("11", "pause.cleared", "09:21:00", title: "Moving again"),
            event("12", "pause.set", "09:30:00", title: "Paused: deploy freeze", payload: #"{"reason":"build"}"#),
            event("13", "pause.cleared", "09:40:00", title: "Moving again"),
            event("14", "note", "09:50:00", title: "Note added", payload: #"{"text":"QA plan:\n1. Open the page.\n2. Walk step 2."}"#, run: "qa-2", actor: #"{"kind":"agent","run_id":"qa-2"}"#),
        ])

        XCTAssertEqual(all.mechanicalCount, 6)
        let folded = all.showing(allEvents: false)
        XCTAssertEqual(titles(folded), [
            "Note added", "Paused: deploy freeze", "Paused: waiting on your answer", "Sent back to Rework by QA", "Reran the failed checks",
        ])
        XCTAssertEqual(folded.mechanicalCount, 0)
        XCTAssertEqual(all.showing(allEvents: true), all)
        XCTAssertEqual(titles(all).count, 11)

        // A run's note reads whole, every line of it, by the run.
        guard case let .entry(note)? = folded.items.first(where: { $0.run == nil }) else { return XCTFail("The note is the newest entry") }
        XCTAssertEqual(note.detail, "QA plan:\n1. Open the page.\n2. Walk step 2.")
        XCTAssertEqual(note.actor, "QA run 2")
        XCTAssertEqual(TimelineModel.showAllEvents, "Show all events")
    }

    func testAnOngoingShortPauseStaysAndADayOfOnlyFoldedEntriesGoes() {
        let all = model([
            event("1", "phase.entered", "09:00:00", title: "Entered QA", payload: #"{"to":"QA"}"#),
            event("2", "pause.set", "11:59:30", title: "Paused: waiting for a slot", payload: #"{"reason":"environment"}"#),
        ])
        XCTAssertEqual(titles(all.showing(allEvents: false)), ["Paused: waiting for a slot"])

        let onlyMechanical = TimelineModel.build(
            history([event("1", "attempt.pushed", "09:03:00", title: "Attempt 1 pushed")]), reference: reference, calendar: calendar
        )
        // The run's day stays; the entry goes.
        XCTAssertEqual(onlyMechanical.showing(allEvents: false).items.count, 1)
        XCTAssertNil(onlyMechanical.showing(allEvents: false).items.first.flatMap { item -> TimelineEntry? in
            if case let .entry(entry) = item { return entry }
            return nil
        })
    }

    func testTheMarkerMovesToTheNewestShownItemItWasAbove() {
        let entries = [
            event("1", "note", "08:00:00", title: "Note added", payload: #"{"text":"Seen"}"#),
            event("2", "attempt.pushed", "08:30:00", title: "Attempt 1 pushed"),
        ]
        let page = TimelineModel.build(history(entries), reference: reference, calendar: calendar)
        var model = page
        model.marker = TimelineMarker(lookedAt: reference, before: "entry-2")
        XCTAssertEqual(model.showing(allEvents: false).marker?.before, "entry-1")
        model.marker = TimelineMarker(lookedAt: reference, before: "entry-gone")
        XCTAssertNil(model.showing(allEvents: false).marker)
    }

    func testAResolvedFindingSaysSoOnItsCardInsteadOfAnEntry() {
        let finding = event(
            "f1", "finding.recorded", "09:00:00", title: "QA found content clipped", payload: #"{"description":"The row is cut. Expected whole."}"#,
            run: "qa-2", actor: #"{"kind":"agent","run_id":"qa-2"}"#
        )
        let resolved = event(
            "r1", "finding.resolved", "09:30:00", title: "Finding marked resolved", payload: #"{"finding_id":"f1","how":"Widened the row"}"#,
            run: "qa-2", actor: #"{"kind":"agent","run_id":"qa-2"}"#
        )
        let byPerson = event(
            "r2", "finding.resolved", "09:40:00", title: "Finding marked resolved", payload: #"{"finding_id":"f2","how":"Fixed"}"#,
            actor: #"{"kind":"person","name":"Tony"}"#
        )
        let other = event("f2", "finding.recorded", "09:35:00", title: "QA found a typo", payload: #"{"description":"A typo."}"#)
        let unknown = event("r3", "finding.resolved", "09:50:00", title: "Finding marked resolved", payload: #"{"finding_id":"gone","how":"?"}"#)
        let timeline = model([finding, resolved, other, byPerson, unknown])

        XCTAssertEqual(titles(timeline), ["Finding marked resolved", "QA found a typo", "QA found content clipped"])
        let cards = timeline.items.compactMap { item -> TimelineEntry? in
            if case let .entry(entry) = item, entry.finding != nil { return entry }
            return nil
        }
        XCTAssertEqual(cards.map { $0.finding?.resolution }, ["Resolved by Tony", "Resolved in QA run 2"])
        XCTAssertEqual(cards.last?.eventIDs, ["f1", "r1"])
        XCTAssertEqual(cards.last?.finding?.accessibilityLabel, "Finding, The row is cut, Expected whole., Resolved in QA run 2")
        // An open finding says nothing of a resolution.
        XCTAssertNil(TimelineFinding(title: "Open").resolution)
    }
}
