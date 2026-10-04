import AppKit
import SwiftUI
import SymphonyBarCore

/// What the Repos window shows, refreshed by its controller.
@MainActor
final class ReposViewModel: ObservableObject {
    @Published var display = ReposDisplay()
    /// The open Add Repo sheet, nil while none is.
    @Published var addRepo: AddRepoViewModel?
    /// What the last Add Repo, Edit, Disconnect or Remove Clone did, shown above the rows.
    @Published var message: String?
    var onAddRepo: () -> Void = {}
    var onEdit: (_ key: String) -> Void = { _ in }
    var onDisconnect: (_ key: String) -> Void = { _ in }
    var onRemoveClone: (_ key: String) -> Void = { _ in }
}

/// Owns the single Repos window. While it is open, each status poll refreshes it: from Symphony's
/// `GET /api/v1/repos` while Symphony answers, otherwise from the repositories in `symphony.yml`.
@MainActor
final class ReposWindowController: NSObject, NSWindowDelegate {
    private static let initialContentSize = NSSize(width: ReposView.width, height: 560)

    /// Symphony's state directory, looked up before each request since Symphony rewrites its control URL on start.
    var stateRoot: () -> URL = { StateRoot.locate(environment: AppStores.current.environment) }
    /// Restarts the app's Symphony gracefully, so it sets up a repo just added or changed.
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
            model.onAddRepo = { [weak self] in self?.showSheet(editing: nil) }
            model.onEdit = { [weak self] key in self?.showSheet(editing: key) }
            model.onDisconnect = { [weak self] key in self?.disconnect(key) }
            model.onRemoveClone = { [weak self] key in self?.removeClone(key) }
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

