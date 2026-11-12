import Foundation
@testable import SymphonyBarCore
import XCTest

/// Reports in the Journal (TP-1462) from the `journal` fixture: the night's report, which cites the night's events and
/// asks a Question, and the evening's, whose citations only the read of its period resolves.
final class JournalReportsTests: XCTestCase {
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

    private func data(_ name: String) throws -> Data {
        try Data(contentsOf: Self.api.appendingPathComponent("\(name).json"))
    }

    private func night() throws -> JournalPayload {
        try XCTUnwrap(JournalPayload.decode(data("events")))
    }

    private func reports() throws -> [JournalReport] {
        try XCTUnwrap(JournalReportsPayload.decode(data("reports"))).reports
    }

    private func report(_ id: String) throws -> JournalReport {
        try XCTUnwrap(try reports().first { $0.id == id })
    }

    /// The citations as the Journal resolves them: the night's events, and with `periods` the evening's period read.
    private func citations(periods: Bool = true) throws -> JournalCitations {
        var citations = JournalCitations(try night().events)
        if periods {
            let evening = try XCTUnwrap(try report("rep-2100").periodEventsPath)
            let (answer, _) = fixtures.answer(URLRequest(url: URL(string: "/" + evening, relativeTo: APIFixtures.baseURL)!))
            citations.take(try XCTUnwrap(JournalPayload.decode(answer)).events)
        }
        return citations
    }

    private var fixtures: APIFixtures {
        APIFixtures(directory: Self.api.deletingLastPathComponent().deletingLastPathComponent(), requestLog: FileManager.default.temporaryDirectory.appendingPathComponent("journal-reports-requests.jsonl"))
    }

    private func cards(periods: Bool = true) throws -> [JournalReportCard] {
        let citations = try citations(periods: periods)
        return try reports().compactMap { JournalReportCard.build($0, citations: citations, calendar: utc) }
    }

    private func card(_ id: String) throws -> JournalReportCard {
        try XCTUnwrap(try cards().first { $0.id == id })
    }

    // MARK: - The reads

    func testTheReportsReadAsSymphonyServesThem() throws {
        let night = try report("rep-0300")
        XCTAssertEqual(night.model, "claude-haiku-5-5")
        XCTAssertEqual(night.period, JournalReport.Period(from: "2026-11-11T21:00:00Z", to: "2026-11-12T03:00:00Z"))
        XCTAssertEqual(night.sentences.count, 5)
        XCTAssertEqual(night.cited(0), ["j13", "j12", "j11"])
        XCTAssertEqual(night.cited(9), [])
        XCTAssertEqual(night.questionID, "q-report-0300")
        XCTAssertNil(try report("rep-2100").questionID)
        XCTAssertEqual(night.pinnedAt, ISO8601DateFormatter().date(from: "2026-11-12T03:00:00Z"))
    }

