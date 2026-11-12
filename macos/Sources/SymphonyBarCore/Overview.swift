import Foundation

/// The scope pop-up (C3, P6): all repos or one. It filters every count and row of the Overview, and later views
/// read it too. The app remembers it across relaunches under `defaultsKey`.
public enum OverviewScope: Equatable, Hashable {
    case all
    case repo(String)

    public static let defaultsKey = "SymphonyWindowScope"
    public static let allTitle = "All repos"

    /// The scope remembered as `stored`: a repo key, or nothing for all repos.
    public init(stored: String?) {
        let key = stored?.trimmingWhitespace() ?? ""
        self = key.isEmpty ? .all : .repo(key)
    }

    /// What the app remembers: the repo key, nil for all repos.
    public var stored: String? {
        switch self {
        case .all: nil
        case let .repo(key): key
        }
    }

    /// The scope remembered in `defaults`, all repos when none is.
    public static func load(from defaults: KeyValueStore) -> OverviewScope {
        OverviewScope(stored: defaults.object(forKey: defaultsKey) as? String)
    }

    /// Remembers the scope in `defaults`; all repos removes the key.
    public func save(to defaults: KeyValueStore) {
        defaults.set(stored, forKey: Self.defaultsKey)
    }

    public var title: String {
        switch self {
        case .all: Self.allTitle
        case let .repo(key): key
        }
    }

    /// What VoiceOver reads for the pop-up: "Scope, all repos".
    public var accessibilityLabel: String {
        "Scope, \(self == .all ? "all repos" : title)"
    }

    /// Whether a row of `repoKey` shows. A row whose repo isn't known shows only under all repos.
    public func includes(_ repoKey: String?) -> Bool {
        switch self {
        case .all: true
        case let .repo(key): repoKey == key
        }
    }

    public func includesAny(_ repoKeys: [String]) -> Bool {
        switch self {
        case .all: true
        case let .repo(key): repoKeys.contains(key)
        }
    }

    /// The pop-up's choices: all repos, then each repo in order. The current repo stays a choice while Symphony
    /// doesn't list it, so a remembered scope is never silently dropped.
    public static func choices(repos: [String], current: OverviewScope) -> [OverviewScope] {
        var keys = repos
        if case let .repo(key) = current, !keys.contains(key) { keys.append(key) }
        return [.all] + keys.sorted().map(OverviewScope.repo)
    }
}

/// What needs attention across every repo (what notifies, D14, and the sidebar's count), today's meters, and the
/// words and numbers every page writes durations and tokens in. Home's board is `HomeBoard`.
public enum Overview {
    /// A button at the end of a Needs attention row.
    public enum Fix: Equatable, Hashable {
        /// Opens the ticket's page (D3).
        case open(String)
        case openInLinear(URL)
        case openDiagnostics
        /// Opens Usage (D8).
        case openUsage
        /// `POST /api/v1/control/force` with `clear`.
        case stopForcing(String)
        /// Opens the Stop Run sheet (D12c); nothing stops until its button is pressed.
        case stopRun(String)
        /// Check Now: the ticket's PR and CI watcher reads and decides at once.
        case checkNow(String)
        /// Opens the ticket's page (D3), named in full where the row's first button is another one.
        case openTicket(String)
        /// Opens the Setup page (SU1).
        case openSetup
        /// S9: Symphony starts the relay of instant GitHub updates again (`restart_relay`).
        case restartRelay

        public var title: String {
            switch self {
            case .checkNow: PRWatchCard.checkNowTitle
            case .openTicket: "Open Ticket"
            case .open: "Open"
            case .openInLinear: "Open in Linear"
            case .openDiagnostics: "Open Diagnostics"
            case .openUsage: "Open Usage"
            case .stopForcing: "Stop Forcing"
            case .stopRun: StopRunSheet.buttonTitle
            case .openSetup: "Open Setup"
            case .restartRelay: GitHubUpdatesCard.Action.restartRelay.title
            }
        }
    }

    /// The kinds of problem Needs attention lists (P3).
    public enum ProblemKind: Equatable {
        /// No agent event for `stuckAfter` (DD7).
        case stuck
        /// `failedAttemptsLimit` failed attempts or more.
        case failing
        /// Routed to more than one repo, so it runs in none.
        case conflict
        /// A provider's usage limit holds new runs.
        case usageLimit
        /// Forced for longer than the configured stale time.
        case staleForced
        /// Processes left running after their runs ended.
        case strayProcesses
        /// A watched ticket with nothing under way and no reason anybody can act on (S17).
        case silentWait
        /// Setup found errors (SU1): one row for all of them.
        case setup
        /// S9: instant GitHub updates are on but don't arrive, so Symphony polls.
        case githubUpdates
    }

