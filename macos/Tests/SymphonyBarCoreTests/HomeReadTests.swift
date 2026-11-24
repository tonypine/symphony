import Foundation
import XCTest
@testable import SymphonyBarCore

/// Home, the window to the queue (TP-1609), from `GET /api/v1/home`: the slots and the paged queue, read from the
/// generated `home-queue` fixture as the fixtures serve it to QA (3 slots: one working, one waiting on you, one empty;
/// a queue of 1,245 tickets; two saved views).
@MainActor
final class HomeReadTests: XCTestCase {
    private let reference = ISO8601DateFormatter().date(from: "2026-10-07T14:20:00Z")!
    private var log: URL!

    override func setUp() {
        log = FileManager.default.temporaryDirectory.appendingPathComponent("home-queue-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: log)
    }

    private static func directory(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/\(name)", isDirectory: true)
    }

    private static func fixture(_ name: String, in directory: String = "home-queue") -> URL {
        self.directory(directory).appendingPathComponent("api/v1/\(name)")
    }

    private var fixtures: APIFixtures { APIFixtures(directory: Self.directory("home-queue"), requestLog: log) }

    /// The fixtures' answer to a read of `path`, as the window's client gives it.
    private func get(_ path: String) -> ConditionalResult {
        let url = LiveAPIClient.url(path, base: APIFixtures.baseURL)!
        let (data, response) = fixtures.answer(URLRequest(url: url))
        return .changed(EndpointResult(.answered(data, statusCode: response.statusCode)), etag: nil)
    }

    private func homeRead(_ path: String = HomeRead.path(offset: 0)) throws -> HomeRead {
        guard case let .changed(.loaded(data), _) = get(path) else { throw XCTSkip("no answer") }
        return try XCTUnwrap(HomeRead.decode(data))
    }

    /// A page model on the fixtures: every read and move goes to them, each recorded.
    private final class Calls {
        var reads: [String] = []
        var moves: [ControlAction] = []
    }

    private func makeModel(_ calls: Calls, refuse: Bool = false) -> HomeQueueModel {
        let fixtures = self.fixtures
        return HomeQueueModel(
            fetch: { [unowned self] path, _ in
                calls.reads.append(path)
                return self.get(path)
            },
            send: { action in
                calls.moves.append(action)
                if refuse { return .failed("Couldn't do it: the engine refused") }
                _ = fixtures.answer(ControlAPI.request(action, base: APIFixtures.baseURL, token: APIFixtures.token))
                return .done
            }
        )
    }

    // MARK: - c1: two sections, one card per slot, an empty slot, no slotted ticket in the queue

    func testInProgressHasOneCardPerSlotAndAnEmptySlotShowsEmpty() async throws {
        let read = try homeRead()
        XCTAssertEqual(read.slotCount, 3)
        XCTAssertEqual(read.slots.map(\.number), [1, 2, 3])
        XCTAssertEqual(read.slots.map { $0.ticket?.identifier }, ["TP-1619", "TP-1594", nil])
        XCTAssertTrue(read.slots[2].isEmpty)

        let working = try XCTUnwrap(read.slots[0].ticket)
        XCTAssertTrue(working.working)
        XCTAssertFalse(working.waitsOnYou)
        XCTAssertEqual(working.currentStage, "coding")
        XCTAssertEqual(working.tokens, 14_200_000)
        XCTAssertEqual(working.tokenBudget, 100_000_000)
        XCTAssertEqual(working.checks, HomeRead.Checks(proved: 3, total: 11, next: "Adding a dependency on a lower ticket is refused with the reason."))
        XCTAssertNil(working.pullRequest)

        let waiting = try XCTUnwrap(read.slots[1].ticket)
        XCTAssertTrue(waiting.waitsOnYou)
        XCTAssertEqual(waiting.move, HomeRead.Move(name: "answer"))
        XCTAssertEqual(waiting.stages.map(\.state), ["passed", "current", "not_yet", "not_yet", "not_yet"])
        XCTAssertEqual(
            waiting.pullRequest,
            HomeRead.PullRequest(number: 1043, filesChanged: 11, additions: 524, deletions: 61, branch: "auto/TP-1594", ci: "passed", reviewState: "REVIEW_REQUIRED")
        )

        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(model.cards.map(\.number), [1, 2, 3])
        XCTAssertEqual(model.cards.map(\.isEmpty), [false, false, true])
        // A ticket that holds a slot is never a queue row.
        let rows = (0..<model.pager.count).compactMap { model.pager.row(at: $0)?.identifier }
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(read.slotted.isDisjoint(with: rows))
        XCTAssertEqual(HomeQueueModel.progressTitle, "In progress")
        XCTAssertEqual(HomeQueueModel.queueTitle, "Queue")
    }

    /// A slot a ticket still holds past a lowered count keeps its card; the free numbers up to the count are empty.
    func testCardsRunToTheCountAndKeepAHeldSlotPastIt() async {
        let calls = Calls()
        let model = makeModel(calls)
        model.load(HomeRead(slotCount: 2, slots: [HomeRead.Slot(number: 4, ticket: HomeRead.SlotTicket(identifier: "TP-9"))]))
        XCTAssertEqual(model.cards.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(model.cards.map(\.isEmpty), [true, true, true, false])
        model.load(HomeRead())
        XCTAssertTrue(model.cards.isEmpty)
    }

    // MARK: - c2: the slot count control

    func testChangingTheSlotCountSendsItAndTheCardsFollowAtOnce() async throws {
        XCTAssertEqual(ControlAction.slots(4).path, "api/v1/control/slots")
        XCTAssertEqual(ControlAction.slots(4).body as? [String: Int], ["count": 4])
        XCTAssertEqual(ControlAction.slots(4).failurePrefix, "Couldn't set the slots to 4")
        XCTAssertNil(ControlAction.slots(4).moveIdentifier)

        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()
        XCTAssertEqual(model.slotCount, 3)

        var seen: [Int] = []
        let watch = model.$slotCount.sink { seen.append($0) }
        await model.setSlots(4)
        watch.cancel()
        XCTAssertEqual(calls.moves, [.slots(4)])
        // The control shows 4 before any read, and the engine's answer settles it there.
        XCTAssertEqual(seen.dropFirst().first, 4)
        XCTAssertEqual(model.slotCount, 4)
        XCTAssertEqual(model.cards.map(\.number), [1, 2, 3, 4])
        XCTAssertTrue(model.cards[3].isEmpty)
        XCTAssertEqual(fixtures.lastSlotCount(), 4)

        // Kept from 1 to 6; the same count sends nothing.
        await model.setSlots(9)
        XCTAssertEqual(calls.moves.last, .slots(6))
        await model.setSlots(6)
        XCTAssertEqual(calls.moves.count, 2)
    }

    func testARefusedSlotCountPutsTheEnginesCountBackAndSaysWhy() async {
        let calls = Calls()
        let model = makeModel(calls, refuse: true)
        await model.refresh()
        await model.setSlots(2)
        XCTAssertEqual(model.slotCount, 3)
        XCTAssertEqual(model.notice, "Couldn't do it: the engine refused")
        XCTAssertEqual(model.cards.count, 3)
    }

    // MARK: - c3: Stop frees the slot

    func testStopGoesThroughTheControlRouteAndHomeReadsAgain() async throws {
        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()
        let before = calls.reads.count
        await model.perform(.stop("TP-1619"))
        XCTAssertEqual(calls.moves, [.stop("TP-1619")])
        XCTAssertEqual(ControlAction.stop("TP-1619").path, "api/v1/control/stop")
        XCTAssertGreaterThan(calls.reads.count, before, "Home reads the slots again after Stop")
        XCTAssertNil(model.notice)

        // After the engine freed the slot, the read shows it empty.
        model.load(HomeRead(slotCount: 3, slots: [HomeRead.Slot(number: 2, ticket: HomeRead.SlotTicket(identifier: "TP-1594"))]))
        XCTAssertEqual(model.cards.map(\.isEmpty), [true, false, true])
    }

    func testARefusedMoveSaysWhyOnThePage() async {
        let calls = Calls()
        let model = makeModel(calls, refuse: true)
        await model.perform(.start("TP-1590", note: nil))
        XCTAssertEqual(model.notice, "Couldn't do it: the engine refused")
    }

    // MARK: - c4: every ticket in its stored order with its number; a saved view keeps the real numbers

    func testTheQueueListsEveryTicketInOrderWithItsNumber() async throws {
        let read = try homeRead()
        XCTAssertEqual(read.queue.total, 1245)
        XCTAssertEqual(read.queue.count, 1245)
        XCTAssertEqual(read.queue.rows.count, 100)
        XCTAssertEqual(read.queue.nextOffset, 100)
        XCTAssertEqual(read.queue.rows.map(\.number), (1...100).map(String.init))
        XCTAssertEqual(read.queue.rows.prefix(4).map(\.identifier), ["TP-1590", "TP-1592", "TP-1596", "HUB-212"])
        XCTAssertEqual(read.queue.rows[0].phase, "Code Review")
        XCTAssertEqual(read.queue.rows[0].situation?.kind, .working)

        let last = try homeRead(HomeRead.path(offset: 1200))
        XCTAssertEqual(last.queue.rows.count, 45)
        XCTAssertNil(last.queue.nextOffset)
        XCTAssertEqual(last.queue.rows.last?.number, "1245")
    }

    func testASavedViewKeepsTheMatchingRowsWithTheirRealNumbers() async throws {
        XCTAssertEqual(HomeRead.path(offset: 100, view: "view a&b"), "api/v1/home?offset=100&limit=100&view=view%20a%26b")
        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()
        await model.pick(view: "view-hub")
        XCTAssertEqual(calls.reads.last, "api/v1/home?offset=0&limit=100&view=view-hub")
        XCTAssertEqual(model.view, "view-hub")
        XCTAssertEqual(model.pager.total, 1245)
        XCTAssertLessThan(model.pager.count, 1245)
        let first = try XCTUnwrap(model.pager.row(at: 0))
        XCTAssertEqual(first.identifier, "HUB-212")
        XCTAssertEqual(first.number, "4", "a filtered row keeps its number in the whole queue")
        XCTAssertTrue((0..<min(model.pager.count, 100)).compactMap { model.pager.row(at: $0) }.allSatisfy { $0.repoKey == "hub" })

        // Back to every ticket: the whole queue from its top.
        await model.pick(view: nil)
        XCTAssertEqual(model.pager.count, 1245)
        XCTAssertEqual(model.pager.row(at: 0)?.number, "1")
    }

    func testAPageReadForAViewNoLongerPickedIsDropped() {
        var pager = HomeQueuePager(view: "view-hub")
        pager.take(HomeRead.QueuePage(rows: [HomeRead.Row(identifier: "TP-1", number: "1")], count: 1), view: nil)
        XCTAssertEqual(pager.count, 0)
        XCTAssertNil(pager.row(at: 0))
    }

    // MARK: - c5: read in pages as the person scrolls; only the rows on screen are drawn

    func testOnlyTheRowsOnScreenAreDrawnAndTheirPagesRead() async throws {
        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()
        XCTAssertEqual(calls.reads, ["api/v1/home?offset=0&limit=100"])
        XCTAssertEqual(model.pager.height, 1245 * 36)

        // The list starts 900 pt down the page, the view is 800 pt tall, scrolled to row 1,000.
        let range = HomeQueuePager.visibleRange(scrollTop: 900 + 1000 * 36, listTop: 900, viewport: 800, count: model.pager.count)
        XCTAssertEqual(range, (1000 - HomeQueuePager.overscan)..<(1000 + 23 + HomeQueuePager.overscan))
        XCTAssertLessThan(range.count, 40, "a screenful of rows, not 1,245")

        await model.show(range)
        XCTAssertEqual(calls.reads.suffix(2), ["api/v1/home?offset=900&limit=100", "api/v1/home?offset=1000&limit=100"])
        XCTAssertEqual(model.pager.row(at: 1000)?.number, "1001")
        XCTAssertNil(model.pager.row(at: 500), "a page never on screen is never read")
        // The same rows again read nothing.
        let count = calls.reads.count
        await model.show(range)
        XCTAssertEqual(calls.reads.count, count)

        // The last rows: the last page, with nothing after it.
        let end = HomeQueuePager.visibleRange(scrollTop: 900 + 1245 * 36, listTop: 900, viewport: 800, count: model.pager.count)
        XCTAssertEqual(end.upperBound, 1245)
        await model.show(end)
        XCTAssertEqual(model.pager.row(at: 1244)?.number, "1245")
        XCTAssertEqual(model.pager.widestNumber(in: end), 1245)
    }

    func testHomeOpenedAtTheTopDrawsItsFirstRowsBeforeAnyScroll() async throws {
        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()

        // Nothing measured yet: no scroll, no viewport, the list's top not reported.
        let range = HomeQueuePager.visibleRange(scrollTop: 0, listTop: 0, viewport: 0, count: model.pager.count)
        XCTAssertEqual(range, 0..<(Int(HomeQueuePager.assumedViewport / HomeQueuePager.pitch) + HomeQueuePager.overscan))
        XCTAssertLessThan(range.count, 100, "a screenful of rows, not 1,245")
        await model.show(range)
        XCTAssertEqual(calls.reads, ["api/v1/home?offset=0&limit=100"], "page 0, read once")
        XCTAssertEqual(model.pager.row(at: 0)?.identifier, "TP-1590")
        XCTAssertEqual(model.pager.row(at: 0)?.number, "1")
        XCTAssertNotNil(model.pager.row(at: range.upperBound - 1))
    }

    func testTheVisibleRangeStaysInsideTheList() {
        // A list below the screen draws only the overscan's first rows.
        XCTAssertEqual(HomeQueuePager.visibleRange(scrollTop: 0, listTop: 900, viewport: 800, count: 1245), 0..<4)
        XCTAssertEqual(HomeQueuePager.visibleRange(scrollTop: 0, listTop: 100, viewport: 800, count: 1245), 0..<(20 + HomeQueuePager.overscan))
        XCTAssertEqual(HomeQueuePager.visibleRange(scrollTop: 0, listTop: 0, viewport: 0, count: 10), 0..<10, "an unmeasured viewport still draws")
        XCTAssertEqual(HomeQueuePager.visibleRange(scrollTop: 0, listTop: 0, viewport: 800, count: 0), 0..<0)
        XCTAssertEqual(HomeQueuePager.visibleRange(scrollTop: 0, listTop: 0, viewport: 800, count: 5), 0..<5)

        let pager = HomeQueuePager(pageSize: 100)
        XCTAssertEqual(pager.pages(covering: 95..<205), [0, 100, 200])
        XCTAssertEqual(pager.pages(covering: 0..<0), [])
        XCTAssertEqual(pager.widestNumber(in: 0..<0), 0)
    }

    func testASubTicketsNumberCountsAsItsWholeNumberForTheCell() {
        var pager = HomeQueuePager()
        pager.take(HomeRead.QueuePage(rows: [HomeRead.Row(identifier: "A", number: "6"), HomeRead.Row(identifier: "B", number: "6.1")], count: 2), view: nil)
        XCTAssertEqual(pager.widestNumber(in: 0..<2), 6)
    }

    func testARowsNumberReadsFromAWholeNumberOrItsPath() throws {
        let json = #"{"queue": {"rows": [{"identifier": "A", "number": 7}, {"identifier": "B", "path": [7, 2]}, {"identifier": "C", "number": "8"}]}}"#
        let read = try XCTUnwrap(HomeRead.decode(Data(json.utf8)))
        XCTAssertEqual(read.queue.rows.map(\.number), ["7", "7.2", "8"])
        XCTAssertEqual(read.queue.count, 3)
        XCTAssertEqual(read.slotCount, 0)
        XCTAssertNil(HomeRead.decode(Data("[]".utf8)))
    }

    // MARK: - c6: Start on a row

    func testStartOnARowStartsTheTicketThroughTheControlAPI() async throws {
        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()
        await model.perform(TicketStart.action("TP-1590"))
        XCTAssertEqual(calls.moves, [.start("TP-1590", note: nil)])
        XCTAssertEqual(ControlAction.start("TP-1590", note: nil).path, "api/v1/control/start")
        let logged = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(logged.contains("/api/v1/control/start"), logged)
    }

    // MARK: - c7: the page follows the engine at once

    func testAQueueNoticeReadsTheSlotsAndTheRowsOnScreenAgain() async throws {
        let calls = Calls()
        let model = makeModel(calls)
        await model.refresh()
        await model.show(150..<180)
        calls.reads = []
        await model.setSlots(4)
        calls.reads = []

        // Another client changed the slots: the engine tells, Home reads at once.
        _ = fixtures.answer(ControlAPI.request(.slots(2), base: APIFixtures.baseURL, token: APIFixtures.token))
        await model.queueChanged()
        XCTAssertEqual(calls.reads, ["api/v1/home?offset=0&limit=100", "api/v1/home?offset=100&limit=100"])
        XCTAssertEqual(model.slotCount, 2, "the count is the engine's")
        XCTAssertEqual(model.cards.map(\.number), [1, 2])
    }

    func testStalePagesOffScreenAreDroppedAfterAChange() {
        var pager = HomeQueuePager(pageSize: 2)
        pager.take(HomeRead.QueuePage(rows: [.init(identifier: "A", number: "1"), .init(identifier: "B", number: "2")], count: 4, offset: 0), view: nil)
        pager.take(HomeRead.QueuePage(rows: [.init(identifier: "C", number: "3"), .init(identifier: "D", number: "4")], count: 4, offset: 2), view: nil)
        pager.invalidate()
        XCTAssertEqual(pager.pagesToRead(for: 0..<4), [0, 2])
        XCTAssertEqual(pager.row(at: 2)?.identifier, "C", "a stale page is drawn until it is read again")
        XCTAssertEqual(pager.dropStale(outside: 0..<2), [2])
        XCTAssertNil(pager.row(at: 2))
        XCTAssertEqual(pager.row(at: 0)?.identifier, "A")
        // A queue that shrank leaves no row past its end.
        pager.take(HomeRead.QueuePage(rows: [.init(identifier: "A", number: "1")], count: 1, offset: 0), view: nil)
        XCTAssertNil(pager.row(at: 1))
    }

    func testAnUnchangedReadKeepsThePage() async {
        var answers: [ConditionalResult] = []
        let data = Data(#"{"slots": {"total": 1, "entries": []}, "queue": {"rows": [{"identifier": "A", "number": "1"}], "count": 1, "total": 1}}"#.utf8)
        answers = [.changed(.loaded(data), etag: "v1"), .unchanged]
        var tags: [String?] = []
        let model = HomeQueueModel(fetch: { _, tag in
            tags.append(tag)
            return answers.removeFirst()
        }, send: { _ in .done })
        await model.refresh()
        await model.refresh()
        XCTAssertEqual(tags, [nil, "v1"])
        XCTAssertEqual(model.pager.row(at: 0)?.identifier, "A")
        XCTAssertEqual(model.slotCount, 1)
    }

    func testAPageDroppedOffScreenIsReadInFullWhenItComesBack() async {
        // Symphony answers 304 to every read that sends a tag: the queue never changes.
        func page(_ offset: Int) -> Data {
            let rows = (offset..<(offset + 100)).map { #"{"identifier": "T-\#($0)", "number": "\#($0 + 1)"}"# }.joined(separator: ",")
            return Data(#"{"slots": {"total": 1, "entries": []}, "queue": {"rows": [\#(rows)], "count": 300, "total": 300}}"#.utf8)
        }
        var reads: [(path: String, tag: String?)] = []
        let model = HomeQueueModel(fetch: { path, tag in
            reads.append((path, tag))
            if tag != nil { return .unchanged }
            let offset = path.contains("offset=100") ? 100 : 0
            return .changed(.loaded(page(offset)), etag: "v-\(offset)")
        }, send: { _ in .done })
        await model.refresh()
        await model.show(100..<130)
        XCTAssertEqual(model.pager.row(at: 100)?.identifier, "T-100")

        // Back to the top, then a poll's refresh drops page 100, which is off screen.
        await model.show(0..<30)
        await model.refresh()
        XCTAssertNil(model.pager.row(at: 100))

        // Scrolling back reads page 100 without its old tag, so its rows are drawn again.
        reads = []
        await model.show(100..<130)
        XCTAssertEqual(reads.map(\.path), ["api/v1/home?offset=100&limit=100"])
        XCTAssertNil(reads.first?.tag)
        XCTAssertEqual(model.pager.row(at: 100)?.identifier, "T-100")
    }

    // MARK: - No read to show

    func testAReadWithNothingToShowSaysWhy() async {
        XCTAssertEqual(HomeQueueModel.failure(after: .changed(.unsupported, etag: nil)), .unsupported)
        XCTAssertEqual(HomeQueueModel.failure(after: .changed(.failed("Symphony isn't answering"), etag: nil)), .failed("Symphony isn't answering"))
        XCTAssertEqual(HomeQueueModel.failure(after: .changed(.loaded(Data("not json".utf8)), etag: "v1")), .failed(HomeQueueModel.unreadable))
        XCTAssertEqual(HomeQueueModel.failure(after: .unchanged), .failed(HomeQueueModel.unreadable))

        let model = HomeQueueModel(fetch: { _, _ in .changed(.unsupported, etag: nil) }, send: { _ in .done })
        await model.refresh()
        XCTAssertFalse(model.loaded)
        XCTAssertEqual(model.failure, .unsupported)
    }

    // MARK: - A provider that refuses the agents' sign-in (TP-1515)

    func testASignInHoldIsOneLineAboveTheSections() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let state = try XCTUnwrap(OverviewState.decode(try Data(contentsOf: Self.fixture("state.json", in: "sign-in-hold"))))
        XCTAssertEqual(HomeQueueModel.notices(state.snapshot, reference: reference, timeZone: utc), [
            "Agents can't sign in to Claude since 14:02 (Failed to authenticate. API Error: 403 Attention Required! | "
                + "Cloudflare): new runs wait until 14:24.",
        ])
        func limit(_ reason: String, phase: StateSnapshot.UsageLimit.Phase = .paused) -> StateSnapshot.UsageLimit {
            StateSnapshot.UsageLimit(phase: phase, reason: reason)
        }
        var snapshot = StateSnapshot()
        snapshot.usageLimits = [limit("model_api_sign_in_failed", phase: .canary), limit("usage_limit"), limit("model_api_unreachable")]
        XCTAssertTrue(HomeQueueModel.notices(snapshot, reference: reference).isEmpty)
    }

    // MARK: - The fixture

    func testTheFixtureServesTheTicketsPageItsSavedViewsComeFrom() throws {
        guard case let .changed(.loaded(data), _) = get(TicketsPayload.path) else { return XCTFail("no tickets read") }
        let tickets = try XCTUnwrap(TicketsPayload.decode(data))
        XCTAssertTrue(tickets.rows.contains { $0.identifier == "TP-1590" })
        guard case let .changed(.loaded(views), _) = get(TicketsPayload.viewsPath) else { return XCTFail("no views read") }
        XCTAssertEqual(try XCTUnwrap(TicketView.views(fromViews: views)).map(\.name), ["Hub", "In review"])
    }

    func testTheFixtureAnswersOnlyWhenItHoldsAGeneratedQueue() throws {
        let other = APIFixtures(directory: Self.directory("home"), requestLog: log)
        XCTAssertNil(other.homeQueue(URL(string: "http://symphony-fixtures.invalid/api/v1/home")!))
        XCTAssertNil(fixtures.homeQueue(URL(string: "http://symphony-fixtures.invalid/api/v1/state")!))
        XCTAssertNil(HomeQueueFixture(Data("[]".utf8)))
        XCTAssertNil(fixtures.lastSlotCount())
        XCTAssertEqual(HomeQueueFixture.filters(of: "nope", in: nil), [:])
        let generated = HomeQueueFixture.generate(HomeQueueFixture.Generated(count: 2))
        XCTAssertEqual(generated.map { $0["identifier"] as? String }, ["TP-1", "TP-2"])
    }
}
