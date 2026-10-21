import Foundation

/// The GitHub updates card on the Setup page (S1, S7, S8, S10, S14, S18): what reaches Symphony from GitHub now, in a
/// symbol and a word, a sentence, each repo with its last update, the card's buttons, and Details (relay, secret, the
/// two intervals, events, address).
public struct GitHubUpdatesCard: Equatable {
    public enum State: Equatable {
        /// S1: instant updates off; Symphony polls.
        case off
        /// S14: on in `symphony.yml`, never set up on this Mac.
        case needsSetup
        /// Turned on, with steps still to do.
        case settingUp
        /// S7: GitHub's updates arrive at once.
        case on
        /// S8: on, but Symphony polls while the relay is down or GitHub went quiet.
        case degraded
        /// S10: on, but deliveries fail the secret check, or there is no secret.
        case secretFailing
    }

    /// How the card's state reads: a symbol, its tint and a word, never the color alone.
    public enum Tone: Equatable {
        case done, idle, working, warning, problem

        public var symbol: String {
            switch self {
            case .done: DesignTokens.Status.done.symbol
            case .idle: "clock.arrow.circlepath"
            case .working: DesignTokens.Status.working.symbol
            case .warning: "exclamationmark.triangle"
            case .problem: DesignTokens.Status.problem.symbol
            }
        }

        public var status: DesignTokens.Status {
            switch self {
            case .done: .done
            case .idle: .idle
            case .working: .working
            case .warning: .you
            case .problem: .problem
            }
        }
    }

    /// A button on the card. One that changes something opens its consequence sheet first, except Restart Relay,
    /// which only starts again what should be running.
    public enum Action: Equatable, Hashable {
        case turnOn
        case finishSetup
        case restartRelay
        case turnOff
        case recreateSecret
        case changeRelay

        public var title: String {
            switch self {
            case .turnOn: "Turn On Instant Updates…"
            case .finishSetup: "Finish Setup…"
            case .restartRelay: "Restart Relay"
            case .turnOff: "Turn Off…"
            case .recreateSecret: "Re-create Secret…"
            case .changeRelay: "Change Relay…"
            }
        }
    }

    public struct RepoRow: Equatable, Identifiable {
        public var id: String
        public var name: String
        public var tone: Tone
        /// "Instant", "Polling", "Polling only".
        public var word: String
        /// "Last update 2 min ago", "No update yet", or why it polls.
        public var detail: String

        /// One element for VoiceOver: "acme/app, Instant, Last update 2 min ago".
        public var accessibilityLabel: String { "\(name), \(word), \(detail)" }
    }

    public struct StepRow: Equatable, Identifiable {
        public var id: String
        public var title: String
        public var tone: Tone
        /// "Done", "Failed", "Waiting", "To do".
        public var word: String
        /// What it went through, or what is wrong and what fixes it.
        public var detail: String?
    }

    /// A line under Details: a label, its value and, for the relay and the secret, its button.
    public struct DetailRow: Equatable, Identifiable {
        public var id: String { label }
        public var label: String
        public var value: String
        public var action: Action?
    }

    /// S18: GitHub's request limit is low or spent.
    public struct RequestsRow: Equatable {
        public var tone: Tone
        public var sentence: String
    }

    public static let title = "GitHub updates"
    /// Below 10% of the limit, the requests row shows.
    public static let lowRequests = 0.10

    public var state: State
    public var tone: Tone
    public var word: String
    public var sentence: String
    public var primary: Action?
    public var secondary: [Action]
    public var repos: [RepoRow]
    /// The setup steps, while setup isn't finished.
    public var steps: [StepRow]
    public var details: [DetailRow]
    /// The safety-net check's interval and the silence alert, in whole minutes, for the two steppers under Details.
    public var safetyNetMinutes: Int
    public var silenceAlertMinutes: Int
    public var requests: RequestsRow?

    /// "GitHub updates, Instant": the card's heading and state for VoiceOver.
    public var accessibilityLabel: String { "\(Self.title), \(word)" }

