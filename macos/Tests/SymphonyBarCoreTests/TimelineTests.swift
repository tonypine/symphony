import Foundation
@testable import SymphonyBarCore
import XCTest

/// A ticket's history as the Timeline section reads it, from the fixture in `Tests/Fixtures/timeline`: two days of a
/// ticket with every class of entry, a pause the rules wrote as many records, a question asked and answered, a run
/// that failed and the run now.
final class TimelineTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/timeline")

    private let reference = ISO8601DateFormatter().date(from: "2026-10-08T10:27:00Z")!

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func history() throws -> TicketEventsPayload {
        try XCTUnwrap(TicketEventsPayload.decode(Data(contentsOf: Self.fixtures.appendingPathComponent("events.json"))))
    }

    private func model(lookedAt: Date? = nil) throws -> TimelineModel {
        TimelineModel.build(try history(), reference: reference, calendar: utc, lookedAt: lookedAt)
    }

    /// When the fixture's person last looked: between the note and the Rework entry, before the run now.
    private let lookedAt = ISO8601DateFormatter().date(from: "2026-10-08T09:40:00Z")!

    private func entries(_ model: TimelineModel) -> [TimelineEntry] {
        model.items.compactMap { item in
            if case let .entry(entry) = item { return entry }
            return nil
        }
    }

    private func page(_ events: [String]) throws -> TicketEventsPayload {
        try XCTUnwrap(TicketEventsPayload.decode(Data(#"{"timeline": [\#(events.joined(separator: ","))]}"#.utf8)))
    }

    private func event(_ id: String, _ at: String, _ type: String, title: String, payload: String = "{}", actor: String = #"{"kind": "machine"}"#) -> String {
        #"{"id": "\#(id)", "at": "2026-10-08T\#(at)Z", "type": "\#(type)", "actor": \#(actor), "payload": \#(payload), "summary": {"title": "\#(title)"}}"#
    }

    // MARK: - Days and order

    func testTheNewestThingIsFirstAndEachDayIsSeparatedWithItsDate() throws {
        let model = try self.model()
        XCTAssertEqual(model.days.map(\.id), ["2026-10-08", "2026-10-07"])
        XCTAssertEqual(model.days.map(\.title), ["Today, Thu 8 Oct", "Yesterday, Wed 7 Oct"])
        // Each day says how long its history ran: today to the run now's reference, yesterday to the pause's end.
        XCTAssertEqual(model.days.map(\.span), ["over 2 h 27 min", "over 1 h 5 min"])
        XCTAssertEqual(model.days[1].accessibilityLabel, "Yesterday, Wed 7 Oct, over 1 hour 5 minutes")
        XCTAssertEqual(model.items.map(\.id), [
            "run-run-2", "entry-m1", "entry-n1", "entry-v2", "entry-v1", "entry-g1", "entry-h1", "entry-q2", "entry-q1",
            "entry-b2", "entry-p1", "run-run-1", "entry-a3", "entry-a1",
        ])
    }

    func testRunsAreGroupsInTheirTimeOrderAndTheRunNowSitsAtTheTopUnfolded() throws {
        let runs = try model().items.compactMap(\.run)
        XCTAssertEqual(runs.map(\.title), ["Implementation run 2", "Implementation run 1"])
        XCTAssertTrue(runs[0].isLive)
        XCTAssertTrue(runs[0].opensByDefault)
        XCTAssertFalse(runs[1].opensByDefault)
        XCTAssertEqual(runs[1].state, .failed)
    }

    func testTheRunNowIsOnTopEvenWhenSomethingHappenedSinceItStarted() throws {
        var merged = try self.history()
        merged.merge(try page([event("late", "10:20:00", "question.asked", title: "Asked you: Which fixture?")]))
        let model = TimelineModel.build(merged, reference: reference, calendar: utc)
        XCTAssertEqual(model.items.prefix(2).map(\.id), ["run-run-2", "entry-late"])
    }

    func testARunNowFromAnEarlierDayOpensTodaysGroup() throws {
        let history = try page([
            #"{"kind": "run", "run_id": "r", "run_kind": "qa", "run_number": 1, "status": "running", "started_at": "2026-10-06T23:00:00Z", "events": []}"#,
        ])
        let model = TimelineModel.build(history, reference: reference, calendar: utc)
        XCTAssertEqual(model.days.map(\.title), ["Today, Thu 8 Oct"])
        XCTAssertEqual(model.items.first?.run?.title, "QA run 1")
    }

    func testAnEmptyHistoryHasNoDaysAndARunWithNoTimeIsLeftOut() throws {
        XCTAssertTrue(TimelineModel.build(TicketEventsPayload(), reference: reference, calendar: utc).isEmpty)
        let history = try page([#"{"kind": "run", "run_id": "r", "status": "ended", "events": []}"#])
        XCTAssertTrue(TimelineModel.build(history, reference: reference, calendar: utc).items.isEmpty)
        XCTAssertEqual(TimelineModel.empty, "Nothing has happened to this ticket yet.")
    }

    func testADayOfOneMomentHasNoSpanAndAnOlderDaySaysOnlyItsDate() throws {
        let history = try page([event("x", "09:00:00", "note", title: "Note added").replacingOccurrences(of: "2026-10-08", with: "2026-10-01")])
        let day = try XCTUnwrap(TimelineModel.build(history, reference: reference, calendar: utc).days.first)
        XCTAssertNil(day.span)
        XCTAssertEqual(day.title, "Thu 1 Oct")
        XCTAssertEqual(day.accessibilityLabel, "Thu 1 Oct")
    }

    // MARK: - Entries, their classes and who did them

    func testEachEntryHasItsClassAndWhoDidIt() throws {
        let entries = self.entries(try model())
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        XCTAssertEqual(byID["a1"]?.kind, .phase)
        XCTAssertEqual(byID["a1"]?.actor, "Tony")
        XCTAssertEqual(byID["a3"]?.actor, "Symphony")
        XCTAssertEqual(byID["q1"]?.kind, .questionAsked)
        XCTAssertEqual(byID["q2"]?.kind, .questionAnswered)
        XCTAssertEqual(byID["q2"]?.actor, "Tony")
        XCTAssertEqual(byID["h1"]?.kind, .person)
        XCTAssertEqual(byID["g1"]?.kind, .rule)
        XCTAssertEqual(byID["g1"]?.actor, "Rule: PR watcher R22")
        XCTAssertEqual(byID["v1"]?.kind, .runFailed)
        XCTAssertEqual(byID["v2"]?.kind, .finding)
        XCTAssertEqual(byID["v2"]?.actor, "QA run")
        XCTAssertEqual(byID["n1"]?.kind, .note)
        // The run's own events fold into its group; the situations that restate an entry leave no row.
        XCTAssertTrue(entries.allSatisfy { !$0.eventIDs.contains { ["r1", "s1", "p2", "p6", "b3"].contains($0) } })
    }

    func testOnePauseReadsOnceWithItsDurationNotFourRows() throws {
        let entries = self.entries(try model())
        let pauses = entries.filter { $0.kind == .pause }
        XCTAssertEqual(pauses.count, 2)
        let freeze = try XCTUnwrap(pauses.first { $0.id == "p1" })
        XCTAssertEqual(freeze.title, "Paused: deploy freeze")
        XCTAssertEqual(freeze.actor, "Tony")
        XCTAssertEqual(freeze.detail, "Also paused: holding for the build of a0be0aa")
        XCTAssertEqual(freeze.eventIDs, ["p1", "p3", "p4", "p5"])
        XCTAssertEqual(freeze.duration, "35 min")
        XCTAssertEqual(
            freeze.accessibilityLabel(time: "09:30"),
            "09:30, pause, Paused: deploy freeze, Also paused: holding for the build of a0be0aa, lasted 35 minutes, by Tony"
        )
        // Set, cleared, set again two seconds later and cleared, with the rule's three writes: one pause of 21 minutes,
        // by the rule that set it.
        let blocked = try XCTUnwrap(pauses.first { $0.id == "b2" })
        XCTAssertEqual(blocked.actor, "Rule: Blocked-by links")
        XCTAssertEqual(Set(blocked.eventIDs), ["b1", "b2", "b4", "b5", "b6", "b7", "b8"])
        XCTAssertEqual(blocked.durationSeconds, 21 * 60)
        XCTAssertFalse(entries.contains { $0.kind == .rule && $0.actor == "Rule: Blocked-by links" })
    }

    func testAPauseThatStillHoldsCountsItsDurationSoFar() throws {
        let history = try page([event("p", "10:00:00", "hold.set", title: "Blocked hold set", payload: #"{"kind": "blocked"}"#)])
        let entry = try XCTUnwrap(entries(TimelineModel.build(history, reference: reference, calendar: utc)).first)
        XCTAssertTrue(entry.isOngoing)
        XCTAssertEqual(entry.duration, "27 min so far")
        XCTAssertEqual(entry.accessibilityLabel(time: "10:00"), "10:00, pause, Blocked hold set, for 27 minutes so far, by Symphony")
    }

    func testAPauseSetAgainLaterIsANewPauseAndAClearWithoutItsSetIsItsOwnEntry() throws {
        let history = try page([
            event("c", "07:00:00", "pause.cleared", title: "Moving again"),
            event("r", "07:00:30", "pause.reason_cleared", title: "Pause reason cleared"),
            event("s1", "08:00:00", "pause.set", title: "Paused: a"),
            event("s2", "08:01:00", "pause.set", title: "Paused: b"),
            event("e1", "08:02:00", "pause.cleared", title: "Moving again"),
            event("s3", "09:00:00", "pause.set", title: "Paused: a"),
            event("e2", "09:00:30", "pause.cleared", title: "Moving again"),
            event("s4", "09:01:00", "pause.set", title: "Paused: other"),
        ])
        let entries = self.entries(TimelineModel.build(history, reference: reference, calendar: utc))
        // Newest first: the pause still holding, the one set again later, the first one, then the two lone clears.
        XCTAssertEqual(entries.map(\.kind), [.pause, .pause, .pause, .pauseCleared, .pauseCleared])
        XCTAssertEqual(entries.map(\.id), ["s4", "s3", "s1", "r", "c"])
        XCTAssertTrue(entries[0].isOngoing)
        XCTAssertEqual(entries[2].detail, "Paused: b")
        XCTAssertEqual(entries[2].durationSeconds, 120)
    }

    func testDuplicateRecordWritesFoldIntoOneEntry() throws {
        let entries = self.entries(try model(lookedAt: lookedAt))
        let rework = entries.filter { $0.title == "Entered Rework from QA" }
        XCTAssertEqual(rework.count, 1)
        XCTAssertEqual(rework.first?.eventIDs, ["m1", "m2"])
        // The second write was newer than the person's last look, so the entry is.
        XCTAssertEqual(rework.first?.isNew, true)

        let history = try page([
            event("d1", "09:00:00", "note", title: "Note added"),
            event("d2", "09:00:00", "note", title: "Note added"),
            event("d3", "09:00:05", "note", title: "Note added"),
            event("x", "09:01:00", "person.action", title: "Forced ahead of the queue", payload: #"{"action": "force"}"#),
            event("d4", "09:02:00", "note", title: "Note added"),
        ])
        let folded = self.entries(TimelineModel.build(history, reference: reference, calendar: utc))
        XCTAssertEqual(folded.map(\.eventIDs), [["d4"], ["x"], ["d1", "d2", "d3"]])
    }

    func testAPhaseEnteredBesideAPersonsMoveIsThatMove() throws {
        let entries = self.entries(try model())
        let move = try XCTUnwrap(entries.first { $0.id == "a1" })
        XCTAssertEqual(move.eventIDs, ["a1", "a2"])
        XCTAssertEqual(move.detail, "Phase 3b chain")
        XCTAssertFalse(entries.contains { $0.id == "a2" })

        let history = try page([
            event("pa", "09:00:00", "person.action", title: "Moved to Done", payload: #"{"action": "move", "to": "Done"}"#, actor: #"{"kind": "person", "name": "Tony"}"#),
            event("pe", "09:00:01", "phase.entered", title: "Entered Done from Merging", payload: #"{"to": "Done", "from": "Merging"}"#),
            event("pf", "09:30:00", "phase.entered", title: "Entered Done again", payload: #"{"to": "Done"}"#),
        ])
        let moves = self.entries(TimelineModel.build(history, reference: reference, calendar: utc))
        XCTAssertEqual(moves.map(\.eventIDs), [["pf"], ["pa", "pe"]])
        XCTAssertEqual(moves[0].actor, "Symphony")
        XCTAssertEqual(moves[1].actor, "Tony")
    }

    func testARuleThatMovedTheTicketIsWhoMadeTheMoveAndOneThatCausedNothingIsItsOwnEntry() throws {
        let history = try page([
            event("m", "09:00:00", "phase.entered", title: "Entered Merging from QA", payload: #"{"to": "Merging"}"#),
            event("r", "09:00:02", "rule.action", title: "R7 moved the ticket", payload: #"{"rule": "R7", "action": "moved"}"#),
            event("l", "11:00:00", "rule.action", title: "Self-heal lifted a pause", payload: #"{"rule": "Self-heal", "action": "lifted_pause"}"#),
        ])
        let entries = self.entries(TimelineModel.build(history, reference: reference, calendar: utc))
        XCTAssertEqual(entries.map(\.id), ["l", "m"])
        XCTAssertEqual(entries[0].kind, .rule)
        XCTAssertEqual(entries[0].actor, "Rule: Self-heal")
        XCTAssertEqual(entries[1].actor, "Rule: R7")
        XCTAssertEqual(entries[1].eventIDs, ["m", "r"])
    }

    func testEveryClassOfEventFindsItsKind() throws {
        let kinds: [(String, String, TimelineEntry.Kind)] = [
            ("ticket.cancelled", "{}", .phase), ("drift.reverted", "{}", .phase),
            ("decision.requested", "{}", .questionAsked), ("question.reopened", "{}", .questionAsked),
            ("decision.recorded", "{}", .questionAnswered),
            ("question.withdrawn", "{}", .questionClosed), ("question.not_asked", "{}", .questionClosed),
            ("run.started", "{}", .runStarted),
            ("run.ended", #"{"exit": "failed"}"#, .runFailed), ("run.ended", #"{"exit": "stopped"}"#, .runStopped),
            ("run.ended", #"{"exit": "handoff"}"#, .runPassed),
            ("verdict.recorded", #"{"kind": "code_review", "outcome": "approve"}"#, .runPassed),
            ("verdict.recorded", "{}", .runPassed),
            ("run.started_by_person", "{}", .person),
            ("finding.resolved", "{}", .findingResolved), ("finding.confirmed", "{}", .findingResolved),
            ("brief.written", "{}", .note), ("ticket.filed", "{}", .ticket),
            ("situation.changed", #"{"to": "retrying"}"#, .situation),
            ("workspace.synced", "{}", .other),
        ]
        for (index, (type, payload, kind)) in kinds.enumerated() {
            let history = try page([event("k\(index)", "09:00:00", type, title: type, payload: payload)])
            XCTAssertEqual(entries(TimelineModel.build(history, reference: reference, calendar: utc)).first?.kind, kind, type)
        }
    }

    func testBookkeepingAndUntimedEventsLeaveNoEntry() throws {
        let history = try page([
            event("r", "09:00:00", "note.read", title: "Note read by a run"),
            #"{"id": "u", "type": "note", "payload": {}}"#,
        ])
        XCTAssertTrue(TimelineModel.build(history, reference: reference, calendar: utc).isEmpty)
    }

    func testWhoDidItFallsBackToTheSetterTheRunAndSymphony() throws {
        let inRun = event("in-run", "07:05:00", "question.asked", title: "Asked you: x")
            .replacingOccurrences(of: #""type""#, with: #""run_id": "q", "type""#)
        let run = #"{"kind": "run", "run_id": "q", "run_kind": "qa", "run_number": 3, "status": "ended", "started_at": "2026-10-08T07:00:00Z", "events": ["#
            + inRun + "]}"
        let history = try page([
            run,
            event("by-rule", "08:00:00", "question.asked", title: "Asked you: y", payload: #"{"asked_by": {"kind": "rule", "name": "CI wait"}}"#),
            event("by-run", "08:01:00", "question.asked", title: "Asked you: z", payload: #"{"asked_by": {"kind": "run", "name": "code_review"}}"#),
            event("by-nobody", "08:02:00", "question.asked", title: "Asked you: w", payload: #"{"asked_by": {"kind": "symphony"}}"#),
            event("agent", "08:03:00", "note", title: "Note added", actor: #"{"kind": "agent", "run_id": "q"}"#),
            event("person", "08:04:00", "note", title: "Note added", actor: #"{"kind": "person"}"#),
            event("rule", "08:05:00", "rule.action", title: "A rule acted", payload: #"{"action": "other"}"#),
            event("setter", "08:06:00", "note", title: "Note", payload: #"{"by": {"kind": "person"}}"#),
            event("hold", "08:07:00", "hold.cleared", title: "Blocked hold cleared", payload: #"{"kind": "blocked", "by": "Tony"}"#),
        ])
        let actors = Dictionary(uniqueKeysWithValues: entries(TimelineModel.build(history, reference: reference, calendar: utc)).map { ($0.id, $0.actor) })
        XCTAssertEqual(actors["in-run"], "QA run 3")
        XCTAssertEqual(actors["by-rule"], "Rule: CI wait")
        XCTAssertEqual(actors["by-run"], "Code Review run")
        XCTAssertEqual(actors["by-nobody"], "Symphony")
        XCTAssertEqual(actors["agent"], "QA run 3")
        XCTAssertEqual(actors["person"], "You")
        XCTAssertEqual(actors["rule"], "Rule: a rule")
        XCTAssertEqual(actors["setter"], "You")
        // A hold cleared with no hold set reads on its own; its `by` is a name, not a setter.
        XCTAssertEqual(actors["hold"], "Symphony")
    }

    func testTheLeadIsTheWordsUpToTheColon() {
        let paused = TimelineEntry(id: "p", kind: .pause, at: reference, title: "Paused: deploy freeze", actor: "Tony")
        XCTAssertEqual(paused.lead, "Paused:")
        XCTAssertEqual(paused.rest, "deploy freeze")
        let moved = TimelineEntry(id: "m", kind: .phase, at: reference, title: "Moved to Done", actor: "Tony")
        XCTAssertEqual(moved.lead, "Moved to Done")
        XCTAssertNil(moved.rest)
        XCTAssertNil(TimelineEntry(id: "e", kind: .other, at: reference, title: "Ended: ", actor: "x").rest)
        XCTAssertEqual(moved.accessibilityLabel(time: "09:02"), "09:02, phase move, Moved to Done, by Tony")
    }

    func testEveryClassHasAGlyphAToneAndAWordAndOnlyOutcomesAreGreen() {
        for kind in TimelineEntry.Kind.allCases {
            XCTAssertFalse(kind.symbol.isEmpty)
            XCTAssertFalse(kind.word.isEmpty)
        }
        let green = TimelineEntry.Kind.allCases.filter { $0.tone == .status(.done) }
        XCTAssertEqual(Set(green), [.questionAnswered, .runPassed])
        XCTAssertEqual(TimelineEntry.Kind.phase.tone, .accent)
    }

    // MARK: - Selection

    func testTheArrowsMoveTheSelectionEntryByEntryAndStopAtEitherEnd() throws {
        let model = try self.model()
        let ids = model.items.map(\.id)
        XCTAssertEqual(model.moving(nil, by: 1), ids.first)
        XCTAssertEqual(model.moving(nil, by: -1), ids.last)
        XCTAssertEqual(model.moving(ids[0], by: 1), ids[1])
        XCTAssertEqual(model.moving(ids[2], by: -1), ids[1])
        XCTAssertEqual(model.moving(ids[0], by: -1), ids[0])
        XCTAssertEqual(model.moving(ids.last, by: 1), ids.last)
        XCTAssertEqual(model.moving(ids[3], by: 0), ids[3])
        XCTAssertEqual(model.moving("gone", by: 1), ids.first)
        XCTAssertNil(TimelineModel(days: []).moving(nil, by: 1))
    }

    func testTheClockReadsInTheCalendarsZone() {
        XCTAssertEqual(TimelineModel.clock(utc)(reference), "10:27")
    }

    // MARK: - Since you last looked (TP-1451)

    func testTheMarkerSitsAboveTheNewestThingSeenAndTheDotsAreTheFeedsNew() throws {
        let model = try model(lookedAt: lookedAt)
        // The feed calls the second Rework write and the run now's events new: the entry and the run carry the dot.
        XCTAssertEqual(model.items.filter(\.isNew).map(\.id), ["run-run-2", "entry-m1"])
        XCTAssertEqual(model.marker, TimelineMarker(lookedAt: lookedAt, before: "entry-n1"))
        let rework = try XCTUnwrap(entries(model).first { $0.id == "m1" })
        XCTAssertEqual(rework.accessibilityLabel(time: "09:44"), "09:44, phase move, Entered Rework from QA, QA failed, by Symphony, new since you last looked")
        // The run now is live: it says so instead of carrying the dot.
        let run = try XCTUnwrap(model.items.first?.run)
        XCTAssertTrue(run.isNew)
        XCTAssertFalse(run.showsNewDot)
        XCTAssertFalse(run.accessibilityLabel.contains(TimelineEntry.newWords))
        XCTAssertEqual(TicketMarksRead.markerText(lookedAt, clock: TimelineModel.clock(utc)), "Since you last looked, at 09:40")
    }

    func testAFirstVisitShowsNoMarkerAndNoDotsThoughTheFeedCallsEverythingNew() throws {
        let history = try page([
            #"{"id": "a", "at": "2026-10-08T09:00:00Z", "type": "note", "actor": {"kind": "machine"}, "payload": {}, "summary": {"title": "Note added"}, "new": true}"#,
            #"{"id": "b", "at": "2026-10-08T09:10:00Z", "type": "note", "actor": {"kind": "machine"}, "payload": {}, "summary": {"title": "Note again"}, "new": true}"#,
        ])
        let model = TimelineModel.build(history, reference: reference, calendar: utc)
        XCTAssertNil(model.marker)
        XCTAssertTrue(model.items.allSatisfy { !$0.isNew })
    }

    func testAnEndedRunWithANewEventCarriesTheDotAndTheLineGoesUnderIt() throws {
        let history = try page([
            #"{"id": "old", "at": "2026-10-08T08:00:00Z", "type": "note", "actor": {"kind": "machine"}, "payload": {}, "summary": {"title": "Note added"}, "new": false}"#,
            #"{"kind": "run", "run_id": "run-1", "run_kind": "implementation", "run_number": 1, "status": "ended", "exit": "normal", "started_at": "2026-10-08T09:00:00Z", "ended_at": "2026-10-08T09:20:00Z", "events": [{"id": "r1", "at": "2026-10-08T09:00:00Z", "type": "run.started", "run_id": "run-1", "payload": {}, "new": true}]}"#,
        ])
        let lookedAt = ISO8601DateFormatter().date(from: "2026-10-08T08:30:00Z")!
        let model = TimelineModel.build(history, reference: reference, calendar: utc, lookedAt: lookedAt)
        let run = try XCTUnwrap(model.items.first?.run)
        XCTAssertTrue(run.showsNewDot)
        XCTAssertTrue(run.accessibilityLabel.hasSuffix(", new since you last looked"))
        XCTAssertEqual(model.marker?.before, "entry-old")
    }

    func testNoMarkerWhenNothingIsNewOrNothingWasSeen() throws {
        let seen = try page([
            #"{"id": "a", "at": "2026-10-08T09:00:00Z", "type": "note", "actor": {"kind": "machine"}, "payload": {}, "summary": {"title": "Note added"}, "new": false}"#,
        ])
        XCTAssertNil(TimelineModel.build(seen, reference: reference, calendar: utc, lookedAt: lookedAt).marker)
        let unseen = try page([
            #"{"id": "a", "at": "2026-10-08T09:50:00Z", "type": "note", "actor": {"kind": "machine"}, "payload": {}, "summary": {"title": "Note added"}, "new": true}"#,
        ])
        let model = TimelineModel.build(unseen, reference: reference, calendar: utc, lookedAt: lookedAt)
        XCTAssertNil(model.marker)
        XCTAssertEqual(model.items.map(\.isNew), [true])
    }

    // MARK: - The entering motion

    func testANewEntryDropsInOnASpringAndReduceMotionPutsItThereAtOnce() {
        XCTAssertEqual(DesignTokens.Motion.entering(reduceMotion: false), .spring(duration: 0.45, bounce: DesignTokens.Motion.springBounce))
        XCTAssertNil(DesignTokens.Motion.entering(reduceMotion: true))
        XCTAssertEqual(DesignTokens.Motion.enterOffset, 12)
        XCTAssertEqual(DesignTokens.Motion.enterTintDuration, 1.2)
        XCTAssertEqual(DesignTokens.Motion.enterTint(dark: true), DesignTokens.StateSurface.selected.opacity(dark: true))
    }
}