    func testAReportThatDoesNotReadIsSkippedAndAPageThatDoesNotReadIsNil() {
        let payload = JournalReportsPayload.decode(Data(#"{"reports":[{"at":"x"},{"id":"r1","period":{"to":"2026-11-12T03:00:00Z"}}]}"#.utf8))
        XCTAssertEqual(payload?.reports.map(\.id), ["r1"])
        XCTAssertNil(JournalReportsPayload.decode(Data("nope".utf8)))
    }

    func testTheReportsReadAsksForTheReportsSinceTheOldestEventHeld() {
        XCTAssertEqual(JournalReportsPayload.path(), "api/v1/reports")
        XCTAssertEqual(JournalReportsPayload.path(since: "2026-11-11T21:00:00+01:00"), "api/v1/reports?since=2026-11-11T21:00:00%2B01:00")
    }

    func testAPeriodIsReadAsTheReportRunReadIt() throws {
        XCTAssertEqual(
            try report("rep-2100").periodEventsPath,
            "api/v1/events?limit=200&notable=true&since=2026-11-11T15:00:00Z&until=2026-11-11T21:00:00Z"
        )
        XCTAssertNil(JournalReport(id: "r", period: .init(from: nil, to: "2026-11-12T03:00:00Z")).periodEventsPath)
    }

    func testTheFixtureAnswersTheReportsAndThePeriodRead() throws {
        let (answer, _) = fixtures.answer(URLRequest(url: URL(string: "/" + JournalReportsPayload.path(), relativeTo: APIFixtures.baseURL)!))
        XCTAssertEqual(JournalReportsPayload.decode(answer)?.reports.count, 2)
        XCTAssertEqual(try citations().events.count, try night().events.count + 3)
    }

    // MARK: - Citations

    /// Each citation resolves to its event: a cited sentence's link opens its ticket's page at the very event it
    /// names, in the order the report cites them; an event on Symphony's own stream opens no page.
    func testEachCitationResolvesToItsEvent() throws {
        let citations = try citations()
        for report in try reports() {
            let card = try XCTUnwrap(JournalReportCard.build(report, citations: citations, calendar: utc))
            for sentence in card.sentences {
                let cited = report.cited(sentence.index)
                XCTAssertEqual(sentence.events, cited)
                let onTickets = cited.filter { citations.events[$0]?.ticket.identifier != nil }
                XCTAssertEqual(sentence.focuses.map(\.eventID), onTickets, "sentence \(sentence.index) of \(report.id)")
                for focus in sentence.focuses {
                    XCTAssertEqual(focus.identifier, citations.events[focus.eventID]?.ticket.identifier)
                }
            }
        }
        let night = try card("rep-0300")
        XCTAssertEqual(night.sentences[0].focus, TimelineFocus(identifier: "TP-1454", eventID: "j13", runID: nil))
        XCTAssertEqual(night.sentences[1].focuses.map(\.identifier), ["TP-1457", "TP-1458"])
        // The release's sentence rests on Symphony's own stream: no ticket page holds it.
        XCTAssertNil(night.sentences[3].focus)
        XCTAssertNil(night.sentences[3].linkLabel)
        XCTAssertEqual(night.sentences[2].linkLabel, "Open TP-1456 at the event this sentence rests on")
        let evening = try card("rep-2100")
        XCTAssertEqual(evening.sentences[1].focuses, [
            TimelineFocus(identifier: "BIL-300", eventID: "p02", runID: "r-300-qa1"),
            TimelineFocus(identifier: "BIL-300", eventID: "p03", runID: "r-300-qa2"),
        ])
    }

    func testThePeriodReadIsNeededOnlyForAReportThePagesDoNotResolve() throws {
        let pages = try citations(periods: false)
        XCTAssertTrue(pages.resolves(try report("rep-0300")))
        XCTAssertFalse(pages.resolves(try report("rep-2100")))
        XCTAssertTrue(try citations().resolves(try report("rep-2100")))
        // Before the period is read its sentences link nothing.
        let evening = try XCTUnwrap(JournalReportCard.build(try report("rep-2100"), citations: pages, calendar: utc))
        XCTAssertTrue(evening.sentences.allSatisfy { $0.focus == nil })
        XCTAssertEqual(evening.tickets, [])
    }

    func testTheTicketsTheReportRestsOnAreItsChipsInOrderOfCitation() throws {
        let night = try card("rep-0300")
        XCTAssertEqual(night.tickets.map(\.identifier), ["TP-1454", "TP-1455", "TP-1457", "TP-1458", "TP-1456", "SHOP-501"])
        XCTAssertEqual(night.tickets.first?.eventID, "j13")
        XCTAssertEqual(night.events(of: "TP-1455"), ["j12", "j11"])
        XCTAssertEqual(night.events(of: "TP-9"), [])
        if case let .ticket(ticket)? = night.references["TP-1457"] {
            XCTAssertEqual(ticket.title, "3b (20/26): Initiatives as the epic's story")
            XCTAssertEqual(ticket.repoKey, "symphony")
        } else {
            XCTFail("TP-1457 is not a ticket reference")
        }
        XCTAssertNil(night.references["Symphony"])
    }

    // MARK: - The card

    func testTheCardReadsTheSentencesAsOneParagraphWithEachSentencesPlaceInIt() throws {
        let night = try card("rep-0300")
        let report = try report("rep-0300")
        XCTAssertEqual(night.text, report.sentences.joined(separator: " "))
        for sentence in night.sentences {
            XCTAssertEqual((night.text as NSString).substring(with: sentence.range), report.sentences[sentence.index])
        }
        XCTAssertEqual(night.period, "21:00 – 03:00")
        XCTAssertEqual(night.modelLine, "Written by claude-haiku-5-5")
        XCTAssertEqual(night.accessibilityLabel, "Report, 21:00 – 03:00, 5 sentences, written by claude-haiku-5-5")
        XCTAssertEqual(night.questionID, "q-report-0300")
    }

    func testAPeriodOfADayOrMoreNamesItsDays() {
        let daily = JournalReport(
            id: "d", model: " ", period: .init(from: "2026-11-11T06:00:00Z", to: "2026-11-12T06:00:00Z"), sentences: ["One thing happened."]
        )
        let card = JournalReportCard.build(daily, citations: JournalCitations(), calendar: utc)
        XCTAssertEqual(card?.period, "Wed 11 Nov 06:00 – Thu 12 Nov 06:00")
        XCTAssertNil(card?.model)
        XCTAssertEqual(card?.accessibilityLabel, "Report, Wed 11 Nov 06:00 – Thu 12 Nov 06:00, 1 sentence")
    }

    func testAReportWithoutSentencesUsesItsTextAndOneWithoutEitherOrATimeHasNoCard() {
        let citations = JournalCitations()
        let textOnly = JournalReport(id: "t", at: "2026-11-12T03:00:00Z", text: "All quiet.")
        let card = JournalReportCard.build(textOnly, citations: citations, calendar: utc)
        XCTAssertEqual(card?.text, "All quiet.")
        XCTAssertEqual(card?.period, "03:00")
        XCTAssertNil(JournalReportCard.build(JournalReport(id: "e", at: "2026-11-12T03:00:00Z", sentences: [" "]), citations: citations, calendar: utc))
        XCTAssertNil(JournalReportCard.build(JournalReport(id: "n", sentences: ["A thing."]), citations: citations, calendar: utc))
        // A blank sentence is left out, and the ones after it keep their index for their citations.
        let gap = JournalReport(
            id: "g", period: .init(to: "2026-11-12T03:00:00Z"), sentences: ["First.", "", "Third."],
            citations: [.init(sentence: 2, events: ["x"])]
        )
        let gapped = JournalReportCard.build(gap, citations: citations, calendar: utc)
        XCTAssertEqual(gapped?.text, "First. Third.")
        XCTAssertEqual(gapped?.sentences.map(\.index), [0, 2])
        XCTAssertEqual(gapped?.sentences.last?.events, ["x"])
    }

    // MARK: - Where a report pins

    func testEachReportPinsAmongTheEventsAtTheEndOfItsPeriod() throws {
        var feed = JournalFeed()
        feed.takeNewest(try night())
        let model = JournalModel.build(feed, reports: try cards(), reference: reference, calendar: utc)
        let today = try XCTUnwrap(model.days.first)
        XCTAssertEqual(today.relative, "Today")
        // The night's report ends at 03:00: after the 03:05 and 03:20 events, before the 02:48 one.
        XCTAssertEqual(today.items.prefix(4).map(\.id), ["event:j01", "event:j02", "report:rep-0300", "event:j03"])
        XCTAssertEqual(today.reports.map(\.id), ["rep-0300"])
        XCTAssertEqual(today.rows.count, 12)
        XCTAssertEqual(today.accessibilityLabel, "Today, Thu 12 Nov, 12 events, 1 report")
        // The evening's ends at 21:00, with the event at 21:00 itself above it: that came after its period.
        let yesterday = try XCTUnwrap(model.days.last)
        XCTAssertEqual(yesterday.items.suffix(2).map(\.id), ["event:j16", "report:rep-2100"])
        XCTAssertEqual(model.reports.map(\.id), ["rep-0300", "rep-2100"])
        XCTAssertEqual(model.rows.count, 16)
    }

    func testReportsOnlyKeepsTheReportsAlone() throws {
        var feed = JournalFeed()
        feed.takeNewest(try night())
        let model = JournalModel.build(feed, reports: try cards(), reportsOnly: true, reference: reference, calendar: utc)
        XCTAssertEqual(model.rows, [])
        XCTAssertEqual(model.days.map(\.id), ["2026-11-12", "2026-11-11"])
        XCTAssertEqual(model.days.map(\.accessibilityLabel), ["Today, Thu 12 Nov, 0 events, 1 report", "Yesterday, Wed 11 Nov, 0 events, 1 report"])
        XCTAssertTrue(JournalModel.build(feed, reportsOnly: true, reference: reference, calendar: utc).isEmpty)
        XCTAssertEqual(JournalModel.emptyTitle(JournalQuery(epic: "TP-1", reportsOnly: true)), JournalModel.noReport)
    }

    func testAReportOlderThanThePagesWaitsForShowEarlier() throws {
        let page = try night()
        var feed = JournalFeed()
        feed.takeNewest(JournalPayload(events: page.events.filter { $0.id != "j16" }, nextUntil: "2026-11-11T21:30:00Z"))
        let cards = try cards()
        XCTAssertEqual(JournalModel.build(feed, reports: cards, reference: reference, calendar: utc).reports.map(\.id), ["rep-0300"])
        feed.takeEarlier(JournalPayload(events: page.events.filter { $0.id == "j16" }, nextUntil: nil))
        XCTAssertEqual(JournalModel.build(feed, reports: cards, reference: reference, calendar: utc).reports.map(\.id), ["rep-0300", "rep-2100"])
    }

    func testTwoReportsOnOneDayPinNewestFirstAndADayWithOnlyAReportHasItsOwnSeparator() {
        let citations = JournalCitations()
        let cards = [("a", "2026-11-12T01:00:00Z"), ("b", "2026-11-12T02:00:00Z"), ("c", "2026-11-09T12:00:00Z")].compactMap { id, to in
            JournalReportCard.build(JournalReport(id: id, period: .init(to: to), sentences: ["A thing."]), citations: citations, calendar: utc)
        }
        let model = JournalModel.build(JournalFeed(), reports: cards, reference: reference, calendar: utc)
        XCTAssertEqual(model.days.map(\.id), ["2026-11-12", "2026-11-09"])
        XCTAssertEqual(model.days.first?.items.map(\.id), ["report:b", "report:a"])
        XCTAssertNil(model.days.last?.relative)
    }

    func testReportsOnlyReadsNothingAgain() {
        XCTAssertTrue(JournalQuery(epic: "TP-1").readsAsTheSame(JournalQuery(epic: "TP-1", reportsOnly: true)))
        XCTAssertFalse(JournalQuery(epic: "TP-1").readsAsTheSame(JournalQuery(reportsOnly: true)))
        XCTAssertEqual(JournalQuery(reportsOnly: true).path(), JournalQuery().path())
    }

    // MARK: - The report's Question in the Inbox

    /// A report's Question is on Symphony itself: the Inbox lists it with no ticket, Send Decision answers it by its id
    /// alone, and nothing sends it to Rework.
    func testTheReportsQuestionIsAnInboxItemOnSymphonyAnsweredByItsIdAlone() throws {
        let inbox = try XCTUnwrap(InboxPayload.decode(data("inbox")))
        let item = try XCTUnwrap(inbox.items.first)
        XCTAssertEqual(item.id, "question:q-report-0300")
        XCTAssertEqual(item.identifier, "Symphony")
        XCTAssertEqual(item.subject, "symphony")
        XCTAssertTrue(item.isSubject)
        XCTAssertTrue(item.isDecision)
        XCTAssertEqual(item.review.action?.questionID, try report("rep-0300").questionID)

        let toolbar = InboxToolbar.toolbar(for: item, picks: DecisionPicks(picks: [0: 0]))
        XCTAssertEqual(toolbar.buttons.map(\.command), [.move(.decide)])
        XCTAssertEqual(toolbar.overflow, [])

        let sheet = ConsequenceSheet(move: .decide, item: item, picks: DecisionPicks(picks: [0: 0]))
        XCTAssertTrue(sheet.isSubject)
        XCTAssertEqual(sheet.title, "Send \"Wait for TP-1475\"?")
        XCTAssertEqual(sheet.stays, "No ticket moves and nothing is paused: the question waited on you alone.")
        let action = try XCTUnwrap(sheet.action())
        guard case let .decide(identifier, request, picks, move) = action else { return XCTFail("\(action) is no decide") }
        XCTAssertEqual(identifier, "")
        XCTAssertEqual(request, .question("q-report-0300"))
        XCTAssertEqual(picks.map(\.answer), ["Wait for TP-1475"])
        XCTAssertNil(move)
        XCTAssertNil(action.body["issue_identifier"])
        XCTAssertEqual(action.body["question_id"] as? String, "q-report-0300")
        XCTAssertEqual(action.failurePrefix, "Couldn't send the decision")
        XCTAssertEqual(ControlAction.decide("TP-1", request: .question("q"), picks: [], move: nil).body["issue_identifier"] as? String, "TP-1")

        // Without an option's effect, the sheet says what it records.
        var bare = item
        bare.review.action?.options = bare.review.action?.options.map { option in
            var option = option
            option.effect = nil
            return option
        } ?? []
        XCTAssertEqual(ConsequenceSheet(move: .decide, item: bare, picks: DecisionPicks(picks: [0: 0])).happens, "Records your answer to Symphony's question.")
    }

    func testAnItemWithNoTicketAndNoQuestionStillDoesNotRead() {
        let json = #"{"items":[{"issue_id":null,"identifier":null,"title":"Symphony","kind":"action","review":{"why":"x"}},"#
            + #"{"issue_id":null,"identifier":null,"title":"web-shop","kind":"action","subject":"repository","review":{"why":"y","question_id":"q2"}}]}"#
        let items = InboxPayload.decode(Data(json.utf8))?.items
        XCTAssertEqual(items?.map(\.id), ["question:q2"])
        XCTAssertEqual(items?.first?.identifier, "web-shop")
        XCTAssertEqual(items?.first?.subject, "repository")
    }
}
