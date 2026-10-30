import Foundation

/// What the menu shows from one `GET /api/v1/state` response.
public struct StateSnapshot: Equatable {
    public var running: Int
    public var retrying: Int
    /// Set while the operator paused dispatch, nil otherwise.
    public var pause: Pause?
    /// Provider usage-limit holds, soonest resume first; empty when nothing is held.
    public var usageLimits: [UsageLimit]
    /// Today's tokens against `agent.limits`, nil when Symphony didn't report them.
    public var budget: Budget?
    /// Tickets held only until the running Symphony includes a fix that merged: updating releases them.
    public var updateUnblocks: Int
    /// The newest published release of the repository the app updates from, as Symphony last heard of it; nil when
    /// Symphony knows none, or predates `app_update.latest_release`.
    public var latestRelease: ReportedRelease?
    /// Tickets forced past the dispatch limits, in queue order; empty when none is, or when Symphony predates them.
    public var forced: [ForcedTicket]
    /// The running agents, in Symphony's order; empty when none runs.
    public var runs: [Run]
    /// The tickets only the operator can move on, oldest first; empty when none does, or when Symphony predates them.
    public var waitingOnYou: [WaitingTicket]
    /// False while Symphony hasn't read Linear for `waitingOnYou` yet, so an empty list may be incomplete; true
    /// once it has, or when Symphony predates the field.
    public var inboxRead: Bool
    /// The kind of every live session (agent runs, QA passes, code review runs), in Symphony's
    /// order; nil when Symphony predates `sessions`.
    public var sessionKinds: [String]?
    /// The setup problems Symphony found (`setup`), nil when Symphony predates Setup.
    public var setup: SetupPayload?
    /// The running Symphony's build (`build.version`), for the app's build warning; nil when it didn't say.
    public var serviceVersion: String?
    /// Linear's workspace webhook and the deliveries Symphony counted (`linear_webhooks`), nil when Symphony
    /// predates them.
    public var linearWebhooks: LinearWebhookHealth?
    /// Where dispatch reads its candidates from and how the record's candidates compared with the poll's
    /// (`dispatch_shadow`), nil when Symphony predates them.
    public var dispatchShadow: DispatchShadowReport?
    /// What the reconciler did and the drift it found (`reconcile`), nil when Symphony predates it.
    public var reconcile: ReconcileReport?
    /// Every configured repository and its pause (`repositories`), in Symphony's order; nil when Symphony predates
    /// the pause of one repository, so the app offers no Pause for it.
    public var repositories: [Repository]?
    /// Every reason Symphony's own pause holds (`pause.reasons`), in the order they were set, the usage-limit holds'
    /// included; nil when Symphony predates them, so the header reads `pause` as before.
    public var pauseReasons: [PauseReason]?

    /// One reason of Symphony's pause: who or what holds dispatch and since when.
    public struct PauseReason: Equatable {
        public enum Kind: Equatable {
            /// The Director paused Symphony.
            case person
            /// An update holds dispatch until it installs `version`.
            case build
            /// Anything else, a usage limit for one, worded by Symphony.
            case other(String)

            init(_ kind: String?) {
                switch kind {
                case "person": self = .person
                case "build": self = .build
                default: self = .other(kind ?? "")
                }
            }
        }

        public var kind: Kind
        /// The reason's line as Symphony words it, for example "You paused Symphony" or "Claude's usage limit until
        /// 14:30".
        public var text: String
        public var since: Date?
        /// The version a `build` reason waits on (`waits_on.version`).
        public var version: String?

        public init(kind: Kind, text: String = "", since: Date? = nil, version: String? = nil) {
            self.kind = kind
            self.text = text
            self.since = since
            self.version = version
        }
    }

    /// Every listed repository is paused, so nothing dispatches even while Symphony itself runs.
    public var allRepositoriesPaused: Bool {
        guard let repositories, !repositories.isEmpty else { return false }
        return repositories.allSatisfy { $0.pause != nil }
    }

    /// The version an update's pause waits on: its `build` reason's field; nil without one, or from a Symphony that
    /// predates reasons.
    public var updatePauseVersion: String? {
        pauseReasons?.first { $0.kind == .build }?.version
    }

    /// A configured repository as `/api/v1/state`'s `repositories` lists it, with its pause while dispatch for it
    /// is paused.
    public struct Repository: Equatable {
        public var key: String
        public var pause: RepositoryPause?

        public init(key: String, pause: RepositoryPause? = nil) {
            self.key = key
            self.pause = pause
        }
    }

