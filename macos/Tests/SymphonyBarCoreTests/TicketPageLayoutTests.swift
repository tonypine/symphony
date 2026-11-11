import Foundation
import XCTest
@testable import SymphonyBarCore

/// The ticket page at laptop width (TP-1448): what each zone reads from the `ticket-page` fixture's three moments
/// (TP-1244 with a run working, TP-1245 waiting on your answer, TP-1246 shipped), the decisions line, and the layout.
final class TicketPageLayoutTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private var api: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/ticket-page/api/v1", isDirectory: true)
    }

    private func data(_ path: String) throws -> Data {
        try Data(contentsOf: api.appendingPathComponent(path))
    }

    private func page(_ identifier: String, events: Bool = true) throws -> TicketPage {
        TicketPage(
            identifier: identifier,
            sources: TicketPage.Sources(
                state: try data("state.json"),
                issue: try data("\(identifier).json"),
                events: events ? TicketEventsPayload.decode(try data("repos/symphony/tickets/\(identifier)/events.json")) : nil
            ),
            timeZone: utc
        )
    }

    private func inbox() throws -> [InboxItem] {
        try XCTUnwrap(InboxPayload.decode(data("inbox.json"))).items
    }

    // MARK: - The zones from the ticket read

    func testARunningTicketReadsItsSituationMovesLifecycleFactsAndHistory() throws {
        let page = try page("TP-1244")

        XCTAssertEqual(page.headerTitle, "The paused line on the ticket page")
        XCTAssertEqual(page.repoKey, "symphony")
        XCTAssertEqual(page.epicChip, "TP-1381 Phase 3b: the Director redesigned around a ticket's situation")
        XCTAssertEqual(page.situation?.kind, .working)
        XCTAssertEqual(page.situation?.word, "Working on the tests step")
        XCTAssertEqual(page.reference, ISO8601DateFormatter().date(from: "2026-10-08T10:27:00Z"))
        // The rail: Stop Run… allowed in More, Start Now refused because a run works on it.
        let rail = TicketActionRail(identifier: page.identifier, moves: try XCTUnwrap(page.moves))
        XCTAssertEqual(rail.items.first { $0.move == .start }?.reason, "A run is already working on it.")
        XCTAssertTrue(rail.more.contains { $0.move == .stop && $0.allowed })
        XCTAssertEqual(page.lifecycleRead?.lifecycle?.current, "coding")
        XCTAssertEqual(page.lifecycleRead?.phasePath?.current, "Rework")
        XCTAssertEqual(page.factsRead?.pullRequest?.number, 741)
        XCTAssertEqual(page.factsRead?.connected?.epic?.identifier, "TP-1381")
        XCTAssertEqual(page.detailsRead?.note?.text, "Keep the paused line to one row on a laptop; the reasons fold under it.")
        XCTAssertEqual(page.detailsRead?.ticket?.title, "The paused line on the ticket page")
        // The timeline: the run now first, live.
        let history = try XCTUnwrap(page.history)
        XCTAssertEqual(history.runs["run-2"]?.status, "running")
        let timeline = TimelineModel.build(history, runNow: page.runNow, reference: page.reference, calendar: calendar)
        XCTAssertEqual(timeline.items.first?.run?.id, "run-2")
        XCTAssertEqual(timeline.items.first?.run?.isLive, true)
        XCTAssertTrue(DecisionsLine(openQuestions: page.openQuestions, questions: TicketPage.questions(of: page.identifier, in: try inbox())).waiting == false)
    }

    func testAWaitingTicketHasItsQuestionOnTheDecisionsLineWithAnswer() throws {
        let page = try page("TP-1245")
        let questions = TicketPage.questions(of: page.identifier, in: try inbox())

        XCTAssertEqual(page.situation?.kind, .you)
        XCTAssertEqual(page.openQuestions, ["How should the paused line's times read?"])
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions.first?.options.map(\.label), ["For how long", "Since when"])
        let rail = TicketActionRail(identifier: page.identifier, moves: try XCTUnwrap(page.moves))
        XCTAssertEqual(rail.primary?.move, .answer)
        XCTAssertEqual(rail.request(.answer), .sheet(.answer))

        let line = DecisionsLine(openQuestions: page.openQuestions, questions: questions)
        XCTAssertTrue(line.waiting)
        XCTAssertEqual(line.title, "A question waits on you")
        XCTAssertEqual(line.detail, "How should the paused line's times read?")
        XCTAssertNil(line.answerReason)
        XCTAssertEqual(line.accessibilityLabel, "A question waits on you: How should the paused line's times read?")
        XCTAssertEqual(page.sheetSubtitle, "TP-1245 · The paused line's times")
    }

    func testAShippedTicketReadsDoneWithItsMergedPullRequest() throws {
        let page = try page("TP-1246")

        XCTAssertEqual(page.situation?.kind, .done)
        XCTAssertEqual(page.situation?.word, "Shipped")
        XCTAssertEqual(page.factsRead?.pullRequest?.state, "merged")
        XCTAssertNil(page.detailsRead?.note)
        XCTAssertEqual(page.lifecycleRead?.lifecycle?.stages.last?.id, "done")
        let rail = TicketActionRail(identifier: page.identifier, moves: try XCTUnwrap(page.moves))
        XCTAssertNil(rail.primary)
        XCTAssertEqual(rail.items.first { $0.move == .restart }?.reason, "The ticket is done.")
        XCTAssertEqual(DecisionsLine(openQuestions: page.openQuestions, questions: []).title, DecisionsLine.quietTitle)
    }

    func testAPageReadBeforeItsFeedHasNoHistory() throws {
        XCTAssertNil(try page("TP-1244", events: false).history)
    }

    func testAReadWithoutTheNewBlocksLeavesTheirZonesOut() {
        let page = TicketPage(identifier: "TP-1", sources: TicketPage.Sources(issue: Data(#"{"issue_identifier":"TP-1"}"#.utf8)), timeZone: utc)

        XCTAssertNil(page.situation)
        XCTAssertNil(page.lifecycleRead?.lifecycle)
        XCTAssertNil(page.factsRead?.pullRequest)
        XCTAssertNil(page.detailsRead?.note)
        XCTAssertNil(page.headerTitle)
        XCTAssertNil(page.epicChip)
        XCTAssertEqual(page.sheetSubtitle, "TP-1")
        XCTAssertNil(page.moveSheet(to: "Todo"))
    }

    // MARK: - The decisions line

    func testTheQuietLineSaysNothingNeedsYouAndOffersNoAnswer() {
        let line = DecisionsLine(openQuestions: [], questions: [])

        XCTAssertFalse(line.waiting)
        XCTAssertEqual(line.count, 0)
        XCTAssertEqual(line.title, "Nothing needs you")
        XCTAssertEqual(line.detail, DecisionsLine.quietDetail)
        XCTAssertNil(line.answerReason)
        XCTAssertEqual(line.accessibilityLabel, "Nothing needs you")
    }

    func testAQuestionSymphonyNamesBeforeTheInboxHoldsItKeepsAnswerOffWithItsReason() {
        let line = DecisionsLine(openQuestions: ["Pick a name", "Pick a colour"], questions: [])

        XCTAssertEqual(line.count, 2)
        XCTAssertEqual(line.title, "2 questions wait on you")
        XCTAssertEqual(line.detail, "Pick a name")
        XCTAssertEqual(line.answerReason, DecisionsLine.readingReason)
    }

    func testTheInboxQuestionsCountWhenSymphonyNamesFewer() throws {
        var question = try XCTUnwrap(TicketPage.questions(of: "TP-1245", in: try inbox()).first)
        question.title = nil
        let line = DecisionsLine(openQuestions: [], questions: [question, question])

        XCTAssertEqual(line.count, 2)
        XCTAssertEqual(line.detail, question.question)
        XCTAssertNil(line.answerReason)
    }

    // MARK: - Move to… from the rail

    func testMoveToOpensTheSheetForAPhaseTheStateListsAndNoneForTheCurrentOne() throws {
        let page = try page("TP-1244")

        let sheet = try XCTUnwrap(page.moveSheet(to: "todo"))
        XCTAssertEqual(sheet.identifier, "TP-1244")
        XCTAssertEqual(sheet.from, "Rework")
        XCTAssertEqual(sheet.to, MachinePhase(name: "Todo", dispatches: true))
        XCTAssertNil(page.moveSheet(to: "Rework"))
        XCTAssertNil(page.moveSheet(to: "Nowhere"))
    }

    // MARK: - The layout

    func testTheLaptopPageKeepsTheRailBesideAMainColumnThatFits() {
        XCTAssertEqual(TicketPageLayout.laptopPageWidth, 1240)
        XCTAssertTrue(TicketPageLayout.railBeside(page: TicketPageLayout.laptopPageWidth))
        // 1240 less two 24 pt margins, the gap and the 340 pt rail.
        XCTAssertEqual(TicketPageLayout.mainColumnWidth(page: 1240), 828)
    }

    func testANarrowPagePutsTheRailUnderTheMainColumn() {
        let narrowest = 2 * TicketPageLayout.gap + TicketPageLayout.mainColumnMinWidth + TicketPageLayout.gap + TicketPageLayout.railWidth
        XCTAssertTrue(TicketPageLayout.railBeside(page: narrowest))
        XCTAssertFalse(TicketPageLayout.railBeside(page: narrowest - 1))
        XCTAssertEqual(TicketPageLayout.mainColumnWidth(page: 700), 652)
        XCTAssertEqual(TicketPageLayout.mainColumnWidth(page: 0), 0)
    }

    // MARK: - The desktop width (TP-1449)

    func testTheBreakpointSwitchesToTheDesktopAt1600Points() {
        XCTAssertFalse(TicketPageLayout.isDesktop(page: 1590))
        XCTAssertFalse(TicketPageLayout.isDesktop(page: 1599.5))
        XCTAssertTrue(TicketPageLayout.isDesktop(page: 1600))
        XCTAssertTrue(TicketPageLayout.isDesktop(page: 1610))
        XCTAssertTrue(TicketPageLayout.isDesktop(page: TicketPageLayout.desktopPageWidth))
    }

    func testUnderTheBreakpointTheLaptopArrangementIsUnchanged() {
        for width in [TicketPageLayout.laptopPageWidth, 1590] {
            for decisions in [false, true] {
                let arrangement = TicketPageLayout.arrangement(page: width, decisions: decisions)
                XCTAssertFalse(arrangement.desktop)
                XCTAssertTrue(arrangement.railBeside)
                XCTAssertEqual(arrangement.railWidth, 340)
                XCTAssertNil(arrangement.decisionsWidth)
                XCTAssertEqual(arrangement.mainWidth, TicketPageLayout.mainColumnWidth(page: width))
                XCTAssertEqual(arrangement.columnGap, TicketPageLayout.gap)
                XCTAssertEqual(arrangement.contentWidth, width - 2 * TicketPageLayout.gap)
            }
        }
        XCTAssertFalse(TicketPageLayout.arrangement(page: 700, decisions: true).railBeside)
    }

    func testADesktopPageWithAQuestionPutsTheDecisionsInAColumnOnTheFarRight() {
        let arrangement = TicketPageLayout.arrangement(page: 2200, decisions: true)

        XCTAssertTrue(arrangement.desktop)
        XCTAssertEqual(arrangement.railWidth, 440)
        XCTAssertEqual(arrangement.decisionsWidth, 600)
        XCTAssertEqual(arrangement.columnGap, 32)
        // 2200 less two 24 pt margins, two 32 pt gaps, the 440 pt rail and the 600 pt column: the main column is fluid.
        XCTAssertEqual(arrangement.mainWidth, 1048)
        XCTAssertEqual(arrangement.contentWidth, 2152)
        // Just past the breakpoint the columns keep their widths and the main column gives way.
        XCTAssertEqual(TicketPageLayout.arrangement(page: 1610, decisions: true).mainWidth, 458)
    }

    func testADesktopPageWithNothingWaitingGivesTheMainColumnUpTo1040Points() {
        let arrangement = TicketPageLayout.arrangement(page: 2200, decisions: false)

        XCTAssertNil(arrangement.decisionsWidth)
        XCTAssertEqual(arrangement.mainWidth, 1040)
        // The columns are centred: the main column, the gap and the rail.
        XCTAssertEqual(arrangement.contentWidth, 1512)
        // At the breakpoint there is already more than 1040 pt beside the rail; wider gives the margins the room.
        XCTAssertEqual(TicketPageLayout.arrangement(page: 1600, decisions: false).mainWidth, 1040)
        XCTAssertEqual(TicketPageLayout.arrangement(page: 3000, decisions: false).mainWidth, 1040)
    }

    // MARK: - Sticky columns

    func testAShortRailSticksUnderTheWindowsTopAndNeverLeavesItsRow() {
        // The row starts 150 pt down the page and is 3000 pt tall; the rail is 800 pt in a 1360 pt window.
        func offset(_ scroll: Double) -> Double {
            TicketPageLayout.stickyOffset(scroll: scroll, viewport: 1360, top: 150, height: 800, room: 3000)
        }
        XCTAssertEqual(offset(0), 0)
        XCTAssertEqual(offset(126), 0)
        XCTAssertEqual(offset(500), 374)
        // At the row's end it stops.
        XCTAssertEqual(offset(5000), 2200)
    }

    func testATallRailScrollsUntilItsFootIsInViewThenStays() {
        // A 2000 pt rail in a 1360 pt window: it scrolls with the page until its foot is 24 pt above the window's bottom.
        func offset(_ scroll: Double) -> Double {
            TicketPageLayout.stickyOffset(scroll: scroll, viewport: 1360, top: 150, height: 2000, room: 4000)
        }
        XCTAssertEqual(offset(0), 0)
        XCTAssertEqual(offset(814), 0)
        XCTAssertEqual(offset(1000), 186)
        // A rail as tall as its row never moves.
        XCTAssertEqual(TicketPageLayout.stickyOffset(scroll: 1000, viewport: 1360, top: 150, height: 2000, room: 2000), 0)
    }

    func testTheDecisionsColumnKeepsItsHeaderAndSendInView() {
        // Before the page scrolls the column starts with its row and ends 24 pt above the window's bottom.
        let start = TicketPageLayout.pinnedDecisions(rowTop: 150, viewport: 1360)
        XCTAssertEqual(start.top, 150)
        XCTAssertEqual(start.height, 1186)
        XCTAssertEqual(TicketPageLayout.decisionsColumnRoom(viewport: 1360, top: 150), 1186)
        // Once the row scrolls up past the visible top, the column sticks 24 pt under it, as tall as the window less
        // the margins.
        let scrolled = TicketPageLayout.pinnedDecisions(rowTop: -450, viewport: 1360)
        XCTAssertEqual(scrolled.top, 24)
        XCTAssertEqual(scrolled.height, 1312)
        // What a toolbar and a banner cover stays out of it; in a tiny window it keeps its least height.
        let covered = TicketPageLayout.pinnedDecisions(rowTop: -450, viewport: 1360, insetTop: 52, insetBottom: 60)
        XCTAssertEqual(covered.top, 76)
        XCTAssertEqual(covered.height, 1200)
        XCTAssertEqual(TicketPageLayout.pinnedDecisions(rowTop: 150, viewport: 300).height, 320)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }
}
