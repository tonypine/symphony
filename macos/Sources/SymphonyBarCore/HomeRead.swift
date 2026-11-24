import Foundation

/// The Director's Home read (`GET /api/v1/home`, `docs/control-api.md` § Slot entries and queue rows), as the queue's
/// Home draws it (TP-1609, `docs/design/prototypes/home-queue/`): one entry per slot, from 1 to the slot count, and one
/// page of the queue, every ticket that holds no slot in its stored order with its position. The app decides nothing
/// about either: it only draws them.
public struct HomeRead: Equatable {
    public static let path = "api/v1/home"
    /// The rows a page asks for.
    public static let pageSize = 100

    /// The read of the page from `offset`, kept to the saved view `view` (a Tickets page's view id) when one is picked:
    /// `api/v1/home?offset=0&limit=100&view=view-a1`.
    public static func path(offset: Int, limit: Int = pageSize, view: String? = nil) -> String {
        var query = "offset=\(max(offset, 0))&limit=\(max(limit, 1))"
        if let view, let escaped = view.addingPercentEncoding(withAllowedCharacters: .urlQueryValue) { query += "&view=\(escaped)" }
        return "\(path)?\(query)"
    }

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

        private enum CodingKeys: String, CodingKey { case name, allowed, reason }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            allowed = try container.decodeIfPresent(Bool.self, forKey: .allowed) ?? true
            reason = try container.decodeIfPresent(String.self, forKey: .reason)
        }
    }

    /// A stage of the ticket's lifecycle, as the ticket read's `lifecycle` gives it, without its times.
    public struct Stage: Equatable {
        public var id: String
        public var name: String
        /// `passed`, `current`, `paused`, `skipped` or `not_yet`.
        public var state: String
        public var tokens: Int

        public init(id: String, name: String, state: String, tokens: Int = 0) {
            self.id = id
            self.name = name
            self.state = state
            self.tokens = tokens
        }
    }

    /// The ticket's plan checks: how many are proved of how many, and the next open one.
    public struct Checks: Equatable {
        public var proved: Int
        public var total: Int
        public var next: String?

        public init(proved: Int, total: Int, next: String? = nil) {
            self.proved = proved
            self.total = total
            self.next = next
        }
    }

    /// The ticket's pull request, as Symphony last read it.
    public struct PullRequest: Equatable {
        public var number: Int?
        public var filesChanged: Int?
        public var additions: Int?
        public var deletions: Int?
        public var branch: String?
        /// `failed`, `running`, `passed`, or nil with no check.
        public var ci: String?
        /// GitHub's review state (`APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`), nil with none.
        public var reviewState: String?

        public init(
            number: Int? = nil, filesChanged: Int? = nil, additions: Int? = nil, deletions: Int? = nil, branch: String? = nil,
            ci: String? = nil, reviewState: String? = nil
        ) {
            self.number = number
            self.filesChanged = filesChanged
            self.additions = additions
            self.deletions = deletions
            self.branch = branch
            self.ci = ci
            self.reviewState = reviewState
        }
    }

    /// The ticket a slot holds: the card's data.
    public struct SlotTicket: Equatable {
        public var issueID: String?
        public var identifier: String
        public var title: String?
        public var repoKey: String?
        public var phase: String?
        public var situation: Situation?
        /// When it took the slot.
        public var since: Date?
        public var working: Bool
        public var waitsOnYou: Bool
        public var move: Move?
        public var currentStage: String?
        public var stages: [Stage]
        public var tokens: Int
        public var tokenBudget: Int?
        public var plan: String?
        public var checks: Checks?
        public var pullRequest: PullRequest?

        public init(
            issueID: String? = nil, identifier: String, title: String? = nil, repoKey: String? = nil, phase: String? = nil,
            situation: Situation? = nil, since: Date? = nil, working: Bool = false, waitsOnYou: Bool = false, move: Move? = nil,
            currentStage: String? = nil, stages: [Stage] = [], tokens: Int = 0, tokenBudget: Int? = nil, plan: String? = nil,
            checks: Checks? = nil, pullRequest: PullRequest? = nil
        ) {
            self.issueID = issueID
            self.identifier = identifier
            self.title = title
            self.repoKey = repoKey
            self.phase = phase
            self.situation = situation
            self.since = since
            self.working = working
            self.waitsOnYou = waitsOnYou
            self.move = move
            self.currentStage = currentStage
            self.stages = stages
            self.tokens = tokens
            self.tokenBudget = tokenBudget
            self.plan = plan
            self.checks = checks
            self.pullRequest = pullRequest
        }
    }

    /// One slot: its number from 1, and its ticket; an empty slot holds none.
    public struct Slot: Equatable, Identifiable {
        public var number: Int
        public var since: Date?
        /// The epic whose slot it is, when the ticket runs through its epic's slot.
        public var epic: String?
        public var ticket: SlotTicket?

        public var id: Int { number }
        public var isEmpty: Bool { ticket == nil }

        public init(number: Int, since: Date? = nil, epic: String? = nil, ticket: SlotTicket? = nil) {
            self.number = number
            self.since = since
            self.epic = epic
            self.ticket = ticket
        }
    }

    /// One row of the queue.
    public struct Row: Equatable, Identifiable {
        public var issueID: String?
        public var identifier: String
        public var title: String?
        public var phase: String?
        public var repoKey: String?
        /// Its position, counted over the whole queue before the filter and the page: "6", "6.1".
        public var number: String
        public var parent: String?
        public var situation: Situation?
        public var waitsOnYou: Bool
        public var move: Move?

        public var id: String { identifier }

        public init(
            issueID: String? = nil, identifier: String, title: String? = nil, phase: String? = nil, repoKey: String? = nil, number: String,
            parent: String? = nil, situation: Situation? = nil, waitsOnYou: Bool = false, move: Move? = nil
        ) {
            self.issueID = issueID
            self.identifier = identifier
            self.title = title
            self.phase = phase
            self.repoKey = repoKey
            self.number = number
            self.parent = parent
            self.situation = situation
            self.waitsOnYou = waitsOnYou
            self.move = move
        }
    }

    /// One page of the queue.
    public struct QueuePage: Equatable {
        public var rows: [Row]
        /// The rows the filter keeps.
        public var count: Int
        /// The rows of the whole queue.
        public var total: Int
        public var offset: Int
        public var limit: Int
        /// The next page's offset, nil on the last.
        public var nextOffset: Int?
        /// The saved view the page was read with, nil without one.
        public var view: String?

        public init(rows: [Row] = [], count: Int? = nil, total: Int? = nil, offset: Int = 0, limit: Int = HomeRead.pageSize, nextOffset: Int? = nil, view: String? = nil) {
            self.rows = rows
            self.count = count ?? rows.count
            self.total = total ?? count ?? rows.count
            self.offset = offset
            self.limit = limit
            self.nextOffset = nextOffset
            self.view = view
        }
    }

    /// The slot count the engine runs.
    public var slotCount: Int
    /// One entry per slot, in number order.
    public var slots: [Slot]
    public var queue: QueuePage

    public init(slotCount: Int? = nil, slots: [Slot] = [], queue: QueuePage = QueuePage()) {
        self.slotCount = slotCount ?? slots.count
        self.slots = slots
        self.queue = queue
    }

    /// The tickets that hold a slot.
    public var slotted: Set<String> { Set(slots.compactMap { $0.ticket?.identifier }) }

    /// The read's JSON; nil for anything else.
    public static func decode(_ data: Data) -> HomeRead? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        let entries = wire.slots?.entries ?? []
        let slots = entries.map(\.model).sorted { $0.number < $1.number }
        let queue = wire.queue ?? WireQueue()
        // The read keeps a ticket that holds a slot out of the rows; the rows keep their places in the list.
        let rows = (queue.rows ?? []).map(\.row)
        return HomeRead(
            slotCount: wire.slots?.total ?? slots.count,
            slots: slots,
            queue: QueuePage(
                rows: rows, count: queue.count, total: queue.total, offset: queue.offset ?? 0, limit: queue.limit ?? pageSize,
                nextOffset: queue.nextOffset, view: queue.view
            )
        )
    }
}

