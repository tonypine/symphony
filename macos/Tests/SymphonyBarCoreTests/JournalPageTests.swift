import Foundation
@testable import SymphonyBarCore
import XCTest

/// The Journal (TP-1459) from the `journal` fixture: a night across TP-1381's tickets, a shop ticket and a billing one,
/// and Symphony's own stream, as `GET /api/v1/events` serves it notable, filtered to the epic and with everything.
final class JournalPageTests: XCTestCase {
    private static let api = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/director-app/journal/api/v1")

    private let reference = ISO8601DateFormatter().date(from: "2026-11-12T03:30:00Z")!

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func payload(_ name: String = "events") throws -> JournalPayload {
        try XCTUnwrap(JournalPayload.decode(Data(contentsOf: Self.api.appendingPathComponent("\(name).json"))))
    }

    private func model(_ name: String = "events") throws -> JournalModel {
        var feed = JournalFeed()
        feed.takeNewest(try payload(name))
        return JournalModel.build(feed, reference: reference, calendar: utc)
    }

    private func event(_ id: String, at: String, ticket: String? = "TP-1", type: String = "phase.entered") -> JournalPayload.Event {
        JournalPayload.Event(
            event: TicketEventsPayload.Event(id: id, seq: nil, at: at, type: type, runID: nil, parent: nil, actor: nil, summary: nil, payload: .init(), artifacts: []),
            ticket: JournalPayload.Ticket(repoKey: "symphony", identifier: ticket, title: "A ticket")
        )
    }

    // MARK: - The read's parameters

    func testTheNotableViewAsksForTheNotableEventsTwoHundredAtATime() {
        XCTAssertEqual(JournalQuery().path(), "api/v1/events?limit=200&notable=true")
    }

    func testEachChipMapsToItsQueryParameter() {
        let cases: [(JournalFilter, JournalQuery, String, String)] = [
            (.repo, JournalQuery(repo: "web-shop"), "repo", "web-shop"),
            (.epic, JournalQuery(epic: "TP-1381"), "epic", "TP-1381"),
            (.classes, JournalQuery(classes: [.verdict, .rule]), "classes", "rule,verdict"),
            (.everything, JournalQuery(everything: true), "notable", "false"),
        ]
        for (filter, query, parameter, value) in cases {
            XCTAssertEqual(filter.parameter, parameter)
            let parameters = query.parameters()
            XCTAssertEqual(parameters.first { $0.name == parameter }?.value, value, "\(filter)")
            XCTAssertTrue(query.isSet(filter))
            XCTAssertFalse(JournalQuery().isSet(filter))
            // A chip sets its own parameter only: the rest are the notable view's.
            let others = parameters.filter { $0.name != parameter }.map { "\($0.name)=\($0.value)" }
            let defaults = JournalQuery().parameters().filter { $0.name != parameter }.map { "\($0.name)=\($0.value)" }
            XCTAssertEqual(others, defaults, "\(filter)")
        }
    }

    func testEveryChipTogetherAndShowEarlierWriteOneQueryInAFixedOrder() {
        let query = JournalQuery(repo: "symphony", epic: "TP-1381", classes: [.pause, .move], everything: true)
        XCTAssertEqual(
            query.path(until: "2026-11-11T21:00:00+00:00"),
            "api/v1/events?classes=move,pause&epic=TP-1381&limit=200&notable=false&repo=symphony&until=2026-11-11T21:00:00%2B00:00"
        )
    }

    func testTheWindowsScopeIsTheRepoUnlessTheRepoChipPicksAnother() {
        XCTAssertEqual(JournalQuery().path(scope: .repo("api")), "api/v1/events?limit=200&notable=true&repo=api")
        XCTAssertEqual(JournalQuery(repo: "docs").path(scope: .repo("api")), "api/v1/events?limit=200&notable=true&repo=docs")
    }

    func testTheChipsSayWhatTheyKeep() {
        var query = JournalQuery()
        XCTAssertEqual(query.chipText(.repo), "Repo: All repos")
        XCTAssertEqual(query.chipText(.epic), "Epic: All epics")
        XCTAssertEqual(query.chipText(.classes), "Class: All classes")
        XCTAssertNil(query.chipText(.everything))
        query.repo = "web-shop"
        query.epic = "TP-1381"
        query.toggle(.rule)
        XCTAssertEqual(query.chipText(.classes), "Class: Rule actions")
        query.toggle(.verdict)
        XCTAssertEqual(query.chipText(.classes), "Class: Verdicts +1")
        XCTAssertEqual([query.chipText(.repo), query.chipText(.epic)], ["Repo: web-shop", "Epic: TP-1381"])
        query.toggle(.verdict)
        XCTAssertEqual(query.classes, [.rule])
        XCTAssertEqual(JournalFilter.allCases.map(\.title), ["Repo", "Epic", "Class", "Everything"])
        XCTAssertEqual(JournalClass.allCases.map(\.id), [
            "verdict", "move", "question", "pause", "rule", "ticket", "situation", "run", "finding", "person", "note",
        ])
    }

