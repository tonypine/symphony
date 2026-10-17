import Foundation

/// S15: the ticket page's **PR and CI** card, from the watcher's block on the ticket (`WatchBlock`). It says in one
/// line why the ticket waits or what the watcher did, who acts next, what clears it and since when; the facts in a
/// table, the fix attempts as "Checks n of max · conflict n of 3"; the last five actions; and its buttons. Rule ids
/// stay in the help tags. Nil when the watcher doesn't watch the ticket.
public struct PRWatchCard: Equatable {
    public static let title = "PR and CI"
    public static let checkNowTitle = "Check Now"
    public static let openPRTitle = "Open PR"
    public static let openInInboxTitle = "Open in Inbox"
    /// A conflict gets this many fix runs (`docs/pr-ci-decisions.md`, fixed in Symphony).
    public static let maxConflictAttempts = 3
    /// How many of the watcher's actions the card lists.
    public static let actionLimit = 5

    /// A button at the foot of the card.
    public enum Button: Equatable, Hashable {
        /// `POST /api/v1/issues/<identifier>/watch/check`: the watcher reads and decides at once.
        case checkNow
        case openPR(URL)
        /// The ticket's decision in the Inbox.
        case openInInbox
        /// A competing ticket, or the fix ticket the ticket waits on.
        case openTicket(String)
        /// A person's competing pull request: "Open PR #12".
        case openPullRequest(String, URL)

        public var title: String {
            switch self {
            case .checkNow: PRWatchCard.checkNowTitle
            case .openPR: PRWatchCard.openPRTitle
            case .openInInbox: PRWatchCard.openInInboxTitle
            case let .openTicket(identifier): "Open \(identifier)"
            case let .openPullRequest(name, _): "Open \(name)"
            }
        }
    }

    /// A row of the facts table.
    public struct Fact: Equatable {
        public var label: String
        public var value: String
        public var url: URL?
        public var help: String?

        public init(label: String, value: String, url: URL? = nil, help: String? = nil) {
            self.label = label
            self.value = value
            self.url = url
            self.help = help
        }
    }

    /// One of the watcher's last actions: when, what, and how its facts arrived.
    public struct ActionRow: Equatable, Identifiable {
        public var id: String
        public var timeText: String
        public var text: String
        /// "instant update" or "check".
        public var source: String?
        /// The rule and the head, for the help tag.
        public var help: String?

        /// One element for VoiceOver: "13:03, sent to CI Fix for the conflict, by a check".
        public var accessibilityLabel: String {
            [timeText.nonEmptyText, text.prefix(1).lowercased() + text.dropFirst(), source.map { "by \(Self.article($0)) \($0)" }]
                .compactMap { $0 }
                .joined(separator: ", ")
        }

        private static func article(_ word: String) -> String { word.first.map { "aeiou".contains($0) } == true ? "an" : "a" }
    }

    /// A competing pull request the ticket waits on, with the files they share.
    public struct Competitor: Equatable {
        public var name: String
        public var files: [String]
    }

    public var status: DesignTokens.Status
    /// The status's word beside its symbol: "Waiting", "Waiting on you", "Needs attention".
    public var word: String
    /// The one-line reason: "Waiting for CI on abc1234".
    public var headline: String
    /// "CI acts next", "You act next".
    public var next: String?
    /// What clears it: "until the checks finish".
    public var clears: String?
    /// How long it has stood: "4 min".
    public var age: String?
    public var ageSeconds: Int?
    /// "Nothing is running and nothing says why", when the ticket waits silently.
    public var warning: String?
    /// "Updated 12 s ago · check".
    public var updated: String?
    /// Two or more competing pull requests, each with its shared files.
    public var competitors: [Competitor]
    public var facts: [Fact]
    /// Newest first, at most `actionLimit`.
    public var actions: [ActionRow]
    public var buttons: [Button]
    /// The rule behind the line and Symphony's own reason, for the help tag.
    public var help: String?
    /// The object of the ticket page's "Waiting on …" line while the card explains the wait: "T-1 to land".
    public var waitingOn: String?

