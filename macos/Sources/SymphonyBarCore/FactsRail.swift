import Foundation

// The ticket read's `pull_request` and `connected` (`docs/control-api.md` § `pull_request`, § `connected`) and what
// the facts rail's Pull request and Connected panels say from them (`docs/design/director-ticket-page.md` §1 facts 9,
// 10, 15, 16 and 21). Symphony reads both from its own records; the app only says them.

/// The ticket's pull request as the PR and CI watcher last read it.
public struct TicketPullRequest: Equatable, Decodable {
    public enum CheckState: String, Equatable, Decodable {
        case passed, failed, running, waiting, skipped
        case cancelledNoMachine = "cancelled_no_machine"

        /// A state this app doesn't know reads as waiting: it says nothing it can't stand behind.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = CheckState(rawValue: raw) ?? .waiting
        }
    }

    public struct Check: Equatable, Decodable {
        public var name: String
        public var state: CheckState
        public var startedAt: Date?
        public var durationMs: Int?
        public var url: URL?
        public var required: Bool?

        public init(name: String, state: CheckState, startedAt: Date? = nil, durationMs: Int? = nil, url: URL? = nil, required: Bool? = nil) {
            self.name = name
            self.state = state
            self.startedAt = startedAt
            self.durationMs = durationMs
            self.url = url
            self.required = required
        }

        private enum CodingKeys: String, CodingKey {
            case name, state, url, required
            case startedAt = "started_at", durationMs = "duration_ms"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            state = try container.decodeIfPresent(CheckState.self, forKey: .state) ?? .waiting
            startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt).flatMap(SymphonyState.parseDate)
            durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
            url = try container.decodeIfPresent(String.self, forKey: .url).flatMap(URL.init(string:))
            required = try container.decodeIfPresent(Bool.self, forKey: .required)
        }
    }

    /// One workflow's checks; `workflow` is nil for a status from outside GitHub Actions.
    public struct Workflow: Equatable, Decodable {
        public var workflow: String?
        public var checks: [Check]

        public init(workflow: String?, checks: [Check]) {
            self.workflow = workflow
            self.checks = checks
        }

        private enum CodingKeys: String, CodingKey { case workflow, checks }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            workflow = try container.decodeIfPresent(String.self, forKey: .workflow)
            checks = try container.decodeIfPresent([Check].self, forKey: .checks) ?? []
        }
    }

    public var number: Int
    public var url: URL?
    public var title: String?
    /// `open`, `merged` or `closed`.
    public var state: String
    public var draft: Bool
    public var headShort: String?
    public var base: String?
    public var filesChanged: Int?
    public var additions: Int?
    public var deletions: Int?
    public var checks: [Workflow]
    public var readAt: Date?

    public init(
        number: Int, url: URL? = nil, title: String? = nil, state: String = "open", draft: Bool = false, headShort: String? = nil,
        base: String? = nil, filesChanged: Int? = nil, additions: Int? = nil, deletions: Int? = nil, checks: [Workflow] = [],
        readAt: Date? = nil
    ) {
        self.number = number
        self.url = url
        self.title = title
        self.state = state
        self.draft = draft
        self.headShort = headShort
        self.base = base
        self.filesChanged = filesChanged
        self.additions = additions
        self.deletions = deletions
        self.checks = checks
        self.readAt = readAt
    }

    private enum CodingKeys: String, CodingKey {
        case number, url, title, state, draft, base, checks, additions, deletions
        case headShort = "head_short", headSha = "head_sha", filesChanged = "files_changed", readAt = "read_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        url = try container.decodeIfPresent(String.self, forKey: .url).flatMap(URL.init(string:))
        title = try container.decodeIfPresent(String.self, forKey: .title)
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? "open"
        draft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        let sha = try container.decodeIfPresent(String.self, forKey: .headSha)
        headShort = try container.decodeIfPresent(String.self, forKey: .headShort) ?? sha.map { String($0.prefix(7)) }
        base = try container.decodeIfPresent(String.self, forKey: .base)
        filesChanged = try container.decodeIfPresent(Int.self, forKey: .filesChanged)
        additions = try container.decodeIfPresent(Int.self, forKey: .additions)
        deletions = try container.decodeIfPresent(Int.self, forKey: .deletions)
        checks = try container.decodeIfPresent([Workflow].self, forKey: .checks) ?? []
        readAt = try container.decodeIfPresent(String.self, forKey: .readAt).flatMap(SymphonyState.parseDate)
    }
}