    /// The card for `section`, its ages counted to `now`.
    public init(section: GitHubUpdatesSection, now: Date, timeZone: TimeZone = .current) {
        let polling = Self.interval(section.poll.intervalMs)
        let safetyNet = Self.interval(section.poll.fallbackIntervalMs)
        let connected = section.connected
        state = Self.state(section)
        steps = []
        repos = []
        secondary = []

        switch state {
        case .off:
            tone = .idle
            word = "Polling only"
            sentence = "Symphony checks GitHub every \(polling), so tickets react to CI and pull requests within a minute. "
                + "Instant updates let GitHub tell Symphony at once."
            primary = .turnOn
        case .needsSetup, .settingUp:
            let done = section.steps.filter { $0.status == .done }.count
            if state == .needsSetup {
                tone = .warning
                word = "Needs setup on this Mac"
                sentence = "symphony.yml turns instant updates on, but they were never set up on this Mac. "
                    + "Symphony checks GitHub every \(polling) until they are."
            } else {
                tone = .working
                word = "Setting up"
                sentence = "\(done) of \(section.steps.count) setup steps done. Symphony checks GitHub every \(polling) until they all are."
            }
            primary = .finishSetup
            secondary = [.turnOff]
            steps = section.steps.map(Self.stepRow)
        case .on:
            tone = .done
            word = "Instant"
            let repos = connected.count == 1 ? "1 repo" : "\(connected.count) repos"
            sentence = "GitHub tells Symphony about CI and pull requests in \(repos) at once, through \(section.relay.label). "
                + "Symphony still checks every \(safetyNet) as a safety net."
            primary = nil
            secondary = [.turnOff]
        case .degraded:
            let relayDown = connected.contains { $0.degraded && $0.relayDown }
            tone = .warning
            word = relayDown ? "Polling while the relay is down" : "Polling while GitHub is quiet"
            let reason = connected.first(where: \.degraded)?.degradedReason.map { " " + Self.sentence($0) } ?? ""
            sentence = "Symphony checks GitHub every \(polling) until instant updates arrive again.\(reason)"
            primary = section.relay.runsInSymphony ? .restartRelay : nil
            secondary = [.turnOff]
        case .secretFailing:
            tone = .problem
            word = "Secret check failing"
            if !section.secret.present {
                sentence = "Symphony has no webhook secret on this Mac, so it refuses GitHub's updates and checks every \(polling) instead."
            } else {
                let failing = connected.filter { $0.signatureFailures24h > 0 && $0.lastDeliveryAt == nil }
                let names = failing.map(\.name).joined(separator: ", ")
                sentence = "Updates from \(names) failed the secret check, so Symphony refuses them and checks GitHub every \(polling) "
                    + "instead. Re-create the secret to connect them again."
            }
            primary = .recreateSecret
            secondary = [.turnOff]
        }

        if [.on, .degraded, .secretFailing].contains(state) {
            repos = section.repos.map { Self.repoRow($0, section: section, now: now) }
        }

        details = [
            DetailRow(label: "Relay", value: section.relay.url.map { "\(section.relay.label), \($0)" } ?? section.relay.label, action: .changeRelay),
            DetailRow(
                label: "Secret",
                value: section.secret.present ? "Saved in your Keychain" + (section.secret.item.map { " as \($0)" } ?? "") : "Not created on this Mac",
                action: .recreateSecret
            ),
            DetailRow(label: "Events", value: section.events.isEmpty ? "None" : section.events.joined(separator: ", "), action: nil),
        ]
        if let address = section.relay.payloadURL ?? section.relay.localURL {
            details.append(DetailRow(label: "Address", value: address, action: nil))
        }
        safetyNetMinutes = GitHubUpdates.minutes(section.poll.fallbackIntervalMs)
        silenceAlertMinutes = GitHubUpdates.stepperMinutes(section.poll.silenceAlertMinutes)
        requests = Self.requestsRow(section, instant: state == .on, now: now, timeZone: timeZone)
    }

    /// Details shows only once the setup ran on this Mac: before, there is nothing to change.
    public var showsDetails: Bool { [.on, .degraded, .secretFailing].contains(state) }

    // MARK: Building

    static func state(_ section: GitHubUpdatesSection) -> State {
        switch section.mode {
        case .off: return .off
        case .needsSetup: return .needsSetup
        case .settingUp: return .settingUp
        case .on, .degraded:
            // A delivery that fails the check while none passed: the secret GitHub signs with isn't Symphony's.
            let refused = section.connected.contains { $0.signatureFailures24h > 0 && $0.lastDeliveryAt == nil }
            if !section.secret.present || refused { return .secretFailing }
            return section.mode == .degraded ? .degraded : .on
        }
    }

    static func repoRow(_ repo: GitHubUpdatesSection.Repo, section: GitHubUpdatesSection, now: Date) -> RepoRow {
        if !repo.connected {
            let step = section.step("repo:\(repo.key)")
            let why = step?.status == .failed ? step?.detail : nil
            return RepoRow(id: repo.key, name: repo.name, tone: .idle, word: "Polling only", detail: why ?? "Not connected to instant updates.")
        }
        if repo.degraded {
            let every = repo.pollIntervalMs.map { "Checked every \(interval($0))" } ?? "Checked by polling"
            return RepoRow(id: repo.key, name: repo.name, tone: .warning, word: "Polling", detail: every + (repo.degradedReason.map { ". " + sentence($0) } ?? "."))
        }
        let last = repo.lastDeliveryAt.map { "Last update " + ago($0, now: now) } ?? "No update yet"
        return RepoRow(id: repo.key, name: repo.name, tone: .done, word: "Instant", detail: last)
    }