    /// The card for `watch`, measured against `reference`; nil when the watcher doesn't watch the ticket.
    /// `inboxDecision` is whether the Inbox holds a decision on the ticket; `rateLimit` is GitHub's, from the state.
    public init?(
        watch: WatchBlock?,
        inboxDecision: Bool = false,
        rateLimit: WatchState.RateLimit? = nil,
        reference: Date,
        timeZone: TimeZone = .current
    ) {
        guard let watch else { return nil }
        let facts = watch.facts
        let pr = Self.prName(facts)
        let fixTicket = watch.waitsOn.first { $0.kind == .fixTicket }
        let competing = watch.waitsOn.filter { $0.kind == .competitor }
        let reason = watch.reason.map(Self.plain)
        func clock(_ date: Date) -> String {
            StatusMenu.clockTime(date, now: reference, timeZone: timeZone, dateFormat: "MMM d, HH:mm")
        }

        var status = DesignTokens.Status.idle
        var word = "Waiting"
        var headline: String
        var waitingOn: String?
        competitors = []

        if facts.github == "rate_limited" || watch.rule == "R1" {
            let reset = facts.githubResetAt ?? rateLimit?.reset
            headline = "GitHub's request limit is spent" + (reset.map { ": reading the PR again at \(clock($0))" } ?? "")
            waitingOn = "GitHub's request limit"
        } else if facts.pr == "merged" {
            status = .done
            word = "Merged"
            headline = "\(pr ?? "The PR") was merged"
        } else if facts.pr == "closed" {
            status = .problem
            word = "PR closed"
            let then: String
            if facts.run == "active" {
                then = "The run under way ends first."
            } else if watch.phase == "in_progress" {
                then = "The next run opens a new PR from main."
            } else {
                then = "Sent back to Rework, where the next run opens a new PR from main."
            }
            headline = "\(pr ?? "The PR") was closed without merging. \(then)"
        } else if let fixTicket {
            status = .problem
            word = "Held"
            let check = watch.decisionCheck ?? facts.fixFailures.last?.check ?? facts.failingCheck ?? "failing"
            headline = "CI keeps failing: waiting on \(fixTicket.identifier), a fix ticket for the \(check) check"
            waitingOn = "\(fixTicket.identifier), a CI fix ticket"
        } else if !competing.isEmpty {
            let names = Self.list(competing.map(\.identifier))
            let files = Self.unique(competing.flatMap(\.files))
            let they = competing.count == 1 ? "they change the same \(files.count == 1 ? "file" : "files")" : "they change the same files"
            headline = "Waiting on \(names) to land · \(they)" + (competing.count == 1 && !files.isEmpty ? " (\(files.joined(separator: ", ")))" : "")
            if competing.count > 1 { competitors = competing.map { Competitor(name: $0.identifier, files: $0.files) } }
            waitingOn = "\(names) to land"
        } else if facts.hold == "needs_decision" || watch.action == "decision" {
            status = .you
            word = "Waiting on you"
            headline = watch.action == "decision" ? "Waiting on your decision: \(reason ?? "a question in the Inbox")" : "On hold: waiting on your decision"
            waitingOn = "you"
        } else if facts.hold == "blocked" {
            status = .problem
            word = "Held"
            headline = "On hold until what it waits on is done"
        } else if watch.rule == "R15a" {
            status = .problem
            word = "Sent to Rework"
            headline = "The conflict with main came back after \(Self.maxConflictAttempts) fix runs and no PR competes: conflict sent to Rework"
        } else if facts.run == "active" || watch.rule == "R9" {
            status = .working
            word = "Working"
            headline = "A run is working on it"
        } else if watch.owner == "ci", ["R24", "R32"].contains(watch.rule ?? "") || facts.ci == "pending" {
            headline = "Waiting for CI" + (watch.head.map { " on \(Self.short($0))" } ?? "")
            waitingOn = "CI"
        } else if watch.rule == "R23" {
            let check = facts.failingCheck.map { "The \($0) check" } ?? "A check"
            headline = "\(check) is red on \(facts.baseRef ?? "the base branch") too: waiting for it to go green there"
            waitingOn = "the base branch's CI"
        } else if watch.action == "ci_fix" {
            status = .working
            word = "Fixing"
            headline = reason ?? "Sent to CI Fix"
        } else if ["dispatch", "land_agent", "return_to_origin", "to_rework", "to_code_review", "to_in_progress"].contains(watch.action ?? "") {
            status = .working
            word = "Moving on"
            headline = reason ?? "Symphony acts on it"
        } else {
            headline = reason ?? watch.summary ?? "Watching \(pr ?? "the PR")"
        }

        var warning: String?
        if let silent = watch.silent {
            status = .problem
            word = "Needs attention"
            warning = Self.silentSentence(bound: silent.bound)
        }

        self.status = status
        self.word = word
        self.headline = headline
        self.warning = warning
        self.waitingOn = waitingOn
        next = Self.ownerWords(watch.owner).map { "\($0) next" }
        clears = watch.clearsWhen.map { "until \(Self.plain($0))" }
        ageSeconds = watch.since.map { max(Int(reference.timeIntervalSince($0)), 0) }
        age = ageSeconds.map(Overview.duration)
        updated = watch.readAt.map { read in
            let seconds = Int(reference.timeIntervalSince(read))
            let ago = seconds < 1 ? "just now" : "\(Overview.duration(seconds)) ago"
            return ["Updated \(ago)", Self.sourceWord(watch.source)].compactMap { $0 }.joined(separator: " · ")
        }
        help = [watch.rule.map { "Rule \($0)" }, watch.reason].compactMap { $0 }.joined(separator: ": ").nonEmptyText

        var rows: [Fact] = []
        if let pr { rows.append(Fact(label: "PR", value: [pr, Self.prWord(facts.pr)].compactMap { $0 }.joined(separator: " · "), url: watch.prURL)) }
        if let head = watch.head {
            rows.append(Fact(label: "Head", value: Self.short(head) + (facts.headOrigin == "person" ? " · pushed by a person" : ""), help: head))
        }
        if ["open", "draft"].contains(facts.pr ?? "") {
            if let checks = Self.checksWords(facts) { rows.append(Fact(label: "Checks", value: checks)) }
            if let merge = Self.mergeWords(facts) { rows.append(Fact(label: "Merge", value: merge)) }
        }
        if facts.autoMerge == "armed" || watch.phase == "merging" {
            rows.append(Fact(label: "Auto-merge", value: facts.autoMerge == "armed" ? "on" : "off"))
        }
        rows.append(Fact(label: "Fix attempts", value: Self.fixAttempts(watch), help: "CI Fix runs for red checks, and for a conflict with main"))
        if let last = facts.fixFailures.last {
            rows.append(Fact(
                label: "Last failure", value: [last.check, last.error].compactMap { $0 }.joined(separator: ": "),
                help: "\(facts.sameFailureStreak ?? 0) in a row on the same failure; the third files a fix ticket for the check"
            ))
        }
        self.facts = rows

        actions = watch.latestActions.prefix(Self.actionLimit).enumerated().map { index, action in
            ActionRow(
                id: "\(index)-\(action.rule ?? "")-\(action.at?.timeIntervalSince1970 ?? 0)",
                timeText: action.at.map(clock) ?? "",
                text: Self.actionWords(action, facts: facts),
                source: Self.sourceWord(action.source),
                help: [action.rule.map { "Rule \($0)" }, action.head.map { "on \(Self.short($0))" }].compactMap { $0 }.joined(separator: " ").nonEmptyText
            )
        }

        var buttons: [Button] = [.checkNow]
        if let url = watch.prURL { buttons.append(.openPR(url)) }
        if inboxDecision || facts.hold == "needs_decision" { buttons.append(.openInInbox) }
        for wait in watch.waitsOn {
            if wait.isTicket {
                buttons.append(.openTicket(wait.identifier))
            } else if let url = wait.prURL {
                buttons.append(.openPullRequest(wait.identifier, url))
            }
        }
        self.buttons = Self.unique(buttons)
    }

