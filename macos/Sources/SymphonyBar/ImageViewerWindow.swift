import AppKit
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// The one image viewer window: a screenshot large, with the images of its set a key away. Opening another image
/// brings the same window to the front on it; closing it and opening one again opens it at its first size.
@MainActor
final class ImageViewerWindow: NSObject, NSWindowDelegate {
    /// The share of the screen's visible frame the window opens at.
    static let openingShare = 0.8
    static let minimumSize = NSSize(width: 640, height: 420)

    private var window: NSWindow?
    private var session: ImageViewerSession?

    /// Shows `current` of `set` in the viewer window, opening it when it is not open.
    func open(_ set: [TicketScreenshot], current: TicketScreenshot, images: ArtifactImages) {
        if let window, let session {
            session.show(set, current: current, images: images)
            window.title = current.label
            window.makeKeyAndOrderFront(nil)
            return
        }
        let session = ImageViewerSession(images: images, model: ImageViewerModel(images: set, current: current))
        let hostingController = NSHostingController(
            rootView: ImageViewerView(session: session) { [weak self] in self?.window?.performClose(nil) }.pointerButtons()
        )
        hostingController.sizingOptions = []
        let window = NSWindow(contentViewController: hostingController)
        window.title = current.label
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentMinSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrame(Self.openingFrame(on: NSApp.keyWindow?.screen ?? NSScreen.main), display: false)
        self.window = window
        self.session = session
        window.makeKeyAndOrderFront(nil)
    }

    /// The window's first frame: `openingShare` of the screen's visible frame each way, in its middle.
    static func openingFrame(on screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: visible.width * openingShare, height: visible.height * openingShare)
        return NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        session = nil
    }
}
