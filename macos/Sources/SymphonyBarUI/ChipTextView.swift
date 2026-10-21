import AppKit
import SymphonyBarCore

/// One paragraph a `ChipTextView` shows: the text, a bold lead before it ("If you don't answer:"), and the mentions
/// found in it by the item's `references`.
public struct ChipTextContent: Equatable {
    public var lead: String?
    public var text: String
    /// The lead, a space and the text: what a selection copies from.
    public var source: String
    /// The mentions, with ranges in `source`.
    public var mentions: [Mention]

    public init(_ text: String, references: [String: Reference], lead: String? = nil) {
        let prefix = lead.map { "\($0) " } ?? ""
        let offset = (prefix as NSString).length
        self.lead = lead
        self.text = text
        source = prefix + text
        mentions = Mentions.find(in: text, references: references).map { mention in
            var mention = mention
            mention.range.location += offset
            return mention
        }
    }

    /// The content of a text whose item resolved its mentions; nil when it has no `references` (an older Symphony, or
    /// a ticket page whose ticket isn't in the Inbox), so the text is drawn as plain text, as it was before chips.
    public static func chips(_ text: String, references: [String: Reference], lead: String? = nil) -> ChipTextContent? {
        references.isEmpty ? nil : ChipTextContent(text, references: references, lead: lead)
    }
}

/// How a `ChipTextView` draws its text.
public struct ChipTextStyle: Equatable {
    public var font: NSFont
    public var color: NSColor
    /// False in a control (an option card): the text can't be selected, and a click outside a chip goes through
    /// to the control.
    public var selectable: Bool

    public init(font: NSFont, color: NSColor = .labelColor, selectable: Bool = true) {
        self.font = font
        self.color = color
        self.selectable = selectable
    }
}

/// Shows a chip's popover (N2, N3) next to it.
public protocol ChipPopoverPresenting: AnyObject {
    /// Opens the popover for `mention`, anchored to `rect` in `view`. One the pointer opened (`hover`) closes when
    /// the pointer leaves the chip and the popover; one the keyboard or VoiceOver opened closes like a menu.
    func show(_ mention: Mention, relativeTo rect: CGRect, of view: NSView, hover: Bool)
    /// The pointer left the chip: a hover popover closes unless the pointer is on it.
    func pointerLeftChip()
    func close()
}

/// A paragraph in native Mac text (TextKit 2) with each ticket and pull request mention drawn as a chip (N1). The
/// text selects, copies and reads like any text; a chip opens its popover after the pointer rests on it, opens its
/// ticket or pull request on a click, and is a link for VoiceOver. Read-only.
///
/// Each chip keeps its characters, with the N1 look drawn behind them by the paragraph's layout fragment. Inside a
/// chip spaces don't break, and the character before it carries the room for the tint (and the pull request
/// symbol), so a chip never splits across lines and its tint never covers the text around it.
open class ChipTextView: NSTextView, NSTextLayoutManagerDelegate {
    public private(set) var content: ChipTextContent
    public private(set) var style: ChipTextStyle
    /// A click on a chip, Return on a focused one, or VoiceOver's press.
    public var openMention: (Mention) -> Void = { _ in }
    /// ⌘-click or ⌘Return: a ticket's page straight away, past the peek. Nil opens the chip as a click does.
    public var openMentionDirectly: ((Mention) -> Void)?
    /// Copy Link, Open in Linear and Open on GitHub in a chip's menu.
    public var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    public var popover: ChipPopoverPresenting?
    public var hoverDelay: TimeInterval = DesignTokens.Chip.hoverDelay
    /// Scrolls the review a distance down, in points, through its SwiftUI scroll view's own position: that scroll view
    /// keeps its offset itself, and its next layout puts back a scroll made from AppKit alone. Nil outside one.
    public var scrollReview: ((CGFloat) -> Void)?

    /// False while a sheet covers the window: the view draws nothing and opens no popover on hover, and SwiftUI draws
    /// the paragraph's image under it, which dims with the window. The view stays in the window, so assistive apps read
    /// it as they do without a sheet.
    public var drawsText = true {
        didSet {
            guard drawsText != oldValue else { return }
            alphaValue = drawsText ? 1 : 0
            if !drawsText { pointerMoved(to: nil) }
        }
    }

