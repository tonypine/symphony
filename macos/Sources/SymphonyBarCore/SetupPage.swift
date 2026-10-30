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

/// Setup's Dispatch shadow line: where dispatch reads its candidates from and how the candidates Symphony's ticket
/// records give compared with the Linear poll's, from `/api/v1/state`'s `dispatch_shadow` (`DispatchShadowReport`), which
/// the window already polls. The operator moves dispatch to the record once the window stays at zero differences.
public struct DispatchShadowLine: Equatable {
    public enum State: Equatable {
        /// The Symphony running predates the shadow report.
        case notAvailable
        /// Dispatch runs from the Linear poll, and the window holds no difference.
        case pollClean
        /// Dispatch runs from the Linear poll, and the window holds at least one difference.
        case pollDiffering
        /// Dispatch runs from the record; the window's differences are information.
        case record
    }

    /// One of the last differences, as the disclosure lists it.
    public struct Row: Equatable, Identifiable {
        public var id: Int
        public var identifier: String
        /// "Only in the poll", "Only in the record", "In both".
        public var side: String
        /// "Candidate", "State", "Priority".
        public var field: String
        /// What each side has, for example "Todo in the poll, none in the record"; nil when neither said.
        public var values: String?
        /// "4 min ago"; nil when Symphony didn't say.
        public var ago: String?
    }

    public static let title = "Dispatch shadow"
    public static let disclosureTitle = "Last differences"
    public static let emptyList = "No differences since Symphony started."

    public var state: State
    /// "Not available", "No differences", "3 differences", "From the record".
    public var word: String
    /// What is true now, as one or two sentences.
    public var detail: String
    /// The last ten differences, newest first.
    public var rows: [Row]

    /// False for an older Symphony: the line is shown greyed out, with no disclosure.
    public var isAvailable: Bool { state != .notAvailable }
    /// True when the line is called out in the warning colour: the poll still drives dispatch and the sides disagree.
    public var isWarning: Bool { state == .pollDiffering }

    /// The line for `report` (nil from an older Symphony), its ages counted from `now`, the state's own time.
    public init(report: DispatchShadowReport?, now: Date) {
        guard let report else {
            state = .notAvailable
            word = "Not available"
            detail = "Not available on this Symphony: update it to compare dispatch from the record with the Linear poll."
            rows = []
            return
        }
        rows = report.recent.enumerated().map { index, difference in Self.row(difference, id: index, now: now) }
        let last = report.lastDifferenceAt.map { " The last difference was \(LinearWebhooksLine.ago($0, now: now))." } ?? ""
        let compared = Self.compared(report)
        switch report.source {
        case .record:
            state = .record
            word = "From the record"
            detail = "Dispatch runs from Symphony's record. \(compared)\(report.cyclesCompared > 0 ? ", for information" : "")."
                + last
        case .poll where report.windowDifferences > 0:
            state = .pollDiffering
            word = Self.differences(report.windowDifferences)
            detail = "Dispatch runs from the Linear poll. \(compared).\(last)"
        case .poll:
            state = .pollClean
            word = "No differences"
            detail = "Dispatch runs from the Linear poll. \(compared).\(last)"
        }
    }

    /// "140 cycles compared, 0 differences in the last 20 cycles"; "No cycle compared yet since Symphony started"
    /// before the first.
    static func compared(_ report: DispatchShadowReport) -> String {
        guard report.cyclesCompared > 0 else { return "No cycle compared yet since Symphony started" }
        let window = report.windowCycles > 0 ? min(report.windowCycles, report.window) : report.window
        return "\(cycles(report.cyclesCompared)) compared, \(differences(report.windowDifferences)) in the last "
            + (window == 1 ? "cycle" : "\(GitHubUpdatesCard.number(window)) cycles")
    }

    static func cycles(_ count: Int) -> String {
        count == 1 ? "1 cycle" : "\(GitHubUpdatesCard.number(count)) cycles"
    }

    static func differences(_ count: Int) -> String {
        count == 1 ? "1 difference" : "\(GitHubUpdatesCard.number(count)) differences"
    }

    static func row(_ difference: DispatchShadowReport.Difference, id: Int, now: Date) -> Row {
        let side: String =
            switch difference.side {
            case .poll: "Only in the poll"
            case .record: "Only in the record"
            case .both: "In both"
            case .other(let text): text.replacingOccurrences(of: "_", with: " ").capitalized
            }
        let values: String? =
            difference.poll == nil && difference.record == nil
            ? nil : "\(difference.poll ?? "none") in the poll, \(difference.record ?? "none") in the record"
        return Row(
            id: id,
            identifier: difference.identifier,
            side: side,
            field: difference.field.replacingOccurrences(of: "_", with: " ").capitalized,
            values: values,
            ago: difference.at.map { LinearWebhooksLine.ago($0, now: now) }
        )
    }
}

