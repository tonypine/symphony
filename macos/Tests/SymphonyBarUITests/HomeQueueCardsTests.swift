import Foundation
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// TP-1609: Home's read drawn with the Gallery's components: a slot's ticket as its card, with Answer… only while it
/// waits on the person and each move's route; a queue row at its real number.
@MainActor
final class HomeQueueCardsTests: XCTestCase {
    private let reference = ISO8601DateFormatter().date(from: "2026-10-07T14:20:00Z")!

    private func fixtureRead() throws -> HomeRead {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/home-queue/api/v1")
        let fixture = try XCTUnwrap(HomeQueueFixture(try Data(contentsOf: directory.appendingPathComponent(HomeQueueFixture.fileName))))
        return try XCTUnwrap(HomeRead.decode(fixture.answer(query: "offset=0&limit=100", views: nil, slotCount: nil)))
    }

    // MARK: - c1 and c3: the cards and their moves

    func testAnswerIsOfferedOnlyOnTheCardThatWaitsOnThePerson() throws {
        let read = try fixtureRead()
        let working = HomeQueueCards.card(try XCTUnwrap(read.slots[0].ticket), reference: reference)
        let waiting = HomeQueueCards.card(try XCTUnwrap(read.slots[1].ticket), reference: reference)
        XCTAssertEqual(working.status, .working)
        XCTAssertEqual(working.actions, [.message, .stop])
        XCTAssertEqual(waiting.status, .you)
        XCTAssertEqual(waiting.actions, [.answer, .message, .stop])
        XCTAssertNil(read.slots[2].ticket, "the third slot is drawn as the empty outline")
        XCTAssertEqual(SlotCard.emptyLabel(3), "Slot 3")
    }

    func testTheCardCarriesTheReadsStagesTokensPlanAndPullRequest() throws {
        let read = try fixtureRead()
        let working = HomeQueueCards.card(try XCTUnwrap(read.slots[0].ticket), reference: reference)
        XCTAssertEqual(working.identifier, "TP-1619")
        XCTAssertEqual(working.stage, 0)
        XCTAssertEqual(working.since, "1 h 5 min")
        XCTAssertEqual(working.word, "Coding")
        XCTAssertEqual(working.sentence, "tests and coverage, round 2")
        XCTAssertEqual(working.tokens.map(\.name), ["Coding", "Code Review", "QA", "Merging"])
        XCTAssertEqual(working.tokens.first?.tokens, 14_200_000)
        XCTAssertEqual(working.tokenTotal, 14_200_000)
        XCTAssertEqual(working.tokenCap, 100_000_000)
        XCTAssertEqual(working.proved, 3)
        XCTAssertEqual(working.checks, 11)
        XCTAssertEqual(working.next, "Adding a dependency on a lower ticket is refused with the reason.")
        XCTAssertNil(working.pullRequest)

        let waiting = HomeQueueCards.card(try XCTUnwrap(read.slots[1].ticket), reference: reference)
        XCTAssertEqual(waiting.stage, 1)
        XCTAssertEqual(waiting.stages.map(\.word), ["Passed", "Waiting on you", "Not yet", "Not yet", "Not yet"])
        XCTAssertEqual(
            waiting.pullRequest,
            SlotCardModel.PullRequest(
                number: "#1043", size: "11 files · +524 −61", branch: "auto/TP-1594", ci: .init(.done, "Checks passed"),
                review: .init(.idle, "Not reviewed yet")
            )
        )
    }

