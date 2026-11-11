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

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }
}
