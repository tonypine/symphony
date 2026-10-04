import AppKit
import SymphonyBarCore

/// Scripted QA mode: presses the menu items a test names in `<QA root>/commands/`, keeps `<QA root>/status.json`
/// current, and records alerts there instead of showing them. See `QAScript`.
@MainActor
final class QAScriptDriver {
    /// The driver while the app runs in scripted QA mode, nil otherwise.
    static private(set) var shared: QAScriptDriver?

    /// How often the driver looks for commands and refreshes the status file.
    static let interval: TimeInterval = 0.25

    private let qaMode: QAMode
    private let menu: NSMenu
    private let symphonyPID: () -> pid_t?
    private var alerts: [QAScript.Alert] = []
    private var presses: [QAScript.Press] = []
    private var lastStatus: QAScript.Status?
    /// The answer for a text prompt the press under way shows.
    private var promptInput: String?
    private var timer: Timer?

    /// Starts the driver when the app is in scripted QA mode. `symphonyPID` is the Symphony the app runs.
    static func startIfScripted(menu: NSMenu, symphonyPID: @escaping () -> pid_t?) {
        guard shared == nil, let qaMode = AppStores.current.qaMode, qaMode.scripted else { return }
        let driver = QAScriptDriver(qaMode: qaMode, menu: menu, symphonyPID: symphonyPID)
        shared = driver
        driver.start()
    }

    private init(qaMode: QAMode, menu: NSMenu, symphonyPID: @escaping () -> pid_t?) {
        self.qaMode = qaMode
        self.menu = menu
        self.symphonyPID = symphonyPID
    }

    private func start() {
        try? FileManager.default.createDirectory(at: qaMode.commandsFolder, withIntermediateDirectories: true)
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        // Common modes, so commands still run while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// Records an alert the app would have shown.
    func record(alertTitle title: String, message: String) {
        alerts.append(QAScript.Alert(title: title, message: message))
        writeStatus()
    }

    /// Records a text prompt the app would have shown and answers it with the press's input; nil, as for Cancel,
    /// when the command held none.
    func answer(promptTitle title: String, message: String) -> String? {
        record(alertTitle: title, message: message)
        defer { promptInput = nil }
        return promptInput
    }

    private func tick() {
        for command in QAScript.pendingCommands(in: qaMode.commandsFolder) {
            try? FileManager.default.removeItem(at: command.file)
            press(command)
        }
        writeStatus()
    }

    /// Presses the visible item the command names, if it is enabled, as a click would, and records the result.
    private func press(_ command: QAScript.Command) {
        refreshMenu()
        let item = visibleItems(menu).first { $0.title == command.title }
        let result: QAScript.PressResult
        if let item {
            result = item.isEnabled && item.action != nil ? .pressed : .disabled
        } else {
            result = .missing
        }
        presses.append(QAScript.Press(command: command.file.lastPathComponent, title: command.title, result: result))
        guard result == .pressed, let item, let action = item.action else { return }
        // Record the press before acting: Quit doesn't return here, as `terminate(_:)` exits the app.
        writeStatus()
        promptInput = command.input
        defer { promptInput = nil }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    /// The visible items of `menu`, each followed by the visible items of its submenu.
    private func visibleItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { !$0.isHidden && !$0.isSeparatorItem }.flatMap { item in
            [item] + (item.submenu.map(visibleItems) ?? [])
        }
    }

    /// Updates the items the way opening the menu does: the delegate's refresh, then enabling.
    private func refreshMenu() {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
    }

    private func writeStatus() {
        refreshMenu()
        let info = Bundle.main.infoDictionary
        let status = QAScript.Status(
            pid: ProcessInfo.processInfo.processIdentifier,
            version: info?["CFBundleShortVersionString"] as? String ?? "",
            build: AppBuild(infoDictionary: info, hasEmbeddedSymphony: true).build,
            appPath: Bundle.main.bundleURL.path,
            symphonyPID: symphonyPID(),
            menu: visibleItems(menu).map {
                QAScript.MenuItem(title: $0.title, enabled: $0.isEnabled)
            },
            alerts: alerts,
            presses: presses
        )
        guard status != lastStatus else { return }
        do {
            try QAScript.write(status, to: qaMode.statusFile)
            lastStatus = status
        } catch {
            NSLog("Symphony QA: couldn't write \(qaMode.statusFile.path): \(error.localizedDescription)")
        }
    }
}
