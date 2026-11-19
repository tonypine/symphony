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
        XCTAssertEqual(story.rows.prefix(6).map(\.mark), [.done, .done, .done, .current, .next, .open])
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
        XCTAssertTrue(current.accessibilityLabel.hasPrefix("4 of 26, TP-1441, The Situation line everywhere, current, Working"))
        XCTAssertEqual(story.rows[0].accessibilityLabel, "1 of 26, TP-1438, The shared styles, Done Tue 10 Nov")
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

    func testACanceledSubTicketIsStruckAtTheEndAndTheTicketInReviewIsCurrent() throws {
        let story = try story("BIL-300")
        XCTAssertEqual(story.rows.map(\.identifier), ["BIL-301", "BIL-304", "BIL-302", "BIL-305", "BIL-303"])
        XCTAssertEqual(story.rows.map(\.number), [1, 2, 3, 4, nil])
        XCTAssertEqual(story.rows.map(\.mark), [.done, .open, .current, .next, .canceled])
        XCTAssertEqual(story.rows.last?.line.kind, .cancelled)
        XCTAssertNil(story.rows.last?.ticket)
        XCTAssertEqual(story.rows.last?.accessibilityLabel, "BIL-303, Annual plans for the free tier, canceled")
        XCTAssertEqual(story.rows[2].blockers.map(\.detail), ["Resolved Mon 9 Nov"])
        XCTAssertEqual(story.rows[3].blockers.map(\.detail), ["Waiting for CI · Code Review"])
        XCTAssertEqual(story.progress, "1 of 4 done")
        XCTAssertFalse(story.rows.contains { $0.identifier == "BIL-300" }, "the epic's own record is not a row")
    }

    func testEveryTicketBeingWorkedOnIsCurrentAndTheOneAfterTheLastIsNext() {
        let initiative = Initiative(
            issueID: "p", identifier: "TP-1", title: nil, repoKey: nil, group: .active,
            subTickets: [
                Initiative.SubTicket(identifier: "TP-2", waits: .slot),
                Initiative.SubTicket(identifier: "TP-3", blockedBy: ["TP-2"], waits: .blocker(["TP-2"])),
                Initiative.SubTicket(identifier: "TP-4", blockedBy: ["TP-3"], waits: .blocker(["TP-3"])),
                Initiative.SubTicket(identifier: "TP-5", blockedBy: ["TP-4"], waits: .blocker(["TP-4"])),
            ]
        )
        let order = DispatchOrder(groups: [
            DispatchOrder.Group(kind: .working, tickets: [
                DispatchOrder.Ticket(identifier: "TP-2", outcome: .running), DispatchOrder.Ticket(identifier: "TP-3", outcome: .running),
            ]),
        ])
        let story = InitiativeStory(initiative: initiative, order: order)
        XCTAssertEqual(story.rows.map(\.mark), [.current, .current, .next, .open])
        XCTAssertEqual(story.currents.map(\.identifier), ["TP-2", "TP-3"])
        XCTAssertEqual(story.sentence.rest, "TP-2 and TP-3 are being worked on; 2 wait behind them, in order.")
        XCTAssertEqual(story.rows.map(\.trail), [nil, nil, "Next: starts when TP-3 lands", "Waits for TP-4"])

        // Nothing runs: the first in the dispatch order is next, else the first open one.
        let inLine = DispatchOrder(groups: [DispatchOrder.Group(kind: .slot, tickets: [DispatchOrder.Ticket(identifier: "TP-3", position: 1)])])
        XCTAssertEqual(InitiativeStory(initiative: initiative, order: inLine).rows.map(\.mark), [.open, .next, .open, .open])
        let idle = InitiativeStory(initiative: initiative)
        XCTAssertEqual(idle.rows.map(\.mark), [.next, .open, .open, .open])
        XCTAssertNil(idle.current)
        XCTAssertEqual(idle.sentence, InitiativeStory.Sentence(lead: "0 of 4 done.", rest: "TP-2 is next; 3 wait behind it, in order."))
        XCTAssertEqual(idle.rows.first?.trail, "Next in line")
        XCTAssertTrue(idle.rows.first?.accessibilityLabel.contains("next") == true)
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

    // MARK: - The page as designed (TP-1500)

    func testTheCardsAreTheCatalogsEpicsEachWithWhatIsNotDone() throws {
        let list = InitiativesList(initiatives: try payload().initiatives, state: try state().snapshot)
        XCTAssertEqual(list.sections.map(\.title), ["Active", "Done recently"])
        XCTAssertEqual(list.sections.map { $0.initiatives.map(\.identifier) }, [["TP-1381", "SHOP-280", "BIL-300"], ["SHOP-500"]])
        let legends = Dictionary(uniqueKeysWithValues: list.ordered.map { ($0.identifier, $0.cardLegend.map(\.text)) })
        XCTAssertEqual(legends["TP-1381"], ["1 working", "22 waiting"])
        XCTAssertEqual(legends["SHOP-280"], ["1 needs a fix", "1 working", "3 waiting"])
        XCTAssertEqual(legends["BIL-300"], ["1 working", "2 waiting"])
        XCTAssertEqual(legends["SHOP-500"], [])

        let phase3b = try fixtureInitiative("TP-1381")
        XCTAssertEqual(phase3b.cardStripItems.count, 26)
        XCTAssertEqual(phase3b.cardStripItems.prefix(5), [.init(.done), .init(.done), .init(.done), .init(.working, live: true), .init(nil)])
        XCTAssertNil(phase3b.landedLine(calendar: utc))
        XCTAssertEqual(
            phase3b.cardAccessibilityLabel(calendar: utc),
            "TP-1381, Phase 3b: the Director redesigned around a ticket’s situation, 3 of 26 done, 1 working, 22 waiting"
        )
        XCTAssertEqual(phase3b.tokens, 14_600_000)
        XCTAssertEqual(phase3b.subTickets.prefix(4).map(\.pullRequest), [859, 860, 861, nil])

        let giftCards = try fixtureInitiative("SHOP-500")
        XCTAssertEqual(giftCards.landedLine(calendar: utc), "Landed Mon 9 Nov")
        XCTAssertEqual(giftCards.cardAccessibilityLabel(calendar: utc), "SHOP-500, Gift cards, 3 of 3 done, Landed Mon 9 Nov")
        var undated = giftCards
        undated.completedAt = nil
        XCTAssertEqual(undated.landedLine(calendar: utc), "Landed")
        XCTAssertEqual(Initiative.legendWord(.problem, count: 2), "need a fix")
        XCTAssertEqual(Initiative.legendWord(.you, count: 1), "waits on you")
        XCTAssertEqual(Initiative.legendWord(.you, count: 2), "wait on you")
        XCTAssertEqual(Initiative.stripItem(Initiative.SubTicket(identifier: "T-1", waits: .you)), .init(.you))
    }

    func testTheStoryHeadSaysWhereTheChainStandsAndWhenItStarted() throws {
        let story = try story("TP-1381")
        XCTAssertEqual(story.sentence.lead, "3 of 26 done.")
        XCTAssertEqual(story.sentence.rest, "TP-1441 is being worked on; 22 wait behind it, in order.")
        XCTAssertEqual(story.sentence.text, "3 of 26 done. TP-1441 is being worked on; 22 wait behind it, in order.")
        XCTAssertEqual(story.stripItems.count, 26)
        XCTAssertEqual(story.stripItems.prefix(5), [.init(.done), .init(.done), .init(.done), .init(.working, live: true), .init(nil)])
        XCTAssertEqual(
            InitiativeStory.note(try fixtureInitiative("TP-1381"), reference: try reference(), calendar: utc),
            "Started Tue 10 Nov · 2 days so far · 14.6M tokens"
        )
        XCTAssertEqual(
            InitiativeStory.note(try fixtureInitiative("SHOP-500"), reference: try reference(), calendar: utc),
            "Started Fri 30 Oct · ran 10 days · 3.1M tokens"
        )
        let bare = Initiative(issueID: "p", identifier: "TP-1", title: nil, repoKey: nil, group: .active, subTickets: [])
        XCTAssertNil(InitiativeStory.note(bare, reference: try reference(), calendar: utc))

        let done = try self.story("SHOP-500")
        XCTAssertEqual(done.sentence, InitiativeStory.Sentence(lead: "3 of 3 done.", rest: "Every sub-ticket landed."))
        let empty = InitiativeStory(initiative: bare)
        XCTAssertEqual(empty.sentence, InitiativeStory.Sentence(lead: "No sub-tickets yet.", rest: nil))
        XCTAssertEqual(empty.sentence.text, "No sub-tickets yet.")
        XCTAssertTrue(empty.stripItems.isEmpty)
        XCTAssertNil(empty.foldIndex)
        XCTAssertEqual(InitiativeStory.behind(0, "it"), "nothing waits behind it.")
        XCTAssertEqual(InitiativeStory.behind(1, "them"), "1 waits behind them.")
    }

    func testEachRowSaysWhatMattersForItsState() throws {
        let story = try story("TP-1381")
        XCTAssertEqual(story.rows.prefix(6).map(\.trail), [
            "Landed Tue 10 Nov · PR #859", "Landed Wed 11 Nov · PR #860", "Landed Wed 11 Nov · PR #861", nil,
            "Next: starts when TP-1441 lands", "Waits for TP-1442",
        ])
        let annual = try self.story("BIL-300")
        XCTAssertEqual(annual.rows.map(\.trail), ["Landed Mon 9 Nov · PR #790", "Waiting for a slot", nil, "Next: starts when BIL-302 lands", "Canceled"])
        XCTAssertEqual(
            InitiativeStory.trail(.done, landed: nil, pullRequest: nil, waitsFor: nil, line: Situation(kind: .done, cause: ""), calendar: utc),
            "Landed"
        )
    }

    func testARowThatNeedsAFixOrWaitsOnYouSaysSoAsItsStripSegmentDoes() throws {
        let story = try story("SHOP-280")
        let fix = try XCTUnwrap(story.rows.first { $0.identifier == "SHOP-305" })
        XCTAssertEqual(fix.attention, .problem)
        XCTAssertEqual(fix.trail, "Retrying")
        let index = try XCTUnwrap(story.chained.firstIndex { $0.identifier == "SHOP-305" })
        XCTAssertEqual(story.stripItems[index].status, .problem, "the row agrees with its segment")
        XCTAssertEqual(story.rows.filter { $0.attention != nil }.map(\.identifier), ["SHOP-305"])

        let initiative = Initiative(
            issueID: "p", identifier: "TP-1", title: nil, repoKey: nil, group: .active,
            subTickets: [
                Initiative.SubTicket(identifier: "TP-2", waits: .working),
                Initiative.SubTicket(identifier: "TP-3", waits: .you),
                Initiative.SubTicket(identifier: "TP-4", waits: .you),
            ]
        )
        let asked = InitiativeStory(initiative: initiative)
        XCTAssertEqual(asked.rows.map(\.mark), [.current, .next, .open])
        XCTAssertEqual(asked.rows.map(\.attention), [nil, .you, .you])
        XCTAssertEqual(asked.rows.map(\.trail), [nil, "Waiting on you", "Waiting on you"])
        XCTAssertNil(InitiativeStory.attention(.done, line: Situation(kind: .you, cause: "")))
        XCTAssertNil(InitiativeStory.attention(.open, line: Situation(kind: .slot, cause: "")))
    }

    func testPastTheTwoAfterTheLastOneBeingWorkedOnTheRestFold() throws {
        let story = try story("TP-1381")
        XCTAssertEqual(story.foldIndex, 6)
        XCTAssertEqual(story.folded?.map(\.identifier), (1444...1463).map { "TP-\($0)" })
        XCTAssertEqual(story.foldLine, "20 more wait in line, in this order")
        XCTAssertNil(try self.story("BIL-300").foldIndex, "nothing past the two after the current one")
        XCTAssertNil(try self.story("SHOP-500").foldLine, "nothing is worked on or next")

        // Nothing worked on: the fold comes after the next one and the one after it.
        var idle = story
        idle.rows = idle.rows.map { row in
            var row = row
            if row.mark == .current { row.mark = .open }
            return row
        }
        XCTAssertEqual(idle.foldIndex, 6)

        // The canceled rows the fold hides are named too.
        var canceled = story
        canceled.rows = Array(story.rows.prefix(7)) + story.rows.prefix(2).map { row in
            var row = row
            row.mark = .canceled
            return row
        }
        XCTAssertEqual(canceled.foldLine, "1 more waits in line, and 2 canceled")
        canceled.rows = Array(story.rows.prefix(6)) + canceled.rows.suffix(2)
        XCTAssertEqual(canceled.foldLine, "2 canceled")
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
