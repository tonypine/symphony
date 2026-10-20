import Foundation

/// A JSON value a setup fix carries, such as a `config_edit`'s `value`: a string, a list, a number, a boolean or null.
public enum SetupValue: Equatable, Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case list([SetupValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let list = try? container.decode([SetupValue].self) {
            self = .list(list)
        } else {
            // A map is no value a fix sets; it reads as none, and the edit is refused.
            self = .null
        }
    }

    /// The value as YAML writes a scalar: a string as it is, a whole number without its decimals; nil for a list or
    /// null.
    public var scalarText: String? {
        switch self {
        case let .string(string): string
        case let .number(number): number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case let .bool(bool): bool ? "true" : "false"
        case .list, .null: nil
        }
    }

    /// The items of a list as text, nil when it isn't a list of scalars.
    public var listText: [String]? {
        guard case let .list(items) = self else { return nil }
        let texts = items.compactMap(\.scalarText)
        return texts.count == items.count ? texts : nil
    }

    /// How the value reads in a sentence: a scalar as it is, a list as `[a, b]`.
    public var display: String {
        if let scalarText { return scalarText }
        if let listText { return "[" + listText.joined(separator: ", ") + "]" }
        return "nothing"
    }

    var json: Any {
        switch self {
        case let .string(string): string
        case let .number(number): number
        case let .bool(bool): bool
        case let .list(items): items.map(\.json)
        case .null: NSNull()
        }
    }
}

/// What `GET /api/v1/setup` reports, and `/api/v1/state` under `setup` (TP-904): the setup problems Symphony found,
/// the checks it couldn't run, and when it checked.
public struct SetupPayload: Equatable {
    public static let path = "api/v1/setup"

    public enum Severity: String, Equatable {
        case error, warning
    }

    /// How a problem is fixed (`SymphonyElixir.Setup.Problem`).
    public enum Fix: Equatable {
        /// An edit of `symphony.yml` the app makes through its settings writer once the operator confirms it.
        case configEdit(path: String, action: ConfigAction, value: SetupValue)
        /// A Linear change Symphony makes once the operator confirms it (`POST /api/v1/setup/fixes`), such as
        /// `create_label`: the `name` in team `team`; for a status (`create_state`), of `type`, just `after` the
        /// status the check names, or first of its type when it names none.
        case linear(action: String, team: String, name: String, type: String?, after: String? = nil)
        /// Re-syncs each ticket's hold label in repo `repo` from the hold Symphony keeps.
        case resyncHold(repo: String, tickets: [String])
        /// No safe fix: the place where the operator fixes it.
        case open(OpenTarget, url: URL?)
        /// A fix this app doesn't know: the problem shows without a button.
        case unknown(String)

        /// The fix as `POST /api/v1/setup/fixes` takes it, nil for one Symphony doesn't run. A re-sync names
        /// `tickets`, the ones the operator picked, or all of them.
        public func descriptor(tickets picked: [String]? = nil) -> [String: Any]? {
            switch self {
            case let .linear(action, team, name, type, after):
                // The place the sheet showed goes back, so Symphony refuses a status whose place moved since.
                var descriptor: [String: Any] = ["kind": "linear", "action": action, "team": team, "name": name]
                if let type { descriptor["type"] = type }
                if let after { descriptor["after"] = after }
                return descriptor
            case let .resyncHold(repo, tickets):
                return ["kind": "linear", "action": "resync_hold", "repo": repo, "tickets": picked ?? tickets]
            case .configEdit, .open, .unknown:
                return nil
            }
        }
    }

    public enum ConfigAction: String, Equatable {
        case remove, set, add
    }

    /// Where an `open` fix goes. `update` is the app's own: the build warning's Check for Updates….
    public enum OpenTarget: String, Equatable {
        case settings
        case symphonyYML = "symphony_yml"
        case linear
        case drainReport = "drain_report"
        case repos
        case update
    }

    public struct Ticket: Equatable, Hashable {
        public var identifier: String
        public var url: URL?

        public init(identifier: String, url: URL? = nil) {
            self.identifier = identifier
            self.url = url
        }
    }

    public struct Detail: Equatable, Hashable {
        public var label: String
        public var value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public struct Problem: Equatable, Identifiable {
        /// Stable across runs: the check and its subject, such as `deprecated_key:auto_review.enabled`.
        public var id: String
        public var severity: Severity
        /// `routing`, `teams`, `labels`, `statuses`, `keys`, `secrets` or `runtime`; another is kept as it came.
        public var category: String
        public var title: String
        /// What breaks, in plain words.
        public var consequence: String
        public var repos: [String]
        public var tickets: [Ticket]
        /// The lines under Details.
        public var details: [Detail]
        public var fix: Fix?

        public init(
            id: String,
            severity: Severity,
            category: String,
            title: String,
            consequence: String,
            repos: [String] = [],
            tickets: [Ticket] = [],
            details: [Detail] = [],
            fix: Fix? = nil
        ) {
            self.id = id
            self.severity = severity
            self.category = category
            self.title = title
            self.consequence = consequence
            self.repos = repos
            self.tickets = tickets
            self.details = details
            self.fix = fix
        }
    }