    public enum Severity: Int, Comparable {
        /// `status.you`: worth a look.
        case warning = 1
        /// `status.problem`: something is stuck or failing.
        case problem = 2

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// An attention row (C9). A ticket with several problems is one row, so the count is of things, not lines.
    public struct Problem: Equatable, Identifiable {
        /// The ticket identifier, or the hold or the processes it is about; stable across polls.
        public var id: String
        public var kinds: [ProblemKind]
        public var severity: Severity
        public var sentence: String
        /// How long it has been a problem, when known.
        public var ageSeconds: Int?
        /// What happens next when no button applies, for example "Runs resume by themselves."
        public var note: String?
        /// The first is the primary fix.
        public var fixes: [Fix]
        /// Where the ticket the row is about stands, under the sentence; nil for a row about no ticket.
        public var situation: Situation?

        public var age: String? { ageSeconds.map(Overview.duration) }

        /// The ticket the row is about, which Return and a double-click open; nil for a hold or stray processes.
        public var ticketIdentifier: String? {
            kinds.contains { [.stuck, .failing, .staleForced, .conflict, .silentWait].contains($0) } ? id : nil
        }
    }

    /// A meter of Today (C11): a ratio against a limit.
    public struct Meter: Equatable, Identifiable {
        /// accent below 75%, `status.you` from 75%, `status.problem` from 95%.
        public enum Level: Equatable {
            case normal, near, atLimit
        }

        public var id: String
        public var label: String
        /// "3.1M of 5M", "100% used".
        public var value: String
        /// From 0 to 1; nil when there is no limit to measure against.
        public var fraction: Double?
        /// "resets 15:40".
        public var note: String?

        public var level: Level { Overview.level(fraction) }

        /// "Tokens today, 62 percent of budget".
        public var accessibilityLabel: String {
            guard let fraction else { return "\(label), \(value)" }
            return "\(label), \(Int((fraction * 100).rounded())) percent" + (id == "tokens" ? " of budget" : " used")
        }
    }

    /// DD7: a run with no agent event for this long counts as stuck, as in the Repos window.
    public static let stuckAfter = RepoHealth.stuckAfter
    public static let failedAttemptsLimit = 3
    public static let nearLimit = 0.75
    public static let atLimit = 0.95

    public static let resumeTitle = "Resume Dispatch"

    /// What needs attention under `scope` (every repo for what notifies, D14), severest first. Ages are measured against
    /// Symphony's own clock (`generated_at`), `now` only when the state has none; clock times are in `timeZone`.
    public static func problems(_ state: OverviewState, scope: OverviewScope = .all, now: Date, timeZone: TimeZone = .current) -> [Problem] {
        problems(state: state, scope: scope, index: TicketIndex(state), reference: state.generatedAt ?? now, timeZone: timeZone)
    }

    // MARK: - Needs attention

    private struct Finding {
        var subject: String
        var kind: ProblemKind
        var severity: Severity
        var sentence: String
        var ageSeconds: Int?
        var note: String?
        var fixes: [Fix]
    }

