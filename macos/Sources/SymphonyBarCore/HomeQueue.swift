import Combine
import Foundation

/// The queue's rows as Home has read them so far (TP-1609): the pages of `GET /api/v1/home` by index, for the saved view
/// in force, with how many rows the filter keeps. Home's list is virtual: it is as tall as `count` rows on a fixed
/// pitch, and only the rows on screen are drawn (`visibleRange`); the pages they fall in are read as they come on
/// screen (`pagesToRead`), so the list scrolls to its last row with every ticket in it.
public struct HomeQueuePager: Equatable {
    /// A row's pitch: its 34 pt and the 2 pt between two rows.
    public static let pitch: Double = 36
    /// The rows drawn beyond each edge of the screen, so a quick scroll finds them drawn.
    public static let overscan = 6

    public private(set) var pageSize: Int
    /// The saved view the rows are read with, nil for every ticket.
    public private(set) var view: String?
    /// The rows the filter keeps; the list's height.
    public private(set) var count: Int
    /// The rows of the whole queue.
    public private(set) var total: Int
    /// The rows read, by their index in the list.
    public private(set) var rows: [Int: HomeRead.Row]
    /// The pages read in the current generation, by their offset.
    public private(set) var fresh: Set<Int>
    /// The pages read before the queue last changed: drawn until a fresh read replaces them.
    public private(set) var stale: Set<Int>

    public init(view: String? = nil, pageSize: Int = HomeRead.pageSize) {
        self.view = view
        self.pageSize = max(pageSize, 1)
        count = 0
        total = 0
        rows = [:]
        fresh = []
        stale = []
    }

    /// The list's height.
    public var height: Double { Double(count) * Self.pitch }

    /// The row at `index`, nil while its page is not read.
    public func row(at index: Int) -> HomeRead.Row? { rows[index] }

    /// Puts `row` at `index`, nil to forget it: a drop shown before Symphony's next read.
    mutating func setRow(_ row: HomeRead.Row?, at index: Int) { rows[index] = row }

    /// The offset of the page that holds `index`.
    public func page(of index: Int) -> Int { (max(index, 0) / pageSize) * pageSize }

    /// Takes a page read with `view`; a page of another view, read before the pick changed, is dropped.
    public mutating func take(_ page: HomeRead.QueuePage, view: String?) {
        guard view == self.view else { return }
        count = page.count
        total = page.total
        let offset = page.offset
        // The page's rows replace what was there, and a shorter last page leaves nothing after it.
        for index in offset..<(offset + pageSize) { rows[index] = nil }
        for (index, row) in page.rows.enumerated() { rows[offset + index] = row }
        fresh.insert(offset)
        stale.remove(offset)
        // Rows past the end of a queue that shrank are gone.
        rows = rows.filter { $0.key < count }
    }

    /// The queue changed: every page read is stale and is read again once it is on screen; until then it is drawn as
    /// it was, so nothing blinks.
    public mutating func invalidate() {
        stale.formUnion(fresh)
        fresh = []
    }

    /// Drops the stale pages outside `range`: they would show rows that may have moved. Returns the offsets of the
    /// pages dropped, whose conditional-read tags the caller forgets, so their next read comes back in full.
    @discardableResult
    public mutating func dropStale(outside range: Range<Int>) -> [Int] {
        let keep = Set(pages(covering: range))
        let dropped = stale.subtracting(keep).sorted()
        for offset in dropped {
            for index in offset..<(offset + pageSize) { rows[index] = nil }
        }
        stale = stale.intersection(keep)
        return dropped
    }

    /// The offsets of the pages that hold the rows of `range`.
    public func pages(covering range: Range<Int>) -> [Int] {
        guard !range.isEmpty else { return [] }
        return Array(stride(from: page(of: range.lowerBound), through: page(of: range.upperBound - 1), by: pageSize))
    }

    /// The pages of `range` not read in this generation, first page first.
    public func pagesToRead(for range: Range<Int>) -> [Int] {
        pages(covering: range).filter { !fresh.contains($0) }
    }

    /// The viewport's height taken while the scroll view has not measured its own yet, as tall as the desktop window,
    /// so Home opened at the top draws its first screen of rows before any scroll (TP-1609).
    public static let assumedViewport: Double = 1440

    /// The rows on screen with `overscan` beyond each edge: the queue list starts `listTop` points below the top of
    /// the scroll view's content, which is scrolled `scrollTop` down in a viewport `viewport` tall. Before the
    /// viewport is measured (0), it is taken as `assumedViewport` tall.
    public static func visibleRange(scrollTop: Double, listTop: Double, viewport: Double, count: Int, overscan: Int = overscan) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let height = viewport > 0 ? viewport : assumedViewport
        let top = scrollTop - listTop
        let first = Int((top / pitch).rounded(.down)) - overscan
        let last = Int(((top + height) / pitch).rounded(.up)) + overscan
        let lower = min(max(first, 0), count)
        let upper = min(max(last, lower), count)
        return lower..<upper
    }

    /// The widest whole number among the rows of `range`, which sizes the number cell: "6.1" counts as 6, and a row
    /// not read yet as its place in the list, which its number is never below.
    public func widestNumber(in range: Range<Int>) -> Int {
        range.reduce(0) { widest, index in
            let whole = rows[index].flatMap { Int($0.number.split(separator: ".").first ?? "") } ?? (index + 1)
            return max(widest, whole)
        }
    }
}