    /// One element for VoiceOver: the status word, the line, who acts next and since when, and when it was read.
    public var accessibilityLabel: String {
        [
            word,
            headline,
            warning,
            [next, clears].compactMap { $0 }.joined(separator: ", ").nonEmptyText,
            ageSeconds.map { "For \(Overview.spokenDuration($0))" },
            updated,
        ]
        .compactMap { $0 }
        .joined(separator: ". ")
    }

    /// "Checks 2 of 10 · conflict 1 of 3 · last: conflict with main".
    static func fixAttempts(_ watch: WatchBlock) -> String {
        let facts = watch.facts
        var parts = [
            "Checks \(facts.redAttempts ?? 0) of \(facts.maxRedAttempts ?? 10)",
            "conflict \(facts.conflictAttempts ?? 0) of \(maxConflictAttempts)",
        ]
        if let cause = lastCause(watch) { parts.append("last: \(cause)") }
        return parts.joined(separator: " · ")
    }

    /// What the last CI Fix run was for: the conflict, or the check that failed.
    private static func lastCause(_ watch: WatchBlock) -> String? {
        let check = watch.facts.fixFailures.last?.check ?? watch.facts.failingCheck
        switch watch.latestActions.first(where: { $0.action == "ci_fix" })?.rule {
        case "R14": return "conflict with main"
        case "R21": return "\(check ?? "a check") failed"
        default: return watch.facts.fixFailures.last?.check.map { "\($0) failed" }
        }
    }

