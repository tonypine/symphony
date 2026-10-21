import Foundation

/// Instant GitHub updates as Symphony reports them (`github_updates` in `GET /api/v1/setup`, and under `setup` in
/// `/api/v1/state`; `SymphonyElixir.GitHub.WebhookSetup`): the mode, the relay, the secret's presence, each setup
/// step, each repo's connection and health, the poll intervals and GitHub's request limit.
public struct GitHubUpdatesSection: Equatable {
    public enum Mode: String, Equatable {
        case off
        /// On in `symphony.yml`, but this Mac was never set up (a `symphony.yml` brought from another Mac).
        case needsSetup = "needs_setup"
        case settingUp = "setting_up"
        case on
        /// A relay can't restart or keeps stopping, or GitHub went quiet after a read found a change it never sent.
        case degraded
    }

    public struct Relay: Equatable {
        /// `gh_webhook_forward`, `smee`, `cloudflare_tunnel` or `tailscale_funnel`.
        public var kind: String
        /// "GitHub CLI forwarding".
        public var label: String
        /// True for `gh_webhook_forward`, which Symphony runs and can restart.
        public var runsInSymphony: Bool
        /// A URL relay's public URL.
        public var url: String?
        /// Where GitHub sends deliveries: the public URL with Symphony's webhook path.
        public var payloadURL: String?
        /// Where the relay forwards them on this Mac.
        public var localURL: String?

        public init(kind: String, label: String, runsInSymphony: Bool, url: String? = nil, payloadURL: String? = nil, localURL: String? = nil) {
            self.kind = kind
            self.label = label
            self.runsInSymphony = runsInSymphony
            self.url = url
            self.payloadURL = payloadURL
            self.localURL = localURL
        }
    }

    public struct Secret: Equatable {
        public var present: Bool
        /// The app's secret item that keeps it: `symphony-github-webhook`.
        public var item: String?

        public init(present: Bool, item: String? = nil) {
            self.present = present
            self.item = item
        }
    }

    public struct Step: Equatable, Identifiable {
        public enum Status: String, Equatable {
            case done, failed, waiting, pending
        }

        /// `relay`, `gh_ready`, `secret`, `port`, `repo:<key>`, `test:<key>`.
        public var id: String
        public var kind: String
        public var repo: String?
        public var title: String
        public var status: Status
        /// What is wrong, or what it went through, in plain words.
        public var detail: String?
        /// What fixes a failed step.
        public var fix: String?

        public init(id: String, kind: String, repo: String? = nil, title: String, status: Status, detail: String? = nil, fix: String? = nil) {
            self.id = id
            self.kind = kind
            self.repo = repo
            self.title = title
            self.status = status
            self.detail = detail
            self.fix = fix
        }
    }

    public struct Repo: Equatable, Identifiable {
        public var key: String
        /// `owner/name`, nil for a repo with no GitHub remote.
        public var github: String?
        /// True when GitHub's updates reach Symphony through the relay; false while it polls only.
        public var connected: Bool
        public var lastDeliveryAt: Date?
        public var signatureFailures24h: Int
        public var degraded: Bool
        public var degradedReason: String?
        /// How often its watcher reads GitHub now.
        public var pollIntervalMs: Int?
        /// The relay Symphony runs for it: `running` or `restarting`; nil for a URL relay.
        public var relayState: String?
        /// False while the relay stopped more than twice in ten minutes.
        public var relayStable: Bool

        public var id: String { key }
        public var name: String { github ?? key }

        public init(
            key: String, github: String? = nil, connected: Bool, lastDeliveryAt: Date? = nil, signatureFailures24h: Int = 0,
            degraded: Bool = false, degradedReason: String? = nil, pollIntervalMs: Int? = nil, relayState: String? = nil,
            relayStable: Bool = true
        ) {
            self.key = key
            self.github = github
            self.connected = connected
            self.lastDeliveryAt = lastDeliveryAt
            self.signatureFailures24h = signatureFailures24h
            self.degraded = degraded
            self.degradedReason = degradedReason
            self.pollIntervalMs = pollIntervalMs
            self.relayState = relayState
            self.relayStable = relayStable
        }

