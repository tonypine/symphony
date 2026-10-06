import AppKit
import SwiftUI
import SymphonyBarCore

/// What the Repos window shows, refreshed by its controller.
@MainActor
final class ReposViewModel: ObservableObject {
    @Published var window = ReposWindow()
    /// The key of the repo shown in the detail.
    @Published var selection: String? {
        didSet {
            if let selection, selection != oldValue { onSelect(selection) }
        }
    }
    /// The open Add Repo sheet, nil while none is.
    @Published var addRepo: AddRepoViewModel?
    /// What the last Add Repo, Edit, Disconnect or Remove Clone did, shown above the detail.
    @Published var message: String?
    /// Whether Start Symphony would start it now.
    @Published var canStart = false
    /// Issue identifiers whose Stop Run is out.
    @Published var stopping: Set<String> = []
    /// Why Stop Run failed, by issue identifier, shown under its line in the Needs attention box.
    @Published var stopFailures: [String: String] = [:]
    var onSelect: (_ key: String) -> Void = { _ in }
    var onAddRepo: () -> Void = {}
    var onEdit: (_ key: String) -> Void = { _ in }
    var onDisconnect: (_ key: String) -> Void = { _ in }
    var onRemoveClone: (_ key: String) -> Void = { _ in }
    var onStart: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onTryAgain: () -> Void = {}
    var onFix: (_ fix: RepoHealth.Fix) -> Void = { _ in }

    var selected: RepoDetail? {
        window.repos.first { $0.key == selection }
    }
}

