import AppKit
import SymphonyBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem?
    private let runner = SymphonyRunner()
    private lazy var settingsWindow = SettingsWindowController(secrets: runner.secrets)
    private let reposWindow = ReposWindowController()
    private let poller = StatusPoller()
    private lazy var restarter = RestartController(runner: runner, poller: poller)
    private var machine = StatusMachine()
    private var usageLimitNotices = UsageLimitNotices()
    private let statusTitleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let sourceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var restartNowItem = menuItem(StatusMenu.restartNowTitle, action: #selector(restartNow(_:)))
    private lazy var cancelRestartItem = menuItem(StatusMenu.cancelRestartTitle, action: #selector(cancelRestart(_:)))
    private var detailItems: [NSMenuItem] = []
    private var startWhenStopped = false
    /// The Pause or Resume request under way, if any.
    private var controlInFlight: ControlAction?
    /// Why the last Pause or Resume failed, shown under the status until the next attempt.
    private var controlError: String?
    /// Heads the forced tickets, hidden while there are none.
    private let forcedTitleItem = NSMenuItem(title: StatusMenu.forcedTitle, action: nil, keyEquivalent: "")
    private lazy var forceItem = menuItem(StatusMenu.forceTitle, action: #selector(forceTicket(_:)))
    /// A row for each forced ticket, between its heading and Force a ticket….
    private var forcedItems: [NSMenuItem] = []
    /// The force or stop-forcing request under way, if any.
    private var forceInFlight: ControlAction?
    private let updates = UpdatePoller()
    /// The newer release, while there is one.
    private var availableRelease: Release?
    private let updateAvailableItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let releaseNotesItem = NSMenuItem(title: UpdateMenu.releaseNotesTitle, action: nil, keyEquivalent: "")
    /// The result of a Check for Updates chosen by hand, under that item.
    private let updateResultItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var updater = UpdateController(current: updates.current)
    private lazy var installUpdateItem = menuItem("", action: #selector(installUpdate(_:)))
    /// Under Update to vX: the update's progress, why it failed, or why Update is off.
    private let updateLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// Set when the app started Symphony after an update: resume dispatch once it answers.
    private var resumeWhenAnswering = false
    /// Stops an owned Symphony before the app exits on SIGTERM, SIGINT or SIGHUP.
    private var terminationSignals: TerminationSignals?
    private var exitingOnSignal = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        EditMenu.install()
        terminationSignals = TerminationSignals(queue: .main) { [weak self] number in
            MainActor.assumeIsolated { self?.terminate(onSignal: number) }
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        statusTitleItem.isEnabled = false
        menu.addItem(statusTitleItem)
        sourceItem.isEnabled = false
        menu.addItem(sourceItem)
        menu.addItem(.separator())
        menu.addItem(menuItem(StatusMenu.startTitle, action: #selector(startSymphony(_:))))
        menu.addItem(menuItem(StatusMenu.stopTitle, action: #selector(stopSymphony(_:))))
        menu.addItem(menuItem(StatusMenu.restartTitle, action: #selector(restartSymphony(_:))))
        menu.addItem(restartNowItem)
        menu.addItem(cancelRestartItem)
        menu.addItem(.separator())
        menu.addItem(menuItem(StatusMenu.pauseTitle, action: #selector(pauseDispatch(_:))))
        menu.addItem(menuItem(StatusMenu.resumeTitle, action: #selector(resumeDispatch(_:))))
        menu.addItem(.separator())
        forcedTitleItem.isEnabled = false
        menu.addItem(forcedTitleItem)
        menu.addItem(forceItem)
        menu.addItem(.separator())
        menu.addItem(menuItem(StatusMenu.openDashboardTitle, action: #selector(openDashboard(_:))))
        menu.addItem(menuItem(StatusMenu.openTerminalDashboardTitle, action: #selector(openTerminalDashboard(_:))))
        menu.addItem(menuItem(StatusMenu.openLogsTitle, action: #selector(openLogs(_:))))
        menu.addItem(.separator())
        updateAvailableItem.action = #selector(showReleaseNotes(_:))
        updateAvailableItem.target = self
        releaseNotesItem.action = #selector(showReleaseNotes(_:))
        releaseNotesItem.target = self
        updateResultItem.isEnabled = false
        updateLineItem.isEnabled = false
        menu.addItem(updateAvailableItem)
        menu.addItem(installUpdateItem)
        menu.addItem(updateLineItem)
        menu.addItem(releaseNotesItem)
        menu.addItem(menuItem(UpdateMenu.checkTitle, action: #selector(checkForUpdates(_:))))
        menu.addItem(updateResultItem)
        menu.addItem(.separator())
        menu.addItem(menuItem(ReposList.menuTitle, action: #selector(openRepos(_:))))
        menu.addItem(
            menuItem(
                StatusMenu.settingsTitle,
                action: #selector(openSettings(_:)),
                keyEquivalent: StatusMenu.settingsKeyEquivalent
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: StatusMenu.quitTitle,
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: StatusMenu.quitKeyEquivalent
            )
        )
        // Start, Stop, Restart, Pause, Resume and the open items are enabled by validateMenuItem; the status lines
        // stay disabled.
        menu.autoenablesItems = true
        // Refreshes the update items each time the menu opens, as Settings may have changed.
        menu.delegate = self
        item.menu = menu

        statusItem = item
        showStatus()

        runner.onEvent = { [weak self] event in self?.handle(event) }
        runner.onKeychainChange = { [weak self] in self?.showStatus() }
        restarter.onChange = { [weak self] in self?.showStatus() }
        // Symphony reads its secrets only at start; restart() does nothing while it isn't running.
        settingsWindow.onSecretsChanged = { [weak self] in self?.restart() }
        updater.onChange = { [weak self] in self?.showUpdateItems() }
        poller.stateRoot = { [weak self] in
            self?.runner.stateRoot ?? StateRoot.locate(environment: AppStores.current.environment)
        }
        reposWindow.stateRoot = poller.stateRoot
        poller.onPoll = { [weak self] poll in
            guard let self else { return StatusMachine.pollInterval }
            handle(.polled(poll))
            return machine.nextPollInterval
        }

        // After an update, bring Symphony back as it was before the app quit.
        let pendingUpdate = updater.pending.take()
        if let pendingUpdate {
            updater.removeDownloads()
            if !pendingUpdate.succeeded(runningBuild: updates.current.build) {
                let message = UpdateMenu.rolledBackMessage(pendingUpdate, logPath: updater.helperLogPath)
                DispatchQueue.main.async { SymphonyRunner.showAlert(title: UpdateMenu.failedTitle, body: message) }
            }
        }

        // First run: nothing to start yet, so ask for settings. Reads only the settings, not the secrets.
        let store = AppStores.current.settingsStore()
        store.migrateDevelopmentMode(embeddedSymphonyAvailable: SymphonyRunner.hasEmbeddedSymphony)
        let settings = store.loadSettings()
        if settings.needsSetup {
            settingsWindow.show()
        } else if settings.startOnLaunch || pendingUpdate?.startSymphony == true {
            // Wait for the first poll, so a Symphony already running from the CLI is attached to, not started twice.
            startWhenStopped = true
            resumeWhenAnswering = pendingUpdate?.resumeDispatch == true
        }
        poller.start()

        updates.onResult = { [weak self] result, manual in self?.showUpdate(result, manual: manual) }
        showUpdate(nil, manual: false)
        updates.start()
        QAScriptDriver.startIfScripted(menu: menu) { [weak self] in self?.runner.pid }
    }

    /// Quitting stops an owned Symphony first, after confirming when agent runs are active.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard runner.isRunning else { return .terminateNow }

        Task {
            if !runner.isStopping, let message = StatusMenu.quitConfirmation(activeRuns: await runner.activeRunCount()) {
                let alert = NSAlert()
                alert.messageText = "Quit Symphony?"
                alert.informativeText = message
                alert.addButton(withTitle: "Quit")
                alert.addButton(withTitle: "Cancel")
                guard SymphonyRunner.confirm(alert) else {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            runner.stop { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    /// A signal skips `applicationShouldTerminate`, so stop Symphony here, without asking, then exit. The exit runs
    /// before the runner reports the exit, so a Restart under way can't start Symphony again. A second signal while
    /// Symphony stops changes nothing: the stop already escalates to SIGKILL.
    private func terminate(onSignal number: Int32) {
        guard !exitingOnSignal else { return }
        exitingOnSignal = true
        runner.stop { TerminationSignals.exit(as: number) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(startSymphony(_:)):
            return !runner.isRunning && !runner.isStarting && machine.canStart && !restarting
        case #selector(stopSymphony(_:)):
            menuItem.title = runner.isStopping && !restarting ? StatusMenu.stoppingTitle : StatusMenu.stopTitle
            return runner.isRunning && machine.canStop && !runner.isStopping && !restarting
        case #selector(restartSymphony(_:)):
            let restartingOnly = restarting && restarter.machine.purpose == .restart
            menuItem.title = restartingOnly ? StatusMenu.restartingTitle : StatusMenu.restartTitle
            return !restarting && !updater.isUpdating && runner.isRunning && !runner.isStopping
                && StatusMenu.canRestart(machine.status)
        case #selector(restartNow(_:)):
            return restarter.machine.offersRestartNow
        case #selector(cancelRestart(_:)):
            return restarter.machine.canCancel
        case #selector(pauseDispatch(_:)):
            menuItem.title = controlInFlight == .pause ? StatusMenu.pausingTitle : StatusMenu.pauseTitle
            return controlInFlight == nil && !restarting && StatusMenu.canPause(machine.status)
        case #selector(resumeDispatch(_:)):
            menuItem.title = controlInFlight == .resume ? StatusMenu.resumingTitle : StatusMenu.resumeTitle
            return controlInFlight == nil && !restarting && StatusMenu.canResume(machine.status)
        case #selector(forceTicket(_:)):
            if case let .force(identifier)? = forceInFlight {
                menuItem.title = StatusMenu.forcingTitle(identifier)
            } else {
                menuItem.title = StatusMenu.forceTitle
            }
            return forceInFlight == nil && StatusMenu.canForce(machine.status)
        case #selector(stopForcing(_:)):
            return forceInFlight == nil && StatusMenu.canForce(machine.status)
        case #selector(openDashboard(_:)), #selector(openTerminalDashboard(_:)):
            switch machine.status {
            case .running, .paused:
                return true
            case .stopped, .starting, .error:
                return false
            }
        case #selector(openLogs(_:)):
            return FileManager.default.fileExists(atPath: runner.logURL.path)
        case #selector(checkForUpdates(_:)):
            menuItem.title = updates.isChecking ? UpdateMenu.checkingTitle : UpdateMenu.checkTitle
            return !updates.isChecking
        case #selector(showReleaseNotes(_:)):
            return availableRelease != nil
        case #selector(installUpdate(_:)):
            return availableRelease != nil && !updater.isUpdating && !restarting && !runner.isStarting
                && !runner.isStopping
                && updateBlocker == nil && (!runner.isRunning || StatusMenu.canRestart(machine.status))
        default:
            return true
        }
    }

    @objc private func startSymphony(_ sender: Any?) {
        runner.start { [weak self] error in
            guard let self, let error else { return }
            resumeWhenAnswering = false
            SymphonyRunner.showAlert(title: "Couldn't start Symphony", body: error.localizedDescription)
            if (error as? LaunchProblem)?.isFixedInSettings == true {
                settingsWindow.show()
            }
        }
    }

    @objc private func stopSymphony(_ sender: Any?) {
        runner.stop()
    }

    @objc private func restartSymphony(_ sender: Any?) {
        restart()
    }

    /// Restarts the app's Symphony gracefully: checks symphony.yml, pauses dispatch, waits for agent runs, stops,
    /// starts, and resumes once Symphony answers.
    func restart() {
        guard runner.isRunning, StatusMenu.canRestart(machine.status) else { return }
        controlError = nil
        restarter.restart(alreadyPaused: StatusMenu.canResume(machine.status))
    }

    @objc private func restartNow(_ sender: Any?) {
        restarter.handle(.restartNow)
    }

    @objc private func cancelRestart(_ sender: Any?) {
        restarter.handle(.cancel)
    }

    private var restarting: Bool { restarter.machine.isRestarting }

    @objc private func pauseDispatch(_ sender: Any?) {
        send(.pause)
    }

    @objc private func resumeDispatch(_ sender: Any?) {
        send(.resume)
    }

    /// Sends Pause or Resume to Symphony's control API, then polls so the icon and menu follow.
    private func send(_ action: ControlAction) {
        guard controlInFlight == nil else { return }
        controlInFlight = action
        controlError = nil
        showStatus()

        let stateRoot = runner.stateRoot
        Task {
            let result = await ControlAPI.send(
                action,
                stateRoot: stateRoot,
                fallback: AppStores.current.controlURLFallback
            )
            controlInFlight = nil
            if case let .failed(message) = result { controlError = message }
            showStatus()
            poller.pollNow()
        }
    }

    /// Asks for a ticket and forces it past the dispatch limits.
    @objc private func forceTicket(_ sender: Any?) {
        guard forceInFlight == nil else { return }
        let alert = NSAlert()
        alert.messageText = StatusMenu.forcePromptTitle
        alert.informativeText = StatusMenu.forcePromptMessage
        alert.addButton(withTitle: StatusMenu.forcePromptButton)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = StatusMenu.forcePromptPlaceholder
        guard let input = SymphonyRunner.prompt(alert, field: field), let identifier = StatusMenu.forceIdentifier(input)
        else { return }
        sendForce(.force(identifier))
    }

    @objc private func stopForcing(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        sendForce(.stopForcing(identifier))
    }

    /// Sends a force or stop-forcing request, then polls so the forced tickets follow. A failure shows an alert, as
    /// the request came from a prompt or a submenu the user has left.
    private func sendForce(_ action: ControlAction) {
        guard forceInFlight == nil else { return }
        forceInFlight = action

        let stateRoot = runner.stateRoot
        Task {
            let result = await ControlAPI.send(
                action,
                stateRoot: stateRoot,
                fallback: AppStores.current.controlURLFallback
            )
            forceInFlight = nil
            if case let .failed(message) = result { SymphonyRunner.showAlert(title: message, body: "") }
            poller.pollNow()
        }
    }

    @objc private func openRepos(_ sender: Any?) {
        reposWindow.show(status: machine.status)
    }

    @objc private func openSettings(_ sender: Any?) {
        settingsWindow.show()
    }

    @objc private func openDashboard(_ sender: Any?) {
        guard let url = StateRoot.controlURL(in: runner.stateRoot, fallback: AppStores.current.controlURLFallback) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Opens Terminal running `symphony dashboard`, through a `.command` script in the app's temporary folder.
    @objc private func openTerminalDashboard(_ sender: Any?) {
        let failureTitle = "Couldn't open the dashboard in Terminal"
        guard let terminal = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: TerminalDashboard.terminalBundleIdentifier
        ) else {
            SymphonyRunner.showAlert(title: failureTitle, body: "Terminal.app was not found.")
            return
        }
        do {
            let script = FileManager.default.temporaryDirectory.appendingPathComponent(TerminalDashboard.scriptFileName)
            try runner.terminalDashboardScript().write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) {
                _, error in
                guard let error else { return }
                DispatchQueue.main.async {
                    SymphonyRunner.showAlert(title: failureTitle, body: error.localizedDescription)
                }
            }
        } catch {
            SymphonyRunner.showAlert(title: failureTitle, body: error.localizedDescription)
        }
    }

    @objc private func openLogs(_ sender: Any?) {
        NSWorkspace.shared.open(runner.logURL)
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updates.check(manual: true)
    }

    @objc private func showReleaseNotes(_ sender: Any?) {
        guard let release = availableRelease else { return }
        UpdatePoller.showReleaseNotes(release)
    }

    /// Asks to confirm, then downloads and verifies the release, drains and stops Symphony, and hands over to the
    /// update helper, which swaps the app and relaunches it.
    @objc private func installUpdate(_ sender: Any?) {
        guard let release = availableRelease, updateBlocker == nil, !updater.isUpdating, !restarting else { return }
        let alert = NSAlert()
        alert.messageText = "\(UpdateMenu.installTitle(release))?"
        alert.informativeText = UpdateMenu.confirmation(release, symphonyRunning: runner.isRunning)
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        guard SymphonyRunner.confirm(alert) else { return }

        controlError = nil
        updater.prepare(release) { [weak self] update in self?.drainForUpdate(update) }
    }

    /// Pauses dispatch, waits for agent runs and stops Symphony, then hands over. A Symphony the app doesn't run
    /// is left alone.
    private func drainForUpdate(_ update: PreparedUpdate) {
        guard !runner.isStarting else {
            updater.fail("Symphony is starting, stopping or restarting; try again once it runs.")
            return
        }
        guard runner.isRunning else {
            handOff(update, symphonyStopped: false, resumeDispatch: false)
            return
        }
        guard !restarting, !runner.isStopping, StatusMenu.canRestart(machine.status) else {
            updater.fail("Symphony is starting, stopping or restarting; try again once it runs.")
            return
        }
        let alreadyPaused = StatusMenu.canResume(machine.status)
        restarter.drainForUpdate(alreadyPaused: alreadyPaused) { [weak self] stopped, pausedByUpdate in
            guard let self else { return }
            guard stopped else {
                updater.cancel()
                return
            }
            handOff(update, symphonyStopped: true, resumeDispatch: pausedByUpdate)
        }
    }

    /// Starts the update helper and quits. When the helper can't start, Symphony comes back as it was.
    private func handOff(_ update: PreparedUpdate, symphonyStopped: Bool, resumeDispatch: Bool) {
        do {
            try updater.handOff(update, symphonyStopped: symphonyStopped, resumeDispatch: resumeDispatch)
            NSApp.terminate(nil)
        } catch {
            updater.fail(error.localizedDescription)
            guard symphonyStopped else { return }
            // Cleared again when the start fails; resumes only once the started Symphony answers.
            resumeWhenAnswering = resumeDispatch
            startSymphony(nil)
        }
    }

    /// Why Update is off, nil when it is available.
    private var updateBlocker: String? {
        updater.blocker(developmentMode: AppStores.current.settingsStore().loadSettings().developmentMode)
    }

    /// Records the result of an update check. Background check failures change nothing; a check chosen by hand
    /// leaves its result under Check for Updates.
    private func showUpdate(_ result: UpdateCheckResult?, manual: Bool) {
        switch result {
        case let .available(release)?:
            availableRelease = release
        case .upToDate?:
            availableRelease = nil
        case .failed?, nil:
            break
        }
        if manual {
            updateResultItem.title = result.flatMap(UpdateMenu.manualResultLine) ?? ""
        }
        showUpdateItems()
    }

    /// Shows or hides the update items.
    private func showUpdateItems() {
        let release = availableRelease
        if let release {
            updateAvailableItem.title = UpdateMenu.availableTitle(release, current: updates.current)
            installUpdateItem.title = updater.isUpdating ? UpdateMenu.installingTitle : UpdateMenu.installTitle(release)
        }
        updateAvailableItem.isHidden = release == nil
        installUpdateItem.isHidden = release == nil
        releaseNotesItem.isHidden = release == nil

        let line = updater.menuLine ?? (release == nil ? nil : updateBlocker)
        updateLineItem.title = line ?? ""
        updateLineItem.isHidden = line == nil
        updateResultItem.isHidden = updateResultItem.title.isEmpty
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        showUpdateItems()
    }

    /// After an update, resumes the dispatch the update paused once the new Symphony answers.
    private func resumeIfAnswering(_ poll: StatusPoll) {
        guard resumeWhenAnswering, runner.isRunning, case .state = poll else { return }
        resumeWhenAnswering = false
        if StatusMenu.canResume(machine.status) { send(.resume) }
    }

    private func handle(_ event: StatusMachine.Event) {
        machine.handle(event)
        switch machine.status {
        case let .running(snapshot, _), let .paused(snapshot, _):
            settingsWindow.budget = snapshot.budget
        default:
            settingsWindow.budget = nil
        }
        // An open Repos window refreshes with each poll.
        reposWindow.update(status: machine.status)
        switch event {
        case .started:
            // A Pause or Resume error was about the Symphony that was running before.
            controlError = nil
        case let .exited(exit, _):
            controlError = nil
            // Before the restart machine sees the exit, which may start Symphony again for a failed update.
            resumeWhenAnswering = false
            restarter.handle(.exited(exit))
        case let .polled(poll):
            restarter.handle(.polled(poll))
            for notice in usageLimitNotices.notices(for: poll) {
                runner.notify(title: notice.title, body: notice.body)
            }
        }
        showStatus()

        switch event {
        case let .polled(poll):
            // Before a start below, so a poll taken before Symphony started can't count as its answer.
            resumeIfAnswering(poll)
            if startWhenStopped {
                startWhenStopped = false
                if machine.canStart {
                    startSymphony(nil)
                } else {
                    resumeWhenAnswering = false
                }
            }
        case .started, .exited:
            // Check straight away instead of waiting out the interval.
            poller.pollNow()
        }
    }

    /// Updates the icon, its tooltip and the status lines at the top of the menu.
    private func showStatus() {
        let status = machine.status

        if let button = statusItem?.button {
            let label = StatusMenu.iconLabel(for: status)
            let image = NSImage(systemSymbolName: StatusMenu.iconSymbolName(for: status), accessibilityDescription: label)
            image?.isTemplate = true
            button.image = image
            button.toolTip = label
        }

        statusTitleItem.title = StatusMenu.statusTitle(status)
        sourceItem.title = runner.sourceLine
        guard let menu = statusTitleItem.menu else { return }
        detailItems.forEach(menu.removeItem)
        let updating = restarter.machine.purpose == .update
        restartNowItem.title = updating ? UpdateMenu.updateNowTitle : StatusMenu.restartNowTitle
        cancelRestartItem.title = updating ? UpdateMenu.cancelUpdateTitle : StatusMenu.cancelRestartTitle
        restartNowItem.isHidden = !restarter.machine.offersRestartNow
        cancelRestartItem.isHidden = !restarter.machine.canCancel
        detailItems = StatusMenu.detailLines(
            status,
            waitingForKeychain: runner.isWaitingForKeychain,
            restartLine: restarter.machine.menuLine,
            controlError: controlError
        ).map { line in
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
        for (offset, item) in detailItems.enumerated() {
            menu.insertItem(item, at: menu.index(of: statusTitleItem) + 1 + offset)
        }
        showForced(in: menu)
    }

    /// Shows a row for each forced ticket, with a submenu to stop forcing it, and hides their heading while there
    /// are none. While the same tickets are listed, only the rows' titles change, so an open submenu stays open.
    private func showForced(in menu: NSMenu) {
        let tickets = StatusMenu.forcedTickets(machine.status)
        forcedTitleItem.isHidden = tickets.isEmpty
        if forcedItems.map({ $0.representedObject as? String }) == tickets.map(\.identifier) {
            zip(forcedItems, tickets).forEach { item, ticket in item.title = StatusMenu.forcedLine(ticket) }
            return
        }
        forcedItems.forEach(menu.removeItem)
        forcedItems = tickets.map { ticket in
            let stop = menuItem(StatusMenu.stopForcingTitle(ticket.identifier), action: #selector(stopForcing(_:)))
            stop.representedObject = ticket.identifier
            let submenu = NSMenu()
            submenu.addItem(stop)
            let item = NSMenuItem(title: StatusMenu.forcedLine(ticket), action: nil, keyEquivalent: "")
            item.representedObject = ticket.identifier
            item.submenu = submenu
            return item
        }
        // Taken once: each row goes in above Force a ticket…, which moves down.
        let start = menu.index(of: forceItem)
        for (offset, item) in forcedItems.enumerated() {
            menu.insertItem(item, at: start + offset)
        }
    }

    private func menuItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }
}
