import Foundation

/// The PR and CI watcher's record of one ticket (`docs/pr-ci-decisions.md`), as `GET /api/v1/state` lists it under
/// `issues`, and as `GET /api/v1/:issue_identifier` and Check Now carry it under `watch`: the decision on the ticket's
/// pull request, the facts it was read from, the last actions applied, the ticket's silence and what it waits on.
/// Every field is optional, so a Symphony that leaves one out never fails the whole block.
public struct WatchBlock: Equatable {
    /// The facts the decision was read from, as the app shows them.
    public struct Facts: Equatable {
        /// `missing`, `open`, `draft`, `closed` or `merged`.
        public var pr: String?
        public var prNumber: Int?
        /// `pending`, `green`, `none`, `red` or `required_missing`.
        public var ci: String?
        /// `not_configured` or `not_reported`: why a head reads as having no CI.
        public var noCI: String?
        /// `failure`, `cancelled`, `human_only` or `also_red_on_base`.
        public var redKind: String?
        public var failingCheck: String?
        public var missingChecks: [String]
        /// `clean`, `behind`, `dirty`, `unstable`, `blocked` or `unknown`.
        public var mergeable: String?
        /// `off` or `armed`.
        public var autoMerge: String?
        /// `none` or `active`.
        public var run: String?
        /// `none`, `needs_decision` or `blocked`.
        public var hold: String?
        /// `ok` or `rate_limited`.
        public var github: String?
        public var githubResetAt: Date?
        /// `symphony` or `person`: who pushed the head.
        public var headOrigin: String?
        /// The base the PR merges into when it is not the repo's base branch.
        public var baseRef: String?
        public var redAttempts: Int?
        public var maxRedAttempts: Int?
        public var conflictAttempts: Int?
        public var sameFailureStreak: Int?
        /// Each CI Fix run's failure, oldest first.
        public var fixFailures: [Failure]
        /// The protected files the PR changes, when Symphony lists them (R18's evidence).
        public var protectedFiles: [String]

        public init(
            pr: String? = nil, prNumber: Int? = nil, ci: String? = nil, noCI: String? = nil, redKind: String? = nil,
            failingCheck: String? = nil, missingChecks: [String] = [], mergeable: String? = nil, autoMerge: String? = nil,
            run: String? = nil, hold: String? = nil, github: String? = nil, githubResetAt: Date? = nil,
            headOrigin: String? = nil, baseRef: String? = nil, redAttempts: Int? = nil, maxRedAttempts: Int? = nil,
            conflictAttempts: Int? = nil, sameFailureStreak: Int? = nil, fixFailures: [Failure] = [], protectedFiles: [String] = []
        ) {
            self.pr = pr
            self.prNumber = prNumber
            self.ci = ci
            self.noCI = noCI
            self.redKind = redKind
            self.failingCheck = failingCheck
            self.missingChecks = missingChecks
            self.mergeable = mergeable
            self.autoMerge = autoMerge
            self.run = run
            self.hold = hold
            self.github = github
            self.githubResetAt = githubResetAt
            self.headOrigin = headOrigin
            self.baseRef = baseRef
            self.redAttempts = redAttempts
            self.maxRedAttempts = maxRedAttempts
            self.conflictAttempts = conflictAttempts
            self.sameFailureStreak = sameFailureStreak
            self.fixFailures = fixFailures
            self.protectedFiles = protectedFiles
        }
    }

    /// A CI Fix run's failure: the check, the first line of its error, the head it failed on.
    public struct Failure: Equatable {
        public var check: String?
        public var error: String?
        public var head: String?

        public init(check: String? = nil, error: String? = nil, head: String? = nil) {
            self.check = check
            self.error = error
            self.head = head
        }
    }

    /// An action the watcher applied: its rule, what it did, on which head, when, and how its facts arrived.
    public struct Action: Equatable {
        public var rule: String?
        public var action: String?
        public var head: String?
        public var at: Date?
        /// `poll` or `webhook`.
        public var source: String?

        public init(rule: String? = nil, action: String? = nil, head: String? = nil, at: Date? = nil, source: String? = nil) {
            self.rule = rule
            self.action = action
            self.head = head
            self.at = at
            self.source = source
        }
    }

