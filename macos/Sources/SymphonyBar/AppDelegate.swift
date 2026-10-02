import AppKit
import SymphonyBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem?
    private let settingsWindow = SettingsWindowController()
    private let runner = SymphonyRunner()
    private let poller = StatusPoller()
    private var machine = StatusMachine()
    private let statusTitleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let sourceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var detailItems: [NSMenuItem] = []
    private var startWhenStopped = false
    /// The Pause or Resume request under way, if any.
    private var controlInFlight: ControlAction?
    /// Why the last Pause or Resume failed, shown under the status until the next attempt.
    private var controlError: String?
    private let updates = UpdatePoller()
    /// The newer release, while there is one.
    private var availableRelease: Release?
    private let updateAvailableItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let releaseNotesItem = NSMenuItem(title: UpdateMenu.releaseNotesTitle, action: nil, keyEquivalent: "")
    /// The result of a Check for Updates chosen by hand, under that item.
    private let updateResultItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        EditMenu.install()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        statusTitleItem.isEnabled = false
        menu.addItem(statusTitleItem)
        sourceItem.isEnabled = false
        menu.addItem(sourceItem)
        menu.addItem(.separator())
        menu.addItem(menuItem(StatusMenu.startTitle, action: #selector(startSymphony(_:))))
        menu.addItem(menuItem(StatusMenu.stopTitle, action: #selector(stopSymphony(_:))))
        menu.addItem(.separator())
        menu.addItem(menuItem(StatusMenu.pauseTitle, action: #selector(pauseDispatch(_:))))
        menu.addItem(menuItem(StatusMenu.resumeTitle, action: #selector(resumeDispatch(_:))))
        menu.addItem(.separator())
        menu.addItem(menuItem(StatusMenu.openDashboardTitle, action: #selector(openDashboard(_:))))
        menu.addItem(menuItem(StatusMenu.openLogsTitle, action: #selector(openLogs(_:))))
        menu.addItem(.separator())
        updateAvailableItem.action = #selector(showReleaseNotes(_:))
        updateAvailableItem.target = self
        releaseNotesItem.action = #selector(showReleaseNotes(_:))
        releaseNotesItem.target = self
        updateResultItem.isEnabled = false
        menu.addItem(updateAvailableItem)
        menu.addItem(releaseNotesItem)
        menu.addItem(menuItem(UpdateMenu.checkTitle, action: #selector(checkForUpdates(_:))))
        menu.addItem(updateResultItem)
        menu.addItem(.separator())
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
        // Start, Stop, Pause, Resume and the open items are enabled by validateMenuItem; the status lines stay disabled.
        menu.autoenablesItems = true
        item.menu = menu

        statusItem = item
        showStatus()

        runner.onEvent = { [weak self] event in self?.handle(event) }
        poller.stateRoot = { [weak self] in self?.runner.stateRoot ?? StateRoot.locate() }
        poller.onPoll = { [weak self] poll in
            guard let self else { return StatusMachine.pollInterval }
            handle(.polled(poll))
            return machine.nextPollInterval
        }

        // First run: nothing to start yet, so ask for settings. Reads only UserDefaults, not the Keychain.
        let store = SettingsStore()
        store.migrateDevelopmentMode(embeddedSymphonyAvailable: SymphonyRunner.hasEmbeddedSymphony)
        let settings = store.loadSettings()
        if settings.needsSetup {
            settingsWindow.show()
        } else if settings.startOnLaunch {
            // Wait for the first poll, so a Symphony already running from the CLI is attached to, not started twice.
            startWhenStopped = true
        }
        poller.start()

        updates.onResult = { [weak self] result, manual in self?.showUpdate(result, manual: manual) }
        showUpdate(nil, manual: false)
        updates.start()
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
                SymphonyRunner.activateApp()
                guard alert.runModal() == .alertFirstButtonReturn else {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            runner.stop { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(startSymphony(_:)):
            return !runner.isRunning && machine.canStart
        case #selector(stopSymphony(_:)):
            menuItem.title = runner.isStopping ? StatusMenu.stoppingTitle : StatusMenu.stopTitle
            return runner.isRunning && machine.canStop && !runner.isStopping
        case #selector(pauseDispatch(_:)):
            menuItem.title = controlInFlight == .pause ? StatusMenu.pausingTitle : StatusMenu.pauseTitle
            return controlInFlight == nil && StatusMenu.canPause(machine.status)
        case #selector(resumeDispatch(_:)):
            menuItem.title = controlInFlight == .resume ? StatusMenu.resumingTitle : StatusMenu.resumeTitle
            return controlInFlight == nil && StatusMenu.canResume(machine.status)
        case #selector(openDashboard(_:)):
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
        default:
            return true
        }
    }

    @objc private func startSymphony(_ sender: Any?) {
        do {
            try runner.start()
        } catch {
            SymphonyRunner.showAlert(title: "Couldn't start Symphony", body: error.localizedDescription)
            if (error as? LaunchProblem)?.isFixedInSettings == true {
                settingsWindow.show()
            }
        }
    }

    @objc private func stopSymphony(_ sender: Any?) {
        runner.stop()
    }

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
            let result = await ControlAPI.send(action, stateRoot: stateRoot)
            controlInFlight = nil
            if case let .failed(message) = result { controlError = message }
            showStatus()
            poller.pollNow()
        }
    }

    @objc private func openSettings(_ sender: Any?) {
        settingsWindow.show()
    }

    @objc private func openDashboard(_ sender: Any?) {
        NSWorkspace.shared.open(StateRoot.controlURL(in: runner.stateRoot))
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

    /// Shows or hides the update items. Background check failures change nothing; a check chosen by hand
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
        if let release = availableRelease {
            updateAvailableItem.title = UpdateMenu.availableTitle(release, current: updates.current)
        }
        updateAvailableItem.isHidden = availableRelease == nil
        releaseNotesItem.isHidden = availableRelease == nil

        if manual {
            updateResultItem.title = result.flatMap(UpdateMenu.manualResultLine) ?? ""
        }
        updateResultItem.isHidden = updateResultItem.title.isEmpty
    }

    private func handle(_ event: StatusMachine.Event) {
        machine.handle(event)
        switch event {
        case .started, .exited:
            // A Pause or Resume error was about the Symphony that was running before.
            controlError = nil
        case .polled:
            break
        }
        showStatus()

        switch event {
        case .polled:
            if startWhenStopped {
                startWhenStopped = false
                if machine.canStart { startSymphony(nil) }
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
        detailItems = StatusMenu.detailLines(status, controlError: controlError).map { line in
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
        for (offset, item) in detailItems.enumerated() {
            menu.insertItem(item, at: menu.index(of: statusTitleItem) + 1 + offset)
        }
    }

    private func menuItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }
}
