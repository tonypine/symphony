import AppKit
import SymphonyBarCore

extension NSWindow {
    /// Puts the window where `store` last saw it, or centers it the first time.
    func restoreFrame(from store: WindowFrameStore) {
        if let descriptor = store.load() { setFrame(from: descriptor) } else { center() }
    }

    /// Saves the frame after a move or a resize, once a live resize ends rather than on each step of it, so the frame
    /// comes back even when the app quits with the window open.
    func saveFrame(to store: WindowFrameStore, after notification: Notification) {
        if notification.name == NSWindow.didResizeNotification, inLiveResize { return }
        store.save(frameDescriptor)
    }
}
