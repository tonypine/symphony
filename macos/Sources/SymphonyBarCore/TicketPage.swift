import Foundation

/// D3: everything about one ticket on one page (principle 5): its header, what runs now, the timeline of every run
/// and event (C14), its facts and the agent's last message. Built from `/api/v1/state`, `/api/v1/:issue_identifier`
/// (404 once Symphony no longer tracks the ticket), `/api/v1/runs` and the ticket's audit records, any of which may be
/// missing: the page shows what the others say.
public struct TicketPage: Equatable {
    /// What the ticket is doing now, the line under the header.
    public enum Phase: Equatable {
        /// An agent runs on it.
        case working
        /// Symphony paused it, for the reasons in `TicketPage.paused`.
        case paused
        /// It waits on something: "you", "CI", "a blocker", "a slot", "a retry at 14:32".
        case waiting(on: String)
        /// In review: Code Review or QA, with the QA pass when it is running or queued.
        case inReview(qa: String?)
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

    /// Why the ticket is paused, as Symphony's `pause` block says: one row per reason, in the order they were set.
    public struct Paused: Equatable {
        public struct Reason: Equatable, Identifiable {
            public var id: Int
            /// `question`, `ticket`, `build`, `person` or `environment`.
            public var kind: String?
            /// "Waiting for your answer", Symphony's own words.
            public var text: String
            /// "14:02", or "Oct 6, 14:02" before today: when it was set.
            public var since: String?
            /// Whether the Director may release it, so its row offers Release.
            public var releasable: Bool

            /// The row's Release for VoiceOver: "Release: waiting for TP-1194 to finish".
            public var releaseAccessibilityLabel: String { "\(TicketPage.releaseTitle): \(Paused.lowercasedLead(text))" }
        }

        /// "14:02": when the ticket was paused.
        public var since: String?
        public var reasons: [Reason]

        /// The line under the title: "Paused: waiting for your answer", or "Paused for 2 reasons" over their rows.
        public var sentence: String {
            guard reasons.count == 1, let reason = reasons.first else { return "Paused for \(reasons.count) reasons" }
            return "Paused: \(Self.lowercasedLead(reason.text))"
        }

        /// "since 14:02", nil when Symphony didn't say.
        public var sinceText: String? { since.map { "since \($0)" } }

        /// "Waiting for TP-1194" reads "waiting for TP-1194" after a colon; a word in capitals ("TP-1194 …") stays.
        static func lowercasedLead(_ text: String) -> String {
            let characters = Array(text)
            guard characters.count > 1, characters[0].isUppercase, characters[1].isLowercase else { return text }
            return characters[0].lowercased() + String(characters.dropFirst())
        }
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
        /// "Implementation run 1", "QA run 1", "Stopped by you".
        public var title: String
        public var result: Result
        /// "failed", "done", "running"; nil when the title says it.
        public var resultWord: String?
        public var durationSeconds: Int?
        public var tokens: Int?
        /// The run's error, the note posted with a move.
        public var detail: String?
        /// A run's group: the run's id, its events in `children`.
        public var runID: String? = nil
        /// What happened inside it: a run's events, the replies to an event.
        public var children: [Step] = []
        /// The screenshots the event carries.
        public var screenshots: [TicketScreenshot] = []

        public var isGroup: Bool { runID != nil }

        public var duration: String? { durationSeconds.map(Overview.duration) }
        public var tokensText: String? { tokens.flatMap { $0 > 0 ? Overview.tokens($0) : nil } }

        /// One element for VoiceOver: "13:03, implementation run 1, failed, 22 minutes".
        public var accessibilityLabel: String {
            let title = title.prefix(1).lowercased() + title.dropFirst()
            return [timeText, title, resultWord, durationSeconds.map(Overview.spokenDuration)]
                .compactMap { $0 }
                .joined(separator: ", ")
        }

