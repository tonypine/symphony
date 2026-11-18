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
        // The epic chip says the epic's short name; its whole title is the tooltip and VoiceOver's words (TP-1485).
        XCTAssertEqual(page.epicChip?.shortName, "Phase 3b")
        XCTAssertEqual(page.epicChip?.fullTitle, "Epic TP-1381: Phase 3b: the Director redesigned around a ticket's situation")
        // The identifier's line: the priority, then the labels.
        XCTAssertEqual(page.headerPriority, "Urgent")
        XCTAssertEqual(page.headerLabels, ["skip-update-hold"])
        // The rail's links: the pull request and the run's workspace.
        XCTAssertEqual(page.railLinks.pullRequest, URL(string: "https://github.com/acme/symphony/pull/741"))
        XCTAssertEqual(page.railLinks.workspacePath, "/Users/director/symphony-workspaces/symphony/TP-1244")
        XCTAssertEqual(page.situation?.kind, .working)
        XCTAssertEqual(page.situation?.word, "Working on the tests step")
        XCTAssertEqual(page.reference, ISO8601DateFormatter().date(from: "2026-10-08T10:27:00Z"))
        // The rail: Stop Run… allowed in More, Start Now refused because a run works on it.
        let rail = TicketActionRail(identifier: page.identifier, moves: try XCTUnwrap(page.moves))
        XCTAssertEqual(rail.items.first { $0.move == .start }?.reason, "A run is already working on it.")
        XCTAssertEqual(rail.stop?.allowed, true)
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
        // The marks (TP-1451): looked at 09:30, eight events since; the finding, the note and the Rework entry are new.
        XCTAssertEqual(page.marksRead?.newText, "8 new")
        let marked = TimelineModel.build(
            history, runNow: page.runNow, reference: page.reference, calendar: calendar, lookedAt: page.marksRead?.lookedAt
        )
        XCTAssertEqual(marked.marker?.before, "entry-v1")
        XCTAssertEqual(marked.items.filter(\.isNew).map(\.id), ["run-run-2", "entry-m1", "entry-n1", "entry-v2"])
        XCTAssertTrue(DecisionsLine(openQuestions: page.openQuestions, questions: TicketPage.questions(of: page.identifier, in: try inbox())).waiting == false)
    }

    func testAWaitingTicketHasItsQuestionOnTheDecisionsLineWithAnswer() throws {
        let page = try page("TP-1245")
        let questions = TicketPage.questions(of: page.identifier, in: try inbox())

        XCTAssertEqual(page.situation?.kind, .you)
        XCTAssertEqual(page.openQuestions, ["How should the times on the paused line read in dark mode?"])
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions.first?.options.map(\.label), ["Use the secondary text colour", "Keep the light colour, one size up", "Drop the times from the line"])
        let rail = TicketActionRail(identifier: page.identifier, moves: try XCTUnwrap(page.moves))
        XCTAssertEqual(rail.primary?.move, .answer)
        XCTAssertEqual(rail.request(.answer), .sheet(.answer))

        let line = DecisionsLine(openQuestions: page.openQuestions, questions: questions)
        XCTAssertTrue(line.waiting)
        XCTAssertEqual(line.title, "A question waits on you")
        XCTAssertEqual(line.detail, "How should the times on the paused line read in dark mode?")
        XCTAssertNil(line.answerReason)
        XCTAssertEqual(line.accessibilityLabel, "A question waits on you: How should the times on the paused line read in dark mode?")
        XCTAssertEqual(page.sheetSubtitle, "TP-1245 · The paused line on the ticket page")
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

    // MARK: - The header's identifier line and title (TP-1485)

    private func header(_ ticket: String, connected: String = "null") -> TicketPage {
        let json = #"{"issue_identifier":"TP-1","ticket":\#(ticket),"connected":\#(connected)}"#
        return TicketPage(identifier: "TP-1", sources: TicketPage.Sources(issue: Data(json.utf8)), timeZone: utc)
    }

    func testNoPriorityShowsNeitherTheHairlineNorASlot_AndNoLabelsShowsThePriorityAlone() {
        let alone = header(#"{"title":"T","priority":2,"labels":[]}"#)
        XCTAssertEqual(alone.headerPriority, "High")
        XCTAssertEqual(alone.headerLabels, [])
        // Linear's 0 is No priority: nothing is drawn for it, as for a ticket without one.
        XCTAssertNil(header(#"{"title":"T","priority":0,"labels":["mac"," "]}"#).headerPriority)
        XCTAssertEqual(header(#"{"title":"T","priority":0,"labels":["mac"," "]}"#).headerLabels, ["mac"])
        XCTAssertNil(header(#"{"title":"T"}"#).headerPriority)
    }

    func testTheEpicChipSaysTheShortNameAndKeepsTheWholeTitleForItsTooltip() {
        let page = header(#"{"title":"T"}"#, connected: #"{"epic":{"identifier":"TP-9","title":"Pauses","done":1,"total":3,"tickets":[]},"blocked_by":[],"blocks":[]}"#)
        XCTAssertEqual(page.epicChip?.shortName, "Pauses")
        XCTAssertEqual(page.epicChip?.fullTitle, "Epic TP-9: Pauses")
        XCTAssertEqual(EpicChip(identifier: "TP-9", title: " ").shortName, "TP-9")
        XCTAssertEqual(EpicChip(identifier: "TP-9", title: nil).fullTitle, "Epic TP-9")
        XCTAssertEqual(EpicChip(identifier: "TP-9", title: ": Pauses").shortName, "Pauses")
        XCTAssertEqual(EpicChip.maxTextWidth, 160)
        // Without the read's epic, the plan the state's lanes name.
        var lane = header(#"{"title":"T"}"#)
        lane.initiative = "SHOP-300 Gift cards: the new flow"
        XCTAssertEqual(lane.epicChip, EpicChip(identifier: "SHOP-300", title: "Gift cards: the new flow"))
        XCTAssertEqual(lane.epicChip?.shortName, "Gift cards")
        lane.initiative = "SHOP-300"
        XCTAssertEqual(lane.epicChip?.shortName, "SHOP-300")
        lane.initiative = "  "
        XCTAssertNil(lane.epicChip)
    }

    func testTheTitleTakesTheTitleStyleUpTo30EmOnALaptopAnd56OnADesktop_AndThreeLines() {
        XCTAssertEqual(TicketPageHeaderLayout.titleWidth(desktop: false), 780)
        XCTAssertEqual(TicketPageHeaderLayout.titleWidth(desktop: true), 1456)
        XCTAssertEqual(TicketPageHeaderLayout.titleLines, 3)
    }

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
        // 1440 less the 232 pt sidebar (TP-1498).
        XCTAssertEqual(TicketPageLayout.laptopPageWidth, 1208)
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

    func testTheDesktopHeaderLeavesAnswerToTheDecisionsColumn() throws {
        let page = try page("TP-1245")
        let moves = try XCTUnwrap(page.moves)
        // The laptop's header offers Answer first; the desktop's has the decisions column open beside it instead (§5).
        XCTAssertEqual(TicketActionRail(identifier: page.identifier, moves: moves).primary?.move, .answer)
        let desktop = TicketActionRail(identifier: page.identifier, moves: moves, omitting: [.answer])
        XCTAssertFalse(desktop.items.contains { $0.move == .answer })
        XCTAssertNil(desktop.request(.answer))
        XCTAssertNotEqual(desktop.primary?.move, .answer)
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
