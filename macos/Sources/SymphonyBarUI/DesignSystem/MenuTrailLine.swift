import AppKit
import SymphonyBarCore

/// The catalog's menu line with a trailing text (`.menu-item` with a `.menu-trail`, TP-1536) for an `NSMenu`: an
/// image, the title in the primary colour and the trailing text in the secondary colour, pinned to the menu's right
/// edge whatever the menu's width, where the key equivalents end. The menu stretches the view to its width; the
/// hovered line is the accent with white words, and a click or VoiceOver's press chooses it.
public final class MenuTrailLineView: NSView {
    /// Where each part sits in a line's bounds.
    public struct Layout: Equatable {
        public var image: NSRect
        public var title: NSRect
        public var trail: NSRect
        public var highlight: NSRect
    }

    public let title: String
    public let trail: String
    public let image: NSImage?
    /// What the line does when it is chosen: by a click, Return on the highlighted line, or VoiceOver's press.
    public var choose: () -> Void
    private let label: String

    /// The line's least width: the menu grows to it, and stretches it wider to its own width.
    public static func naturalWidth(title: String, trail: String, image: NSImage?) -> CGFloat {
        let edge = DesignTokens.Menu.padding + DesignTokens.Menu.itemInset
        let lead = image.map { $0.size.width + DesignTokens.Menu.itemGap } ?? 0
        return ceil(2 * edge + lead + width(title) + DesignTokens.Menu.hintGap + width(trail))
    }

    /// The parts' places in `bounds`: the image and the title from the leading inset, the trailing text ending at the
    /// trailing inset, each centred on the line.
    public static func layout(in bounds: NSRect, title: String, trail: String, image: NSImage?) -> Layout {
        let edge = DesignTokens.Menu.padding + DesignTokens.Menu.itemInset
        let font = Self.font
        let textHeight = ceil(font.ascender - font.descender + font.leading)
        let textY = bounds.minY + floor((bounds.height - textHeight) / 2)
        var x = bounds.minX + edge
        var imageRect = NSRect(x: x, y: bounds.midY, width: 0, height: 0)
        if let size = image?.size {
            imageRect = NSRect(x: x, y: bounds.minY + floor((bounds.height - size.height) / 2), width: size.width, height: size.height)
            x += size.width + DesignTokens.Menu.itemGap
        }
        let trailWidth = width(trail)
        let trailRect = NSRect(x: bounds.maxX - edge - trailWidth, y: textY, width: trailWidth, height: textHeight)
        let titleWidth = max(0, min(width(title), trailRect.minX - DesignTokens.Menu.hintGap - x))
        let titleRect = NSRect(x: x, y: textY, width: titleWidth, height: textHeight)
        let highlight = bounds.insetBy(dx: DesignTokens.Menu.padding, dy: 0)
        return Layout(image: imageRect, title: titleRect, trail: trailRect, highlight: highlight)
    }

    /// The line's height: an ordinary menu item's, measured from a menu of one and of two items, or the catalog's
    /// item height when the menu can't be measured.
    public static let rowHeight: CGFloat = {
        func menuHeight(_ count: Int) -> CGFloat {
            let menu = NSMenu()
            for _ in 0..<count {
                menu.addItem(NSMenuItem(title: "Ag", action: nil, keyEquivalent: ""))
            }
            return menu.size.height
        }
        let measured = menuHeight(2) - menuHeight(1)
        return measured > 0 ? measured : DesignTokens.Menu.itemHeight
    }()

    public init(title: String, trail: String, image: NSImage?, accessibilityLabel: String, choose: @escaping () -> Void) {
        self.title = title
        self.trail = trail
        self.image = image
        self.label = accessibilityLabel
        self.choose = choose
        let width = Self.naturalWidth(title: title, trail: trail, image: image)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.rowHeight))
        autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// Whether the menu highlights the line: the pointer is on it or the keyboard moved to it.
    public var isHighlighted: Bool { enclosingMenuItem?.isHighlighted == true }

    override public func draw(_: NSRect) {
        let highlighted = isHighlighted
        let layout = Self.layout(in: bounds, title: title, trail: trail, image: image)
        if highlighted {
            DesignTokens.ColorToken.accent.nsColor.setFill()
            let radius = DesignTokens.Menu.itemRadius
            NSBezierPath(roundedRect: layout.highlight, xRadius: radius, yRadius: radius).fill()
        }
        image?.draw(in: layout.image)
        let words = highlighted ? DesignTokens.TextColor.onAccent : DesignTokens.TextColor.primary
        let quiet = highlighted ? DesignTokens.TextColor.onAccent : DesignTokens.TextColor.secondary
        Self.text(title, colour: words.nsColor).draw(with: layout.title, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        Self.text(trail, colour: quiet.nsColor).draw(with: layout.trail, options: [.usesLineFragmentOrigin])
    }

    override public func mouseUp(with _: NSEvent) {
        enclosingMenuItem?.menu?.cancelTracking()
        choose()
    }

    override public func isAccessibilityElement() -> Bool { true }
    override public func accessibilityRole() -> NSAccessibility.Role? { .menuItem }
    override public func accessibilityLabel() -> String? { label }

    override public func accessibilityPerformPress() -> Bool {
        choose()
        return true
    }

    // MARK: - Text

    private static var font: NSFont { NSFont.menuFont(ofSize: 0) }

    private static func width(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func text(_ string: String, colour: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: colour, .paragraphStyle: paragraph])
    }
}