    /// The chip under the pointer.
    public private(set) var hoveredChip: Int? {
        didSet { if hoveredChip != oldValue { redrawChips() } }
    }

    /// The chip the keyboard is on, after Tab entered the paragraph. A chip that takes the keyboard scrolls into view.
    public private(set) var focusedChip: Int? {
        didSet {
            guard focusedChip != oldValue else { return }
            redrawChips()
            if let focusedChip { scrollChipToVisible(focusedChip) }
        }
    }

    private var pressedChip: Int?
    private var hoverWork: DispatchWorkItem?
    private var hoverArea: NSTrackingArea?
    private lazy var chipElements: [ChipAccessibilityElement] = makeChipElements()

    public static let chipAttribute = NSAttributedString.Key("SymphonyChip")

    public init(content: ChipTextContent, style: ChipTextStyle) {
        self.content = content
        self.style = style
        let storage = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.textContainer = container
        storage.addTextLayoutManager(manager)
        storage.primaryTextLayoutManager = manager
        super.init(frame: .zero, textContainer: container)
        manager.delegate = self
        isEditable = false
        isSelectable = style.selectable
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        apply()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows new text or a new style; the same ones change nothing.
    public func update(content: ChipTextContent, style: ChipTextStyle) {
        guard content != self.content || style != self.style else { return }
        let mentionsChanged = content.mentions != self.content.mentions
        self.content = content
        self.style = style
        isSelectable = style.selectable
        if mentionsChanged {
            hoveredChip = nil
            focusedChip = nil
            chipElements = makeChipElements()
        }
        apply()
    }

    // MARK: - Text

    /// The paragraph as the text view holds it: each chip's text in place of its mention, no-break spaces inside
    /// it, and room for its tint as kerning on the characters around it. Every position is the same as in
    /// `content.source`.
    func attributedText() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let string = NSMutableAttributedString(
            string: content.source,
            attributes: [.font: style.font, .foregroundColor: style.color, .paragraphStyle: paragraph]
        )
        if let lead = content.lead {
            let bold = NSFontManager.shared.convert(style.font, toHaveTrait: .boldFontMask)
            string.addAttribute(.font, value: bold, range: NSRange(location: 0, length: (lead as NSString).length))
        }
        var kerns: [Int: CGFloat] = [:]
        for (index, mention) in content.mentions.enumerated() {
            string.replaceCharacters(in: mention.range, with: mention.chipText.replacingOccurrences(of: " ", with: "\u{00A0}"))
            string.addAttribute(Self.chipAttribute, value: index, range: mention.range)
            if mention.isMissing {
                string.addAttributes([
                    .underlineStyle: NSUnderlineStyle.single.union(.patternDot).rawValue,
                    .underlineColor: NSColor.secondaryLabelColor,
                ], range: mention.range)
                continue
            }
            let before = mention.range.location - 1
            if before >= 0 {
                // The space before a chip doesn't break, so the room it carries stays on the chip's line.
                if (content.source as NSString).character(at: before) == 0x20 {
                    string.replaceCharacters(in: NSRange(location: before, length: 1), with: "\u{00A0}")
                }
                kerns[before, default: 0] += leadingRoom(for: mention)
            } else {
                let indented = NSMutableParagraphStyle()
                indented.setParagraphStyle(paragraph)
                indented.firstLineHeadIndent = leadingRoom(for: mention)
                string.addAttribute(.paragraphStyle, value: indented, range: NSRange(location: 0, length: string.length))
            }
            kerns[NSMaxRange(mention.range) - 1, default: 0] += DesignTokens.Chip.padding
        }
        for (location, kern) in kerns {
            string.addAttribute(.kern, value: kern, range: NSRange(location: location, length: 1))
        }
        return string
    }

    private func apply() {
        measured = []
        drawn = nil
        setAccessibilityElement(style.selectable)
        textStorage?.setAttributedString(attributedText())
        needsLayout = true
        needsDisplay = true
    }

