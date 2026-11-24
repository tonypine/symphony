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
    /// reordering is off). A top-level ticket, an epic with its sub-tickets and a sub-ticket all move; a ticket that waits
    /// on another or on the person moves like any other.
    public static func canDrag(_ row: HomeRead.Row?, view: String?) -> Bool {
        view == nil && row != nil
    }

    /// Whether the row at the list's place `index` of `pager` may be dragged: as `canDrag(_:view:)`, and a queue row's
    /// place: an epic's done row is never dragged (TP-1645).
    public static func canDrag(_ row: HomeRead.Row?, at index: Int, in pager: HomeQueuePager) -> Bool {
        guard canDrag(row, view: pager.view), case .row? = pager.entry(at: index) else { return false }
        return true
    }

    /// The gap `row`, dragged from the list's place `from`, lands in for `gap` (TP-1645). A top-level row (an epic with
    /// its block) lands only between top-level rows: a gap inside an epic's block moves down past it. A sub-row lands only
    /// among its parent's sub-rows: the nearest gap before one of them, or after the last; a gap outside its parent's
    /// block takes the nearest of those.
    public static func snap(_ gap: Int, dragging row: HomeRead.Row, from: Int, in pager: HomeQueuePager) -> Int {
        let gap = min(max(gap, 0), pager.shownCount)
        guard let parent = row.parent else {
            var gap = gap
            while gap < pager.shownCount, !pager.isTopLevel(shown: gap) { gap += 1 }
            return gap
        }
        let gaps = siblingGaps(parent: parent, from: from, in: pager)
        return gaps.min { abs($0 - gap) < abs($1 - gap) } ?? from
    }

    /// The gaps a sub-row of `parent`, at the list's place `from`, may land in: before each of the parent's sub-rows, and
    /// after its block. Empty when the parent's row is not read.
    static func siblingGaps(parent: String, from: Int, in pager: HomeQueuePager) -> [Int] {
        var at = min(from, pager.shownCount) - 1
        while at >= 0, pager.row(shown: at)?.identifier != parent {
            if case let .row(read)? = pager.entry(at: at), pager.row(at: read) == nil { return [] }
            at -= 1
        }
        guard at >= 0, let epic = pager.row(shown: at) else { return [] }
        let block = pager.block(at: at, row: epic)
        let siblings = block.dropFirst().filter { pager.row(shown: $0)?.parent == parent }
        return siblings + [block.upperBound]
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

    /// Where `row`, at the list's place `from`, goes when dropped into `gap` of the list in `pager`, among the tickets of
    /// its scope (the top level, or its parent's sub-tickets): the queue's top or end for a top-level row, or before the
    /// row of its scope below the gap (after the one above it when the one below is not read). Nil for a drop at its own
    /// place or inside its own block, which sends nothing, or a gap with no row of its scope read on either side.
    public static func place(_ row: HomeRead.Row, from: Int, gap: Int, in pager: HomeQueuePager) -> QueuePlace? {
        let block = pager.block(at: from, row: row)
        guard gap < block.lowerBound || gap > block.upperBound else { return nil }
        if row.parent == nil {
            if gap <= 0 { return .top }
            if gap >= pager.shownCount { return .end }
        }
        if let below = pager.row(shown: gap), below.parent == row.parent { return .before(below.identifier) }
        var at = gap - 1
        while at >= 0 {
            switch pager.entry(at: at) {
            case .done?:
                break
            case let .row(read)?:
                guard let above = pager.row(at: read), above.identifier != row.parent else { return nil }
                if above.parent == row.parent { return .after(above.identifier) }
            case nil:
                return nil
            }
            at -= 1
        }
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
    /// strip: -1 up in the band below the strip (or the top) and above the scroll view, 1 down near the bottom, 0
    /// elsewhere. Over the strip's own band the list holds still: its lines are drop targets, and scrolling up would
    /// bring the cards back and take it away.
    public static func scrollDirection(y: Double, top: Double, viewport: Double) -> Int {
        guard viewport > 0 else { return 0 }
        if y > viewport - edge { return 1 }
        if y >= 0, y < top { return 0 }
        if y < top + edge { return -1 }
        return 0
    }
}
