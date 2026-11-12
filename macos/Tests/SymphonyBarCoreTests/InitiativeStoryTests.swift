import Foundation
import XCTest
@testable import SymphonyBarCore

/// Work › Initiatives as the epic's story (TP-1458), on the `initiative-story` fixture the snapshots and QA read too:
/// TP-1381 with its fourth sub-ticket running, SHOP-500 done, BIL-300 with a canceled sub-ticket.
final class InitiativeStoryTests: XCTestCase {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    // MARK: - The chain order

    func testTheChainOrderIsTopologicalWithItsBranchesTiedByPriorityThenAge() {
        // A → (B, C) → D, E after C; B is urgent, so it goes before C although C is older.
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [
            InitiativeStory.ChainItem(identifier: "TP-5", blockedBy: ["TP-3", "TP-4"], priority: 1, createdAt: day),
            InitiativeStory.ChainItem(identifier: "TP-4", blockedBy: ["TP-1"], priority: 3, createdAt: day.addingTimeInterval(10)),
            InitiativeStory.ChainItem(identifier: "TP-3", blockedBy: ["TP-1"], priority: 3, createdAt: day.addingTimeInterval(20)),
            InitiativeStory.ChainItem(identifier: "TP-2", blockedBy: ["TP-1"], priority: 1, createdAt: day.addingTimeInterval(30)),
            InitiativeStory.ChainItem(identifier: "TP-1", priority: 2, createdAt: day.addingTimeInterval(40)),
            InitiativeStory.ChainItem(identifier: "TP-6", blockedBy: ["TP-3"], priority: 2, createdAt: day.addingTimeInterval(50)),
        ]
        XCTAssertEqual(InitiativeStory.chainOrder(items), ["TP-1", "TP-2", "TP-4", "TP-3", "TP-5", "TP-6"])
    }

    func testANoPriorityTicketGoesAfterThePrioritisedOnesAndTheIdentifierBreaksTheLastTie() {
        let items = [
            InitiativeStory.ChainItem(identifier: "TP-10"),
            InitiativeStory.ChainItem(identifier: "TP-9"),
            InitiativeStory.ChainItem(identifier: "TP-11", priority: 0),
            InitiativeStory.ChainItem(identifier: "TP-12", priority: 4),
        ]
        XCTAssertEqual(InitiativeStory.chainOrder(items), ["TP-12", "TP-9", "TP-10", "TP-11"])
    }

    func testATicketWithNoBlockerRelationSortsByItsDispatchPosition() {
        let items = [
            InitiativeStory.ChainItem(identifier: "TP-1", priority: 1),
            InitiativeStory.ChainItem(identifier: "TP-2", blockedBy: ["TP-1"], priority: 1),
            InitiativeStory.ChainItem(identifier: "TP-7", priority: 4, position: 2),
            InitiativeStory.ChainItem(identifier: "TP-8", priority: 4, position: 1),
            // A position does not move a ticket in the chain ahead of its place.
            InitiativeStory.ChainItem(identifier: "TP-3", blockedBy: ["TP-2"], priority: 1, position: 3),
        ]
        XCTAssertEqual(InitiativeStory.chainOrder(items), ["TP-8", "TP-7", "TP-1", "TP-2", "TP-3"])
    }

    func testACycleIsBrokenOnTheSameKeyAndOutsideLinksAreIgnored() {
        let items = [
            InitiativeStory.ChainItem(identifier: "TP-2", blockedBy: ["TP-1", "OTHER-9"], priority: 2),
            InitiativeStory.ChainItem(identifier: "TP-1", blockedBy: ["TP-2", "TP-1"], priority: 1),
            InitiativeStory.ChainItem(identifier: "TP-1", priority: 1),
        ]
        XCTAssertEqual(InitiativeStory.chainOrder(items), ["TP-1", "TP-2"])
    }

    // MARK: - The fixture's epics

    func testAnEpicMidChainReadsOneToTwentySixWithTheFourthCurrentAndTheFirstThreeDone() throws {
        let story = try story("TP-1381")
        XCTAssertEqual(story.rows.map(\.identifier), (1438...1463).map { "TP-\($0)" })
        XCTAssertEqual(story.rows.map(\.number), (1...26).map(Optional.some))
        XCTAssertEqual(story.rows.prefix(5).map(\.mark), [.done, .done, .done, .current, .open])
        XCTAssertEqual(story.current?.identifier, "TP-1441")
        XCTAssertEqual(story.current?.line.kind, .working)
        XCTAssertEqual(story.rows.prefix(3).map(\.doneLine), ["Done Tue 10 Nov", "Done yesterday, Wed 11 Nov", "Done yesterday, Wed 11 Nov"])
        XCTAssertEqual(story.progress, "3 of 26 done")
        XCTAssertEqual(story.strip?.segments.count, 26)
        XCTAssertEqual(story.strip?.segments.prefix(4), [.done, .done, .done, .working])
        XCTAssertEqual(story.progressAccessibilityLabel, "3 of 26 sub-tickets done")
    }