    func testWhatThePageSaysWithNoRow() {
        XCTAssertEqual(JournalModel.emptyTitle(JournalQuery()), "Nothing notable has happened yet.")
        XCTAssertEqual(JournalModel.emptyTitle(JournalQuery(everything: true)), "Nothing has happened yet.")
        XCTAssertEqual(JournalModel.emptyTitle(JournalQuery(epic: "TP-1381")), "No events match these filters.")
    }

    // MARK: - The rows

    func testTheNightReadsNewestFirstUnderASeparatorForEachDay() throws {
        let model = try self.model()
        XCTAssertEqual(model.days.map(\.title), ["Today, Thu 12 Nov", "Yesterday, Wed 11 Nov"])
        XCTAssertEqual(model.days.map(\.accessibilityLabel), ["Today, Thu 12 Nov, 12 events", "Yesterday, Wed 11 Nov, 4 events"])
        let times = model.rows.map(\.entry.at)
        XCTAssertEqual(times, times.sorted(by: >))
        XCTAssertEqual(model.rows.first?.entry.title, "QA passed")
        XCTAssertFalse(model.canShowEarlier)
    }

    func testEachRowHasTheTimelinesGlyphForItsClassAndWhoDidIt() throws {
        let rows = Dictionary(uniqueKeysWithValues: try model().rows.map { ($0.id, $0) })
        let expected: [(String, TimelineEntry.Kind, String)] = [
            ("j01", .runPassed, "QA run"),
            ("j02", .rule, "Rule: PR watcher R22"),
            ("j03", .phase, "Symphony"),
            ("j04", .pauseCleared, "Symphony"),
            ("j05", .ticket, "Rule: Self-heal"),
            ("j06", .rule, "Rule: Blocked-by links"),
            ("j07", .questionAnswered, "Tony"),
            ("j08", .situation, "Symphony"),
            ("j09", .questionAsked, "Implementation run"),
            ("j10", .pause, "Rule: Blocked-by links"),
            ("j11", .person, "Tony"),
            ("j12", .runFailed, "Code Review run"),
            ("j13", .phase, "Symphony"),
            ("j14", .rule, "Rule: CI wait"),
            ("j15", .pause, "Tony"),
            ("j16", .runFailed, "QA run"),
        ]
        for (id, kind, actor) in expected {
            XCTAssertEqual(rows[id]?.entry.kind, kind, id)
            XCTAssertEqual(rows[id]?.entry.actor, actor, id)
        }
        XCTAssertEqual(rows["j02"]?.entry.detail, "A check failed on PR #887: macos-e2e lost its runner.")
    }

    func testARuleActionNamesTheRuleAndWhatItDid() throws {
        let row = try XCTUnwrap(try model().rows.first { $0.id == "j02" })
        XCTAssertEqual(row.entry.title, "PR watcher R22 reran the failed checks")
        XCTAssertEqual(row.entry.actor, "Rule: PR watcher R22")
        // Without its summary, its rule and its action still say it.
        var bare = event("r1", at: "2026-11-12T01:00:00Z", type: "rule.action")
        bare.event.payload = .init(action: "lifted_pause", rule: "CI wait")
        bare.by = JournalPayload.By(kind: "rule", name: "CI wait")
        let fallback = JournalModel.row(bare, at: reference)
        XCTAssertEqual(fallback.entry.title, "CI wait lifted a pause")
        XCTAssertEqual(fallback.entry.actor, "Rule: CI wait")
        let words = ["rerun", "paused", "parked", "filed_ticket", "moved", "updated_branch", "auto_merge", "asked", "other", nil].map(JournalModel.ruleDid)
        XCTAssertEqual(words, [
            "reran the failed checks", "paused the ticket", "parked the ticket", "filed a fix ticket", "moved the ticket",
            "updated the branch", "turned on auto-merge", "asked a question", "acted on the ticket", "acted on the ticket",
        ])
        bare.event.payload = .init()
        XCTAssertEqual(JournalModel.row(bare, at: reference).entry.title, "A rule acted on the ticket")
        XCTAssertEqual(JournalModel.row(event("t1", at: "2026-11-12T01:00:00Z", type: "note"), at: reference).entry.title, "note")
    }