    private static func problems(state: OverviewState, scope: OverviewScope, index: TicketIndex, reference: Date, timeZone: TimeZone) -> [Problem] {
        var findings: [Finding] = []

        for run in state.running where scope.includes(run.repoKey) {
            guard let idle = idleSeconds(run, reference: reference), isStuck(idleSeconds: idle) else { continue }
            findings.append(Finding(
                subject: run.identifier, kind: .stuck, severity: .problem,
                sentence: "\(run.identifier) shows no agent activity for \(duration(idle)).",
                ageSeconds: idle, fixes: [.stopRun(run.identifier), .open(run.identifier)]
            ))
        }

        for retry in state.retrying where scope.includes(retry.repoKey) && retry.attempt >= failedAttemptsLimit {
            let error = retry.error?.trimmingWhitespace() ?? ""
            findings.append(Finding(
                subject: retry.identifier, kind: .failing, severity: .problem,
                sentence: "\(retry.identifier) keeps failing" + (error.isEmpty ? "." : ": \(error)."),
                fixes: [.open(retry.identifier), .stopRun(retry.identifier)]
            ))
        }

        for conflict in state.conflicts where scope.includesAny(conflict.repoKeys) {
            let repos = conflict.repoKeys.isEmpty ? "" : " (\(conflict.repoKeys.joined(separator: ", ")))"
            findings.append(Finding(
                subject: conflict.identifier, kind: .conflict, severity: .warning,
                sentence: "\(conflict.identifier) matches more than one repo\(repos), so Symphony runs it in none.",
                note: "Fix its labels in Linear.",
                fixes: (conflict.url ?? index.url(identifier: conflict.identifier)).map { [.openInLinear($0)] } ?? []
            ))
        }

        for limit in state.snapshot.usageLimits where limit.phase != .canary {
            let resume = limit.resumeAt ?? limit.resetsAt
            let when = resume.map { " until \(StatusMenu.clockTime($0, now: reference, timeZone: timeZone, dateFormat: "MMM d, HH:mm"))" } ?? ""
            let what = limit.isAPIUnreachable ? StatusMenu.apiUnreachableName(limit) : "The \(StatusMenu.limitName(limit))"
            findings.append(Finding(
                subject: "usage-limit-\(limit.provider)-\(limit.scope)", kind: .usageLimit, severity: .warning,
                sentence: limit.isAPIUnreachable ? "\(what): new runs wait\(when)." : "\(what) holds new runs\(when).",
                note: "Runs resume by themselves.", fixes: limit.isAPIUnreachable ? [] : [.openUsage]
            ))
        }

        // A forced ticket no list names (a Todo held by blockers) has no known repo: it shows under every scope.
        for ticket in state.snapshot.forced where ticket.stale && index.repoKey(identifier: ticket.identifier).map(scope.includes) ?? true {
            let forFor = ticket.forcedForSeconds.map { " for \(duration($0))" } ?? ""
            let fixes: [Fix] = [.open(ticket.identifier), .stopForcing(ticket.identifier)]
            findings.append(Finding(
                subject: ticket.identifier, kind: .staleForced, severity: .warning,
                sentence: "\(ticket.identifier) has been forced\(forFor) and is still not done.",
                ageSeconds: ticket.forcedForSeconds, fixes: fixes
            ))
        }

        // S17: the watcher found nothing under way and no reason on it. A ticket of no known repo shows under every scope.
        for wait in state.silentWaits where (wait.repoKey ?? index.repoKey(identifier: wait.identifier)).map(scope.includes) ?? true {
            let phase = WatchBlock.phaseName(wait.phase).map { " in \($0)" } ?? ""
            findings.append(Finding(
                subject: wait.identifier, kind: .silentWait, severity: .problem,
                sentence: "\(wait.identifier)\(phase): \(PRWatchCard.silentSentence(bound: wait.bound)).",
                ageSeconds: wait.since.map { max(Int(reference.timeIntervalSince($0)), 0) },
                note: PRWatchCard.silentExpectation,
                fixes: [.checkNow(wait.identifier), .openTicket(wait.identifier)]
            ))
        }

        // SU1: one row for every setup error, whatever the scope: setup is the whole factory's.
        if let sentence = SetupSummary(payload: state.snapshot.setup).attentionSentence {
            findings.append(Finding(
                subject: "setup", kind: .setup, severity: .problem, sentence: sentence,
                note: "Symphony may skip tickets or fail quietly until they are fixed.", fixes: [.openSetup]
            ))
        }

        // S9: instant updates that stopped arriving, whatever the scope: they are the whole factory's.
        if let attention = GitHubUpdatesCard.attention(state.snapshot.setup?.githubUpdates) {
            findings.append(Finding(
                subject: "github-updates", kind: .githubUpdates, severity: .warning, sentence: attention.sentence,
                note: attention.note, fixes: (attention.restart ? [.restartRelay] : []) + [.openSetup]
            ))
        }

        let strays = state.strayProcesses.count
        if strays > 0 {
            findings.append(Finding(
                subject: "stray-processes", kind: .strayProcesses, severity: .warning,
                sentence: strays == 1 ? "1 process is still running from a finished run."
                    : "\(strays) processes are still running from finished runs.",
                fixes: [.openDiagnostics]
            ))
        }

        // One row per thing: a ticket's problems join in one row with all their fixes.
        var rows: [Problem] = []
        for finding in findings {
            if let index = rows.firstIndex(where: { $0.id == finding.subject }) {
                var row = rows[index]
                row.kinds.append(finding.kind)
                row.severity = max(row.severity, finding.severity)
                // The ticket is named once: "SHOP-305 shows no agent activity for 14 min. It has been forced…"
                let prefix = "\(finding.subject) "
                let sentence = finding.sentence.hasPrefix(prefix) ? "It " + finding.sentence.dropFirst(prefix.count) : finding.sentence
                row.sentence += " \(sentence)"
                row.ageSeconds = [row.ageSeconds, finding.ageSeconds].compactMap { $0 }.max()
                row.note = row.note ?? finding.note
                row.fixes += finding.fixes.filter { !row.fixes.contains($0) }
                rows[index] = row
            } else {
                rows.append(Problem(
                    id: finding.subject, kinds: [finding.kind], severity: finding.severity, sentence: finding.sentence,
                    ageSeconds: finding.ageSeconds, note: finding.note, fixes: finding.fixes,
                    situation: state.snapshot.situation(finding.subject)
                ))
            }
        }
        // Severity first, then the oldest; a problem of unknown age after those of its severity with an age.
        return rows.enumerated().sorted { lhs, rhs in
            let left = lhs.element, right = rhs.element
            if left.severity != right.severity { return left.severity > right.severity }
            if left.ageSeconds != right.ageSeconds { return (left.ageSeconds ?? -1) > (right.ageSeconds ?? -1) }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Seconds since a run's last agent event, or since it started before the first.
    public static func idleSeconds(_ run: OverviewState.Run, reference: Date) -> Int? {
        (run.lastEventAt ?? run.startedAt).map { Int(reference.timeIntervalSince($0)) }
    }

    /// DD7: stuck from `stuckAfter` without an agent event.
    public static func isStuck(idleSeconds: Int) -> Bool {
        TimeInterval(idleSeconds) >= stuckAfter
    }

    /// While the pointer is over a list, a poll keeps the rows it already shows in their places and adds new ones
    /// below them (P7). `previous` is the order shown; ids no longer in `next` leave.
    public static func holdingOrder(_ next: [String], previous: [String]) -> [String] {
        let present = Set(next)
        let kept = previous.filter(present.contains)
        let keptSet = Set(kept)
        return kept + next.filter { !keptSet.contains($0) }
    }

    // MARK: - Parts

    /// "implementation" → "Implementation", "plan_revision" → "Plan revision".
    static func phaseName(_ runKind: String) -> String {
        let words = runKind.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func pauseSentence(_ pause: StateSnapshot.Pause, reference: Date, timeZone: TimeZone) -> String {
        var sentence = "Dispatch is paused"
        if let since = pause.since {
            sentence += " since \(StatusMenu.clockTime(since, now: reference, timeZone: timeZone, dateFormat: "MMM d, HH:mm"))"
        }
        let reason = pause.reason?.trimmingWhitespace() ?? ""
        if !reason.isEmpty {
            sentence += ": \(reason)"
            if !reason.hasSuffix(".") { sentence += "." }
        } else {
            sentence += "."
        }
        return sentence
    }

    static func meters(_ snapshot: StateSnapshot, reference: Date, timeZone: TimeZone) -> [Meter] {
        var meters: [Meter] = []
        if let budget = snapshot.budget {
            if let limit = budget.dailyLimit, limit > 0 {
                meters.append(Meter(
                    id: "tokens", label: "Tokens today", value: "\(tokens(budget.dailyUsed)) of \(tokens(limit))",
                    fraction: min(Double(budget.dailyUsed) / Double(limit), 1),
                    note: budget.dailyPaused ? "The daily budget holds new runs." : nil
                ))
            } else {
                meters.append(Meter(id: "tokens", label: "Tokens today", value: "\(tokens(budget.dailyUsed)) tokens, no daily budget", fraction: nil, note: nil))
            }
        }
        for limit in snapshot.usageLimits {
            guard let utilization = limit.utilization else { continue }
            let resets = (limit.resetsAt ?? limit.resumeAt).map { "resets \(StatusMenu.clockTime($0, now: reference, timeZone: timeZone, dateFormat: "MMM d, HH:mm"))" }
            meters.append(Meter(
                id: "limit-\(limit.provider)-\(limit.scope)-\(limit.window ?? "")", label: StatusMenu.limitName(limit),
                value: "\(Int((utilization * 100).rounded()))% used", fraction: min(max(utilization, 0), 1), note: resets
            ))
        }
        return meters
    }

    static func level(_ fraction: Double?) -> Meter.Level {
        guard let fraction else { return .normal }
        if fraction >= atLimit { return .atLimit }
        if fraction >= nearLimit { return .near }
        return .normal
    }

    // MARK: - Words and numbers

    /// "14 s", "14 min", "3 h 12 min", "3 h", "2 days" (design system §7).
    public static func duration(_ seconds: Int) -> String {
        let seconds = max(seconds, 0)
        switch seconds {
        case ..<60:
            return "\(seconds) s"
        case ..<3_600:
            return "\(seconds / 60) min"
        case ..<86_400:
            let minutes = seconds % 3_600 / 60
            return minutes == 0 ? "\(seconds / 3_600) h" : "\(seconds / 3_600) h \(minutes) min"
        default:
            let days = seconds / 86_400
            return days == 1 ? "1 day" : "\(days) days"
        }
    }

    /// The same duration as VoiceOver should read it: "3 hours 12 minutes".
    public static func spokenDuration(_ seconds: Int) -> String {
        func unit(_ value: Int, _ name: String) -> String { "\(value) \(name)\(value == 1 ? "" : "s")" }
        let seconds = max(seconds, 0)
        switch seconds {
        case ..<60:
            return unit(seconds, "second")
        case ..<3_600:
            return unit(seconds / 60, "minute")
        case ..<86_400:
            let minutes = seconds % 3_600 / 60
            return unit(seconds / 3_600, "hour") + (minutes == 0 ? "" : " \(unit(minutes, "minute"))")
        default:
            return unit(seconds / 86_400, "day")
        }
    }

    /// "1,284", "845K", "3.1M", "5M" (design system §7).
    public static func tokens(_ count: Int) -> String {
        func short(_ value: Double, _ suffix: String) -> String {
            let rounded = (value * 10).rounded() / 10
            let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
            return text + suffix
        }
        switch count {
        case ..<10_000:
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = ","
            formatter.usesGroupingSeparator = true
            return formatter.string(from: NSNumber(value: count)) ?? String(count)
        case ..<1_000_000:
            return "\(count / 1_000)K"
        default:
            return short(Double(count) / 1_000_000, "M")
        }
    }

}

/// Every ticket the state names, to find its identifier, repo, title and Linear URL from any list.
private struct TicketIndex {
    private var identifiers: [String: String] = [:]
    private var reposByID: [String: String] = [:]
    private var reposByIdentifier: [String: String] = [:]
    private var titles: [String: String] = [:]
    private var urls: [String: URL] = [:]
    /// `https://linear.app/<workspace>/issue/`, from any ticket URL, for a ticket whose own URL isn't served.
    private var issueBase: String?

    init(_ state: OverviewState) {
        for run in state.running {
            add(issueID: run.issueID, identifier: run.identifier, repoKey: run.repoKey, title: run.title, url: run.url)
        }
        for ticket in state.watching + state.shippedToday {
            add(issueID: ticket.issueID, identifier: ticket.identifier, repoKey: ticket.repoKey, title: ticket.title, url: ticket.url)
        }
        for waiting in state.slotWaiting {
            add(issueID: waiting.issueID, identifier: waiting.identifier, repoKey: waiting.repoKey, title: waiting.title, url: nil)
        }
        for retry in state.retrying {
            add(issueID: retry.issueID, identifier: retry.identifier, repoKey: retry.repoKey, title: retry.title, url: nil)
        }
        for conflict in state.conflicts {
            add(issueID: nil, identifier: conflict.identifier, repoKey: nil, title: conflict.title, url: conflict.url)
        }
    }

    private mutating func add(issueID: String?, identifier: String, repoKey: String?, title: String?, url: URL?) {
        if let issueID {
            identifiers[issueID] = identifiers[issueID] ?? identifier
            if let repoKey { reposByID[issueID] = reposByID[issueID] ?? repoKey }
        }
        if let repoKey { reposByIdentifier[identifier] = reposByIdentifier[identifier] ?? repoKey }
        if let title { titles[identifier] = titles[identifier] ?? title }
        if let url {
            urls[identifier] = urls[identifier] ?? url
            if issueBase == nil, let range = url.absoluteString.range(of: "/issue/") {
                issueBase = String(url.absoluteString[..<range.upperBound])
            }
        }
    }

    func identifier(issueID: String) -> String? { identifiers[issueID] }
    func repoKey(issueID: String) -> String? { reposByID[issueID] }
    func repoKey(identifier: String) -> String? { reposByIdentifier[identifier] }
    func title(identifier: String) -> String? { titles[identifier] }

    /// The ticket's Linear URL, or one built from the workspace's issue path.
    func url(identifier: String) -> URL? {
        urls[identifier] ?? issueBase.flatMap { URL(string: $0 + identifier) }
    }
}
