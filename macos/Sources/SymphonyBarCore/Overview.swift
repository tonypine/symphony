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

/// The Overview (D1): a sentence, the flow strip, what needs attention, what is working and what is next, and
/// today's spend, all from one state payload. Pure, so each of the four states is tested against its fixture.
public struct Overview: Equatable {
    /// Which of the four states the sentence says (P1).
    public enum Mood: Equatable {
        case flowing, attention, paused, idle
    }

    /// A stage of the flow strip (P2), left to right.
    public enum StageKind: String, CaseIterable, Equatable {
        case queued, working, autoReview, waitingOnYou, merging, shippedToday

        public var title: String {
            switch self {
            case .queued: "Queued"
            case .working: "Working"
            case .autoReview: "Auto Review"
            case .waitingOnYou: "Waiting on you"
            case .merging: "Merging"
            case .shippedToday: "Shipped today"
            }
        }
    }

    /// A stat tile (C5): a count, its label and one line of context.
    public struct Stage: Equatable, Identifiable {
        public var kind: StageKind
        public var count: Int
        public var context: String
        /// The context as VoiceOver reads it, durations in words.
        public var spokenContext: String

        public var id: StageKind { kind }
        public var title: String { kind.title }
        /// A stage at 0 keeps its place in tertiary text.
        public var isZero: Bool { count == 0 }
        /// Only Waiting on you carries a status tint, and only while something waits.
        public var isTinted: Bool { kind == .waitingOnYou && count > 0 }
        /// One element for VoiceOver: "Waiting on you, 4, oldest 3 hours".
        public var accessibilityLabel: String { "\(title), \(count), \(spokenContext)" }
    }

    /// A button at the end of a Needs attention row.
    public enum Fix: Equatable, Hashable {
        /// Opens the ticket's page (D3).
        case open(String)
        case openInLinear(URL)
        case openDiagnostics
        /// `POST /api/v1/control/force` with `clear`.
        case stopForcing(String)
        /// Opens the Stop Run sheet (D12c); nothing stops until its button is pressed.
        case stopRun(String)

