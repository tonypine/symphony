import CoreGraphics
import Foundation

/// What the app's open menu and pop-up list do with the keys and where they open (TP-1508, the catalog's `.menu`):
/// Up and Down move between the items a click could pick and wrap round, Home and End go to the ends, typed letters
/// jump to the first item they start, and the menu opens under its control, moved in to stay on the screen.
public enum MenuNavigation {
    /// One line of a menu as the keys and the layout see it.
    public struct Line: Equatable {
        public var title: String
        public var enabled: Bool
        public var separator: Bool

        public init(title: String, enabled: Bool = true) {
            self.title = title
            self.enabled = enabled
            separator = false
        }

        private init(separator: Bool) {
            title = ""
            enabled = false
            self.separator = separator
        }

        public static let separator = Line(separator: true)

        /// Whether the keys can land on it: an item that is not off.
        public var selectable: Bool { enabled && !separator }
    }

    // MARK: - Keys

    /// The selectable line `step` lines of them away from `current`, wrapping round as a menu does; from none, the
    /// first going down and the last going up. Nil when no line can be picked.
    public static func move(from current: Int?, step: Int, in lines: [Line]) -> Int? {
        let selectable = lines.indices.filter { lines[$0].selectable }
        guard !selectable.isEmpty else { return nil }
        guard let current, let at = selectable.firstIndex(of: current) else {
            return step >= 0 ? selectable.first : selectable.last
        }
        let count = selectable.count
        return selectable[((at + step) % count + count) % count]
    }

    /// The first selectable line (Home), or the last (End).
    public static func end(_ last: Bool, in lines: [Line]) -> Int? {
        let selectable = lines.indices.filter { lines[$0].selectable }
        return last ? selectable.last : selectable.first
    }

    /// Typed letters, gathered while they come within `DesignTokens.Menu.typeAheadTimeout` of each other.
    public struct TypeAhead: Equatable {
        public private(set) var query = ""
        private var last = -Double.infinity

        public init() {}

        /// Adds `text` typed at `time` (in seconds) and returns the line it lands on: the first selectable line whose
        /// title starts with what was typed, ignoring case and accents. The same letter typed again moves on from
        /// `current` to the next line it starts. Nil when no line starts with it.
        public mutating func type(_ text: String, at time: Double, current: Int?, in lines: [Line]) -> Int? {
            guard !text.isEmpty else { return nil }
            if time - last > DesignTokens.Menu.typeAheadTimeout { query = "" }
            last = time
            let repeated = query.count == 1 && Self.fold(text) == Self.fold(query)
            if !repeated { query += text }
            let wanted = Self.fold(query)
            guard !lines.isEmpty else { return nil }
            let start = repeated ? (current.map { $0 + 1 } ?? 0) : 0
            for offset in 0..<lines.count {
                let index = (start + offset) % lines.count
                if lines[index].selectable, Self.fold(lines[index].title).hasPrefix(wanted) { return index }
            }
            return nil
        }

        static func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
    }

    // MARK: - Layout

    /// The menu's height: its padding, an item's height per item and a separator's span per separator.
    public static func height(of lines: [Line]) -> Double {
        let menu = DesignTokens.Menu.self
        return 2 * menu.padding + lines.reduce(0) { $0 + ($1.separator ? menu.separatorSpan : menu.itemHeight) }
    }

    /// Each line's top, from the menu's top edge.
    public static func tops(of lines: [Line]) -> [Double] {
        var top = DesignTokens.Menu.padding
        return lines.map { line in
            defer { top += line.separator ? DesignTokens.Menu.separatorSpan : DesignTokens.Menu.itemHeight }
            return top
        }
    }

    /// Which edge of the control the menu lines up with.
    public enum Alignment: Equatable {
        case leading, trailing
    }

    /// Where a menu of `size` opens for a control at `anchor`, both in screen coordinates (y up), inside `visible`
    /// (the screen's visible frame): `gap` under the control with its leading (or trailing) edge on the control's,
    /// above the control when there is no room under it, and moved in to stay `margin` inside the screen's edges.
    public static func frame(
        size: CGSize, anchor: CGRect, visible: CGRect, alignment: Alignment = .leading,
        gap: Double = DesignTokens.Menu.gap, margin: Double = DesignTokens.Menu.edgeMargin
    ) -> CGRect {
        var x = alignment == .leading ? anchor.minX : anchor.maxX - size.width
        var y = anchor.minY - gap - size.height
        if y < visible.minY + margin, anchor.maxY + gap + size.height <= visible.maxY - margin {
            y = anchor.maxY + gap
        }
        x = clamp(x, low: visible.minX + margin, high: visible.maxX - margin - size.width)
        y = clamp(y, low: visible.minY + margin, high: visible.maxY - margin - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Where a submenu of `size` opens beside its item at `item` (screen coordinates): its first item level with the
    /// item, on the trailing side, or the leading side when there is no room there, kept on the screen.
    public static func submenuFrame(
        size: CGSize, item: CGRect, visible: CGRect, margin: Double = DesignTokens.Menu.edgeMargin
    ) -> CGRect {
        let inset = DesignTokens.Menu.padding
        var x = item.maxX + inset
        if x + size.width > visible.maxX - margin { x = item.minX - inset - size.width }
        var y = item.maxY + inset - size.height
        x = clamp(x, low: visible.minX + margin, high: visible.maxX - margin - size.width)
        y = clamp(y, low: visible.minY + margin, high: visible.maxY - margin - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// `value` inside `low`…`high`; `low` when the range is empty, so the menu's start stays on the screen.
    static func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        max(low, min(value, high))
    }
}