/// Where the ticket sits among the others: its epic, the tickets it waits on and the tickets it holds up.
public struct TicketConnected: Equatable, Decodable {
    /// Another ticket as the read names it: a `title` and `state` may be unknown; `situation` is its situation's kind.
    public struct Ticket: Equatable, Decodable {
        public var identifier: String
        public var title: String?
        public var state: String?
        public var situation: DesignTokens.SituationKind?
        /// True on this ticket, in its epic's list.
        public var current: Bool

        public init(identifier: String, title: String? = nil, state: String? = nil, situation: DesignTokens.SituationKind? = nil, current: Bool = false) {
            self.identifier = identifier
            self.title = title
            self.state = state
            self.situation = situation
            self.current = current
        }

        private enum CodingKeys: String, CodingKey { case identifier, title, state, situation, current }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            identifier = try container.decode(String.self, forKey: .identifier)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            state = try container.decodeIfPresent(String.self, forKey: .state)
            situation = try container.decodeIfPresent(String.self, forKey: .situation).flatMap(DesignTokens.SituationKind.init(apiKind:))
            current = try container.decodeIfPresent(Bool.self, forKey: .current) ?? false
        }
    }

    public struct Epic: Equatable, Decodable {
        public var identifier: String
        public var title: String?
        public var done: Int
        public var total: Int
        public var tickets: [Ticket]

        public init(identifier: String, title: String? = nil, done: Int = 0, total: Int = 0, tickets: [Ticket] = []) {
            self.identifier = identifier
            self.title = title
            self.done = done
            self.total = total
            self.tickets = tickets
        }

        private enum CodingKeys: String, CodingKey { case identifier, title, done, total, tickets }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            identifier = try container.decode(String.self, forKey: .identifier)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            done = try container.decodeIfPresent(Int.self, forKey: .done) ?? 0
            total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
            tickets = try container.decodeIfPresent([Ticket].self, forKey: .tickets) ?? []
        }
    }

    public struct Blocker: Equatable, Decodable {
        public var identifier: String
        public var title: String?
        public var state: String?
        public var resolved: Bool
        public var resolvedAt: Date?

        public init(identifier: String, title: String? = nil, state: String? = nil, resolved: Bool = false, resolvedAt: Date? = nil) {
            self.identifier = identifier
            self.title = title
            self.state = state
            self.resolved = resolved
            self.resolvedAt = resolvedAt
        }

        private enum CodingKeys: String, CodingKey {
            case identifier, title, state, status
            case resolvedAt = "resolved_at"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            identifier = try container.decode(String.self, forKey: .identifier)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            state = try container.decodeIfPresent(String.self, forKey: .state)
            resolved = try container.decodeIfPresent(String.self, forKey: .status) == "resolved"
            resolvedAt = try container.decodeIfPresent(String.self, forKey: .resolvedAt).flatMap(SymphonyState.parseDate)
        }
    }

    public var epic: Epic?
    public var blockedBy: [Blocker]
    public var blocks: [Ticket]

    public init(epic: Epic? = nil, blockedBy: [Blocker] = [], blocks: [Ticket] = []) {
        self.epic = epic
        self.blockedBy = blockedBy
        self.blocks = blocks
    }

    private enum CodingKeys: String, CodingKey {
        case epic, blocks
        case blockedBy = "blocked_by"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        epic = try container.decodeIfPresent(Epic.self, forKey: .epic)
        blockedBy = try container.decodeIfPresent([Blocker].self, forKey: .blockedBy) ?? []
        blocks = try container.decodeIfPresent([Ticket].self, forKey: .blocks) ?? []
    }
}

/// A ticket read's `pull_request` and `connected`, each nil when the read holds none (no PR yet, an older Symphony).
public struct TicketFactsRead: Equatable, Decodable {
    public var pullRequest: TicketPullRequest?
    public var connected: TicketConnected?

    public init(pullRequest: TicketPullRequest?, connected: TicketConnected?) {
        self.pullRequest = pullRequest
        self.connected = connected
    }

    private enum CodingKeys: String, CodingKey {
        case connected
        case pullRequest = "pull_request"
    }

