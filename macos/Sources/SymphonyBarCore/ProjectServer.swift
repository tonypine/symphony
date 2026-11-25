import Foundation

/// When Symphony runs the project's own server: `verification.dev_server.runs`, a closed set.
public enum ProjectServerRuns: String, CaseIterable, Identifiable, Equatable, Sendable {
    /// On Symphony's host, for agent runs and web QA passes, while `verification.enabled` is on.
    case symphonyHost = "symphony_host"
    /// Every macOS app QA pass, on the QA host.
    case everyQAPass = "every_qa_pass"
    /// Only a macOS app QA pass the ticket's plan marks live, on the QA host.
    case liveQAPass = "live_qa_pass"

    public var id: String { rawValue }

    /// The rule's name in Settings.
    public var title: String {
        switch self {
        case .symphonyHost: "On Symphony's host"
        case .everyQAPass: "Every QA pass"
        case .liveQAPass: "Live QA passes"
        }
    }
}

/// The signal Symphony stops the project's server with: `verification.dev_server.stop_signal`.
public enum ProjectServerStopSignal: String, CaseIterable, Identifiable, Equatable, Sendable {
    case term = "TERM"
    case int = "INT"
    case quit = "QUIT"
    case hup = "HUP"
    case kill = "KILL"

    public var id: String { rawValue }
}

/// The project's own server, described once in `verification.dev_server` of a `symphony.yml`: how it is built,
/// started, checked and stopped, and the rule for when it runs. Only the lines that change are rewritten, or
/// inserted when missing, so the rest of the file stays as it is.
public struct ProjectServerSettings: Equatable, Sendable {
    /// `build_cmd`: what builds the server before it starts, or nil for nothing.
    public var buildCmd: String?
    /// `start_cmd`: what starts the server.
    public var startCmd: String
    /// `health_check_url`: the address Symphony asks until the server answers.
    public var healthCheckURL: String
    /// `health_timeout_ms`: how long the server has to answer, more than 0.
    public var healthTimeoutMs: Int
    /// `stop_signal`: the signal the server is stopped with.
    public var stopSignal: ProjectServerStopSignal
    /// `stop_timeout_ms`: how long the server has to stop before it is killed, 0 or more.
    public var stopTimeoutMs: Int
    /// `runs`: the rule for when the server runs.
    public var runs: ProjectServerRuns

    /// What Symphony uses when a key is missing or null.
    public static let defaultHealthTimeoutMs = 30_000
    public static let defaultStopSignal = ProjectServerStopSignal.term
    public static let defaultStopTimeoutMs = 10_000
    public static let defaultRuns = ProjectServerRuns.symphonyHost

    static let path = ["verification", "dev_server"]

    public init(
        buildCmd: String? = nil,
        startCmd: String = "",
        healthCheckURL: String = "",
        healthTimeoutMs: Int = defaultHealthTimeoutMs,
        stopSignal: ProjectServerStopSignal = defaultStopSignal,
        stopTimeoutMs: Int = defaultStopTimeoutMs,
        runs: ProjectServerRuns = defaultRuns
    ) {
        self.buildCmd = buildCmd
        self.startCmd = startCmd
        self.healthCheckURL = healthCheckURL
        self.healthTimeoutMs = healthTimeoutMs
        self.stopSignal = stopSignal
        self.stopTimeoutMs = stopTimeoutMs
        self.runs = runs
    }

    /// These settings with the commands and the address trimmed, and a blank build command as none.
    public func trimmed() -> ProjectServerSettings {
        var copy = self
        let build = buildCmd?.trimmingWhitespace() ?? ""
        copy.buildCmd = build.isEmpty ? nil : build
        copy.startCmd = startCmd.trimmingWhitespace()
        copy.healthCheckURL = healthCheckURL.trimmingWhitespace()
        return copy
    }

