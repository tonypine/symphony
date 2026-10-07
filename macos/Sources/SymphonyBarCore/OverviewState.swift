import Foundation

/// What the Overview reads from one `GET /api/v1/state` payload: the menu's `StateSnapshot` (pause, usage limits,
/// budget, forced tickets) and the lists of tickets by stage. Every field of an entry is optional, so an entry
/// missing one never fails the whole state.
public struct OverviewState: Equatable {
    /// The pause, usage limits, budget and forced tickets, read as the menu reads them.
    public var snapshot: StateSnapshot
    /// Symphony's clock when it took the state; ages are measured against it.
    public var generatedAt: Date?
    /// The repos Symphony has tickets in, for the scope pop-up.
    public var repos: [String]
    public var running: [Run]
    /// Tickets Symphony ran and now watches in Linear: In Review, Auto Review, Human Review, Merging.
    public var watching: [Ticket]
    /// Tickets in Human Review, which wait on the Director.
    public var humanReview: [Ticket]
    public var retrying: [Retry]
    public var slotWaiting: [Waiting]
    public var conflicts: [Conflict]
    /// Tickets Symphony saw reach Done today, newest first.
    public var shippedToday: [Ticket]
    /// `counts.shipped_today`; nil from a Symphony that predates it.
    public var shippedTodayCount: Int?
    /// Issue ids with a QA pass running or queued.
    public var qaRunning: [String]
    public var qaQueued: [String]
    /// Issue ids of the landing runs.
    public var landing: [String]
    public var strayProcesses: [StrayProcess]

    public struct Run: Equatable {
        public var issueID: String?
        public var identifier: String
        public var title: String?
        public var repoKey: String?
        public var state: String?
        /// For example `implementation` or `rework`; nil when Symphony didn't say.
        public var runKind: String?
        public var url: URL?
        public var turnCount: Int
        public var lastMessage: String?
        public var startedAt: Date?
        public var lastEventAt: Date?
        public var totalTokens: Int

        public init(
            issueID: String? = nil,
            identifier: String,
            title: String? = nil,
            repoKey: String? = nil,
            state: String? = nil,
            runKind: String? = nil,
            url: URL? = nil,
            turnCount: Int = 0,
            lastMessage: String? = nil,
            startedAt: Date? = nil,
            lastEventAt: Date? = nil,
            totalTokens: Int = 0
        ) {
            self.issueID = issueID
            self.identifier = identifier
            self.title = title
            self.repoKey = repoKey
            self.state = state
            self.runKind = runKind
            self.url = url
            self.turnCount = turnCount
            self.lastMessage = lastMessage
            self.startedAt = startedAt
            self.lastEventAt = lastEventAt
            self.totalTokens = totalTokens
        }
    }

    public struct Ticket: Equatable {
        public var issueID: String?
        public var identifier: String
        public var title: String?
        public var repoKey: String?
        public var state: String?
        public var url: URL?
        /// Since its last run ended, for a watched ticket.
        public var secondsSinceLastRun: Int?

        public init(
            issueID: String? = nil,
            identifier: String,
            title: String? = nil,
            repoKey: String? = nil,
            state: String? = nil,
            url: URL? = nil,
            secondsSinceLastRun: Int? = nil
        ) {
            self.issueID = issueID
            self.identifier = identifier
            self.title = title
            self.repoKey = repoKey
            self.state = state
            self.url = url
            self.secondsSinceLastRun = secondsSinceLastRun
        }
    }

    public struct Retry: Equatable {
        public var issueID: String?
        public var identifier: String
        public var title: String?
        public var repoKey: String?
        /// How many attempts failed so far.
        public var attempt: Int
        public var dueAt: Date?
        public var error: String?

        public init(issueID: String? = nil, identifier: String, title: String? = nil, repoKey: String? = nil, attempt: Int = 0, dueAt: Date? = nil, error: String? = nil) {
            self.issueID = issueID
            self.identifier = identifier
            self.title = title
            self.repoKey = repoKey
            self.attempt = attempt
            self.dueAt = dueAt
            self.error = error
        }
    }

