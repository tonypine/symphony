import Foundation

/// The Setup page (SU3–SU6): its status sentence, an Errors and a Warnings card with rows grouped by category, the
/// checks that couldn't run, and the stale banner while Linear can't be reached.
public struct SetupPage: Equatable {
    public enum Mood: Equatable {
        /// SU5: no problem.
        case healthy
        case problems
        /// Symphony hasn't finished its first run yet.
        case checking
        /// SU6: the Symphony running predates Setup, so there is nothing to show; Check for Updates….
        case olderService
    }

    /// What a row's button does.
    public enum Action: Equatable {
        /// Opens the fix's consequence sheet; nothing changes until its button is pressed.
        case fix(SetupPayload.Fix)
        /// Goes where the operator fixes it.
        case open(SetupDestination)
    }

    public struct Row: Equatable, Identifiable {
        public var problem: SetupPayload.Problem
        /// The prominent button; nil when the problem has no fix this app knows.
        public var actionTitle: String?
        public var action: Action?

        public var id: String { problem.id }
        public var title: String { problem.title }
        public var consequence: String { problem.consequence }
        public var tickets: [SetupPayload.Ticket] { problem.tickets }
        public var details: [SetupPayload.Detail] { problem.details }

        /// "Repos: web-shop, symphony", nil when it names none.
        public var reposLine: String? {
            problem.repos.isEmpty ? nil : (problem.repos.count == 1 ? "Repo: " : "Repos: ") + problem.repos.joined(separator: ", ")
        }

        /// SU4: a drift row lists one line per ticket under Details, each with its own Re-sync.
        public var resyncsPerTicket: Bool {
            if case .resyncHold = problem.fix { return true }
            return false
        }

        /// The detail line of a drifted ticket, by its name.
        public func detail(for ticket: String) -> String? {
            problem.details.first { $0.label == ticket }?.value
        }

        public init(problem: SetupPayload.Problem) {
            self.problem = problem
            switch problem.fix {
            case let .open(target, url)?:
                let destination = SetupDestination(target, url: url)
                actionTitle = destination.title
                action = .open(destination)
            case let fix?:
                actionTitle = Self.fixTitle(fix)
                action = actionTitle == nil ? nil : .fix(fix)
            case nil:
                actionTitle = nil
                action = nil
            }
        }

        /// Remove…, Change…, Add…, Create Label…, Create Status…, Re-sync…; nil for a fix this app doesn't know.
        static func fixTitle(_ fix: SetupPayload.Fix) -> String? {
            switch fix {
            case let .configEdit(_, action, _):
                switch action {
                case .remove: "Remove…"
                case .set: "Change…"
                case .add: "Add…"
                }
            case let .linear(action, _, _, _, _):
                SetupLinearKind(action: action).buttonTitle
            case .resyncHold:
                "Re-sync…"
            case .open, .unknown:
                nil
            }
        }
    }

    /// The rows of one category in a card.
    public struct Group: Equatable, Identifiable {
        public var category: String
        public var rows: [Row]
        public var id: String { category }
        public var title: String { SetupPage.categoryTitle(category) }
    }

    public static let title = "Setup"
    public static let errorsTitle = "Errors"
    public static let warningsTitle = "Warnings"
    public static let notCheckedTitle = "Not checked"
    public static let checkAgainTitle = "Check Again"
    public static let detailsTitle = "Details"
    public static let healthySentence = "Symphony is set up right."
    /// SU5: when the checks run again by themselves (`Setup`'s interval and its reload hook on the service).
    public static let recheckNote = "Symphony checks again every 15 minutes and each time symphony.yml changes."
    /// The categories in the order the cards list them; one the app doesn't know goes last.
    public static let categories = ["routing", "teams", "labels", "statuses", "keys", "secrets", "runtime"]

    public var mood: Mood
    public var sentence: String
    /// The line under the sentence: what was checked and when.
    public var context: String?
    public var errors: [Group]
    public var warnings: [Group]
    public var notChecked: [SetupPayload.NotChecked]
    /// The stale banner (SU6): Linear couldn't be reached, so its results are from this run.
    public var staleBanner: String?

