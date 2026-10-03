import AppKit
import SwiftUI

/// Owns the single Settings window. Each time it opens, values are read fresh from UserDefaults and the Keychain.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Room for the Form at about its ideal height plus the button bar.
    private static let initialContentSize = NSSize(width: SettingsView.width, height: 720)

    private var window: NSWindow?

    /// Called after Save stored changed secrets, so a running Symphony restarts with them.
    var onSecretsChanged: () -> Void = {}

    func show() {
        if window == nil {
            let model = SettingsViewModel(onSecretsChanged: { [weak self] in self?.onSecretsChanged() })
            let view = SettingsView(model: model) { [weak self] in self?.window?.close() }
            let hostingController = NSHostingController(rootView: view)
            // The default (.preferredContentSize) keeps resizing the window to SwiftUI's ideal size, which
            // collapses the scroll-backed Form after the first layout pass. Let SwiftUI set only the bounds.
            hostingController.sizingOptions = [.minSize, .maxSize]
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Symphony Settings"
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(Self.initialContentSize)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }

        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