    /// A ticket that waits with nothing under way and no reason anybody can act on.
    public struct Silent: Equatable {
        public var since: Date?
        public var ticks: Int?
        /// The bound that passed (`ci.merging_wait_timeout_ms`, `rate_limit_reset`), nil when it is only quiet.
        public var bound: String?
        public var reason: String?

        public init(since: Date? = nil, ticks: Int? = nil, bound: String? = nil, reason: String? = nil) {
            self.since = since
            self.ticks = ticks
            self.bound = bound
            self.reason = reason
        }
    }

    /// What the ticket waits on (D14, D15): a competing pull request, or the fix ticket of the red backstop.
    public struct Wait: Equatable {
        public enum Kind: Equatable {
            case competitor, fixTicket, other(String)

            init(_ name: String?) {
                switch name {
                case "competitor": self = .competitor
                case "fix_ticket": self = .fixTicket
                default: self = .other(name ?? "")
                }
            }
        }

        /// The competitor's ticket ("TP-1"), "PR #12" for a person's PR, or the fix ticket.
        public var identifier: String
        public var kind: Kind
        public var prURL: URL?
        /// The files it shares with the ticket's PR.
        public var files: [String]

        public init(identifier: String, kind: Kind, prURL: URL? = nil, files: [String] = []) {
            self.identifier = identifier
            self.kind = kind
            self.prURL = prURL
            self.files = files
        }

        /// A ticket the app can open, rather than a person's pull request.
        public var isTicket: Bool { !identifier.hasPrefix("PR #") }
    }

    public var phase: String?
    public var head: String?
    public var prURL: URL?
    /// `poll` or `webhook`: how the facts arrived.
    public var source: String?
    public var readAt: Date?
    public var rule: String?
    public var action: String?
    public var reason: String?
    /// Who acts next: `agent`, `ci`, `github`, `person` or `symphony`.
    public var owner: String?
    public var clearsWhen: String?
    public var since: Date?
    public var outcome: String?
    public var summary: String?
    public var facts: Facts
    /// The last five actions applied, as served.
    public var actions: [Action]
    public var silent: Silent?
    public var waitsOn: [Wait]
    /// The check a fix-ticket wait is for (the decision's `args.check`).
    public var decisionCheck: String?

    public init(
        phase: String? = nil, head: String? = nil, prURL: URL? = nil, source: String? = nil, readAt: Date? = nil,
        rule: String? = nil, action: String? = nil, reason: String? = nil, owner: String? = nil, clearsWhen: String? = nil,
        since: Date? = nil, outcome: String? = nil, summary: String? = nil, facts: Facts = Facts(), actions: [Action] = [],
        silent: Silent? = nil, waitsOn: [Wait] = [], decisionCheck: String? = nil
    ) {
        self.phase = phase
        self.head = head
        self.prURL = prURL
        self.source = source
        self.readAt = readAt
        self.rule = rule
        self.action = action
        self.reason = reason
        self.owner = owner
        self.clearsWhen = clearsWhen
        self.since = since
        self.outcome = outcome
        self.summary = summary
        self.facts = facts
        self.actions = actions
        self.silent = silent
        self.waitsOn = waitsOn
        self.decisionCheck = decisionCheck
    }

    /// A bare watch block, such as `test/fixtures/api/watch_block.json`; nil when it isn't one.
    public static func decode(_ data: Data) -> WatchBlock? {
        (try? decoder.decode(Payload.self, from: data)).map(WatchBlock.init)
    }

    /// The `watch` of a payload that carries one: `/api/v1/:issue_identifier`, or Check Now's answer.
    public static func decode(carriedIn data: Data) -> WatchBlock? {
        struct Carrier: Decodable {
            let watch: Payload?
        }
        return (try? decoder.decode(Carrier.self, from: data))?.watch.map(WatchBlock.init)
    }

    /// The newest of `blocks` by when their facts were read; the first one when none says.
    public static func newest(_ blocks: [WatchBlock?]) -> WatchBlock? {
        blocks.compactMap { $0 }.enumerated().max { lhs, rhs in
            let left = lhs.element.readAt ?? .distantPast, right = rhs.element.readAt ?? .distantPast
            return left == right ? lhs.offset > rhs.offset : left < right
        }?.element
    }

    /// The rule the ticket's open question came from: the decision on it, or the last decision applied while a
    /// Needs Decision hold now keeps it (R4).
    public var decisionRule: String? {
        if action == "decision" { return rule }
        return latestActions.first { $0.action == "decision" }?.rule
    }

