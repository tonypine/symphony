import AppKit
import SymphonyBarCore
import UserNotifications

/// Owns the Symphony child process: starts it from the saved settings, stops it, and reports unexpected exits.
@MainActor
final class SymphonyRunner {
    /// Called after Symphony starts or exits.
    var onEvent: ((StatusMachine.Event) -> Void)?

    private let store: SettingsStore
    /// Reads the secrets for Start, config checks and the Settings window, one read at a time.
    let secrets: SecretsReader
    private let logDirectory = AppStores.current.logDirectory
    private var child: ChildProcess?
    private var stopWaiters: [() -> Void] = []
    // SYMPHONY_STATE_ROOT from the last start, which may come from the stored variables.
    private var launchedStateRoot: String?
    // Settings of the running Symphony, so the menu names the binary that runs even after Settings change.
    private var launchedSettings: AppSettings?

    /// Where this build's embedded Symphony is, at `Contents/Resources/symphony`.
    nonisolated static let embeddedSymphonyPath = EmbeddedSymphony.path(resourcesPath: Bundle.main.resourcePath)
    nonisolated static let qaDriverAppPath = QADriverApp.path(bundlePath: Bundle.main.bundlePath)

    /// True when this build carries an embedded Symphony.
    nonisolated static var hasEmbeddedSymphony: Bool { EmbeddedSymphony.isAvailable(at: embeddedSymphonyPath) }

    init(store: SettingsStore = AppStores.current.settingsStore()) {
        self.store = store
        secrets = SecretsReader(load: store.loadSecrets)
    }

    var isRunning: Bool { child != nil }
    /// The Symphony the app started, nil while it runs none.
    var pid: pid_t? { child?.pid }
    var isStopping: Bool { child?.stopRequested == true }
    /// True while Start waits to read the Keychain.
    private(set) var isStarting = false
    /// True while Start, a config check or Settings waits to read the Keychain, which is usually a password prompt.
    var isWaitingForKeychain: Bool { secrets.isWaiting }

    /// Called when a Keychain read starts or ends.
    var onKeychainChange: (() -> Void)? {
        get { secrets.onChange }
        set { secrets.onChange = newValue }
    }

    /// Symphony's state directory, using the `SYMPHONY_STATE_ROOT` the app last started Symphony with.
    var stateRoot: URL {
        var environment = AppStores.current.environment
        environment[StateRoot.environmentKey] = launchedStateRoot ?? environment[StateRoot.environmentKey]
        return StateRoot.locate(environment: environment)
    }

    /// Which Symphony runs, or would run on Start, for the menu.
    var sourceLine: String {
        StatusMenu.sourceLine(
            launchedSettings ?? store.loadSettings(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            embeddedAvailable: Self.hasEmbeddedSymphony
        )
    }

    /// Symphony's output log.
    var logURL: URL { logDirectory.appendingPathComponent(ChildLog.fileName) }

    /// The log path for messages, with `~` for the home folder.
    var logPath: String {
        (logURL.path as NSString).abbreviatingWithTildeInPath
    }

    /// Starts Symphony, reading the Keychain off the main thread so a password prompt can't freeze the menu.
    /// `completion` gets nil once Symphony runs, or a `LaunchProblem` when the settings aren't ready, or a Keychain,
    /// log or spawn error.
    func start(completion: ((Error?) -> Void)? = nil) {
        guard child == nil, !isStarting else {
            completion?(nil)
            return
        }

        isStarting = true
        let settings = store.loadSettings()
        secrets.read { [weak self] secrets in
            guard let self else { return }
            isStarting = false
            do {
                try spawn(settings: settings, secrets: secrets.get())
                completion?(nil)
            } catch {
                completion?(error)
            }
        }
    }

    private func spawn(settings: AppSettings, secrets: SecretSettings) throws {
        let launch = try launch(settings: settings, secrets: secrets)
        launchedStateRoot = launch.environment[StateRoot.environmentKey]
        let log = try ChildLog.rotate(in: logDirectory)
        writeHeader(to: log, launch: launch)

        child = try ChildProcess.spawn(launch, logURL: log, queue: .main) { [weak self] exit, requested in
            MainActor.assumeIsolated { self?.childExited(exit, requested: requested) }
        }
        launchedSettings = settings
        onEvent?(.started)
    }

    /// The `symphony check --config <symphony.yml>` that matches what Start would run, with the same environment,
    /// read off the main thread like Start.
    func checkLaunch(completion: @escaping (Result<ChildLaunch, Error>) -> Void) {
        let settings = store.loadSettings()
        secrets.read { [weak self] secrets in
            guard let self else { return }
            completion(Result {
                try self.launch(settings: settings, secrets: secrets.get(), subcommand: ["check"])
            })
        }
    }

    /// The `symphony dashboard` script for Terminal, from the binary the running Symphony came from (or Start
    /// would run), against the state directory the app watches.
    func terminalDashboardScript() throws -> String {
        try TerminalDashboard.script(
            settings: launchedSettings ?? store.loadSettings(),
            embeddedSymphonyPath: Self.embeddedSymphonyPath,
            stateRoot: stateRoot
        )
    }

    /// Minutes Restart waits for agent runs before it offers Restart Now Anyway.
    var restartTimeoutMinutes: Int {
        let range = AppSettings.restartTimeoutRange
        return min(max(store.loadSettings().restartTimeoutMinutes, range.lowerBound), range.upperBound)
    }

    private func launch(settings: AppSettings, secrets: SecretSettings, subcommand: [String] = []) throws -> ChildLaunch {
        try ChildLaunchBuilder.build(
            settings: settings,
            secrets: secrets,
            baseEnvironment: AppStores.current.environment,
            embeddedSymphonyPath: Self.embeddedSymphonyPath,
            qaDriverAppPath: Self.qaDriverAppPath,
            subcommand: subcommand
        )
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
    }

    /// How many agent runs Symphony reports, or nil when its state can't be read.
    func activeRunCount() async -> Int? {
        guard case let .state(snapshot) = await StatusPoller.fetch(stateRoot: stateRoot) else { return nil }
        return snapshot.running
    }

    private func childExited(_ exit: ChildExit, requested: Bool) {
        child = nil
        launchedSettings = nil
        if !requested {
            notify(title: "Symphony stopped unexpectedly", body: StatusMenu.unexpectedExitMessage(exit, logPath: logPath))
        }
        let waiters = stopWaiters
        stopWaiters = []
        waiters.forEach { $0() }
        onEvent?(.exited(exit, requested: requested))
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

    /// Posts a notification, or shows an alert when notifications aren't allowed. Scripted QA mode records it.
    func notify(title: String, body: String) {
        if let script = QAScriptDriver.shared {
            script.record(alertTitle: title, message: body)
            return
        }
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

    /// Shows an alert, or in scripted QA mode records it instead.
    static func showAlert(title: String, body: String) {
        if let script = QAScriptDriver.shared {
            script.record(alertTitle: title, message: body)
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        activateApp()
        alert.runModal()
    }

    /// Asks `alert`'s question and returns true for its first button. Scripted QA mode records it and answers yes.
    static func confirm(_ alert: NSAlert) -> Bool {
        if let script = QAScriptDriver.shared {
            script.record(alertTitle: alert.messageText, message: alert.informativeText)
            return true
        }
        activateApp()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Brings the app in front of whichever app is active. The macOS 14 `NSApp.activate()` only asks, and the
    /// system declines it while another app is frontmost, which is the usual case for a menu bar app.
    static func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
