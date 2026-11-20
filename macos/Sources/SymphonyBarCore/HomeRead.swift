import Foundation

/// The Director's Home read (`GET /api/v1/home`, `docs/control-api.md` § The Home read): the two lists Home draws,
/// already shaped by Symphony. `inProgress` is every ticket that has started, a ticket of an epic under its epic's node;
/// `queue` is every ticket Symphony would dispatch that has not started, as the tree of what waits on what. The app
/// decides nothing about either: it only draws them (`HomeLists`).
public struct HomeRead: Equatable {
    public static let path = "api/v1/home"

    /// The move a ticket that waits on the Director offers: `answer` or `unblock`, as the ticket's `moves` judge it.
    public struct Move: Equatable, Decodable {
        public var name: String
        public var allowed: Bool
        public var reason: String?

        public init(name: String, allowed: Bool = true, reason: String? = nil) {
            self.name = name
            self.allowed = allowed
            self.reason = reason
        }
    }

    /// A ticket in progress.
    public struct Ticket: Equatable {
        public var issueID: String?
        public var identifier: String
        public var title: String?
        public var repoKey: String?
        public var phase: String?
        public var situation: Situation?
        public var since: Date?
        /// Whether a run works on it now.
        public var working: Bool
        public var move: Move?

        public init(
            issueID: String? = nil, identifier: String, title: String? = nil, repoKey: String? = nil, phase: String? = nil,
            situation: Situation? = nil, since: Date? = nil, working: Bool = false, move: Move? = nil
        ) {
            self.issueID = issueID
            self.identifier = identifier
            self.title = title
            self.repoKey = repoKey
            self.phase = phase
            self.situation = situation
            self.since = since
            self.working = working
            self.move = move
        }
    }

    /// An epic's tickets by state, which `total` sums.
    public struct Counts: Equatable {
        public var done: Int
        public var inProgress: Int
        public var needsPerson: Int
        public var needsFix: Int
        public var notStarted: Int

        public init(done: Int = 0, inProgress: Int = 0, needsPerson: Int = 0, needsFix: Int = 0, notStarted: Int = 0) {
            self.done = done
            self.inProgress = inProgress
            self.needsPerson = needsPerson
            self.needsFix = needsFix
            self.notStarted = notStarted
        }
    }

    /// An epic with a ticket in progress, and those tickets.
    public struct Epic: Equatable {
        /// Nil when Symphony holds no record of the epic.
        public var issueID: String?
        public var identifier: String
        public var title: String?
        public var counts: Counts
        public var total: Int
        public var tickets: [Ticket]

        public init(issueID: String? = nil, identifier: String, title: String? = nil, counts: Counts, total: Int, tickets: [Ticket]) {
            self.issueID = issueID
            self.identifier = identifier
            self.title = title
            self.counts = counts
            self.total = total
            self.tickets = tickets
        }
    }

    /// One entry of `in_progress`: an epic's node, or a ticket with no epic.
    public enum Entry: Equatable {
        case epic(Epic)
        case ticket(Ticket)
    }

    /// A queued ticket and the queued tickets that wait on it.
    public struct QueueNode: Equatable {
        public var issueID: String?
        public var identifier: String
        public var title: String?
        public var repoKey: String?
        /// The ticket's epic's title, nil when it has none.
        public var epic: String?
        /// On a root, the ticket in progress it starts after.
        public var after: String?
        public var alsoWaitsOn: [String]
        /// On a root that waits on nothing, where it stands; nil on every other node.
        public var situation: Situation?
        public var children: [QueueNode]

        public init(
            issueID: String? = nil, identifier: String, title: String? = nil, repoKey: String? = nil, epic: String? = nil,
            after: String? = nil, alsoWaitsOn: [String] = [], situation: Situation? = nil, children: [QueueNode] = []
        ) {
            self.issueID = issueID
            self.identifier = identifier
            self.title = title
            self.repoKey = repoKey
            self.epic = epic
            self.after = after
            self.alsoWaitsOn = alsoWaitsOn
            self.situation = situation
            self.children = children
        }
    }