    static func stepRow(_ step: GitHubUpdatesSection.Step) -> StepRow {
        let detail = [step.detail, step.fix].compactMap { $0 }.joined(separator: " ")
        let (tone, word): (Tone, String) =
            switch step.status {
            case .done: (.done, "Done")
            case .failed: (.problem, "Failed")
            case .waiting: (.working, "Waiting")
            case .pending: (.idle, "To do")
            }
        return StepRow(id: step.id, title: step.title, tone: tone, word: word, detail: detail.isEmpty ? nil : detail)
    }

    static func requestsRow(_ section: GitHubUpdatesSection, instant: Bool, now: Date, timeZone: TimeZone) -> RequestsRow? {
        guard let limit = section.rateLimit else { return nil }
        let until = limit.resetAt.map { " until \(StatusMenu.clockTime($0, now: now, timeZone: timeZone, dateFormat: "MMM d, HH:mm"))" } ?? ""
        if limit.remaining <= 0 {
            let still = instant ? " Instant updates still arrive." : ""
            return RequestsRow(tone: .problem, sentence: "GitHub requests are used up\(until). Symphony can't read CI or pull requests until then.\(still)")
        }
        guard let total = limit.limit, total > 0, Double(limit.remaining) < Double(total) * lowRequests else { return nil }
        return RequestsRow(tone: .warning, sentence: "GitHub requests are low: \(number(limit.remaining)) of \(number(total)) left\(until).")
    }

    /// "30 s", "5 min".
    public static func interval(_ ms: Int) -> String { Overview.duration(ms / 1_000) }

    /// "2 min ago", "just now".
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        return seconds < 60 ? "just now" : "\(Overview.duration(seconds)) ago"
    }

    /// A reason as a sentence: ending with a full stop.
    static func sentence(_ text: String) -> String {
        let text = text.trimmingWhitespace()
        return text.hasSuffix(".") ? text : text + "."
    }

    static func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: Overview

    /// S9: the Overview's Needs attention row while instant updates are on but don't arrive; nil otherwise.
    public static func attention(_ section: GitHubUpdatesSection?) -> (sentence: String, note: String, restart: Bool)? {
        guard let section else { return nil }
        let polling = interval(section.poll.intervalMs)
        switch state(section) {
        case .degraded:
            let relayDown = section.connected.contains { $0.degraded && $0.relayDown }
            let what = relayDown ? "the relay is down" : "GitHub went quiet"
            return ("Instant GitHub updates stopped: \(what).", "Symphony checks GitHub every \(polling) meanwhile.", section.relay.runsInSymphony)
        case .secretFailing:
            return ("Instant GitHub updates fail the secret check.", "Symphony checks GitHub every \(polling) meanwhile.", false)
        case .off, .needsSetup, .settingUp, .on:
            return nil
        }
    }
}

/// The consequence sheets of the card (P5, C17): S12 Turn Off, S11 Re-create Secret, and the relay sheet behind Turn On
/// Instant Updates…, Finish Setup… and Change Relay…. The title is the question; then what happens, what stays, and
/// Cancel with the verb. Nothing changes until its button is pressed; a failure stays in the sheet with the reason.
public struct GitHubUpdatesSheet: Equatable, Identifiable {
    public enum Kind: Equatable {
        case turnOff
        case recreateSecret
        case turnOn
        case finishSetup
        case changeRelay
    }

    public enum Phase: Equatable {
        case ready
        case working
        case failed(String)
    }

    /// A relay the sheet offers, with what it needs.
    public struct RelayOption: Equatable, Identifiable {
        public var id: String
        public var label: String
        public var note: String
        /// A URL relay needs its public URL.
        public var needsURL: Bool { id != "gh_webhook_forward" }
    }

    /// The relays Symphony can run updates through, the recommended one first (D1).
    public static let relays: [RelayOption] = [
        RelayOption(id: "gh_webhook_forward", label: "GitHub CLI forwarding", note: "Recommended. Symphony runs it with your GitHub CLI; no account to create."),
        RelayOption(id: "smee", label: "smee.io", note: "Free, no account. Anyone with the channel URL can read the updates."),
        RelayOption(id: "cloudflare_tunnel", label: "Cloudflare Tunnel", note: "Needs a Cloudflare account and a domain."),
        RelayOption(id: "tailscale_funnel", label: "Tailscale Funnel", note: "Needs a Tailscale account."),
    ]

