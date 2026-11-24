import CoreGraphics
import Foundation
import XCTest
@testable import SymphonyBarCore

/// Home's drag and drop (TP-1610), on the `home-queue-drag` fixture as the fixtures serve it to QA: 2 slots, both taken
/// (TP-1619 and TP-1594), and a queue of 1,246 tickets whose fourth, TP-1605, waits on the person; Symphony refuses any
/// move of TP-1596, which depends on TP-1590. Every move goes through `ControlAPI` to the fixtures, which change the
/// queue as Symphony does.
@MainActor
final class HomeQueueDragTests: XCTestCase {
    private var log: URL!
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("home-queue-drag-\(UUID().uuidString)", isDirectory: true)
        log = root.appendingPathComponent(APIFixtures.requestLogFileName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private var fixtures: APIFixtures {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/home-queue-drag", isDirectory: true)
        return APIFixtures(directory: directory, requestLog: log)
    }

    /// The moves sent, and the queue the page showed at the moment each was sent.
    private final class Calls {
        var moves: [ControlAction] = []
        var shownWhenSent: [[String]] = []
        weak var model: HomeQueueModel?
    }

    /// A page model on the fixtures: reads as the window's client makes them, moves through the control API.
    private func makeModel(_ calls: Calls, view: String? = nil) -> HomeQueueModel {
        let fixtures = self.fixtures
        let root = self.root!
        let model = HomeQueueModel(
            fetch: { path, _ in
                let (data, response) = fixtures.answer(URLRequest(url: LiveAPIClient.url(path, base: APIFixtures.baseURL)!))
                return .changed(EndpointResult(.answered(data, statusCode: response.statusCode)), etag: nil)
            },
            send: { action in
                calls.moves.append(action)
                calls.shownWhenSent.append(calls.model.map { Self.shown($0.pager, count: 6) } ?? [])
                return await ControlAPI.send(
                    action, stateRoot: root, fallback: APIFixtures.baseURL, token: APIFixtures.token, transport: fixtures.transport
                )
            },
            view: view
        )
        calls.model = model
        return model
    }

    /// The first `count` rows the page shows, each "number identifier".
    private static func shown(_ pager: HomeQueuePager, count: Int) -> [String] {
        (0..<count).compactMap { pager.row(at: $0) }.map { "\($0.number) \($0.identifier)" }
    }

    private static let before = ["1 TP-1590", "2 TP-1592", "3 TP-1596", "4 TP-1605", "5 HUB-212", "6 TP-1700"]

    // MARK: - c1: a row dropped on another row's place moves there, and the numbers follow at once

    func testDroppingARowOnAnotherRowsPlaceMovesItThereAndTheNumbersFollowAtOnce() async throws {
        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()
        XCTAssertEqual(Self.shown(model.pager, count: 6), Self.before)

        let hub = try XCTUnwrap(model.pager.row(at: 4))
        await model.move(hub, from: 4, to: 1)

        XCTAssertEqual(calls.moves, [.queueMove("HUB-212", place: .before("TP-1592"))])
        let atOnce = ["1 TP-1590", "2 HUB-212", "3 TP-1592", "4 TP-1596", "5 TP-1605", "6 TP-1700"]
        XCTAssertEqual(calls.shownWhenSent, [atOnce], "the page shows the move before Symphony answers")
        XCTAssertEqual(Self.shown(model.pager, count: 6), atOnce, "Symphony's read after the move keeps it")
        XCTAssertNil(model.notice)
        let logged = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(logged.contains(#""before":"TP-1592""#), logged)
        XCTAssertTrue(logged.contains("/api/v1/control/queue/move"), logged)
    }

    func testARowDroppedFarDownTheQueueLandsThere() async throws {
        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()
        await model.show(150..<180)
        let row = try XCTUnwrap(model.pager.row(at: 170))
        await model.move(row, from: 170, to: 160)

        XCTAssertEqual(calls.moves, [.queueMove(row.identifier, place: .before("TP-2154"))])
        XCTAssertEqual(model.pager.row(at: 160)?.identifier, row.identifier)
        XCTAssertEqual(model.pager.row(at: 160)?.number, "161")
        XCTAssertEqual(model.pager.row(at: 161)?.identifier, "TP-2154")
        XCTAssertEqual(model.pager.row(at: 161)?.number, "162")
    }

    func testTheGapUnderThePointerIsTheNearestOnTheRowPitch() {
        XCTAssertEqual(HomeQueueDrag.gap(y: -30, count: 10), 0)
        XCTAssertEqual(HomeQueueDrag.gap(y: 17, count: 10), 0)
        XCTAssertEqual(HomeQueueDrag.gap(y: 19, count: 10), 1)
        XCTAssertEqual(HomeQueueDrag.gap(y: 36 * 7 + 5, count: 10), 7)
        XCTAssertEqual(HomeQueueDrag.gap(y: 36 * 40, count: 10), 10)
        XCTAssertEqual(HomeQueueDrag.lineY(3), 36 * 3 - 2)
        XCTAssertEqual(HomeQueueDrag.destination(from: 2, gap: 6), 5)
        XCTAssertEqual(HomeQueueDrag.destination(from: 6, gap: 2), 2)
    }

    func testAGapBecomesTheTopTheEndOrANeighbour() {
        var pager = HomeQueuePager(pageSize: 4)
        let rows = (0..<4).map { HomeRead.Row(identifier: "T-\($0)", number: String($0 + 1)) }
        pager.take(HomeRead.QueuePage(rows: rows, count: 10, total: 10, offset: 0, limit: 4), view: nil)
        XCTAssertEqual(HomeQueueDrag.place(from: 3, gap: 0, in: pager), .top)
        XCTAssertEqual(HomeQueueDrag.place(from: 1, gap: 10, in: pager), .end)
        XCTAssertEqual(HomeQueueDrag.place(from: 0, gap: 2, in: pager), .before("T-2"))
        // The row below the gap is not read: the row above it names the place.
        XCTAssertEqual(HomeQueueDrag.place(from: 0, gap: 4, in: pager), .after("T-3"))
        // Neither side read: nowhere to name.
        XCTAssertNil(HomeQueueDrag.place(from: 0, gap: 6, in: pager))
        // A drop at its own place sends nothing.
        XCTAssertNil(HomeQueueDrag.place(from: 2, gap: 2, in: pager))
        XCTAssertNil(HomeQueueDrag.place(from: 2, gap: 3, in: pager))
    }

    /// A queue with an epic and its open sub-tickets as the live Home read nests them: "1 A", "2 E", "2.1 E-1",
    /// "2.2 E-2", "3 B", "4 C".
    private static func nested() -> HomeQueuePager {
        var pager = HomeQueuePager(pageSize: 10)
        let rows = [
            HomeRead.Row(identifier: "A", number: "1"),
            HomeRead.Row(identifier: "E", number: "2"),
            HomeRead.Row(identifier: "E-1", number: "2.1", parent: "E"),
            HomeRead.Row(identifier: "E-2", number: "2.2", parent: "E"),
            HomeRead.Row(identifier: "B", number: "3"),
            HomeRead.Row(identifier: "C", number: "4"),
        ]
        pager.take(HomeRead.QueuePage(rows: rows, count: 6, total: 6, offset: 0, limit: 10), view: nil)
        return pager
    }

    private static func shown(_ pager: HomeQueuePager) -> [String] { shown(pager, count: pager.count) }

    func testAnEpicRowWithItsSubTicketsBelowItCannotBeDragged() {
        let pager = Self.nested()
        XCTAssertFalse(HomeQueueDrag.canDrag(pager.row(at: 1), at: 1, in: pager), "the epic would leave its sub-tickets behind")
        XCTAssertFalse(HomeQueueDrag.canDrag(pager.row(at: 2), at: 2, in: pager), "a sub-ticket is not a queue row to move")
        XCTAssertTrue(HomeQueueDrag.canDrag(pager.row(at: 0), at: 0, in: pager))
        XCTAssertTrue(HomeQueueDrag.canDrag(pager.row(at: 5), at: 5, in: pager), "the last row has nothing below it")
        var filtered = HomeQueuePager(view: "view-hub", pageSize: 10)
        let page = HomeRead.QueuePage(rows: [HomeRead.Row(identifier: "A", number: "1")], count: 1, total: 6, offset: 0, limit: 10)
        filtered.take(page, view: "view-hub")
        XCTAssertFalse(HomeQueueDrag.canDrag(filtered.row(at: 0), at: 0, in: filtered))
    }

    func testAGapInsideAnEpicsSubTicketsSnapsToTheGapAfterTheEpic() {
        let pager = Self.nested()
        XCTAssertEqual(HomeQueueDrag.snap(2, in: pager), 4, "between the epic and its first sub-ticket")
        XCTAssertEqual(HomeQueueDrag.snap(3, in: pager), 4, "between two sub-tickets")
        XCTAssertEqual(HomeQueueDrag.snap(1, in: pager), 1, "before the epic stays")
        XCTAssertEqual(HomeQueueDrag.snap(6, in: pager), 6)
    }

    func testARowMovedAcrossAnEpicKeepsTheEpicTogetherAndEveryNumberRight() {
        var up = Self.nested()
        up.move(up.row(at: 5)!, from: 5, to: 1)
        XCTAssertEqual(Self.shown(up), ["1 A", "2 C", "3 E", "3.1 E-1", "3.2 E-2", "4 B"])

        var down = Self.nested()
        down.move(down.row(at: 0)!, from: 0, to: 5)
        XCTAssertEqual(Self.shown(down), ["1 E", "1.1 E-1", "1.2 E-2", "2 B", "3 A", "4 C"])

        // Dropped between two sub-tickets, it lands after the epic.
        var inside = Self.nested()
        inside.move(inside.row(at: 0)!, from: 0, to: 3)
        XCTAssertEqual(Self.shown(inside), ["1 E", "1.1 E-1", "1.2 E-2", "2 A", "3 B", "4 C"])
    }

    func testADropBetweenAnEpicsSubTicketsIsSentAsBeforeTheNextTopLevelRow() async throws {
        let calls = Calls()
        let model = HomeQueueModel(fetch: { _, _ in .unchanged }, send: { calls.moves.append($0); return .done })
        let nested = Self.nested()
        let page = HomeRead.QueuePage(rows: (0..<nested.count).compactMap { nested.row(at: $0) }, count: 6, total: 6, offset: 0, limit: 10)
        model.load(HomeRead(queue: page))
        try await model.move(XCTUnwrap(model.pager.row(at: 0)), from: 0, to: 3)
        XCTAssertEqual(calls.moves, [.queueMove("A", place: .before("B"))])
        XCTAssertEqual(Self.shown(model.pager), ["1 E", "1.1 E-1", "1.2 E-2", "2 A", "3 B", "4 C"])

        // The epic itself is not moved.
        try await model.move(XCTUnwrap(model.pager.row(at: 0)), from: 0, to: 6)
        XCTAssertEqual(calls.moves.count, 1)
    }

    func testARowWhosePageWasDroppedStillLands() {
        var pager = HomeQueuePager(pageSize: 4)
        let rows = (0..<4).map { HomeRead.Row(identifier: "T-\($0)", number: String($0 + 1)) }
        pager.take(HomeRead.QueuePage(rows: rows, count: 8, total: 8, offset: 0, limit: 4), view: nil)
        // The dragged row, at 6, is in a page no longer held.
        pager.move(HomeRead.Row(identifier: "T-6", number: "7"), from: 6, to: 1)
        XCTAssertEqual(pager.row(at: 1)?.identifier, "T-6")
        XCTAssertEqual(pager.row(at: 1)?.number, "2")
        XCTAssertEqual(pager.row(at: 2)?.identifier, "T-1")
        XCTAssertEqual(pager.row(at: 2)?.number, "3")
        XCTAssertNil(pager.row(at: 6))
        // A move to its own place, or outside the list, changes nothing.
        let held = pager
        pager.move(HomeRead.Row(identifier: "T-0", number: "1"), from: 0, to: 1)
        pager.move(HomeRead.Row(identifier: "T-0", number: "1"), from: 0, to: 20)
        XCTAssertEqual(pager, held)
    }

    func testADropAtItsOwnPlaceSendsNothing() async throws {
        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()
        let row = try XCTUnwrap(model.pager.row(at: 2))
        await model.move(row, from: 2, to: 3)
        XCTAssertEqual(calls.moves, [])
        XCTAssertEqual(Self.shown(model.pager, count: 6), Self.before)
    }

    func testTheMoveBodyNamesOnePlace() {
        XCTAssertEqual(ControlAction.queueMove("A", place: .top).path, "api/v1/control/queue/move")
        XCTAssertEqual(ControlAction.queueMove("A", place: .top).body as? [String: String], ["issue_identifier": "A", "position": "top"])
        XCTAssertEqual(ControlAction.queueMove("A", place: .end).body as? [String: String], ["issue_identifier": "A", "position": "end"])
        XCTAssertEqual(ControlAction.queueMove("A", place: .after("B")).body as? [String: String], ["issue_identifier": "A", "after": "B"])
        XCTAssertEqual(ControlAction.queueMove("A", place: .before("B")).body as? [String: String], ["issue_identifier": "A", "before": "B"])
        XCTAssertEqual(ControlAction.queueMove("A", place: .top).failurePrefix, "Couldn't move A in the queue")
        XCTAssertNil(ControlAction.queueMove("A", place: .top).moveIdentifier)
    }

    // MARK: - c2: a row dropped on a slot starts there; the ticket that held it is first in the queue

    func testDroppingARowOnATakenSlotStartsItThereAndTheTicketThatHeldItIsFirstInTheQueue() async throws {
        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()
        XCTAssertEqual(model.cards.map { $0.ticket?.identifier }, ["TP-1619", "TP-1594"])

        await model.start("TP-1592", slot: 2)

        XCTAssertEqual(calls.moves, [.start("TP-1592", note: nil, slot: 2)])
        XCTAssertEqual(model.cards.map { $0.ticket?.identifier }, ["TP-1619", "TP-1592"])
        XCTAssertEqual(Self.shown(model.pager, count: 3), ["1 TP-1594", "2 TP-1590", "3 TP-1596"])
        XCTAssertFalse((0..<100).contains { model.pager.row(at: $0)?.identifier == "TP-1592" }, "a ticket in a slot is not in the queue")
        XCTAssertNil(model.notice)
        let logged = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(logged.contains(#""slot":2"#), logged)
    }

    func testDroppingARowOnAnEmptySlotSimplyStartsIt() async throws {
        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()
        await model.setSlots(3)
        XCTAssertEqual(model.cards.map(\.isEmpty), [false, false, true])

        await model.start("TP-1590", slot: 3)

        XCTAssertEqual(model.cards.map { $0.ticket?.identifier }, ["TP-1619", "TP-1594", "TP-1590"])
        XCTAssertEqual(Self.shown(model.pager, count: 2), ["1 TP-1592", "2 TP-1596"])
        XCTAssertEqual(model.pager.total, 1245)
    }

    func testTheStripLineWinsOverTheCardAndTheRowsBeneathIt() {
        let list = CGRect(x: 32, y: 400, width: 1000, height: 36 * 200)
        let cards = [1: CGRect(x: 32, y: 40, width: 1000, height: 300), 2: CGRect(x: 32, y: 352, width: 1000, height: 300)]
        let strip = [1: CGRect(x: 24, y: 6, width: 1016, height: 30), 2: CGRect(x: 24, y: 38, width: 1016, height: 30)]
        // A strip line over a card and the rows: the line.
        XCTAssertEqual(HomeQueueDrag.target(at: CGPoint(x: 300, y: 50), strip: strip, cards: cards, list: list, count: 200), .slot(2))
        // A card with no strip shown.
        XCTAssertEqual(HomeQueueDrag.target(at: CGPoint(x: 300, y: 50), strip: [:], cards: cards, list: list, count: 200), .slot(1))
        // Over the list: the gap nearest the pointer.
        XCTAssertEqual(HomeQueueDrag.target(at: CGPoint(x: 300, y: 400 + 36 * 9 + 3), strip: strip, cards: [:], list: list, count: 200), .gap(9))
        // Just above the list counts as its first gap; beside it, or well above, is nothing.
        XCTAssertEqual(HomeQueueDrag.target(at: CGPoint(x: 300, y: 390), strip: [:], cards: [:], list: list, count: 200), .gap(0))
        XCTAssertNil(HomeQueueDrag.target(at: CGPoint(x: 10, y: 600), strip: [:], cards: [:], list: list, count: 200))
        XCTAssertNil(HomeQueueDrag.target(at: CGPoint(x: 300, y: 300), strip: [:], cards: [:], list: list, count: 200))
        XCTAssertNil(HomeQueueDrag.target(at: CGPoint(x: 300, y: 300), strip: [:], cards: [:], list: nil, count: 200))
    }

    func testTheStartBodyNamesTheSlot() {
        XCTAssertEqual(ControlAction.start("A", note: nil, slot: 2).body["slot"] as? Int, 2)
        XCTAssertNil(ControlAction.start("A", note: nil).body["slot"])
        XCTAssertEqual(ControlAction.start("A", note: "now").body["note"] as? String, "now")
        XCTAssertEqual(ControlAction.start("A", note: nil, slot: 2).failurePrefix, "Couldn't start A in slot 2")
        XCTAssertEqual(ControlAction.start("A", note: nil).failurePrefix, "Couldn't start A now")
    }

    func testADragNearAnEdgeScrollsTheList() {
        XCTAssertEqual(HomeQueueDrag.scrollDirection(y: 880, top: 0, viewport: 900), 1)
        XCTAssertEqual(HomeQueueDrag.scrollDirection(y: 100, top: 72, viewport: 900), -1)
        XCTAssertEqual(HomeQueueDrag.scrollDirection(y: 400, top: 72, viewport: 900), 0)
        XCTAssertEqual(HomeQueueDrag.scrollDirection(y: 400, top: 0, viewport: 0), 0)
    }

    // MARK: - c3: no reordering under a saved filter

    func testUnderASavedFilterNoRowCanBeDragged() async throws {
        let calls = Calls()
        let model = makeModel(calls, view: "view-hub")
        await model.refresh()
        let first = try XCTUnwrap(model.pager.row(at: 0))
        let shown = Self.shown(model.pager, count: 4)
        XCTAssertFalse(HomeQueueDrag.canDrag(first, view: model.view))

        await model.move(first, from: 0, to: 3)

        XCTAssertEqual(calls.moves, [])
        XCTAssertEqual(Self.shown(model.pager, count: 4), shown, "the rows keep their real numbers")
        XCTAssertTrue(HomeQueueDrag.canDrag(first, view: nil))
        XCTAssertFalse(HomeQueueDrag.canDrag(nil, view: nil))
        XCTAssertFalse(HomeQueueDrag.canDrag(HomeRead.Row(identifier: "TP-2", number: "6.1", parent: "TP-1"), view: nil))
    }

    // MARK: - c4: a ticket that cannot start moves like any other

    func testATicketThatCannotStartIsDraggedLikeAnyOtherAndShowsItsNumberThere() async throws {
        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()
        let waiting = try XCTUnwrap(model.pager.row(at: 3))
        XCTAssertEqual(waiting.identifier, "TP-1605")
        XCTAssertTrue(waiting.waitsOnYou)
        XCTAssertTrue(HomeQueueDrag.canDrag(waiting, view: nil))

        await model.move(waiting, from: 3, to: 0)

        XCTAssertEqual(calls.moves, [.queueMove("TP-1605", place: .top)])
        XCTAssertEqual(Self.shown(model.pager, count: 4), ["1 TP-1605", "2 TP-1590", "3 TP-1592", "4 TP-1596"])
    }

    // MARK: - c5: a refused drop leaves the list as it was and says why

    func testARefusedDropLeavesTheQueueAsItWasAndSaysWhy() async throws {
        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()
        let refused = try XCTUnwrap(model.pager.row(at: 2))
        XCTAssertEqual(refused.identifier, "TP-1596")

        await model.move(refused, from: 2, to: 0)

        XCTAssertEqual(calls.moves, [.queueMove("TP-1596", place: .top)])
        XCTAssertEqual(Self.shown(model.pager, count: 6), Self.before)
        XCTAssertEqual(model.notice, "Couldn't move TP-1596 in the queue: TP-1596 depends on TP-1590 and must stay below it. (HTTP 409)")
    }

    func testTheFixtureRefusesOnlyTheMovesItNames() throws {
        let fixture = try XCTUnwrap(fixtures.homeQueueFixture())
        XCTAssertEqual(fixture.refusal(path: "/api/v1/control/queue/move", body: ["issue_identifier": "TP-1596"]), fixture.refuse["TP-1596"])
        XCTAssertNil(fixture.refusal(path: "/api/v1/control/queue/move", body: ["issue_identifier": "TP-1590"]))
        XCTAssertNil(fixture.refusal(path: "/api/v1/control/start", body: ["issue_identifier": "TP-1596"]))
        XCTAssertNil(fixture.refusal(path: "/api/v1/control/queue/move", body: nil))
        // Moves that name no ticket of the queue, or no place in it, change nothing.
        let moves = [
            HomeQueueFixture.Move(path: "/api/v1/control/queue/move", body: ["issue_identifier": "NOPE-1", "position": "top"]),
            HomeQueueFixture.Move(path: "/api/v1/control/queue/move", body: ["issue_identifier": "TP-1590", "after": "NOPE-1"]),
            HomeQueueFixture.Move(path: "/api/v1/control/start", body: ["issue_identifier": "TP-1590"]),
            HomeQueueFixture.Move(path: "/api/v1/control/stop", body: ["issue_identifier": "TP-1619"]),
        ]
        let applied = fixture.applying(moves, to: [])
        XCTAssertEqual(applied.rows.prefix(3).map { $0["identifier"] as? String }, ["TP-1590", "TP-1592", "TP-1596"])
        XCTAssertTrue(applied.entries.isEmpty)
        // To the end, and after a ticket.
        let ended = fixture.applying([
            HomeQueueFixture.Move(path: "/api/v1/control/queue/move", body: ["issue_identifier": "TP-1590", "position": "end"]),
            HomeQueueFixture.Move(path: "/api/v1/control/queue/move", body: ["issue_identifier": "TP-1592", "after": "TP-1596"]),
        ], to: [])
        XCTAssertEqual(ended.rows.first?["identifier"] as? String, "TP-1596")
        XCTAssertEqual(ended.rows[1]["identifier"] as? String, "TP-1592")
        XCTAssertEqual(ended.rows.last?["identifier"] as? String, "TP-1590")
        XCTAssertEqual(ended.rows.last?["number"] as? String, "1246")
    }
}