    public var inProgress: [Entry]
    public var queue: [QueueNode]

    public init(inProgress: [Entry] = [], queue: [QueueNode] = []) {
        self.inProgress = inProgress
        self.queue = queue
    }

    /// The read's JSON; nil for anything else.
    public static func decode(_ data: Data) -> HomeRead? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        return HomeRead(inProgress: wire.inProgress.map(\.entry), queue: wire.queue.roots.map(\.node))
    }
}

// MARK: - The wire

private struct Wire: Decodable {
    var inProgress: [WireEntry]
    var queue: WireQueue

    enum CodingKeys: String, CodingKey { case inProgress = "in_progress", queue }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inProgress = try container.decodeIfPresent([WireEntry].self, forKey: .inProgress) ?? []
        queue = try container.decodeIfPresent(WireQueue.self, forKey: .queue) ?? WireQueue(roots: [])
    }
}

private struct WireQueue: Decodable {
    var roots: [WireNode]
}

private struct WireTicket: Decodable {
    var issueID: String?
    var identifier: String
    var title: String?
    var repoKey: String?
    var phase: String?
    var situation: Situation?
    var since: String?
    var working: Bool?
    var move: HomeRead.Move?

    enum CodingKeys: String, CodingKey {
        case issueID = "issue_id", identifier, title, repoKey = "repo_key", phase, situation, since, working, move
    }

    var ticket: HomeRead.Ticket {
        HomeRead.Ticket(
            issueID: issueID, identifier: identifier, title: title, repoKey: repoKey, phase: phase, situation: situation,
            since: since.flatMap(SymphonyState.parseDate) ?? situation?.since, working: working ?? false, move: move
        )
    }
}

private struct WireCounts: Decodable {
    var done: Int?
    var inProgress: Int?
    var needsPerson: Int?
    var needsFix: Int?
    var notStarted: Int?

    enum CodingKeys: String, CodingKey {
        case done, inProgress = "in_progress", needsPerson = "needs_person", needsFix = "needs_fix", notStarted = "not_started"
    }

    var counts: HomeRead.Counts {
        HomeRead.Counts(
            done: done ?? 0, inProgress: inProgress ?? 0, needsPerson: needsPerson ?? 0, needsFix: needsFix ?? 0,
            notStarted: notStarted ?? 0
        )
    }
}

private struct WireEntry: Decodable {
    var entry: HomeRead.Entry

    enum CodingKeys: String, CodingKey { case kind, issueID = "issue_id", identifier, title, counts, total, tickets }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decodeIfPresent(String.self, forKey: .kind) == "epic" else {
            entry = .ticket(try WireTicket(from: decoder).ticket)
            return
        }
        let counts = (try container.decodeIfPresent(WireCounts.self, forKey: .counts))?.counts ?? HomeRead.Counts()
        let tickets = try container.decodeIfPresent([WireTicket].self, forKey: .tickets) ?? []
        let sum = counts.done + counts.inProgress + counts.needsPerson + counts.needsFix + counts.notStarted
        entry = .epic(HomeRead.Epic(
            issueID: try container.decodeIfPresent(String.self, forKey: .issueID),
            identifier: try container.decode(String.self, forKey: .identifier),
            title: try container.decodeIfPresent(String.self, forKey: .title),
            counts: counts,
            total: try container.decodeIfPresent(Int.self, forKey: .total) ?? sum,
            tickets: tickets.map(\.ticket)
        ))
    }
}

private struct WireEpicRef: Decodable {
    var identifier: String?
    var title: String?
}

private struct WireNode: Decodable {
    var issueID: String?
    var identifier: String
    var title: String?
    var repoKey: String?
    var epic: WireEpicRef?
    var after: String?
    var alsoWaitsOn: [String]?
    var situation: Situation?
    var children: [WireNode]?

    enum CodingKeys: String, CodingKey {
        case issueID = "issue_id", identifier, title, repoKey = "repo_key", epic, after, alsoWaitsOn = "also_waits_on", situation,
             children
    }