    func testEachOpenSubTicketsBlockersComeFromItsTicketRead() throws {
        let story = try story("TP-1381")
        let current = try XCTUnwrap(story.current)
        XCTAssertEqual(current.blockers.map(\.identifier), ["TP-1440"])
        XCTAssertEqual(current.blockers.first?.struck, true)
        XCTAssertEqual(current.blockers.first?.detail, "Resolved yesterday, Wed 11 Nov")
        let next = story.rows[4]
        XCTAssertEqual(next.blockers.map(\.identifier), ["TP-1441"])
        XCTAssertEqual(next.blockers.first?.struck, false)
        XCTAssertEqual(next.blockers.first?.detail, "Working · In Progress")
        XCTAssertEqual(story.rows[0].blockers, [], "a done sub-ticket shows no blockers")
        XCTAssertTrue(current.accessibilityLabel.hasPrefix("4 of 26, TP-1441, 3b (4/26): The Situation line everywhere, current, Working"))
        XCTAssertEqual(story.rows[0].accessibilityLabel, "1 of 26, TP-1438, 3b (1/26): The shared styles, Done Tue 10 Nov")
    }

    func testWithoutTheReadsTheBlockersStayEmptyAndTheProgressIsTheInitiatives() throws {
        let initiative = try fixtureInitiative("TP-1381")
        let story = InitiativeStory(initiative: initiative, reference: try reference(), calendar: utc)
        XCTAssertEqual(story.rows.map(\.identifier), (1438...1463).map { "TP-\($0)" })
        XCTAssertTrue(story.rows.allSatisfy(\.blockers.isEmpty))
        XCTAssertNil(story.strip)
        XCTAssertEqual(story.progress, "3 of 26 done")
        XCTAssertEqual(story.current?.identifier, "TP-1441", "a sub-ticket that waits on its run is current without the order")
        // The Initiatives' link gives the date when the record does not.
        XCTAssertEqual(story.rows.prefix(3).map(\.doneLine), ["Done Tue 10 Nov", "Done yesterday, Wed 11 Nov", "Done yesterday, Wed 11 Nov"])
    }

    func testADoneSubTicketNoFactDatesReadsDone() {
        let initiative = Initiative(
            issueID: "p", identifier: "TP-1", title: nil, repoKey: nil, group: .done,
            subTickets: [Initiative.SubTicket(identifier: "TP-2", waits: .done)]
        )
        XCTAssertEqual(InitiativeStory(initiative: initiative).rows.map(\.doneLine), ["Done"])
    }

    func testAResolvedBlockerOnASiblingsReadDatesADoneSubTicket() {
        let initiative = Initiative(
            issueID: "p", identifier: "TP-1", title: nil, repoKey: nil, group: .active,
            subTickets: [Initiative.SubTicket(identifier: "TP-2", waits: .done), Initiative.SubTicket(identifier: "TP-3", waits: .slot)]
        )
        let resolved = ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z")!
        let connected = ["TP-3": TicketConnected(blockedBy: [TicketConnected.Blocker(identifier: "TP-2", resolved: true, resolvedAt: resolved)])]
        let story = InitiativeStory(initiative: initiative, connected: connected, reference: resolved.addingTimeInterval(86_400 * 3), calendar: utc)
        XCTAssertEqual(story.rows.map(\.doneLine), ["Done Fri 6 Nov", nil])
        XCTAssertEqual(story.rows.map(\.identifier), ["TP-2", "TP-3"])
    }

    func testALandedTicketGoesBeforeOneStillToLand() {
        let items = [
            InitiativeStory.ChainItem(identifier: "TP-1", priority: 1, position: 1),
            InitiativeStory.ChainItem(identifier: "TP-2", priority: 4, done: true),
        ]
        XCTAssertEqual(InitiativeStory.chainOrder(items), ["TP-2", "TP-1"])
    }

    func testADoneEpicReadsEveryRowQuietlyWithItsDate() throws {
        let story = try story("SHOP-500")
        XCTAssertEqual(story.rows.map(\.identifier), ["SHOP-501", "SHOP-502", "SHOP-503"])
        XCTAssertEqual(story.rows.map(\.mark), [.done, .done, .done])
        XCTAssertNil(story.current)
        XCTAssertEqual(story.rows.map(\.doneLine), ["Done Tue 3 Nov", "Done Thu 5 Nov", "Done Fri 6 Nov"])
        XCTAssertEqual(story.progress, "3 of 3 done")
    }

