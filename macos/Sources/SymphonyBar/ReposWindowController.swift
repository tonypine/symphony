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
            guard let selection, selection != oldValue else { return }
            // Picking another repo drops the wait for the banner's.
            if selection != pendingSelection { pendingSelection = nil }
            onSelect(selection)
        }
    }
    /// The banner's repo while the window doesn't list it yet, selected once it does.
    var pendingSelection: String?
    /// The open Add Repo sheet, nil while none is.
    @Published var addRepo: AddRepoViewModel?
    /// What the last Add Repo, Edit, Disconnect or Remove Clone did, shown at the top of its repo's detail.
    @Published var banner: ReposBanner? {
        didSet {
            if banner == nil { pendingSelection = nil }
        }
    }
    /// The toolbar chip while a restart is under way, nil while none is.
    @Published var restartChip: ReposRestartChip?
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
    var onRestartNow: () -> Void = {}
    var onCancelRestart: () -> Void = {}
    var onFix: (_ fix: RepoHealth.Fix) -> Void = { _ in }

    var selected: RepoDetail? {
        window.repos.first { $0.key == selection }
    }

    /// The banner on the detail shown now.
    var shownBanner: ReposBanner? {
        banner.flatMap { $0.isShown(on: selection, listed: window.repos.map(\.key)) ? $0 : nil }
    }
}