        /// A run group's fold button: "Collapse QA run 2, failed", "Expand QA run 2, running".
        public func foldAccessibilityLabel(folded: Bool) -> String {
            ([(folded ? "Expand " : "Collapse ") + title] + [resultWord].compactMap { $0 }).joined(separator: ", ")
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
        /// Check Now's answer, with the watch block the watcher decided on just then.
        public var check: Data?
        /// Whether the Inbox holds a decision on the ticket, so the PR and CI card offers Open in Inbox.
        public var inboxDecision: Bool
        /// The ticket's events feed, merged from every page read; nil while Symphony doesn't serve it.
        public var events: TicketEventsPayload?
        /// Why `events` is nil (`TicketEventsReader.absence`): not read yet or a failed read, a ticket Symphony keeps
        /// no record of yet, or a Symphony that predates the feed.
        public var feedAbsence: TicketFeedAbsence

        public init(
            state: Data? = nil, issue: Data? = nil, runs: Data? = nil, audit: [Data] = [], stops: [LocalStop] = [],
            check: Data? = nil, inboxDecision: Bool = false, events: TicketEventsPayload? = nil, feedAbsence: TicketFeedAbsence = .unread
        ) {
            self.state = state
            self.issue = issue
            self.runs = runs
            self.audit = audit
            self.stops = stops
            self.check = check
            self.inboxDecision = inboxDecision
            self.events = events
            self.feedAbsence = feedAbsence
        }
    }

    public static let stoppedByYou = "Stopped by you"
    /// The running indicator's word for VoiceOver.
    public static let runningTitle = "Running"
    /// A note the Director wrote on the ticket.
    public static let noteByYou = "Note by you"
    public static let movedToBacklog = "moved to Backlog"
    public static let viewTranscriptTitle = "View Transcript"
    public static let openInLinearTitle = "Open in Linear"
    public static let copyAPIURLTitle = "Copy API URL"
    public static let showAuditRecordsTitle = "Show Audit Records"
    public static let revealWorktreeTitle = "Reveal Worktree"
    /// A releasable pause reason's button: it sends the unblock move.
    public static let releaseTitle = "Release"
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
    /// Why it is paused, nil while it moves or before Symphony said (a Symphony without the `pause` block).
    public var paused: Paused?
    /// The ticket's questions still waiting for an answer, by title; empty from a Symphony without the block.
    public var openQuestions: [String]
    public var now: Now?
    /// Oldest first; the current step last.
    public var timeline: [Step]
    public var facts: [Fact]
    /// S15: the PR and CI card, nil while the watcher doesn't watch the ticket.
    public var watch: PRWatchCard?
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
    /// Whether the note field takes a note: Symphony serves the ticket's events feed, which a note is written to, and
    /// the ticket's repo is known. An older Symphony doesn't.
    public var acceptsNotes: Bool
    /// Why the note field is off, nil while it takes notes: an older Symphony, whose 404 isn't the feed's own; a ticket
    /// the feed has no record of, before its first run; or the ticket's history not read yet (before the first read,
    /// after a failed one, or while its repo isn't known).
    public var notesOffReason: String? {
        if acceptsNotes { return nil }
        switch feedAbsence {
        case .unsupported: return TicketNoteComposer.unsupportedReason
        case .unknownTicket: return TicketNoteComposer.unknownTicketReason
        case .unread: return TicketNoteComposer.readingReason
        }
    }

    /// Why the page has no history from the events feed, as the feed's reader last said.
    public var feedAbsence: TicketFeedAbsence
    /// Whether the Director paused the ticket's repository, as the ticket's payload says; false from a Symphony that
    /// predates the pause of one repository.
    public var repositoryPaused: Bool

    /// The page's one line while the ticket's repository is paused, nil otherwise.
    public var repositoryPausedNote: String? {
        guard repositoryPaused else { return nil }
        return repoKey.map { "The repository \($0) is paused: Symphony doesn't dispatch its tickets." }
            ?? "The repository is paused: Symphony doesn't dispatch its tickets."
    }
    /// Whether the ticket is forced past the dispatch limits, so its ⋯ menu offers Stop Forcing instead of Force.
    public var isForced: Bool { badges.contains { $0.status == .forced } }

