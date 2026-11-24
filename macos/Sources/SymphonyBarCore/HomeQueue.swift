import Combine
import Foundation

/// What the list shows at one of its places (TP-1645): a queue row, by its index in the read, or one of an epic's done
/// sub-tickets at the top of its block, with the epic's identifier and its row's index in the read.
public enum HomeQueueEntry: Equatable {
    case row(Int)
    case done(epic: String, at: Int, HomeRead.DoneSubTicket)

    /// The index in the read of the row it is, or of the epic it is a done row of.
    public var readIndex: Int {
        switch self {
        case let .row(index): index
        case let .done(_, index, _): index
        }
    }
}

/// Which epics of the queue are closed, and which show their done sub-tickets (TP-1645): client state over the read,
/// kept while the app runs and never stored. An epic is open at first, its done sub-tickets hidden.
public struct HomeQueueFold: Equatable {
    public var closed: Set<String>
    public var showingDone: Set<String>

    public init(closed: Set<String> = [], showingDone: Set<String> = []) {
        self.closed = closed
        self.showingDone = showingDone
    }

    /// Whether the epic `identifier` shows its open sub-tickets.
    public func isOpen(_ identifier: String) -> Bool { !closed.contains(identifier) }
    /// Whether the epic `identifier` shows its done sub-tickets: only while it is open.
    public func showsDone(_ identifier: String) -> Bool { isOpen(identifier) && showingDone.contains(identifier) }

    /// The chevron: closes an open epic, opens a closed one.
    public mutating func toggle(_ identifier: String) {
        if closed.contains(identifier) { closed.remove(identifier) } else { closed.insert(identifier) }
    }

    /// The done count: shows the done sub-tickets, opening a closed epic, or hides them again.
    public mutating func toggleDone(_ identifier: String) {
        if !isOpen(identifier) {
            closed.remove(identifier)
            showingDone.insert(identifier)
        } else if showingDone.contains(identifier) {
            showingDone.remove(identifier)
        } else {
            showingDone.insert(identifier)
        }
    }
}

