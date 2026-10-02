import AppKit
import SymphonyBarCore
import UserNotifications

/// Owns the Symphony child process: starts it from the saved settings, stops it, and reports unexpected exits.
@MainActor
final class SymphonyRunner {
    /// Called after Symphony starts, begins stopping, or exits.
    var onChange: (() -> Void)?

    private let store: SettingsStore
    private let logDirectory = ChildLog.defaultDirectory()
    private var child: ChildProcess?
    private var stopWaiters: [() -> Void] = []

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
    }

    var isRunning: Bool { child != nil }
    var isStopping: Bool { child?.stopRequested == true }

    private var logPath: String {
        (logDirectory.appendingPathComponent(ChildLog.fileName).path as NSString).abbreviatingWithTildeInPath
    }

    /// Starts Symphony. Throws a `LaunchProblem` when the settings aren't ready, or a Keychain, log or spawn error.
    func start() throws {
        guard child == nil else { return }

        let launch = try ChildLaunchBuilder.build(
            settings: store.loadSettings(),
            secrets: try store.loadSecrets(),
            baseEnvironment: ProcessInfo.processInfo.environment
        )
        let log = try ChildLog.rotate(in: logDirectory)
        writeHeader(to: log, launch: launch)

        child = try ChildProcess.spawn(launch, logURL: log, queue: .main) { [weak self] exit, requested in
            MainActor.assumeIsolated { self?.childExited(exit, requested: requested) }
        }
        onChange?()
    }

    /// Stops Symphony, calling `completion` once it has exited (straight away if it isn't running).
    func stop(completion: (() -> Void)? = nil) {
        guard let child else {
            completion?()
            return
        }
        if let completion { stopWaiters.append(completion) }

        let range = AppSettings.stopTimeoutRange
        let timeout = min(max(store.loadSettings().stopTimeoutSeconds, range.lowerBound), range.upperBound)
        child.stop(timeout: TimeInterval(timeout))
        onChange?()
    }

    /// How many agent runs Symphony reports, or nil when its state can't be read.
    func activeRunCount() async -> Int? {
        let contents = try? String(contentsOf: SymphonyState.controlURLFile(), encoding: .utf8)
        let url = SymphonyState.stateURL(base: SymphonyState.baseURL(controlURLContents: contents))
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return SymphonyState.runningCount(fromStateJSON: data)
    }

    private func childExited(_ exit: ChildExit, requested: Bool) {
        child = nil
        if !requested {
            notify(title: "Symphony stopped unexpectedly", body: StatusMenu.unexpectedExitMessage(exit, logPath: logPath))
        }
        let waiters = stopWaiters
        stopWaiters = []
        waiters.forEach { $0() }
        onChange?()
    }

    /// Notes the start time and command at the top of the log. The command line never holds a secret.
    private func writeHeader(to log: URL, launch: ChildLaunch) {
        let header = """
            === \(Date().ISO8601Format()) Symphony menu bar app starting Symphony
            cwd: \(launch.workingDirectory)
            command: \(([launch.executable] + launch.arguments).map(ShellWords.quote).joined(separator: " "))

            """
        guard let handle = try? FileHandle(forWritingTo: log) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(header.utf8))
    }

    /// Posts a notification, or shows an alert when notifications aren't allowed.
    private func notify(title: String, body: String) {
        // UNUserNotificationCenter needs an app bundle; `swift run` has none.
        guard Bundle.main.bundleIdentifier != nil else {
            Self.showAlert(title: title, body: body)
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                Task { @MainActor in Self.showAlert(title: title, body: body) }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    static func showAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        activateApp()
        alert.runModal()
    }

    static func activateApp() {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
