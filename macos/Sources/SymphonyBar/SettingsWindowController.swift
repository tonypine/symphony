import AppKit
import SwiftUI
import SymphonyBarCore

/// Owns the single Settings window. Each time it opens, values are read fresh from UserDefaults and the secret store.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Room for the Form at about its ideal height plus the button bar.
    private static let initialContentSize = NSSize(width: SettingsView.width, height: 720)

    private var window: NSWindow?
    private let secrets: SecretsReader

    /// `secrets` is shared with Start, so Settings and Start can't each put up a Keychain prompt.
    init(secrets: SecretsReader) {
        self.secrets = secrets
    }

    /// Called after Save stored changed secrets, so a running Symphony restarts with them.
    var onSecretsChanged: () -> Void = {}

    /// Today's tokens from the latest poll, nil while Symphony isn't answering. Shown under Agents.
    var budget: StateSnapshot.Budget? {
        didSet { model?.budget = budget }
    }

    /// Symphony's latest state, nil while it isn't answering. Its gate stats show under Acceptance gate.
    var state: StateSnapshot? {
        didSet { model?.state = state }
    }

    private var model: SettingsViewModel?

    func show() {
        if window == nil {
            let model = SettingsViewModel(secrets: secrets, onSecretsChanged: { [weak self] in self?.onSecretsChanged() })
            model.budget = budget
            model.state = state
            self.model = model
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

        SymphonyRunner.activateApp()
        window?.makeKeyAndOrderFront(nil)
        // Puts the window in front even if the system still declined to activate the app.
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        model = nil
    }
}