        public var title: String {
            switch self {
            case .open: "Open"
            case .openInLinear: "Open in Linear"
            case .openDiagnostics: "Open Diagnostics"
            case .stopForcing: "Stop Forcing"
            case .stopRun: StopRunSheet.buttonTitle
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

        public var age: String? { ageSeconds.map(Overview.duration) }

        /// The ticket the row is about, which Return and a double-click open; nil for a hold or stray processes.
        public var ticketIdentifier: String? {
            kinds.contains { [.stuck, .failing, .staleForced, .conflict].contains($0) } ? id : nil
        }
    }

    /// A row of Now working (C8): an agent run, a QA pass or a landing.
    public struct WorkingRow: Equatable, Identifiable {
        public enum Kind: Equatable {
            case agent, qaPass, landing
        }

        public var id: String
        public var kind: Kind
        public var identifier: String
        public var title: String?
        public var repoKey: String?
        /// "Implementation", "QA pass", "Landing".
        public var phase: String
        public var turn: Int?
        /// "12 s ago", from the run's last agent event.
        public var lastActivity: String?
        public var lastMessage: String?
        public var runningTime: String?
        public var tokens: String?
        public var url: URL?
        /// No agent event for `stuckAfter`.
        public var isStuck: Bool

        /// The second line: "Implementation · turn 7 · last activity 12 s ago".
        public var detail: String {
            var parts = [phase]
            if let turn, turn > 0 { parts.append("turn \(turn)") }
            if let lastActivity { parts.append("last activity \(lastActivity)") }
            return parts.joined(separator: " · ")
        }
    }

    /// A row of Next up: a queued ticket and why it waits.
    public struct QueuedRow: Equatable, Identifiable {
        public var id: String { identifier }
        public var identifier: String
        public var title: String?
        public var repoKey: String?
        public var reason: String
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
    public static let nextUpLimit = 5
    public static let nearLimit = 0.75
    public static let atLimit = 0.95

    public static let resumeTitle = "Resume Dispatch"
    public static let allCaughtUp = "All caught up."
    public static let nowWorkingTitle = "Now working"
    public static let nextUpTitle = "Next up"
    public static let needsAttentionTitle = "Needs attention"
    public static let todayTitle = "Today"
    public static let reposTitle = "Repos"

    public var mood: Mood
    public var sentence: String
    public var context: String
    public var stages: [Stage]
    public var problems: [Problem]
    public var working: [WorkingRow]
    public var nextUp: [QueuedRow]
    public var meters: [Meter]
    /// Repos health in one line, nil until Symphony listed its repos.
    public var reposLine: String?

    /// The sentence offers Resume Dispatch while dispatch is paused.
    public var showsResume: Bool { mood == .paused }
    /// The main column says "All caught up." while the factory is idle.
    public var showsAllCaughtUp: Bool { mood == .idle }

    // MARK: - Building

    /// The Overview of `state` under `scope`. Ages are measured against Symphony's own clock (`generated_at`),
    /// `now` only when the state has none. Clock times are in `timeZone`.
    public init(state: OverviewState, scope: OverviewScope = .all, repos: ReposPoll? = nil, now: Date, timeZone: TimeZone = .current) {
        let reference = state.generatedAt ?? now
        let index = TicketIndex(state)
        let paused = state.snapshot.pause != nil

        // The flow strip's tickets, by stage, as identifiers.
        let landingIDs = Set(state.landing)
        let scopedRuns = state.running.filter { scope.includes($0.repoKey) }
        let isLanding: (OverviewState.Run) -> Bool = { run in
            run.issueID.map(landingIDs.contains) == true || Self.isState(run.state, "Merging")
        }
        let agentRuns = scopedRuns.filter { !isLanding($0) }
        let landingRuns = scopedRuns.filter(isLanding)
        let runningIDs = Set(state.running.map(\.identifier))

        let waiting = state.slotWaiting.filter { scope.includes($0.repoKey) }
        let queuedWaiting = waiting.filter { !Self.isState($0.state, "Merging") && !runningIDs.contains($0.identifier) }
        let queuedRetries = state.retrying.filter { scope.includes($0.repoKey) && !runningIDs.contains($0.identifier) }
        let queued = Self.unique(queuedWaiting.map(\.identifier) + queuedRetries.map(\.identifier))

        let working = Self.unique(agentRuns.map(\.identifier))

        let qaIdentifiers = (state.qaRunning + state.qaQueued).compactMap { id -> String? in
            guard scope.includes(index.repoKey(issueID: id)) else { return nil }
            return index.identifier(issueID: id) ?? id
        }
        let autoReview = Self.unique(
            state.watching.filter { Self.isState($0.state, "Auto Review") && scope.includes($0.repoKey) }.map(\.identifier)
                + qaIdentifiers
        )

        // The Inbox's items, as the state lists them: the same count as the sidebar badge and the menu (US1).
        let waitingOnYou = state.snapshot.waitingOnYou.filter { scope.includes($0.repoKey) }

        let merging = Self.unique(
            state.watching.filter { Self.isState($0.state, "Merging") && scope.includes($0.repoKey) }.map(\.identifier)
                + landingRuns.map(\.identifier)
                + waiting.filter { Self.isState($0.state, "Merging") }.map(\.identifier)
        )

        let shipped = state.shippedToday.filter { scope.includes($0.repoKey) }
        let shippedCount = scope == .all ? (state.shippedTodayCount ?? shipped.count) : shipped.count

        let oldestWaitingOnYou = waitingOnYou.compactMap(\.waitingSeconds).max()
        let longestRun = agentRuns.compactMap { $0.startedAt.map { Int(reference.timeIntervalSince($0)) } }.max()
        let scopedQA = state.qaRunning.filter { scope.includes(index.repoKey(issueID: $0)) }

        stages = [
            Stage(
                kind: .queued,
                count: queued.count,
                context: queued.isEmpty ? "Nothing queued" : paused ? "held by the pause" : "next: \(queued[0])"
            ),
            Stage(
                kind: .working,
                count: working.count,
                context: working.isEmpty ? "No runs" : paused ? "finishing" : longestRun.map { "longest \(Self.duration($0))" } ?? "running",
                spoken: working.isEmpty || paused ? nil : longestRun.map { "longest \(Self.spokenDuration($0))" }
            ),
            Stage(
                kind: .autoReview,
                count: autoReview.count,
                context: autoReview.isEmpty ? "None" : scopedQA.isEmpty ? "waiting on checks"
                    : scopedQA.count == 1 ? "1 QA pass running" : "\(scopedQA.count) QA passes running"
            ),
            Stage(
                kind: .waitingOnYou,
                count: waitingOnYou.count,
                context: waitingOnYou.isEmpty ? "Nothing waits on you"
                    : oldestWaitingOnYou.map { "oldest \(Self.duration($0))" } ?? "in the Inbox",
                spoken: waitingOnYou.isEmpty ? nil : oldestWaitingOnYou.map { "oldest \(Self.spokenDuration($0))" }
            ),
            Stage(
                kind: .merging,
                count: merging.count,
                context: merging.isEmpty ? "None" : landingRuns.isEmpty ? "waiting on CI" : "\(landingRuns.count) landing"
            ),
            Stage(
                kind: .shippedToday,
                count: shippedCount,
                context: shippedCount == 0 ? "None yet" : shipped.first.map { "latest \($0.identifier)" } ?? "today"
            ),
        ]

        problems = Self.problems(state: state, scope: scope, index: index, reference: reference, timeZone: timeZone)

        // The sentence and its context line (P1).
        let inProgress = Self.unique(queued + working + autoReview + waitingOnYou.map(\.identifier) + merging)
        if let pause = state.snapshot.pause {
            mood = .paused
            sentence = Self.pauseSentence(pause, reference: reference, timeZone: timeZone)
            let finishing = scopedRuns.count
            context = (finishing == 0 ? "Nothing is running." : finishing == 1 ? "1 run is finishing." : "\(finishing) runs are finishing.")
                + " No new run starts until you resume, forced tickets included."
        } else if !problems.isEmpty {
            mood = .attention
            sentence = problems.count == 1 ? "1 thing needs attention." : "\(problems.count) things need attention."
            context = Self.flowContext(inProgress: inProgress, index: index, scope: scope, waitingOnYou: waitingOnYou.count, oldest: oldestWaitingOnYou)
        } else if inProgress.isEmpty {
            mood = .idle
            sentence = "The factory is idle."
            context = "Nothing is queued and nothing waits on you. Tickets moved to Todo in Linear start here."
        } else {
            mood = .flowing
            sentence = "The factory is flowing."
            context = Self.flowContext(inProgress: inProgress, index: index, scope: scope, waitingOnYou: waitingOnYou.count, oldest: oldestWaitingOnYou)
        }

        // Now working: agent runs and landings in the order they started, so a new run joins at the end, then the
        // QA passes.
        let runRows = scopedRuns
            .enumerated()
            .sorted { ($0.element.startedAt ?? .distantFuture, $0.offset) < ($1.element.startedAt ?? .distantFuture, $1.offset) }
            .map { Self.workingRow($0.element, landing: isLanding($0.element), reference: reference) }
        let passRows = Self.unique(state.qaRunning).compactMap { id -> WorkingRow? in
            let identifier = index.identifier(issueID: id) ?? id
            guard scope.includes(index.repoKey(issueID: id)), !runningIDs.contains(identifier) else { return nil }
            return WorkingRow(
                id: "qa-\(id)", kind: .qaPass, identifier: identifier, title: index.title(identifier: identifier),
                repoKey: index.repoKey(issueID: id), phase: "QA pass", turn: nil, lastActivity: nil, lastMessage: nil,
                runningTime: nil, tokens: nil, url: index.url(identifier: identifier), isStuck: false
            )
        }
        self.working = runRows + passRows

        // Next up: tickets waiting for a slot, longest first, then retries in the order they come due.
        let waitingRows = queuedWaiting
            .enumerated()
            .sorted { ($0.element.since ?? .distantFuture, $0.offset) < ($1.element.since ?? .distantFuture, $1.offset) }
            .map { QueuedRow(identifier: $0.element.identifier, title: $0.element.title, repoKey: $0.element.repoKey, reason: $0.element.reason ?? "waiting for a slot") }
        let retryRows = queuedRetries
            .enumerated()
            .sorted { ($0.element.dueAt ?? .distantFuture, $0.offset) < ($1.element.dueAt ?? .distantFuture, $1.offset) }
            .map { entry in
                let retry = entry.element
                let when = retry.dueAt.map { " at \(StatusMenu.clockTime($0, now: reference, timeZone: timeZone, dateFormat: "MMM d HH:mm"))" } ?? ""
                return QueuedRow(identifier: retry.identifier, title: retry.title, repoKey: retry.repoKey, reason: "retries\(when) after \(retry.attempt) failed attempt\(retry.attempt == 1 ? "" : "s")")
            }
        var seen = Set<String>()
        nextUp = Array((waitingRows + retryRows).filter { seen.insert($0.identifier).inserted }.prefix(Self.nextUpLimit))

        meters = Self.meters(state.snapshot, reference: reference, timeZone: timeZone)
        reposLine = repos.flatMap { Self.reposLine($0, scope: scope, runs: state.snapshot.runs, reference: reference) }
    }

    /// The count on the sidebar's Overview item: what needs attention in every repo, whatever the scope (P6).
    public static func badgeCount(_ state: OverviewState, now: Date) -> Int {
        problems(state, now: now).count
    }

    /// What needs attention in every repo, whatever the scope: what notifies (D14).
    public static func problems(_ state: OverviewState, now: Date) -> [Problem] {
        problems(state: state, scope: .all, index: TicketIndex(state), reference: state.generatedAt ?? now, timeZone: .current)
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
                sentence: "\(retry.identifier) failed \(retry.attempt) times" + (error.isEmpty ? "." : ": \(error)."),
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
                note: "Runs resume by themselves.", fixes: []
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
                    ageSeconds: finding.ageSeconds, note: finding.note, fixes: finding.fixes
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

    private static func workingRow(_ run: OverviewState.Run, landing: Bool, reference: Date) -> WorkingRow {
        let idle = idleSeconds(run, reference: reference)
        let phase = landing ? "Landing" : run.runKind.map(phaseName) ?? run.state ?? "Working"
        let message = run.lastMessage?.trimmingWhitespace() ?? ""
        return WorkingRow(
            id: run.issueID ?? run.identifier,
            kind: landing ? .landing : .agent,
            identifier: run.identifier,
            title: run.title,
            repoKey: run.repoKey,
            phase: phase,
            turn: run.turnCount,
            lastActivity: run.lastEventAt.flatMap { _ in idle.map { "\(duration($0)) ago" } },
            lastMessage: message.isEmpty ? nil : message,
            runningTime: run.startedAt.map { duration(Int(reference.timeIntervalSince($0))) },
            tokens: run.totalTokens > 0 ? "\(tokens(run.totalTokens)) tokens" : nil,
            url: run.url,
            isStuck: idle.map(isStuck(idleSeconds:)) ?? false
        )
    }

    /// "implementation" → "Implementation", "plan_revision" → "Plan revision".
    static func phaseName(_ runKind: String) -> String {
        let words = runKind.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private static func pauseSentence(_ pause: StateSnapshot.Pause, reference: Date, timeZone: TimeZone) -> String {
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

    /// "10 tickets in progress across 3 repos. 4 wait on you, the oldest for 3 h 12 min."
    private static func flowContext(inProgress: [String], index: TicketIndex, scope: OverviewScope, waitingOnYou: Int, oldest: Int?) -> String {
        let count = inProgress.count
        let tickets = count == 1 ? "1 ticket in progress" : "\(count) tickets in progress"
        let repos = Set(inProgress.compactMap { index.repoKey(identifier: $0) })
        let place: String
        if case let .repo(key) = scope {
            place = " in \(key)"
        } else if repos.count == 1, let repo = repos.first {
            place = " in \(repo)"
        } else if repos.count > 1 {
            place = " across \(repos.count) repos"
        } else {
            place = ""
        }
        let waiting: String
        switch waitingOnYou {
        case 0:
            waiting = "Nothing waits on you."
        case 1:
            waiting = "1 waits on you" + (oldest.map { ", for \(duration($0))." } ?? ".")
        default:
            waiting = "\(waitingOnYou) wait on you" + (oldest.map { ", the oldest for \(duration($0))." } ?? ".")
        }
        return "\(tickets)\(place). \(waiting)"
    }

    private static func meters(_ snapshot: StateSnapshot, reference: Date, timeZone: TimeZone) -> [Meter] {
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

    /// "3 repos healthy", or "2 of 3 repos healthy. api is not working." Nil when Symphony didn't list its repos.
    private static func reposLine(_ poll: ReposPoll, scope: OverviewScope, runs: [StateSnapshot.Run], reference: Date) -> String? {
        guard case let .repos(all, _) = poll else { return nil }
        let repos = all.filter { scope.includes($0.key) }
        guard !repos.isEmpty else { return nil }
        let unhealthy = repos.compactMap { repo -> String? in
            let health = RepoHealth.of(repo, warning: nil, runs: runs, pending: nil, now: reference)
            switch health.status {
            case .healthy, .notChecked: return nil
            case .needsAttention: return "\(repo.key) needs attention"
            case .notWorking: return "\(repo.key) is not working"
            }
        }
        if repos.count == 1 {
            return unhealthy.first.map { "\($0)." } ?? "\(repos[0].key) is healthy."
        }
        guard !unhealthy.isEmpty else { return "\(repos.count) repos healthy." }
        return "\(repos.count - unhealthy.count) of \(repos.count) repos healthy. \(unhealthy.joined(separator: "; "))."
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

    // MARK: - Helpers

    private static func isState(_ state: String?, _ name: String) -> Bool {
        state?.trimmingWhitespace().caseInsensitiveCompare(name) == .orderedSame
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

private extension Overview.Stage {
    init(kind: Overview.StageKind, count: Int, context: String, spoken: String? = nil) {
        self.init(kind: kind, count: count, context: context, spokenContext: spoken ?? context)
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
        for ticket in state.watching + state.humanReview + state.shippedToday {
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
