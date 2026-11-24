import Foundation
import XCTest
@testable import SymphonyBarCore

/// The epic slot card's read and moves (TP-1646), on the `home-queue-epic-slot` fixture as the fixtures serve it to QA:
/// slot 1 is held by the epic TP-1597 (7 of its 16 sub-tickets done, TP-1619 in work, eight to come: TP-1623, then
/// TP-1624 waiting on TP-1623, TP-1607, TP-1609, TP-1610 and TP-1620 each waiting on the one before, then TP-1625 and
/// TP-1626); slot 2 holds TP-1594 on its own. Every move goes through `ControlAPI` to the fixtures, which change the
/// epic's open sub-tickets and refuse a move or a Start as the engine does.
@MainActor
final class HomeEpicSlotTests: XCTestCase {
    private var log: URL!
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("home-queue-epic-slot-\(UUID().uuidString)", isDirectory: true)
        log = root.appendingPathComponent(APIFixtures.requestLogFileName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/home-queue-epic-slot", isDirectory: true)
    }

    private var fixtures: APIFixtures { APIFixtures(directory: directory, requestLog: log) }

    /// The moves sent, and the epic's list to come at the moment each was sent.
    private final class Calls {
        var moves: [ControlAction] = []
        var upcomingWhenSent: [[String]] = []
        weak var model: HomeQueueModel?
    }

    private func makeModel(_ calls: Calls = Calls()) -> HomeQueueModel {
        let fixtures = self.fixtures
        let root = self.root!
        let model = HomeQueueModel(
            fetch: { path, _ in
                let (data, response) = fixtures.answer(URLRequest(url: LiveAPIClient.url(path, base: APIFixtures.baseURL)!))
                return .changed(EndpointResult(.answered(data, statusCode: response.statusCode)), etag: nil)
            },
            send: { action in
                calls.moves.append(action)
                calls.upcomingWhenSent.append(calls.model.map { Self.upcoming($0) } ?? [])
                return await ControlAPI.send(
                    action, stateRoot: root, fallback: APIFixtures.baseURL, token: APIFixtures.token, transport: fixtures.transport
                )
            }
        )
        calls.model = model
        return model
    }

    /// Slot 1's epic's sub-tickets to come, by identifier.
    private static func upcoming(_ model: HomeQueueModel) -> [String] {
        model.slots.first { $0.number == 1 }?.epic?.openSubTickets.map(\.identifier) ?? []
    }

    private static let open = ["TP-1623", "TP-1624", "TP-1607", "TP-1609", "TP-1610", "TP-1620", "TP-1625", "TP-1626"]
    private static let done = ["TP-1611", "TP-1612", "TP-1608", "TP-1615", "TP-1616", "TP-1606", "TP-1622"]

    // MARK: - c1: the read gives a slot's epic whole

    func testASlotHeldByAnEpicReadsTheEpicItsCountsAndItsTwoLists() async throws {
        let model = makeModel()
        await model.refresh()
        let slot = try XCTUnwrap(model.cards.first)
        let epic = try XCTUnwrap(slot.epic)
        XCTAssertEqual(epic.identifier, "TP-1597")
        XCTAssertEqual(epic.issueID, "issue-tp-1597")
        XCTAssertEqual(epic.title, "A real queue: a slot belongs to one ticket until it is done, and Home is the window to the queue")
        XCTAssertEqual(epic.repoKey, "symphony")
        XCTAssertEqual(epic.since, SymphonyState.parseDate("2026-10-04T14:00:00Z"))
        XCTAssertEqual([epic.done, epic.total], [7, 16])
        XCTAssertEqual(slot.ticket?.identifier, "TP-1619", "the card inside is the sub-ticket in work")
        XCTAssertEqual(epic.doneSubTickets.map(\.identifier), Self.done, "done sub-tickets oldest first")
        XCTAssertEqual(epic.doneSubTickets.first?.pullRequestNumber, 1047)
        XCTAssertNotNil(epic.doneSubTickets.first?.doneAt)
        XCTAssertEqual(epic.openSubTickets.map(\.identifier), Self.open, "open ones in queue order")
        XCTAssertEqual(epic.openSubTickets[1].unmet.map(\.identifier), ["TP-1623"])
        XCTAssertEqual(epic.openSubTickets[1].parent, "TP-1597")
        XCTAssertNil(model.cards[1].epic, "a ticket on its own has no epic")
    }