    /// The two fields of a ticket read (`GET /api/v1/:issue_identifier`); nil for anything but a JSON object.
    public static func decode(_ data: Data) -> TicketFactsRead? {
        try? JSONDecoder().decode(TicketFactsRead.self, from: data)
    }
}

// MARK: - The Pull request panel

/// What the Pull request panel says: the PR's number, state, head and size, its checks in one line, then every check
/// by workflow with its state and how long it took, the workflow with a failed check first.
public struct PullRequestPanelModel: Equatable {
    public struct Check: Equatable, Identifiable {
        public var id: String
        public var name: String
        public var state: TicketPullRequest.CheckState
        /// "Passed", "Failed", "Running", "Waiting", "Skipped", "No machine".
        public var word: String
        public var status: DesignTokens.Status
        /// "6 min 12 s"; nil until it finishes.
        public var duration: String?
        /// Its log on GitHub; nil when the read names none, and the row opens nothing.
        public var url: URL?
        public var accessibilityLabel: String
    }

    public struct Group: Equatable, Identifiable {
        public var id: String
        /// The workflow, or "Other checks" for statuses from outside GitHub Actions.
        public var name: String
        public var checks: [Check]
    }

    /// "PR #741".
    public var name: String
    public var url: URL?
    public var title: String?
    /// "Open", "Draft", "Merged", "Closed", with its status.
    public var state: String
    public var stateStatus: DesignTokens.Status
    /// "8b03e51", or "8b03e51 → main".
    public var head: String?
    /// "9 files · +486 −52"; nil when the read names no size.
    public var size: String?
    /// "1 check failed", "Checks running", "Checks passing", "No checks yet", with its status.
    public var checksBadge: String
    public var checksStatus: DesignTokens.Status
    /// "1 failed · 2 running · 5 passed"; nil without checks.
    public var checksLine: String?
    public var groups: [Group]
    public var accessibilityLabel: String

    /// The panel's line when the ticket has no pull request yet.
    public static let emptyLine = "No pull request yet: the first run opens one, and its checks appear here."

    /// The panel from `pull_request`; nil for a ticket without one, which shows `emptyLine`.
    public static func build(_ pr: TicketPullRequest?) -> PullRequestPanelModel? {
        guard let pr else { return nil }
        let (state, stateStatus): (String, DesignTokens.Status) = switch pr.state {
        case "merged": ("Merged", .done)
        case "closed": ("Closed", .idle)
        default: pr.draft ? ("Draft", .idle) : ("Open", .working)
        }
        let head = pr.headShort.map { head in pr.base.map { "\(head) → \($0)" } ?? head }
        let groups = groups(pr.checks)
        let all = groups.flatMap(\.checks)
        let (badge, badgeStatus) = badge(all)
        let line = checksLine(all)
        let spoken = ["Pull request \(pr.number)", state.lowercased(), size(pr, spoken: true), badge.lowercased()].compactMap { $0 }
        return PullRequestPanelModel(
            name: "PR #\(pr.number)", url: pr.url, title: pr.title, state: state, stateStatus: stateStatus, head: head,
            size: size(pr, spoken: false), checksBadge: badge, checksStatus: badgeStatus, checksLine: line, groups: groups,
            accessibilityLabel: spoken.joined(separator: ", ")
        )
    }

    /// The workflows as GitHub lists them, but a workflow with a failed check first, and inside a workflow its failed
    /// checks first: a red check reads first.
    static func groups(_ workflows: [TicketPullRequest.Workflow]) -> [Group] {
        let groups = workflows.enumerated().compactMap { index, workflow -> Group? in
            guard !workflow.checks.isEmpty else { return nil }
            let name = workflow.workflow ?? "Other checks"
            let checks = workflow.checks.enumerated().map { position, check in
                Self.check(check, id: "\(index)-\(position)")
            }
            let ordered = checks.filter { $0.state == .failed } + checks.filter { $0.state != .failed }
            return Group(id: "workflow-\(index)", name: name, checks: ordered)
        }
        let red = groups.filter { $0.checks.contains { $0.state == .failed } }
        return red + groups.filter { group in !red.contains(group) }
    }

