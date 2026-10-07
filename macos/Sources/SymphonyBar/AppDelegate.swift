import AppKit
import Combine
import SymphonyBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem?
    private let runner = SymphonyRunner()
    private lazy var settingsWindow = SettingsWindowController(secrets: runner.secrets)
    private lazy var reposWindow = ReposWindowController(secrets: runner.secrets)
    private let poller = StatusPoller()
    /// The one client the Symphony window's views read Symphony's local API through.
    private lazy var apiClient = LiveAPIClient(
        fetch: LiveAPIClient.fetch(
            base: { [weak self] in
                let stateRoot = self?.poller.stateRoot() ?? StateRoot.locate(environment: AppStores.current.environment)
                return StateRoot.controlURL(in: stateRoot, fallback: AppStores.current.apiFallback)
            },
            transport: AppStores.current.apiTransport
        )
    )
    private lazy var symphonyWindow = SymphonyWindowController(client: apiClient)
    /// Notifies each new Inbox item and Needs attention problem from the window's state polls (D14).
    private lazy var inboxNotifications = InboxNotificationCenter(defaults: AppStores.current.defaults)
    private var stateSubscription: AnyCancellable?
    private lazy var restarter = RestartController(runner: runner, poller: poller)
    private var machine = StatusMachine()
    private var usageLimitNotices = UsageLimitNotices()
    private let statusTitleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let sourceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var restartNowItem = menuItem(StatusMenu.restartNowTitle, action: #selector(restartNow(_:)))
    private lazy var cancelRestartItem = menuItem(StatusMenu.cancelRestartTitle, action: #selector(cancelRestart(_:)))
    private var detailItems: [NSMenuItem] = []
    /// The "Waiting on you" heading, a row per waiting ticket and "N more…", under the status lines.
    private var waitingItems: [NSMenuItem] = []
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
    /// The acceptance gate's kill switch: a row for each repository the gate runs on, under Pause and Resume.
    private var gateItems: [NSMenuItem] = []
    private let updates = UpdatePoller()
    /// The newer release, while there is one.
    private var availableRelease: Release?
    /// The latest release the last successful check found, newer or not.
    private var latestRelease: Release?
    private let updateAvailableItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let releaseNotesItem = NSMenuItem(title: UpdateMenu.releaseNotesTitle, action: nil, keyEquivalent: "")
    /// The result of a Check for Updates chosen by hand, under that item.
    private let updateResultItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var updater = UpdateController(current: updates.current)
    private lazy var installUpdateItem = menuItem("", action: #selector(installUpdate(_:)))
    private lazy var skipUpdateItem = menuItem(UpdateMenu.skipTitle, action: #selector(skipUpdate(_:)))
    /// Under Update to vX: the update's progress, why it failed, or why Update is off.
    private let updateLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// What the last update or rollback did, which opens the release notes of the version it names.
    private lazy var updateOutcomeItem = menuItem("", action: #selector(showOutcomeNotes(_:)))
    /// Set when the app started Symphony after an update: resume dispatch once it answers.
    private var resumeWhenAnswering = false
    /// True until the dispatch an update paused is resumed: kept across the health check's restarts of Symphony.
    private var resumeAfterUpdate = false
    /// Checks Symphony on the build an update relaunched, and asks for a rollback when it isn't healthy.
    private var health = UpdateHealthCheck()
    /// The update the health check is about.
    private var checkedUpdate: PendingUpdate?
    /// Decides when Automatically when idle or Automatically at a set time installs a release.
    private var autoUpdater = AutoUpdater()
    /// Fires at the set time, so the attempt doesn't wait for the next status poll.
    private var setTimeTimer: Timer?
    /// Stops an owned Symphony before the app exits on SIGTERM, SIGINT or SIGHUP.
    private var terminationSignals: TerminationSignals?
    private var exitingOnSignal = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install(
            settings: menuItem(
                StatusMenu.settingsTitle,
                action: #selector(openSettings(_:)),
                keyEquivalent: StatusMenu.settingsKeyEquivalent
            ),
            view: symphonyWindow.viewMenu()
        )
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
        menu.addItem(
            menuItem(
                StatusMenu.openSymphonyTitle,
                action: #selector(openSymphony(_:)),
                keyEquivalent: StatusMenu.openSymphonyKeyEquivalent
            )
        )
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
        updateAvailableItem.action = #selector(showReleaseNotes(_:))
        updateAvailableItem.target = self
        releaseNotesItem.action = #selector(showReleaseNotes(_:))
        releaseNotesItem.target = self
        updateResultItem.isEnabled = false
        updateLineItem.isEnabled = false
        menu.addItem(updateAvailableItem)
        menu.addItem(installUpdateItem)
        menu.addItem(updateLineItem)
        menu.addItem(updateOutcomeItem)
        menu.addItem(skipUpdateItem)
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
        let developer = NSMenu(title: StatusMenu.developerTitle)
        developer.addItem(menuItem(StatusMenu.openTerminalDashboardTitle, action: #selector(openTerminalDashboard(_:))))
        developer.addItem(menuItem(StatusMenu.openLogsTitle, action: #selector(openLogs(_:))))
        developer.addItem(menuItem(StatusMenu.openWebDashboardTitle, action: #selector(openWebDashboard(_:))))
        let developerItem = NSMenuItem(title: StatusMenu.developerTitle, action: nil, keyEquivalent: "")
        developerItem.submenu = developer
        menu.addItem(developerItem)
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
        restarter.onChange = { [weak self] in
            self?.showStatus()
            self?.reposWindow.restartChanged()
        }
        // Symphony reads its secrets only at start; restart() does nothing while it isn't running.
        settingsWindow.onSecretsChanged = { [weak self] in self?.restart() }
        updater.onChange = { [weak self] in self?.showUpdateItems() }
        poller.stateRoot = { [weak self] in
            self?.runner.stateRoot ?? StateRoot.locate(environment: AppStores.current.environment)
        }
        reposWindow.stateRoot = poller.stateRoot
        reposWindow.restart = { [weak self] in self?.restart() }
        reposWindow.start = { [weak self] in self?.startSymphony(nil) }
        reposWindow.canStart = { [weak self] in
            guard let self else { return false }
            return !runner.isRunning && !runner.isStarting && machine.canStart && !restarting
        }
        reposWindow.openSettings = { [weak self] in self?.settingsWindow.show() }
        reposWindow.restartMachine = { [weak self] in self?.restarter.machine ?? RestartMachine() }
        reposWindow.restartNow = { [weak self] in self?.restartNow(nil) }
        reposWindow.cancelRestart = { [weak self] in self?.cancelRestart(nil) }
        symphonyWindow.appVersion = updates.current.version ?? ""
        symphonyWindow.stateRoot = poller.stateRoot
        symphonyWindow.onAction = { [weak self] action in self?.perform(action) }
        symphonyWindow.openRepos = { [weak self] in self?.openRepos(nil) }
        symphonyWindow.openWebDashboard = { [weak self] in self?.openWebDashboard(nil) }
        symphonyWindow.canOpenWebDashboard = { [weak self] in self?.canOpenWebDashboard ?? false }
        symphonyWindow.canOpenLogs = { [weak self] in self?.canOpenLogs ?? false }
        symphonyWindow.afterControl = { [weak self] in self?.poller.pollNow() }
        symphonyWindow.update(status: machine.status, configPath: configPath)
        inboxNotifications.onOpen = { [weak self] issueID in
            guard let self else { return }
            if let issueID { symphonyWindow.showInbox(selecting: issueID) } else { symphonyWindow.show(view: .overview) }
        }
        inboxNotifications.start()
        stateSubscription = apiClient.$stateJSON
            .compactMap { $0.flatMap(OverviewState.decode) }
            .sink { [weak self] state in self?.inboxNotifications.update(state) }
        apiClient.start()
        poller.onPoll = { [weak self] poll in
            guard let self else { return StatusMachine.pollInterval }
            handle(.polled(poll))
            return machine.nextPollInterval
        }

        // After an update or a rollback, bring Symphony back as it was before the app quit.
        let startAfterUpdate = relaunched(
            UpdateRelaunch(
                pending: updater.pending.take(),
                rollback: updater.rollbacks.take(),
                runningBuild: updates.current.build,
                runningBundle: updater.bundleFileNumber
            )
        )

        // First run: nothing to start yet, so ask for settings. Reads only the settings, not the secrets.
        let store = AppStores.current.settingsStore()
        store.migrateDevelopmentMode(embeddedSymphonyAvailable: SymphonyRunner.hasEmbeddedSymphony)
        let settings = store.loadSettings()
        if settings.needsSetup {
            settingsWindow.show()
        } else if let checkedUpdate {
            // Check the new build before Symphony starts on it; the check starts it once symphony.yml passes.
            performHealth(
                health.begin(version: checkedUpdate.version, startsSymphony: settings.startOnLaunch || startAfterUpdate)
            )
        } else if settings.startOnLaunch || startAfterUpdate {
            // Wait for the first poll, so a Symphony already running from the CLI is attached to, not started twice.
            startWhenStopped = true
            resumeWhenAnswering = resumeAfterUpdate
        }
        poller.start()

        updates.onResult = { [weak self] result, manual in self?.showUpdate(result, manual: manual) }
        showUpdate(nil, manual: false)
        updates.start()
        QAScriptDriver.startIfScripted(menu: menu) { [weak self] in self?.runner.pid }
    }

    /// Acts on what the quitting app recorded before an update or a rollback, and returns whether Symphony ran before
    /// the update, so the app starts it.
    private func relaunched(_ relaunch: UpdateRelaunch) -> Bool {
        switch relaunch {
        case .none:
            return false
        case let .notReplaced(pending):
            updater.removeDownloads()
            let message = UpdateMenu.rolledBackMessage(pending, logPath: updater.helperLogPath)
            DispatchQueue.main.async { SymphonyRunner.showAlert(title: UpdateMenu.failedTitle, body: message) }
            resumeAfterUpdate = pending.resumeDispatch
            return pending.startSymphony
        case let .checkHealth(pending):
            updater.removeDownloads()
            checkedUpdate = pending
            resumeAfterUpdate = pending.resumeDispatch
            return pending.startSymphony
        case let .rolledBack(record):
            updater.rolledBack = record
            notifyAfterLaunch(.rolledBack(record, restoredVersion: updates.current.version))
            resumeAfterUpdate = record.resumeDispatch
            return record.startSymphony
        case let .rollbackFailed(record):
            // Still the build that failed its check: say how to roll back by hand, and don't start Symphony for the
            // update. Start Symphony at launch still applies.
            let problem = RollbackProblem.swapFailed(logPath: updater.rollbackLogPath)
            updater.notice = UpdateMenu.rollbackFailedLine(
                version: record.version,
                reason: record.reason,
                problem: problem
            )
            notifyAfterLaunch(.rollbackFailed(version: record.version, reason: record.reason, problem: problem))
            return false
        }
    }

    private func handleHealth(_ event: UpdateHealthCheck.Event) {
        let phase = health.phase
        let effects = health.handle(event)
        // Most polls change nothing; only a new step or an effect refreshes the update items.
        guard health.phase != phase || !effects.isEmpty else { return }
        performHealth(effects)
    }

    /// Carries out what the update's health check asks for.
    private func performHealth(_ effects: [UpdateHealthCheck.Effect]) {
        for effect in effects {
            switch effect {
            case .checkConfig:
                runner.checkLaunch { [weak self] launch in
                    switch launch {
                    case let .success(launch):
                        Task { self?.handleHealth(.configChecked(await ConfigCheck.run(launch))) }
                    case let .failure(error):
                        self?.handleHealth(.configChecked(.failed(error.localizedDescription)))
                    }
                }
            case .start:
                // On the next poll, so a Symphony already running from the CLI is attached to, not started twice.
                startWhenStopped = true
                resumeWhenAnswering = resumeAfterUpdate
                poller.pollNow()
            case .healthy:
                guard let checkedUpdate else { break }
                let update = LastUpdate(checkedUpdate, installedAt: Date())
                updater.lastUpdates.save(update)
                // A manual update you just confirmed needs no notification.
                if checkedUpdate.automatic { notify(.updated(update)) }
            case let .rollBack(failure):
                rollBack(failure)
            }
        }
        showUpdateItems()
    }

    /// The updated build isn't healthy: pins it, stops Symphony and hands over to the helper, which puts
    /// `Symphony (previous).app` back and relaunches it. Without a previous app, or when the helper can't start, the
    /// menu says how to roll back by hand.
    private func rollBack(_ failure: UpdateHealthFailure) {
        guard let update = checkedUpdate else { return }
        let record = RollbackRecord(
            build: update.toBuild,
            version: update.version,
            reason: failure.reason(logPath: runner.logPath),
            startSymphony: update.startSymphony,
            resumeDispatch: resumeAfterUpdate,
            details: update.details,
            bundle: updater.bundleFileNumber
        )
        // A crash loop can follow the healthy part of the check: the build put back doesn't say it was updated to.
        updater.lastUpdates.clear()
        startWhenStopped = false
        resumeWhenAnswering = false
        guard updater.hasPreviousApp else {
            rollbackFailed(record, .noPreviousApp)
            return
        }
        runner.stop { [weak self] in
            guard let self else { return }
            if let problem = updater.rollBack(record) {
                rollbackFailed(record, problem)
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    private func rollbackFailed(_ record: RollbackRecord, _ problem: RollbackProblem) {
        updater.pin(record)
        updater.notice = UpdateMenu.rollbackFailedLine(version: record.version, reason: record.reason, problem: problem)
        notify(.rollbackFailed(version: record.version, reason: record.reason, problem: problem))
    }

    private func notify(_ notice: UpdateNotice) {
        runner.notify(title: notice.title, body: notice.body)
    }

    /// Notifies once launch has finished, so a scripted QA run has started and records the notice.
    private func notifyAfterLaunch(_ notice: UpdateNotice) {
        DispatchQueue.main.async { [weak self] in self?.notify(notice) }
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
            return canStartNow
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
        case #selector(openTerminalDashboard(_:)):
            return isAnswering
        case #selector(openWebDashboard(_:)):
            return canOpenWebDashboard
        case #selector(openWaitingTicket(_:)):
            return menuItem.representedObject is URL
        case #selector(openLogs(_:)):
            return canOpenLogs
        case #selector(checkForUpdates(_:)):
            menuItem.title = updates.isChecking ? UpdateMenu.checkingTitle : UpdateMenu.checkTitle
            return !updates.isChecking
        case #selector(showReleaseNotes(_:)):
            return availableRelease != nil
        case #selector(showOutcomeNotes(_:)):
            return updateOutcome?.release(latest: latestRelease) != nil
        case #selector(skipUpdate(_:)):
            return availableRelease != nil && !updater.isUpdating
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
            handleHealth(.notStarted)
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
            let result = await AppStores.current.sendControl(action, stateRoot: stateRoot)
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
            let result = await AppStores.current.sendControl(action, stateRoot: stateRoot)
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

    @objc private func openSymphony(_ sender: Any?) {
        symphonyWindow.show()
    }

    /// Acts on a button of the Symphony window's placeholder (D0).
    private func perform(_ action: WindowState.Action) {
        switch action {
        case .startSymphony:
            if canStartNow { startSymphony(nil) }
        case .openLogs:
            if canOpenLogs { openLogs(nil) }
        case .restartSymphony:
            switch StatusMenu.restartPath(machine.status, appRunsSymphony: runner.isRunning) {
            case .graceful:
                restart()
            case .stopAndStart:
                guard !restarting, !runner.isStopping, !updater.isUpdating else { return }
                runner.stop { [weak self] in self?.startSymphony(nil) }
            case .start:
                if canStartNow { startSymphony(nil) }
            case nil:
                break
            }
        case .openSettings:
            settingsWindow.show()
        }
    }

    private var canStartNow: Bool {
        !runner.isRunning && !runner.isStarting && machine.canStart && !restarting
    }

    private var isAnswering: Bool {
        switch machine.status {
        case .running, .paused:
            return true
        case .stopped, .starting, .error:
            return false
        }
    }

    /// The web dashboard opens while Symphony answers at a control URL; never the API fixtures' made-up one.
    private var canOpenWebDashboard: Bool {
        isAnswering && StateRoot.controlURL(in: runner.stateRoot, fallback: AppStores.current.controlURLFallback) != nil
    }

    private var canOpenLogs: Bool {
        FileManager.default.fileExists(atPath: runner.logURL.path)
    }

    @objc private func openWebDashboard(_ sender: Any?) {
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

    /// Shows the notes of the version the last update installed or the last rollback took out.
    @objc private func showOutcomeNotes(_ sender: Any?) {
        guard let outcome = updateOutcome, let release = outcome.release(latest: latestRelease) else { return }
        UpdatePoller.showReleaseNotes(release, message: outcome.notesMessage)
    }

    /// The rollback that put this build back, or else the update that installed it while its line shows.
    private var updateOutcome: UpdateOutcome? {
        UpdateOutcome(
            rolledBack: updater.rolledBack,
            lastUpdate: updater.lastUpdates.shown(runningBuild: updates.current.build)
        )
    }

    /// Records the available release as skipped: the menu shows it as skipped, and Update to vX still installs it.
    @objc private func skipUpdate(_ sender: Any?) {
        guard let release = availableRelease, !updater.isUpdating else { return }
        updater.skips.record(SkippedRelease(release, reason: .skipped))
        showUpdateItems()
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
        // Installing by hand overrides Skip This Version for this build.
        updater.skips.clear(build: release.build)
        updater.prepare(release) { [weak self] update in self?.drainForUpdate(update) }
    }

    /// Pauses dispatch, waits for agent runs and stops Symphony, then hands over. A Symphony the app doesn't run
    /// is left alone. An automatic update passes `automaticRunsTimeout`: see `RestartController.drainForUpdate`.
    private func drainForUpdate(_ update: PreparedUpdate, automaticRunsTimeout: TimeInterval? = nil) {
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
        restarter.drainForUpdate(alreadyPaused: alreadyPaused, automaticRunsTimeout: automaticRunsTimeout) {
            [weak self] stopped, pausedByUpdate in
            guard let self else { return }
            guard stopped else {
                updater.cancel()
                if restarter.machine.postponed { autoUpdater.postponed() }
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
            latestRelease = release
        case let .upToDate(release)?:
            availableRelease = nil
            latestRelease = release
        case .failed?, nil:
            break
        }
        if manual {
            updateResultItem.title = result.flatMap(UpdateMenu.manualResultLine) ?? ""
        }
        showUpdateItems()
        if let result { performAutoUpdate(autoUpdater.checked(result, autoUpdateContext)) }
    }

    /// What `AutoUpdater` decides from: the update settings, the release the last check found, and what Symphony is
    /// doing.
    private var autoUpdateContext: AutoUpdater.Context {
        let settings = AppStores.current.settingsStore().loadSettings()
        let busy = restarting || updater.isUpdating || runner.isStarting || runner.isStopping || startWhenStopped
            || resumeWhenAnswering || controlInFlight != nil || health.isChecking
        return AutoUpdater.Context(
            mode: settings.updateMode,
            time: settings.updateTime,
            offer: availableRelease.map { UpdateOffer($0, skips: updater.skips) },
            blocker: updater.blocker(developmentMode: settings.developmentMode),
            activity: SymphonyActivity(status: machine.status, symphonyRunning: runner.isRunning, busy: busy),
            runsTimeout: TimeInterval(runner.restartTimeoutMinutes * 60)
        )
    }

    /// Lets the automatic update modes act, on each status poll and at the set time, then sets the timer for the next
    /// set time.
    private func autoUpdateTick() {
        let action = autoUpdater.tick(autoUpdateContext, now: Date(), calendar: .current)
        scheduleSetTimeTimer()
        performAutoUpdate(action)
    }

    private func scheduleSetTimeTimer() {
        let next = autoUpdater.nextSetTime
        guard setTimeTimer?.isValid != true || setTimeTimer?.fireDate != next else { return }
        setTimeTimer?.invalidate()
        setTimeTimer = nil
        guard let next else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { self.autoUpdateTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        setTimeTimer = timer
    }

    private func performAutoUpdate(_ action: AutoUpdater.Action?) {
        switch action {
        case .check?:
            updates.check(manual: false)
        case let .install(release, runsTimeout)?:
            // No confirmation: a failure shows on the update line, not in an alert.
            guard !updater.isUpdating, !restarting else { return }
            controlError = nil
            updater.prepare(release, automatic: true) { [weak self] update in
                self?.drainForUpdate(update, automaticRunsTimeout: runsTimeout)
            }
        case nil:
            break
        }
    }

    /// Shows or hides the update items.
    private func showUpdateItems() {
        let release = availableRelease
        let offer = release.map { UpdateOffer($0, skips: updater.skips) }
        if let offer {
            updateAvailableItem.title = offer.title(current: updates.current)
            installUpdateItem.title = updater.isUpdating ? UpdateMenu.installingTitle : offer.installTitle
        }
        updateAvailableItem.isHidden = release == nil
        installUpdateItem.isHidden = release == nil
        skipUpdateItem.isHidden = offer?.offersSkip != true
        releaseNotesItem.isHidden = release == nil

        let line = updater.menuLine ?? health.menuLine ?? (release == nil ? nil : updateBlocker)
        updateLineItem.title = line ?? ""
        updateLineItem.isHidden = line == nil
        let outcome = updateOutcome
        updateOutcomeItem.title = outcome?.menuTitle ?? ""
        updateOutcomeItem.isHidden = outcome == nil
        updateResultItem.isHidden = updateResultItem.title.isEmpty
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        showUpdateItems()
        showGateItems(in: menu)
    }

    /// Shows a row for each repository whose acceptance gate runs, read from symphony.yml each time the menu opens,
    /// with a submenu to switch it to Shadow or Off. Nothing shows when the file can't be read.
    private func showGateItems(in menu: NSMenu) {
        gateItems.forEach(menu.removeItem)
        let file = SymphonyConfigFile(path: configPath)
        guard let global = try? file.readAcceptanceGateMode(), let entries = try? file.readRepositories() else {
            gateItems = []
            return
        }
        gateItems = AcceptanceGate.menuItems(global: global, entries: entries).map { gate in
            let submenu = NSMenu()
            for mode in AcceptanceGate.MenuItem.choices {
                let item = menuItem(mode.title, action: #selector(switchAcceptanceGate(_:)))
                item.representedObject = GateSwitch(key: gate.key, mode: mode)
                item.state = gate.mode == mode ? .on : .off
                submenu.addItem(item)
            }
            let item = NSMenuItem(title: gate.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            return item
        }
        guard let resume = menu.items.firstIndex(where: { $0.action == #selector(resumeDispatch(_:)) }) else { return }
        for (offset, item) in gateItems.enumerated() {
            menu.insertItem(item, at: resume + 1 + offset)
        }
    }

    /// The repository, or the global mode for a nil key, and the mode a kill switch item sets.
    private struct GateSwitch {
        let key: String?
        let mode: AcceptanceGateMode
    }

    /// Writes the mode to symphony.yml straight away, without `symphony check`, so the kill switch can't wait on or
    /// be refused by it. Symphony reads the mode again on its next poll.
    @objc private func switchAcceptanceGate(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? GateSwitch else { return }
        let file = SymphonyConfigFile(path: configPath)
        do {
            if let key = target.key {
                try file.writeRepositoryAcceptanceGateMode(.mode(target.mode), of: key)
            } else {
                try file.writeAcceptanceGateMode(target.mode)
            }
        } catch {
            SymphonyRunner.showAlert(title: "Couldn't switch the acceptance gate", body: error.localizedDescription)
        }
        reposWindow.update(status: machine.status)
    }

    private var configPath: String {
        AppStores.current.settingsStore().loadSettings().configPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// After an update, resumes the dispatch the update paused once the new Symphony answers.
    private func resumeIfAnswering(_ poll: StatusPoll) {
        guard resumeWhenAnswering, runner.isRunning, case .state = poll else { return }
        resumeWhenAnswering = false
        resumeAfterUpdate = false
        if StatusMenu.canResume(machine.status) { send(.resume) }
    }

    private func handle(_ event: StatusMachine.Event) {
        machine.handle(event)
        switch machine.status {
        case let .running(snapshot, _), let .paused(snapshot, _):
            settingsWindow.budget = snapshot.budget
            settingsWindow.state = snapshot
        default:
            settingsWindow.budget = nil
            settingsWindow.state = nil
        }
        // An open Repos window refreshes with each poll.
        reposWindow.update(status: machine.status)
        symphonyWindow.update(status: machine.status, configPath: configPath)
        switch event {
        case .started:
            // A Pause or Resume error was about the Symphony that was running before.
            controlError = nil
            handleHealth(.started)
        case let .exited(exit, requested):
            controlError = nil
            // Before the restart machine sees the exit, which may start Symphony again for a failed update.
            resumeWhenAnswering = false
            restarter.handle(.exited(exit))
            // Within the window after an update, an unexpected exit starts Symphony again, or rolls back.
            handleHealth(.exited(requested: requested))
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
            handleHealth(.polled(poll))
            resumeIfAnswering(poll)
            if startWhenStopped {
                startWhenStopped = false
                if machine.canStart {
                    startSymphony(nil)
                } else {
                    resumeWhenAnswering = false
                    handleHealth(.notStarted)
                }
            }
            autoUpdateTick()
        case .started, .exited:
            // Check straight away instead of waiting out the interval.
            poller.pollNow()
        }
    }

    /// Updates the icon, its tooltip and the status lines at the top of the menu.
    private func showStatus() {
        let status = machine.status

        if let button = statusItem?.button {
            let badge = StatusMenu.badgeCount(for: status)
            let label = StatusMenu.iconLabel(for: status, badge: badge)
            let image = NSImage(systemSymbolName: StatusMenu.iconSymbolName(for: status), accessibilityDescription: label)
            image?.isTemplate = true
            button.image = badge == nil ? image : image.map(Self.badged)
            button.toolTip = label
        }
        symphonyWindow.dockBadge = StatusMenu.badgeCount(for: status)

        statusTitleItem.title = StatusMenu.statusTitle(status)
        sourceItem.title = runner.sourceLine
        guard let menu = statusTitleItem.menu else { return }
        detailItems.forEach(menu.removeItem)
        let updating = restarter.machine.purpose.isUpdate
        restartNowItem.title = updating ? UpdateMenu.updateNowTitle : StatusMenu.restartNowTitle
        cancelRestartItem.title = updating ? UpdateMenu.cancelUpdateTitle : StatusMenu.cancelRestartTitle
        restartNowItem.isHidden = !restarter.machine.offersRestartNow
        cancelRestartItem.isHidden = !restarter.machine.canCancel
        detailItems = StatusMenu.detailLines(
            status,
            slowToAnswer: machine.slowToAnswer,
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
        showWaiting(in: menu)
        showForced(in: menu)
    }

    /// Lists the tickets waiting on the operator under the status lines (D13): each row, with its kind's symbol and
    /// age, opens the window on it in the Inbox, and "N more…" opens the Inbox. Nothing shows while none waits.
    private func showWaiting(in menu: NSMenu) {
        waitingItems.forEach(menu.removeItem)
        let waiting = StatusMenu.waitingMenu(machine.status)
        guard !waiting.tickets.isEmpty else {
            waitingItems = []
            return
        }
        let heading = NSMenuItem(title: StatusMenu.waitingTitle, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        let rows = waiting.tickets.map { ticket in
            let item = menuItem(StatusMenu.waitingLine(ticket), action: #selector(openWaitingTicket(_:)))
            item.representedObject = ticket.issueID ?? ticket.identifier
            item.toolTip = ticket.title
            item.image = NSImage(systemSymbolName: ticket.kind.symbol, accessibilityDescription: StatusMenu.kindLabel(ticket.kind))
            return item
        }
        let more = waiting.moreTitle.map { [menuItem($0, action: #selector(openWaitingTicket(_:)))] } ?? []
        waitingItems = [.separator(), heading] + rows + more
        let start = menu.index(of: sourceItem) + 1
        for (offset, item) in waitingItems.enumerated() {
            menu.insertItem(item, at: start + offset)
        }
    }

    @objc private func openWaitingTicket(_ sender: NSMenuItem) {
        symphonyWindow.showInbox(selecting: sender.representedObject as? String)
    }

    /// The menu bar icon with a dot in its top right corner while the Inbox isn't empty. Drawn per appearance, so
    /// the symbol keeps the menu bar's text color while the dot keeps `status.you`'s orange.
    private static func badged(_ symbol: NSImage) -> NSImage {
        let size = NSSize(width: max(symbol.size.width, 18), height: max(symbol.size.height, 18))
        let image = NSImage(size: size, flipped: false) { rect in
            let symbolRect = NSRect(
                x: (rect.width - symbol.size.width) / 2, y: (rect.height - symbol.size.height) / 2,
                width: symbol.size.width, height: symbol.size.height
            )
            let tinted = NSImage(size: symbol.size, flipped: false) { tintRect in
                symbol.draw(in: tintRect)
                NSColor.labelColor.set()
                tintRect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: symbolRect)
            let dot = NSRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 7, height: 7)
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.accessibilityDescription = symbol.accessibilityDescription
        return image
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