    func testAnEpicThatDoesNotReadLeavesTheCardWithoutIt() throws {
        let json = #"""
        {"slots": {"total": 3, "entries": [
          {"slot": 1, "since": "2026-10-07T13:15:00Z", "epic": {"identifier": "TP-9", "open_sub_tickets": "no", "done_sub_tickets": 4},
           "ticket": {"identifier": "TP-10"}},
          {"slot": 2, "epic": "not an epic", "ticket": {"identifier": "TP-11"}},
          {"slot": 3, "epic": {"title": "names no ticket"}, "ticket": {"identifier": "TP-12"}}
        ]}, "queue": {"rows": []}}
        """#
        let read = try XCTUnwrap(HomeRead.decode(Data(json.utf8)))
        let epic = try XCTUnwrap(read.slots[0].epic)
        XCTAssertEqual(epic.identifier, "TP-9")
        XCTAssertEqual([epic.done, epic.total], [0, 0])
        XCTAssertEqual(epic.openSubTickets, [], "a list that doesn't read is left out")
        XCTAssertEqual(epic.doneSubTickets, [])
        XCTAssertNil(read.slots[1].epic)
        XCTAssertNil(read.slots[2].epic, "an epic naming no ticket is left out")
        XCTAssertEqual(read.slots.map { $0.ticket?.identifier }, ["TP-10", "TP-11", "TP-12"])
    }

    // MARK: - c2: rows to come are numbered on from the done count

    func testARowToComeContinuesTheEpicsCount() {
        let epic = HomeRead.SlotEpic(identifier: "TP-1597", done: 7, total: 14)
        XCTAssertEqual(epic.number(at: 0), 9, "7 done and one in work: the first to come is 9")
        XCTAssertEqual(epic.number(at: 5), 14)
    }

    // MARK: - c2, c3: two independent controls, both closed at first

    func testTheTwoListsAreClosedAtFirstAndOpenIndependently() async {
        let model = makeModel()
        await model.refresh()
        XCTAssertFalse(model.epicSlots.showsUpcoming("TP-1597"))
        XCTAssertFalse(model.epicSlots.showsDone("TP-1597"))

        model.toggleUpcoming(epic: "TP-1597")
        XCTAssertTrue(model.epicSlots.showsUpcoming("TP-1597"))
        XCTAssertFalse(model.epicSlots.showsDone("TP-1597"), "the band opens only what is to come")

        model.toggleSlotDone(epic: "TP-1597")
        XCTAssertTrue(model.epicSlots.showsDone("TP-1597"))
        XCTAssertTrue(model.epicSlots.showsUpcoming("TP-1597"), "the done count leaves what is to come as it was")

        model.toggleSlotDone(epic: "TP-1597")
        XCTAssertFalse(model.epicSlots.showsDone("TP-1597"), "a second click closes only the done list")
        XCTAssertTrue(model.epicSlots.showsUpcoming("TP-1597"))

        model.toggleUpcoming(epic: "TP-1597")
        XCTAssertEqual(model.epicSlots, HomeEpicSlotFold())
    }

    func testTheListsStayOpenAcrossAReadAgain() async {
        let model = makeModel()
        await model.refresh()
        model.toggleUpcoming(epic: "TP-1597")
        await model.queueChanged()
        XCTAssertTrue(model.epicSlots.showsUpcoming("TP-1597"))
    }

    // MARK: - c5: a Start the engine refuses leaves the page as it was and says why

    func testARefusedStartOnARowToComeChangesNothingAndSaysTheEnginesReason() async {
        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()
        let slots = model.slots
        let pager = model.pager
        await model.start("TP-1624", slot: 1)
        XCTAssertEqual(calls.moves, [.start("TP-1624", note: nil, slot: 1)])
        XCTAssertEqual(model.notice, "TP-1624 depends on TP-1623 and can't start before it is done.")
        XCTAssertEqual(model.slots, slots, "the card, the band's count and the list are as they were")
        XCTAssertEqual(model.pager.rows, pager.rows)
    }

    func testAStartTheEngineTakesSwapsTheSubTicketInWork() async {
        let model = makeModel()
        await model.refresh()
        await model.start("TP-1623", slot: 1)
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.cards[0].ticket?.identifier, "TP-1623", "the started one takes the slot")
        XCTAssertEqual(model.cards[0].epic?.identifier, "TP-1597", "the epic keeps it")
        XCTAssertEqual(Self.upcoming(model).first, "TP-1619", "the one that was in work is the first to come")
        XCTAssertEqual(Array(Self.upcoming(model).dropFirst()), Array(Self.open.dropFirst()))
    }

    // MARK: - c6: a row to come dropped elsewhere among its epic's lands there

    func testARowToComeDroppedAmongItsEpicsLandsThere() async {
        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()
        await model.moveUpcoming(inSlot: 1, from: 6, to: 0)
        XCTAssertEqual(calls.moves, [.queueMove("TP-1625", place: .before("TP-1623"))])
        let moved = ["TP-1625"] + Self.open.filter { $0 != "TP-1625" }
        XCTAssertEqual(calls.upcomingWhenSent, [moved], "the list showed the move at once")
        XCTAssertNil(model.notice)
        XCTAssertEqual(Self.upcoming(model), moved, "the read again has it there")

        await model.moveUpcoming(inSlot: 1, from: 0, to: 8)
        XCTAssertEqual(calls.moves.last, .queueMove("TP-1625", place: .after("TP-1626")))
        XCTAssertEqual(Self.upcoming(model), Self.open.filter { $0 != "TP-1625" } + ["TP-1625"])
    }

    func testADropAtItsOwnPlaceOrOnASlotWithoutAnEpicSendsNothing() async {
        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()
        await model.moveUpcoming(inSlot: 1, from: 2, to: 2)
        await model.moveUpcoming(inSlot: 1, from: 2, to: 3)
        await model.moveUpcoming(inSlot: 1, from: 20, to: 0)
        await model.moveUpcoming(inSlot: 2, from: 0, to: 1)
        await model.moveUpcoming(inSlot: 9, from: 0, to: 1)
        XCTAssertEqual(calls.moves, [])
        XCTAssertEqual(Self.upcoming(model), Self.open)
    }

    // MARK: - c7: a drop the engine refuses leaves the list as it was and says why

    func testADropAboveATicketItDependsOnIsRefusedAndTheListStaysAsItWas() async {
        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()
        await model.moveUpcoming(inSlot: 1, from: 1, to: 0)
        XCTAssertEqual(calls.moves, [.queueMove("TP-1624", place: .before("TP-1623"))])
        XCTAssertEqual(calls.upcomingWhenSent.first?.prefix(2), ["TP-1624", "TP-1623"], "the list showed the move at once")
        XCTAssertEqual(model.notice, "TP-1624 depends on TP-1623 and must stay below it.")
        XCTAssertEqual(Self.upcoming(model), Self.open, "the list is as it was")
    }

    // MARK: - The rules a drop in a card's list follows

    func testAPlaceInACardsListIsBeforeTheRowBelowOrAfterTheLast() {
        let rows = ["A", "B", "C"].map { HomeRead.Row(identifier: $0, number: "") }
        XCTAssertEqual(HomeQueueDrag.place(in: rows, from: 2, gap: 0), .before("A"))
        XCTAssertEqual(HomeQueueDrag.place(in: rows, from: 0, gap: 2), .before("C"))
        XCTAssertEqual(HomeQueueDrag.place(in: rows, from: 0, gap: 3), .after("C"))
        XCTAssertNil(HomeQueueDrag.place(in: rows, from: 1, gap: 1), "its own place")
        XCTAssertNil(HomeQueueDrag.place(in: rows, from: 1, gap: 2), "its own place")
        XCTAssertNil(HomeQueueDrag.place(in: rows, from: 3, gap: 0), "no such row")
        XCTAssertNil(HomeQueueDrag.place(in: rows, from: 0, gap: 4), "outside the list")
        XCTAssertEqual(HomeQueueDrag.moved(["A", "B", "C"], from: 2, gap: 0), ["C", "A", "B"])
        XCTAssertEqual(HomeQueueDrag.moved(["A", "B", "C"], from: 0, gap: 3), ["B", "C", "A"])
        XCTAssertEqual(HomeQueueDrag.moved(["A", "B", "C"], from: 0, gap: 1), ["A", "B", "C"])
        XCTAssertEqual(HomeQueueDrag.moved(["A", "B", "C"], from: 5, gap: 0), ["A", "B", "C"])
    }

    // MARK: - The fixture, as Symphony serves a slot's epic

    func testTheFixtureJudgesASlotEpicsSubTicketAmongItsSiblings() throws {
        let fixture = try XCTUnwrap(HomeQueueFixture(Data(contentsOf: directory.appendingPathComponent("api/v1/home.queue.json"))))
        let move = "/api/v1/control/queue/move", start = "/api/v1/control/start"
        XCTAssertEqual(
            fixture.refusal(path: move, body: ["issue_identifier": "TP-1609", "before": "TP-1607"]),
            "TP-1609 depends on TP-1607 and must stay below it."
        )
        XCTAssertNil(fixture.refusal(path: move, body: ["issue_identifier": "TP-1626", "position": "top"]))
        XCTAssertEqual(
            fixture.refusal(path: start, body: ["issue_identifier": "TP-1607", "slot": 1]),
            "TP-1607 depends on TP-1619 and can't start before it is done."
        )
        XCTAssertNil(fixture.refusal(path: start, body: ["issue_identifier": "TP-1625", "slot": 1]))
        // Once TP-1625 started, TP-1619 is the first to come, and a move of it is judged among the epic's sub-tickets.
        let started = HomeQueueFixture.Move(path: start, body: ["issue_identifier": "TP-1625", "slot": 1])
        XCTAssertEqual(
            fixture.refusal(path: move, body: ["issue_identifier": "TP-1619", "position": "end"], after: [started]),
            "TP-1607 depends on TP-1619 and must stay below it."
        )
        let other = HomeQueueFixture.Move(path: "/api/v1/control/slots", body: ["issue_identifier": "TP-1625"])
        XCTAssertEqual(HomeQueueFixture.applying(other, identifier: "TP-1625", toSlot: ["slot": 1]).count, 1, "no epic: nothing changes")
        XCTAssertEqual(
            HomeQueueFixture.openSubTickets(HomeQueueFixture.applying(other, identifier: "TP-1625", toSlot: fixture.slotEntries[0]))
                .compactMap { $0["identifier"] as? String },
            Self.open, "any other move changes nothing"
        )
    }
}