    /// The page for `payload` (nil from a Symphony that predates Setup), with the app's own build warning. `order` is
    /// the row order shown so far: rows keep their places and new ones join below (P7).
    public init(
        payload: SetupPayload?,
        buildWarning: SetupPayload.Problem? = nil,
        order: [String] = [],
        now: Date,
        timeZone: TimeZone = .current
    ) {
        guard let payload else {
            mood = .olderService
            sentence = "This Symphony doesn't check its setup."
            context = "Update Symphony to see what's wrong with its setup, with a fix where one is safe."
            errors = []
            warnings = []
            notChecked = []
            staleBanner = nil
            return
        }

        let problems = Self.ordered(payload.problems + [buildWarning].compactMap { $0 }, order: order)
        errors = Self.groups(problems.filter { $0.severity == .error })
        warnings = Self.groups(problems.filter { $0.severity == .warning })
        notChecked = payload.notChecked
        let time = payload.checkedAt.map { StatusMenu.clockTime($0, now: now, timeZone: timeZone, dateFormat: "MMM d, HH:mm") }

        if payload.checkedAt == nil && payload.problems.isEmpty {
            mood = .checking
            sentence = "Checking Symphony's setup…"
            context = nil
        } else if problems.isEmpty {
            mood = .healthy
            sentence = payload.notChecked.isEmpty ? Self.healthySentence : "Nothing is wrong in what Symphony could check."
            let checked = Self.checkedAreas(payload)
            context = "Checked \(checked)" + (time.map { " at \($0)." } ?? ".") + " " + Self.recheckNote
        } else {
            mood = .problems
            let errorCount = problems.filter { $0.severity == .error }.count
            sentence = "Setup has " + Self.sentenceCounts(errors: errorCount, warnings: problems.count - errorCount) + "."
            context = time.map { "Checked at \($0)." }
        }

        if payload.isStale, let linear = payload.linearCheckedAt {
            let when = StatusMenu.clockTime(linear, now: now, timeZone: timeZone, dateFormat: "MMM d, HH:mm")
            staleBanner = "Symphony couldn't reach Linear. Its teams, statuses and labels are as they were at \(when)."
        } else {
            staleBanner = nil
        }
    }

    /// The ids in the order to show them: the ones shown keep their places, new ones join below.
    public var order: [String] { (errors + warnings).flatMap(\.rows).map(\.id) }

    public static func categoryTitle(_ category: String) -> String {
        switch category {
        case "routing": "Routing"
        case "teams": "Teams"
        case "labels": "Labels"
        case "statuses": "Statuses"
        case "keys": "Keys"
        case "secrets": "Secrets"
        case "runtime": "Runtime"
        default: category.prefix(1).uppercased() + category.dropFirst()
        }
    }

    /// "1 error and 1 warning", "2 warnings".
    static func sentenceCounts(errors: Int, warnings: Int) -> String {
        let parts = SetupSummary.counts(errors: errors, warnings: warnings).components(separatedBy: ", ")
        return parts.joined(separator: " and ")
    }

    /// "routing, teams, labels, keys, secrets and runtime": the areas a run covered, the ones it couldn't left out
    /// when every check of theirs is listed under Not checked.
    static func checkedAreas(_ payload: SetupPayload) -> String {
        let linear = ["teams", "labels", "statuses"]
        let areas = payload.notChecked.isEmpty ? categories : categories.filter { !linear.contains($0) }
        let words = areas.map { categoryTitle($0).lowercased() }
        guard let last = words.last, words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " and " + last
    }