    var node: HomeRead.QueueNode {
        HomeRead.QueueNode(
            issueID: issueID, identifier: identifier, title: title, repoKey: repoKey, epic: epic?.title ?? epic?.identifier,
            after: after, alsoWaitsOn: alsoWaitsOn ?? [], situation: situation, children: (children ?? []).map(\.node)
        )
    }
}

// MARK: - The page

/// Home as it is drawn (TP-1499, `docs/design/director-window-and-home.md` § Home): two tree lists of one-line rows,
/// "In progress" and "Queue", each left out when it has no entry. Every row is keyed by its ticket's identifier.
public struct HomeLists: Equatable {
    public static let progressTitle = "In progress"
    public static let queueTitle = "Queue"
    /// While the first read is on its way.
    public static let reading = "Reading Home…"
    /// A read that came back and doesn't decode.
    public static let unreadable = "Symphony's Home read doesn't read."
    /// The failure symbol of the Empty state Home shows while it has no read to show.
    public static let failureSymbol = "exclamationmark.triangle"

    /// What `result`, a Home read that gave no Home to show, tells the page: `unsupported` for an older Symphony's
    /// 404, its failure for one that got no answer, and `unreadable` for a body that came and doesn't decode.
    public static func failure(after result: ConditionalResult) -> EndpointResult {
        if case let .changed(answer, _) = result {
            switch answer {
            case .loaded: break
            case .unsupported, .failed: return answer
            }
        }
        return .failed(unreadable)
    }

    /// One row of either list.
    public struct Row: Equatable, Identifiable {
        /// What the row starts with: the live dot while a run works, the situation's glyph, the clock of a ticket that
        /// waits in the queue, or the epic's glyph.
        public enum Lead: Equatable {
            case live
            case status(DesignTokens.Status)
            case waiting
            case epic
        }

        /// The situation as a small badge.
        public struct Badge: Equatable {
            public var status: DesignTokens.Status
            public var word: String
        }

        /// The move on a ticket that needs the Director: its title and the move the read names.
        public struct Move: Equatable {
            public var name: String
            public var title: String
            /// Why it can't act now; nil when it can.
            public var reason: String?
        }

        public var identifier: String
        public var issueID: String?
        public var title: String
        public var lead: Lead
        /// "TP-1480": the ticket in progress a queue root starts after.
        public var after: String?
        /// The epic's chip, in the queue.
        public var epic: String?
        public var badge: Badge?
        public var move: Move?
        /// How long the situation has held, or an epic's "4 of 9".
        public var value: String?
        /// An epic's progress strip.
        public var strip: [DesignTokens.ProgressStrip.Item]?

        public var id: String { identifier }
        public var isEpic: Bool { lead == .epic }

        /// "Starts when TP-1480 lands": the help of the ticket a root comes after.
        public static func afterHelp(_ identifier: String) -> String { "Starts when \(identifier) lands" }
    }

    public var progress: [TreeNode<String>]
    public var queue: [TreeNode<String>]
    public var rows: [String: Row]
    /// What holds the whole factory, one line each above the lists (TP-1515): "Agents can't sign in to Claude since
    /// Nov 13, 09:46 (Failed to authenticate. …): new runs wait until Nov 13, 10:01." Empty when nothing does.
    public var notices: [String]

    public init(progress: [TreeNode<String>] = [], queue: [TreeNode<String>] = [], rows: [String: Row] = [:], notices: [String] = []) {
        self.progress = progress
        self.queue = queue
        self.rows = rows
        self.notices = notices
    }

    /// Home's lines for a provider that refuses the agents' sign-in, one per hold, from `snapshot`: the provider's
    /// message and since when. A hold its probe is checking (canary) is lifting, so it has no line.
    public static func notices(_ snapshot: StateSnapshot, reference: Date, timeZone: TimeZone = .current) -> [String] {
        snapshot.usageLimits.filter { $0.isSignInFailure && $0.phase != .canary }.map { limit in
            Overview.signInSentence(
                limit, what: StatusMenu.apiUnreachableName(limit), when: Overview.untilPhrase(limit, reference: reference, timeZone: timeZone),
                reference: reference, timeZone: timeZone
            )
        }
    }