    /// The line under the header: "Working", "Waiting on a retry at 14:32", "Done, merged 13:40".
    public var phaseSentence: String {
        switch phase {
        case .working: return "Working"
        case .paused: return paused?.sentence ?? "Paused"
        case let .waiting(on): return "Waiting on \(on)"
        case let .inReview(qa):
            return (["In review"] + [qa].compactMap { $0 }).joined(separator: " · ")
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

    /// The ticket's events feed grouped by run, after `since` (exclusive) when given.
    public static func eventsPath(_ identifier: String, repoKey: String, since: String? = nil, limit: Int? = nil) -> String {
        func encoded(_ text: String, _ allowed: CharacterSet, except reserved: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: allowed.subtracting(CharacterSet(charactersIn: reserved))) ?? text
        }
        func segment(_ text: String) -> String { encoded(text, .urlPathAllowed, except: "/?#") }
        var query = ["group=run"]
        if let limit { query.append("limit=\(limit)") }
        if let since { query.append("since=" + encoded(since, .urlQueryAllowed, except: "+&=#")) }
        return "api/v1/repos/\(segment(repoKey))/tickets/\(segment(identifier))/events?" + query.joined(separator: "&")
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
        let skipped = state?.dispatchSkipped?.first(where: matches)
        let blocked = state?.blocked?.first(where: matches)
        let shipped = state?.shippedToday?.first(where: matches)
        let forced = state?.forced?.first(where: matches)
        // The watcher's newest word on the ticket's pull request: Check Now's, the ticket's own, or the state's.
        let watchState = sources.state.map(WatchState.decode)
        let watchCard = PRWatchCard(
            watch: WatchBlock.newest([
                sources.check.flatMap { WatchBlock.decode(carriedIn: $0) },
                sources.issue.flatMap { WatchBlock.decode(carriedIn: $0) },
                watchState?.watches[identifier],
            ]),
            inboxDecision: sources.inboxDecision,
            rateLimit: watchState?.rateLimit,
            reference: reference,
            timeZone: timeZone
        )
        let history = (state?.runHistory ?? []).filter(matches)
        let records = runs.filter { $0.issueIdentifier == identifier }
        let entries: [Entry?] = [running, retry, watching, waitingOnYou, slot, skipped, blocked, shipped, forced] + history.map { $0 }

        self.identifier = identifier
        watch = watchCard
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
        // A ticket only waiting to be dispatched has no run, so no transcript yet.
        isTracked = running != nil || retry != nil || watching != nil
            || issue.map { !["slot_waiting", "dispatch_skipped"].contains($0.status ?? "") } ?? false
        acceptsNotes = sources.events != nil && repoKey?.isEmpty == false
        feedAbsence = sources.feedAbsence
        repositoryPaused = issue?.repositoryPaused ?? false
        // Symphony's one answer to why it doesn't move: the ticket's own payload, else its entry in the state. A
        // Symphony that predates it sends no `open_questions`, and the page derives the phase from the lists.
        let status = sources.issue.flatMap { try? Self.decoder.decode(TicketStatus.Carrier.self, from: $0) }?.status
            ?? sources.state.flatMap { try? Self.decoder.decode(TicketStatus.Lists.self, from: $0) }?.status(of: identifier)
        paused = status?.pause.flatMap { Self.paused($0, clock: { StatusMenu.clockTime($0, now: reference, timeZone: timeZone, dateFormat: "MMM d, HH:mm") }) }
        openQuestions = status?.openQuestions.compactMap { $0.title?.nonEmpty } ?? []

        let pullRequest = [running?.pullRequestUrl, watching?.pullRequestUrl, issue?.watching?.pullRequestUrl]
            .compactMap { $0.flatMap(URL.init(string:)) }.first
            ?? records.reversed().lazy.compactMap { $0.pullRequestUrl.flatMap(URL.init(string:)) }.first
        let qaRunning = (state?.qa?.running ?? []).contains { $0.identifier == identifier || $0.issueId == watching?.issueId }
        let qaQueued = (state?.qa?.queued ?? []).contains { $0.identifier == identifier || $0.issueId == watching?.issueId }
        // Split in two: a single `??` chain over all of these exceeds the type-checker's budget
        // on Xcode 26.3.
        let liveState: String? = [running?.state, watching?.state, retry?.state, slot?.state, skipped?.state,
                                  blocked?.state, waitingOnYou?.state].lazy.compactMap { $0 }.first
        let ticketState: String? = liveState ?? (shipped == nil ? history.last?.state : "Done")
        let idle = running.flatMap { run in
            (run.lastEventAt ?? run.startedAt).flatMap(Self.date).map { Int(reference.timeIntervalSince($0)) }
        }

        // What it is doing now, the first answer that applies. With Symphony's answer a ticket is running, paused or
        // moving; the Inbox and blocked lists are its pauses then.
        if running != nil {
            phase = .working
        } else if let shipped {
            phase = .done(pullRequest: pullRequest, mergedAt: shipped.completedAt.flatMap(Self.date))
        } else if paused != nil {
            phase = .paused
        } else if status == nil, waitingOnYou != nil {
            phase = .waiting(on: "you")
        } else if Self.isState(watching?.state, "Merging") {
            phase = .waiting(on: watchCard?.waitingOn ?? "CI")
        } else if let watching, ["Code Review", "QA"].contains(where: { Self.isState(watching.state, $0) }) {
            phase = .inReview(qa: qaRunning ? "QA pass running" : qaQueued ? "QA pass queued" : nil)
        } else if let retry {
            let due = retry.dueAt.flatMap(Self.date)
            phase = .waiting(on: due.map { "a retry at \(StatusMenu.clockTime($0, now: reference, timeZone: timeZone, dateFormat: "MMM d, HH:mm"))" } ?? "a retry")
        } else if status == nil, let blocked {
            let blockers = (blocked.blockedBy ?? []).compactMap(\.issueIdentifier)
            phase = .waiting(on: blockers.isEmpty ? (blocked.reason.map { "a blocker (\($0))" } ?? "a blocker") : "a blocker: \(blockers.joined(separator: ", "))")
        } else if let slot {
            phase = .waiting(on: slot.reason.map { "a slot (\($0))" } ?? "a slot")
        } else if let skipped {
            phase = .waiting(on: skipped.reason ?? "a dispatch gate")
        } else if watching != nil {
            phase = .waiting(on: watching?.state ?? "Linear")
        } else {
            phase = .unknown
        }

        var badges: [Badge] = []
        switch phase {
        case .working: badges.append(Badge(status: .working, word: "Working"))
        case .paused:
            let you = paused?.reasons.contains { $0.kind == "question" || $0.kind == "person" } ?? false
            badges.append(you ? Badge(status: .you, word: "Waiting on you") : Badge(status: .idle, word: "Paused"))
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
                tokens: run.tokens, detail: run.inconclusiveCause.map(Self.inconclusiveDetail) ?? run.error?.nonEmpty
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
                    result: .current, resultWord: "running",
                    durationSeconds: elapsed, tokens: total, detail: nil
                ))
            }
        } else {
            self.now = nil
        }

