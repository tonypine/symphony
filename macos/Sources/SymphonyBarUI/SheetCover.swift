import AppKit

/// Whether a window has a sheet over it. SwiftUI dims the window behind a sheet in its own drawing, and an AppKit view
/// in the window (a `ChipTextView`, a `TextEditor`) draws above that, at full contrast; such a view hands its drawing
/// to SwiftUI while its window is covered.
public final class SheetCover {
    public private(set) var covered = false
    /// Called when `covered` changes.
    public var changed: (Bool) -> Void = { _ in }
    private var observers: [NSObjectProtocol] = []
    private weak var sender: AnyObject?

    public init() {}

    deinit { stop() }

    /// Follows `window`'s sheets, starting from whether it has one now. Out of a window, nothing covers it.
    public func watch(_ window: NSWindow?) {
        watch(window, hasSheet: { [weak window] in window?.attachedSheet != nil })
    }

    /// Follows the sheets `sender` posts AppKit's sheet notifications for; `hasSheet` says whether one is up.
    func watch(_ sender: AnyObject?, hasSheet: @escaping () -> Bool) {
        guard sender !== self.sender || observers.isEmpty else { return }
        stop()
        self.sender = sender
        guard let sender else {
            set(false)
            return
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.willBeginSheetNotification, object: sender, queue: .main) { [weak self] _ in
                self?.set(true)
            },
            center.addObserver(forName: NSWindow.didEndSheetNotification, object: sender, queue: .main) { [weak self] _ in
                // Another sheet may still be up.
                self?.set(hasSheet())
            },
        ]
        set(hasSheet())
    }

    private func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func set(_ covered: Bool) {
        guard covered != self.covered else { return }
        self.covered = covered
        changed(covered)
    }
}

/// A view that draws nothing and takes no clicks, and says when its window has a sheet over it.
public final class SheetCoverView: NSView {
    public let cover = SheetCover()

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cover.watch(window)
    }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }
}