    /// A check that couldn't run, and why.
    public struct NotChecked: Equatable, Identifiable {
        public var id: String
        public var title: String
        public var reason: String

        public init(id: String, title: String, reason: String) {
            self.id = id
            self.title = title
            self.reason = reason
        }
    }

    public var problems: [Problem]
    public var notChecked: [NotChecked]
    /// When the last run ended; nil until the first one has.
    public var checkedAt: Date?
    /// When the last run that reached Linear was; earlier than `checkedAt` while Linear can't be reached.
    public var linearCheckedAt: Date?

    public init(problems: [Problem] = [], notChecked: [NotChecked] = [], checkedAt: Date? = nil, linearCheckedAt: Date? = nil) {
        self.problems = problems
        self.notChecked = notChecked
        self.checkedAt = checkedAt
        self.linearCheckedAt = linearCheckedAt
    }

    /// The payload with only the problems of the repo `key`: those naming it, and those naming no repo (keys, secrets
    /// and the rest of the global setup), as `GET /api/v1/setup?repo=` answers.
    public func forRepo(_ key: String) -> SetupPayload {
        var payload = self
        payload.problems = problems.filter { $0.repos.isEmpty || $0.repos.contains(key) }
        return payload
    }

    public var errors: [Problem] { problems.filter { $0.severity == .error } }
    public var warnings: [Problem] { problems.filter { $0.severity == .warning } }

    /// True while Linear can't be reached: the Linear-side problems are those of the last run that reached it.
    public var isStale: Bool {
        guard let checkedAt, let linearCheckedAt else { return false }
        return linearCheckedAt < checkedAt
    }

    /// The newer of two payloads by `checkedAt`: the state poll's, or the one a fix or Check Again answered with.
    /// A payload that has checked wins over one that hasn't; `current` wins a tie.
    public static func newest(_ current: SetupPayload?, _ other: SetupPayload?) -> SetupPayload? {
        guard let current else { return other }
        guard let other else { return current }
        switch (current.checkedAt, other.checkedAt) {
        case let (mine?, theirs?): return theirs > mine ? other : current
        case (nil, .some): return other
        default: return current
        }
    }

    // MARK: Decoding

    /// The payload of `/api/v1/setup`, or of the answer to `POST /api/v1/setup/refresh` and `/fixes`; nil when it
    /// isn't one.
    public static func decode(_ data: Data) -> SetupPayload? {
        (try? decoder.decode(Wire.self, from: data)).map(SetupPayload.init(wire:))
    }

    /// The `setup` section of a `/api/v1/state` payload, nil when Symphony predates it.
    public static func decode(state data: Data) -> SetupPayload? {
        struct State: Decodable { let setup: Wire? }
        return (try? decoder.decode(State.self, from: data))?.setup.map(SetupPayload.init(wire:))
    }

    init(wire: Wire) {
        problems = (wire.problems ?? []).compactMap(Self.problem)
        notChecked = (wire.notChecked ?? []).compactMap { entry in
            guard let id = entry.id else { return nil }
            return NotChecked(id: id, title: entry.title ?? id, reason: entry.reason ?? "")
        }
        checkedAt = wire.checkedAt.flatMap(SymphonyState.parseDate)
        linearCheckedAt = wire.linearCheckedAt.flatMap(SymphonyState.parseDate)
    }

    private static func problem(_ wire: Wire.Problem) -> Problem? {
        guard let id = wire.id, let title = wire.title else { return nil }
        return Problem(
            id: id,
            severity: wire.severity == "error" ? .error : .warning,
            category: wire.category ?? "runtime",
            title: title,
            consequence: wire.consequence ?? "",
            repos: wire.repos ?? [],
            tickets: (wire.tickets ?? []).compactMap { ticket in
                ticket.identifier.map { Ticket(identifier: $0, url: ticket.url.flatMap(URL.init(string:))) }
            },
            details: (wire.details ?? []).compactMap { detail in
                guard let label = detail.label, let value = detail.value else { return nil }
                return Detail(label: label, value: value)
            },
            fix: wire.fix.map(fix)
        )
    }