    /// The room before a chip's characters: its padding, and the pull request symbol with a gap. A missing
    /// mention has no tint, so none.
    func leadingRoom(for mention: Mention) -> CGFloat {
        guard !mention.isMissing else { return 0 }
        guard mention.kind == .pullRequest else { return DesignTokens.Chip.padding }
        return DesignTokens.Chip.padding + symbolImage().size.width + 2
    }

    private func symbolImage() -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: style.font.pointSize * 0.85, weight: .medium)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: style.color))
        let image = NSImage(systemSymbolName: ReferencePopover.pullRequestSymbol, accessibilityDescription: nil) ?? NSImage()
        return image.withSymbolConfiguration(configuration) ?? image
    }

    // MARK: - Size

    /// The paragraph's height at `width`, from TextKit's own layout, so the view wraps in its pane like a `Text`.
    public func height(forWidth width: CGFloat) -> CGFloat {
        ceil(layout(width: width).usageBoundsForTextContainer.height)
    }

    /// A line of `font`'s text as TextKit lays it out: how far its baseline sits below the line's top, and how far
    /// the line goes below its baseline. SwiftUI aligns a symbol or a radio on the paragraph's first line with them.
    public static func baseline(of font: NSFont) -> (ascent: CGFloat, descent: CGFloat) {
        if let known = baselines[font] { return known }
        let storage = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        manager.textContainer = NSTextContainer(size: CGSize(width: 1000, height: CGFloat.greatestFiniteMagnitude))
        storage.addTextLayoutManager(manager)
        storage.attributedString = NSAttributedString(string: "Ag", attributes: [.font: font])
        var metrics = (ascent: ceil(font.ascender), descent: ceil(-font.descender))
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
            // The glyphs' origin in the line is its baseline.
            if let line = fragment.textLineFragments.first {
                metrics = (line.glyphOrigin.y, line.typographicBounds.height - line.glyphOrigin.y)
            }
            return false
        }
        baselines[font] = metrics
        return metrics
    }

    nonisolated(unsafe) private static var baselines: [NSFont: (ascent: CGFloat, descent: CGFloat)] = [:]

    /// The size the paragraph takes at most `width` wide, as a `Text` sizes itself: as wide as its longest line,
    /// and on one line when SwiftUI proposes no width.
    public func fittingSize(width: CGFloat?) -> CGSize {
        let used = layout(width: width ?? 100_000).usageBoundsForTextContainer
        return CGSize(width: ceil(min(width ?? .greatestFiniteMagnitude, used.maxX)), height: ceil(used.height))
    }

    /// The paragraph laid out at `width` by a TextKit 2 layout of its own: the view's container never gets wider
    /// than the view, so a width SwiftUI only proposes, or a snapshot's, is measured and drawn here.
    private func layout(width: CGFloat) -> NSTextLayoutManager {
        let width = max(1, width)
        if let index = measured.firstIndex(where: { $0.width == width }) {
            let layout = measured.remove(at: index)
            measured.append(layout)
            return layout.manager
        }
        let storage = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.textContainer = container
        manager.delegate = self
        storage.addTextLayoutManager(manager)
        storage.attributedString = attributedText()
        manager.ensureLayout(for: manager.documentRange)
        measured.append((width, storage, manager))
        if measured.count > Self.measuredWidths { measured.removeFirst() }
        return manager
    }

    /// The layouts measured last, most recent at the end. SwiftUI proposes a few widths in turn (none, the pane's,
    /// a minimum) and VoiceOver asks at the view's own, so keeping one per width saves laying the text out again on
    /// every request.
    private var measured: [(width: CGFloat, storage: NSTextContentStorage, manager: NSTextLayoutManager)] = []
    static let measuredWidths = 4

    /// How many layouts the paragraph keeps.
    var measuredCount: Int { measured.count }

    override open func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // A container given its own size again still lays its text out again, so only a new width resets it.
        let width = max(1, newSize.width)
        if textContainer?.size.width != width {
            textContainer?.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    // MARK: - Chips

    /// The rectangles of a chip's tint in the view, one per line it is on (one, since a chip doesn't break).
    public func chipRects(_ index: Int) -> [CGRect] {
        guard let manager = textLayoutManager else { return [] }
        let origin = textContainerOrigin
        return chipFrames(index, in: manager).map { $0.offsetBy(dx: origin.x, dy: origin.y) }
    }

    /// A chip's tint in a layout's text container, from where its glyphs sit on their lines. TextKit's text segments
    /// and caret offsets put half of a character's kerning on its neighbour, so they miss the room before and after a
    /// chip by half; the glyph origins don't.
    private func chipFrames(_ index: Int, in manager: NSTextLayoutManager) -> [CGRect] {
        guard content.mentions.indices.contains(index), let contentManager = manager.textContentManager else { return [] }
        let mention = content.mentions[index]
        manager.ensureLayout(for: manager.documentRange)
        let documentStart = contentManager.documentRange.location
        guard let start = contentManager.location(documentStart, offsetBy: mention.range.location),
            let end = contentManager.location(start, offsetBy: mention.range.length),
            let range = NSTextRange(location: start, end: end)
        else { return [] }
        let room = leadingRoom(for: mention)
        var frames: [CGRect] = []
        manager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            guard fragment.rangeInElement.location.compare(range.endLocation) == .orderedAscending else { return false }
            let paragraphStart = contentManager.offset(from: documentStart, to: fragment.rangeInElement.location)
            let fragmentFrame = fragment.layoutFragmentFrame
            for line in fragment.textLineFragments {
                let lineRange = NSRange(location: paragraphStart + line.characterRange.location, length: line.characterRange.length)
                let chars = NSIntersectionRange(lineRange, mention.range)
                guard chars.length > 0 else { continue }
                let bounds = line.typographicBounds
                let glyphs = GlyphOrigins(line)
                let x = { (location: Int) in
                    fragmentFrame.minX + bounds.minX + glyphs.x(at: location - paragraphStart - line.characterRange.location)
                }
                let minX = x(chars.location) - (chars.location == mention.range.location ? room : 0)
                let maxX = x(NSMaxRange(chars))
                frames.append(CGRect(x: minX, y: fragmentFrame.minY + bounds.minY, width: maxX - minX, height: bounds.height))
            }
            return true
        }
        return frames
    }

    /// The chip at `point` in the view, nil in plain text.
    public func chipIndex(at point: CGPoint) -> Int? {
        content.mentions.indices.first { index in chipRects(index).contains { $0.contains(point) } }
    }

    /// Draws the chips that sit in a layout fragment, under its text: tinted, or dotted-underlined when missing (the
    /// underline is a text attribute); hovered, tinted more with a hairline; focused, with a focus ring.
    func drawChips(of fragment: NSTextLayoutFragment, at point: CGPoint, context: CGContext) {
        guard let manager = fragment.textLayoutManager else { return }
        let fragmentFrame = fragment.layoutFragmentFrame
        let offset = CGPoint(x: point.x - fragmentFrame.minX, y: point.y - fragmentFrame.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        for (index, mention) in content.mentions.enumerated() where !mention.isMissing {
            for rect in chipFrames(index, in: manager) where rect.intersects(fragmentFrame) {
                let chip = rect.offsetBy(dx: offset.x, dy: offset.y)
                let radius = min(DesignTokens.Chip.radius, chip.height / 2)
                let shape = NSBezierPath(roundedRect: chip, xRadius: radius, yRadius: radius)
                let lit = index == hoveredChip || index == popoverChip
                NSColor.controlAccentColor.withAlphaComponent(lit ? DesignTokens.Chip.hoverTint : DesignTokens.Chip.tint).setFill()
                shape.fill()
                if lit {
                    let hairline = NSBezierPath(roundedRect: chip.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
                    hairline.lineWidth = 1
                    NSColor.controlAccentColor.withAlphaComponent(0.5).setStroke()
                    hairline.stroke()
                }
                if index == focusedChip {
                    let ring = NSBezierPath(roundedRect: chip.insetBy(dx: -1.5, dy: -1.5), xRadius: radius + 1.5, yRadius: radius + 1.5)
                    ring.lineWidth = 3
                    NSColor.keyboardFocusIndicatorColor.setStroke()
                    ring.stroke()
                }
                if mention.kind == .pullRequest {
                    let symbol = symbolImage()
                    let size = symbol.size
                    symbol.draw(
                        in: CGRect(x: chip.minX + DesignTokens.Chip.padding, y: chip.midY - size.height / 2, width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
                    )
                }
            }
        }
    }

    /// The chip whose popover is open, which stays lit.
    public private(set) var popoverChip: Int? {
        didSet { if popoverChip != oldValue { redrawChips() } }
    }

    private func redrawChips() {
        drawn = nil
        guard let manager = textLayoutManager else { return }
        manager.invalidateLayout(for: manager.documentRange)
        manager.textViewportLayoutController.layoutViewport()
        needsDisplay = true
    }

    public func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let fragment = ChipLayoutFragment(textElement: textElement, range: textElement.elementRange)
        fragment.owner = self
        return fragment
    }

    // MARK: - Popover and opening

    /// Opens a chip's popover (N2, N3, or the "can't see" line), on screen: the chip scrolls into view first.
    public func showDetails(_ index: Int, hover: Bool = false) {
        guard content.mentions.indices.contains(index) else { return }
        scrollChipToVisible(index)
        guard let rect = chipRects(index).first else { return }
        popoverChip = index
        popover?.show(content.mentions[index], relativeTo: rect, of: self, hover: hover)
    }

    /// Scrolls the review so a chip and its focus ring are in view; outside a scroll view, nothing moves. With
    /// `scrollReview`, the review scrolls through it, and its clip view moves the same distance at once, so a popover
    /// opened next is anchored on screen.
    func scrollChipToVisible(_ index: Int) {
        guard let rect = chipRects(index).first else { return }
        let ringed = rect.insetBy(dx: -Self.focusRingMargin, dy: -Self.focusRingMargin)
        guard let scrollReview, let scrollView = enclosingScrollView, scrollView.contentView.isFlipped else {
            scrollToVisible(ringed)
            return
        }
        let clip = scrollView.contentView
        let insets = clip.contentInsets
        let visible = CGRect(
            x: clip.bounds.minX, y: clip.bounds.minY + insets.top,
            width: clip.bounds.width, height: clip.bounds.height - insets.top - insets.bottom
        )
        let distance = Self.distance(showing: convert(ringed, to: clip), in: visible)
        guard distance != 0 else { return }
        scrollReview(distance)
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: clip.bounds.minY + distance))
        scrollView.reflectScrolledClipView(clip)
    }

    /// How far down a top-down review scrolls for `visible` to show `rect`: the least distance, or to its top when it
    /// is taller.
    static func distance(showing rect: CGRect, in visible: CGRect) -> CGFloat {
        if rect.minY < visible.minY || rect.height > visible.height { return rect.minY - visible.minY }
        return max(0, rect.maxY - visible.maxY)
    }

    /// Room around a chip for its focus ring, which is drawn 3 pt outside the tint.
    static let focusRingMargin: CGFloat = 3

    /// The popover closed.
    public func popoverClosed() {
        popoverChip = nil
    }

    /// Opens a chip's ticket or pull request; `directly` (⌘) skips the peek.
    public func open(_ index: Int, directly: Bool = false) {
        guard content.mentions.indices.contains(index) else { return }
        hoverWork?.cancel()
        popover?.close()
        let mention = content.mentions[index]
        if directly, let openMentionDirectly { openMentionDirectly(mention) } else { openMention(mention) }
    }

    /// The pointer moved to `point` in the view, or left it: the chip under it lights, and its popover opens after
    /// the pointer rests there for `hoverDelay`. Under a sheet (`drawsText` false) no chip lights.
    public func pointerMoved(to point: CGPoint?) {
        let chip = drawsText ? point.flatMap(chipIndex(at:)) : nil
        guard chip != hoveredChip else { return }
        hoveredChip = chip
        hoverWork?.cancel()
        hoverWork = nil
        guard let chip else {
            popover?.pointerLeftChip()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.showDetails(chip, hover: true) }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverDelay, execute: work)
    }

    override open func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override open func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        pointerMoved(to: point)
        if hoveredChip != nil { NSCursor.pointingHand.set() }
    }

    override open func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        pointerMoved(to: nil)
    }

    override open func mouseDown(with event: NSEvent) {
        guard let chip = chipIndex(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        hoverWork?.cancel()
        pressedChip = chip
    }

    override open func mouseDragged(with event: NSEvent) {
        if pressedChip == nil { super.mouseDragged(with: event) }
    }

    override open func mouseUp(with event: NSEvent) {
        guard let pressed = pressedChip else {
            super.mouseUp(with: event)
            return
        }
        pressedChip = nil
        if chipIndex(at: convert(event.locationInWindow, from: nil)) == pressed {
            open(pressed, directly: event.modifierFlags.contains(.command))
        }
    }

    /// Out of a control's text, a click outside a chip goes to the control.
    override open func hitTest(_ point: NSPoint) -> NSView? {
        guard !style.selectable else { return super.hitTest(point) }
        let local = superview.map { convert(point, from: $0) } ?? point
        return chipIndex(at: local) == nil ? nil : super.hitTest(point)
    }

    override open func menu(for event: NSEvent) -> NSMenu? {
        guard let chip = chipIndex(at: convert(event.locationInWindow, from: nil)) else { return super.menu(for: event) }
        return chipMenu(chip)
    }

    /// A chip's menu: Copy Link, then Open in Linear or Open on GitHub.
    public func chipMenu(_ index: Int) -> NSMenu? {
        guard content.mentions.indices.contains(index), let url = content.mentions[index].reference.url else { return nil }
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy Link", action: #selector(copyLink(_:)), keyEquivalent: "")
        let open = NSMenuItem(
            title: content.mentions[index].kind == .pullRequest ? "Open on GitHub" : "Open in Linear",
            action: #selector(openLink(_:)), keyEquivalent: ""
        )
        for item in [copy, open] {
            item.target = self
            item.representedObject = url
            menu.addItem(item)
        }
        return menu
    }

    @objc func copyLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc func openLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openURL(url)
    }

    // MARK: - Selection and copy

    /// What copying `range` gives: the item's own text, with each chip it touches whole ("TP-891", or
    /// "TP-891 (Short name)" as written).
    public func copiedText(for range: NSRange) -> String {
        let source = content.source as NSString
        let range = wholeChips(range)
        guard range.location != NSNotFound, NSMaxRange(range) <= source.length else { return "" }
        return source.substring(with: range)
    }

    private func wholeChips(_ range: NSRange) -> NSRange {
        content.mentions.reduce(range) { range, mention in
            let touches = range.length > 0 ? NSIntersectionRange(range, mention.range).length > 0 : false
            return touches ? NSUnionRange(range, mention.range) : range
        }
    }

    /// A selection takes a chip whole.
    override open func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges.map { NSValue(range: wholeChips($0.rangeValue)) }, affinity: affinity, stillSelecting: stillSelecting)
    }

    override open var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    /// What ⌘C copies: the selection's text, chips whole; nil without a selection.
    public var copiedSelection: String? {
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        return ranges.isEmpty ? nil : ranges.map(copiedText(for:)).joined(separator: "\n")
    }

    override open func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let copiedSelection else { return false }
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString(copiedSelection, forType: .string)
    }

    // MARK: - Keyboard

    override open var acceptsFirstResponder: Bool { style.selectable || !content.mentions.isEmpty }
    override open var canBecomeKeyView: Bool { !content.mentions.isEmpty }

    override open func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        switch window?.keyViewSelectionDirection {
        case .selectingNext?: enterChips(forward: true)
        case .selectingPrevious?: enterChips(forward: false)
        default: break
        }
        return true
    }

    /// Tab or Shift-Tab came into the paragraph: the keyboard goes to its first chip, or its last going back.
    public func enterChips(forward: Bool) {
        guard focusedChip == nil, !content.mentions.isEmpty else { return }
        focusedChip = forward ? 0 : content.mentions.count - 1
    }

    override open func resignFirstResponder() -> Bool {
        focusedChip = nil
        return super.resignFirstResponder()
    }

    /// The keys a paragraph with chips answers.
    public enum Key: Equatable {
        case tab, backtab, space, enter, commandEnter, escape
    }

    /// Tab and Shift-Tab move between the chips and then out of the paragraph, Space shows the focused chip's
    /// popover, Return opens it (⌘Return past the peek), Escape closes the popover. False when the key isn't the
    /// chips'.
    @discardableResult
    public func handle(_ key: Key) -> Bool {
        switch key {
        case .tab, .backtab:
            let step = key == .tab ? 1 : -1
            let next = (focusedChip ?? (step > 0 ? -1 : content.mentions.count)) + step
            if content.mentions.indices.contains(next) {
                focusedChip = next
                return true
            }
            focusedChip = nil
            if key == .tab { window?.selectNextKeyView(self) } else { window?.selectPreviousKeyView(self) }
            // Moved on by hand, the window sets no direction for the next paragraph to read.
            (window?.firstResponder as? ChipTextView)?.enterChips(forward: key == .tab)
            return true
        case .space:
            guard let focusedChip else { return false }
            showDetails(focusedChip)
            return true
        case .enter, .commandEnter:
            guard let focusedChip else { return false }
            open(focusedChip, directly: key == .commandEnter)
            return true
        case .escape:
            guard popoverChip != nil else { return false }
            popover?.close()
            return true
        }
    }

    /// ⌘Return is also Send Decision's shortcut: on a focused chip it opens the chip's page instead.
    override open func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, [36, 76].contains(event.keyCode), modifiers == .command, handle(.commandEnter) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override open func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key: Key? = switch event.keyCode {
        case 48: modifiers.contains(.shift) ? .backtab : .tab
        case 49: .space
        case 36, 76: modifiers == .command ? .commandEnter : .enter
        case 53: .escape
        default: nil
        }
        if let key, key == .commandEnter || modifiers.subtracting(.shift).isEmpty, handle(key) { return }
        // A read-only paragraph has no use for plain keys: the number keys that pick an option go on to the review.
        if modifiers.subtracting(.shift).isEmpty, let characters = event.charactersIgnoringModifiers,
            characters.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains), !characters.isEmpty
        {
            nextResponder?.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Accessibility

    /// The paragraph reads as one text; each chip is a link inside it. Reading the children changes nothing and lays
    /// nothing out: each link works out its frame when asked for it. Text in a control (an option card) is no
    /// element at all: the control reads for it.
    override open func accessibilityChildren() -> [Any]? {
        guard style.selectable else { return [] }
        return (super.accessibilityChildren() ?? []) + chipElements
    }

    /// The chips' link elements, in reading order.
    public var chipAccessibilityElements: [NSAccessibilityElement] {
        chipElements
    }

    /// A chip's rectangle in the view for VoiceOver, from the paragraph's own layout at the view's width, so an
    /// accessibility read never lays out the text view while it answers.
    func accessibilityChipRect(_ index: Int) -> CGRect {
        let origin = textContainerOrigin
        return chipFrames(index, in: layout(width: bounds.width)).first?.offsetBy(dx: origin.x, dy: origin.y) ?? .zero
    }

    private func makeChipElements() -> [ChipAccessibilityElement] {
        content.mentions.enumerated().map { index, mention in
            let element = ChipAccessibilityElement(index: index, view: self)
            element.setAccessibilityRole(.link)
            element.setAccessibilityLabel(mention.accessibilityLabel)
            element.setAccessibilityHelp("Shows details")
            element.setAccessibilityURL(mention.reference.url)
            element.setAccessibilityParent(self)
            element.setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: "Show Details") { [weak self] in
                    self?.showDetails(index)
                    return true
                },
            ])
            return element
        }
    }

    // MARK: - Snapshots

    /// The image drawn last, kept until the text, the chips' look, the width, the scale or the appearance changes.
    private var drawn: (width: CGFloat, scale: CGFloat, appearance: NSAppearance.Name, image: NSImage)?

    /// The paragraph drawn at `width` into an image, offscreen and without a window, for `ImageRenderer` snapshots
    /// (which can't draw an AppKit view) and for the paragraph under a sheet. It draws exactly what the view's layout
    /// fragments draw, once: a redraw at the same width gets the same image.
    public func image(width: CGFloat, scale: CGFloat = 2) -> NSImage {
        let appearance = effectiveAppearance.name
        if let drawn, drawn.width == width, drawn.scale == scale, drawn.appearance == appearance {
            return drawn.image
        }
        let image = drawImage(width: width, scale: scale)
        drawn = (width, scale, appearance, image)
        return image
    }

    private func drawImage(width: CGFloat, scale: CGFloat) -> NSImage {
        let manager = layout(width: width)
        let size = CGSize(width: max(1, width), height: max(1, ceil(manager.usageBoundsForTextContainer.height)))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )
        guard let rep, let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return NSImage(size: size) }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        // In points and top-down, as the view lays its text out.
        context.translateBy(x: 0, y: CGFloat(rep.pixelsHigh))
        context.scaleBy(x: scale, y: -scale)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
                fragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
                return true
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}

