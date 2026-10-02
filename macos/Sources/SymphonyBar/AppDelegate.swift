import AppKit
import SymphonyBarCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        menu.addItem(
            NSMenuItem(
                title: StatusMenu.quitTitle,
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: StatusMenu.quitKeyEquivalent
            )
        )
        item.menu = menu

        statusItem = item
    }
}
