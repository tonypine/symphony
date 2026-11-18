import Foundation

/// The order of the catalog's Reorderable list (`components/reorderable-list`, TP-1531): a short list whose order the
/// Director sets, such as the first choice and fallbacks of a kind of run. One line at a time is picked up (by its
/// handle, with the pointer or Space), moved to any place, including above the first, and dropped, which reports the
/// new order once; Escape puts it back where it was. While a line is up the numbers keep the places they had when it
/// was picked up; they change at once on the drop. The list never removes its only line.
public struct ReorderModel<ID: Hashable>: Equatable {
    /// The lines in their order, the lifted one where it is now.
    public private(set) var order: [ID]
    /// The line picked up, if any.
    public private(set) var lifted: ID?
    /// The order when the line was picked up: Escape restores it, and the drop reports only a change from it.
    private var start: [ID] = []

    public init(_ order: [ID]) {
        self.order = order
    }

    /// The order the caller now has, taken while no line is up (a line added or removed by the page). While one is
    /// up the lift goes on and the caller's order waits for the drop.
    public mutating func reset(_ order: [ID]) {
        guard lifted == nil else { return }
        self.order = order
    }

    /// The line's place, from 1, in the order now.
    public func position(of id: ID) -> Int? {
        order.firstIndex(of: id).map { $0 + 1 }
    }

    /// The number drawn on the line: its place, the place it had at the pick-up while a line is up.
    public func number(of id: ID) -> Int? {
        let shown = lifted == nil ? order : start
        return shown.firstIndex(of: id).map { $0 + 1 }
    }

    /// Picks `id` up; false when it is no line of the list or a line is up already.
    @discardableResult
    public mutating func pickUp(_ id: ID) -> Bool {
        guard lifted == nil, order.contains(id) else { return false }
        lifted = id
        start = order
        return true
    }

    /// Moves the lifted line `offset` places (Up is -1, Down +1), stopping at either end; false when it doesn't move.
    @discardableResult
    public mutating func move(by offset: Int) -> Bool {
        guard let lifted, let from = order.firstIndex(of: lifted) else { return false }
        return move(to: from + offset)
    }

    /// Moves the lifted line to the place `index` (0 is above the first), held to the list; false when it doesn't move.
    @discardableResult
    public mutating func move(to index: Int) -> Bool {
        guard let lifted, let from = order.firstIndex(of: lifted) else { return false }
        let to = Self.clamp(index, count: order.count)
        guard to != from else { return false }
        order.remove(at: from)
        order.insert(lifted, at: to)
        return true
    }

    /// Drops the lifted line where it is: the new order when it differs from the order at the pick-up, nil when the
    /// line landed where it started or no line was up.
    public mutating func drop() -> [ID]? {
        guard lifted != nil else { return nil }
        lifted = nil
        let changed = order != start
        start = []
        return changed ? order : nil
    }

    /// Puts the lifted line back where it was at the pick-up (Escape).
    public mutating func cancel() {
        guard lifted != nil else { return }
        order = start
        lifted = nil
        start = []
    }

    /// Whether the list may remove `id`: never its only line, nor while a line is up.
    public func canRemove(_ id: ID) -> Bool {
        lifted == nil && order.count > 1 && order.contains(id)
    }

    /// Whether lines carry their remove button: none on the only line.
    public var showsRemove: Bool { order.count > 1 }

    /// `index` held to a list of `count` lines.
    static func clamp(_ index: Int, count: Int) -> Int {
        min(max(index, 0), max(count - 1, 0))
    }

    /// Where a line dragged from the place `from` lands: the places the pointer travelled (`translation` over the
    /// `pitch` of a line and its gap, rounded), held to the list.
    public static func target(from: Int, translation: Double, pitch: Double, count: Int) -> Int {
        guard pitch > 0 else { return clamp(from, count: count) }
        return clamp(from + Int((translation / pitch).rounded()), count: count)
    }

    /// How many places the line at `index` steps aside while a line dragged from `from` is over `to`: up one (-1)
    /// for a line between them below the place it left, down one (+1) for a line between them above it, none
    /// otherwise.
    public static func shift(_ index: Int, from: Int, to: Int) -> Int {
        if from < to, index > from, index <= to { return -1 }
        if to < from, index >= to, index < from { return 1 }
        return 0
    }
}

/// What the Reorderable list says: the handle's name, and what VoiceOver announces on the pick-up, each move, the
/// drop and Escape, with the line's place: "Line 2 of 3".
public enum ReorderSpeech {
    /// The handle's name: "Move line 2".
    public static func handle(_ number: Int) -> String { "Move line \(number)" }
    /// "Line 2 of 3".
    public static func place(_ position: Int, of count: Int) -> String { "Line \(position) of \(count)" }
    /// "Picked up. Line 2 of 3".
    public static func pickedUp(_ position: Int, of count: Int) -> String { "Picked up. \(place(position, of: count))" }
    /// "Line 1 of 3".
    public static func moved(_ position: Int, of count: Int) -> String { place(position, of: count) }
    /// "Dropped. Line 1 of 3".
    public static func dropped(_ position: Int, of count: Int) -> String { "Dropped. \(place(position, of: count))" }
    /// "Put back. Line 2 of 3".
    public static func putBack(_ position: Int, of count: Int) -> String { "Put back. \(place(position, of: count))" }
    /// What a handle's help says.
    public static let help = "Drag to change the order"
    /// A line's remove button, when the page names none.
    public static let remove = "Remove this line"
}