    /// Why a repository is paused: its reasons' lines, as Symphony words them, and since when.
    public struct RepositoryPause: Equatable {
        public var reasons: [String]
        public var since: Date?

        public init(reasons: [String] = [], since: Date? = nil) {
            self.reasons = reasons
            self.since = since
        }
    }

    /// The listed repository `key`, nil when Symphony doesn't list it or predates `repositories`.
    public func repository(_ key: String) -> Repository? {
        repositories?.first { $0.key == key }
    }

    /// A ticket waiting on the operator, as `/api/v1/state`'s `waiting_on_you` lists it.
    public struct WaitingTicket: Equatable {
        /// What the operator is asked for.
        public enum Kind: Equatable {
            /// A plan waiting for approval.
            case plan
            /// A pull request to review.
            case pr
            /// A decision an agent asked for with `linear_request_human_action`.
            case action
            /// A ticket the quality gate held for clarification or skipped.
            case clarify
            /// A ticket an access hold pauses in place, waiting on an Unblock.
            case blocked
            /// A kind this app doesn't know yet.
            case other(String)

            public init(_ text: String?) {
                switch text {
                case "plan"?: self = .plan
                case "pr"?: self = .pr
                case "action"?: self = .action
                case "clarify"?: self = .clarify
                case "blocked"?: self = .blocked
                default: self = .other(text ?? "")
                }
            }

            /// The Inbox kind, nil for one this app doesn't know.
            public var inboxKind: InboxItem.Kind? {
                switch self {
                case .plan: .plan
                case .pr: .pr
                case .action: .action
                case .clarify: .clarify
                case .blocked: .blocked
                case .other: nil
                }
            }

            /// The SF Symbol of the kind, in the menu and in notifications.
            public var symbol: String { inboxKind?.symbol ?? SymphonyView.inbox.symbol }
        }

        /// The Linear issue id, which the Inbox selects it by.
        public var issueID: String?
        public var identifier: String
        /// The repo it belongs to, for the window's scope; nil when Symphony didn't say.
        public var repoKey: String?
        public var title: String?
        /// The ticket in Linear.
        public var url: URL?
        public var kind: Kind
        /// A request that offers options to answer with: it reads "Decision", as the Inbox's does (DD-7). An older
        /// hand-written request with steps, or a Symphony that doesn't say, stays an action.
        public var isDecision: Bool
        /// The `**What to review:**` line of its review brief, nil when it has none.
        public var headline: String?
        /// How long it has waited, nil when Symphony couldn't tell.
        public var waitingSeconds: Int?
        /// A pull request whose checks are green: its notification offers Approve and Merge….
        public var checksGreen: Bool

        public init(
            issueID: String? = nil,
            identifier: String,
            repoKey: String? = nil,
            title: String? = nil,
            url: URL? = nil,
            kind: Kind = .pr,
            isDecision: Bool = false,
            headline: String? = nil,
            waitingSeconds: Int? = nil,
            checksGreen: Bool = false
        ) {
            self.issueID = issueID
            self.identifier = identifier
            self.repoKey = repoKey
            self.title = title
            self.url = url
            self.kind = kind
            self.isDecision = isDecision
            self.headline = headline
            self.waitingSeconds = waitingSeconds
            self.checksGreen = checksGreen
        }
    }

    /// A running agent, as `/api/v1/state`'s `running` lists it.
    public struct Run: Equatable {
        public var issueIdentifier: String
        /// The repo it runs on, nil when Symphony didn't say.
        public var repoKey: String?
        /// The issue in Linear.
        public var url: URL?
        public var startedAt: Date?
        /// Its last agent event, nil before the first.
        public var lastEventAt: Date?

        public init(issueIdentifier: String, repoKey: String? = nil, url: URL? = nil, startedAt: Date? = nil, lastEventAt: Date? = nil) {
            self.issueIdentifier = issueIdentifier
            self.repoKey = repoKey
            self.url = url
            self.startedAt = startedAt
            self.lastEventAt = lastEventAt
        }
    }

    public struct Pause: Equatable {
        public var reason: String?
        public var since: Date?

        public init(reason: String? = nil, since: Date? = nil) {
            self.reason = reason
            self.since = since
        }
    }

    /// A hold Symphony put on new runs of a provider, for example after Claude's five-hour limit ran out.
    public struct UsageLimit: Equatable {
        public enum Phase: Equatable {
            /// New runs wait for the window to reset.
            case paused
            /// The window reset, and one run checks the limit before the rest resume.
            case canary
            /// The window is close to used up, so new runs wait for it to reset.
            case headroom
        }