    func testACanceledSubTicketIsStruckAtTheEndAndTheNextInLineIsCurrent() throws {
        let story = try story("BIL-300")
        XCTAssertEqual(story.rows.map(\.identifier), ["BIL-301", "BIL-304", "BIL-302", "BIL-305", "BIL-303"])
        XCTAssertEqual(story.rows.map(\.number), [1, 2, 3, 4, nil])
        XCTAssertEqual(story.rows.map(\.mark), [.done, .current, .open, .open, .canceled])
        XCTAssertEqual(story.rows.last?.line.kind, .cancelled)
        XCTAssertNil(story.rows.last?.ticket)
        XCTAssertEqual(story.rows.last?.accessibilityLabel, "BIL-303, Annual plans for the free tier, canceled")
        XCTAssertEqual(story.rows[2].blockers.map(\.detail), ["Resolved Mon 9 Nov"])
        XCTAssertEqual(story.rows[3].blockers.map(\.detail), ["Waiting for CI · Code Review"])
        XCTAssertEqual(story.progress, "1 of 4 done")
        XCTAssertFalse(story.rows.contains { $0.identifier == "BIL-300" }, "the epic's own record is not a row")
    }

    func testARunningTicketInTheOrderIsCurrentBeforeTheNextInLine() throws {
        let initiative = try fixtureInitiative("BIL-300")
        let order = DispatchOrder(groups: [
            DispatchOrder.Group(kind: .working, tickets: [DispatchOrder.Ticket(identifier: "BIL-302", outcome: .running)]),
            DispatchOrder.Group(kind: .slot, tickets: [DispatchOrder.Ticket(identifier: "BIL-304", position: 1)]),
        ])
        XCTAssertEqual(InitiativeStory(initiative: initiative, order: order).current?.identifier, "BIL-302")
        XCTAssertNil(InitiativeStory(initiative: initiative).current, "nothing runs and nothing is in line")
    }

    // MARK: - Reads and counts

    func testTheRecordsPathAsksForTheEpicsColumns() {
        let path = InitiativeStory.recordsPath("TP-1381")
        XCTAssertTrue(path.hasPrefix("api/v1/tickets?epic=TP-1381&columns="), path)
        for column in ["priority", "created_at", "phase_at", "phase", "situation", "epic"] {
            XCTAssertTrue(path.contains(column), "\(column) is missing from \(path)")
        }
    }

    func testTheReadsNeededAreTheOpenSubTicketsOrTheFirstOfADoneEpic() throws {
        XCTAssertEqual(InitiativeStory.readsNeeded(try fixtureInitiative("TP-1381")), (1441...1463).map { "TP-\($0)" })
        XCTAssertEqual(InitiativeStory.readsNeeded(try fixtureInitiative("SHOP-500")), ["SHOP-501"])
        let empty = Initiative(issueID: "p", identifier: "TP-1", title: nil, repoKey: nil, group: .active, subTickets: [])
        XCTAssertEqual(InitiativeStory.readsNeeded(empty), [])
    }

    func testWorksCountIsTheEpicsWithASubTicketWaitingOnAPerson() throws {
        let initiatives = try payload().initiatives
        XCTAssertEqual(InitiativesList.waitingOnPerson(initiatives), 0)
        var waiting = try fixtureInitiative("BIL-300")
        waiting.subTickets[2].waits = .you
        XCTAssertEqual(InitiativesList.waitingOnPerson(initiatives + [waiting, waiting]), 2)
    }

    // MARK: - The fixture

    private var api: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/director-app/initiative-story/api/v1").standardizedFileURL
    }

    private func payload() throws -> InitiativesPayload {
        try XCTUnwrap(InitiativesPayload.decode(try Data(contentsOf: api.appendingPathComponent("initiatives.json"))))
    }

    private func state() throws -> OverviewState {
        try XCTUnwrap(OverviewState.decode(try Data(contentsOf: api.appendingPathComponent("state.json"))))
    }

    private func reference() throws -> Date {
        try XCTUnwrap(try state().generatedAt)
    }

    private func fixtureInitiative(_ identifier: String) throws -> Initiative {
        let list = InitiativesList(initiatives: try payload().initiatives, state: try state().snapshot)
        return try XCTUnwrap(list.ordered.first { $0.identifier == identifier })
    }

    private func story(_ identifier: String) throws -> InitiativeStory {
        let initiative = try fixtureInitiative(identifier)
        let records = try XCTUnwrap(TicketsPayload.decode(try Data(contentsOf: api.appendingPathComponent("tickets.json")))).rows
        var connected: [String: TicketConnected] = [:]
        for ticket in initiative.subTickets {
            guard let data = try? Data(contentsOf: api.appendingPathComponent("\(ticket.identifier).json")) else { continue }
            connected[ticket.identifier] = TicketFactsRead.decode(data)?.connected
        }
        return InitiativeStory(
            initiative: initiative, records: records, connected: connected, order: try state().order, reference: try reference(), calendar: utc
        )
    }
}
