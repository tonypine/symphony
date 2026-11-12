import Foundation

/// Work › Initiatives as the epic's story (TP-1458, analysis §2.3 and §4.4): the sub-tickets in their chain order,
/// numbered, the one Symphony works or starts next highlighted, the done ones quiet with the day they finished, the
/// canceled ones struck at the end, the header's progress from the epic read, and each open sub-ticket's blockers
/// from its own ticket read.
///
/// It reads what the app already holds: the Initiatives' sub-tickets and their links, the epic's records
/// (`GET /api/v1/tickets?epic=`: priority, age, phase and when it entered it; the canceled sub-tickets, which the
/// Initiatives leave out), the dispatch order on `/state`, and the sub-tickets' ticket reads (`connected`).
public struct InitiativeStory: Equatable {
    /// How a row stands out: the one Symphony works or starts next, a finished one, a canceled one, or none.
    public enum Mark: Equatable {
        case current, done, canceled, open
    }

    public struct Row: Equatable, Identifiable {
        /// Its place in the chain, from 1; nil for a canceled sub-ticket, which takes no place.
        public var number: Int?
        public var identifier: String
        public var title: String?
        public var mark: Mark
        public var line: Situation
        /// "Done Fri 6 Nov", "Done": a finished sub-ticket's line in place of its situation.
        public var doneLine: String?
        /// Its blockers from its ticket read, open with their phase and situation, resolved struck with their date;
        /// empty for a finished or canceled one and until its read answers.
        public var blockers: [ConnectedPanelModel.Row]
        /// The Initiatives' sub-ticket, for Review; nil for a canceled one.
        public var ticket: Initiative.SubTicket?
        public var accessibilityLabel: String

        public var id: String { identifier }
    }

    /// A sub-ticket as the chain order weighs it.
    public struct ChainItem: Equatable {
        public var identifier: String
        public var blockedBy: [String]
        /// Linear's priority: 1 urgent … 4 low; 0 or nil for none, which sorts last.
        public var priority: Int?
        public var createdAt: Date?
        /// Its place in the dispatch order, 1 for the next; nil when it is not in line.
        public var position: Int?
        /// Whether it landed: a landed ticket goes before the ones still to land.
        public var done: Bool

        public init(
            identifier: String, blockedBy: [String] = [], priority: Int? = nil, createdAt: Date? = nil, position: Int? = nil, done: Bool = false
        ) {
            self.identifier = identifier
            self.blockedBy = blockedBy
            self.priority = priority
            self.createdAt = createdAt
            self.position = position
            self.done = done
        }
    }

    public var identifier: String
    public var rows: [Row]
    /// The epic read's strip; nil until a sub-ticket's ticket read names the epic.
    public var strip: ProgressStrip?
    /// "3 of 26 done": the epic read's count, the Initiatives' until it answers.
    public var progress: String
    /// What VoiceOver reads for the header's progress.
    public var progressAccessibilityLabel: String

    public var current: Row? { rows.first { $0.mark == .current } }

