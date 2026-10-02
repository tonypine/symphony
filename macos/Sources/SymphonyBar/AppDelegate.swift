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
    private var detailItems: [NSMenuItem] = []
    private var startWhenStopped = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        EditMenu.install()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        statusTitleItem.isEnabled = false
        menu.addItem(statusTitleItem)
        menu.addItem(.separator())
        menu.addItem(menuItem(StatusMenu.startTitle, action: #selector(startSymphony(_:))))
        menu.addItem(menuItem(StatusMenu.stopTitle, action: #selector(stopSymphony(_:))))
        menu.addItem(.separator())
        menu.addItem(menuItem(StatusMenu.openDashboardTitle, action: #selector(openDashboard(_:))))
        menu.addItem(menuItem(StatusMenu.openLogsTitle, action: #selector(openLogs(_:))))
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
        // Start, Stop and the open items are enabled by validateMenuItem; the status lines stay disabled.
        menu.autoenablesItems = true
        item.menu = menu

        statusItem = item
        showStatus()

        runner.onEvent = { [weak self] event in self?.handle(event) }
        poller.onPoll = { [weak self] poll in
            guard let self else { return StatusMachine.pollInterval }
            handle(.polled(poll))
            return machine.nextPollInterval
        }

        // First run: nothing to start yet, so ask for settings. Reads only UserDefaults, not the Keychain.
        let settings = SettingsStore().loadSettings()
        if settings.checkoutPath.isEmpty {
            settingsWindow.show()
        } else if settings.startOnLaunch {
            // Wait for the first poll, so a Symphony already running from the CLI is attached to, not started twice.
            startWhenStopped = true
        }
        poller.start()
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
        case #selector(openDashboard(_:)):
            switch machine.status {
            case .running, .paused:
                return true
            case .stopped, .starting, .error:
                return false
            }
        case #selector(openLogs(_:)):
            return FileManager.default.fileExists(atPath: runner.logURL.path)
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

    @objc private func openSettings(_ sender: Any?) {
        settingsWindow.show()
    }

    @objc private func openDashboard(_ sender: Any?) {
        NSWorkspace.shared.open(SymphonyState.baseURL(controlURLFile: SymphonyState.controlURLFile()))
    }

    @objc private func openLogs(_ sender: Any?) {
        NSWorkspace.shared.open(runner.logURL)
    }

    private func handle(_ event: StatusMachine.Event) {
        machine.handle(event)
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
        guard let menu = statusTitleItem.menu else { return }
        detailItems.forEach(menu.removeItem)
        detailItems = StatusMenu.detailLines(status).map { line in
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