/// The queue's rows as Home has read them so far (TP-1609): the pages of `GET /api/v1/home` by index, for the saved view
/// in force, with how many rows the filter keeps. Home's list is virtual: it is as tall as the rows it shows on a fixed
/// pitch, and only the rows on screen are drawn (`visibleRange`); the pages they fall in are read as they come on
/// screen (`pagesToRead`), so the list scrolls to its last row with every ticket in it.
///
/// The read is flat: an epic's open sub-tickets are the rows after it (TP-1645). What the list shows (`entries`) is
/// the read under the fold: a closed epic's sub-rows left out, and an epic's done sub-tickets shown as done rows at the
/// top of its block. Indexes into `entries` are the list's places ("shown"); `rows` stay by their index in the read.
/// A row not read yet is shown in its place until its page is read.
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
    /// Which epics are closed and which show their done sub-tickets.
    public private(set) var fold: HomeQueueFold
    /// What the list shows, in order: the read under the fold.
    public private(set) var entries: [HomeQueueEntry]

    public init(view: String? = nil, pageSize: Int = HomeRead.pageSize, fold: HomeQueueFold = HomeQueueFold()) {
        self.view = view
        self.pageSize = max(pageSize, 1)
        self.fold = fold
        count = 0
        total = 0
        rows = [:]
        fresh = []
        stale = []
        entries = []
    }

    /// The places the list shows.
    public var shownCount: Int { entries.count }

    /// The list's height.
    public var height: Double { Double(shownCount) * Self.pitch }

    /// The row at `index` of the read, nil while its page is not read.
    public func row(at index: Int) -> HomeRead.Row? { rows[index] }

    /// What the list shows at `index`, nil outside it.
    public func entry(at index: Int) -> HomeQueueEntry? { entries.indices.contains(index) ? entries[index] : nil }

    /// The queue row the list shows at `index`: nil for a done row, a row not read yet or a place outside the list.
    public func row(shown index: Int) -> HomeRead.Row? {
        guard case let .row(read)? = entry(at: index) else { return nil }
        return rows[read]
    }

    /// Whether the list's place `index` is a top-level row's: a row with no parent, or one not read yet.
    func isTopLevel(shown index: Int) -> Bool {
        guard case let .row(read)? = entry(at: index) else { return false }
        return rows[read]?.parent == nil
    }

    /// The read's indexes the list's places `range` stand for: from the first's to the last's, the rows a closed epic
    /// keeps out between them included, and to the read's end when `range` ends the list.
    public func readRange(shown range: Range<Int>) -> Range<Int> {
        let range = range.clamped(to: 0..<entries.count)
        guard let first = range.first, let last = range.last else { return 0..<0 }
        let upper = range.upperBound == entries.count ? count : entries[last].readIndex + 1
        return entries[first].readIndex..<max(upper, entries[first].readIndex)
    }

    /// The index in the read the list's gap `gap` stands before: the next row's, or the read's end.
    func readGap(shown gap: Int) -> Int {
        var gap = max(gap, 0)
        while gap < entries.count {
            if case let .row(read) = entries[gap] { return read }
            gap += 1
        }
        return count
    }

    /// The list's places of the block that starts with `row` at the place `index`: the row, then the rows under it and
    /// the done rows of epics among them that follow it. A row not read yet ends the block.
    public func block(at index: Int, row: HomeRead.Row) -> Range<Int> {
        guard entries.indices.contains(index) else { return index..<index }
        var under: Set<String> = [row.identifier]
        var end = index + 1
        scan: while end < entries.count {
            switch entries[end] {
            case let .done(epic, _, _):
                guard under.contains(epic) else { break scan }
            case let .row(read):
                guard let next = rows[read], let parent = next.parent, under.contains(parent) else { break scan }
                under.insert(next.identifier)
            }
            end += 1
        }
        return index..<end
    }

    /// How many rows of the read the block of `row`, at `index` in the read, holds: the row and every row under it that
    /// follows, a closed epic's hidden sub-rows included.
    func readBlockSize(at index: Int, row: HomeRead.Row) -> Int {
        var under: Set<String> = [row.identifier]
        var end = index + 1
        while end < count, let next = rows[end], let parent = next.parent, under.contains(parent) {
            under.insert(next.identifier)
            end += 1
        }
        return end - index
    }

    /// The chevron of the epic `identifier`: closes it, or opens it.
    public mutating func toggle(_ identifier: String) {
        fold.toggle(identifier)
        relayout()
    }

    /// The done count of the epic `identifier`: shows its done sub-tickets at the top of its block (opening it when it
    /// is closed), or hides them.
    public mutating func toggleDone(_ identifier: String) {
        fold.toggleDone(identifier)
        relayout()
    }

    /// Lays the read out under the fold: a closed epic's rows under it are left out, and an open epic that shows its
    /// done sub-tickets has them right after its row.
    mutating func relayout() {
        var shown: [HomeQueueEntry] = []
        shown.reserveCapacity(count)
        var hidden: Set<String> = []
        for index in 0..<count {
            guard let row = rows[index] else {
                shown.append(.row(index))
                continue
            }
            if let parent = row.parent, hidden.contains(parent) {
                hidden.insert(row.identifier)
                continue
            }
            shown.append(.row(index))
            if !fold.isOpen(row.identifier) {
                hidden.insert(row.identifier)
            } else if fold.showsDone(row.identifier) {
                shown += row.doneSubTickets.map { .done(epic: row.identifier, at: index, $0) }
            }
        }
        if shown != entries { entries = shown }
    }

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
        relayout()
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
        if !dropped.isEmpty { relayout() }
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

    /// The widest whole number among the rows the list shows at `range`, which sizes the number cell: "6.1" counts as
    /// 6, a row not read yet as its place in the read, and a done row as nothing.
    public func widestNumber(in range: Range<Int>) -> Int {
        range.clamped(to: 0..<entries.count).reduce(0) { widest, index in
            guard case let .row(read) = entries[index] else { return widest }
            let whole = rows[read].flatMap { Int($0.number.split(separator: ".").first ?? "") } ?? (read + 1)
            return max(widest, whole)
        }
    }

    /// The most characters after the whole number among the rows the list shows at `range`: 2 for "6.1", 3 for "6.12",
    /// 0 while no sub-row is on screen. The number cell widens by them, so the part after the point hangs right.
    public func widestFraction(in range: Range<Int>) -> Int {
        range.clamped(to: 0..<entries.count).reduce(0) { widest, index in
            guard case let .row(read) = entries[index], let number = rows[read]?.number, let dot = number.firstIndex(of: ".") else {
                return widest
            }
            return max(widest, number[dot...].count)
        }
    }
}

