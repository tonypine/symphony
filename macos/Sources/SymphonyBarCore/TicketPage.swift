import Foundation

/// D3: everything about one ticket on one page (principle 5): its header, what runs now, the timeline of every run
/// and event (C14), its facts and the agent's last message. Built from `/api/v1/state`, `/api/v1/:issue_identifier`
/// (404 once Symphony no longer tracks the ticket), `/api/v1/runs` and the ticket's audit records, any of which may be
/// missing: the page shows what the others say.
public struct TicketPage: Equatable {
    /// What the ticket is doing now, the line under the header.
    public enum Phase: Equatable {
        /// An agent runs on it; `stuck` after `Overview.stuckAfter` without an agent event.
        case working(stuck: Bool)
        /// It waits on something: "you", "CI", "a blocker", "a slot", "a retry at 14:32".
        case waiting(on: String)
        /// In review: Auto Review's QA pass and the gate's verdict, when known.
        case inReview(gate: String?, qa: String?)
        /// Done: its pull request and when it merged, when known.
        case done(pullRequest: URL?, mergedAt: Date?)
        /// Symphony says nothing about it now.
        case unknown
    }

    /// C7: a status badge in the header.
    public struct Badge: Equatable {
        public var status: DesignTokens.Status
        public var word: String
    }

    /// Now: the run under way.
    public struct Now: Equatable {
        /// "Implementation run 2".
        public var run: String
        /// "claude-opus-5-5 · high", nil when Symphony didn't say.
        public var model: String?
        public var runningTime: String?
        public var turn: Int?
        /// "14 min ago".
        public var lastActivity: String?
        /// The tool call it waits on: "waiting on mix test for 14 min".
        public var pendingTool: String?
        public var workspace: String?
        /// The run's tokens against the per-ticket cap (C11).
        public var tokens: Overview.Meter
    }

    /// A row of the Ticket card.
    public struct Fact: Equatable {
        public var label: String
        public var value: String
        public var url: URL?

        public init(label: String, value: String, url: URL? = nil) {
            self.label = label
            self.value = value
            self.url = url
        }
    }

    /// C14: a step of the timeline.
    public struct Step: Equatable, Identifiable {
        public enum Result: Equatable {
            case done, current, failed, stopped
        }

        public var id: String
        public var time: Date
        /// "13:03", or "Oct 6, 13:03" before today.
        public var timeText: String
        /// "Implementation run 1", "Gate: approve", "Stopped by you".
        public var title: String
        public var result: Result
        /// "failed", "done", "running"; nil when the title says it.
        public var resultWord: String?
        public var durationSeconds: Int?
        public var tokens: Int?
        /// The run's error, the note posted with a move.
        public var detail: String?

        public var duration: String? { durationSeconds.map(Overview.duration) }
        public var tokensText: String? { tokens.flatMap { $0 > 0 ? Overview.tokens($0) : nil } }

        /// One element for VoiceOver: "13:03, implementation run 1, failed, 22 minutes".
        public var accessibilityLabel: String {
            let title = title.prefix(1).lowercased() + title.dropFirst()
            return [timeText, title, resultWord, durationSeconds.map(Overview.spokenDuration)]
                .compactMap { $0 }
                .joined(separator: ", ")
        }
    }

    /// A stop the Director made from the app that the audit records may not show yet.
    public struct LocalStop: Equatable {
        public var identifier: String
        public var at: Date
        public var movedToBacklog: Bool
        public var note: String?

        public init(identifier: String, at: Date, movedToBacklog: Bool, note: String? = nil) {
            self.identifier = identifier
            self.at = at
            self.movedToBacklog = movedToBacklog
            self.note = note
        }
    }

    /// What the page is built from: each endpoint's body, nil when it didn't answer.
    public struct Sources: Equatable {
        public var state: Data?
        public var issue: Data?
        public var runs: Data?
        /// NDJSON bodies of `/api/v1/audit`, one per query.
        public var audit: [Data]
        public var stops: [LocalStop]

        public init(state: Data? = nil, issue: Data? = nil, runs: Data? = nil, audit: [Data] = [], stops: [LocalStop] = []) {
            self.state = state
            self.issue = issue
            self.runs = runs
            self.audit = audit
            self.stops = stops
        }
    }