    private var configPath: String {
        AppStores.current.settingsStore().loadSettings().configPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func showDisplay() {
        let configPath = configPath
        let display = ReposList.display(
            status: status,
            poll: poll,
            configPath: configPath,
            readConfig: { try SymphonyConfigFile(path: $0).readRepositories() }
        )
        let root = clonesRoot(configPath)
        model?.display = ReposList.withActions(display, entries: readEntries(configPath)) { [status, poll] gitHub in
            ManagedClones.removal(gitHub: gitHub, root: root, status: status, poll: poll)
        }
    }

    private func readEntries(_ configPath: String) -> Result<[RepositoryEntry], AddRepoProblem> {
        guard !configPath.isEmpty else { return .failure(AddRepoProblem("Set the symphony.yml path in Settings first.")) }
        do {
            return .success(try SymphonyConfigFile(path: configPath).readRepositories())
        } catch {
            let shown = (configPath as NSString).abbreviatingWithTildeInPath
            return .failure(AddRepoProblem("Couldn't read the repos in \(shown): \(error.localizedDescription)"))
        }
    }

    private func clonesRoot(_ configPath: String) -> URL {
        (try? SymphonyConfigFile(path: configPath).readClonesRoot()) ?? ManagedClones.root(in: "", configPath: configPath)
    }

    /// Opens the Add Repo sheet, or with `editing` the same sheet on that repo.
    private func showSheet(editing key: String?) {
        guard let model, model.addRepo == nil else { return }
        model.message = nil
        model.addRepo = AddRepoViewModel(configPath: configPath, secrets: secrets, editing: key) { [weak self] saved in
            self?.saved(saved)
        }
    }

    /// Closes the sheet, shows the repo from the file, and gets Symphony to use it: Symphony reads routes while it
    /// runs, but makes a repo's workflow store and its own clone only when it starts.
    private func saved(_ saved: AddRepoViewModel.Saved) {
        switch saved {
        case let .added(key, madeDefault):
            let apply = AddRepo.apply(status: status)
            finish(
                message: AddRepo.savedMessage(key: key, apply: apply, madeDefault: madeDefault),
                apply: apply,
                question: { AddRepo.restartQuestion(key: key, runs: $0) },
                later: "Added \(key). Restart Symphony from the menu to connect it."
            )
        case let .edited(original, entry):
            let apply = EditRepo.apply(status: status, from: original, to: entry)
            finish(
                message: EditRepo.savedMessage(key: entry.key, apply: apply),
                apply: apply,
                question: { EditRepo.restartQuestion(key: entry.key, runs: $0) },
                later: "Saved \(entry.key). Restart Symphony from the menu to apply it."
            )
        }
    }

    /// Asks before disconnecting `key`, with a pick of the new default when it is the default, then removes its
    /// entry from `symphony.yml`. Never deletes a folder.
    private func disconnect(_ key: String) {
        guard let model, model.addRepo == nil else { return }
        let file = SymphonyConfigFile(path: configPath)
        let entries: [RepositoryEntry]
        switch readEntries(configPath) {
        case let .success(read):
            entries = read
        case let .failure(problem):
            model.message = problem.message
            return
        }
        if let problem = DisconnectRepo.problem(key: key, entries: entries) {
            model.message = problem
            return
        }
        guard let entry = entries.first(where: { $0.key == key }) else { return }
        let candidates = DisconnectRepo.defaultCandidates(key: key, entries: entries)
        let question = DisconnectRepo.question(for: entry, newDefaultNeeded: candidates != nil)

        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.message
        alert.addButton(withTitle: DisconnectRepo.confirmTitle).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        var picker: NSPopUpButton?
        if let candidates {
            let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
            popUp.addItems(withTitles: candidates)
            alert.accessoryView = popUp
            picker = popUp
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let newDefault = picker?.titleOfSelectedItem
        do {
            try file.disconnectRepository(key, newDefault: newDefault)
        } catch {
            model.message = "Couldn't disconnect \(key): \(error.localizedDescription)"
            return
        }
        let apply = AddRepo.apply(status: status)
        finish(
            message: DisconnectRepo.message(key: key, apply: apply, newDefault: newDefault),
            apply: apply,
            question: { DisconnectRepo.restartQuestion(key: key, runs: $0) },
            later: "Disconnected \(key). Restart Symphony from the menu to drop it."
        )
    }

    /// Asks before deleting Symphony's clone of a managed repo, asks Symphony again whether an agent uses it, then
    /// deletes it if it is inside the clones folder.
    private func removeClone(_ key: String) {
        guard let model, let row = model.display.rows.first(where: { $0.key == key }),
              let gitHub = row.managedGitHub, let path = row.actions.cloneRemoval?.path else { return }
        let question = ManagedClones.question(key: key, gitHub: gitHub, path: path)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = question.title
        alert.informativeText = question.message
        alert.addButton(withTitle: ManagedClones.confirmTitle).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            // An agent may have started on the clone while the alert was open.
            if ReposList.isAnswering(status) {
                poll = await ReposAPI.fetch(stateRoot: stateRoot(), fallback: AppStores.current.controlURLFallback)
            }
            let root = clonesRoot(configPath)
            let removal = ManagedClones.removal(gitHub: gitHub, root: root, status: status, poll: poll)
            if let path = removal.path {
                do {
                    try await Task.detached { try ManagedClones.remove(path, root: root) }.value
                    self.model?.message = ManagedClones.removedMessage(key: key, path: path)
                } catch {
                    self.model?.message = "Couldn't remove the clone: \(error.localizedDescription)"
                }
            } else if case let .blocked(reason) = removal {
                self.model?.message = "Didn't remove the clone: \(reason)"
            }
            update(status: status)
        }
    }

    /// Shows what a change did and gets Symphony to use it, asking first when the restart waits for agent runs.
    private func finish(
        message: String,
        apply: AddRepoApply?,
        question: @escaping (_ runs: Int) -> (title: String, message: String),
        later: String
    ) {
        model?.addRepo = nil
        model?.message = message
        update(status: status)
        switch apply {
        case .restart?:
            restart()
        case let .askToRestart(runs)?:
            // After the sheet has closed, so the alert sits on the window.
            DispatchQueue.main.async { [weak self] in self?.askToRestart(question(runs), later: later) }
        case .onNextStart?, .restartManually?, nil:
            break
        }
    }

    private func askToRestart(_ question: (title: String, message: String), later: String) {
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.message
        alert.addButton(withTitle: "Restart When Runs Finish")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            restart()
        } else {
            model?.message = later
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        model = nil
        poll = nil
    }
}