extension HomeQueuePager {
    /// Moves `row`, at the list's place `from`, into the list's `gap` (`HomeQueueDrag.snap` keeps it in its scope) among
    /// the rows read: its block (an epic's sub-rows, the hidden ones of a closed epic too) moves with it, the rows between
    /// slide up or down, and the numbers follow at once. The numbers of its scope (the top-level ones, or its parent's
    /// sub-tickets') stay in their order and go to the rows of its scope in their new order; a row under one of them takes
    /// its new number before its own part ("7.2"). `row` is the dragged one as it was picked up, so a row whose page was
    /// dropped from memory during the drag still lands. A gap outside the list, or one in the row's own place, changes
    /// nothing.
    public mutating func move(_ row: HomeRead.Row, from: Int, to gap: Int) {
        guard gap >= 0, gap <= shownCount, case let .row(readFrom)? = entry(at: from) else { return }
        let gap = HomeQueueDrag.snap(gap, dragging: row, from: from, in: self)
        let block = self.block(at: from, row: row)
        guard gap < block.lowerBound || gap > block.upperBound else { return }
        let size = readBlockSize(at: readFrom, row: row)
        let readGap = self.readGap(shown: gap)
        let range = min(readFrom, readGap)..<max(readFrom + size, readGap)
        var slice = range.map { $0 == readFrom ? row : rows[$0] }
        var numbers = slice.compactMap { $0 }.filter { $0.parent == row.parent }.map(\.number).makeIterator()
        let taken = (readFrom - range.lowerBound)..<(readFrom - range.lowerBound + size)
        let moved = Array(slice[taken])
        slice.removeSubrange(taken)
        slice.insert(contentsOf: moved, at: (readGap > readFrom ? readGap - size : readGap) - range.lowerBound)
        var renumbered: [String: String] = [:]
        for (offset, index) in range.enumerated() {
            guard var placed = slice[offset] else {
                rows[index] = nil
                continue
            }
            if placed.parent == row.parent, let number = numbers.next() {
                placed.number = number
                renumbered[placed.identifier] = number
            } else if let parent = placed.parent, let prefix = renumbered[parent], let dot = placed.number.lastIndex(of: ".") {
                placed.number = prefix + placed.number[dot...]
                renumbered[placed.identifier] = placed.number
            }
            rows[index] = placed
        }
        relayout()
    }
}