        public var provider: String
        /// `all`, or the model family the hold is on, for example `opus`.
        public var scope: String
        /// For example `five_hour` or `seven_day`; nil when the provider didn't say.
        public var window: String?
        public var phase: Phase
        public var resetsAt: Date?
        public var resumeAt: Date?
        /// How much of the window is used, from 0 to 1, when known.
        public var utilization: Double?
        /// Why Symphony holds the provider, for example `claude_usage_limit` or `model_api_unreachable`; nil when
        /// Symphony predates it.
        public var reason: String?
        /// What the agent got when it couldn't reach the model API, for example `ENOTFOUND`.
        public var error: String?

        /// Symphony holds the provider because its API couldn't be reached, not for a usage limit.
        public var isAPIUnreachable: Bool { reason == "model_api_unreachable" }

        public init(
            provider: String = "anthropic",
            scope: String = "all",
            window: String? = nil,
            phase: Phase = .paused,
            resetsAt: Date? = nil,
            resumeAt: Date? = nil,
            utilization: Double? = nil,
            reason: String? = nil,
            error: String? = nil
        ) {
            self.provider = provider
            self.scope = scope
            self.window = window
            self.phase = phase
            self.resetsAt = resetsAt
            self.resumeAt = resumeAt
            self.utilization = utilization
            self.reason = reason
            self.error = error
        }
    }

    /// A ticket forced past the dispatch limits (`symphony force`, or its force label in Linear).
    public struct ForcedTicket: Equatable {
        public var identifier: String
        public var issueID: String?
        public var title: String?
        public var repoKey: String?
        /// What it is doing and what it waits on, as Symphony words it: "implementation · running",
        /// "implementation · waiting on blocker TP-1", "waiting for a human". Nil when Symphony didn't say.
        public var summary: String?
        /// Its Linear state, for example "Todo".
        public var state: String?
        public var forcedForSeconds: Int?
        /// Forced for longer than `agent.concurrency.forced_stale_after_hours`.
        public var stale: Bool
        /// For a forced parent, the sub-ticket it is working through now.
        public var part: String?

        public init(
            identifier: String,
            issueID: String? = nil,
            title: String? = nil,
            repoKey: String? = nil,
            summary: String? = nil,
            state: String? = nil,
            forcedForSeconds: Int? = nil,
            stale: Bool = false,
            part: String? = nil
        ) {
            self.identifier = identifier
            self.issueID = issueID
            self.title = title
            self.repoKey = repoKey
            self.summary = summary
            self.state = state
            self.forcedForSeconds = forcedForSeconds
            self.stale = stale
            self.part = part
        }
    }

    /// Symphony's token counts for the UTC day and its token caps; a nil limit is a cap turned off.
    public struct Budget: Equatable {
        public var dailyLimit: Int?
        public var dailyUsed: Int
        public var dailyRemaining: Int?
        /// True while the daily cap holds new runs.
        public var dailyPaused: Bool
        public var perIssueLimit: Int?

        public init(
            dailyLimit: Int? = nil,
            dailyUsed: Int = 0,
            dailyRemaining: Int? = nil,
            dailyPaused: Bool = false,
            perIssueLimit: Int? = nil
        ) {
            self.dailyLimit = dailyLimit
            self.dailyUsed = dailyUsed
            self.dailyRemaining = dailyRemaining
            self.dailyPaused = dailyPaused
            self.perIssueLimit = perIssueLimit
        }
    }

    public init(
        running: Int = 0,
        retrying: Int = 0,
        pause: Pause? = nil,
        usageLimits: [UsageLimit] = [],
        budget: Budget? = nil,
        updateUnblocks: Int = 0,
        latestRelease: ReportedRelease? = nil,
        forced: [ForcedTicket] = [],
        runs: [Run] = [],
        waitingOnYou: [WaitingTicket] = [],
        inboxRead: Bool = true,
        sessionKinds: [String]? = nil,
        setup: SetupPayload? = nil,
        serviceVersion: String? = nil,
        linearWebhooks: LinearWebhookHealth? = nil,
        dispatchShadow: DispatchShadowReport? = nil,
        reconcile: ReconcileReport? = nil,
        repositories: [Repository]? = nil,
        pauseReasons: [PauseReason]? = nil
    ) {
        self.running = running
        self.retrying = retrying
        self.pause = pause
        self.usageLimits = usageLimits
        self.budget = budget
        self.updateUnblocks = updateUnblocks
        self.latestRelease = latestRelease
        self.forced = forced
        self.runs = runs
        self.waitingOnYou = waitingOnYou
        self.inboxRead = inboxRead
        self.sessionKinds = sessionKinds
        self.setup = setup
        self.serviceVersion = serviceVersion
        self.linearWebhooks = linearWebhooks
        self.dispatchShadow = dispatchShadow
        self.reconcile = reconcile
        self.repositories = repositories
        self.pauseReasons = pauseReasons
    }
}