    /// The sentence for a silent wait (S17): quiet, or a wait past its bound.
    public static func silentSentence(bound: String?) -> String {
        switch bound {
        case "ci.merging_wait_timeout_ms": "CI has been running longer than the wait allows, and nothing says why"
        case "rate_limit_reset": "GitHub's request limit should have reset by now, and nothing has read the PR since"
        default: "nothing is running and nothing says why"
        }
    }

    static func ownerWords(_ owner: String?) -> String? {
        switch owner {
        case "agent": "An agent acts"
        case "ci": "CI acts"
        case "github": "GitHub acts"
        case "person": "You act"
        case "symphony": "Symphony acts"
        default: nil
        }
    }

    static func sourceWord(_ source: String?) -> String? {
        switch source {
        case "webhook": "instant update"
        case "poll", "check": "check"
        default: nil
        }
    }

    private static func actionWords(_ action: WatchBlock.Action, facts: WatchBlock.Facts) -> String {
        switch action.action {
        case "ci_fix": action.rule == "R14" ? "Sent to CI Fix for the conflict" : "Sent to CI Fix for the red checks"
        case "dispatch": "Started a run"
        case "to_rework": "Sent to Rework"
        case "to_code_review": "Sent back to Code Review"
        case "to_in_progress": "Sent back to In Progress"
        case "return_to_origin": "Returned with its approvals"
        case "wait_for_competitors": "Waited on the competing PRs"
        case "decision": "Asked you"
        case "rerun_failed": "Reran the failed checks"
        case "file_fix_ticket": "Filed a fix ticket for the \(facts.failingCheck ?? "failing") check"
        case "update_branch": "Updated the branch from main"
        case "merge_now": "Merged the PR"
        case "arm": "Turned auto-merge on"
        case "disarm": "Turned auto-merge off"
        case "land_agent": "Started the landing agent"
        case "close_out": "Closed out the merged PR"
        case let other?: Overview.phaseName(other)
        case nil: "Acted"
        }
    }

    private static func checksWords(_ facts: WatchBlock.Facts) -> String? {
        switch facts.ci {
        case "pending": return "running"
        case "green": return "passing"
        case "none": return facts.noCI == "not_reported" ? "none reported (counts as passing)" : "no CI (counts as passing)"
        case "required_missing": return "\(list(facts.missingChecks.isEmpty ? ["a required check"] : facts.missingChecks)) never reported"
        case "red":
            let check = facts.failingCheck ?? "a check"
            switch facts.redKind {
            case "cancelled": return "\(check) cancelled"
            case "human_only": return "\(check) failed; only a person clears it"
            case "also_red_on_base": return "\(check) failing, on the base branch too"
            default: return "\(check) failing"
            }
        default: return nil
        }
    }

    private static func mergeWords(_ facts: WatchBlock.Facts) -> String? {
        let base = facts.baseRef ?? "the base branch"
        switch facts.mergeable {
        case "clean": return "no conflict"
        case "behind": return "behind \(base)"
        case "dirty": return "conflicts with \(base)"
        case "unstable": return "unstable: a check that isn't required failed"
        case "blocked": return "blocked by branch protection"
        case "unknown": return "GitHub is still checking"
        default: return nil
        }
    }

    private static func prName(_ facts: WatchBlock.Facts) -> String? {
        guard facts.pr != "missing" else { return nil }
        return facts.prNumber.map { "PR #\($0)" }
    }

    private static func prWord(_ pr: String?) -> String? {
        switch pr {
        case "open": "open"
        case "draft": "a draft"
        case "closed": "closed without merging"
        case "merged": "merged"
        default: nil
        }
    }

    /// The first 7 characters of a commit.
    static func short(_ sha: String) -> String { String(sha.prefix(7)) }

    /// Symphony's reasons quote names in backticks; the card shows them as words.
    static func plain(_ text: String) -> String { text.replacingOccurrences(of: "`", with: "") }

    /// "T-1", "T-1 and T-2", "T-1, T-2 and T-3".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    static func unique<T: Hashable>(_ items: [T]) -> [T] {
        var seen = Set<T>()
        return items.filter { seen.insert($0).inserted }
    }
}

extension String {
    /// Nil for an empty string.
    var nonEmptyText: String? { isEmpty ? nil : self }
}