/// Home's queue page (TP-1609): the slots and the paged queue Symphony serves, the saved view picked above the queue,
/// and the moves made from the page (the slot count, Start on a row, Stop on a card). Every read and move goes through
/// `fetch` and `send`, the window's client and control path in the app, stubs in the tests. A move reads Home again at
/// once, and so does each `event: queue` notice on the live channel, so a slot that fills or frees and a queue that
/// changes show without a reload. The first page's read also gives Recently done (TP-1644), so a ticket that finishes
/// shows at its top on the same notice.
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
    /// Recently done (TP-1644): the range and the fold picked, both ranges' counts and the entries read.
    @Published public private(set) var recentlyDone: RecentlyDoneList

    private let fetch: Fetch
    private let send: Send
    private var reads = ConditionalReads()
    /// The list's places on screen.
    public private(set) var shown: Range<Int> = 0..<0
    /// The rows of the read on screen, which a refresh reads again.
    public var visible: Range<Int> { pager.readRange(shown: shown) }
    /// The paths on their way, so a page is asked for once.
    private var inFlight: Set<String> = []
    /// The count the person last asked for, until the engine's answer settles it.
    private var askedSlots: Int?
    /// Reads that arrived while one was on its way: the queue changed again, so it is read again after.
    private var refreshAgain = false

    /// Where Recently done's range and fold are remembered, nil to remember them only while the model lives.
    private let choices: KeyValueStore?

    public init(fetch: @escaping Fetch, send: @escaping Send, view: String? = nil, choices: KeyValueStore? = nil) {
        self.fetch = fetch
        self.send = send
        self.choices = choices
        pager = HomeQueuePager(view: view)
        recentlyDone = RecentlyDoneList(choices.map(RecentlyDoneChoices.load(from:)) ?? RecentlyDoneChoices())
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
        guard !inFlight.contains(path(0)) else {
            refreshAgain = true
            return
        }
        pager.invalidate()
        var offsets = [0] + pager.pagesToRead(for: visible)
        offsets = offsets.reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
        for offset in offsets { await read(offset) }
        // A dropped page holds no rows, so a `304` to its next read would leave it blank: its tag goes with it.
        for offset in pager.dropStale(outside: visible) { reads.forget(path(offset)) }
        if refreshAgain {
            refreshAgain = false
            await refresh()
        }
    }

    /// The list's places on screen changed: reads the pages they fall in that are not read yet.
    public func show(_ range: Range<Int>) async {
        shown = range
        for offset in pager.pagesToRead(for: visible) { await read(offset) }
    }

    /// A pick above the queue: the saved view `id`, or every ticket with nil. The list starts again from its top, and
    /// each epic stays open or closed as it was.
    public func pick(view id: String?) async {
        guard id != view else { return }
        pager = HomeQueuePager(view: id, fold: pager.fold)
        reads = ConditionalReads()
        shown = 0..<0
        await read(0)
    }

    /// A click on an epic's row (TP-1645): shows or hides its open sub-tickets. The rows it brings on screen are read.
    public func toggle(epic identifier: String) async {
        pager.toggle(identifier)
        await show(shown)
    }

    /// An epic's done count: shows its done sub-tickets at the top of its block, opening it when it is closed, or hides
    /// them.
    public func toggleDone(epic identifier: String) async {
        pager.toggleDone(identifier)
        await show(shown)
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

    /// Start on a queue row, Stop on a slot card: the control call, then Home read again. A refusal says Symphony's reason
    /// in its own words (TP-1645).
    public func perform(_ action: ControlAction) async {
        notice = nil
        if case let .failed(message) = await send(action) { notice = ControlAPI.reason(message, for: action) }
        await refresh()
    }

    /// A queue row, at the list's place `from`, dropped into `gap` of the list (TP-1610): the list shows the ticket there
    /// at once with every number following, Symphony is asked to move it, and Home is read again. An epic's row moves
    /// with its sub-tickets and lands only between top-level rows; a sub-row lands only among its parent's sub-rows
    /// (TP-1645, `HomeQueueDrag.snap`). A refusal puts the list back as it was and says Symphony's reason. A drop at the
    /// row's own place, or a row that may not be dragged, sends nothing.
    public func move(_ row: HomeRead.Row, from: Int, to gap: Int) async {
        guard HomeQueueDrag.canDrag(row, at: from, in: pager) else { return }
        let gap = HomeQueueDrag.snap(gap, dragging: row, from: from, in: pager)
        guard let place = HomeQueueDrag.place(row, from: from, gap: gap, in: pager) else { return }
        let before = pager
        pager.move(row, from: from, to: gap)
        notice = nil
        let action = ControlAction.queueMove(row.identifier, place: place)
        if case let .failed(message) = await send(action) {
            if pager.view == before.view { pager = before }
            notice = ControlAPI.reason(message, for: action)
        }
        await refresh()
    }

    /// A queue row dropped on slot `slot` (TP-1610), the shortcut for Start: the ticket takes that slot, and the one
    /// that held it stops and becomes the queue's first.
    public func start(_ identifier: String, slot: Int) async {
        await perform(.start(identifier, note: nil, slot: slot))
    }

    /// Recently done's range control: the range's entries are read at once, with Home's first page, and the pick is
    /// remembered.
    public func pick(doneRange range: HomeRead.DoneRange) async {
        guard range != recentlyDone.range else { return }
        recentlyDone.pick(range)
        remember()
        // The range's entries were let go: a `304` to a read made before would leave the section without them.
        reads.forget(path(0))
        await read(0)
    }

    /// Recently done's head: folds the section to its head, or opens it, and remembers it.
    public func toggleRecentlyDone() {
        recentlyDone.open.toggle()
        remember()
    }

    /// Keeps Recently done's range and fold where the app remembers them.
    private func remember() {
        if let choices { recentlyDone.choices.save(to: choices) }
    }

    /// The person scrolled to the end of the entries read: the next page of the range is read, if there is one.
    public func showMoreDone() async {
        guard let page = recentlyDone.nextPage else { return }
        // Only the done entries are wanted: one queue row comes with them.
        let path = HomeRead.path(offset: 0, limit: 1, done: page)
        guard !inFlight.contains(path) else { return }
        inFlight.insert(path)
        let result = await fetch(path, nil)
        inFlight.remove(path)
        guard case let .changed(.loaded(data), _) = result, let done = HomeRead.decode(data)?.recentlyDone else { return }
        recentlyDone.take(done)
    }

    /// The live channel's `event: queue`: the queue or a slot changed in the engine, or a ticket finished.
    public func queueChanged() async {
        await refresh()
    }

    /// The slot count the engine last served.
    private var engineSlotCount = 0

    /// Shows `read` as the first page under `fold`, with no request: for an offscreen render.
    public func load(_ read: HomeRead, fold: HomeQueueFold = HomeQueueFold()) {
        if fold != pager.fold { pager = HomeQueuePager(view: view, pageSize: pager.pageSize, fold: fold) }
        apply(read, offset: 0, view: view)
    }

    /// The read of the page at `offset`: the first page also asks for Recently done's first entries of the range picked.
    private func path(_ offset: Int) -> String {
        HomeRead.path(offset: offset, view: view, done: offset == 0 ? recentlyDone.firstPage : nil)
    }

    private func read(_ offset: Int) async {
        let view = self.view
        let path = self.path(offset)
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
        if offset == 0, let done = read.recentlyDone {
            var next = recentlyDone
            next.take(done)
            if next != recentlyDone { recentlyDone = next }
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
