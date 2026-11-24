import CoreGraphics
import Foundation

/// Home's drag and drop (TP-1610, `docs/design/prototypes/home-queue/` section Behaviour), as pure rules a view and a
/// test both read: a queue row is dragged by its handle onto a gap between two rows, which moves the ticket there, or
/// onto a slot (a slot card, or a line of the strip that stays on top), which starts the ticket on that slot. The list
/// is virtual, so the gap under the pointer is worked out from the pointer's height in the list and the row pitch, never
/// from the row views drawn.
public enum HomeQueueDrag {
    /// What a drop lands on.
    public enum Target: Equatable {
        /// The gap before the row at this index of the list; the list's count is the gap after its last row.
        case gap(Int)
        /// Slot `n`, from 1: a card or a strip line.
        case slot(Int)
    }

    /// The points above the list's top that still count as its first gap, as in the prototype.
    public static let reach: Double = 20
    /// The band at the scroll view's bottom, and below the strip at its top, where a drag scrolls the list.
    public static let edge: Double = 48
    /// The points the list scrolls by at each step of a drag at its edge.
    public static let scrollStep: Double = 14

    /// Whether `row` may be dragged: only with no saved view picked (a filtered row keeps its real number and
    /// reordering is off), and only a top-level ticket's row; a ticket that waits on another or on the person moves like
    /// any other.
    public static func canDrag(_ row: HomeRead.Row?, view: String?) -> Bool {
        guard view == nil, let row else { return false }
        return row.parent == nil
    }

    /// The gap nearest `y`, the pointer's height below the list's top, in a list of `count` rows: from 0, before the
    /// first row, to `count`, after the last.
    public static func gap(y: Double, count: Int) -> Int {
        let nearest = Int((y / HomeQueuePager.pitch).rounded())
        return min(max(nearest, 0), max(count, 0))
    }

    /// The point a drop line stands at for `gap`, below the list's top: in the 2 pt between the row above and the one
    /// below.
    public static func lineY(_ gap: Int) -> Double {
        Double(gap) * HomeQueuePager.pitch - DesignTokens.HomeQueue.dropLineHeight
    }

    /// The row's index after it is dropped from `from` into `gap`: a gap below it closes the hole it leaves.
    public static func destination(from: Int, gap: Int) -> Int { gap > from ? gap - 1 : gap }

    /// Where the ticket at `from` goes when dropped into `gap` of the list in `pager`: the queue's top or end, or before
    /// the row below the gap (after the row above it when the one below is not read). Nil for a drop at its own place,
    /// which sends nothing, or a gap with no row read on either side.
    public static func place(from: Int, gap: Int, in pager: HomeQueuePager) -> QueuePlace? {
        guard gap != from, gap != from + 1 else { return nil }
        if gap <= 0 { return .top }
        if gap >= pager.count { return .end }
        if let below = pager.row(at: gap) { return .before(below.identifier) }
        if let above = pager.row(at: gap - 1) { return .after(above.identifier) }
        return nil
    }

    /// What a drop at `point` lands on: a strip line first (the strip is pinned over the list, so its lines win over
    /// the rows beneath), then a slot card, then the list's nearest gap while the point is over the list or just above
    /// it. Each frame is in the same space as `point`; `list` is the list's frame, `count` its rows. Nil outside them.
    public static func target(
        at point: CGPoint, strip: [Int: CGRect], cards: [Int: CGRect], list: CGRect?, count: Int
    ) -> Target? {
        if let slot = strip.sorted(by: { $0.key < $1.key }).first(where: { $0.value.contains(point) })?.key { return .slot(slot) }
        if let slot = cards.sorted(by: { $0.key < $1.key }).first(where: { $0.value.contains(point) })?.key { return .slot(slot) }
        guard let list, point.x >= list.minX, point.x <= list.maxX, point.y >= list.minY - reach else { return nil }
        return .gap(gap(y: point.y - list.minY, count: count))
    }

    /// Which way a drag at `y` scrolls the list, in a scroll view `viewport` tall whose top `top` points are under the
    /// strip: -1 up near the top, 1 down near the bottom, 0 elsewhere.
    public static func scrollDirection(y: Double, top: Double, viewport: Double) -> Int {
        guard viewport > 0 else { return 0 }
        if y > viewport - edge { return 1 }
        if y < top + edge { return -1 }
        return 0
    }
}

extension HomeQueuePager {
    /// Moves `row`, at `from`, into `gap` (`HomeQueueDrag`) among the rows read: the rows between slide up or down a
    /// place, and every place keeps its number, so the numbers follow the rows at once. `row` is the dragged one as it
    /// was picked up, so a row whose page was dropped from memory during the drag still lands.
    public mutating func move(_ row: HomeRead.Row, from: Int, to gap: Int) {
        let to = HomeQueueDrag.destination(from: from, gap: gap)
        guard from != to, from >= 0, from < count, to >= 0, to < count else { return }
        let range = min(from, to)...max(from, to)
        var slice = range.map { $0 == from ? row : rows[$0] }
        let numbers = range.map { $0 == from ? row.number : rows[$0]?.number ?? String($0 + 1) }
        let moved = slice.remove(at: from - range.lowerBound)
        slice.insert(moved, at: to - range.lowerBound)
        for (offset, index) in range.enumerated() {
            if var placed = slice[offset] {
                placed.number = numbers[offset]
                setRow(placed, at: index)
            } else {
                setRow(nil, at: index)
            }
        }
    }
}