    private static func ordered(_ problems: [SetupPayload.Problem], order: [String]) -> [SetupPayload.Problem] {
        let ids = Overview.holdingOrder(problems.map(\.id), previous: order)
        let byID = Dictionary(problems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    private static func groups(_ problems: [SetupPayload.Problem]) -> [Group] {
        let known = categories.compactMap { category -> Group? in
            let rows = problems.filter { $0.category == category }.map(Row.init)
            return rows.isEmpty ? nil : Group(category: category, rows: rows)
        }
        var others: [Group] = []
        for problem in problems where !categories.contains(problem.category) {
            if let index = others.firstIndex(where: { $0.category == problem.category }) {
                others[index].rows.append(Row(problem: problem))
            } else {
                others.append(Group(category: problem.category, rows: [Row(problem: problem)]))
            }
        }
        return known + others
    }
}

/// Where an `open` fix, or the build warning's update, goes (SU3).
public enum SetupDestination: Equatable {
    /// Open Settings…: the app's Settings window, where the keys are.
    case settings
    /// Open symphony.yml: the file in the operator's editor.
    case symphonyYML
    /// Open in Linear: the link the problem gives, or Linear itself.
    case linear(URL?)
    /// Open Drain Report: the link the problem gives, or the Tickets view, where the stragglers are.
    case drainReport(URL?)
    /// Open Repos: the Repos window.
    case repos
    /// Check for Updates…: the app's update check.
    case update

    public init(_ target: SetupPayload.OpenTarget, url: URL?) {
        switch target {
        case .settings: self = .settings
        case .symphonyYML: self = .symphonyYML
        case .linear: self = .linear(url)
        case .drainReport: self = .drainReport(url)
        case .repos: self = .repos
        case .update: self = .update
        }
    }

    public var title: String {
        switch self {
        case .settings: "Open Settings…"
        case .symphonyYML: "Open symphony.yml"
        case .linear: "Open in Linear"
        case .drainReport: "Open Drain Report"
        case .repos: "Open Repos"
        case .update: UpdateMenu.checkTitle
        }
    }
}

/// What a `linear` fix creates, from its action: `create_label` a label, `create_state` (or
/// `create_workflow_state`) a status.
public struct SetupLinearKind: Equatable {
    /// "label" or "status"; "change" for an action this app doesn't know.
    public var noun: String
    public var isStatus: Bool

    /// Create Label…, Create Status…, or Fix… for an action this app doesn't know.
    public var buttonTitle: String { noun == "change" ? "Fix…" : "Create \(noun.capitalized)…" }

    public init(action: String) {
        switch action {
        case "create_label":
            noun = "label"
            isStatus = false
        case "create_state", "create_workflow_state", "create_status":
            noun = "status"
            isStatus = true
        default:
            noun = "change"
            isStatus = false
        }
    }
}

/// Setup's Linear webhooks line: whether Linear's deliveries arrive, from `/api/v1/state`'s `linear_webhooks`
/// (`LinearWebhookHealth`), which the window already polls.
public struct LinearWebhooksLine: Equatable {
    public enum State: Equatable {
        /// The Symphony running predates the deliveries block.
        case notAvailable
        case off
        /// On, with no delivery since Symphony started.
        case waiting
        /// On, and deliveries arrive with none refused.
        case arriving
        /// On, and Symphony refused at least one delivery, or has no signing secret to check them with.
        case rejecting
    }

    public static let title = "Linear webhooks"

    public var state: State
    /// "Off", "On", "Deliveries refused", "No signing secret", "Not available".
    public var word: String
    /// What is true now, as one sentence.
    public var detail: String

    /// False for an older Symphony: the line is shown greyed out.
    public var isAvailable: Bool { state != .notAvailable }
    /// True when the line is called out in the warning colour.
    public var isWarning: Bool { state == .rejecting }

    /// The line for `health` (nil from an older Symphony), its ages counted from `now`, the state's own time.
    public init(health: LinearWebhookHealth?, now: Date) {
        guard let health else {
            state = .notAvailable
            word = "Not available"
            detail = "Not available on this Symphony: update it to see Linear's deliveries here."
            return
        }
        guard health.enabled else {
            state = .off
            word = "Off"
            detail = "Symphony learns of Linear changes by polling. Turn the webhook on in Settings."
            return
        }
        word = "On"
        let arrived = Self.arrived(health, now: now)
        if health.rejected > 0 {
            state = .rejecting
            word = "Deliveries refused"
            let when = health.lastRejectedAt.map { " \(Self.ago($0, now: now))" } ?? ""
            let reason = health.lastRejectedReason.map { " because \(Self.reason($0))" } ?? ""
            let last = when.isEmpty && reason.isEmpty ? "" : ", the last\(when)\(reason)"
            detail = (arrived ?? "No delivery accepted yet.") + " \(health.rejected) refused\(last)."
        } else if !health.secretConfigured {
            state = .rejecting
            word = "No signing secret"
            detail = "No signing secret is set, so Symphony will refuse every delivery. Set the secret in Settings."
        } else if let arrived {
            state = .arriving
            detail = arrived
        } else {
            state = .waiting
            detail = "No deliveries yet since Symphony started."
        }
    }

    /// "3 deliveries, last 12 s ago."; nil before the first.
    static func arrived(_ health: LinearWebhookHealth, now: Date) -> String? {
        guard health.total > 0 else { return nil }
        let last = health.lastAt.map { ", last \(ago($0, now: now))" } ?? ""
        return "\(count(health.total))\(last)."
    }

    static func count(_ deliveries: Int) -> String {
        deliveries == 1 ? "1 delivery" : "\(GitHubUpdatesCard.number(deliveries)) deliveries"
    }

    /// "12 s ago", "3 min ago".
    static func ago(_ date: Date, now: Date) -> String {
        "\(Overview.duration(Int(now.timeIntervalSince(date)))) ago"
    }

    /// A refusal's reason in plain words.
    static func reason(_ code: String) -> String {
        switch code {
        case "missing_secret": "no signing secret is set"
        case "missing_signature": "it had no signature"
        case "bad_signature": "its signature didn't match the secret"
        case "stale_timestamp": "it was more than a minute old"
        default: code.replacingOccurrences(of: "_", with: " ")
        }
    }
}