        steps += Self.eventSteps(audit: audit, stops: sources.stops.filter { $0.identifier == identifier }, clock: clock)
        steps += (issue?.verdicts ?? []).compactMap { Self.verdictStep($0, clock: clock) }

        if let shipped, let merged = shipped.completedAt.flatMap(Self.date) {
            steps.append(Step(
                id: "done", time: merged, timeText: clock(merged), title: pullRequest == nil ? "Done" : "Merged",
                result: .done, resultWord: nil, durationSeconds: nil, tokens: nil, detail: pullRequest?.absoluteString
            ))
        }
        if let feed = sources.events, !feed.isEmpty {
            // The feed tells every run and event itself; a stop made from the app shows until the feed has caught up.
            let newest = feed.newestEventAt ?? .distantPast
            let stops = sources.stops.filter { $0.identifier == identifier && $0.at > newest }
            timeline = feed.steps(reference: reference, clock: clock) + Self.eventSteps(audit: [], stops: stops, clock: clock)
        } else {
            // The current run stays last, the step that is live.
            timeline = steps.enumerated().sorted { lhs, rhs in
                let left = lhs.element, right = rhs.element
                if (left.result == .current) != (right.result == .current) { return right.result == .current }
                if left.time != right.time { return left.time < right.time }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }

        var facts: [Fact] = []
        if let ticketState { facts.append(Fact(label: "State", value: ticketState)) }
        facts.append(Fact(label: "Type", value: Self.type(title: title, inboxKind: waitingOnYou?.kind)))
        if let initiative { facts.append(Fact(label: "Initiative", value: initiative)) }
        if let pullRequest { facts.append(Fact(label: "Pull request", value: Self.pullRequestName(pullRequest), url: pullRequest)) }
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

    /// The pause block as the page shows it; nil when it has no reason to show.
    private static func paused(_ pause: TicketStatus.Pause, clock: (Date) -> String) -> Paused? {
        let reasons = (pause.reasons ?? []).enumerated().compactMap { index, reason -> Paused.Reason? in
            guard let text = reason.text?.nonEmpty else { return nil }
            return Paused.Reason(
                id: index, kind: reason.kind, text: text,
                since: reason.setAt.flatMap(date).map(clock), releasable: reason.releasable ?? false
            )
        }
        guard !reasons.isEmpty else { return nil }
        return Paused(since: pause.since.flatMap(date).map(clock), reasons: reasons)
    }

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

    /// A Code Review or QA verdict as a timeline step: "Approved by Code Review", "QA failed".
    private static func verdictStep(_ verdict: IssuePayload.Verdict, clock: (Date) -> String) -> Step? {
        guard let at = verdict.recordedAt.flatMap(date), let (title, result) = verdictTitle(verdict) else { return nil }
        return Step(
            id: "verdict-\(verdict.kind ?? "")-\(at.timeIntervalSince1970)", time: at, timeText: clock(at),
            title: title, result: result, resultWord: nil, durationSeconds: nil, tokens: nil,
            detail: verdict.headSha.map { "on \($0.prefix(7))" }
        )
    }

    private static func verdictTitle(_ verdict: IssuePayload.Verdict) -> (String, Step.Result)? {
        let outcome = verdict.outcome ?? ""
        switch (verdict.kind, outcome) {
        case ("code_review", "approve"): return ("Approved by Code Review", .done)
        case ("code_review", "rework"): return ("Sent to Rework by Code Review", .failed)
        case ("code_review", "block"): return ("Blocked by Code Review", .failed)
        case ("code_review", _): return ("Code Review \(outcome.replacingOccurrences(of: "_", with: " "))", .done)
        case ("qa", "pass"): return ("QA passed", .done)
        case ("qa", "fail"): return ("QA failed", .failed)
        case ("qa", "skip"): return ("QA skipped", .done)
        case ("qa", _): return ("QA \(outcome.replacingOccurrences(of: "_", with: " "))", .done)
        default: return nil
        }
    }

    /// The Director's move as a timeline step: "Moved to Backlog by you".
    static func moveTitle(_ move: AuditRecord) -> String {
        switch move.move {
        case "approve_plan": return "Plan approved by you"
        // A move Symphony retired; older audit records still name it.
        case "approve_pr": return "Moved to Merging by you"
        case "rework": return "Sent to Rework by you"
        case "decisions": return "Decisions sent by you"
        case "backlog": return "Moved to Backlog by you"
        case "undo": return "Move undone by you"
        default: return "Moved to \(move.toState ?? "another state") by you"
        }
    }

    /// A run's status as a step result and its word.
    /// A Code Review run that stayed inconclusive, with its cause in words: "Review inconclusive: invalid verdict".
    static func inconclusiveDetail(_ cause: String) -> String {
        "Review inconclusive: \(cause.replacingOccurrences(of: "_", with: " "))"
    }

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

    private static func type(title: String?, inboxKind: String?) -> String {
        if inboxKind == "plan" { return "Plan" }
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

    /// Why the ticket does not move (TP-1242): its pause, nil while it moves, and its open questions. The ticket
    /// payload and each of its state entries carry it; a Symphony that predates it sends neither field.
    struct TicketStatus: Decodable {
        struct Pause: Decodable {
            struct Reason: Decodable {
                let kind: String?
                let text: String?
                let setAt: String?
                let releasable: Bool?
            }

            let since: String?
            let reasons: [Reason]?
        }

        struct Question: Decodable {
            let id: String?
            let title: String?
        }

        let pause: Pause?
        let openQuestions: [Question]

        private enum CodingKeys: String, CodingKey { case pause, openQuestions }

        /// Nil when the payload has no `open_questions`, the field every Symphony with the block sends.
        static func decode(_ decoder: Decoder) -> TicketStatus? {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self),
                  let questions = try? container.decode([Question].self, forKey: .openQuestions) else { return nil }
            return TicketStatus(pause: try? container.decodeIfPresent(Pause.self, forKey: .pause), openQuestions: questions)
        }

        init(pause: Pause?, openQuestions: [Question]) {
            self.pause = pause
            self.openQuestions = openQuestions
        }

        /// A payload that may carry the block: the ticket's, or one entry of a state list.
        struct Carrier: Decodable {
            private enum CodingKeys: String, CodingKey { case issueIdentifier }

            let issueIdentifier: String?
            let status: TicketStatus?

            init(from decoder: Decoder) throws {
                issueIdentifier = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .issueIdentifier)
                status = TicketStatus.decode(decoder)
            }
        }

        /// The state lists whose entries carry the block.
        struct Lists: Decodable {
            let running: [Carrier]?
            let retrying: [Carrier]?
            let watching: [Carrier]?
            let slotWaiting: [Carrier]?
            let dispatchSkipped: [Carrier]?

            func status(of identifier: String) -> TicketStatus? {
                [running, retrying, watching, slotWaiting, dispatchSkipped].lazy
                    .compactMap { $0?.first { $0.issueIdentifier == identifier }?.status }.first
            }
        }
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
        /// Why a Code Review run stayed inconclusive, such as `invalid_verdict`.
        let reviewInconclusiveCause: String?
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
        let dispatchSkipped: [Entry]?
        let blocked: [Entry]?
        let shippedToday: [Entry]?
        let forced: [Entry]?
        let runHistory: [Entry]?
        let budget: Budget?
        let qa: Passes?
        let epicLanes: Lanes?
    }

