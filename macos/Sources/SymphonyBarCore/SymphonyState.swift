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
    /// Tickets forced past the dispatch limits, in queue order; empty when none is, or when Symphony predates them.
    public var forced: [ForcedTicket]
    /// Tickets waiting in Human Review, which only the operator can move on; 0 when Symphony predates it.
    public var humanReview: Int
    /// The acceptance gate's agreement stats per repository key; nil when Symphony predates them.
    public var gateAgreement: [String: GateAgreement]?

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

        public init(
            provider: String = "anthropic",
            scope: String = "all",
            window: String? = nil,
            phase: Phase = .paused,
            resetsAt: Date? = nil,
            resumeAt: Date? = nil,
            utilization: Double? = nil
        ) {
            self.provider = provider
            self.scope = scope
            self.window = window
            self.phase = phase
            self.resetsAt = resetsAt
            self.resumeAt = resumeAt
            self.utilization = utilization
        }
    }

    /// A ticket forced past the dispatch limits (`symphony force`, or its force label in Linear).
    public struct ForcedTicket: Equatable {
        public var identifier: String
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
            summary: String? = nil,
            state: String? = nil,
            forcedForSeconds: Int? = nil,
            stale: Bool = false,
            part: String? = nil
        ) {
            self.identifier = identifier
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

    /// How far a repository's acceptance gate verdicts agree with the person who decided them, over its last 50
    /// decisions (`acceptance_gate.agreement` in `/api/v1/state`).
    public struct GateAgreement: Equatable {
        public var judged: Int
        public var agreed: Int
        /// From 0 to 1, nil while no verdict the gate didn't escalate has been decided.
        public var agreementRate: Double?
        public var unsafeApprovals: Int
        public var falseReworks: Int
        public var escalations: Int
        public var readyToEnforce: Bool
        /// The first condition for `enforce` still unmet, for example "at least 20 judged tickets (12 so far)".
        public var unmetCondition: String?

        public init(
            judged: Int = 0,
            agreed: Int = 0,
            agreementRate: Double? = nil,
            unsafeApprovals: Int = 0,
            falseReworks: Int = 0,
            escalations: Int = 0,
            readyToEnforce: Bool = false,
            unmetCondition: String? = nil
        ) {
            self.judged = judged
            self.agreed = agreed
            self.agreementRate = agreementRate
            self.unsafeApprovals = unsafeApprovals
            self.falseReworks = falseReworks
            self.escalations = escalations
            self.readyToEnforce = readyToEnforce
            self.unmetCondition = unmetCondition
        }
    }

    public init(
        running: Int = 0,
        retrying: Int = 0,
        pause: Pause? = nil,
        usageLimits: [UsageLimit] = [],
        budget: Budget? = nil,
        updateUnblocks: Int = 0,
        forced: [ForcedTicket] = [],
        humanReview: Int = 0,
        gateAgreement: [String: GateAgreement]? = nil
    ) {
        self.running = running
        self.retrying = retrying
        self.pause = pause
        self.usageLimits = usageLimits
        self.budget = budget
        self.updateUnblocks = updateUnblocks
        self.forced = forced
        self.humanReview = humanReview
        self.gateAgreement = gateAgreement
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
            running: counts.running, retrying: counts.retrying ?? 0, updateUnblocks: payload.appUpdate?.unblocks ?? 0,
            humanReview: counts.humanReview ?? 0
        )
        if let pause = payload.pause, pause.paused {
            snapshot.pause = .init(reason: pause.reason, since: pause.pausedAt.flatMap(parseDate))
        }
        snapshot.usageLimits = (payload.usageLimits ?? []).map { limit in
            StateSnapshot.UsageLimit(
                provider: limit.provider ?? "anthropic",
                scope: limit.scope ?? "all",
                window: limit.window,
                phase: phase(limit.phase),
                resetsAt: limit.resetsAt.flatMap(parseDate),
                resumeAt: limit.resumeAt.flatMap(parseDate),
                utilization: limit.utilization
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
                summary: ticket.summary,
                state: ticket.state,
                forcedForSeconds: ticket.forcedForSeconds,
                stale: ticket.stale ?? false,
                part: ticket.subIssue?.issueIdentifier
            )
        }
        snapshot.gateAgreement = gateAgreement(data)
        return .state(snapshot)
    }

    /// `acceptance_gate.agreement`, read without `convertFromSnakeCase`, which would rewrite repository keys such
    /// as `my_repo` into `myRepo`. Nil when the state has none.
    private static func gateAgreement(_ data: Data) -> [String: StateSnapshot.GateAgreement]? {
        guard let payload = try? JSONDecoder().decode(GatePayload.self, from: data),
              let agreement = payload.acceptanceGate?.agreement else { return nil }
        return agreement.mapValues { stats in
            StateSnapshot.GateAgreement(
                judged: stats.judged ?? 0,
                agreed: stats.agreed ?? 0,
                agreementRate: stats.agreementRate,
                unsafeApprovals: stats.unsafeApprovals ?? 0,
                falseReworks: stats.falseReworks ?? 0,
                escalations: stats.escalations ?? 0,
                readyToEnforce: stats.readyToEnforce ?? false,
                unmetCondition: stats.unmetCondition
            )
        }
    }

    private struct GatePayload: Decodable {
        struct Gate: Decodable {
            let agreement: [String: Stats]?
        }

        struct Stats: Decodable {
            let judged: Int?
            let agreed: Int?
            let agreementRate: Double?
            let unsafeApprovals: Int?
            let falseReworks: Int?
            let escalations: Int?
            let readyToEnforce: Bool?
            let unmetCondition: String?

            enum CodingKeys: String, CodingKey {
                case judged, agreed, escalations
                case agreementRate = "agreement_rate"
                case unsafeApprovals = "unsafe_approvals"
                case falseReworks = "false_reworks"
                case readyToEnforce = "ready_to_enforce"
                case unmetCondition = "unmet_condition"
            }
        }

        let acceptanceGate: Gate?

        enum CodingKeys: String, CodingKey {
            case acceptanceGate = "acceptance_gate"
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Symphony writes whole-second UTC timestamps, for example `2026-10-02T12:16:02Z`.
    private static func parseDate(_ text: String) -> Date? {
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
            /// Missing before Symphony had a Human Review state.
            let humanReview: Int?
        }

        struct Pause: Decodable {
            let paused: Bool
            let reason: String?
            let pausedAt: String?
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
        }

        struct Budget: Decodable {
            let dailyLimit: Int?
            let dailyUsed: Int?
            let dailyRemaining: Int?
            let dailyPaused: Bool?
            let perIssueLimit: Int?
        }

        struct AppUpdate: Decodable {
            let unblocks: Int?
        }

        struct Forced: Decodable {
            struct Part: Decodable {
                let issueIdentifier: String?
            }

            let issueId: String?
            let issueIdentifier: String?
            let summary: String?
            let state: String?
            let forcedForSeconds: Int?
            let stale: Bool?
            let subIssue: Part?
        }

        let counts: Counts?
        let pause: Pause?
        let budget: Budget?
        let usageLimits: [UsageLimit]?
        let appUpdate: AppUpdate?
        /// Missing before Symphony reported forced tickets.
        let forced: [Forced]?
        let error: Failure?
    }
}
