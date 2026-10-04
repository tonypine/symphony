import AppKit
import SwiftUI
import SymphonyBarCore

/// What the Repos window shows, refreshed by its controller.
@MainActor
final class ReposViewModel: ObservableObject {
    @Published var display = ReposDisplay()
    /// The open Add Repo sheet, nil while none is.
    @Published var addRepo: AddRepoViewModel?
    /// What the last Add Repo did, shown above the rows.
    @Published var message: String?
    var onAddRepo: () -> Void = {}
}

/// Owns the single Repos window. While it is open, each status poll refreshes it: from Symphony's
/// `GET /api/v1/repos` while Symphony answers, otherwise from the repositories in `symphony.yml`.
@MainActor
final class ReposWindowController: NSObject, NSWindowDelegate {
    private static let initialContentSize = NSSize(width: ReposView.width, height: 560)

    /// Symphony's state directory, looked up before each request since Symphony rewrites its control URL on start.
    var stateRoot: () -> URL = { StateRoot.locate(environment: AppStores.current.environment) }
    /// Restarts the app's Symphony gracefully, so it sets up a repo just added.
    var restart: () -> Void = {}

    private let secrets: SecretsReader

    /// `secrets` is shared with Start, so the Add Repo sheet and Start can't each put up a Keychain prompt.
    init(secrets: SecretsReader) {
        self.secrets = secrets
    }

    private var window: NSWindow?
    private var model: ReposViewModel?
    private var status = SymphonyStatus.stopped
    /// The last answer to `GET /api/v1/repos`, nil before the first and while Symphony isn't answering.
    private var poll: ReposPoll?
    private var inFlight = false

    func show(status: SymphonyStatus) {
        if window == nil {
            let model = ReposViewModel()
            model.onAddRepo = { [weak self] in self?.showAddRepo() }
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

    private func showAddRepo() {
        guard let model, model.addRepo == nil else { return }
        model.message = nil
        model.addRepo = AddRepoViewModel(
            configPath: AppStores.current.settingsStore().loadSettings().configPath,
            secrets: secrets
        ) { [weak self] key, madeDefault in
            self?.added(key, madeDefault: madeDefault)
        }
    }

    /// Closes the sheet, shows the repo from the file, and gets Symphony to set it up: Symphony reads new routes
    /// while it runs, but makes a repo's workflow store and its own clone only when it starts.
    private func added(_ key: String, madeDefault: String?) {
        let apply = AddRepo.apply(status: status)
        model?.addRepo = nil
        model?.message = AddRepo.savedMessage(key: key, apply: apply, madeDefault: madeDefault)
        update(status: status)
        switch apply {
        case .restart:
            restart()
        case let .askToRestart(runs):
            // After the sheet has closed, so the alert sits on the window.
            DispatchQueue.main.async { [weak self] in self?.askToRestart(key: key, runs: runs) }
        case .onNextStart, .restartManually:
            break
        }
    }

    private func askToRestart(key: String, runs: Int) {
        let question = AddRepo.restartQuestion(key: key, runs: runs)
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.message
        alert.addButton(withTitle: "Restart When Runs Finish")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            restart()
        } else {
            model?.message = "Added \(key). Restart Symphony from the menu to connect it."
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        model = nil
        poll = nil
    }
}