    public static let stoppedByYou = "Stopped by you"
    public static let movedToBacklog = "moved to Backlog"
    public static let viewTranscriptTitle = "View Transcript"
    public static let openInLinearTitle = "Open in Linear"
    public static let copyAPIURLTitle = "Copy API URL"
    public static let showAuditRecordsTitle = "Show Audit Records"
    public static let revealWorktreeTitle = "Reveal Worktree"
    /// The audit record types the timeline reads; each is its own query, as the API filters on one type.
    public static let auditTypes = ["run_stopped", "director_move"]
    /// How many days of audit records the page reads.
    public static let auditDays = 14
    /// A Backlog move this soon after a stop is part of it: "Stopped by you, moved to Backlog".
    static let stopMoveWindow: TimeInterval = 120

    public var identifier: String
    public var title: String?
    public var repoKey: String?
    /// "SHOP-300 Gift cards", the plan the ticket is a sub-ticket of.
    public var initiative: String?
    /// The ticket in Linear.
    public var url: URL?
    public var badges: [Badge]
    public var phase: Phase
    public var now: Now?
    /// Oldest first; the current step last.
    public var timeline: [Step]
    public var facts: [Fact]
    public var lastMessage: String?
    /// "13:40", or "Oct 6, 13:40" before today: when a done ticket merged.
    public var mergedText: String?
    /// The run's session, for Copy Session ID; nil without a run.
    public var sessionID: String?
    public var workspacePath: String?
    /// Whether an agent runs on the ticket, so Stop has something to stop.
    public var isRunning: Bool
    /// Whether Symphony tracks the ticket now, so its transcript endpoint answers.
    public var isTracked: Bool

    /// The line under the header: "Working", "Waiting on a retry at 14:32", "Done, merged 13:40".
    public var phaseSentence: String {
        switch phase {
        case .working(stuck: false): return "Working"
        case .working(stuck: true): return "Working, but no agent activity for a while"
        case let .waiting(on): return "Waiting on \(on)"
        case let .inReview(gate, qa):
            return (["In review"] + [qa, gate].compactMap { $0 }).joined(separator: " · ")
        case .done: return "Done"
        case .unknown: return "Symphony isn't working on \(identifier) right now"
        }
    }

    /// The ticket's API path, for Copy API URL.
    public var apiPath: String { Self.issuePath(identifier) }

    public static func issuePath(_ identifier: String) -> String { "api/v1/\(identifier)" }
    public static let runsPath = "api/v1/runs"

    /// The transcript endpoint for the ticket: under its repo when known, so a multi-repo Symphony finds it.
    public static func transcriptPath(_ identifier: String, repoKey: String?) -> String {
        guard let repoKey, !repoKey.isEmpty else { return "api/v1/issues/\(identifier)/transcript" }
        return "api/v1/repos/\(repoKey)/issues/\(identifier)/transcript"
    }