    /// A ticket waiting for a slot, or a Merging ticket waiting for CI.
    public struct Waiting: Equatable {
        public var issueID: String?
        public var identifier: String
        public var title: String?
        public var repoKey: String?
        public var state: String?
        public var reason: String?
        public var since: Date?

        public init(issueID: String? = nil, identifier: String, title: String? = nil, repoKey: String? = nil, state: String? = nil, reason: String? = nil, since: Date? = nil) {
            self.issueID = issueID
            self.identifier = identifier
            self.title = title
            self.repoKey = repoKey
            self.state = state
            self.reason = reason
            self.since = since
        }
    }

    /// A ticket whose labels route it to more than one repo, so Symphony runs it nowhere.
    public struct Conflict: Equatable {
        public var identifier: String
        public var title: String?
        public var url: URL?
        public var repoKeys: [String]

        public init(identifier: String, title: String? = nil, url: URL? = nil, repoKeys: [String] = []) {
            self.identifier = identifier
            self.title = title
            self.url = url
            self.repoKeys = repoKeys
        }
    }

    /// A process left running in a workspace after its run ended.
    public struct StrayProcess: Equatable {
        public var pid: Int?
        public var command: String?
        public var cwd: String?

        public init(pid: Int? = nil, command: String? = nil, cwd: String? = nil) {
            self.pid = pid
            self.command = command
            self.cwd = cwd
        }
    }

    public init(
        snapshot: StateSnapshot = StateSnapshot(),
        generatedAt: Date? = nil,
        repos: [String] = [],
        running: [Run] = [],
        watching: [Ticket] = [],
        humanReview: [Ticket] = [],
        retrying: [Retry] = [],
        slotWaiting: [Waiting] = [],
        conflicts: [Conflict] = [],
        shippedToday: [Ticket] = [],
        shippedTodayCount: Int? = nil,
        qaRunning: [String] = [],
        qaQueued: [String] = [],
        landing: [String] = [],
        strayProcesses: [StrayProcess] = []
    ) {
        self.snapshot = snapshot
        self.generatedAt = generatedAt
        self.repos = repos
        self.running = running
        self.watching = watching
        self.humanReview = humanReview
        self.retrying = retrying
        self.slotWaiting = slotWaiting
        self.conflicts = conflicts
        self.shippedToday = shippedToday
        self.shippedTodayCount = shippedTodayCount
        self.qaRunning = qaRunning
        self.qaQueued = qaQueued
        self.landing = landing
        self.strayProcesses = strayProcesses
    }

