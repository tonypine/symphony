import Foundation
import XCTest
@testable import SymphonyBarCore

/// The Action rail (TP-1440): the ticket read's `moves` as the app decodes them from
/// `test/fixtures/api/ticket_moves.json`, and the rail's set, order, primary and requests, all from the read.
final class ActionRailTests: XCTestCase {
    private func fixture() throws -> [String: TicketMoves] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("test/fixtures/api/ticket_moves.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let tickets = try XCTUnwrap(root["tickets"] as? [[String: Any]])
        var reads: [String: TicketMoves] = [:]
        for ticket in tickets {
            let name = try XCTUnwrap(ticket["name"] as? String)
            reads[name] = try XCTUnwrap(TicketMoves.of(issue: JSONSerialization.data(withJSONObject: ticket)), name)
        }
        return reads
    }

    private func rail(_ name: String) throws -> TicketActionRail {
        TicketActionRail(identifier: "TP-1", moves: try XCTUnwrap(try fixture()[name], "the fixture has no \(name)"))
    }

    private func moves(_ items: [TicketActionRail.Item]) -> [TicketActionRail.Move] { items.map(\.move) }

    private static let everyMoveAllowed = TicketMoves(Dictionary(uniqueKeysWithValues: TicketActionRail.Move.allCases.map {
        ($0.rawValue, TicketMoveRead(allowed: true, states: $0 == .moveTo ? ["Todo", "Done"] : []))
    }))

    // MARK: - Decoding

    func testTheReadDecodesEachMoveWithItsReasonAndMoveTosPhases() throws {
        let working = try XCTUnwrap(try fixture()["working"])
        XCTAssertEqual(working["start"], TicketMoveRead(allowed: false, reason: "A run is already working on it."))
        XCTAssertEqual(working["stop"], TicketMoveRead(allowed: true))
        XCTAssertEqual(working["move_to"]?.states, ["Backlog", "Todo", "Code Review", "Rework", "Done"])
    }