/// Setup's Reconcile line: when the reconciler last ran and how often it runs, the changes made in Linear it applied, and
/// the drift found on phases Symphony owns (tickets moved by hand in Linear) and whether Symphony moved each back, from
/// `/api/v1/state`'s `reconcile` (`ReconcileReport`), which the window already polls. It is the operator's evidence that
/// dispatch from the record stays in step with Linear.
public struct ReconcileLine: Equatable {
    public enum State: Equatable {
        /// The Symphony running predates the reconciler.
        case notAvailable
        /// No run and no drift yet since Symphony started.
        case waiting
        /// It ran, and no drift was found.
        case clean
        /// Drift was found, and every move back that finished succeeded.
        case reverted
        /// At least one move back failed.
        case failing
    }

    /// One of the last drifts, as the disclosure lists it.
    public struct Row: Equatable, Identifiable {
        public var id: Int
        public var identifier: String
        /// "Code Review in the record, Done in Linear".
        public var states: String
        /// "Reverted", "Failed".
        public var outcome: String
        public var failed: Bool
        /// "4 min ago"; nil when Symphony didn't say.
        public var ago: String?
    }

    public static let title = "Reconcile"
    public static let disclosureTitle = "Last drift"
    public static let emptyList = "No drift since Symphony started."

    public var state: State
    /// "Not available", "No run yet", "No drift", "Drift reverted", "Drift not reverted".
    public var word: String
    /// What is true now, as two sentences: the runs, then what they did since Symphony started.
    public var detail: String
    /// The last ten drifts, newest first.
    public var rows: [Row]

    /// False for an older Symphony: the line is shown greyed out, with no disclosure.
    public var isAvailable: Bool { state != .notAvailable }
    /// True when the line is called out in the warning colour: a move back failed.
    public var isWarning: Bool { state == .failing }

    /// The line for `report` (nil from an older Symphony), its ages counted from `now`, the state's own time.
    public init(report: ReconcileReport?, now: Date) {
        guard let report else {
            state = .notAvailable
            word = "Not available"
            detail = "Not available on this Symphony: update it to see what the reconciler did."
            rows = []
            return
        }
        rows = report.recent.enumerated().map { index, drift in Self.row(drift, id: index, now: now) }
        let every = Overview.duration(report.intervalMs / 1_000)
        let runs =
            report.lastRunAt.map { "Last run \(LinearWebhooksLine.ago($0, now: now)), every \(every)." }
            ?? "No run yet since Symphony started. It runs every \(every) while dispatch reads Symphony's record."
        detail = "\(runs) Since Symphony started: \(Self.work(report))."
        if report.revertFailed > 0 {
            state = .failing
            word = "Drift not reverted"
        } else if report.detected > 0 {
            state = .reverted
            word = "Drift reverted"
        } else if report.lastRunAt != nil {
            state = .clean
            word = "No drift"
        } else {
            state = .waiting
            word = "No run yet"
        }
    }

    /// "3 changes from Linear applied, 1 drift detected and reverted", with the failed writes made again and the tickets
    /// read for the first time when there were any.
    static func work(_ report: ReconcileReport) -> String {
        var parts = [count(report.applied, "change from Linear applied", "changes from Linear applied")]
        if report.reapplied > 0 {
            parts.append(count(report.reapplied, "failed write to Linear made again", "failed writes to Linear made again"))
        }
        if report.unobservedFilled > 0 {
            parts.append(count(report.unobservedFilled, "ticket read for the first time", "tickets read for the first time"))
        }
        parts.append(drift(report))
        return parts.joined(separator: ", ")
    }

    /// "no drift detected", "1 drift detected and reverted", "3 drifts detected, 2 reverted, 1 failed to revert".
    static func drift(_ report: ReconcileReport) -> String {
        guard report.detected > 0 else { return "no drift detected" }
        let detected = count(report.detected, "drift detected", "drifts detected")
        if report.revertFailed == 0, report.reverted == report.detected { return "\(detected) and reverted" }
        let failed = report.revertFailed > 0 ? ", \(GitHubUpdatesCard.number(report.revertFailed)) failed to revert" : ""
        return "\(detected), \(GitHubUpdatesCard.number(report.reverted)) reverted\(failed)"
    }

    /// "no change from Linear applied", "1 change from Linear applied", "3 changes from Linear applied".
    static func count(_ count: Int, _ one: String, _ many: String) -> String {
        switch count {
        case 0: "no \(one)"
        case 1: "1 \(one)"
        default: "\(GitHubUpdatesCard.number(count)) \(many)"
        }
    }

    static func row(_ drift: ReconcileReport.Drift, id: Int, now: Date) -> Row {
        let outcome: String =
            switch drift.outcome {
            case .reverted: "Reverted"
            case .failed: "Failed"
            case .other(let text): text.replacingOccurrences(of: "_", with: " ").capitalized
            }
        return Row(
            id: id,
            identifier: drift.identifier,
            states: "\(drift.recordPhase ?? "unknown") in the record, \(drift.linearPhase ?? "unknown") in Linear",
            outcome: outcome,
            failed: drift.outcome == .failed,
            ago: drift.at.map { LinearWebhooksLine.ago($0, now: now) }
        )
    }
}
