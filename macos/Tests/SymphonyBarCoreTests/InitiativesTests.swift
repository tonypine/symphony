import Foundation
import XCTest
@testable import SymphonyBarCore

final class InitiativesTests: XCTestCase {
    // MARK: - The shipped fixture

    func testTheFixtureHasTwoActiveInitiativesOneInReviewAndOneDone() throws {
        let list = InitiativesList(initiatives: try payload().initiatives)
        XCTAssertEqual(list.sections.map(\.title), ["Active", "In review", "Done recently"])
        XCTAssertEqual(list.sections.map { $0.initiatives.map(\.identifier) }, [["BIL-200", "DOCS-20"], ["SHOP-330"], ["SHOP-300"]])
        XCTAssertEqual(list.active.map(\.identifier), ["BIL-200", "DOCS-20"])
        XCTAssertEqual(list.selection(nil)?.identifier, "BIL-200")
        XCTAssertEqual(list.selection("p-20")?.identifier, "DOCS-20")
        XCTAssertEqual(list.selection("gone")?.identifier, "BIL-200")
    }

    func testTheFirstActiveInitiativesDetailMatchesTheFixture() throws {
        let initiative = try XCTUnwrap(try payload().initiatives.first)
        XCTAssertEqual(initiative.sentence, "4 of 8 done. BIL-206 waits on you, and 2 tickets wait on it.")
        XCTAssertEqual(initiative.subTickets.map(\.identifier), (201...208).map { "BIL-\($0)" })
        XCTAssertEqual(initiative.subTickets.map(\.waits.line), [
            "Done", "Done", "Done", "Done", "Working", "Waits on you", "Waits on BIL-206", "Waits on BIL-206",
        ])
        XCTAssertEqual(initiative.subTickets[5].issueID, "i-206")
        XCTAssertEqual(initiative.subTickets[6].blockedBy, ["BIL-206"])
        XCTAssertEqual(initiative.slot?.line, "Holds a lane, running BIL-205")
        XCTAssertEqual(initiative.legend.map(\.stage), [.done, .working, .you, .blocked])
        XCTAssertEqual(initiative.legend.map(\.count), [4, 1, 1, 2])
        XCTAssertEqual(initiative.barAccessibilityLabel, "4 of 8 done: 4 done, 1 working, 1 waiting on you, 2 blocked")
        XCTAssertEqual(
            initiative.subTickets[6].accessibilityLabel,
            "BIL-207, Credit notes for downgrades, waits on BIL-206, blocked by BIL-206"
        )
        XCTAssertEqual(Initiative.SubTicket.spoken("Waits on 3 tickets"), "waits on 3 tickets")
        XCTAssertEqual(Initiative.SubTicket.spoken(""), "")
    }

    func testTheReviewedSubTicketIsAnInboxItem() throws {
        let initiative = try XCTUnwrap(try payload().initiatives.first)
        let inbox = try XCTUnwrap(InboxPayload.decode(try Data(contentsOf: fixture().appendingPathComponent("inbox.json"))))
        let waiting = try XCTUnwrap(initiative.subTickets.first { $0.waits == .you })
        XCTAssertTrue(inbox.items.contains { $0.id == waiting.issueID })
    }

    func testTheOtherInitiativesReadAsTheyShould() throws {
        let initiatives = try payload().initiatives
        XCTAssertEqual(initiatives[1].sentence, "2 of 5 done.")
        XCTAssertEqual(initiatives[1].slot?.line, "Queued for a lane, 1st")
        XCTAssertEqual(initiatives[1].subTickets[2].waits.line, "Waits on CI")
        XCTAssertEqual(initiatives[1].subTickets[3].waits.line, "Waits on a slot")
        XCTAssertEqual(initiatives[2].sentence, "0 of 3 done. SHOP-331 waits on you, and 1 ticket waits on it. 2 more wait on you.")
        XCTAssertEqual(initiatives[3].sentence, "3 of 3 done. Every sub-ticket is done.")
        XCTAssertNil(initiatives[2].slot)
    }

    func testTheScopeKeepsOneReposInitiatives() throws {
        let list = InitiativesList(initiatives: try payload().initiatives, scope: .repo("web-shop"))
        XCTAssertEqual(list.ordered.map(\.identifier), ["SHOP-330", "SHOP-300"])
        XCTAssertTrue(list.active.isEmpty)
        XCTAssertTrue(InitiativesList(initiatives: [], scope: .all).isEmpty)
    }