    /// The settings, with Symphony's default for a missing or null key.
    public static func values(in yaml: String) throws -> ProjectServerSettings {
        let document = Document(yaml)
        guard let range = try MacAppQAPlaybook.block(path, in: document) else { return ProjectServerSettings() }
        let build = try text(document.child("build_cmd", in: range), key: "build_cmd")
        return ProjectServerSettings(
            buildCmd: build,
            startCmd: try text(document.child("start_cmd", in: range), key: "start_cmd") ?? "",
            healthCheckURL: try text(document.child("health_check_url", in: range), key: "health_check_url") ?? "",
            healthTimeoutMs: try integer(
                document.child("health_timeout_ms", in: range), key: "health_timeout_ms", default: defaultHealthTimeoutMs, least: 1
            ),
            stopSignal: try choice(document.child("stop_signal", in: range), key: "stop_signal", default: defaultStopSignal),
            stopTimeoutMs: try integer(
                document.child("stop_timeout_ms", in: range), key: "stop_timeout_ms", default: defaultStopTimeoutMs, least: 0
            ),
            runs: try choice(document.child("runs", in: range), key: "runs", default: defaultRuns)
        )
    }

    /// The same text with the settings that differ between `old` and `new` set to their `new` values. A missing key
    /// goes first under `dev_server:`, so they are set last to first and read in order.
    public static func updating(_ yaml: String, from old: ProjectServerSettings, to new: ProjectServerSettings) throws -> String {
        var yaml = yaml
        if new.runs != old.runs {
            yaml = try setting("runs", to: new.runs.rawValue, in: yaml)
        }
        if new.stopTimeoutMs != old.stopTimeoutMs {
            yaml = try setting("stop_timeout_ms", to: String(new.stopTimeoutMs), in: yaml)
        }
        if new.stopSignal != old.stopSignal {
            yaml = try setting("stop_signal", to: new.stopSignal.rawValue, in: yaml)
        }
        if new.healthTimeoutMs != old.healthTimeoutMs {
            yaml = try setting("health_timeout_ms", to: String(new.healthTimeoutMs), in: yaml)
        }
        if new.healthCheckURL != old.healthCheckURL {
            yaml = try setting("health_check_url", to: MacAppQAPlaybook.quoted(new.healthCheckURL), in: yaml)
        }
        if new.startCmd != old.startCmd {
            yaml = try setting("start_cmd", to: MacAppQAPlaybook.quoted(new.startCmd), in: yaml)
        }
        if new.buildCmd != old.buildCmd {
            yaml = try setting("build_cmd", to: new.buildCmd.map(MacAppQAPlaybook.quoted) ?? "null", in: yaml)
        }
        return yaml
    }

    // MARK: Reading

    /// A text setting, or nil when it is missing or null.
    private static func text(_ key: Document.Key?, key name: String) throws -> String? {
        guard let key else { return nil }
        let value = ValueLine(key.rest).value
        if TokenLimits.nullValues.contains(value) { return nil }
        return try MacAppQAPlaybook.scalar(value, key: "dev_server.\(name)")
    }

    /// A whole-number setting of at least `least`, with `fallback` when it is missing or null.
    private static func integer(_ key: Document.Key?, key name: String, default fallback: Int, least: Int) throws -> Int {
        guard let key else { return fallback }
        let value = ValueLine(key.rest).value
        if TokenLimits.nullValues.contains(value) { return fallback }
        guard let number = Int(value.filter { $0 != "_" }), number >= least else {
            throw MacAppQAPlaybookError.unreadable(key: "dev_server.\(name)", value: value)
        }
        return number
    }

    /// One of a closed set of values, with `fallback` when it is missing or null; any other value can't be read.
    private static func choice<Choice: RawRepresentable>(
        _ key: Document.Key?, key name: String, default fallback: Choice
    ) throws -> Choice where Choice.RawValue == String {
        guard let key else { return fallback }
        let value = ValueLine(key.rest).value
        if TokenLimits.nullValues.contains(value) { return fallback }
        let text = try MacAppQAPlaybook.scalar(value, key: "dev_server.\(name)")
        guard let choice = Choice(rawValue: text) else {
            throw MacAppQAPlaybookError.unreadable(key: "dev_server.\(name)", value: value)
        }
        return choice
    }

    // MARK: Writing

    private static func setting(_ key: String, to value: String, in yaml: String) throws -> String {
        try MacAppQAPlaybook.blockSection {
            try ConfigSetting.setting(at: path + [key], to: value, in: MacAppQAPlaybook.opening(path, in: yaml))
        }
    }
}