extension CharacterSet {
    /// What a query value keeps as it is: the URL query characters but the ones that separate its parts.
    static let urlQueryValue = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?"))
}

// MARK: - The wire

private struct Wire: Decodable {
    var slots: WireSlots?
    var queue: WireQueue?
}

private struct WireSlots: Decodable {
    var total: Int?
    var entries: [WireSlot]?
}

private struct WireEpicRef: Decodable {
    var identifier: String?
    var title: String?
}

private struct WireSlot: Decodable {
    var slot: Int
    var since: String?
    var epic: WireEpicRef?
    var ticket: WireSlotTicket?

    var model: HomeRead.Slot {
        HomeRead.Slot(number: slot, since: since.flatMap(SymphonyState.parseDate), epic: epic?.identifier, ticket: ticket?.ticket)
    }
}

private struct WireStage: Decodable {
    var id: String
    var name: String?
    var state: String?
    var tokens: Int?
}

private struct WireChecks: Decodable {
    struct Next: Decodable {
        var statement: String?
    }

    var proved: Int?
    var total: Int?
    var next: Next?
}

private struct WireTokens: Decodable {
    var used: Int?
    var budget: Int?
}

private struct WirePlan: Decodable {
    var summary: String?
}

private struct WirePullRequest: Decodable {
    var number: Int?
    var filesChanged: Int?
    var additions: Int?
    var deletions: Int?
    var branch: String?
    var ci: String?
    var reviewState: String?