/// Linear's workspace webhook as `/api/v1/state`'s `linear_webhooks` reports it
/// (`SymphonyElixir.Linear.Webhook.Deliveries`): whether it is on, whether a signing secret resolves, and the deliveries
/// counted since Symphony started. The counts live in Symphony's memory, so they start again at a restart.
public struct LinearWebhookHealth: Equatable {
    public var enabled: Bool
    /// True when `linear.webhooks.secret` resolves to a value; never the value itself.
    public var secretConfigured: Bool
    /// Accepted deliveries.
    public var total: Int
    /// Refused deliveries: no secret, no or a bad signature, a stale timestamp.
    public var rejected: Int
    public var lastAt: Date?
    public var lastRejectedAt: Date?
    /// Why the last refused delivery was refused: `missing_secret`, `missing_signature`, `bad_signature` or
    /// `stale_timestamp`.
    public var lastRejectedReason: String?

    public init(
        enabled: Bool = false,
        secretConfigured: Bool = false,
        total: Int = 0,
        rejected: Int = 0,
        lastAt: Date? = nil,
        lastRejectedAt: Date? = nil,
        lastRejectedReason: String? = nil
    ) {
        self.enabled = enabled
        self.secretConfigured = secretConfigured
        self.total = total
        self.rejected = rejected
        self.lastAt = lastAt
        self.lastRejectedAt = lastRejectedAt
        self.lastRejectedReason = lastRejectedReason
    }

    /// The `linear_webhooks` block of a `/api/v1/state` payload, nil when Symphony predates it. Read on its own, so a
    /// block this app can't read never fails the rest of the state.
    public static func decode(state data: Data) -> LinearWebhookHealth? {
        struct Wire: Decodable {
            let enabled: Bool?
            let secretConfigured: Bool?
            let total: Int?
            let rejected: Int?
            let lastAt: String?
            let lastRejectedAt: String?
            let lastRejectedReason: String?
        }
        struct State: Decodable { let linearWebhooks: Wire? }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let wire = (try? decoder.decode(State.self, from: data))?.linearWebhooks else { return nil }
        return LinearWebhookHealth(
            enabled: wire.enabled ?? false,
            secretConfigured: wire.secretConfigured ?? false,
            total: wire.total ?? 0,
            rejected: wire.rejected ?? 0,
            lastAt: wire.lastAt.flatMap(SymphonyState.parseDate),
            lastRejectedAt: wire.lastRejectedAt.flatMap(SymphonyState.parseDate),
            lastRejectedReason: wire.lastRejectedReason
        )
    }
}

/// Where dispatch reads its candidates from, and how the candidates Symphony's ticket records give compared with the
/// Linear poll's, as `/api/v1/state`'s `dispatch_shadow` reports it (`SymphonyElixir.Dispatch.Shadow`). The counts live
/// in Symphony's memory, so they start again at a restart.
public struct DispatchShadowReport: Equatable {
    /// One ticket the two sides disagree on.
    public struct Difference: Equatable {
        /// Which side has the ticket: only the poll, only the record, or both with a different field.
        public enum Side: Equatable {
            case poll
            case record
            case both
            /// A side this app doesn't know yet.
            case other(String)

            public init(_ text: String) {
                switch text {
                case "poll": self = .poll
                case "record": self = .record
                case "both": self = .both
                default: self = .other(text)
                }
            }
        }

        public var identifier: String
        public var side: Side
        /// `candidate` (the ticket is a candidate on one side only), `state` or `priority`.
        public var field: String
        /// What each side has: the state for `candidate`, nil on the side without the ticket.
        public var poll: String?
        public var record: String?
        public var at: Date?

        public init(identifier: String, side: Side, field: String, poll: String? = nil, record: String? = nil, at: Date? = nil) {
            self.identifier = identifier
            self.side = side
            self.field = field
            self.poll = poll
            self.record = record
            self.at = at
        }
    }

    /// `dispatch.source`: `poll` or `record`.
    public var source: DispatchSettings.Source
    /// `dispatch.shadow_window`: how many cycles `windowDifferences` counts over.
    public var window: Int
    public var cyclesCompared: Int
    public var cyclesWithDifferences: Int
    /// The cycles the window holds so far, up to `window`.
    public var windowCycles: Int
    public var windowDifferences: Int
    /// The last ten differences that appeared, newest first.
    public var recent: [Difference]