    /// The actions applied, newest first.
    public var latestActions: [Action] {
        actions.enumerated().sorted { lhs, rhs in
            let left = lhs.element.at ?? .distantPast, right = rhs.element.at ?? .distantPast
            return left == right ? lhs.offset > rhs.offset : left > right
        }.map(\.element)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    fileprivate init(_ payload: Payload) {
        let facts = payload.facts
        let date = { (text: String?) in text.flatMap(SymphonyState.parseDate) }
        self.init(
            phase: payload.phase,
            head: payload.head,
            prURL: (payload.prUrl ?? facts?.prUrl).flatMap(URL.init(string:)),
            source: payload.source,
            readAt: date(payload.readAt),
            rule: payload.rule,
            action: payload.action,
            reason: payload.reason,
            owner: payload.owner,
            clearsWhen: payload.clearsWhen,
            since: date(payload.since),
            outcome: payload.outcome,
            summary: payload.summary,
            facts: Facts(
                pr: facts?.pr, prNumber: facts?.prNumber, ci: facts?.ci, noCI: facts?.noCi, redKind: facts?.redKind,
                failingCheck: facts?.failingCheck, missingChecks: facts?.missingChecks ?? [], mergeable: facts?.mergeable,
                autoMerge: facts?.autoMerge, run: facts?.run, hold: facts?.hold, github: facts?.github,
                githubResetAt: date(facts?.githubResetAt), headOrigin: facts?.headOrigin, baseRef: facts?.baseRef,
                redAttempts: facts?.redAttempts, maxRedAttempts: facts?.maxRedAttempts,
                conflictAttempts: facts?.conflictAttempts, sameFailureStreak: facts?.sameFailureStreak,
                fixFailures: (facts?.fixFailures ?? []).map { Failure(check: $0.check, error: $0.error, head: $0.headSha) },
                protectedFiles: facts?.protectedFiles ?? []
            ),
            actions: (payload.actions ?? []).map {
                Action(rule: $0.rule, action: $0.action, head: $0.head, at: date($0.at), source: $0.source)
            },
            silent: payload.silent.map { Silent(since: date($0.since), ticks: $0.ticks, bound: $0.bound, reason: $0.reason) },
            waitsOn: (payload.waitsOn ?? []).compactMap { wait in
                guard let identifier = wait.identifier, !identifier.isEmpty else { return nil }
                return Wait(identifier: identifier, kind: Wait.Kind(wait.kind), prURL: wait.prUrl.flatMap(URL.init(string:)), files: wait.files ?? [])
            },
            decisionCheck: payload.decision?.args?.check
        )
    }

    struct Payload: Decodable {
        struct Facts: Decodable {
            struct Failure: Decodable {
                let check: String?
                let error: String?
                let headSha: String?
            }

            let pr: String?
            let prNumber: Int?
            let prUrl: String?
            let ci: String?
            let noCi: String?
            let redKind: String?
            let failingCheck: String?
            let missingChecks: [String]?
            let mergeable: String?
            let autoMerge: String?
            let run: String?
            let hold: String?
            let github: String?
            let githubResetAt: String?
            let headOrigin: String?
            let baseRef: String?
            let redAttempts: Int?
            let maxRedAttempts: Int?
            let conflictAttempts: Int?
            let sameFailureStreak: Int?
            let fixFailures: [Failure]?
            let protectedFiles: [String]?
        }

        struct Action: Decodable {
            let rule: String?
            let action: String?
            let head: String?
            let at: String?
            let source: String?
        }

        struct Silent: Decodable {
            let since: String?
            let ticks: Int?
            let bound: String?
            let reason: String?
        }

        struct Wait: Decodable {
            let identifier: String?
            let kind: String?
            let prUrl: String?
            let files: [String]?
        }

        struct Decision: Decodable {
            struct Args: Decodable {
                let check: String?
            }

            let args: Args?
        }

        let phase: String?
        let head: String?
        let prUrl: String?
        let source: String?
        let readAt: String?
        let rule: String?
        let action: String?
        let reason: String?
        let owner: String?
        let clearsWhen: String?
        let since: String?
        let outcome: String?
        let summary: String?
        let facts: Facts?
        let actions: [Action]?
        let silent: Silent?
        let waitsOn: [Wait]?
        let decision: Decision?
    }
}

/// What `GET /api/v1/state` says about the PR and CI watcher: each watched ticket's block by identifier, the tickets
/// that wait silently, and GitHub's rate limit as the newest read left it.
public struct WatchState: Equatable {
    /// A ticket that waits with nothing under way and no reason anybody can act on (`silent_waits`).
    public struct SilentWait: Equatable {
        public var issueID: String?
        public var identifier: String
        public var repoKey: String?
        /// `rework`, `code_review`, …
        public var phase: String?
        public var prURL: URL?
        public var since: Date?
        public var rule: String?
        public var bound: String?
        public var reason: String?

