import Foundation
import XCTest
@testable import SymphonyBarCore

/// Home's Recently done (TP-1644): decoded from the Home read, read with Home's first page on the range picked, more
/// entries read as the person scrolls, the range and the fold remembered, the section's empty rules, and a ticket that
/// finishes showing at the top on the engine's `event: queue`. Read from the `home-queue` fixture (ten tickets done in
/// the week, five of them today) and `home-queue-done-week` (none today), as the fixtures serve them to QA.
@MainActor
final class RecentlyDoneTests: XCTestCase {
    private var log: URL!
    private let utc = TimeZone(identifier: "UTC")!

    override func setUp() {
        log = FileManager.default.temporaryDirectory.appendingPathComponent("recently-done-\(UUID().uuidString).jsonl")
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

    private func get(_ path: String, fixture: String = "home-queue") -> ConditionalResult {
        let fixtures = APIFixtures(directory: Self.directory(fixture), requestLog: log)
        let url = LiveAPIClient.url(path, base: APIFixtures.baseURL)!
        let (data, response) = fixtures.answer(URLRequest(url: url))
        return .changed(EndpointResult(.answered(data, statusCode: response.statusCode)), etag: nil)
    }

    private func read(_ path: String, fixture: String = "home-queue") throws -> HomeRead {
        guard case let .changed(.loaded(data), _) = get(path, fixture: fixture) else { throw XCTSkip("no answer") }
        return try XCTUnwrap(HomeRead.decode(data))
    }

    private final class Reads {
        var paths: [String] = []
    }

    private func model(fixture: String = "home-queue", choices: KeyValueStore? = nil, reads: Reads = Reads()) -> HomeQueueModel {
        HomeQueueModel(
            fetch: { [unowned self] path, _ in
                reads.paths.append(path)
                return self.get(path, fixture: fixture)
            },
            send: { _ in .done }, choices: choices
        )
    }

    // MARK: - c1: decoded from the Home read

    func testTheReadGivesTheRangeBothCountsThePagingAndEachEntry() throws {
        XCTAssertEqual(
            HomeRead.path(offset: 0, done: HomeRead.DonePage(range: .week, offset: 50, limit: 50)),
            "api/v1/home?offset=0&limit=100&done_range=week&done_offset=50&done_limit=50"
        )
        let today = try XCTUnwrap(try read(HomeRead.path(offset: 0)).recentlyDone)
        XCTAssertEqual(today.range, .today)
        XCTAssertEqual(today.today, 5)
        XCTAssertEqual(today.week, 10)
        XCTAssertEqual(today.offset, 0)
        XCTAssertEqual(today.limit, 50)
        XCTAssertNil(today.nextOffset)
        XCTAssertEqual(today.entries.map(\.identifier), ["TP-1622", "MOT-104", "TP-1606", "TP-1616", "TP-1615"])

        let first = try XCTUnwrap(today.entries.first)
        XCTAssertEqual(first.issueID, "issue-tp-1622")
        XCTAssertEqual(first.title, "Engine: the queue's order is stored as one sort key per ticket")
        XCTAssertEqual(first.repoKey, "symphony")
        XCTAssertEqual(first.doneAt, ISO8601DateFormatter().date(from: "2026-10-07T14:00:00Z"))
        XCTAssertEqual(first.pullRequestNumber, 1053)
        XCTAssertEqual(first.epic, HomeRead.EpicRef(identifier: "TP-1597", title: "A real queue"))

        // The week in pages: six from the first, the rest from the next offset.
        let week = try XCTUnwrap(try read(HomeRead.path(offset: 0, done: .init(range: .week, limit: 6))).recentlyDone)
        XCTAssertEqual(week.range, .week)
        XCTAssertEqual(week.entries.count, 6)
        XCTAssertEqual(week.nextOffset, 6)
        let rest = try XCTUnwrap(try read(HomeRead.path(offset: 0, done: .init(range: .week, offset: 6, limit: 6))).recentlyDone)
        XCTAssertEqual(rest.offset, 6)
        XCTAssertEqual(rest.entries.map(\.identifier), ["TP-1601", "TP-983", "MOT-99", "TP-982"])
        XCTAssertNil(rest.nextOffset)
        // A ticket with no epic and no pull request.
        let lone = try XCTUnwrap(rest.entries.first { $0.identifier == "MOT-99" })
        XCTAssertNil(lone.epic)
        XCTAssertNil(lone.pullRequestNumber)
    }

    func testAReadWithoutTheBlockStillDecodes() throws {
        let plain = try XCTUnwrap(HomeRead.decode(Data(#"{"slots": {"total": 1, "entries": []}, "queue": {"rows": []}}"#.utf8)))
        XCTAssertNil(plain.recentlyDone)
        let broken = try XCTUnwrap(HomeRead.decode(Data(#"{"queue": {"rows": []}, "recently_done": {"entries": [{"title": "no identifier"}]}}"#.utf8)))
        XCTAssertNil(broken.recentlyDone, "a block that doesn't read leaves the rest of Home")
        let bare = try XCTUnwrap(HomeRead.decode(Data(#"{"recently_done": {"range": "nope", "entries": [{"identifier": "A", "epic": {}}]}}"#.utf8)))
        XCTAssertEqual(bare.recentlyDone, HomeRead.RecentlyDone(range: .today, entries: [HomeRead.DoneEntry(identifier: "A")]))
        XCTAssertEqual(HomeRead.DoneRange.allCases.map(\.title), ["Today", "Week"])
    }

    // MARK: - c2: the section's head and rows, most recent first

    func testTheModelReadsRecentlyDoneWithHomesFirstPage() async throws {
        let reads = Reads()
        let model = model(reads: reads)
        await model.refresh()
        XCTAssertEqual(reads.paths, ["api/v1/home?offset=0&limit=100&done_range=today&done_offset=0&done_limit=50"])
        let list = model.recentlyDone
        XCTAssertTrue(list.drawn)
        XCTAssertEqual(list.countText, "5")
        XCTAssertTrue(list.showsRows)
        XCTAssertEqual(list.entries.first?.identifier, "TP-1622", "most recent first")
        XCTAssertEqual(RecentlyDoneList.title, "Recently done")
        XCTAssertEqual(RecentlyDoneList.visibleRows, 6)
        XCTAssertEqual(DesignTokens.HomeQueue.recentHeight, 216)
    }

    func testPickingWeekReadsTheWeekWithItsCount() async throws {
        let reads = Reads()
        let model = model(reads: reads)
        await model.refresh()
        await model.pick(doneRange: .week)
        XCTAssertEqual(reads.paths.last, "api/v1/home?offset=0&limit=100&done_range=week&done_offset=0&done_limit=50")
        XCTAssertEqual(model.recentlyDone.range, .week)
        XCTAssertEqual(model.recentlyDone.countText, "10")
        XCTAssertEqual(model.recentlyDone.entries.count, 10)
        // The same range again reads nothing.
        let count = reads.paths.count
        await model.pick(doneRange: .week)
        XCTAssertEqual(reads.paths.count, count)
    }

    /// Back to a range read before: Symphony would answer `304` to its old tag, and the entries let go at the pick would
    /// never come back. The read goes without the tag.
    func testPickingBackARangeReadsItInFull() async throws {
        let today = try XCTUnwrap(get(HomeRead.path(offset: 0)).loadedData)
        var tags: [String?] = []
        let model = HomeQueueModel(fetch: { [unowned self] path, tag in
            tags.append(tag)
            if tag != nil { return .unchanged }
            return path.contains("done_range=week") ? self.get(path) : .changed(.loaded(today), etag: "today")
        }, send: { _ in .done })
        await model.refresh()
        await model.pick(doneRange: .week)
        await model.pick(doneRange: .today)
        XCTAssertEqual(tags, [nil, nil, nil])
        XCTAssertEqual(model.recentlyDone.entries.count, 5)
    }

    func testMoreEntriesAreReadAsThePersonScrolls() async throws {
        func answer(_ ids: ClosedRange<Int>, offset: Int, next: Int?) -> Data {
            let entries = ids.map { #"{"identifier": "T-\#($0)", "done_at": "2026-10-07T10:00:00Z"}"# }.joined(separator: ",")
            let nextText = next.map(String.init) ?? "null"
            return Data(#"""
            {"queue": {"rows": []}, "recently_done": {"range": "week", "counts": {"today": 0, "week": 4},
             "entries": [\#(entries)], "offset": \#(offset), "limit": 2, "next_offset": \#(nextText)}}
            """#.utf8)
        }
        var paths: [String] = []
        let store = MemoryKeyValueStore()
        RecentlyDoneChoices(range: .week).save(to: store)
        let model = HomeQueueModel(fetch: { path, _ in
            paths.append(path)
            if path.contains("done_offset=2") { return .changed(.loaded(answer(3...4, offset: 2, next: nil)), etag: nil) }
            return .changed(.loaded(answer(1...2, offset: 0, next: 2)), etag: nil)
        }, send: { _ in .done }, choices: store)
        await model.refresh()
        XCTAssertEqual(model.recentlyDone.entries.map(\.identifier), ["T-1", "T-2"])
        XCTAssertEqual(model.recentlyDone.nextPage, HomeRead.DonePage(range: .week, offset: 2, limit: RecentlyDoneList.pageSize))

        await model.showMoreDone()
        XCTAssertEqual(paths.last, "api/v1/home?offset=0&limit=1&done_range=week&done_offset=2&done_limit=50")
        XCTAssertEqual(model.recentlyDone.entries.map(\.identifier), ["T-1", "T-2", "T-3", "T-4"])
        XCTAssertNil(model.recentlyDone.nextPage)
        // Every entry is read: nothing more to ask for.
        let count = paths.count
        await model.showMoreDone()
        XCTAssertEqual(paths.count, count)
        // A read again of Home keeps what was scrolled to.
        XCTAssertEqual(model.recentlyDone.firstPage.limit, RecentlyDoneList.pageSize)
    }

    func testAPageThatDoesNotFollowOrDoesNotReadChangesNothing() {
        var list = RecentlyDoneList(range: .week)
        let entry = HomeRead.DoneEntry(identifier: "A")
        list.take(HomeRead.RecentlyDone(range: .week, today: 0, week: 3, entries: [entry], nextOffset: 1))
        // A later page past the entries read is dropped.
        list.take(HomeRead.RecentlyDone(range: .week, today: 0, week: 3, entries: [HomeRead.DoneEntry(identifier: "Z")], offset: 5))
        XCTAssertEqual(list.entries.map(\.identifier), ["A"])
        // A page of the other range, read before the pick changed, gives its counts and nothing else.
        list.take(HomeRead.RecentlyDone(range: .today, today: 1, week: 4, entries: [HomeRead.DoneEntry(identifier: "B")]))
        XCTAssertEqual(list.entries.map(\.identifier), ["A"])
        XCTAssertEqual(list.week, 4)
        XCTAssertEqual(list.today, 1)
        // The first page grows with the entries read, up to the most a read gives.
        XCTAssertEqual(RecentlyDoneList(range: .week).firstPage, HomeRead.DonePage(range: .week, offset: 0, limit: 50))
        var long = RecentlyDoneList(range: .week)
        long.take(HomeRead.RecentlyDone(range: .week, week: 900, entries: (0..<600).map { HomeRead.DoneEntry(identifier: "T-\($0)") }))
        XCTAssertEqual(long.firstPage.limit, RecentlyDoneList.maxLimit)
    }

    func testAShowMoreThatGetsNoAnswerKeepsTheEntries() async {
        let data = Data(#"{"recently_done": {"range": "today", "counts": {"today": 9, "week": 9}, "entries": [{"identifier": "A"}], "next_offset": 1}}"#.utf8)
        let model = HomeQueueModel(fetch: { path, _ in
            path.contains("done_offset=1") ? .changed(.failed("no"), etag: nil) : .changed(.loaded(data), etag: nil)
        }, send: { _ in .done })
        await model.refresh()
        await model.showMoreDone()
        XCTAssertEqual(model.recentlyDone.entries.map(\.identifier), ["A"])
        XCTAssertEqual(model.recentlyDone.nextOffset, 1)
    }

    // MARK: - c3: the range and the fold are remembered

    func testTheRangeAndTheFoldAreRememberedAcrossRelaunches() async {
        let store = MemoryKeyValueStore()
        let first = model(choices: store)
        XCTAssertEqual(first.recentlyDone.range, .today, "Today by default")
        XCTAssertTrue(first.recentlyDone.open, "open by default")
        await first.refresh()
        await first.pick(doneRange: .week)
        first.toggleRecentlyDone()
        XCTAssertFalse(first.recentlyDone.open)
        XCTAssertFalse(first.recentlyDone.showsRows, "folded, only the head shows")
        XCTAssertTrue(first.recentlyDone.drawn)
        XCTAssertEqual(store.values[RecentlyDoneChoices.Key.range] as? String, "week")
        XCTAssertEqual(store.values[RecentlyDoneChoices.Key.open] as? Bool, false)

        // The app quits and opens again: a new model on the same store.
        let reads = Reads()
        let again = model(choices: store, reads: reads)
        XCTAssertEqual(again.recentlyDone.range, .week)
        XCTAssertFalse(again.recentlyDone.open)
        await again.refresh()
        XCTAssertEqual(reads.paths, ["api/v1/home?offset=0&limit=100&done_range=week&done_offset=0&done_limit=50"])
        XCTAssertEqual(again.recentlyDone.countText, "10")
        again.toggleRecentlyDone()
        XCTAssertTrue(again.recentlyDone.showsRows)
        XCTAssertEqual(RecentlyDoneChoices.load(from: store), RecentlyDoneChoices(range: .week, open: true))

        // A value the store doesn't know falls back to the default.
        let odd = MemoryKeyValueStore()
        odd.values = [RecentlyDoneChoices.Key.range: "month", RecentlyDoneChoices.Key.open: "yes"]
        XCTAssertEqual(RecentlyDoneChoices.load(from: odd), RecentlyDoneChoices())
    }

    // MARK: - c4: the empty rules

    func testTodayEmptyKeepsTheHeadWithoutACountOrRows() async {
        let model = model(fixture: "home-queue-done-week")
        await model.refresh()
        let list = model.recentlyDone
        XCTAssertEqual(list.range, .today, "the range stays Today")
        XCTAssertTrue(list.drawn, "something finished this week")
        XCTAssertNil(list.countText, "no count at 0")
        XCTAssertFalse(list.showsRows)
        XCTAssertTrue(list.entries.isEmpty)
        await model.pick(doneRange: .week)
        XCTAssertEqual(model.recentlyDone.countText, "10")
        XCTAssertTrue(model.recentlyDone.showsRows)
    }

    func testNothingInTheWeekDrawsNoSection() async {
        // The drag fixture's read holds no ticket done.
        let model = model(fixture: "home-queue-drag")
        await model.refresh()
        XCTAssertTrue(model.loaded)
        XCTAssertFalse(model.recentlyDone.drawn)
        XCTAssertFalse(model.recentlyDone.showsRows)
        XCTAssertFalse(RecentlyDoneList().drawn, "nothing read yet draws nothing")
    }

    // MARK: - c5: a ticket that finishes shows at the top at once

    func testATicketThatFinishesShowsAtTheTopOnTheQueueNotice() async throws {
        func read(_ identifiers: [String], slot: String?) -> Data {
            let entries = identifiers.map { #"{"identifier": "\#($0)", "done_at": "2026-10-07T14:00:00Z"}"# }.joined(separator: ",")
            let ticket = slot.map { #"{"identifier": "\#($0)"}"# } ?? "null"
            return Data(#"""
            {"slots": {"total": 1, "entries": [{"slot": 1, "ticket": \#(ticket)}]}, "queue": {"rows": []},
             "recently_done": {"range": "today", "counts": {"today": \#(identifiers.count), "week": \#(identifiers.count)}, "entries": [\#(entries)]}}
            """#.utf8)
        }
        var finished = false
        let model = HomeQueueModel(fetch: { _, tag in
            // Symphony's read changes once the ticket finishes; before that it answers 304 to a tag.
            if finished { return .changed(.loaded(read(["TP-1619", "TP-1615"], slot: nil)), etag: "v2") }
            if tag != nil { return .unchanged }
            return .changed(.loaded(read(["TP-1615"], slot: "TP-1619")), etag: "v1")
        }, send: { _ in .done })
        await model.refresh()
        XCTAssertEqual(model.recentlyDone.entries.map(\.identifier), ["TP-1615"])
        XCTAssertEqual(model.cards.first?.ticket?.identifier, "TP-1619")

        // The engine finishes TP-1619 in its slot and sends `event: queue`.
        await model.queueChanged()
        XCTAssertEqual(model.recentlyDone.entries.map(\.identifier), ["TP-1615"], "nothing changed yet")
        finished = true
        await model.queueChanged()
        XCTAssertEqual(model.recentlyDone.entries.first?.identifier, "TP-1619", "at the top, with no reload")
        XCTAssertEqual(model.recentlyDone.countText, "2")
        XCTAssertTrue(model.cards.first?.isEmpty ?? false, "its slot is free")
    }

    // MARK: - The when cell

    func testWhenATicketFinishedReadsAsThePrototypeSaysIt() throws {
        let formatter = ISO8601DateFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2026-10-07T14:20:00Z")) // a Wednesday
        func when(_ text: String) -> String { DoneWhen.text(formatter.date(from: text), now: now, timeZone: utc) }
        XCTAssertEqual(when("2026-10-07T14:00:00Z"), "20 min ago")
        XCTAssertEqual(when("2026-10-07T14:19:50Z"), "1 min ago")
        XCTAssertEqual(when("2026-10-07T14:30:00Z"), "1 min ago", "a clock a little behind is never in the future")
        XCTAssertEqual(when("2026-10-07T11:15:00Z"), "3 h ago")
        XCTAssertEqual(when("2026-10-07T00:10:00Z"), "14 h ago")
        XCTAssertEqual(when("2026-10-06T16:40:00Z"), "yesterday")
        XCTAssertEqual(when("2026-10-03T09:45:00Z"), "Sat")
        XCTAssertEqual(DoneWhen.text(nil, now: now), "")
        // Midnight is the zone's: 23:30 the day before, in UTC, is yesterday; ten minutes past midnight is minutes.
        let justAfter = try XCTUnwrap(formatter.date(from: "2026-10-08T00:10:00Z"))
        XCTAssertEqual(DoneWhen.text(formatter.date(from: "2026-10-07T23:50:00Z"), now: justAfter, timeZone: utc), "20 min ago")
        XCTAssertEqual(DoneWhen.text(formatter.date(from: "2026-10-07T20:00:00Z"), now: justAfter, timeZone: utc), "yesterday")
    }
}

private extension ConditionalResult {
    /// The body of an answer that loaded.
    var loadedData: Data? {
        if case let .changed(.loaded(data), _) = self { return data }
        return nil
    }
}
