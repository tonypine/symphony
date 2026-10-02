import AppKit
import SymphonyBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let settingsWindow = SettingsWindowController()

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
        let settingsItem = NSMenuItem(
            title: StatusMenu.settingsTitle,
            action: #selector(openSettings(_:)),
            keyEquivalent: StatusMenu.settingsKeyEquivalent
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
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
        if SettingsStore().loadSettings().checkoutPath.isEmpty {
            settingsWindow.show()
        }
    }

    @objc private func openSettings(_ sender: Any?) {
        settingsWindow.show()
    }
}