    func testAStageAndAStateFallBackWhenTheReadSaysLess() {
        let bare = HomeRead.SlotTicket(identifier: "TP-1", stages: [HomeRead.Stage(id: "qa", name: "QA", state: "paused")])
        XCTAssertEqual(HomeQueueCards.stage(bare), 2)
        XCTAssertEqual(HomeQueueCards.stage(HomeRead.SlotTicket(identifier: "TP-1")), 0)
        let card = HomeQueueCards.card(bare, epic: "TP-1597", reference: reference)
        XCTAssertEqual(card.since, "—")
        XCTAssertEqual(card.plan, HomeQueueCards.noPlan)
        XCTAssertEqual(card.word, "In progress")
        XCTAssertEqual(card.epic, "TP-1597")
        XCTAssertEqual(card.title, "TP-1")

        var failing = HomeRead.SlotTicket(identifier: "TP-2")
        failing.situation = Situation(kind: .retrying, word: "Retrying", cause: "The run failed.")
        XCTAssertEqual(HomeQueueCards.status(failing), .problem)

        XCTAssertNil(HomeQueueCards.pullRequest(HomeRead.PullRequest()))
        XCTAssertEqual(HomeQueueCards.pullRequest(HomeRead.PullRequest(number: 7, filesChanged: 1))?.size, "1 file")
        XCTAssertEqual(HomeQueueCards.ci("failed"), .init(.problem, "Checks failed"))
        XCTAssertEqual(HomeQueueCards.ci("running"), .init(.working, "Checks running"))
        XCTAssertEqual(HomeQueueCards.ci(nil), .init(.idle, "No checks yet"))
        XCTAssertEqual(HomeQueueCards.review("APPROVED"), .init(.done, "Approved"))
        XCTAssertEqual(HomeQueueCards.review("changes_requested"), .init(.problem, "Changes requested"))
    }

    func testEachMoveOfACardGoesThroughItsRoute() throws {
        let read = try fixtureRead()
        let waiting = try XCTUnwrap(read.slots[1].ticket)
        XCTAssertEqual(HomeQueueCards.move(.answer, waiting), .answer(issueID: "issue-tp-1594"))
        XCTAssertEqual(HomeQueueCards.move(.message, waiting), .openTicket("TP-1594"))
        XCTAssertEqual(HomeQueueCards.move(.stop, waiting), .control(.stop("TP-1594")))

        var unblock = waiting
        unblock.move = HomeRead.Move(name: "unblock")
        XCTAssertEqual(HomeQueueCards.move(.answer, unblock), .control(.unblock("TP-1594")))
        var unknown = waiting
        unknown.issueID = nil
        XCTAssertEqual(HomeQueueCards.move(.answer, unknown), .openTicket("TP-1594"))
    }

    // MARK: - c4: a row at its real number

    func testARowKeepsItsNumberItsStateAndItsRepo() throws {
        let read = try fixtureRead()
        let first = HomeQueueCards.row(read.queue.rows[0])
        XCTAssertEqual(first.number, 1)
        XCTAssertNil(first.label)
        XCTAssertEqual(first.numberText, "1")
        XCTAssertEqual(first.identifier, "TP-1590")
        XCTAssertEqual(first.marks, [.init(.idle, "Code Review")])
        XCTAssertEqual(first.lead, .status(.working))
        XCTAssertEqual(first.repo, "symphony")

        let todo = HomeQueueCards.row(read.queue.rows[3])
        XCTAssertEqual(todo.identifier, "HUB-212")
        XCTAssertEqual(todo.number, 4)
        XCTAssertTrue(todo.marks.isEmpty)
        XCTAssertEqual(todo.lead, .glyph("clock", DesignTokens.TextColor.secondary))

        let sub = HomeQueueCards.row(HomeRead.Row(identifier: "TP-9", number: "6.1"))
        XCTAssertEqual(sub.number, 6)
        XCTAssertEqual(sub.numberText, "6.1")
        XCTAssertEqual(sub.title, "TP-9")

        let waiting = HomeQueueCards.row(HomeRead.Row(identifier: "TP-8", number: "1243", waitsOnYou: true))
        XCTAssertEqual(waiting.numberText, "1,243")
        XCTAssertEqual(waiting.marks, [.init(.you, DesignTokens.Status.you.word)])
    }
}
