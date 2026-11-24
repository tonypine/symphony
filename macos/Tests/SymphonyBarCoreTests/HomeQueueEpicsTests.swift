import Foundation
import XCTest
@testable import SymphonyBarCore

/// Epics and dependencies in Home's queue (TP-1645), on the `home-queue-epics` fixture as the fixtures serve it to QA: two
/// slots, both taken, and a queue whose sixth ticket is the epic TP-975 with six open sub-tickets (TP-976 to TP-981,
/// 6.1 to 6.6, each but the first waiting on another) and two done (TP-982, TP-983); then TP-1051, which waits for
/// TP-1590 to be released; the epic MOT-105 with three open sub-tickets (8.1 to 8.3) and one done; HUB-213, which
/// waits on HUB-212; TP-1700, whose dependency is met; and 200 generated tickets. The saved view "Rework" matches
/// TP-1596 and two of TP-975's sub-tickets. Every move goes through `ControlAPI` to the fixtures, which change the queue
/// and refuse a move or a Start as the engine does.
@MainActor
final class HomeQueueEpicsTests: XCTestCase {
    private var log: URL!
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("home-queue-epics-\(UUID().uuidString)", isDirectory: true)
        log = root.appendingPathComponent(APIFixtures.requestLogFileName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private var fixtures: APIFixtures {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/home-queue-epics", isDirectory: true)
        return APIFixtures(directory: directory, requestLog: log)
    }

    /// The moves sent, and what the page showed at the moment each was sent.
    private final class Calls {
        var moves: [ControlAction] = []
        var shownWhenSent: [[String]] = []
        weak var model: HomeQueueModel?
    }

    private func makeModel(_ calls: Calls = Calls(), view: String? = nil) -> HomeQueueModel {
        let fixtures = self.fixtures
        let root = self.root!
        let model = HomeQueueModel(
            fetch: { path, _ in
                let (data, response) = fixtures.answer(URLRequest(url: LiveAPIClient.url(path, base: APIFixtures.baseURL)!))
                return .changed(EndpointResult(.answered(data, statusCode: response.statusCode)), etag: nil)
            },
            send: { action in
                calls.moves.append(action)
                calls.shownWhenSent.append(calls.model.map { Self.shown($0.pager, count: 20) } ?? [])
                return await ControlAPI.send(
                    action, stateRoot: root, fallback: APIFixtures.baseURL, token: APIFixtures.token, transport: fixtures.transport
                )
            },
            view: view
        )
        calls.model = model
        return model
    }

    /// The first `count` places the list shows: a row as "number identifier", a done row as "done identifier".
    private static func shown(_ pager: HomeQueuePager, count: Int) -> [String] {
        (0..<min(count, pager.shownCount)).compactMap { index in
            switch pager.entry(at: index) {
            case let .done(_, _, ticket)?: "done \(ticket.identifier)"
            case .row?: pager.row(shown: index).map { "\($0.number) \($0.identifier)" }
            case nil: nil
            }
        }
    }

    private static let open = [
        "1 TP-1590", "2 TP-1592", "3 TP-1596", "4 TP-1605", "5 HUB-212", "6 TP-975", "6.1 TP-976", "6.2 TP-977", "6.3 TP-978",
        "6.4 TP-979", "6.5 TP-980", "6.6 TP-981", "7 TP-1051", "8 MOT-105", "8.1 MOT-106", "8.2 MOT-107", "8.3 MOT-108", "9 HUB-213",
        "10 TP-1700", "11 TP-2000",
    ]

    // MARK: - The read

    func testAQueueRowReadsItsDependenciesItsSubTicketsAndItsDoneSubTickets() throws {
        let json = #"""
        {"slots": {"total": 1, "entries": []}, "queue": {"rows": [
          {"identifier": "TP-975", "number": "6", "sub_tickets": {"done": 2, "total": 11},
           "done_sub_tickets": [{"issue_id": "i-982", "identifier": "TP-982", "title": "Name the files", "pull_request_number": 598,
                                 "done_at": "2026-09-29T10:00:00Z"}, {"issue_id": "i-990", "identifier": null}]},
          {"identifier": "TP-977", "number": "6.2", "parent": "TP-975", "dependencies": [
             {"issue_id": "i-976", "identifier": "TP-976", "kind": "done", "met": false},
             {"issue_id": "i-1590", "identifier": "TP-1590", "kind": "released", "met": false},
             {"issue_id": "i-900", "identifier": "TP-900", "kind": "done", "met": true},
             {"issue_id": "i-901", "kind": "sideways"}, {"kind": "done"}]},
          {"identifier": "TP-1", "number": 1, "dependencies": "not a list", "sub_tickets": {"done": 0, "total": 0}}
        ]}}
        """#
        let read = try XCTUnwrap(HomeRead.decode(Data(json.utf8)))
        let epic = read.queue.rows[0]
        XCTAssertEqual(epic.subTickets, HomeRead.SubTickets(done: 2, total: 11))
        XCTAssertTrue(epic.isEpic)
        XCTAssertEqual(epic.doneSubTickets.map(\.identifier), ["TP-982", "i-990"], "a done sub-ticket known by its id alone keeps its id")
        XCTAssertEqual(epic.doneSubTickets[0].pullRequestNumber, 598)
        XCTAssertNotNil(epic.doneSubTickets[0].doneAt)
        let sub = read.queue.rows[1]
        XCTAssertEqual(sub.dependencies.map(\.identifier), ["TP-976", "TP-1590", "TP-900", "i-901"], "a dependency naming no ticket is left out")
        XCTAssertEqual(sub.dependencies.map(\.kind), [.done, .released, .done, .done], "an unknown kind reads as done")
        XCTAssertEqual(sub.unmet.map(\.identifier), ["TP-976", "TP-1590", "i-901"], "a met dependency is not waited for")
        let plain = read.queue.rows[2]
        XCTAssertEqual(plain.dependencies, [], "a part that doesn't read leaves the row without it")
        XCTAssertFalse(plain.isEpic, "no sub-tickets: no epic")
        XCTAssertEqual(plain.doneSubTickets, [])
    }

    // MARK: - c1: an epic is one row whose chevron shows and hides its open sub-tickets, numbered inside it

    func testAnEpicIsOneRowWhoseChevronShowsAndHidesItsSubRows() async {
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(Self.shown(model.pager, count: 20), Self.open, "an epic is open at first, its sub-rows after it")
        XCTAssertEqual(model.pager.widestFraction(in: 0..<20), 2, "sub-rows on screen widen the number cell by \".1\"")
        XCTAssertEqual(model.pager.widestNumber(in: 0..<20), 11)

        await model.toggle(epic: "TP-975")
        XCTAssertEqual(
            Self.shown(model.pager, count: 8), ["1 TP-1590", "2 TP-1592", "3 TP-1596", "4 TP-1605", "5 HUB-212", "6 TP-975", "7 TP-1051", "8 MOT-105"]
        )
        XCTAssertEqual(model.pager.shownCount, model.pager.count - 6, "the closed epic's six sub-rows are not in the list")
        XCTAssertEqual(model.visible, model.pager.readRange(shown: model.shown))
        await model.toggle(epic: "MOT-105")
        XCTAssertEqual(model.pager.widestFraction(in: 0..<10), 0, "no sub-row on screen: the number cell holds whole numbers only")

        await model.toggle(epic: "TP-975")
        XCTAssertEqual(Self.shown(model.pager, count: 13), Array(Self.open.prefix(13)), "the chevron opens it again")

        // The fold stays through a read and through a saved view picked and let go.
        await model.refresh()
        XCTAssertEqual(Self.shown(model.pager, count: 15)[13...].map { $0 }, ["8 MOT-105", "9 HUB-213"])
        await model.pick(view: "view-hub")
        await model.pick(view: nil)
        XCTAssertFalse(model.pager.fold.isOpen("MOT-105"))
    }

    func testTheListsPlacesMapToTheReadAcrossAClosedEpic() async {
        let model = makeModel()
        await model.refresh()
        await model.toggle(epic: "TP-975")
        let pager = model.pager
        XCTAssertEqual(pager.readRange(shown: 4..<8), 4..<14, "the hidden sub-rows between are read with the rows around them")
        XCTAssertEqual(pager.readRange(shown: 0..<0), 0..<0)
        XCTAssertEqual(pager.readRange(shown: (pager.shownCount - 2)..<(pager.shownCount + 5)), (pager.count - 2)..<pager.count)
        XCTAssertEqual(pager.readGap(shown: 6), 12, "the gap after a closed epic stands before the row after its block")
        XCTAssertEqual(pager.readGap(shown: pager.shownCount), pager.count)
        XCTAssertNil(pager.entry(at: -1))
        XCTAssertNil(pager.row(shown: pager.shownCount))
        XCTAssertEqual(pager.block(at: pager.shownCount + 3, row: HomeRead.Row(identifier: "X", number: "1")), (pager.shownCount + 3)..<(pager.shownCount + 3))
    }

    // MARK: - c2: the done count shows and hides the done sub-tickets as done rows at the top of the block

    func testTheDoneCountShowsTheDoneSubTicketsAtTheTopOfTheBlockAndTheyNeitherDragNorStart() async {
        let model = makeModel()
        await model.refresh()
        await model.toggleDone(epic: "TP-975")
        XCTAssertEqual(
            Self.shown(model.pager, count: 10)[5...].map { $0 }, ["6 TP-975", "done TP-982", "done TP-983", "6.1 TP-976", "6.2 TP-977"],
            "the done rows, oldest first, come before the open sub-rows"
        )
        XCTAssertTrue(model.pager.fold.showsDone("TP-975"))
        XCTAssertEqual(model.pager.widestNumber(in: 6..<8), 0, "a done row holds no number")
        XCTAssertEqual(model.pager.widestFraction(in: 6..<8), 0)
        let epic = model.pager.row(shown: 5)
        XCTAssertFalse(HomeQueueDrag.canDrag(epic, at: 6, in: model.pager), "a done row's place is never dragged")
        XCTAssertNil(model.pager.row(shown: 6), "a done row is no queue row: it has no Start")
        XCTAssertEqual(model.pager.block(at: 5, row: epic!), 5..<14, "the done rows go with their epic's block")

        await model.toggleDone(epic: "TP-975")
        XCTAssertEqual(Self.shown(model.pager, count: 20), Self.open, "a second press hides them")

        // Pressed on a closed epic, the done count opens it with its done rows.
        await model.toggle(epic: "MOT-105")
        await model.toggleDone(epic: "MOT-105")
        XCTAssertEqual(Self.shown(model.pager, count: 17)[13...].map { $0 }, ["8 MOT-105", "done MOT-104", "8.1 MOT-106", "8.2 MOT-107"])
        // Closing an epic hides its done rows with its sub-rows; opening it shows both again.
        await model.toggle(epic: "MOT-105")
        XCTAssertEqual(Self.shown(model.pager, count: 15)[13...].map { $0 }, ["8 MOT-105", "9 HUB-213"])
        XCTAssertFalse(model.pager.fold.showsDone("MOT-105"))
        await model.toggle(epic: "MOT-105")
        XCTAssertEqual(Self.shown(model.pager, count: 15)[13...].map { $0 }, ["8 MOT-105", "done MOT-104"])
    }

    // MARK: - c4: a saved view keeps the same form, and reordering is off

    func testASavedViewKeepsTheEpicsRowAboveOnlyItsMatchingSubRowsWithTheirRealNumbers() async {
        let model = makeModel()
        await model.refresh()
        await model.pick(view: "view-rework")
        XCTAssertEqual(Self.shown(model.pager, count: 10), ["3 TP-1596", "6 TP-975", "6.3 TP-978", "6.6 TP-981"])
        XCTAssertEqual(model.pager.widestFraction(in: 0..<4), 2)
        for index in 0..<model.pager.shownCount {
            XCTAssertFalse(HomeQueueDrag.canDrag(model.pager.row(shown: index), at: index, in: model.pager), "no row drags under a saved view")
        }
        await model.toggle(epic: "TP-975")
        XCTAssertEqual(Self.shown(model.pager, count: 10), ["3 TP-1596", "6 TP-975"], "the chevron closes it as always")
        await model.toggle(epic: "TP-975")
        XCTAssertEqual(Self.shown(model.pager, count: 10), ["3 TP-1596", "6 TP-975", "6.3 TP-978", "6.6 TP-981"])
        let row = model.pager.row(shown: 2)!
        await model.move(row, from: 2, to: 3)
        XCTAssertEqual(Self.shown(model.pager, count: 10), ["3 TP-1596", "6 TP-975", "6.3 TP-978", "6.6 TP-981"], "nothing moves")
    }

    // MARK: - c5: a Start the engine refuses for an unmet dependency leaves the rows as they were

    func testARefusedStartLeavesTheRowsAsTheyWereAndSaysTheEnginesReason() async {
        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()
        let slots = model.slots
        await model.perform(.start("TP-977", note: nil))
        XCTAssertEqual(model.notice, "TP-977 depends on TP-976 and can't start before it is done.")
        XCTAssertEqual(Self.shown(model.pager, count: 20), Self.open)
        XCTAssertEqual(model.slots, slots, "no slot changes")

        await model.perform(.start("TP-1051", note: nil))
        XCTAssertEqual(model.notice, "TP-1051 depends on TP-1590 and can't start before it is released.")

        // A Start the engine takes clears the notice.
        await model.perform(.start("TP-1700", note: nil))
        XCTAssertNil(model.notice, "a met dependency starts")
    }

    // MARK: - c6: an epic moves with its sub-tickets; a sub-row moves among its siblings and nowhere else

    func testAnEpicsRowDraggedMovesWithItsSubTicketsAndTheNumbersFollow() async throws {
        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()
        let epic = try XCTUnwrap(model.pager.row(shown: 5))
        XCTAssertTrue(HomeQueueDrag.canDrag(epic, at: 5, in: model.pager))
        await model.move(epic, from: 5, to: 2)

        XCTAssertEqual(calls.moves, [.queueMove("TP-975", place: .before("TP-1596"))])
        let moved = [
            "1 TP-1590", "2 TP-1592", "3 TP-975", "3.1 TP-976", "3.2 TP-977", "3.3 TP-978", "3.4 TP-979", "3.5 TP-980", "3.6 TP-981", "4 TP-1596",
            "5 TP-1605", "6 HUB-212", "7 TP-1051",
        ]
        XCTAssertEqual(calls.shownWhenSent.first.map { Array($0.prefix(13)) }, moved, "the page shows the move before Symphony answers")
        XCTAssertEqual(Self.shown(model.pager, count: 13), moved, "Symphony's read after the move keeps it")
        XCTAssertNil(model.notice)
    }

    func testAClosedEpicMovesWithItsHiddenSubTickets() async throws {
        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()
        await model.toggle(epic: "TP-975")
        let epic = try XCTUnwrap(model.pager.row(shown: 5))
        // Dropped among MOT-105's sub-rows, it lands after that epic's block.
        await model.move(epic, from: 5, to: 8)
        XCTAssertEqual(calls.moves, [.queueMove("TP-975", place: .before("HUB-213"))])
        XCTAssertEqual(Self.shown(model.pager, count: 9), [
            "1 TP-1590", "2 TP-1592", "3 TP-1596", "4 TP-1605", "5 HUB-212", "6 TP-1051", "7 MOT-105", "7.1 MOT-106", "7.2 MOT-107",
        ])
        XCTAssertEqual(model.pager.row(at: 10)?.identifier, "TP-975")
        XCTAssertEqual(model.pager.row(at: 10)?.number, "8")
        XCTAssertEqual(model.pager.row(at: 11)?.number, "8.1", "the hidden sub-rows follow it with their numbers")
        XCTAssertEqual(Self.shown(model.pager, count: 12)[10...].map { $0 }, ["8 TP-975", "9 HUB-213"])
    }

    func testASubRowMovesAmongItsSiblingsAndNowhereElse() async throws {
        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()

        // Among its siblings: TP-979 (6.4) above TP-977 (6.2).
        let sub = try XCTUnwrap(model.pager.row(shown: 9))
        XCTAssertEqual(sub.identifier, "TP-979")
        XCTAssertTrue(HomeQueueDrag.canDrag(sub, at: 9, in: model.pager))
        await model.move(sub, from: 9, to: 7)
        XCTAssertEqual(calls.moves.last, .queueMove("TP-979", place: .before("TP-977")))
        XCTAssertEqual(Self.shown(model.pager, count: 12)[5...].map { $0 }, [
            "6 TP-975", "6.1 TP-976", "6.2 TP-979", "6.3 TP-977", "6.4 TP-978", "6.5 TP-980", "6.6 TP-981",
        ])

        // Dropped below its epic's block, it lands last among its siblings.
        let first = try XCTUnwrap(model.pager.row(shown: 14))
        XCTAssertEqual(first.identifier, "MOT-106")
        await model.move(first, from: 14, to: 18)
        XCTAssertEqual(calls.moves.last, .queueMove("MOT-106", place: .after("MOT-108")))
        XCTAssertEqual(Self.shown(model.pager, count: 18)[13...].map { $0 }, ["8 MOT-105", "8.1 MOT-107", "8.2 MOT-108", "8.3 MOT-106", "9 HUB-213"])

        // Dropped at the top of the queue, it lands first among its siblings.
        let last = try XCTUnwrap(model.pager.row(shown: 16))
        await model.move(last, from: 16, to: 0)
        XCTAssertEqual(calls.moves.last, .queueMove("MOT-106", place: .before("MOT-107")))
        XCTAssertEqual(Self.shown(model.pager, count: 17)[13...].map { $0 }, ["8 MOT-105", "8.1 MOT-106", "8.2 MOT-107", "8.3 MOT-108"])

        // The drop line's gap: a sub-row's gaps are only its siblings' places and the end of its parent's block.
        let pager = model.pager
        let mot = try XCTUnwrap(pager.row(shown: 15))
        XCTAssertEqual(HomeQueueDrag.snap(2, dragging: mot, from: 15, in: pager), 14)
        XCTAssertEqual(HomeQueueDrag.snap(16, dragging: mot, from: 15, in: pager), 16)
        XCTAssertEqual(HomeQueueDrag.snap(40, dragging: mot, from: 15, in: pager), 17)
        // A drop on its own place, or right after it, sends nothing.
        let count = calls.moves.count
        await model.move(mot, from: 15, to: 16)
        XCTAssertEqual(calls.moves.count, count)
    }

    func testASubRowWhoseParentIsNotReadHasNowhereToGo() {
        var pager = HomeQueuePager(pageSize: 2)
        let rows = [HomeRead.Row(identifier: "E-1", number: "1.1", parent: "E"), HomeRead.Row(identifier: "E-2", number: "1.2", parent: "E")]
        pager.take(HomeRead.QueuePage(rows: rows, count: 4, total: 4, offset: 2, limit: 2), view: nil)
        XCTAssertEqual(HomeQueueDrag.siblingGaps(parent: "E", from: 3, in: pager), [], "the epic's row at 0 is not read")
        XCTAssertEqual(HomeQueueDrag.snap(0, dragging: rows[1], from: 3, in: pager), 3, "it stays where it is")
        XCTAssertNil(HomeQueueDrag.place(rows[1], from: 3, gap: 3, in: pager))
        // The row above the gap is the parent: no sibling before it to name.
        var nested = HomeQueuePager(pageSize: 10)
        let block = [HomeRead.Row(identifier: "E", number: "1"), HomeRead.Row(identifier: "B", number: "2")]
        nested.take(HomeRead.QueuePage(rows: block, count: 2, total: 2, offset: 0, limit: 10), view: nil)
        XCTAssertNil(HomeQueueDrag.place(HomeRead.Row(identifier: "X", number: "1.1", parent: "E"), from: 5, gap: 1, in: nested))
        XCTAssertNil(HomeQueueDrag.place(block[1], from: 1, gap: 1, in: nested))
    }

    // MARK: - c7: a drop the engine refuses leaves the list as it was and says why

    func testADropAboveATicketItDependsOnIsRefusedAndTheListStaysAsItWas() async throws {
        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()
        let row = try XCTUnwrap(model.pager.row(shown: 8))
        XCTAssertEqual(row.identifier, "TP-978")
        await model.move(row, from: 8, to: 7)
        XCTAssertEqual(calls.moves, [.queueMove("TP-978", place: .before("TP-977"))])
        XCTAssertEqual(
            calls.shownWhenSent.first.map { Array($0[7...8]) }, ["6.2 TP-978", "6.3 TP-977"], "the page showed the move at once"
        )
        XCTAssertEqual(model.notice, "TP-978 depends on TP-977 and must stay below it.")
        XCTAssertEqual(Self.shown(model.pager, count: 20), Self.open, "the list is as it was")
    }

    func testADropOnASlotForATicketThatWaitsIsRefusedAndNoSlotChanges() async {
        let model = makeModel()
        await model.refresh()
        let slots = model.slots
        await model.start("TP-977", slot: 1)
        XCTAssertEqual(model.notice, "TP-977 depends on TP-976 and can't start before it is done.")
        XCTAssertEqual(model.slots, slots)
        XCTAssertEqual(Self.shown(model.pager, count: 20), Self.open)
    }

    // MARK: - The fixture, as Symphony serves the queue

    func testTheFixtureNumbersNestedRowsAndKeepsAnEpicAboveItsMatchingSubRows() throws {
        let rows: [[String: Any]] = [
            ["identifier": "A"], ["identifier": "E"], ["identifier": "E-1", "parent": "E"], ["identifier": "E-2", "parent": "E"],
            ["identifier": "X", "parent": "NOT-QUEUED"], ["identifier": "B", "phase": "Rework"],
        ]
        let numbered = HomeQueueFixture.numbered(rows)
        XCTAssertEqual(numbered.map { $0["number"] as? String }, ["1", "2", "2.1", "2.2", "3", "4"], "a parent not in the queue counts as none")
        var phased = numbered
        phased[3]["phase"] = "Rework"
        let kept = HomeQueueFixture.keeping(phased, filters: ["phase": ["Rework"]])
        XCTAssertEqual(kept.map { $0["identifier"] as? String }, ["E", "E-2", "B"])
    }

    func testTheFixtureMovesABlockInsideItsScope() throws {
        let rows = HomeQueueFixture.numbered([
            ["identifier": "A"], ["identifier": "E"], ["identifier": "E-1", "parent": "E"], ["identifier": "E-2", "parent": "E"],
            ["identifier": "E-3", "parent": "E"], ["identifier": "B"],
        ])
        func order(_ moved: [[String: Any]]?) -> [String] { (moved ?? []).compactMap { $0["identifier"] as? String } }
        XCTAssertEqual(order(HomeQueueFixture.moving("E", body: ["position": "top"], in: rows)), ["E", "E-1", "E-2", "E-3", "A", "B"])
        XCTAssertEqual(order(HomeQueueFixture.moving("E", body: ["position": "end"], in: rows)), ["A", "B", "E", "E-1", "E-2", "E-3"])
        XCTAssertEqual(order(HomeQueueFixture.moving("A", body: ["after": "E"], in: rows)), ["E", "E-1", "E-2", "E-3", "A", "B"])
        XCTAssertEqual(order(HomeQueueFixture.moving("E-3", body: ["position": "top"], in: rows)), ["A", "E", "E-3", "E-1", "E-2", "B"])
        XCTAssertEqual(order(HomeQueueFixture.moving("E-1", body: ["position": "end"], in: rows)), ["A", "E", "E-2", "E-3", "E-1", "B"])
        XCTAssertEqual(order(HomeQueueFixture.moving("E-1", body: ["before": "E-3"], in: rows)), ["A", "E", "E-2", "E-1", "E-3", "B"])
        XCTAssertNil(HomeQueueFixture.moving("E-1", body: ["before": "B"], in: rows), "a place outside its scope moves nothing")
        XCTAssertNil(HomeQueueFixture.moving("NOPE", body: ["position": "top"], in: rows))
        let only = HomeQueueFixture.numbered([["identifier": "E"], ["identifier": "E-1", "parent": "E"]])
        XCTAssertNil(HomeQueueFixture.moving("E-1", body: ["position": "top"], in: only), "no sibling left to stand before")
    }

    func testTheFixtureRefusesOnlyWhatTheEngineRefuses() throws {
        let fixture = try XCTUnwrap(HomeQueueFixture(Data(contentsOf: fixtures.homeQueueFile)))
        let move = HomeQueueFixture.movePath
        XCTAssertEqual(
            fixture.refusal(path: move, body: ["issue_identifier": "TP-978", "before": "TP-977"]), "TP-978 depends on TP-977 and must stay below it."
        )
        XCTAssertNil(fixture.refusal(path: move, body: ["issue_identifier": "TP-978", "after": "TP-980"]), "below it stays allowed")
        XCTAssertNil(fixture.refusal(path: move, body: ["issue_identifier": "TP-1700", "position": "top"]), "a met dependency holds nothing")
        XCTAssertNil(fixture.refusal(path: move, body: ["issue_identifier": "TP-978", "before": "NOPE"]))
        XCTAssertNil(fixture.refusal(path: move, body: nil))
        XCTAssertNil(fixture.refusal(path: "/api/v1/control/stop", body: ["issue_identifier": "TP-977"]))
        let start = HomeQueueFixture.startPath
        XCTAssertNil(fixture.refusal(path: start, body: ["issue_identifier": "TP-976"]))
        XCTAssertNil(fixture.refusal(path: start, body: ["issue_identifier": "NOT-QUEUED"]))
        // Once TP-978 moved below TP-980, TP-981, which depends on it, can't go above it.
        let after = [HomeQueueFixture.Move(path: move, body: ["issue_identifier": "TP-978", "after": "TP-980"])]
        XCTAssertEqual(
            fixture.refusal(path: move, body: ["issue_identifier": "TP-981", "after": "TP-977"], after: after),
            "TP-981 depends on TP-978 and must stay below it."
        )
    }
}
