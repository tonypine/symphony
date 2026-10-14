import AppKit
import SymphonyBarCore

/// Shows a chip's popover in an `NSPopover` on the system's glass, with content the app makes for each mention.
/// One the pointer opened stays while the pointer is on the chip or on the popover, and closes a moment after it
/// leaves both; one the keyboard or VoiceOver opened closes like a menu, on a click elsewhere or Escape.
public final class ChipPopover: NSObject, ChipPopoverPresenting, NSPopoverDelegate {
    /// How long the pointer may take to cross from the chip to the popover.
    public static let closeDelay: TimeInterval = 0.3

    private let content: (Mention) -> NSViewController
    private let makePopover: () -> NSPopover
    private var popover: NSPopover?
    private var shown: Mention?
    private weak var owner: ChipTextView?
    private var openedByHover = false
    private var pointerOnPopover = false
    private var closeWork: DispatchWorkItem?

    /// `makePopover` lets tests stand in a popover that opens without a window.
    public init(
        content: @escaping (Mention) -> NSViewController,
        makePopover: @escaping () -> NSPopover = { NSPopover() }
    ) {
        self.content = content
        self.makePopover = makePopover
    }

    public var isShown: Bool { popover?.isShown == true }

    public func show(_ mention: Mention, relativeTo rect: CGRect, of view: NSView, hover: Bool) {
        closeWork?.cancel()
        if isShown, shown == mention, owner === view {
            // Opened again from the keyboard: it now closes like a menu.
            if !hover { setOpenedByHover(false) }
            return
        }
        // Let go of the last popover first, so its close doesn't count as this one's.
        let previous = popover
        popover = nil
        previous?.close()
        let controller = content(mention)
        let popover = makePopover()
        popover.contentViewController = controller
        popover.animates = true
        popover.delegate = self
        self.popover = popover
        shown = mention
        owner = view as? ChipTextView
        pointerOnPopover = false
        setOpenedByHover(hover)
        controller.view.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self
        ))
        popover.show(relativeTo: rect, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
    }

    public func pointerLeftChip() {
        guard openedByHover, isShown else { return }
        scheduleClose()
    }

    public func close() {
        closeWork?.cancel()
        popover?.close()
    }

    private func setOpenedByHover(_ hover: Bool) {
        openedByHover = hover
        popover?.behavior = hover ? .applicationDefined : .transient
    }

    private func scheduleClose() {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerOnPopover, self.owner?.hoveredChip == nil else { return }
            self.close()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDelay, execute: work)
    }

    @objc public func mouseEntered(with event: NSEvent) {
        pointerOnPopover = true
        closeWork?.cancel()
    }

    @objc public func mouseExited(with event: NSEvent) {
        pointerOnPopover = false
        if openedByHover { scheduleClose() }
    }

    public func popoverDidClose(_ notification: Notification) {
        // A popover that was replaced finishes closing after the next one opens; only the open one's close counts.
        guard notification.object as? NSPopover === popover else { return }
        owner?.popoverClosed()
        shown = nil
        popover = nil
    }
}
