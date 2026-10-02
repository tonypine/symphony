import AppKit
import SymphonyBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem?
    private let settingsWindow = SettingsWindowController()
    private let runner = SymphonyRunner()

    func applicationDidFinishLaunching(_ notification: Notification) {
        EditMenu.install()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            let image = NSImage(
                systemSymbolName: StatusMenu.iconSymbolName,
                accessibilityDescription: StatusMenu.accessibilityLabel
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = StatusMenu.accessibilityLabel
        }

        let menu = NSMenu()
        menu.addItem(menuItem(StatusMenu.startTitle, action: #selector(startSymphony(_:))))
        menu.addItem(menuItem(StatusMenu.stopTitle, action: #selector(stopSymphony(_:))))
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
        item.menu = menu

        statusItem = item

        // First run: nothing to start yet, so ask for settings. Reads only UserDefaults, not the Keychain.
        let settings = SettingsStore().loadSettings()
        if settings.checkoutPath.isEmpty {
            settingsWindow.show()
        } else if settings.startOnLaunch {
            startSymphony(nil)
        }
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
            return !runner.isRunning
        case #selector(stopSymphony(_:)):
            menuItem.title = runner.isStopping ? StatusMenu.stoppingTitle : StatusMenu.stopTitle
            return runner.isRunning && !runner.isStopping
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

    private func menuItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }
}