    public static func relayLabel(_ kind: String) -> String {
        relays.first { $0.id == kind }?.label ?? kind
    }

    public let kind: Kind
    public var title: String
    public var happens: String
    public var stays: String
    /// The verb on the button.
    public var verb: String
    /// Turn Off is destructive: it removes webhooks.
    public var isDestructive: Bool
    /// The relay picked, for Turn On, Finish Setup and Change Relay.
    public var relay: String
    /// A URL relay's public URL.
    public var url: String
    public var phase: Phase = .ready

    public var id: String {
        switch kind {
        case .turnOff: "turn_off"
        case .recreateSecret: "recreate_secret"
        case .turnOn: "turn_on"
        case .finishSetup: "finish_setup"
        case .changeRelay: "change_relay"
        }
    }

    /// The sheet a card button opens; nil for Restart Relay, which needs none.
    public init?(_ action: GitHubUpdatesCard.Action, section: GitHubUpdatesSection) {
        let polling = GitHubUpdatesCard.interval(section.poll.intervalMs)
        let connected = section.connected.count
        let repos = connected == 1 ? "1 repo" : "\(connected) repos"
        relay = section.relay.kind
        url = section.relay.url ?? ""
        isDestructive = false

        switch action {
        case .restartRelay:
            return nil
        case .turnOff:
            kind = .turnOff
            title = "Turn off instant GitHub updates?"
            let stop = section.relay.runsInSymphony
                ? "Symphony stops forwarding GitHub's updates for \(repos)"
                : "Symphony stops listening through \(section.relay.label) and removes the webhooks it added to \(repos)"
            happens = "\(stop). It goes on checking GitHub every \(polling), so tickets react within a minute instead of seconds."
            stays = "The webhook secret stays in your Keychain, and webhooks you added yourself stay on GitHub. "
                + "Turn On Instant Updates… sets them up again."
            verb = "Turn Off"
            isDestructive = true
        case .recreateSecret:
            kind = .recreateSecret
            title = "Re-create the webhook secret?"
            happens = "Symphony makes a new secret, saves it in your Keychain and connects \(repos) again with it. "
                + "Updates signed with the old secret are refused from then on."
            stays = "Symphony goes on checking GitHub every \(polling) while the repos connect again, so no change is missed."
            verb = "Re-create Secret"
        case .turnOn, .finishSetup:
            kind = action == .turnOn ? .turnOn : .finishSetup
            title = action == .turnOn ? "Turn on instant GitHub updates?" : "Finish setting up instant updates on this Mac?"
            happens = "Symphony turns instant updates on in symphony.yml through the relay you pick, and checks each setup step. "
                + "A step that needs you shows what to do on the card."
            stays = "Symphony goes on checking GitHub every \(polling) until GitHub's updates arrive."
            verb = action == .turnOn ? "Turn On" : "Finish Setup"
        case .changeRelay:
            kind = .changeRelay
            title = "Change how GitHub reaches this Mac?"
            happens = "Symphony switches to the relay you pick. What the old relay connected is removed, and each repo connects again through the new one."
            stays = "Symphony goes on checking GitHub every \(polling) while the repos connect again."
            verb = "Change Relay"
        }
    }

    /// True when the sheet picks a relay.
    public var picksRelay: Bool { [.turnOn, .finishSetup, .changeRelay].contains(kind) }

    public var option: RelayOption? { Self.relays.first { $0.id == relay } }

    public var needsURL: Bool { picksRelay && option?.needsURL == true }

    public var isWorking: Bool { phase == .working }

    public var error: String? {
        if case let .failed(message) = phase { return message }
        return nil
    }

    /// Cancel, or Close once it failed.
    public var cancelTitle: String { error == nil ? "Cancel" : "Close" }

    /// The verb, or Try Again once it failed.
    public var confirmTitle: String { error == nil ? verb : "Try Again" }

    public var canConfirm: Bool {
        guard !isWorking else { return false }
        return !needsURL || !url.trimmingWhitespace().isEmpty
    }

    /// What the button sends.
    public var request: (action: GitHubUpdatesAPI.Action, params: [String: String]) {
        var params: [String: String] = [:]
        if picksRelay {
            params["relay"] = relay
            let url = url.trimmingWhitespace()
            if needsURL, !url.isEmpty { params["url"] = url }
        }
        switch kind {
        case .turnOff: return (.turnOff, params)
        case .recreateSecret: return (.recreateSecret, params)
        case .turnOn, .finishSetup: return (.turnOn, params)
        case .changeRelay: return (.changeRelay, params)
        }
    }

    public mutating func start() { phase = .working }

    public mutating func fail(_ message: String) { phase = .failed(message) }
}