    func testAPayloadWithoutMovesHasNone_AndAnUnreadableEntryIsLeftOut() throws {
        XCTAssertNil(TicketMoves.of(issue: nil))
        XCTAssertNil(TicketMoves.of(issue: Data(#"{"identifier":"TP-1"}"#.utf8)))
        let moves = try XCTUnwrap(TicketMoves.of(issue: Data(#"""
        {"moves": {"start": {"allowed": true}, "stop": {"reason": "no allowed"}, "force": {"allowed": false, "reason": "  "}}}
        """#.utf8)))
        XCTAssertEqual(moves.entries, ["start": TicketMoveRead(allowed: true), "force": TicketMoveRead(allowed: false)])
    }

    // MARK: - The set, the order and the primary follow the read

    func testAWorkingRun_StartRefused_StopRunLastInMore() throws {
        let rail = try rail("working")
        XCTAssertNil(rail.primary)
        XCTAssertEqual(moves(rail.secondary), [.start, .force])
        XCTAssertEqual(rail.secondary.first?.reason, "A run is already working on it.")
        XCTAssertEqual(moves(rail.more), [.answer, .unblock, .moveTo, .restart, .cancel, .note, .stop])
        XCTAssertEqual(rail.more.last?.destructive, true)
        XCTAssertEqual(rail.more.last?.allowed, true)
    }

    func testWaitingOnYou_AnswerIsThePrimary() throws {
        let rail = try rail("waiting_on_you")
        XCTAssertEqual(rail.primary?.move, .answer)
        XCTAssertEqual(rail.primary?.title, "Answer")
        XCTAssertEqual(moves(rail.secondary), [.start, .force])
        XCTAssertEqual(rail.secondary.first?.reason, "It waits on your answer first.")
        XCTAssertEqual(moves(rail.more), [.unblock, .moveTo, .restart, .cancel, .note, .stop])
        XCTAssertEqual(rail.more.last?.reason, "No run is working.")
    }

    func testAHeldTicket_UnblockIsThePrimary() throws {
        let rail = try rail("held")
        XCTAssertEqual(rail.primary?.move, .unblock)
        XCTAssertEqual(moves(rail.secondary), [.start, .force])
        XCTAssertEqual(moves(rail.more), [.answer, .moveTo, .restart, .cancel, .note, .stop])
    }

    func testNothingRunning_StartNowIsThePrimary() throws {
        let rail = try rail("nothing_running")
        XCTAssertEqual(rail.primary?.move, .start)
        XCTAssertEqual(moves(rail.secondary), [.force])
    }

    func testADoneTicket_EveryRefusalSaysWhy() throws {
        let rail = try rail("done")
        XCTAssertNil(rail.primary)
        XCTAssertEqual(rail.secondary.map(\.reason), ["The ticket is done.", "The ticket is done."])
        XCTAssertEqual(rail.more.first { $0.move == .restart }?.reason, "The ticket is done.")
        XCTAssertNil(rail.more.first { $0.move == .moveTo }?.reason)
    }

    func testOnlyTheMovesTheReadJudgedAreOffered_AndARefusalWithoutAReasonStillSaysOne() {
        let rail = TicketActionRail(identifier: "TP-1", moves: TicketMoves([
            "stop": TicketMoveRead(allowed: false), "unforce": TicketMoveRead(allowed: false, reason: "It isn't forced."),
        ]))
        XCTAssertNil(rail.primary)
        XCTAssertEqual(moves(rail.secondary), [.unforce])
        XCTAssertEqual(moves(rail.more), [.stop])
        XCTAssertEqual(rail.more.first?.reason, TicketActionRail.unknownReason)
        XCTAssertEqual(moves(TicketActionRail(identifier: "TP-1", moves: TicketMoves([:])).items), [])
    }

    func testAForcedTicketOffersStopForcingInForcesPlace() {
        let rail = TicketActionRail(identifier: "TP-1", moves: TicketMoves([
            "force": TicketMoveRead(allowed: false, reason: "It is already forced."), "unforce": TicketMoveRead(allowed: true),
        ]))
        XCTAssertEqual(moves(rail.secondary), [.unforce])
        XCTAssertEqual(rail.secondary.first?.title, TicketList.stopForcingTitle)
    }

    func testEveryMoveAllowed_AnswerFirst_EachMoveOnce() {
        let rail = TicketActionRail(identifier: "TP-1", moves: Self.everyMoveAllowed)
        XCTAssertEqual(rail.primary?.move, .answer)
        XCTAssertEqual(moves(rail.secondary), [.start, .unforce])
        XCTAssertEqual(moves(rail.more), [.unblock, .moveTo, .restart, .cancel, .note, .stop])
        XCTAssertEqual(Set(moves(rail.items)).count, rail.items.count)
    }

    // MARK: - Pressing a move

    func testEachAllowedMoveAsksForItsCallOrItsSheet() {
        let rail = TicketActionRail(identifier: "TP-1", moves: Self.everyMoveAllowed)
        XCTAssertEqual(rail.request(.answer), .sheet(.answer))
        XCTAssertEqual(rail.request(.start), .send(.start("TP-1", note: nil)))
        XCTAssertEqual(rail.request(.stop), .sheet(.stopRun))
        XCTAssertEqual(rail.request(.moveTo, state: "Done"), .sheet(.moveTo("Done")))
        XCTAssertNil(rail.request(.moveTo))
        XCTAssertEqual(rail.request(.unforce), .send(.stopForcing("TP-1")))
        XCTAssertEqual(rail.request(.restart), .sheet(.restart))
        XCTAssertEqual(rail.request(.unblock), .send(.unblock("TP-1")))
        XCTAssertEqual(rail.request(.note), .sheet(.note))
        guard case let .confirm(confirmation)? = rail.request(.cancel) else { return XCTFail("Cancel asks first") }
        XCTAssertEqual(confirmation.action, .cancel("TP-1", note: nil))
        XCTAssertEqual(confirmation.title, "Cancel TP-1?")
        // Force is not on a rail that offers Stop Forcing.
        XCTAssertNil(rail.request(.force))
    }

    func testForceOpensItsSheet_AndARefusedMoveAsksForNothing() throws {
        let rail = try rail("working")
        XCTAssertEqual(rail.request(.force), .sheet(.force))
        XCTAssertNil(rail.request(.start))
        XCTAssertNil(rail.request(.answer))
    }

    func testVoiceOverSaysWhyAMoveCantAct() throws {
        let rail = try rail("working")
        XCTAssertEqual(TicketActionRail.accessibilityLabel(rail.secondary[0]), "Start Now, unavailable: A run is already working on it.")
        XCTAssertEqual(TicketActionRail.accessibilityLabel(rail.secondary[1]), "Force…")
    }

    func testTheCancelCallGoesToItsEndpointWithTheNote() {
        XCTAssertEqual(ControlAction.cancel("TP-1", note: nil).path, "api/v1/control/cancel")
        XCTAssertEqual(ControlAction.cancel("TP-1", note: "dup").body as? [String: String], ["issue_identifier": "TP-1", "note": "dup"])
        XCTAssertEqual(ControlAction.cancel("TP-1", note: nil).moveIdentifier, "TP-1")
        XCTAssertEqual(ControlAction.cancel("TP-1", note: nil).failurePrefix, "Couldn't cancel TP-1")
    }

    func testTheTicketPageCarriesTheReadsMoves() {
        let issue = Data(#"{"identifier": "TP-1", "moves": {"stop": {"allowed": true, "reason": null}}}"#.utf8)
        let page = TicketPage(identifier: "TP-1", sources: TicketPage.Sources(issue: issue))
        XCTAssertEqual(page.moves, TicketMoves(["stop": TicketMoveRead(allowed: true)]))
    }
}