/// The text view a paragraph's image is drawn from, made on first use and kept up to date after, so drawing the
/// paragraph again (a redraw, an accessibility read that lays the window out) makes no text view and draws no image
/// again.
public final class ChipTextImageSource {
    private var made: ChipTextView?

    public init() {}

    /// The text view showing `content` in `style` and `appearance`.
    public func view(content: ChipTextContent, style: ChipTextStyle, appearance: NSAppearance.Name) -> ChipTextView {
        let view = made ?? ChipTextView(content: content, style: style)
        made = view
        view.update(content: content, style: style)
        if view.appearance?.name != appearance {
            view.appearance = NSAppearance(named: appearance)
        }
        return view
    }
}

/// The paragraph's layout fragment: the chips' tint under the text.
final class ChipLayoutFragment: NSTextLayoutFragment {
    weak var owner: ChipTextView?

    /// Wide enough for a chip's tint and symbol before its first character.
    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.insetBy(dx: -32, dy: -2)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        owner?.drawChips(of: self, at: point, context: context)
        super.draw(at: point, in: context)
    }
}

/// A chip as VoiceOver finds it: a link named "TP-891, Remove the retired review states, Code Review" with the hint
/// "Shows details". Press opens it; Show Details (and Show Alternate UI, the hover's action) opens its popover.
final class ChipAccessibilityElement: NSAccessibilityElement {
    let index: Int
    weak var view: ChipTextView?