        /// The relay Symphony runs for it is down: restarting, or stopping again and again.
        public var relayDown: Bool { relayState.map { $0 != "running" } == true || !relayStable }
    }

    public struct Poll: Equatable {
        /// `pull_requests.poll_interval_ms`: the poll while GitHub's updates don't arrive.
        public var intervalMs: Int
        /// `github.webhooks.fallback_poll_interval_ms`: the safety-net poll while they do.
        public var fallbackIntervalMs: Int
        /// `github.webhooks.silence_alert_minutes`.
        public var silenceAlertMinutes: Int

        public init(intervalMs: Int = 30_000, fallbackIntervalMs: Int = GitHubUpdates.defaultFallbackPollMs, silenceAlertMinutes: Int = GitHubUpdates.defaultSilenceAlertMinutes) {
            self.intervalMs = intervalMs
            self.fallbackIntervalMs = fallbackIntervalMs
            self.silenceAlertMinutes = silenceAlertMinutes
        }
    }

    /// GitHub's request limit, as the watcher last read it.
    public struct RateLimit: Equatable {
        public var limit: Int?
        public var remaining: Int
        public var resetAt: Date?

        public init(limit: Int? = nil, remaining: Int, resetAt: Date? = nil) {
            self.limit = limit
            self.remaining = remaining
            self.resetAt = resetAt
        }
    }

    public var mode: Mode
    public var enabled: Bool
    public var relay: Relay
    public var secret: Secret
    public var events: [String]
    public var steps: [Step]
    public var repos: [Repo]
    public var poll: Poll
    public var rateLimit: RateLimit?

    public init(
        mode: Mode, enabled: Bool? = nil, relay: Relay = Relay(kind: "gh_webhook_forward", label: "GitHub CLI forwarding", runsInSymphony: true),
        secret: Secret = Secret(present: false), events: [String] = [], steps: [Step] = [], repos: [Repo] = [], poll: Poll = Poll(),
        rateLimit: RateLimit? = nil
    ) {
        self.mode = mode
        self.enabled = enabled ?? (mode != .off)
        self.relay = relay
        self.secret = secret
        self.events = events
        self.steps = steps
        self.repos = repos
        self.poll = poll
        self.rateLimit = rateLimit
    }

    /// The repos GitHub's updates reach through the relay.
    public var connected: [Repo] { repos.filter(\.connected) }

    /// The step named `id`, such as `repo:web-shop`.
    public func step(_ id: String) -> Step? { steps.first { $0.id == id } }

    // MARK: Decoding

    /// The section of a `GET /api/v1/setup` payload, or of an action's answer (`{"github_updates": …}`); nil when there
    /// is none.
    public static func decode(_ data: Data) -> GitHubUpdatesSection? {
        struct Payload: Decodable {
            let github_updates: Wire?
        }
        return (try? JSONDecoder().decode(Payload.self, from: data))?.github_updates.flatMap(GitHubUpdatesSection.init(wire:))
    }

    /// The section under `setup` in a `/api/v1/state` payload; nil from a Symphony that predates it, or when it
    /// couldn't read it.
    public static func decode(state data: Data) -> GitHubUpdatesSection? {
        struct State: Decodable {
            struct Setup: Decodable {
                let github_updates: Wire?
            }

            let setup: Setup?
        }
        return (try? JSONDecoder().decode(State.self, from: data))?.setup?.github_updates.flatMap(GitHubUpdatesSection.init(wire:))
    }