    public init(
        source: DispatchSettings.Source = .poll,
        window: Int = DispatchSettings.defaultShadowWindow,
        cyclesCompared: Int = 0,
        cyclesWithDifferences: Int = 0,
        windowCycles: Int = 0,
        windowDifferences: Int = 0,
        recent: [Difference] = []
    ) {
        self.source = source
        self.window = window
        self.cyclesCompared = cyclesCompared
        self.cyclesWithDifferences = cyclesWithDifferences
        self.windowCycles = windowCycles
        self.windowDifferences = windowDifferences
        self.recent = recent
    }

    /// When the newest difference appeared; nil when none has.
    public var lastDifferenceAt: Date? { recent.compactMap(\.at).max() }

    /// The `dispatch_shadow` block of a `/api/v1/state` payload, nil when Symphony predates it. Read on its own, so a
    /// block this app can't read never fails the rest of the state.
    public static func decode(state data: Data) -> DispatchShadowReport? {
        struct Wire: Decodable {
            let source: String?
            let window: Int?
            let cyclesCompared: Int?
            let cyclesWithDifferences: Int?
            let windowCycles: Int?
            let windowDifferences: Int?
            let recent: [WireDifference]?
        }
        struct WireDifference: Decodable {
            let identifier: String?
            let issueId: String?
            let side: String
            let field: String
            let poll: Value?
            let record: Value?
            let at: String?
        }
        struct State: Decodable { let dispatchShadow: Wire? }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let wire = (try? decoder.decode(State.self, from: data))?.dispatchShadow else { return nil }
        return DispatchShadowReport(
            source: wire.source.flatMap(DispatchSettings.Source.init(rawValue:)) ?? .poll,
            window: wire.window ?? DispatchSettings.defaultShadowWindow,
            cyclesCompared: wire.cyclesCompared ?? 0,
            cyclesWithDifferences: wire.cyclesWithDifferences ?? 0,
            windowCycles: wire.windowCycles ?? 0,
            windowDifferences: wire.windowDifferences ?? 0,
            recent: (wire.recent ?? []).map { difference in
                Difference(
                    identifier: difference.identifier ?? difference.issueId ?? "?",
                    side: .init(difference.side),
                    field: difference.field,
                    poll: difference.poll?.text,
                    record: difference.record?.text,
                    at: difference.at.flatMap(SymphonyState.parseDate)
                )
            }
        )
    }

    /// A side's value: a state's name or a priority's number.
    private struct Value: Decodable {
        let text: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                text = nil
            } else if let number = try? container.decode(Int.self) {
                text = String(number)
            } else {
                text = try container.decode(String.self)
            }
        }
    }
}

/// What the reconciler did while dispatch reads Symphony's record, and the drift found on phases Symphony owns, as
/// `/api/v1/state`'s `reconcile` reports it (`SymphonyElixir.TicketObservation`). The counts live in Symphony's memory,
/// so they start again at a restart.
public struct ReconcileReport: Equatable {
    /// A ticket moved in Linear off a phase Symphony owns.
    public struct Drift: Equatable {
        /// Whether Symphony moved it back in Linear.
        public enum Outcome: Equatable {
            case reverted
            case failed
            /// An outcome this app doesn't know yet.
            case other(String)

            public init(_ text: String?) {
                switch text {
                case "reverted"?: self = .reverted
                case "revert_failed"?: self = .failed
                default: self = .other(text ?? "unknown")
                }
            }
        }

        public var identifier: String
        /// The phase Symphony's record holds.
        public var recordPhase: String?
        /// The state the ticket was moved to in Linear.
        public var linearPhase: String?
        public var outcome: Outcome
        public var at: Date?

        public init(identifier: String, recordPhase: String? = nil, linearPhase: String? = nil, outcome: Outcome, at: Date? = nil) {
            self.identifier = identifier
            self.recordPhase = recordPhase
            self.linearPhase = linearPhase
            self.outcome = outcome
            self.at = at
        }
    }

    /// When the reconciler last ran; nil before its first run.
    public var lastRunAt: Date?
    /// `linear.reconcile_interval_ms`.
    public var intervalMs: Int
    /// Changes made in Linear the reconciler applied to the record.
    public var applied: Int
    /// Failed writes to Linear (a move or a hold label) the reconciler made again.
    public var reapplied: Int
    /// Records no read had seen yet that the reconciler read by id.
    public var unobservedFilled: Int
    public var detected: Int
    public var reverted: Int
    public var revertFailed: Int
    /// The last ten drifts, newest first.
    public var recent: [Drift]