    private static func fix(_ wire: Wire.Fix) -> Fix {
        switch wire.kind {
        case "config_edit":
            guard let path = wire.path, let action = wire.action.flatMap(ConfigAction.init(rawValue:)) else {
                return .unknown("config_edit")
            }
            return .configEdit(path: path, action: action, value: wire.value ?? .null)
        case "linear":
            if wire.action == "resync_hold", let repo = wire.repo, let tickets = wire.tickets, !tickets.isEmpty {
                return .resyncHold(repo: repo, tickets: tickets)
            }
            guard let action = wire.action, let team = wire.team, let name = wire.name else { return .unknown("linear") }
            return .linear(action: action, team: team, name: name, type: wire.type, after: wire.after)
        case "open":
            // The app's own `update` is never one Symphony sends.
            guard let target = wire.target.flatMap(OpenTarget.init(rawValue:)), target != .update else { return .unknown("open") }
            return .open(target, url: wire.url.flatMap(URL.init(string:)))
        default:
            return .unknown(wire.kind ?? "")
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Every field is optional, so a problem missing one never fails the whole payload.
    struct Wire: Decodable {
        struct Problem: Decodable {
            let id: String?
            let severity: String?
            let category: String?
            let title: String?
            let consequence: String?
            let repos: [String]?
            let tickets: [Ticket]?
            let details: [Detail]?
            let fix: Fix?
        }

        struct Ticket: Decodable {
            let identifier: String?
            let url: String?
        }

        struct Detail: Decodable {
            let label: String?
            let value: String?
        }

        struct Fix: Decodable {
            let kind: String?
            let path: String?
            let action: String?
            let value: SetupValue?
            let team: String?
            let name: String?
            let type: String?
            let after: String?
            let repo: String?
            let tickets: [String]?
            let target: String?
            let url: String?
        }

        struct NotChecked: Decodable {
            let id: String?
            let title: String?
            let reason: String?
        }

        let problems: [Problem]?
        let notChecked: [NotChecked]?
        let checkedAt: String?
        let linearCheckedAt: String?
    }
}

// MARK: - App and service builds

/// J11: the app and the Symphony it talks to run different builds, so settings the newer side writes may be ignored by
/// the older one. Computed in the app from `/api/v1/state`'s `build.version`.
public enum SetupBuildCheck {
    public static let problemID = "app_build"

    /// The warning row, nil when the builds match, either is unknown, or the app is a development build (it runs a
    /// checkout's Symphony, whose build is never the app's).
    public static func warning(serviceVersion: String?, app: AppBuild) -> SetupPayload.Problem? {
        guard !app.isDevelopment,
            let appVersion = app.version?.trimmingWhitespace(), !appVersion.isEmpty,
            let serviceVersion = serviceVersion?.trimmingWhitespace(), !serviceVersion.isEmpty,
            appVersion != serviceVersion
        else { return nil }

        let appNewer = compare(appVersion, serviceVersion) == .orderedDescending
        let (newer, older) = appNewer ? ("this app", "Symphony \(serviceVersion)") : ("Symphony \(serviceVersion)", "this app")
        return SetupPayload.Problem(
            id: problemID,
            severity: .warning,
            category: "runtime",
            title: "This app is \(appVersion) but Symphony runs \(serviceVersion)",
            consequence: "Settings \(newer) writes may be ignored by \(older) until both run the same build. Update so they match.",
            details: [
                SetupPayload.Detail(label: "App", value: appVersion),
                SetupPayload.Detail(label: "Symphony", value: serviceVersion),
            ],
            fix: .open(.update, url: nil)
        )
    }

    /// Dotted versions compared number by number: `0.0.1.600` is newer than `0.0.1.583`.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

// MARK: - Counts, badge, menu row

/// What the sidebar badge, the menu bar and the Overview say about Setup (SU1, SU2): errors first, then warnings.
public struct SetupSummary: Equatable {
    public var errors: Int
    public var warnings: Int

    public init(errors: Int = 0, warnings: Int = 0) {
        self.errors = errors
        self.warnings = warnings
    }

    /// The counts of `payload` and the build warning. An older Symphony, which reports no `setup`, counts nothing.
    public init(payload: SetupPayload?, buildWarning: SetupPayload.Problem? = nil) {
        let problems = (payload?.problems ?? []) + [buildWarning].compactMap { $0 }
        errors = problems.filter { $0.severity == .error }.count
        warnings = problems.filter { $0.severity == .warning }.count
    }

    public var isHealthy: Bool { errors == 0 && warnings == 0 }

    /// The sidebar badge: the error count in `status.problem`, else the warning count in `status.you`'s orange, else
    /// none.
    public var badge: (count: Int, status: DesignTokens.Status)? {
        if errors > 0 { return (errors, .problem) }
        if warnings > 0 { return (warnings, .you) }
        return nil
    }

    /// The menu bar icon's dot shows while there are errors.
    public var showsMenuDot: Bool { errors > 0 }

    /// "Setup: 1 error, 1 warning", nil while healthy (the menu row hides).
    public var menuTitle: String? {
        guard !isHealthy else { return nil }
        return "Setup: " + Self.counts(errors: errors, warnings: warnings)
    }

    /// "1 error, 1 warning"; a count at 0 is left out.
    public static func counts(errors: Int, warnings: Int) -> String {
        var parts: [String] = []
        if errors > 0 { parts.append(errors == 1 ? "1 error" : "\(errors) errors") }
        if warnings > 0 { parts.append(warnings == 1 ? "1 warning" : "\(warnings) warnings") }
        return parts.joined(separator: ", ")
    }

    /// The Overview's Needs attention row while there are errors: "Setup has 1 error."; nil without errors.
    public var attentionSentence: String? {
        guard errors > 0 else { return nil }
        return errors == 1 ? "Setup has 1 error." : "Setup has \(errors) errors."
    }

    /// "Setup, 1 error" for VoiceOver on the sidebar item; empty while healthy.
    public var accessibilityValue: String {
        isHealthy ? "" : Self.counts(errors: errors, warnings: warnings)
    }
}