    init?(wire: Wire) {
        guard let mode = wire.mode.flatMap(Mode.init(rawValue:)) else { return nil }
        self.mode = mode
        enabled = wire.enabled ?? (mode != .off)
        let kind = wire.relay?.kind ?? "gh_webhook_forward"
        relay = Relay(
            kind: kind,
            label: wire.relay?.label ?? GitHubUpdatesSheet.relayLabel(kind),
            runsInSymphony: wire.relay?.runs_in_symphony ?? (kind == "gh_webhook_forward"),
            url: wire.relay?.url,
            payloadURL: wire.relay?.payload_url,
            localURL: wire.relay?.local_url
        )
        secret = Secret(present: wire.secret?.present ?? false, item: wire.secret?.item)
        events = wire.events ?? []
        steps = (wire.steps ?? []).compactMap { step in
            guard let id = step.id else { return nil }
            return Step(
                id: id, kind: step.kind ?? id, repo: step.repo, title: step.title ?? id,
                status: step.status.flatMap(Step.Status.init(rawValue:)) ?? .pending, detail: step.detail, fix: step.fix
            )
        }
        repos = (wire.repos ?? []).compactMap { repo in
            guard let key = repo.key else { return nil }
            return Repo(
                key: key, github: repo.github, connected: repo.connection == "webhook",
                lastDeliveryAt: repo.last_delivery_at.flatMap(SymphonyState.parseDate),
                signatureFailures24h: repo.signature_failures_24h ?? 0, degraded: repo.degraded ?? false,
                degradedReason: repo.degraded_reason, pollIntervalMs: repo.poll_interval_ms, relayState: repo.relay?.state,
                relayStable: repo.relay?.stable ?? true
            )
        }
        poll = Poll(
            intervalMs: wire.poll?.interval_ms ?? 30_000,
            fallbackIntervalMs: wire.poll?.fallback_interval_ms ?? GitHubUpdates.defaultFallbackPollMs,
            silenceAlertMinutes: wire.poll?.silence_alert_minutes ?? GitHubUpdates.defaultSilenceAlertMinutes
        )
        rateLimit = wire.rate_limit.flatMap { limit in
            limit.remaining.map { RateLimit(limit: limit.limit, remaining: $0, resetAt: limit.reset_at.flatMap(SymphonyState.parseDate)) }
        }
    }

    /// The section as Symphony sends it, its keys as they are. Every field is optional, so one missing never fails the
    /// rest of the payload.
    struct Wire: Decodable {
        struct Relay: Decodable {
            let kind: String?
            let label: String?
            let runs_in_symphony: Bool?
            let url: String?
            let payload_url: String?
            let local_url: String?
        }

        struct Secret: Decodable {
            let present: Bool?
            let item: String?
        }

        struct Step: Decodable {
            let id: String?
            let kind: String?
            let repo: String?
            let title: String?
            let status: String?
            let detail: String?
            let fix: String?
        }

        struct RepoRelay: Decodable {
            let state: String?
            let stable: Bool?
        }

        struct Repo: Decodable {
            let key: String?
            let github: String?
            let connection: String?
            let last_delivery_at: String?
            let signature_failures_24h: Int?
            let degraded: Bool?
            let degraded_reason: String?
            let poll_interval_ms: Int?
            let relay: RepoRelay?
        }

        struct Poll: Decodable {
            let interval_ms: Int?
            let fallback_interval_ms: Int?
            let silence_alert_minutes: Int?
        }

        struct Limit: Decodable {
            let limit: Int?
            let remaining: Int?
            let reset_at: String?
        }

        let mode: String?
        let enabled: Bool?
        let relay: Relay?
        let secret: Secret?
        let events: [String]?
        let steps: [Step]?
        let repos: [Repo]?
        let poll: Poll?
        let rate_limit: Limit?
    }
}

/// What an action answered, and the state poll's section when it did. The answer stands until the state poll reports
/// something new, so the card never flips back to what it showed before the action while Symphony catches up.
public struct GitHubUpdatesAnswer: Equatable {
    public var section: GitHubUpdatesSection
    /// The state poll's section when the answer came.
    public var baseline: GitHubUpdatesSection?