    public init(
        lastRunAt: Date? = nil,
        intervalMs: Int = DispatchSettings.defaultReconcileIntervalMs,
        applied: Int = 0,
        reapplied: Int = 0,
        unobservedFilled: Int = 0,
        detected: Int = 0,
        reverted: Int = 0,
        revertFailed: Int = 0,
        recent: [Drift] = []
    ) {
        self.lastRunAt = lastRunAt
        self.intervalMs = intervalMs
        self.applied = applied
        self.reapplied = reapplied
        self.unobservedFilled = unobservedFilled
        self.detected = detected
        self.reverted = reverted
        self.revertFailed = revertFailed
        self.recent = recent
    }

    /// The `reconcile` block of a `/api/v1/state` payload, nil when Symphony predates it. Read on its own, so a block
    /// this app can't read never fails the rest of the state.
    public static func decode(state data: Data) -> ReconcileReport? {
        struct Wire: Decodable {
            let lastRunAt: String?
            let intervalMs: Int?
            let applied: Int?
            let reapplied: Int?
            let unobservedFilled: Int?
            let detected: Int?
            let reverted: Int?
            let revertFailed: Int?
            let recent: [WireDrift]?
        }
        struct WireDrift: Decodable {
            let identifier: String?
            let recordPhase: String?
            let linearPhase: String?
            let outcome: String?
            let at: String?
        }
        struct State: Decodable { let reconcile: Wire? }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let wire = (try? decoder.decode(State.self, from: data))?.reconcile else { return nil }
        return ReconcileReport(
            lastRunAt: wire.lastRunAt.flatMap(SymphonyState.parseDate),
            intervalMs: wire.intervalMs ?? DispatchSettings.defaultReconcileIntervalMs,
            applied: wire.applied ?? 0,
            reapplied: wire.reapplied ?? 0,
            unobservedFilled: wire.unobservedFilled ?? 0,
            detected: wire.detected ?? 0,
            reverted: wire.reverted ?? 0,
            revertFailed: wire.revertFailed ?? 0,
            recent: (wire.recent ?? []).map { drift in
                Drift(
                    identifier: drift.identifier ?? "?",
                    recordPhase: drift.recordPhase,
                    linearPhase: drift.linearPhase,
                    outcome: .init(drift.outcome),
                    at: drift.at.flatMap(SymphonyState.parseDate)
                )
            }
        )
    }
}

/// The newest published release Symphony reports under `/api/v1/state`'s `app_update`, from GitHub's `release`
/// delivery or its own timed read. The app checks for an update at once when it is newer than the build it runs
/// (`UpdateCheckSchedule.checksAtOnce`).
public struct ReportedRelease: Equatable {
    /// For example `v0.0.1.583`.
    public var tag: String
    /// When GitHub published it; nil when Symphony didn't say.
    public var publishedAt: Date?

    public init(tag: String, publishedAt: Date? = nil) {
        self.tag = tag
        self.publishedAt = publishedAt
    }

    /// The tag without its `v`, as `Release.version` and `AppBuild.version` read it: `0.0.1.583`.
    public var version: String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }
}

/// The outcome of polling Symphony's state.
public enum StatusPoll: Equatable {
    /// Symphony answered with its state.
    case state(StateSnapshot)
    /// Nothing answered on the control URL.
    case unreachable
    /// Something answered, but not with a state; the message says what went wrong.
    case failed(String)
}

/// Reads what the app needs from Symphony's `GET /api/v1/state`.
public enum SymphonyState {
    /// Dashboard URL used when Symphony hasn't written its control URL file.
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:4000")!

    /// The URL in the control URL file's contents, or the default when they are empty or not a URL.
    public static func baseURL(controlURLContents: String?) -> URL {
        baseURL(controlURLContents: controlURLContents, fallback: defaultBaseURL) ?? defaultBaseURL
    }