/// Home's queue page (TP-1609): the slots and the paged queue Symphony serves, the saved view picked above the queue,
/// and the moves made from the page (the slot count, Start on a row, Stop on a card). Every read and move goes through
/// `fetch` and `send`, the window's client and control path in the app, stubs in the tests. A move reads Home again at
/// once, and so does each `event: queue` notice on the live channel, so a slot that fills or frees and a queue that
/// changes show without a reload.
@MainActor
public final class HomeQueueModel: ObservableObject {
    public typealias Fetch = @MainActor (_ path: String, _ tag: String?) async -> ConditionalResult
    public typealias Send = @MainActor (ControlAction) async -> ControlResult

    /// While the first read is on its way.
    public static let reading = "Reading Home…"
    /// A read that came back and doesn't decode.
    public static let unreadable = "Symphony's Home read doesn't read."
    /// The failure symbol of the Empty state Home shows while it has no read to show.
    public static let failureSymbol = "exclamationmark.triangle"
    public static let progressTitle = "In progress"
    public static let queueTitle = "Queue"
    /// The pick above the queue that keeps every ticket.
    public static let allTitle = "All tickets"

    /// The slots as Symphony last served them.
    @Published public private(set) var slots: [HomeRead.Slot] = []
    /// The slot count the control shows: the engine's, or the one just asked for until the engine answers.
    @Published public private(set) var slotCount = 0
    @Published public private(set) var pager = HomeQueuePager()
    /// Whether a read came back: until then the page shows that it reads.
    @Published public private(set) var loaded = false
    /// What the last read got when it got no Home to show, nil after one that did.
    @Published public private(set) var failure: EndpointResult?
    /// Why the last move from the page didn't go through, in Symphony's words; nil when it did.
    @Published public var notice: String?

    private let fetch: Fetch
    private let send: Send
    private var reads = ConditionalReads()
    /// The rows on screen, which a refresh reads again.
    public private(set) var visible: Range<Int> = 0..<0
    /// The paths on their way, so a page is asked for once.
    private var inFlight: Set<String> = []
    /// The count the person last asked for, until the engine's answer settles it.
    private var askedSlots: Int?
    /// Reads that arrived while one was on its way: the queue changed again, so it is read again after.
    private var refreshAgain = false

    public init(fetch: @escaping Fetch, send: @escaping Send, view: String? = nil) {
        self.fetch = fetch
        self.send = send
        pager = HomeQueuePager(view: view)
    }

    /// The saved view in force, nil for every ticket.
    public var view: String? { pager.view }