    /// The Overview's state in a state payload, nil when it isn't one (an error, or not JSON).
    public static func decode(_ data: Data) -> OverviewState? {
        guard case let .state(snapshot) = SymphonyState.poll(data: data, statusCode: 200),
              let payload = try? decoder.decode(Payload.self, from: data)
        else { return nil }
        return OverviewState(
            snapshot: snapshot,
            generatedAt: payload.generatedAt.flatMap(SymphonyState.parseDate),
            repos: payload.repos ?? [],
            running: (payload.running ?? []).compactMap { run in
                guard let identifier = run.issueIdentifier ?? run.issueId else { return nil }
                return Run(
                    issueID: run.issueId,
                    identifier: identifier,
                    title: run.title,
                    repoKey: run.repoKey,
                    state: run.state,
                    runKind: run.runKind,
                    url: run.url.flatMap(URL.init(string:)),
                    turnCount: run.turnCount ?? 0,
                    lastMessage: run.lastMessage,
                    startedAt: run.startedAt.flatMap(SymphonyState.parseDate),
                    lastEventAt: run.lastEventAt.flatMap(SymphonyState.parseDate),
                    totalTokens: run.tokens?.totalTokens ?? 0
                )
            },
            watching: (payload.watching ?? []).compactMap(ticket),
            humanReview: (payload.humanReview ?? []).compactMap(ticket),
            retrying: (payload.retrying ?? []).compactMap { retry in
                guard let identifier = retry.issueIdentifier ?? retry.issueId else { return nil }
                return Retry(
                    issueID: retry.issueId,
                    identifier: identifier,
                    title: retry.title,
                    repoKey: retry.repoKey,
                    attempt: retry.attempt ?? 0,
                    dueAt: retry.dueAt.flatMap(SymphonyState.parseDate),
                    error: retry.error
                )
            },
            slotWaiting: (payload.slotWaiting ?? []).compactMap { waiting in
                guard let identifier = waiting.issueIdentifier ?? waiting.issueId else { return nil }
                return Waiting(
                    issueID: waiting.issueId,
                    identifier: identifier,
                    title: waiting.title,
                    repoKey: waiting.repoKey,
                    state: waiting.state,
                    reason: waiting.reason,
                    since: waiting.since.flatMap(SymphonyState.parseDate)
                )
            },
            conflicts: (payload.conflicts ?? []).compactMap { conflict in
                guard let identifier = conflict.issueIdentifier ?? conflict.issueId else { return nil }
                return Conflict(
                    identifier: identifier,
                    title: conflict.title,
                    url: conflict.url.flatMap(URL.init(string:)),
                    repoKeys: conflict.repoKeys ?? []
                )
            },
            shippedToday: (payload.shippedToday ?? []).compactMap(ticket),
            shippedTodayCount: payload.counts?.shippedToday,
            qaRunning: (payload.qa?.running ?? []).compactMap(\.issueId),
            qaQueued: (payload.qa?.queued ?? []).compactMap(\.issueId),
            landing: (payload.finishing?.running ?? []).compactMap(\.issueId),
            strayProcesses: (payload.strayProcesses ?? []).map { StrayProcess(pid: $0.pid, command: $0.command, cwd: $0.cwd) }
        )
    }

    private static func ticket(_ entry: Payload.Ticket) -> Ticket? {
        guard let identifier = entry.issueIdentifier ?? entry.issueId else { return nil }
        return Ticket(
            issueID: entry.issueId,
            identifier: identifier,
            title: entry.title,
            repoKey: entry.repoKey,
            state: entry.state,
            url: entry.url.flatMap(URL.init(string:)),
            secondsSinceLastRun: entry.secondsSinceLastRun
        )
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private struct Payload: Decodable {
        struct Counts: Decodable {
            let shippedToday: Int?
        }

        struct Tokens: Decodable {
            let totalTokens: Int?
        }

        struct Running: Decodable {
            let issueId: String?
            let issueIdentifier: String?
            let title: String?
            let repoKey: String?
            let state: String?
            let runKind: String?
            let url: String?
            let turnCount: Int?
            let lastMessage: String?
            let startedAt: String?
            let lastEventAt: String?
            let tokens: Tokens?
        }

        struct Ticket: Decodable {
            let issueId: String?
            let issueIdentifier: String?
            let title: String?
            let repoKey: String?
            let state: String?
            let url: String?
            let secondsSinceLastRun: Int?
        }

        struct Retry: Decodable {
            let issueId: String?
            let issueIdentifier: String?
            let title: String?
            let repoKey: String?
            let attempt: Int?
            let dueAt: String?
            let error: String?
        }

        struct Waiting: Decodable {
            let issueId: String?
            let issueIdentifier: String?
            let title: String?
            let repoKey: String?
            let state: String?
            let reason: String?
            let since: String?
        }

        struct Conflict: Decodable {
            let issueId: String?
            let issueIdentifier: String?
            let title: String?
            let url: String?
            let repoKeys: [String]?
        }

        struct Pass: Decodable {
            let issueId: String?
        }

        struct Passes: Decodable {
            let running: [Pass]?
            let queued: [Pass]?
        }

        struct Stray: Decodable {
            let pid: Int?
            let command: String?
            let cwd: String?
        }

        let generatedAt: String?
        let repos: [String]?
        let counts: Counts?
        let running: [Running]?
        let watching: [Ticket]?
        let humanReview: [Ticket]?
        let retrying: [Retry]?
        let slotWaiting: [Waiting]?
        let conflicts: [Conflict]?
        let shippedToday: [Ticket]?
        let qa: Passes?
        let finishing: Passes?
        let strayProcesses: [Stray]?
    }
}