    init(index: Int, view: ChipTextView) {
        self.index = index
        self.view = view
        super.init()
    }

    override func isAccessibilityElement() -> Bool { true }

    override func isAccessibilityFocused() -> Bool { view?.focusedChip == index }

    override func accessibilityFrameInParentSpace() -> NSRect {
        view?.accessibilityChipRect(index) ?? .zero
    }

    override func accessibilityFrame() -> NSRect {
        guard let view else { return .zero }
        return NSAccessibility.screenRect(fromView: view, rect: view.accessibilityChipRect(index))
    }

    override func accessibilityPerformPress() -> Bool {
        view?.open(index)
        return view != nil
    }

    override func accessibilityPerformShowAlternateUI() -> Bool {
        view?.showDetails(index)
        return view != nil
    }
}

/// Where each character's glyph starts on a line, as CoreText draws it: with the kerning of the character before.
private struct GlyphOrigins {
    private var origins: [Int: CGFloat] = [:]
    private let width: CGFloat

    init(_ line: NSTextLineFragment) {
        let ctLine = CTLineCreateWithAttributedString(line.attributedString.attributedSubstring(from: line.characterRange))
        width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        for run in CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            for (index, position) in zip(indices, positions) where origins[index] == nil {
                origins[index] = position.x
            }
        }
    }

    /// The glyph origin of the character at `index` in the line, or of the next one with a glyph of its own (inside
    /// a ligature); the line's end past its last character.
    func x(at index: Int) -> CGFloat {
        origins[index] ?? origins.filter { $0.key > index }.min { $0.key < $1.key }?.value ?? width
    }
}