    func testWhoDidItWithoutAByReadsAsTheTimelineReadsIt() {
        var anonymous = event("a1", at: "2026-11-12T01:00:00Z")
        XCTAssertEqual(JournalModel.row(anonymous, at: reference).entry.actor, "Symphony")
        anonymous.event.actor = TicketEventsPayload.Actor(kind: "person", name: "Ana")
        XCTAssertEqual(JournalModel.row(anonymous, at: reference).entry.actor, "Ana")
        anonymous.by = JournalPayload.By(kind: "person")
        XCTAssertEqual(JournalModel.row(anonymous, at: reference).entry.actor, "You")
        anonymous.by = JournalPayload.By(kind: "rule")
        XCTAssertEqual(JournalModel.row(anonymous, at: reference).entry.actor, "Rule: a rule")
        anonymous.by = JournalPayload.By(kind: "symphony", name: "Symphony")
        XCTAssertEqual(JournalModel.row(anonymous, at: reference).entry.actor, "Symphony")
    }

    func testEachRowsChipNamesItsTicketAndOpensItAtTheEvent() throws {
        let rows = try model().rows
        let verdict = try XCTUnwrap(rows.first { $0.id == "j01" })
        XCTAssertEqual(verdict.chipIdentifier, "TP-1457")
        XCTAssertEqual(verdict.ticket.title, "3b (20/26): Initiatives as the epic's story")
        XCTAssertEqual(verdict.focus, TimelineFocus(identifier: "TP-1457", eventID: "j01", runID: "r-1457-qa1"))
        XCTAssertEqual(verdict.chipLabel, "Open TP-1457, 3b (20/26): Initiatives as the epic's story, at this event")
        // Symphony's own stream (the release, the dispatch pause) is no ticket's: its chip opens nothing.
        let release = try XCTUnwrap(rows.first { $0.id == "j04" })
        XCTAssertEqual(release.chipIdentifier, "Symphony")
        XCTAssertNil(release.focus)
        XCTAssertEqual(release.chipLabel, "Symphony")
        // A ticket Symphony keeps no record of reads by its repo.
        let unknown = JournalModel.row(
            JournalPayload.Event(event: event("u1", at: "2026-11-12T01:00:00Z").event, ticket: JournalPayload.Ticket(repoKey: "docs")),
            at: reference
        )
        XCTAssertEqual(unknown.chipIdentifier, "docs")
        XCTAssertNil(unknown.focus)
    }

    func testFilteredToTheEpicOnlyItsTicketsRemain() throws {
        XCTAssertEqual(JournalQuery(epic: "TP-1381").path(), "api/v1/events?epic=TP-1381&limit=200&notable=true")
        let rows = try model("events.epic=TP-1381&limit=200&notable=true").rows
        XCTAssertEqual(rows.count, 12)
        XCTAssertTrue(rows.allSatisfy { $0.chipIdentifier.hasPrefix("TP-14") })
    }

    func testEverythingAddsTheRunsFindingsAndNotes() throws {
        XCTAssertEqual(JournalQuery(everything: true).path(), "api/v1/events?limit=200&notable=false")
        let rows = try model("events.limit=200&notable=false").rows
        XCTAssertEqual(rows.count, 21)
        let kinds = Set(rows.map(\.entry.kind))
        XCTAssertTrue(kinds.isSuperset(of: [.runStarted, .finding, .note, .runPassed, .rule, .pause, .pauseCleared, .ticket, .situation, .person]))
    }

    // MARK: - Reading and paging