/// Owns the single Repos window. While it is open, each status poll refreshes it: from Symphony's
/// `GET /api/v1/repos` while Symphony answers, otherwise from the repositories in `symphony.yml`.
@MainActor
final class ReposWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private static let initialContentSize = NSSize(width: ReposView.defaultWidth, height: ReposView.defaultHeight)
    /// The window's frame, in the app's defaults so QA mode keeps it under the QA root.
    private let frame = WindowFrameStore(name: "SymphonyReposWindow", defaults: AppStores.current.defaults)
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
    /// The app's graceful restart, which the toolbar chip follows, and its Restart Now and Cancel Restart.
    var restartMachine: () -> RestartMachine = { RestartMachine() }
    var restartNow: () -> Void = {}
    var cancelRestart: () -> Void = {}

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
            model.onRestartNow = { [weak self] in self?.restartNow() }
            model.onCancelRestart = { [weak self] in self?.cancelRestart() }
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
            window.restoreFrame(from: frame)
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
            let result = await AppStores.current.fetchRepos(stateRoot: stateRoot())
            inFlight = false
            // The window may have closed, or Symphony stopped, while the request was out.
            guard model != nil, ReposList.isAnswering(self.status) else { return }
            poll = result
            showDisplay()
        }
    }

    /// Called after each step of a restart, so the toolbar chip follows it. Does nothing while the window is closed.
    func restartChanged() {
        showDisplay()
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
        model.restartChip = ReposRestartChip(machine: restartMachine(), window: shown)
        select(in: model)
    }

    /// Selects the banner's repo once the window lists it, else keeps the selection while listed, else restores it.
    private func select(in model: ReposViewModel) {
        let saved = AppStores.current.defaults.object(forKey: Self.selectionKey) as? String
        let next = ReposList.selection(
            current: model.selection, pending: model.pendingSelection, saved: saved, in: model.window
        )
        model.selection = next.selection
        model.pendingSelection = next.pending
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
        let sheet = AddRepoViewModel(configPath: configPath, secrets: secrets, editing: key, state: state) { [weak self] saved in
            self?.saved(saved)
        }
        // Also on the repo, so the error is still there once the sheet is closed.
        sheet.onSaveError = { [weak self] message in self?.show(ReposChange.failed(key: key, message: message).banner) }
        model.addRepo = sheet
    }

    /// Closes the sheet, shows the repo from the file, and gets Symphony to use it: Symphony reads routes while it
    /// runs, but makes a repo's workflow store and its own clone only when it starts.
    private func saved(_ saved: AddRepoViewModel.Saved) {
        switch saved {
        case let .added(key, madeDefault):
            let apply = AddRepo.apply(status: status)
            finish(
                .added(key: key, apply: apply, madeDefault: madeDefault),
                apply: apply,
                question: { AddRepo.restartQuestion(key: key, runs: $0) }
            )
        case let .edited(original, entry):
            let apply = EditRepo.apply(status: status, from: original, to: entry)
            finish(
                .edited(key: entry.key, apply: apply),
                apply: apply,
                question: { EditRepo.restartQuestion(key: entry.key, runs: $0) }
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
            show(ReposChange.failed(key: key, message: problem.message).banner)
            return
        }
        if let problem = DisconnectRepo.problem(key: key, entries: entries) {
            show(ReposChange.failed(key: key, message: problem).banner)
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
        let next = DisconnectRepo.nextSelection(after: key, in: model.window.repos.map(\.key))
        do {
            try file.disconnectRepository(key, newDefault: newDefault)
        } catch {
            show(ReposChange.failed(key: key, message: "Couldn't disconnect \(key): \(error.localizedDescription)").banner)
            return
        }
        let apply = AddRepo.apply(status: status)
        finish(
            .disconnected(key: key, apply: apply, newDefault: newDefault, next: next),
            apply: apply,
            question: { DisconnectRepo.restartQuestion(key: key, runs: $0) }
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
                poll = await AppStores.current.fetchRepos(stateRoot: stateRoot())
            }
            let root = ReposConfig.read(path: configPath).clonesRoot
            let removal = ManagedClones.removal(gitHub: gitHub, root: root, status: status, poll: poll)
            var change: ReposChange?
            if let path = removal.path {
                do {
                    try await Task.detached { try ManagedClones.remove(path, root: root) }.value
                    change = .cloneRemoved(key: key, path: path)
                } catch {
                    change = .failed(key: key, message: "Couldn't remove the clone: \(error.localizedDescription)")
                }
            } else if case let .blocked(reason) = removal {
                change = .cloneKept(key: key, reason: reason)
            }
            update(status: status)
            if let change { show(change.banner) }
        }
    }

    /// Shows `banner` in place of the last one, and selects its repo now or once the window lists it.
    private func show(_ banner: ReposBanner) {
        guard let model else { return }
        model.banner = banner
        model.pendingSelection = banner.key
        select(in: model)
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
        let key = model.selection
        let stateRoot = stateRoot()
        Task {
            let result = await AppStores.current.sendControl(.stop(identifier), stateRoot: stateRoot)
            guard let model = self.model else { return }
            model.stopping.remove(identifier)
            switch result {
            case .done, .moved:
                show(ReposBanner(key: key, text: RepoHealth.stoppedMessage(issueIdentifier: identifier)))
            case let .failed(message):
                model.stopFailures[identifier] = message
            }
            update(status: status)
        }
    }

    /// Shows what a change did and gets Symphony to use it, asking first when the restart waits for agent runs.
    private func finish(
        _ change: ReposChange,
        apply: AddRepoApply?,
        question: @escaping (_ runs: Int) -> (title: String, message: String)
    ) {
        model?.addRepo = nil
        update(status: status)
        show(change.banner)
        switch apply {
        case .restart?:
            restart()
        case let .askToRestart(runs)?:
            // After the sheet has closed, so the alert sits on the window.
            DispatchQueue.main.async { [weak self] in self?.askToRestart(question(runs), later: change.laterBanner) }
        case .onNextStart?, .restartManually?, nil:
            break
        }
    }

    private func askToRestart(_ question: (title: String, message: String), later: ReposBanner) {
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.message
        alert.addButton(withTitle: "Restart When Runs Finish")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            restart()
        } else {
            show(later)
        }
    }

    func windowDidMove(_ notification: Notification) {
        window?.saveFrame(to: frame, after: notification)
    }

    func windowDidResize(_ notification: Notification) {
        window?.saveFrame(to: frame, after: notification)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        window?.saveFrame(to: frame, after: notification)
    }

    func windowWillClose(_ notification: Notification) {
        window?.saveFrame(to: frame, after: notification)
        window = nil
        model = nil
        poll = nil
    }
}