    public init(section: GitHubUpdatesSection, baseline: GitHubUpdatesSection?) {
        self.section = section
        self.baseline = baseline
    }

    /// The section to show: the answer while the state poll still reports what it did when the answer came, else the
    /// state poll's.
    public static func shown(state: GitHubUpdatesSection?, answer: GitHubUpdatesAnswer?) -> GitHubUpdatesSection? {
        guard let answer, answer.baseline == state else { return state }
        return answer.section
    }
}

/// `POST /api/v1/setup/github_updates/<action>`: turn instant updates on or off, restart the relay, re-create the
/// secret, change the relay. Symphony answers with the section as the action leaves it. It needs no control token:
/// Symphony takes it from a client that sends no `Origin` header, as the app doesn't.
public enum GitHubUpdatesAPI {
    public enum Action: String, Equatable {
        case turnOn = "turn_on"
        case restartRelay = "restart_relay"
        case recreateSecret = "recreate_secret"
        case changeRelay = "change_relay"
        case turnOff = "turn_off"

        /// The start of the message when it fails.
        var failurePrefix: String {
            switch self {
            case .turnOn: "Couldn't turn on instant updates"
            case .restartRelay: "Couldn't restart the relay"
            case .recreateSecret: "Couldn't re-create the webhook secret"
            case .changeRelay: "Couldn't change the relay"
            case .turnOff: "Couldn't turn off instant updates"
            }
        }
    }

    public enum Result: Equatable {
        /// The section as the action left it.
        case updated(GitHubUpdatesSection)
        /// What went wrong, in plain words.
        case failed(String)
    }

    /// Turning on and changing the relay check every step, which asks `gh`.
    public static let timeout: TimeInterval = 60

    public static func path(_ action: Action) -> String { "api/v1/setup/github_updates/\(action.rawValue)" }

    /// The request for `action` with its `params` (`relay`, `url`) against Symphony at `base`.
    public static func request(_ action: Action, params: [String: String] = [:], base: URL) -> URLRequest {
        var request = URLRequest(url: LiveAPIClient.url(path(action), base: base) ?? base, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A map of strings always encodes.
        request.httpBody = try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])
        return request
    }

    /// Sends `action` to the control URL in `stateRoot` (or `fallback` while Symphony hasn't written one).
    public static func send(
        _ action: Action,
        params: [String: String] = [:],
        stateRoot: URL,
        fallback: URL? = SymphonyState.defaultBaseURL,
        transport: ControlAPI.Transport = { try await URLSession.shared.data(for: $0) }
    ) async -> Result {
        guard let base = StateRoot.controlURL(in: stateRoot, fallback: fallback) else {
            return .failed("\(action.failurePrefix): Symphony hasn't said where it listens.")
        }
        guard let (data, response) = try? await transport(request(action, params: params, base: base)) else {
            return .failed("\(action.failurePrefix): nothing answered at \(base.absoluteString).")
        }
        return result(action, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }

    /// Symphony's answer: the section, or the reason it names.
    public static func result(_ action: Action, statusCode: Int, data: Data) -> Result {
        struct Failure: Decodable {
            struct Error: Decodable {
                let message: String?
            }

            let error: Error?
        }
        if statusCode == 200, let section = GitHubUpdatesSection.decode(data) {
            return .updated(section)
        }
        if let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error?.message?.trimmingWhitespace(), !message.isEmpty {
            return .failed("\(action.failurePrefix): \(message)")
        }
        switch statusCode {
        case 200: return .failed("\(action.failurePrefix): Symphony's answer couldn't be read.")
        case 404: return .failed("\(action.failurePrefix): this Symphony predates instant updates. Update it.")
        default: return .failed("\(action.failurePrefix): Symphony answered with HTTP \(statusCode).")
        }
    }
}