/// Owns the single Repos window. While it is open, each status poll refreshes it: from Symphony's
/// `GET /api/v1/repos` while Symphony answers, otherwise from the repositories in `symphony.yml`.
@MainActor
final class ReposWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private static let initialContentSize = NSSize(width: ReposView.defaultWidth, height: ReposView.defaultHeight)
    private static let frameName = "SymphonyReposWindow"
    /// The app's defaults key for the repo selected last.
    private static let selectionKey = "ReposWindowSelection"
    private static let chipItem = NSToolbarItem.Identifier("ReposChip")
    private static let addItem = NSToolbarItem.Identifier("ReposAdd")

    /// Symphony's state directory, looked up before each request since Symphony rewrites its control URL on start.
    var stateRoot: () -> URL = { StateRoot.locate(environment: AppStores.current.environment) }
    /// Restarts the app's Symphony gracefully, so it sets up a repo just added or changed.
    var restart: () -> Void = {}
    /// Starts the app's Symphony, and whether it can now.
    var start: () -> Void = {}
    var canStart: () -> Bool = { false }
    var openSettings: () -> Void = {}

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
            model.onSelect = { key in AppStores.current.defaults.set(key, forKey: Self.selectionKey) }
            model.onAddRepo = { [weak self] in self?.showSheet(editing: nil) }
            model.onEdit = { [weak self] key in self?.showSheet(editing: key) }
            model.onDisconnect = { [weak self] key in self?.disconnect(key) }
            model.onRemoveClone = { [weak self] key in self?.removeClone(key) }
            model.onStart = { [weak self] in self?.start() }
            model.onOpenSettings = { [weak self] in self?.openSettings() }
            model.onTryAgain = { [weak self] in self.map { $0.update(status: $0.status) } }
            model.onFix = { [weak self] fix in self?.fix(fix) }
            self.model = model
            let hostingController = NSHostingController(rootView: ReposView(model: model))
            // Only the minimum: the window keeps the size it was left at.
            hostingController.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: hostingController)
            window.title = ReposList.windowTitle
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.toolbar = toolbar()
            window.toolbarStyle = .unified
            window.setContentSize(Self.initialContentSize)
            window.contentMinSize = NSSize(width: ReposView.minWidth, height: ReposView.minHeight)
            window.isReleasedWhenClosed = false
            window.delegate = self
            if !window.setFrameUsingName(Self.frameName) { window.center() }
            window.setFrameAutosaveName(Self.frameName)
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
        model?.addRepo?.gateAgreement?.state = state
        model?.canStart = canStart()
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
        guard let model else { return }
        let config = ReposConfig.read(path: configPath)
        let shown = ReposList.window(status: status, poll: poll, config: config) { [status, poll] gitHub in
            ManagedClones.removal(gitHub: gitHub, root: config.clonesRoot, status: status, poll: poll)
        }
        model.window = shown
        if model.selection.map({ key in !shown.repos.contains { $0.key == key } }) ?? true {
            let saved = AppStores.current.defaults.object(forKey: Self.selectionKey) as? String
            model.selection = ReposList.selection(saved: saved, in: shown)
        }
    }

    /// Symphony's state while it answers, for the Edit sheet's gate stats.
    private var state: StateSnapshot? {
        switch status {
        case let .running(snapshot, _), let .paused(snapshot, _):
            return snapshot
        case .stopped, .starting, .error:
            return nil
        }
    }

    // MARK: Toolbar

    private func toolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "SymphonyRepos")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.chipItem, Self.addItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case Self.chipItem:
            guard let model else { return nil }
            item.label = "Symphony"
            item.view = NSHostingView(rootView: ReposChipView(model: model))
        case Self.addItem:
            item.label = AddRepo.buttonTitle
            item.toolTip = AddRepo.buttonTitle
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: AddRepo.buttonTitle)
            item.isBordered = true
            item.target = self
            item.action = #selector(addRepo(_:))
        default:
            return nil
        }
        return item
    }

    @objc private func addRepo(_ sender: Any?) {
        showSheet(editing: nil)
    }

    /// Opens the Add Repo sheet, or with `editing` the same sheet on that repo.
    private func showSheet(editing key: String?) {
        guard let model, model.addRepo == nil else { return }
        model.message = nil
        model.addRepo = AddRepoViewModel(configPath: configPath, secrets: secrets, editing: key, state: state) { [weak self] saved in
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
        switch ReposConfig.read(path: configPath).entries {
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
        guard let model, let repo = model.window.repos.first(where: { $0.key == key }),
              let gitHub = repo.source.managedGitHub, let path = repo.actions.cloneRemoval?.path else { return }
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
            let root = ReposConfig.read(path: configPath).clonesRoot
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

    /// Runs a fix from the Needs attention box.
    private func fix(_ fix: RepoHealth.Fix) {
        switch fix {
        case let .openWorkflow(url), let .viewPullRequest(url), let .openOnGitHub(url), let .openInLinear(url):
            NSWorkspace.shared.open(url)
        case let .revealInFinder(path), let .revealWorktree(path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case let .copyError(error):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(error, forType: .string)
        case let .stopRun(identifier):
            stopRun(identifier)
        }
    }

    /// Asks before stopping the agent on `identifier`, then asks Symphony to stop it. A failure shows under the
    /// problem's line.
    private func stopRun(_ identifier: String) {
        guard let model, !model.stopping.contains(identifier) else { return }
        let question = RepoHealth.stopQuestion(issueIdentifier: identifier)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = question.title
        alert.informativeText = question.message
        alert.addButton(withTitle: RepoHealth.stopConfirmTitle).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        model.stopping.insert(identifier)
        model.stopFailures[identifier] = nil
        let stateRoot = stateRoot()
        Task {
            let result = await ControlAPI.send(
                .stop(identifier),
                stateRoot: stateRoot,
                fallback: AppStores.current.controlURLFallback
            )
            guard let model = self.model else { return }
            model.stopping.remove(identifier)
            switch result {
            case .done:
                model.message = RepoHealth.stoppedMessage(issueIdentifier: identifier)
            case let .failed(message):
                model.stopFailures[identifier] = message
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
        // Saves the frame now and frees its name, which the next window takes even if this one isn't freed yet.
        window?.saveFrame(usingName: Self.frameName)
        window?.setFrameAutosaveName("")
        window = nil
        model = nil
        poll = nil
    }
}