    /// The audit queries the timeline reads: one per type, over the last `auditDays` days (UTC, as Symphony's files).
    public static func auditPaths(_ identifier: String, now: Date) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let to = formatter.string(from: now)
        let from = formatter.string(from: now.addingTimeInterval(-Double(auditDays - 1) * 86_400))
        let issue = identifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? identifier
        return auditTypes.map { "api/v1/audit?issue=\(issue)&type=\($0)&from=\(from)&to=\(to)" }
    }

    /// The web dashboard's Audit view filtered to the ticket, as the app's Audit view is deferred.
    public static func auditRecordsURL(_ identifier: String, base: URL) -> URL? {
        var components = URLComponents(url: base.appendingPathComponent("audit"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "issue", value: identifier)]
        return components?.url
    }

    // MARK: - Building

    public init(identifier: String, sources: Sources, now: Date = Date(), timeZone: TimeZone = .current) {
        let state = sources.state.flatMap { try? Self.decoder.decode(StatePayload.self, from: $0) }
        let issue = sources.issue.flatMap { try? Self.decoder.decode(IssuePayload.self, from: $0) }
        let runs = sources.runs.flatMap { try? Self.decoder.decode(RunsPayload.self, from: $0) }?.runs ?? []
        // A record two queries both return (a server that ignores the type filter) counts once.
        var seenRecords = Set<String>()
        let audit = sources.audit.flatMap(Self.auditRecords).filter { record in
            record.issueIdentifier == identifier && record.recordHash.map { seenRecords.insert($0).inserted } ?? true
        }
        let reference = state?.generatedAt.flatMap(Self.date) ?? now

        func matches(_ entry: Entry) -> Bool { entry.issueIdentifier == identifier }
        let running = state?.running?.first(where: matches)
        let retry = state?.retrying?.first(where: matches)
        let watching = state?.watching?.first(where: matches)
        let waitingOnYou = state?.waitingOnYou?.first(where: matches)
        let slot = state?.slotWaiting?.first(where: matches)
        let blocked = state?.blocked?.first(where: matches)
        let shipped = state?.shippedToday?.first(where: matches)
        let forced = state?.forced?.first(where: matches)
        let history = (state?.runHistory ?? []).filter(matches)
        let records = runs.filter { $0.issueIdentifier == identifier }
        let entries: [Entry?] = [running, retry, watching, waitingOnYou, slot, blocked, shipped, forced] + history.map { $0 }

        self.identifier = identifier
        title = entries.lazy.compactMap { $0?.title }.first
        repoKey = issue?.repoKey ?? entries.lazy.compactMap { $0?.repoKey }.first
        url = entries.lazy.compactMap { $0?.url.flatMap(URL.init(string:)) }.first
        initiative = state?.epicLanes?.lanes?.first { $0.subIssue?.identifier == identifier }.map { lane in
            [lane.identifier, lane.title].compactMap { $0 }.joined(separator: " ")
        }
        sessionID = running?.sessionId ?? history.last?.sessionId ?? records.last?.sessionId
        workspacePath = issue?.workspace?.path ?? running?.workspacePath ?? retry?.workspacePath
        lastMessage = running?.lastMessage?.nonEmpty ?? retry?.error?.nonEmpty ?? issue?.lastError?.nonEmpty
        isRunning = running != nil
        isTracked = running != nil || retry != nil || watching != nil || issue != nil

        let pullRequest = [running?.pullRequestUrl, watching?.pullRequestUrl, issue?.watching?.pullRequestUrl,
                           issue?.acceptanceGate?.prUrl]
            .compactMap { $0.flatMap(URL.init(string:)) }.first
            ?? records.reversed().lazy.compactMap { $0.pullRequestUrl.flatMap(URL.init(string:)) }.first
        let gate = issue?.acceptanceGate.flatMap(Self.gateWord)
        let qaRunning = (state?.qa?.running ?? []).contains { $0.identifier == identifier || $0.issueId == watching?.issueId }
        let qaQueued = (state?.qa?.queued ?? []).contains { $0.identifier == identifier || $0.issueId == watching?.issueId }
        let ticketState = running?.state ?? watching?.state ?? retry?.state ?? slot?.state ?? blocked?.state
            ?? waitingOnYou?.state ?? (shipped == nil ? history.last?.state : "Done")
        let idle = running.flatMap { run in
            (run.lastEventAt ?? run.startedAt).flatMap(Self.date).map { Int(reference.timeIntervalSince($0)) }
        }
        let stuck = idle.map(Overview.isStuck(idleSeconds:)) ?? false

        // What it is doing now, the first answer that applies.
        if running != nil {
            phase = .working(stuck: stuck)
        } else if let shipped {
            phase = .done(pullRequest: pullRequest, mergedAt: shipped.completedAt.flatMap(Self.date))
        } else if waitingOnYou != nil || Self.isState(watching?.state, "Human Review") {
            phase = .waiting(on: "you")
        } else if Self.isState(watching?.state, "Merging") {
            phase = .waiting(on: "CI")
        } else if let watching, Self.isState(watching.state, "In Review") || Self.isState(watching.state, "Auto Review") {
            phase = .inReview(gate: gate.map { "Gate: \($0)" }, qa: qaRunning ? "QA pass running" : qaQueued ? "QA pass queued" : nil)
        } else if let retry {
            let due = retry.dueAt.flatMap(Self.date)
            phase = .waiting(on: due.map { "a retry at \(StatusMenu.clockTime($0, now: reference, timeZone: timeZone, dateFormat: "MMM d, HH:mm"))" } ?? "a retry")
        } else if let blocked {
            let blockers = (blocked.blockedBy ?? []).compactMap(\.issueIdentifier)
            phase = .waiting(on: blockers.isEmpty ? (blocked.reason.map { "a blocker (\($0))" } ?? "a blocker") : "a blocker: \(blockers.joined(separator: ", "))")
        } else if let slot {
            phase = .waiting(on: slot.reason.map { "a slot (\($0))" } ?? "a slot")
        } else if watching != nil {
            phase = .waiting(on: watching?.state ?? "Linear")
        } else {
            phase = .unknown
        }

        var badges: [Badge] = []
        switch phase {
        case let .working(stuck): badges.append(stuck ? Badge(status: .problem, word: "Needs attention") : Badge(status: .working, word: "Working"))
        case .waiting(on: "you"): badges.append(Badge(status: .you, word: "Waiting on you"))
        case .waiting: badges.append(Badge(status: .idle, word: "Waiting"))
        case .inReview: badges.append(Badge(status: .working, word: "In review"))
        case .done: badges.append(Badge(status: .done, word: "Done"))
        case .unknown: break
        }
        if let retry, retry.attempt ?? 0 >= Overview.failedAttemptsLimit {
            badges.append(Badge(status: .problem, word: "Failed \(retry.attempt ?? 0) times"))
        }
        if forced != nil || running?.forced == true || retry?.forced == true {
            badges.append(Badge(status: .forced, word: "Forced"))
        }
        self.badges = badges

        // The timeline: every run, then the events around them, oldest first.
        var steps: [Step] = []
        func clock(_ date: Date) -> String {
            StatusMenu.clockTime(date, now: reference, timeZone: timeZone, dateFormat: "MMM d, HH:mm")
        }
        var counts: [String: Int] = [:]
        var seenRuns = Set<String>()
        var pastRuns: [(run: RunItem, started: Date)] = []
        // The run under way is Now's, not a past run's, whether or not the history lists it yet.
        func isCurrent(_ sessionID: String?) -> Bool { sessionID != nil && sessionID == running?.sessionId }
        for entry in history where entry.status?.lowercased() != "running" && !isCurrent(entry.sessionId) {
            guard let started = entry.startedAt.flatMap(Self.date) else { continue }
            if let id = entry.runId { seenRuns.insert(id) }
            pastRuns.append((RunItem(history: entry), started))
        }
        for record in records where !(record.runId.map(seenRuns.contains) ?? false) {
            guard let started = record.startedAt.flatMap(Self.date), !isCurrent(record.sessionId) else { continue }
            pastRuns.append((RunItem(record: record), started))
        }
        for (run, started) in pastRuns.sorted(by: { $0.started < $1.started }) {
            let name = run.name
            counts[name, default: 0] += 1
            let (result, word) = Self.result(run.status, error: run.error)
            steps.append(Step(
                id: "run-\(run.id ?? "\(started.timeIntervalSince1970)")",
                time: started, timeText: clock(started), title: "\(name) run \(counts[name] ?? 1)",
                result: result, resultWord: word,
                durationSeconds: run.durationSeconds ?? run.ended.map { max(Int($0.timeIntervalSince(started)), 0) },
                tokens: run.tokens, detail: run.error?.nonEmpty
            ))
        }

        if let running {
            let name = running.runKind.map(Overview.phaseName) ?? "Agent"
            let number = (counts[name] ?? 0) + 1
            let started = running.startedAt.flatMap(Self.date)
            let elapsed = started.map { max(Int(reference.timeIntervalSince($0)), 0) }
            let total = running.tokens?.totalTokens ?? 0
            let cap = state?.budget?.perIssueLimit
            let fraction = cap.flatMap { $0 > 0 ? min(Double(total) / Double($0), 1) : nil }
            let pending = issue?.running?.pendingTool ?? running.pendingTool
            let model = [running.runProfile?.model, running.runProfile?.effort].compactMap { $0?.nonEmpty }
            self.now = Now(
                run: "\(name) run \(number)",
                model: model.isEmpty ? nil : model.joined(separator: " · "),
                runningTime: elapsed.map(Overview.duration),
                turn: running.turnCount.flatMap { $0 > 0 ? $0 : nil },
                lastActivity: idle.map { "\(Overview.duration($0)) ago" },
                pendingTool: pending.flatMap { tool in
                    tool.name.map { name in "waiting on \(name)" + (tool.ageMs.map { " for \(Overview.duration($0 / 1_000))" } ?? "") }
                },
                workspace: workspacePath,
                tokens: Overview.Meter(
                    id: "ticket-tokens", label: "Tokens",
                    value: cap.map { "\(Overview.tokens(total)) of \(Overview.tokens($0))" } ?? Overview.tokens(total),
                    fraction: fraction, note: cap == nil ? "No per-ticket cap" : "Per-ticket cap"
                )
            )
            if let started {
                steps.append(Step(
                    id: "run-current", time: started, timeText: clock(started), title: "\(name) run \(number)",
                    result: .current, resultWord: stuck ? "no activity for \(idle.map(Overview.duration) ?? "a while")" : "running",
                    durationSeconds: elapsed, tokens: total, detail: nil
                ))
            }
        } else {
            self.now = nil
        }

        if let verdict = issue?.acceptanceGate, let judged = verdict.judgedAt.flatMap(Self.date), let word = Self.gateWord(verdict) {
            steps.append(Step(
                id: "gate-\(judged.timeIntervalSince1970)", time: judged, timeText: clock(judged), title: "Gate: \(word)",
                result: verdict.verdict == "rework" ? .failed : .done, resultWord: nil, durationSeconds: nil, tokens: nil,
                detail: (verdict.reasons ?? []).first
            ))
        }

        steps += Self.eventSteps(audit: audit, stops: sources.stops.filter { $0.identifier == identifier }, clock: clock)

        if let shipped, let merged = shipped.completedAt.flatMap(Self.date) {
            steps.append(Step(
                id: "done", time: merged, timeText: clock(merged), title: pullRequest == nil ? "Done" : "Merged",
                result: .done, resultWord: nil, durationSeconds: nil, tokens: nil, detail: pullRequest?.absoluteString
            ))
        }
        // The current run stays last, the step that is live.
        timeline = steps.enumerated().sorted { lhs, rhs in
            let left = lhs.element, right = rhs.element
            if (left.result == .current) != (right.result == .current) { return right.result == .current }
            if left.time != right.time { return left.time < right.time }
            return lhs.offset < rhs.offset
        }.map(\.element)

        var facts: [Fact] = []
        if let ticketState { facts.append(Fact(label: "State", value: ticketState)) }
        facts.append(Fact(label: "Type", value: Self.type(title: title, inboxKind: waitingOnYou?.kind)))
        if let initiative { facts.append(Fact(label: "Initiative", value: initiative)) }
        if let pullRequest { facts.append(Fact(label: "Pull request", value: Self.pullRequestName(pullRequest), url: pullRequest)) }
        if let gate { facts.append(Fact(label: "Gate verdict", value: gate)) }
        if case let .done(_, mergedAt?) = phase {
            mergedText = clock(mergedAt)
            facts.append(Fact(label: "Merged", value: clock(mergedAt)))
        } else {
            mergedText = nil
        }
        facts.append(Fact(label: "Forced", value: badges.contains { $0.status == .forced } ? "Yes" : "No"))
        self.facts = facts
    }

    // MARK: - Parts

    /// "Stopped by you", joined with a Backlog move right after it, and the Director's other moves.
    private static func eventSteps(audit: [AuditRecord], stops: [LocalStop], clock: (Date) -> String) -> [Step] {
        var steps: [Step] = []
        var moves = audit.filter { $0.eventType == "director_move" }
        let auditStops = audit.filter { $0.eventType == "run_stopped" }.compactMap { record in record.timestamp.flatMap(date).map { (record, $0) } }

        func takeBacklogMove(after time: Date) -> AuditRecord? {
            guard let index = moves.firstIndex(where: { move in
                guard move.move == "backlog", let at = move.timestamp.flatMap(date) else { return false }
                return at >= time.addingTimeInterval(-stopMoveWindow) && at <= time.addingTimeInterval(stopMoveWindow)
            }) else { return nil }
            return moves.remove(at: index)
        }

        for (record, at) in auditStops {
            let move = takeBacklogMove(after: at)
            steps.append(stopStep(id: "stop-\(record.recordHash ?? "\(at.timeIntervalSince1970)")", at: at, movedToBacklog: move != nil, note: move?.comment, clock: clock))
        }
        // A stop made from the app shows at once; once its record arrives, the record is shown instead.
        for stop in stops where !auditStops.contains(where: { abs($0.1.timeIntervalSince(stop.at)) <= stopMoveWindow }) {
            let move = takeBacklogMove(after: stop.at)
            steps.append(stopStep(id: "stop-local-\(stop.at.timeIntervalSince1970)", at: stop.at, movedToBacklog: stop.movedToBacklog || move != nil, note: stop.note ?? move?.comment, clock: clock))
        }
        for move in moves {
            guard let at = move.timestamp.flatMap(date) else { continue }
            steps.append(Step(
                id: "move-\(move.recordHash ?? "\(at.timeIntervalSince1970)")", time: at, timeText: clock(at),
                title: moveTitle(move), result: .done, resultWord: nil, durationSeconds: nil, tokens: nil,
                detail: move.comment?.nonEmpty
            ))
        }
        return steps
    }

    private static func stopStep(id: String, at: Date, movedToBacklog moved: Bool, note: String?, clock: (Date) -> String) -> Step {
        Step(
            id: id, time: at, timeText: clock(at), title: stoppedByYou + (moved ? ", \(movedToBacklog)" : ""),
            result: .stopped, resultWord: nil, durationSeconds: nil, tokens: nil, detail: note?.nonEmpty
        )
    }

    /// The Director's move as a timeline step: "Moved to Backlog by you".
    static func moveTitle(_ move: AuditRecord) -> String {
        switch move.move {
        case "approve_plan": return "Plan approved by you"
        case "approve_pr": return "Moved to Merging by you"
        case "rework": return "Sent to Rework by you"
        case "decisions": return "Decisions sent by you"
        case "sign_off": return "Signed off by you"
        case "backlog": return "Moved to Backlog by you"
        case "undo": return "Move undone by you"
        default: return "Moved to \(move.toState ?? "another state") by you"
        }
    }

    /// A run's status as a step result and its word.
    static func result(_ status: String?, error: String?) -> (Step.Result, String?) {
        switch status?.lowercased() {
        case nil:
            return error?.nonEmpty == nil ? (.done, "done") : (.failed, "failed")
        case "success", "succeeded", "completed", "done", "ok":
            return (.done, "done")
        case "stopped", "canceled", "cancelled":
            return (.stopped, "stopped")
        case let other?:
            return (.failed, other == "failure" || other == "error" ? "failed" : other.replacingOccurrences(of: "_", with: " "))
        }
    }

    /// "approve", "rework", "escalate", with "(shadow)" when the gate only watches.
    private static func gateWord(_ gate: IssuePayload.Gate) -> String? {
        guard let verdict = gate.verdict?.nonEmpty else { return nil }
        let word = verdict.replacingOccurrences(of: "_", with: " ")
        return gate.mode == "shadow" ? "\(word) (shadow)" : word
    }

    private static func type(title: String?, inboxKind: String?) -> String {
        if inboxKind == "plan" { return "Plan" }
        if title?.hasPrefix("Final verification:") == true || inboxKind == "final_verification" { return "Final verification" }
        return "Ticket"
    }

    /// "acme/web-shop#412" for a GitHub pull request URL, else the URL.
    public static func pullRequestName(_ url: URL) -> String {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[2] == "pull" else { return url.absoluteString }
        return "\(parts[0])/\(parts[1])#\(parts[3])"
    }

    private static func isState(_ state: String?, _ name: String) -> Bool {
        state?.trimmingWhitespace().caseInsensitiveCompare(name) == .orderedSame
    }

    /// ISO-8601 with or without fractional seconds, as Elixir writes both.
    static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// The records in an NDJSON body; lines that don't read are skipped.
    static func auditRecords(_ data: Data) -> [AuditRecord] {
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
            try? decoder.decode(AuditRecord.self, from: Data(line.utf8))
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    // MARK: - Payloads

    struct AuditRecord: Decodable, Equatable {
        let eventType: String?
        let timestamp: String?
        let issueIdentifier: String?
        let move: String?
        let toState: String?
        let comment: String?
        let recordHash: String?
    }

    /// The fields any state list's entry may carry; each list fills some.
    private struct Entry: Decodable {
        struct Tokens: Decodable {
            let totalTokens: Int?
        }

        struct Profile: Decodable {
            let model: String?
            let effort: String?
        }

        struct PendingTool: Decodable {
            let name: String?
            let ageMs: Int?
        }

        struct Blocker: Decodable {
            let issueIdentifier: String?
        }

        let issueId: String?
        let issueIdentifier: String?
        let title: String?
        let repoKey: String?
        let state: String?
        let url: String?
        let pullRequestUrl: String?
        let runKind: String?
        let runProfile: Profile?
        let sessionId: String?
        let workspacePath: String?
        let turnCount: Int?
        let lastMessage: String?
        let startedAt: String?
        let lastEventAt: String?
        let pendingTool: PendingTool?
        let forced: Bool?
        let tokens: Tokens?
        let attempt: Int?
        let dueAt: String?
        let error: String?
        let reason: String?
        let blockedBy: [Blocker]?
        let kind: String?
        let completedAt: String?
        // A run_history entry.
        let runId: String?
        let status: String?
        let endedAt: String?
        let runtimeSeconds: Int?
    }

    private struct StatePayload: Decodable {
        struct Budget: Decodable {
            let perIssueLimit: Int?
        }

        struct Pass: Decodable {
            let identifier: String?
            let issueId: String?
        }

        struct Passes: Decodable {
            let running: [Pass]?
            let queued: [Pass]?
        }

        struct Lanes: Decodable {
            struct Lane: Decodable {
                struct SubIssue: Decodable {
                    let identifier: String?
                }

                let identifier: String?
                let title: String?
                let subIssue: SubIssue?
            }

            let lanes: [Lane]?
        }

        let generatedAt: String?
        let running: [Entry]?
        let retrying: [Entry]?
        let watching: [Entry]?
        let waitingOnYou: [Entry]?
        let slotWaiting: [Entry]?
        let blocked: [Entry]?
        let shippedToday: [Entry]?
        let forced: [Entry]?
        let runHistory: [Entry]?
        let budget: Budget?
        let qa: Passes?
        let epicLanes: Lanes?
    }

    private struct IssuePayload: Decodable {
        struct Workspace: Decodable {
            let path: String?
        }

        struct Running: Decodable {
            let pendingTool: Entry.PendingTool?
        }

        struct Watching: Decodable {
            let pullRequestUrl: String?
        }

        struct Gate: Decodable {
            let verdict: String?
            let mode: String?
            let judgedAt: String?
            let reasons: [String]?
            let prUrl: String?
        }

        let repoKey: String?
        let status: String?
        let workspace: Workspace?
        let running: Running?
        let watching: Watching?
        let lastError: String?
        let acceptanceGate: Gate?
    }

    private struct RunsPayload: Decodable {
        struct Run: Decodable {
            struct Tokens: Decodable {
                let totalTokens: Int?
            }

            let runId: String?
            let issueIdentifier: String?
            let status: String?
            let error: String?
            let tokens: Tokens?
            let durationSeconds: Int?
            let sessionId: String?
            let pullRequestUrl: String?
            let startedAt: String?
            let endedAt: String?
        }

        let runs: [Run]?
    }

    /// A finished run, from the state's run history or the run records.
    private struct RunItem {
        var id: String?
        var name: String
        var status: String?
        var error: String?
        var durationSeconds: Int?
        var ended: Date?
        var tokens: Int?

        init(history entry: Entry) {
            id = entry.runId
            name = entry.kind == "qa" ? "QA pass" : entry.runKind.map(Overview.phaseName) ?? "Agent"
            status = entry.status
            error = entry.error
            durationSeconds = entry.runtimeSeconds.flatMap { $0 > 0 ? $0 : nil }
            ended = entry.endedAt.flatMap(TicketPage.date)
            tokens = entry.tokens?.totalTokens
        }

        init(record: RunsPayload.Run) {
            id = record.runId
            name = "Agent"
            status = record.status
            error = record.error
            durationSeconds = record.durationSeconds.flatMap { $0 > 0 ? $0 : nil }
            ended = record.endedAt.flatMap(TicketPage.date)
            tokens = record.tokens?.totalTokens
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingWhitespace()
        return trimmed.isEmpty ? nil : trimmed
    }
}