        public init(
            issueID: String? = nil, identifier: String, repoKey: String? = nil, phase: String? = nil, prURL: URL? = nil,
            since: Date? = nil, rule: String? = nil, bound: String? = nil, reason: String? = nil
        ) {
            self.issueID = issueID
            self.identifier = identifier
            self.repoKey = repoKey
            self.phase = phase
            self.prURL = prURL
            self.since = since
            self.rule = rule
            self.bound = bound
            self.reason = reason
        }
    }

    /// GitHub's rate limit: requests left of the limit, and when it resets.
    public struct RateLimit: Equatable {
        public var remaining: Int?
        public var limit: Int?
        public var reset: Date?

        public init(remaining: Int? = nil, limit: Int? = nil, reset: Date? = nil) {
            self.remaining = remaining
            self.limit = limit
            self.reset = reset
        }
    }

    /// Each watched ticket's block, by identifier.
    public var watches: [String: WatchBlock]
    public var silentWaits: [SilentWait]
    public var rateLimit: RateLimit?

    public init(watches: [String: WatchBlock] = [:], silentWaits: [SilentWait] = [], rateLimit: RateLimit? = nil) {
        self.watches = watches
        self.silentWaits = silentWaits
        self.rateLimit = rateLimit
    }

    /// The watcher's part of a state payload; empty when the payload has none (a Symphony that predates it).
    public static func decode(_ data: Data) -> WatchState {
        guard let payload = try? WatchBlock.decoder.decode(Payload.self, from: data) else { return WatchState() }
        var watches: [String: WatchBlock] = [:]
        for issue in payload.issues ?? [] {
            guard let identifier = issue.identifier ?? issue.issueId, let watch = issue.watch else { continue }
            watches[identifier] = WatchBlock.newest([watches[identifier], WatchBlock(watch)])
        }
        let date = { (text: String?) in text.flatMap(SymphonyState.parseDate) }
        return WatchState(
            watches: watches,
            silentWaits: (payload.silentWaits ?? []).compactMap { entry in
                guard let identifier = entry.identifier ?? entry.issueId else { return nil }
                return SilentWait(
                    issueID: entry.issueId, identifier: identifier, repoKey: entry.repoKey, phase: entry.phase,
                    prURL: entry.prUrl.flatMap(URL.init(string:)), since: date(entry.since), rule: entry.rule,
                    bound: entry.bound, reason: entry.reason
                )
            },
            rateLimit: payload.rateLimit.map { RateLimit(remaining: $0.remaining, limit: $0.limit, reset: date($0.reset)) }
        )
    }

    private struct Payload: Decodable {
        struct Issue: Decodable {
            let issueId: String?
            let identifier: String?
            let watch: WatchBlock.Payload?
        }

        struct Silent: Decodable {
            let issueId: String?
            let identifier: String?
            let repoKey: String?
            let phase: String?
            let prUrl: String?
            let since: String?
            let rule: String?
            let bound: String?
            let reason: String?
        }

        struct Limit: Decodable {
            let remaining: Int?
            let limit: Int?
            let reset: String?
        }

        let issues: [Issue]?
        let silentWaits: [Silent]?
        let rateLimit: Limit?
    }
}

extension WatchBlock {
    /// The Linear state's name for a watcher phase: `code_review` → "Code Review".
    public static func phaseName(_ phase: String?) -> String? {
        switch phase {
        case nil, "": nil
        case "in_progress": "In Progress"
        case "code_review": "Code Review"
        case "qa": "QA"
        case "ci_fix": "CI Fix"
        case let other?: Overview.phaseName(other).split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }
}