    static func check(_ check: TicketPullRequest.Check, id: String) -> Check {
        let (word, status): (String, DesignTokens.Status) = switch check.state {
        case .passed: ("Passed", .done)
        case .failed: ("Failed", .problem)
        case .running: ("Running", .working)
        case .waiting: ("Waiting", .idle)
        case .skipped: ("Skipped", .idle)
        case .cancelledNoMachine: ("No machine", .idle)
        }
        let duration = check.durationMs.map(Self.duration)
        let spoken = [check.name, word.lowercased(), check.durationMs.map(Self.spokenDuration)].compactMap { $0 }
        return Check(
            id: id, name: check.name, state: check.state, word: word, status: status, duration: duration, url: check.url,
            accessibilityLabel: spoken.joined(separator: ", ")
        )
    }

    static func badge(_ checks: [Check]) -> (String, DesignTokens.Status) {
        let failed = checks.filter { $0.state == .failed }.count
        if failed > 0 { return (failed == 1 ? "1 check failed" : "\(failed) checks failed", .problem) }
        if checks.isEmpty { return ("No checks yet", .idle) }
        if checks.contains(where: { $0.state == .running || $0.state == .waiting }) { return ("Checks running", .working) }
        return ("Checks passing", .done)
    }

    /// "1 failed · 2 running · 5 passed · 1 waiting · 2 skipped": the states there are, worst first.
    static func checksLine(_ checks: [Check]) -> String? {
        guard !checks.isEmpty else { return nil }
        let order: [(TicketPullRequest.CheckState, String)] = [
            (.failed, "failed"), (.running, "running"), (.passed, "passed"), (.waiting, "waiting"), (.skipped, "skipped"),
            (.cancelledNoMachine, "without a machine"),
        ]
        return order.compactMap { state, word in
            let count = checks.filter { $0.state == state }.count
            return count > 0 ? "\(count) \(word)" : nil
        }
        .joined(separator: " · ")
    }

