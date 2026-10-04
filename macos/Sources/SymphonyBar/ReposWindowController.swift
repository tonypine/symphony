import AppKit
import SwiftUI
import SymphonyBarCore

/// What the Repos window shows, refreshed by its controller.
@MainActor
final class ReposViewModel: ObservableObject {
    @Published var display = ReposDisplay()
}

/// Owns the single Repos window. While it is open, each status poll refreshes it: from Symphony's
/// `GET /api/v1/repos` while Symphony answers, otherwise from the repositories in `symphony.yml`.
@MainActor
final class ReposWindowController: NSObject, NSWindowDelegate {
    private static let initialContentSize = NSSize(width: ReposView.width, height: 560)

    /// Symphony's state directory, looked up before each request since Symphony rewrites its control URL on start.
    var stateRoot: () -> URL = { StateRoot.locate(environment: AppStores.current.environment) }

    private var window: NSWindow?
    private var model: ReposViewModel?
    private var status = SymphonyStatus.stopped
    /// The last answer to `GET /api/v1/repos`, nil before the first and while Symphony isn't answering.
    private var poll: ReposPoll?
    private var inFlight = false

    func show(status: SymphonyStatus) {
        if window == nil {
            let model = ReposViewModel()
            self.model = model
            let hostingController = NSHostingController(rootView: ReposView(model: model))
            hostingController.sizingOptions = [.minSize, .maxSize]
            let window = NSWindow(contentViewController: hostingController)
            window.title = ReposList.windowTitle
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(Self.initialContentSize)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        update(status: status)

        SymphonyRunner.activateApp()
        window?.makeKeyAndOrderFront(nil)
        // Puts the window in front even if the system still declined to activate the app.
        window?.orderFrontRegardless()
    }

    /// Called after each status poll and child process event. Does nothing while the window is closed.
    func update(status: SymphonyStatus) {
        guard model != nil else { return }
        self.status = status
        if !ReposList.isAnswering(status) { poll = nil }
        showDisplay()
        guard ReposList.isAnswering(status), !inFlight else { return }
        inFlight = true
        Task {
            let result = await ReposAPI.fetch(stateRoot: stateRoot(), fallback: AppStores.current.controlURLFallback)
            inFlight = false
            // The window may have closed, or Symphony stopped, while the request was out.
            guard model != nil, ReposList.isAnswering(self.status) else { return }
            poll = result
            showDisplay()
        }
    }

    private func showDisplay() {
        model?.display = ReposList.display(
            status: status,
            poll: poll,
            configPath: AppStores.current.settingsStore().loadSettings().configPath,
            readConfig: { try SymphonyConfigFile(path: $0).readRepositories() }
        )
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        model = nil
        poll = nil
    }
}