    /// The URL in the control URL file's contents, or `fallback` when they are empty or not a URL.
    public static func baseURL(controlURLContents: String?, fallback: URL?) -> URL? {
        let text = controlURLContents?.trimmingWhitespace() ?? ""
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme),
            url.host != nil
        else { return fallback }
        return url
    }

    /// The URL in the control URL file, or the default when the file is missing or holds no URL.
    public static func baseURL(controlURLFile file: URL) -> URL {
        baseURL(controlURLFile: file, fallback: defaultBaseURL) ?? defaultBaseURL
    }

    /// The URL in the control URL file, or `fallback` when the file is missing or holds no URL.
    public static func baseURL(controlURLFile file: URL, fallback: URL?) -> URL? {
        baseURL(controlURLContents: try? String(contentsOf: file, encoding: .utf8), fallback: fallback)
    }

    public static func stateURL(base: URL) -> URL {
        base.appendingPathComponent("api/v1/state")
    }

    /// Turns a state response into a poll result.
    public static func poll(data: Data, statusCode: Int) -> StatusPoll {
        guard statusCode == 200 else { return .failed("Symphony answered with HTTP \(statusCode)") }
        guard let payload = try? decoder.decode(Payload.self, from: data) else {
            return .failed("Symphony's state couldn't be read")
        }
        if let error = payload.error {
            return .failed(error.message ?? error.code ?? "Symphony reported an error")
        }
        guard let counts = payload.counts else { return .failed("Symphony's state couldn't be read") }

        var snapshot = StateSnapshot(
            running: counts.running, retrying: counts.retrying ?? 0, updateUnblocks: payload.appUpdate?.unblocks ?? 0
        )
        if let release = payload.appUpdate?.latestRelease, let tag = release.tag, !tag.isEmpty {
            snapshot.latestRelease = ReportedRelease(tag: tag, publishedAt: release.publishedAt.flatMap(parseDate))
        }
        if let pause = payload.pause, pause.paused {
            snapshot.pause = .init(reason: pause.reason, since: pause.pausedAt.flatMap(parseDate))
        }
        snapshot.pauseReasons = payload.pause?.reasons?.compactMap { reason in
            let version = reason.waitsOn?.version?.trimmingWhitespace()
            return StateSnapshot.PauseReason(
                kind: .init(reason.kind),
                text: reason.text?.trimmingWhitespace() ?? "",
                since: reason.since.flatMap(parseDate),
                version: version?.isEmpty == false ? version : nil
            )
        }
        snapshot.usageLimits = (payload.usageLimits ?? []).map { limit in
            StateSnapshot.UsageLimit(
                provider: limit.provider ?? "anthropic",
                scope: limit.scope ?? "all",
                window: limit.window,
                phase: phase(limit.phase),
                resetsAt: limit.resetsAt.flatMap(parseDate),
                resumeAt: limit.resumeAt.flatMap(parseDate),
                utilization: limit.utilization,
                reason: limit.reason,
                error: limit.error
            )
        }
        snapshot.budget = payload.budget.map { budget in
            StateSnapshot.Budget(
                dailyLimit: budget.dailyLimit,
                dailyUsed: budget.dailyUsed ?? 0,
                dailyRemaining: budget.dailyRemaining,
                dailyPaused: budget.dailyPaused ?? false,
                perIssueLimit: budget.perIssueLimit
            )
        }
        snapshot.forced = (payload.forced ?? []).compactMap { ticket in
            guard let identifier = ticket.issueIdentifier ?? ticket.issueId else { return nil }
            return StateSnapshot.ForcedTicket(
                identifier: identifier,
                issueID: ticket.issueId,
                title: ticket.title,
                repoKey: ticket.repoKey,
                summary: ticket.summary,
                state: ticket.state,
                forcedForSeconds: ticket.forcedForSeconds,
                stale: ticket.stale ?? false,
                part: ticket.subIssue?.issueIdentifier
            )
        }
        snapshot.sessionKinds = payload.sessions?.map { $0.kind ?? "agent" }
        snapshot.runs = (payload.running ?? []).compactMap { run in
            guard let identifier = run.issueIdentifier ?? run.issueId else { return nil }
            return StateSnapshot.Run(
                issueIdentifier: identifier,
                repoKey: run.repoKey,
                url: run.url.flatMap(URL.init(string:)),
                startedAt: run.startedAt.flatMap(parseDate),
                lastEventAt: run.lastEventAt.flatMap(parseDate)
            )
        }
        snapshot.waitingOnYou = (payload.waitingOnYou ?? []).compactMap { ticket in
            guard let identifier = ticket.issueIdentifier ?? ticket.issueId else { return nil }
            return StateSnapshot.WaitingTicket(
                issueID: ticket.issueId,
                identifier: identifier,
                repoKey: ticket.repoKey,
                title: ticket.title,
                url: ticket.url.flatMap(URL.init(string:)),
                kind: .init(ticket.kind),
                isDecision: ticket.decision ?? false,
                headline: ticket.headline,
                waitingSeconds: ticket.waitingSeconds,
                checksGreen: ticket.checksGreen ?? false
            )
        }
        snapshot.inboxRead = payload.inboxRead ?? true
        snapshot.setup = SetupPayload.decode(state: data)
        snapshot.serviceVersion = payload.build?.version
        snapshot.linearWebhooks = LinearWebhookHealth.decode(state: data)
        snapshot.dispatchShadow = DispatchShadowReport.decode(state: data)
        snapshot.reconcile = ReconcileReport.decode(state: data)
        snapshot.repositories = payload.repositories?.compactMap { repository in
            guard let key = repository.repoKey, !key.isEmpty else { return nil }
            let pause = repository.pause.map { pause in
                StateSnapshot.RepositoryPause(
                    reasons: (pause.reasons ?? []).compactMap { $0.text?.trimmingWhitespace() }.filter { !$0.isEmpty },
                    since: pause.since.flatMap(parseDate)
                )
            }
            return StateSnapshot.Repository(key: key, pause: pause)
        }
        return .state(snapshot)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Symphony writes whole-second UTC timestamps, for example `2026-10-02T12:16:02Z`.
    static func parseDate(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }

    /// An unknown phase reads as paused, the hold every Symphony with `usage_limits` reports.
    private static func phase(_ text: String?) -> StateSnapshot.UsageLimit.Phase {
        switch text {
        case "canary":
            return .canary
        case "headroom":
            return .headroom
        default:
            return .paused
        }
    }

    private struct Payload: Decodable {
        struct Counts: Decodable {
            let running: Int
            let retrying: Int?
        }

        struct Pause: Decodable {
            struct Reason: Decodable {
                struct WaitsOn: Decodable {
                    let version: String?
                }

                let kind: String?
                let text: String?
                let since: String?
                let waitsOn: WaitsOn?
            }

            let paused: Bool
            let reason: String?
            let pausedAt: String?
            /// Missing before Symphony's pause carried its reasons.
            let reasons: [Reason]?
        }

        struct Failure: Decodable {
            let code: String?
            let message: String?
        }

        struct UsageLimit: Decodable {
            let provider: String?
            let scope: String?
            let window: String?
            let phase: String?
            let resetsAt: String?
            let resumeAt: String?
            let utilization: Double?
            let reason: String?
            let error: String?
        }

        struct Budget: Decodable {
            let dailyLimit: Int?
            let dailyUsed: Int?
            let dailyRemaining: Int?
            let dailyPaused: Bool?
            let perIssueLimit: Int?
        }

        struct AppUpdate: Decodable {
            struct LatestRelease: Decodable {
                let tag: String?
                let publishedAt: String?
            }

            let unblocks: Int?
            /// Missing before Symphony reported the newest release.
            let latestRelease: LatestRelease?
        }

        struct Forced: Decodable {
            struct Part: Decodable {
                let issueIdentifier: String?
            }

            let issueId: String?
            let issueIdentifier: String?
            let title: String?
            let repoKey: String?
            let summary: String?
            let state: String?
            let forcedForSeconds: Int?
            let stale: Bool?
            let subIssue: Part?
        }

        struct Running: Decodable {
            let issueId: String?
            let issueIdentifier: String?
            let repoKey: String?
            let url: String?
            let startedAt: String?
            let lastEventAt: String?
        }

        struct Session: Decodable {
            let kind: String?
        }

        struct Build: Decodable {
            let version: String?
        }

        struct Repository: Decodable {
            struct Pause: Decodable {
                struct Reason: Decodable {
                    let text: String?
                }

                let since: String?
                let reasons: [Reason]?
            }

            let repoKey: String?
            /// Null while the repository isn't paused.
            let pause: Pause?
        }

        struct Waiting: Decodable {
            let issueId: String?
            let issueIdentifier: String?
            let repoKey: String?
            let title: String?
            let url: String?
            let kind: String?
            let decision: Bool?
            let headline: String?
            let waitingSeconds: Int?
            let checksGreen: Bool?
        }

        let counts: Counts?
        /// Every field is optional, so an entry missing one never fails the whole state.
        let running: [Running]?
        /// Missing before Symphony listed every live session with its kind.
        let sessions: [Session]?
        let pause: Pause?
        let budget: Budget?
        let usageLimits: [UsageLimit]?
        let appUpdate: AppUpdate?
        /// Missing before Symphony reported forced tickets.
        let forced: [Forced]?
        /// Missing before Symphony listed what waits on the operator.
        let waitingOnYou: [Waiting]?
        /// Missing before Symphony said whether it had read the Inbox.
        let inboxRead: Bool?
        let build: Build?
        /// Missing before Symphony paused one repository at a time.
        let repositories: [Repository]?
        let error: Failure?
    }
}