    /// The story of `initiative`: `records` are the epic's ticket records, `connected` each sub-ticket's ticket read by
    /// identifier, `order` the dispatch order. Dates read in `calendar`, against `reference`'s day.
    public init(
        initiative: Initiative, records: [TicketsRow] = [], connected: [String: TicketConnected] = [:], order: DispatchOrder? = nil,
        reference: Date = Date(), calendar: Calendar = .current
    ) {
        identifier = initiative.identifier
        let records = Dictionary(
            records.filter { $0.epic == nil || $0.epic == initiative.identifier }.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let dispatched = Dictionary(
            (order?.groups ?? []).flatMap(\.tickets).map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let subTickets = Dictionary(initiative.subTickets.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })

        let isDone: (Initiative.SubTicket) -> Bool = { ticket in
            ticket.waits == .done || records[ticket.identifier].map(Self.isDone) == true
        }
        let items = initiative.subTickets.map { ticket in
            let read = connected[ticket.identifier]?.blockedBy.map(\.identifier) ?? []
            let record = records[ticket.identifier]
            return ChainItem(
                identifier: ticket.identifier, blockedBy: Self.unique(ticket.blockedBy + read), priority: record?.number("priority"),
                createdAt: record?.time("created_at"), position: dispatched[ticket.identifier]?.position, done: isDone(ticket)
            )
        }
        let chain = Self.chainOrder(items).compactMap { subTickets[$0] }

        let epicRead = chain.lazy.compactMap { connected[$0.identifier]?.epic }.first { $0.identifier == initiative.identifier }
        let known = Self.kinds(chain, epicRead: epicRead, dispatched: dispatched)
        let current = Self.current(chain.filter { !isDone($0) }, dispatched: dispatched)

        var rows: [Row] = chain.enumerated().map { index, ticket in
            let done = isDone(ticket)
            let mark: Mark = done ? .done : ticket.identifier == current ? .current : .open
            let finished = done
                ? Self.finished(ticket.identifier, record: records[ticket.identifier], initiative: initiative, connected: connected)
                : nil
            let doneLine = done ? ["Done", finished.map { ConnectedPanelModel.day($0, reference: reference, calendar: calendar) }].compactMap { $0 }.joined(separator: " ") : nil
            let blockers = done ? [] : (connected[ticket.identifier]?.blockedBy ?? []).map {
                ConnectedPanelModel.row($0, situation: known[$0.identifier], reference: reference, calendar: calendar)
            }
            let line = done ? Situation(kind: .done, cause: "") : ticket.line
            return Row(
                number: index + 1, identifier: ticket.identifier, title: ticket.title, mark: mark, line: line, doneLine: doneLine,
                blockers: blockers, ticket: ticket,
                accessibilityLabel: Self.spoken(
                    number: index + 1, of: chain.count, identifier: ticket.identifier, title: ticket.title, mark: mark,
                    state: doneLine ?? SituationText(line, reference: reference).spoken(), blockers: blockers
                )
            )
        }
        let canceled = records.values
            .filter { subTickets[$0.identifier] == nil && $0.identifier != initiative.identifier && Self.isCanceled($0) }
            .sorted { Self.precedes(($0.time("created_at"), $0.identifier), ($1.time("created_at"), $1.identifier)) }
        rows += canceled.map { record in
            let title = record.text("title")
            return Row(
                number: nil, identifier: record.identifier, title: title, mark: .canceled, line: Situation(kind: .cancelled, cause: ""),
                doneLine: nil, blockers: [], ticket: nil,
                accessibilityLabel: [record.identifier, title, "canceled"].compactMap { $0 }.joined(separator: ", ")
            )
        }
        self.rows = rows

        if let epicRead {
            let model = ConnectedPanelModel.epic(epicRead)
            strip = model.strip
            progress = model.progress
            let total = max(epicRead.total, epicRead.tickets.count)
            progressAccessibilityLabel = "\(epicRead.done) of \(total) \(total == 1 ? "sub-ticket" : "sub-tickets") done"
        } else {
            strip = nil
            progress = initiative.progress
            progressAccessibilityLabel = initiative.barAccessibilityLabel
        }
    }

    // MARK: - The chain order

    /// The identifiers of `items` in chain order: a topological order of `blockedBy` between them, each step taking the
    /// ready ticket first that landed, then by its dispatch position when it has no blocker relation with the others,
    /// then by priority (urgent first, none last), then by age (the oldest first), then by identifier. A cycle is broken
    /// on the same key.
    public static func chainOrder(_ items: [ChainItem]) -> [String] {
        let identifiers = Set(items.map(\.identifier))
        var waits = Dictionary(
            items.map { item in (item.identifier, Set(item.blockedBy).intersection(identifiers).subtracting([item.identifier])) },
            uniquingKeysWith: { first, second in first.union(second) }
        )
        let related = waits.values.reduce(into: Set(waits.filter { !$0.value.isEmpty }.keys)) { $0.formUnion($1) }
        var remaining = unique(items.map(\.identifier)).compactMap { identifier in items.first { $0.identifier == identifier } }
        var order: [String] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { waits[$0.identifier]?.isEmpty ?? true }
            let candidates = ready.isEmpty ? remaining : ready
            guard let next = candidates.min(by: { precedes($0, $1, related: related) }) else { break }
            order.append(next.identifier)
            remaining.removeAll { $0.identifier == next.identifier }
            for key in waits.keys { waits[key]?.remove(next.identifier) }
        }
        return order
    }

    static func precedes(_ lhs: ChainItem, _ rhs: ChainItem, related: Set<String>) -> Bool {
        if lhs.done != rhs.done { return lhs.done }
        let place: (ChainItem) -> Int = { related.contains($0.identifier) ? Int.max : $0.position ?? Int.max }
        if place(lhs) != place(rhs) { return place(lhs) < place(rhs) }
        let rank: (ChainItem) -> Int = { item in
            guard let priority = item.priority, priority > 0 else { return 5 }
            return priority
        }
        if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
        return precedes((lhs.createdAt, lhs.identifier), (rhs.createdAt, rhs.identifier))
    }