    /// One card per slot: the engine's entries from 1 to the count shown, a free number an empty slot, and any higher
    /// slot a ticket still holds after the count was lowered.
    public var cards: [HomeRead.Slot] {
        let byNumber = Dictionary(slots.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        let held = slots.filter { !$0.isEmpty }.map(\.number).max() ?? 0
        let last = max(slotCount, held)
        guard last > 0 else { return [] }
        return (1...last).map { byNumber[$0] ?? HomeRead.Slot(number: $0) }
    }

    /// The first read, or a read again of the slots and the rows on screen after the queue changed.
    public func refresh() async {
        guard !inFlight.contains(HomeRead.path(offset: 0, view: view)) else {
            refreshAgain = true
            return
        }
        pager.invalidate()
        var offsets = [0] + pager.pagesToRead(for: visible)
        offsets = offsets.reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
        for offset in offsets { await read(offset) }
        // A dropped page holds no rows, so a `304` to its next read would leave it blank: its tag goes with it.
        for offset in pager.dropStale(outside: visible) { reads.forget(HomeRead.path(offset: offset, view: view)) }
        if refreshAgain {
            refreshAgain = false
            await refresh()
        }
    }

    /// The rows on screen changed: reads the pages they fall in that are not read yet.
    public func show(_ range: Range<Int>) async {
        visible = range
        for offset in pager.pagesToRead(for: range) { await read(offset) }
    }

    /// A pick above the queue: the saved view `id`, or every ticket with nil. The list starts again from its top.
    public func pick(view id: String?) async {
        guard id != view else { return }
        pager = HomeQueuePager(view: id)
        reads = ConditionalReads()
        visible = 0..<0
        await read(0)
    }

    /// The slot count control: the cards follow at once, and the engine is told; a refusal puts the engine's count back.
    public func setSlots(_ count: Int) async {
        let count = min(max(count, DesignTokens.HomeQueue.slots.lowerBound), DesignTokens.HomeQueue.slots.upperBound)
        guard count != slotCount else { return }
        askedSlots = count
        slotCount = count
        notice = nil
        let result = await send(.slots(count))
        if case let .failed(message) = result {
            if askedSlots == count {
                askedSlots = nil
                slotCount = engineSlotCount
            }
            notice = message
            return
        }
        await refresh()
    }

    /// Start on a queue row, Stop on a slot card: the control call, then Home read again.
    public func perform(_ action: ControlAction) async {
        notice = nil
        if case let .failed(message) = await send(action) { notice = message }
        await refresh()
    }

    /// A queue row dropped into `gap` of the list (TP-1610): the list shows the ticket there at once with every number
    /// following, Symphony is asked to move it, and Home is read again. A refusal puts the list back as it was and says
    /// Symphony's reason. A drop at the row's own place, or a row that may not be dragged, sends nothing.
    public func move(_ row: HomeRead.Row, from: Int, to gap: Int) async {
        guard HomeQueueDrag.canDrag(row, view: view), let place = HomeQueueDrag.place(from: from, gap: gap, in: pager) else { return }
        let before = pager
        pager.move(row, from: from, to: gap)
        notice = nil
        if case let .failed(message) = await send(.queueMove(row.identifier, place: place)) {
            if pager.view == before.view { pager = before }
            notice = message
        }
        await refresh()
    }

    /// A queue row dropped on slot `slot` (TP-1610), the shortcut for Start: the ticket takes that slot, and the one
    /// that held it stops and becomes the queue's first.
    public func start(_ identifier: String, slot: Int) async {
        await perform(.start(identifier, note: nil, slot: slot))
    }

    /// The live channel's `event: queue`: the queue or a slot changed in the engine.
    public func queueChanged() async {
        await refresh()
    }

    /// The slot count the engine last served.
    private var engineSlotCount = 0

    /// Shows `read` as the first page, with no request: for an offscreen render.
    public func load(_ read: HomeRead) {
        apply(read, offset: 0, view: view)
    }

    private func read(_ offset: Int) async {
        let view = self.view
        let path = HomeRead.path(offset: offset, view: view)
        guard !inFlight.contains(path) else { return }
        inFlight.insert(path)
        let result = await fetch(path, reads.tag(for: path))
        inFlight.remove(path)
        guard view == self.view else { return }
        switch reads.take(result, for: path) {
        case .unchanged:
            // Nothing changed since the page's last read: what it shows is fresh.
            if pager.rows[offset] != nil || offset == 0 { pager.take(currentPage(offset), view: view) }
        case let .changed(data):
            guard let data, let read = HomeRead.decode(data) else {
                reads.forget(path)
                if !loaded || offset == 0 { failure = Self.failure(after: result) }
                return
            }
            apply(read, offset: offset, view: view)
        }
    }

    private func apply(_ read: HomeRead, offset: Int, view: String?) {
        if slots != read.slots { slots = read.slots }
        engineSlotCount = read.slotCount
        // While the engine hasn't taken the count asked for, the control keeps it.
        if askedSlots == nil || askedSlots == read.slotCount {
            askedSlots = nil
            if slotCount != read.slotCount { slotCount = read.slotCount }
        }
        var page = read.queue
        page.offset = offset
        pager.take(page, view: view)
        loaded = true
        if failure != nil { failure = nil }
    }

    /// The page at `offset` as the pager holds it, for a read Symphony answered with nothing new.
    private func currentPage(_ offset: Int) -> HomeRead.QueuePage {
        let rows = (offset..<(offset + pager.pageSize)).compactMap { pager.rows[$0] }
        return HomeRead.QueuePage(rows: rows, count: pager.count, total: pager.total, offset: offset, limit: pager.pageSize)
    }

    /// Home's lines for a provider that refuses the agents' sign-in, one per hold, from `snapshot` (TP-1515): the
    /// provider's message and since when. A hold its probe is checking (canary) is lifting, so it has no line.
    public static func notices(_ snapshot: StateSnapshot, reference: Date, timeZone: TimeZone = .current) -> [String] {
        snapshot.usageLimits.filter { $0.isSignInFailure && $0.phase != .canary }.map { limit in
            Overview.signInSentence(
                limit, what: StatusMenu.apiUnreachableName(limit), when: Overview.untilPhrase(limit, reference: reference, timeZone: timeZone),
                reference: reference, timeZone: timeZone
            )
        }
    }

    /// What `result`, a Home read that gave no Home to show, tells the page: `unsupported` for an older Symphony's 404,
    /// its failure for one that got no answer, and `unreadable` for a body that came and doesn't decode.
    public static func failure(after result: ConditionalResult) -> EndpointResult {
        if case let .changed(answer, _) = result {
            switch answer {
            case .loaded: break
            case .unsupported, .failed: return answer
            }
        }
        return .failed(unreadable)
    }
}