    /// The lists of `read`, with `notices` above them; ages are measured against `reference`, Symphony's own clock.
    public init(read: HomeRead, reference: Date, notices: [String] = []) {
        self.notices = notices
        var rows: [String: Row] = [:]
        progress = read.inProgress.map { entry in
            switch entry {
            case let .ticket(ticket):
                rows[ticket.identifier] = Self.row(ticket, reference: reference)
                return TreeNode(ticket.identifier)
            case let .epic(epic):
                rows[epic.identifier] = Self.row(epic)
                for ticket in epic.tickets { rows[ticket.identifier] = Self.row(ticket, reference: reference) }
                return TreeNode(epic.identifier, children: epic.tickets.map { TreeNode($0.identifier) })
            }
        }
        func walk(_ node: HomeRead.QueueNode) -> TreeNode<String> {
            rows[node.identifier] = Self.row(node, reference: reference)
            return TreeNode(node.identifier, children: node.children.map(walk))
        }
        queue = read.queue.map(walk)
        self.rows = rows
    }

    public func row(_ identifier: String) -> Row? { rows[identifier] }

    /// Whether neither list has an entry.
    public var isEmpty: Bool { progress.isEmpty && queue.isEmpty }

    static func row(_ ticket: HomeRead.Ticket, reference: Date) -> Row {
        let lead: Row.Lead = ticket.working ? .live : ticket.situation.map { .status($0.kind.status) } ?? .waiting
        return Row(
            identifier: ticket.identifier, issueID: ticket.issueID, title: ticket.title ?? ticket.identifier, lead: lead,
            badge: ticket.situation.map(badge), move: ticket.move.map(move), value: age(ticket.since, reference: reference)
        )
    }

    static func row(_ epic: HomeRead.Epic) -> Row {
        Row(
            identifier: epic.identifier, issueID: epic.issueID, title: epic.title ?? epic.identifier, lead: .epic,
            value: "\(epic.counts.done) of \(epic.total)", strip: strip(epic.counts)
        )
    }

    static func row(_ node: HomeRead.QueueNode, reference: Date) -> Row {
        Row(
            identifier: node.identifier, issueID: node.issueID, title: node.title ?? node.identifier,
            lead: node.situation.map { .status($0.kind.status) } ?? .waiting, after: node.after, epic: node.epic,
            badge: node.situation.map(badge), value: age(node.situation?.since, reference: reference)
        )
    }

    static func badge(_ situation: Situation) -> Row.Badge {
        Row.Badge(status: situation.kind.status, word: situation.word)
    }

    static func move(_ move: HomeRead.Move) -> Row.Move {
        let title = TicketActionRail.Move(rawValue: move.name)?.title ?? move.name.capitalized
        return Row.Move(name: move.name, title: title, reason: move.allowed ? nil : (move.reason ?? TicketActionRail.unknownReason))
    }

    /// "14 min": how long since `since`, nil without one.
    static func age(_ since: Date?, reference: Date) -> String? {
        since.map { Overview.duration(Int(reference.timeIntervalSince($0))) }
    }

    /// An epic's strip: its done tickets, those waiting on the Director, those to fix, those in progress (breathing),
    /// then those not started, one segment each.
    static func strip(_ counts: HomeRead.Counts) -> [DesignTokens.ProgressStrip.Item] {
        let parts: [(DesignTokens.Status?, Int)] = [
            (.done, counts.done), (.you, counts.needsPerson), (.problem, counts.needsFix), (.working, counts.inProgress),
            (nil, counts.notStarted),
        ]
        return parts.flatMap { status, count in
            Array(repeating: DesignTokens.ProgressStrip.Item(status, live: status == .working), count: max(count, 0))
        }
    }
}