    /// The older first, one without a date last, then by identifier as a person counts ("TP-9" before "TP-10").
    static func precedes(_ lhs: (Date?, String), _ rhs: (Date?, String)) -> Bool {
        let left = lhs.0 ?? .distantFuture
        let right = rhs.0 ?? .distantFuture
        if left != right { return left < right }
        return lhs.1.compare(rhs.1, options: .numeric) == .orderedAscending
    }

    static func unique(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return identifiers.filter { seen.insert($0).inserted }
    }

    // MARK: - The marks

    /// The open sub-ticket to highlight: the first in the chain a run works on, else the one first in the dispatch
    /// order; nil when none runs and none is in line.
    static func current(_ open: [Initiative.SubTicket], dispatched: [String: DispatchOrder.Ticket]) -> String? {
        if let running = open.first(where: { dispatched[$0.identifier]?.outcome == .running || $0.waits == .working }) {
            return running.identifier
        }
        return open
            .compactMap { ticket in dispatched[ticket.identifier]?.position.map { (ticket.identifier, $0) } }
            .min { $0.1 < $1.1 }?.0
    }

    static func isDone(_ record: TicketsRow) -> Bool {
        record.phase?.lowercased() == "done" || record.situationKind == .done
    }

    static func isCanceled(_ record: TicketsRow) -> Bool {
        ["canceled", "cancelled"].contains(record.phase?.lowercased() ?? "") || record.situationKind == .cancelled
    }

    /// When a finished sub-ticket finished: its record's entry into Done, else when a sibling's link or ticket read
    /// saw it resolve.
    static func finished(_ identifier: String, record: TicketsRow?, initiative: Initiative, connected: [String: TicketConnected]) -> Date? {
        if let record, isDone(record), let at = record.time("phase_at") { return at }
        let linked = initiative.subTickets.flatMap(\.blockers).first { $0.identifier == identifier && !$0.open && $0.completedAt != nil }
        if let at = linked?.completedAt { return at }
        return connected.keys.sorted().lazy
            .compactMap { connected[$0]?.blockedBy.first { $0.identifier == identifier && $0.resolved && $0.resolvedAt != nil }?.resolvedAt }
            .first
    }

    /// Each ticket's situation kind a blocker's line reads: the epic read's, then the sub-tickets' own.
    static func kinds(
        _ chain: [Initiative.SubTicket], epicRead: TicketConnected.Epic?, dispatched: [String: DispatchOrder.Ticket]
    ) -> [String: DesignTokens.SituationKind] {
        var kinds = [String: DesignTokens.SituationKind]()
        for ticket in dispatched.values { if let kind = ticket.situation?.kind { kinds[ticket.identifier] = kind } }
        for ticket in chain { kinds[ticket.identifier] = ticket.line.kind }
        for ticket in epicRead?.tickets ?? [] { if let kind = ticket.situation { kinds[ticket.identifier] = kind } }
        return kinds
    }

    /// "4 of 26, TP-1441, The Situation line, current, Working: …, blocked by TP-1440, …".
    static func spoken(
        number: Int, of total: Int, identifier: String, title: String?, mark: Mark, state: String, blockers: [ConnectedPanelModel.Row]
    ) -> String {
        var parts = ["\(number) of \(total)", identifier]
        if let title { parts.append(title) }
        if mark == .current { parts.append("current") }
        parts.append(state)
        parts += blockers.map(\.accessibilityLabel)
        return parts.joined(separator: ", ")
    }
}

extension InitiativeStory {
    /// The columns the story reads from the epic's records.
    public static let recordColumns = ["identifier", "title", "epic", "phase", "situation", "priority", "created_at", "phase_at"]

    /// `GET /api/v1/tickets` for the records of the epic `identifier`, every repo.
    public static func recordsPath(_ identifier: String) -> String {
        let query = TicketsQuery(chips: [TicketFilterChip(filter: .epic, values: [identifier])], columns: recordColumns)
        return query.path(scope: .all, now: Date())
    }

    /// The sub-tickets whose ticket reads the story needs: every open one, or the first when all are done, for the
    /// header's epic read.
    public static func readsNeeded(_ initiative: Initiative) -> [String] {
        let open = initiative.subTickets.filter { $0.waits != .done }.map(\.identifier)
        return open.isEmpty ? Array(initiative.subTickets.prefix(1).map(\.identifier)) : open
    }
}

extension InitiativesList {
    /// Work's sidebar count: the epics waiting on a person, one of their sub-tickets waiting on the Director.
    public static func waitingOnPerson(_ initiatives: [Initiative]) -> Int {
        initiatives.filter { initiative in initiative.subTickets.contains { $0.waits == .you } }.count
    }
}