    // MARK: - Lines and sentences

    func testSentences() {
        func initiative(_ waits: [InitiativeWait], blockedBy: [[String]] = []) -> Initiative {
            let tickets = waits.enumerated().map { index, wait in
                Initiative.SubTicket(identifier: "T-\(index)", blockedBy: index < blockedBy.count ? blockedBy[index] : [], waits: wait)
            }
            return Initiative(issueID: "p", identifier: "P-1", title: nil, repoKey: nil, group: .active, subTickets: tickets)
        }
        XCTAssertEqual(initiative([]).sentence, "No sub-tickets yet.")
        XCTAssertEqual(initiative([.you, .slot]).sentence, "0 of 2 done. T-0 waits on you.")
        XCTAssertEqual(initiative([.you, .you, .you]).sentence, "0 of 3 done. T-0 waits on you. 2 more wait on you.")
        XCTAssertEqual(initiative([.you, .you]).sentence, "0 of 2 done. T-0 waits on you. 1 more waits on you.")
        XCTAssertEqual(initiative([.you, .done], blockedBy: [[], ["T-0"]]).sentence, "1 of 2 done. T-0 waits on you.")
        XCTAssertEqual(initiative([]).barAccessibilityLabel, "0 of 0 done")
    }

    func testWaitLinesAndStages() {
        XCTAssertEqual(InitiativeWait.blocker([]).line, "Waits on a blocker")
        XCTAssertEqual(InitiativeWait.blocker(["A-1", "A-2"]).line, "Waits on A-1 and A-2")
        XCTAssertEqual(InitiativeWait("nonsense", waitingFor: []), .slot)
        XCTAssertEqual(InitiativeWait("ci", waitingFor: []).stage, .working)
        XCTAssertEqual(InitiativeStage.allCases.map(\.word), ["Done", "Working", "Waiting on you", "Queued", "Blocked"])
        XCTAssertEqual(InitiativeStage.allCases.map(\.status), [.done, .working, .you, .idle, .idle])
        XCTAssertEqual(InitiativeStage.allCases.map(\.symbol).count, Set(InitiativeStage.allCases.map(\.symbol)).count)
        XCTAssertEqual(InitiativeStage.allCases.filter(\.isLight), [.blocked])
    }

    func testSlotLines() {
        XCTAssertEqual(Initiative.Slot(status: "running").line, "Holds a lane")
        XCTAssertEqual(Initiative.Slot(status: "waiting", identifier: "A-2").line, "Holds a lane for A-2")
        XCTAssertEqual(Initiative.Slot(status: "waiting").line, "Holds a lane")
        XCTAssertEqual(Initiative.Slot(status: "yielded", reason: "every part waits on you").line, "Gave up its lane: every part waits on you")
        XCTAssertEqual(Initiative.Slot(status: "yielded").line, "Gave up its lane")
        XCTAssertEqual(Initiative.Slot(status: "queued").line, "Queued for a lane")
        XCTAssertEqual(Initiative.Slot(status: "other").line, "other")
    }

    // MARK: - Decoding

    func testAnErrorOrABrokenPayloadIsNoList() {
        XCTAssertNil(InitiativesPayload.decode(Data(#"{"error":{"code":"snapshot_timeout"}}"#.utf8)))
        XCTAssertNil(InitiativesPayload.decode(Data("nope".utf8)))
        XCTAssertNil(InitiativesPayload.decode(Data("{}".utf8)))
        let partial = #"""
        {"initiatives":[{"issue_id":"p","identifier":"P-1","group":"active",
          "sub_tickets":[{"identifier":"T-1"},{"title":"no identifier"}],
          "slot":{"identifier":"X"}},
          {"identifier":"no id"},{"issue_id":"q","identifier":"Q-1","group":"later"}]}
        """#
        let payload = InitiativesPayload.decode(Data(partial.utf8))
        XCTAssertEqual(payload?.initiatives.count, 1)
        XCTAssertEqual(payload?.initiatives.first?.subTickets.map(\.waits), [.slot])
        XCTAssertNil(payload?.initiatives.first?.slot)
    }

    private func payload() throws -> InitiativesPayload {
        try XCTUnwrap(InitiativesPayload.decode(try Data(contentsOf: fixture().appendingPathComponent("initiatives.json"))))
    }

    private func fixture() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/inbox/api/v1", isDirectory: true)
    }
}