    private struct IssuePayload: Decodable {
        /// A Code Review or QA verdict from the ticket's state record.
        struct Verdict: Decodable, Equatable {
            let kind: String?
            let outcome: String?
            let headSha: String?
            let recordedAt: String?
        }

        struct Workspace: Decodable {
            let path: String?
        }

        struct Running: Decodable {
            let pendingTool: Entry.PendingTool?
        }

        struct Watching: Decodable {
            let pullRequestUrl: String?
        }

        let repoKey: String?
        let status: String?
        let workspace: Workspace?
        let running: Running?
        let watching: Watching?
        let lastError: String?
        let verdicts: [Verdict]?
        /// Missing before Symphony paused one repository at a time.
        let repositoryPaused: Bool?
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
        var inconclusiveCause: String?

        init(history entry: Entry) {
            id = entry.runId
            name = entry.kind == "qa" ? "QA pass" : entry.runKind.map(Overview.phaseName) ?? "Agent"
            status = entry.status
            error = entry.error
            durationSeconds = entry.runtimeSeconds.flatMap { $0 > 0 ? $0 : nil }
            ended = entry.endedAt.flatMap(TicketPage.date)
            tokens = entry.tokens?.totalTokens
            inconclusiveCause = entry.reviewInconclusiveCause?.nonEmpty
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

// MARK: - What the Inbox says about the ticket

extension TicketPage {
    /// What the ticket page shows from the ticket's Inbox item (D3), the API's ticket having none of it: its summary,
    /// its latest review brief and the decisions answered on it, each ticket and pull request they mention a chip
    /// (N1) read from the item's `references`.
    public struct Brief: Equatable {
        /// The brief's card: "Review brief", "Your decision", "Action", "What the quality gate found" or "Why it is
        /// blocked".
        public var title: String
        /// The ticket's Symphony status line, from its own reference; nil when the item doesn't resolve itself.
        public var summary: String?
        public var paragraphs: [String]
        /// Requests on the ticket a person answered, newest first.
        public var decisions: [TicketContext.EarlierDecision]
        public var references: [String: Reference]

        /// The brief of the first of `items` about ticket `identifier`; nil when the Inbox holds none.
        public init?(identifier: String, items: [InboxItem]) {
            guard let item = items.first(where: { $0.identifier == identifier }) else { return nil }
            let review = item.review
            switch item.kind {
            case .plan, .pr:
                title = "Review brief"
                paragraphs = Self.paragraphs(of: review.brief) ?? [item.ask]
            case .action:
                title = item.isDecision ? "Your decision" : "Action"
                paragraphs = [review.action?.question].compactMap { $0 } + (review.action?.whyParagraphs ?? [])
            case .clarify:
                title = "What the quality gate found"
                paragraphs = [review.clarify?.found].compactMap { $0 } + (review.clarify?.questions ?? [])
            case .blocked:
                title = "Why it is blocked"
                paragraphs = [review.blocked?.reason].compactMap { $0 }
            }
            if paragraphs.isEmpty { paragraphs = [item.ask] }
            if case let .ticket(ticket)? = item.references[identifier] { summary = ticket.summary }
            decisions = item.context?.earlierDecisions ?? []
            references = item.references
        }

        /// A brief's What to review and What changed lines, or its paragraphs when it didn't parse; nil when it says
        /// nothing.
        static func paragraphs(of brief: InboxReview.Brief?) -> [String]? {
            let paragraphs: [String]
            switch brief {
            case let .parsed(parsed):
                paragraphs = parsed.whatToReview.map(\.text) + parsed.whatChanged
            case let .raw(markdown):
                paragraphs = markdown.components(separatedBy: "\n\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            case nil:
                paragraphs = []
            }
            return paragraphs.isEmpty ? nil : paragraphs
        }
    }
}