    static func size(_ pr: TicketPullRequest, spoken: Bool) -> String? {
        var parts: [String] = []
        if let files = pr.filesChanged { parts.append(files == 1 ? "1 file" : "\(files) files") }
        if let additions = pr.additions, let deletions = pr.deletions {
            parts.append(spoken ? "\(additions) lines added, \(deletions) removed" : "+\(additions) −\(deletions)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: spoken ? ", " : " · ")
    }

    /// "840 ms", "42 s", "6 min 12 s", "1 h 4 min": how long a check ran.
    static func duration(_ ms: Int) -> String {
        let ms = max(ms, 0)
        guard ms >= 1_000 else { return "\(ms) ms" }
        let seconds = ms / 1_000
        switch seconds {
        case ..<60: return "\(seconds) s"
        case ..<3_600: return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(seconds % 60) s"
        default: return Overview.duration(seconds)
        }
    }

    static func spokenDuration(_ ms: Int) -> String {
        let seconds = max(ms, 0) / 1_000
        guard seconds >= 60, seconds < 3_600, seconds % 60 != 0 else { return Overview.spokenDuration(seconds) }
        return Overview.spokenDuration(seconds - seconds % 60) + " " + Overview.spokenDuration(seconds % 60)
    }
}

// MARK: - The Connected panel

/// What the Connected panel says: the epic with its progress, each blocker (an open one with where it stands, a
/// resolved one struck through with when) and the tickets this one holds up.
public struct ConnectedPanelModel: Equatable {
    public struct Epic: Equatable {
        public var identifier: String
        public var title: String
        public var strip: ProgressStrip?
        /// "4 of 7 done".
        public var progress: String
        public var accessibilityLabel: String
    }

    public struct Row: Equatable, Identifiable {
        public var id: String { identifier }
        public var identifier: String
        public var title: String
        /// "Waiting for CI · In Progress", "Resolved Mon 9 Nov", "Todo".
        public var detail: String
        public var status: DesignTokens.Status
        /// A resolved blocker: drawn struck through, never hidden.
        public var struck: Bool
        public var accessibilityLabel: String
    }

    public var epic: Epic?
    public var waitingOn: [Row]
    public var holdingUp: [Row]

    public static let noEpicLine = "Not part of an epic."
    public static let noBlockerLine = "Nothing: no ticket holds this one up."
    public static let holdsNothingLine = "Nothing waits on this one."

    /// The panel from `connected`; a ticket without the field reads as connected to nothing. A blocker's situation is
    /// read from the epic's list when the blocker is one of its tickets. Dates read in `calendar`, against
    /// `reference`'s day.
    public static func build(_ connected: TicketConnected?, reference: Date, calendar: Calendar = .current) -> ConnectedPanelModel {
        let connected = connected ?? TicketConnected()
        let known = Dictionary(
            (connected.epic?.tickets ?? []).map { ($0.identifier, $0) } + connected.blocks.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let waitingOn = connected.blockedBy.map { blocker in
            row(blocker, situation: known[blocker.identifier]?.situation, reference: reference, calendar: calendar)
        }
        return ConnectedPanelModel(
            epic: connected.epic.map(epic), waitingOn: waitingOn, holdingUp: connected.blocks.map(row)
        )
    }

    static func epic(_ epic: TicketConnected.Epic) -> Epic {
        let segments = epic.tickets.map(ProgressStrip.Segment.init(ticket:))
        let total = max(epic.total, segments.count)
        let strip = segments.isEmpty ? nil : ProgressStrip(segments: segments, done: epic.done, total: total)
        let progress = "\(epic.done) of \(total) done"
        let title = epic.title ?? epic.identifier
        return Epic(
            identifier: epic.identifier, title: title, strip: strip, progress: progress,
            accessibilityLabel: "Epic \(epic.identifier), \(title), \(epic.done) of \(total) \(total == 1 ? "sub-ticket" : "sub-tickets") done"
        )
    }

    static func row(_ blocker: TicketConnected.Blocker, situation: DesignTokens.SituationKind?, reference: Date, calendar: Calendar) -> Row {
        let title = blocker.title ?? blocker.identifier
        if blocker.resolved {
            let when = blocker.resolvedAt.map { day($0, reference: reference, calendar: calendar) }
            let detail = when.map { "Resolved \($0)" } ?? "Resolved"
            return Row(
                identifier: blocker.identifier, title: title, detail: detail, status: .done, struck: true,
                accessibilityLabel: "\(blocker.identifier), \(title), no longer holds this one up, resolved" + (when.map { " \($0)" } ?? "")
            )
        }
        let detail = [situation?.word, blocker.state].compactMap { $0 }.joined(separator: " · ")
        let status = situation?.status ?? .idle
        let spoken = [blocker.identifier, title, "holds this one up", detail.isEmpty ? nil : detail.replacingOccurrences(of: " · ", with: ", ")]
        return Row(
            identifier: blocker.identifier, title: title, detail: detail.isEmpty ? "Open" : detail, status: status, struck: false,
            accessibilityLabel: spoken.compactMap { $0 }.joined(separator: ", ")
        )
    }

    static func row(_ held: TicketConnected.Ticket) -> Row {
        let title = held.title ?? held.identifier
        let detail = [held.situation?.word, held.state].compactMap { $0 }.joined(separator: " · ")
        let spoken = [held.identifier, title, "waits on this one", detail.isEmpty ? nil : detail.replacingOccurrences(of: " · ", with: ", ")]
        return Row(
            identifier: held.identifier, title: title, detail: detail, status: held.situation?.status ?? .idle, struck: false,
            accessibilityLabel: spoken.compactMap { $0 }.joined(separator: ", ")
        )
    }

    /// "today 14:02", "yesterday, Mon 9 Nov", "Fri 6 Nov".
    static func day(_ date: Date, reference: Date, calendar: Calendar) -> String {
        func text(_ format: String) -> String {
            SharedDateFormatter.string(date, format: format, locale: SharedDateFormatter.british, calendar: calendar)
        }
        if calendar.isDate(date, inSameDayAs: reference) { return "today \(text("HH:mm"))" }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: reference).map { calendar.isDate(date, inSameDayAs: $0) } ?? false
        return (yesterday ? "yesterday, " : "") + text("EEE d MMM")
    }
}

extension ProgressStrip {
    init(segments: [Segment], done: Int, total: Int) {
        self.segments = segments
        self.done = done
        self.total = total
    }
}

extension ProgressStrip.Segment {
    /// An epic's ticket: Done, waiting on the person, under way, or not started (Todo, Backlog, or unknown).
    init(ticket: TicketConnected.Ticket) {
        if ticket.state == "Done" || ticket.situation == .done {
            self = .done
        } else if ticket.situation == .you {
            self = .waitingOnYou
        } else if let state = ticket.state, !["Todo", "Backlog", "Triage"].contains(state) {
            self = .working
        } else {
            self = .notStarted
        }
    }
}