    func testAPageDecodesItsEventsTicketsClassesAndWhoDidThem() throws {
        let page = try payload()
        XCTAssertEqual(page.events.count, 16)
        XCTAssertNil(page.nextUntil)
        let first = try XCTUnwrap(page.events.first)
        XCTAssertEqual(first.event.type, "verdict.recorded")
        XCTAssertEqual(first.eventClass, "verdict")
        XCTAssertTrue(first.notable)
        XCTAssertEqual(first.by, JournalPayload.By(kind: "run", name: "qa", runId: "r-1457-qa1"))
        XCTAssertEqual(first.ticket, JournalPayload.Ticket(repoKey: "symphony", identifier: "TP-1457", title: "3b (20/26): Initiatives as the epic's story"))
        XCTAssertNil(JournalPayload.decode(Data("[]".utf8)))
        // An event without an id is skipped, not the page; a missing ticket reads as no ticket.
        let partial = try XCTUnwrap(JournalPayload.decode(Data(#"{"events": [{"type": "note"}, {"id": "e1", "at": "2026-11-12T01:00:00Z"}], "next_until": "2026-11-12T00:00:00Z"}"#.utf8)))
        XCTAssertEqual(partial.events.map(\.id), ["e1"])
        XCTAssertEqual(partial.events.first?.ticket, JournalPayload.Ticket())
        XCTAssertEqual(partial.events.first?.notable, true)
        XCTAssertNil(partial.events.first?.by)
        XCTAssertEqual(partial.nextUntil, "2026-11-12T00:00:00Z")
    }

    func testShowEarlierAddsThePageBeforeAndANewerReadKeepsIt() {
        var feed = JournalFeed()
        XCTAssertFalse(feed.loaded)
        feed.takeNewest(JournalPayload(events: [event("b", at: "2026-11-12T02:00:00Z"), event("a", at: "2026-11-12T01:00:00Z")], nextUntil: "2026-11-12T01:00:00Z"))
        XCTAssertTrue(feed.loaded)
        XCTAssertTrue(feed.canShowEarlier)
        feed.takeEarlier(JournalPayload(events: [event("z", at: "2026-11-11T09:00:00Z")], nextUntil: nil))
        XCTAssertFalse(feed.canShowEarlier)
        XCTAssertEqual(feed.events.map(\.id), ["b", "a", "z"])
        // The newest page read again adds what is new and keeps the earlier pages and where they end.
        feed.takeNewest(JournalPayload(events: [event("c", at: "2026-11-12T03:00:00Z"), event("b", at: "2026-11-12T02:00:00Z")], nextUntil: "2026-11-12T02:00:00Z"))
        XCTAssertEqual(feed.events.map(\.id), ["c", "b", "a", "z"])
        XCTAssertFalse(feed.canShowEarlier)
        let model = JournalModel.build(feed, reference: reference, calendar: utc)
        XCTAssertEqual(model.days.map(\.id), ["2026-11-12", "2026-11-11"])
        XCTAssertFalse(model.isEmpty)
        XCTAssertTrue(JournalModel.build(JournalFeed(), reference: reference, calendar: utc).isEmpty)
    }

    func testEventsOfOneMomentKeepSymphonysOrderAndAnEventWithoutATimeIsLeftOut() {
        var first = event("a", at: "2026-11-12T01:00:00Z")
        first.event.seq = 1
        var second = event("b", at: "2026-11-12T01:00:00Z")
        second.event.seq = 2
        let third = event("c", at: "2026-11-12T01:00:00Z")
        let fourth = event("d", at: "2026-11-12T01:00:00Z")
        var timeless = event("t", at: "")
        timeless.event.at = nil
        var feed = JournalFeed()
        feed.takeNewest(JournalPayload(events: [first, second, third, fourth, timeless]))
        XCTAssertEqual(feed.events.map(\.id), ["d", "c", "b", "a", "t"])
        XCTAssertEqual(JournalModel.build(feed, reference: reference, calendar: utc).rows.map(\.id), ["d", "c", "b", "a"])
    }

    // MARK: - The ticket page at the event

    func testTheTicketPageFindsTheItemThatHoldsTheEvent() throws {
        let data = try Data(contentsOf: Self.api.appendingPathComponent("repos/symphony/tickets/TP-1457/events.json"))
        let history = try XCTUnwrap(TicketEventsPayload.decode(data))
        let timeline = TimelineModel.build(history, reference: reference, calendar: utc)
        // An entry of its own: the rule's rerun.
        XCTAssertEqual(timeline.item(holding: TimelineFocus(identifier: "TP-1457", eventID: "j02")), "entry-j02")
        // The verdict sits in its run's group.
        XCTAssertEqual(timeline.item(holding: TimelineFocus(identifier: "TP-1457", eventID: "j01", runID: "r-1457-qa1")), "run-r-1457-qa1")
        // Neither on the pages read yet.
        XCTAssertNil(timeline.item(holding: TimelineFocus(identifier: "TP-1457", eventID: "gone")))
        XCTAssertNil(timeline.item(holding: TimelineFocus(identifier: "TP-1457", eventID: "gone", runID: "r-other")))
    }

    func testTheJournalsExplanation() {
        XCTAssertEqual(Journal.explanation, "What happened while you were away")
    }
}