    enum CodingKeys: String, CodingKey {
        case number, filesChanged = "files_changed", additions, deletions, branch, ci, reviewState = "review_state"
    }

    var pullRequest: HomeRead.PullRequest {
        HomeRead.PullRequest(
            number: number, filesChanged: filesChanged, additions: additions, deletions: deletions, branch: branch, ci: ci,
            reviewState: reviewState
        )
    }
}

private struct WireSlotTicket: Decodable {
    var issueID: String?
    var identifier: String
    var title: String?
    var repoKey: String?
    var phase: String?
    var situation: Situation?
    var since: String?
    var working: Bool?
    var waitsOnYou: Bool?
    var move: HomeRead.Move?
    var currentStage: String?
    var stages: [WireStage]?
    var tokens: WireTokens?
    var plan: WirePlan?
    var checks: WireChecks?
    var pullRequest: WirePullRequest?

    enum CodingKeys: String, CodingKey {
        case issueID = "issue_id", identifier, title, repoKey = "repo_key", phase, situation, since, working, waitsOnYou = "waits_on_you",
             move, currentStage = "current_stage", stages, tokens, plan, checks, pullRequest = "pull_request"
    }

    var ticket: HomeRead.SlotTicket {
        HomeRead.SlotTicket(
            issueID: issueID, identifier: identifier, title: title, repoKey: repoKey, phase: phase, situation: situation,
            since: since.flatMap(SymphonyState.parseDate), working: working ?? false,
            waitsOnYou: waitsOnYou ?? (situation?.kind == .you), move: move, currentStage: currentStage,
            stages: (stages ?? []).map { HomeRead.Stage(id: $0.id, name: $0.name ?? $0.id, state: $0.state ?? "not_yet", tokens: $0.tokens ?? 0) },
            tokens: tokens?.used ?? 0, tokenBudget: tokens?.budget, plan: plan?.summary,
            checks: checks.map { HomeRead.Checks(proved: $0.proved ?? 0, total: $0.total ?? 0, next: $0.next?.statement) },
            pullRequest: pullRequest?.pullRequest
        )
    }
}

private struct WireQueue: Decodable {
    var rows: [WireRow]?
    var count: Int?
    var total: Int?
    var offset: Int?
    var limit: Int?
    var nextOffset: Int?
    var view: String?

    enum CodingKeys: String, CodingKey { case rows, count, total, offset, limit, nextOffset = "next_offset", view }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rows = try container.decodeIfPresent([WireRow].self, forKey: .rows)
        count = try container.decodeIfPresent(Int.self, forKey: .count)
        total = try container.decodeIfPresent(Int.self, forKey: .total)
        offset = try container.decodeIfPresent(Int.self, forKey: .offset)
        limit = try container.decodeIfPresent(Int.self, forKey: .limit)
        nextOffset = try container.decodeIfPresent(Int.self, forKey: .nextOffset)
        // The view read back is its id, or the view itself.
        view = (try? container.decodeIfPresent(String.self, forKey: .view)) ?? nil
    }
}

private struct WireRow: Decodable {
    var issueID: String?
    var identifier: String
    var title: String?
    var phase: String?
    var repoKey: String?
    var number: String
    var parent: String?
    var situation: Situation?
    var waitsOnYou: Bool?
    var move: HomeRead.Move?

    enum CodingKeys: String, CodingKey {
        case issueID = "issue_id", identifier, title, phase, repoKey = "repo_key", number, path, parent, situation,
             waitsOnYou = "waits_on_you", move
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        issueID = try container.decodeIfPresent(String.self, forKey: .issueID)
        identifier = try container.decode(String.self, forKey: .identifier)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        phase = try container.decodeIfPresent(String.self, forKey: .phase)
        repoKey = try container.decodeIfPresent(String.self, forKey: .repoKey)
        // "6.1", or a whole number; else from its path.
        if let text = try? container.decode(String.self, forKey: .number) {
            number = text
        } else if let whole = try? container.decode(Int.self, forKey: .number) {
            number = String(whole)
        } else {
            number = ((try? container.decode([Int].self, forKey: .path)) ?? []).map(String.init).joined(separator: ".")
        }
        parent = try container.decodeIfPresent(String.self, forKey: .parent)
        situation = try? container.decodeIfPresent(Situation.self, forKey: .situation)
        waitsOnYou = try container.decodeIfPresent(Bool.self, forKey: .waitsOnYou)
        move = try? container.decodeIfPresent(HomeRead.Move.self, forKey: .move)
    }

    var row: HomeRead.Row {
        HomeRead.Row(
            issueID: issueID, identifier: identifier, title: title, phase: phase, repoKey: repoKey, number: number, parent: parent,
            situation: situation, waitsOnYou: waitsOnYou ?? (situation?.kind == .you), move: move
        )
    }
}
