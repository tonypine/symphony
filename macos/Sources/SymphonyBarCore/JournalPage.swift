import Foundation

// The Journal (TP-1459; analysis §2.6 piece 1, §2.8 and §6.4): what happened while the Director was away. The notable
// events of every ticket from Symphony's read across tickets (`GET /api/v1/events`, `docs/control-api.md` § "The events
// across tickets"), newest first under a separator for each day, each row the Timeline entry's glyph for its class,
// the ticket it is on as a chip, the sentence of what happened and who did it. The filter bar keeps a repository, an
// epic and classes of event, and Everything shows every event instead of the notable ones. The read pages 200 at a
// time; Show Earlier reads the page before. A row's chip opens its ticket's page at that event.

/// A class of event, as the read's `classes` filters it and its menu lists it.
public enum JournalClass: String, CaseIterable, Identifiable, Equatable, Comparable {
    case verdict, move, question, pause, rule, ticket, situation, run, finding, person, note

    public var id: String { rawValue }

    /// The class's name in the Class menu and its chip.
    public var title: String {
        switch self {
        case .verdict: "Verdicts"
        case .move: "Phase moves"
        case .question: "Questions"
        case .pause: "Pauses"
        case .rule: "Rule actions"
        case .ticket: "Tickets filed"
        case .situation: "Situations"
        case .run: "Runs"
        case .finding: "Findings"
        case .person: "Your actions"
        case .note: "Notes"
        }
    }

    /// In the menu's order.
    public static func < (lhs: JournalClass, rhs: JournalClass) -> Bool {
        (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
    }
}

/// The filter bar's chips: each one sets one parameter of the read.
public enum JournalFilter: String, CaseIterable, Identifiable, Equatable {
    case repo, epic, classes, everything

    public var id: String { rawValue }

    /// The read's parameter the chip sets.
    public var parameter: String {
        switch self {
        case .repo: "repo"
        case .epic: "epic"
        case .classes: "classes"
        case .everything: "notable"
        }
    }

    public var title: String {
        switch self {
        case .repo: "Repo"
        case .epic: "Epic"
        case .classes: "Class"
        case .everything: "Everything"
        }
    }
}

/// What the filter bar asks the read for.
public struct JournalQuery: Equatable {
    /// A repository's key; nil reads the window's scope.
    public var repo: String?
    /// An epic's identifier: its own events and its sub-tickets'.
    public var epic: String?
    /// The classes kept; empty keeps every class.
    public var classes: Set<JournalClass>
    /// Every event, not only the notable ones.
    public var everything: Bool
    /// The reports alone (TP-1462), without the events: it changes what the page shows, not what it reads.
    public var reportsOnly: Bool

    /// A page of the read: the most the read serves.
    public static let pageSize = 200
    public static let path = "api/v1/events"

    public init(repo: String? = nil, epic: String? = nil, classes: Set<JournalClass> = [], everything: Bool = false, reportsOnly: Bool = false) {
        self.repo = repo
        self.epic = epic
        self.classes = classes
        self.everything = everything
        self.reportsOnly = reportsOnly
    }

    /// Whether `other` reads the same pages: Reports only reads nothing of its own.
    public func readsAsTheSame(_ other: JournalQuery) -> Bool {
        var other = other
        other.reportsOnly = reportsOnly
        return self == other
    }

    public static let reportsOnlyTitle = "Reports only"
    public static let reportsOnlyHelp = "Show the reports alone, without the events"

    /// The read's parameters, in a fixed order: `classes`, `epic`, `limit`, `notable`, `repo`, `until`. The repo chip
    /// wins over the window's `scope`. Everything sends `notable=false`: the read keeps the notable ones by default.
    public func parameters(scope: OverviewScope = .all, until: String? = nil) -> [(name: String, value: String)] {
        var parameters: [(name: String, value: String)] = []
        if !classes.isEmpty { parameters.append(("classes", classes.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue).joined(separator: ","))) }
        if let epic { parameters.append(("epic", epic)) }
        parameters.append(("limit", String(Self.pageSize)))
        parameters.append(("notable", everything ? "false" : "true"))
        if let repo = repo ?? scope.stored { parameters.append(("repo", repo)) }
        if let until { parameters.append(("until", until)) }
        return parameters
    }

    /// The read of the newest page, or of the page before `until`.
    public func path(scope: OverviewScope = .all, until: String? = nil) -> String {
        Self.path + "?" + parameters(scope: scope, until: until).map { "\($0.name)=\(Self.encode($0.value))" }.joined(separator: "&")
    }

    /// The chip's words: "Repo: All repos", "Epic: TP-1381", "Class: Verdicts +2"; nil for the Everything switch.
    public func chipText(_ filter: JournalFilter) -> String? {
        switch filter {
        case .repo: return "Repo: " + (repo ?? OverviewScope.allTitle)
        case .epic: return "Epic: " + (epic ?? Self.allEpics)
        case .classes:
            let sorted = classes.sorted()
            guard let first = sorted.first else { return "Class: " + Self.allClasses }
            return "Class: " + first.title + (sorted.count > 1 ? " +\(sorted.count - 1)" : "")
        case .everything: return nil
        }
    }

    /// Whether the chip narrows the read.
    public func isSet(_ filter: JournalFilter) -> Bool {
        switch filter {
        case .repo: repo != nil
        case .epic: epic != nil
        case .classes: !classes.isEmpty
        case .everything: everything
        }
    }

    /// Whether any chip narrows the read beyond the notable events.
    public var narrows: Bool { repo != nil || epic != nil || !classes.isEmpty }

    /// Turns `value` on or off in the Class chip.
    public mutating func toggle(_ value: JournalClass) {
        if classes.contains(value) { classes.remove(value) } else { classes.insert(value) }
    }

    public static let allEpics = "All epics"
    public static let allClasses = "All classes"

    /// Percent-encodes a value: `+` would read as a space, and `until`'s time zone holds one.
    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~:,"))
}

/// A page of the read across tickets: each event the ticket feed's, with its ticket, class, whether it is notable and
/// who did it.
public struct JournalPayload: Equatable {
    /// The ticket an event is on; every field nil on Symphony's own stream (its pauses and questions).
    public struct Ticket: Decodable, Equatable {
        public var repoKey: String?
        public var identifier: String?
        public var title: String?

        public init(repoKey: String? = nil, identifier: String? = nil, title: String? = nil) {
            self.repoKey = repoKey
            self.identifier = identifier
            self.title = title
        }
    }

    /// Who did it: `symphony`, `rule` (its name), `person` (the Director) or `run` (its kind, and its run).
    public struct By: Decodable, Equatable {
        public var kind: String?
        public var name: String?
        public var runId: String?

        public init(kind: String? = nil, name: String? = nil, runId: String? = nil) {
            self.kind = kind
            self.name = name
            self.runId = runId
        }
    }

    public struct Event: Equatable, Identifiable {
        public var event: TicketEventsPayload.Event
        public var ticket: Ticket
        /// The read's class: `verdict`, `move`, … `other`.
        public var eventClass: String?
        public var notable: Bool
        public var by: By?

        public var id: String { event.id }

        public init(event: TicketEventsPayload.Event, ticket: Ticket = Ticket(), eventClass: String? = nil, notable: Bool = true, by: By? = nil) {
            self.event = event
            self.ticket = ticket
            self.eventClass = eventClass
            self.notable = notable
            self.by = by
        }
    }

    public var events: [Event]
    /// The `until` the page before passes; nil on the last page.
    public var nextUntil: String?

    public init(events: [Event], nextUntil: String? = nil) {
        self.events = events
        self.nextUntil = nextUntil
    }

    /// A page of the read, nil when it isn't one.
    public static func decode(_ data: Data) -> JournalPayload? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let page = try? decoder.decode(Page.self, from: data) else { return nil }
        return JournalPayload(events: page.events.compactMap(\.event), nextUntil: page.nextUntil)
    }

    private struct Page: Decodable {
        let events: [Entry]
        let nextUntil: String?
    }

    /// An event of the page; one that doesn't read (no id) is skipped, not the page.
    private struct Entry: Decodable {
        let event: Event?

        enum CodingKeys: String, CodingKey {
            case ticket, `class`, notable, by
        }

        init(from decoder: Decoder) throws {
            guard let event = try? TicketEventsPayload.Event(from: decoder) else {
                self.event = nil
                return
            }
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            self.event = Event(
                event: event,
                ticket: ((try? container?.decodeIfPresent(Ticket.self, forKey: .ticket)) ?? nil) ?? Ticket(),
                eventClass: (try? container?.decodeIfPresent(String.self, forKey: .class)) ?? nil,
                notable: ((try? container?.decodeIfPresent(Bool.self, forKey: .notable)) ?? nil) ?? true,
                by: (try? container?.decodeIfPresent(By.self, forKey: .by)) ?? nil
            )
        }
    }
}

/// The pages read so far under one query, newest first: the newest page read again adds what is new and keeps the
/// earlier pages Show Earlier read; Show Earlier adds the page before the oldest.
public struct JournalFeed: Equatable {
    public private(set) var events: [JournalPayload.Event] = []
    /// The `until` Show Earlier reads; nil once the oldest page is in.
    public private(set) var nextUntil: String?
    /// Whether a page came in yet.
    public private(set) var loaded = false

    public init() {}

    public var canShowEarlier: Bool { nextUntil != nil }

    /// The newest page: the first one sets where the earlier pages start; a later one adds the events that are new.
    public mutating func takeNewest(_ page: JournalPayload) {
        if !loaded { nextUntil = page.nextUntil }
        loaded = true
        merge(page.events)
    }

    /// The page before the oldest one held.
    public mutating func takeEarlier(_ page: JournalPayload) {
        loaded = true
        nextUntil = page.nextUntil
        merge(page.events)
    }

    private mutating func merge(_ incoming: [JournalPayload.Event]) {
        var byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for event in incoming { byID[event.id] = event }
        events = byID.values.sorted(by: Self.newerFirst)
    }

    /// Newest first: by when it happened, then by Symphony's order, then by id, as the read pages them.
    static func newerFirst(_ lhs: JournalPayload.Event, _ rhs: JournalPayload.Event) -> Bool {
        let left = lhs.event.at.flatMap(TicketPage.date) ?? .distantPast
        let right = rhs.event.at.flatMap(TicketPage.date) ?? .distantPast
        if left != right { return left > right }
        if let l = lhs.event.seq, let r = rhs.event.seq, l != r { return l > r }
        return lhs.id > rhs.id
    }
}

/// One row of the Journal: the Timeline entry it draws as, the ticket's chip and where the chip opens.
public struct JournalRow: Equatable, Identifiable {
    public var entry: TimelineEntry
    public var ticket: JournalPayload.Ticket
    /// The ticket page's event the chip opens at; nil on Symphony's own stream or a ticket Symphony keeps no record of.
    public var focus: TimelineFocus?

    public var id: String { entry.id }

    /// The chip's identifier: the ticket's, or "Symphony" on its own stream.
    public var chipIdentifier: String { ticket.identifier ?? (ticket.repoKey ?? JournalModel.symphonyStream) }

    /// The chip for VoiceOver and its help: "Open TP-1401, The situation read model, at this event".
    public var chipLabel: String {
        guard focus != nil else { return chipIdentifier }
        return "Open " + [chipIdentifier, ticket.title].compactMap { $0 }.joined(separator: ", ") + ", at this event"
    }
}

/// One day of the Journal, newest first, under its separator: its events, and the reports whose period ends that day,
/// each pinned among the events at the end of its period (TP-1462).
public struct JournalDay: Equatable, Identifiable {
    /// An event's row or a report's card.
    public enum Item: Equatable, Identifiable {
        case event(JournalRow)
        case report(JournalReportCard)

        public var id: String {
            switch self {
            case let .event(row): "event:" + row.id
            case let .report(card): "report:" + card.id
            }
        }

        /// When it sits in the day: the event's time, the end of the report's period.
        public var at: Date {
            switch self {
            case let .event(row): row.entry.at
            case let .report(card): card.at
            }
        }
    }

    /// "2026-11-09".
    public var id: String
    /// "Today", "Yesterday", else nil.
    public var relative: String?
    /// "Mon 9 Nov".
    public var date: String
    /// Newest first.
    public var items: [Item]

    public init(id: String, relative: String?, date: String, items: [Item]) {
        self.id = id
        self.relative = relative
        self.date = date
        self.items = items
    }

    public init(id: String, relative: String?, date: String, rows: [JournalRow]) {
        self.init(id: id, relative: relative, date: date, items: rows.map(Item.event))
    }

    /// The events' rows.
    public var rows: [JournalRow] {
        items.compactMap { item in
            if case let .event(row) = item { return row }
            return nil
        }
    }

    /// The reports' cards.
    public var reports: [JournalReportCard] {
        items.compactMap { item in
            if case let .report(card) = item { return card }
            return nil
        }
    }

    /// "Today, Mon 9 Nov".
    public var title: String { [relative, date].compactMap { $0 }.joined(separator: ", ") }

    /// "Today, Mon 9 Nov, 12 events", with ", 1 report" when it holds one.
    public var accessibilityLabel: String {
        let reports = reports.count
        return title + ", " + (rows.count == 1 ? "1 event" : "\(rows.count) events")
            + (reports == 0 ? "" : reports == 1 ? ", 1 report" : ", \(reports) reports")
    }
}

/// The Journal as it draws: its days and whether there are earlier pages.
public struct JournalModel: Equatable {
    public var days: [JournalDay]
    public var canShowEarlier: Bool

    public init(days: [JournalDay], canShowEarlier: Bool = false) {
        self.days = days
        self.canShowEarlier = canShowEarlier
    }

    public var isEmpty: Bool { days.isEmpty }
    public var rows: [JournalRow] { days.flatMap(\.rows) }
    public var reports: [JournalReportCard] { days.flatMap(\.reports) }

    public static let symphonyStream = "Symphony"
    public static let showEarlier = "Show Earlier"
    public static let empty = "Nothing notable has happened yet."
    public static let emptyEverything = "Nothing has happened yet."
    public static let noMatch = "No events match these filters."
    public static let noReport = "No report has been published yet."

    /// What the page says with nothing to show: no report under Reports only, the filters keep nothing, or nothing
    /// happened.
    public static func emptyTitle(_ query: JournalQuery) -> String {
        if query.reportsOnly { return noReport }
        if query.narrows { return noMatch }
        return query.everything ? emptyEverything : empty
    }

    /// `feed`'s events and the `reports` cut into days by `calendar`, newest first, each report pinned among the
    /// events at the end of its period; `reference` says which is today. A report older than the pages read waits for
    /// Show Earlier to read its events. Reports only keeps the reports alone.
    public static func build(
        _ feed: JournalFeed, reports: [JournalReportCard] = [], reportsOnly: Bool = false, reference: Date, calendar: Calendar
    ) -> JournalModel {
        let rows: [JournalDay.Item] = reportsOnly ? [] : feed.events.compactMap { event in
            event.event.at.flatMap(TicketPage.date).map { .event(row(event, at: $0)) }
        }
        let oldest = feed.events.last?.event.at.flatMap(TicketPage.date)
        let cards = reports
            .filter { card in !feed.canShowEarlier || oldest.map { card.at >= $0 } ?? true }
            .sorted { $0.at > $1.at }
        var days: [JournalDay] = []
        for item in pinned(cards, among: rows) {
            let id = TimelineModel.dayID(item.at, calendar)
            if let index = days.firstIndex(where: { $0.id == id }) {
                days[index].items.append(item)
            } else {
                days.append(JournalDay(
                    id: id, relative: TimelineModel.relative(item.at, reference: reference, calendar: calendar),
                    date: TimelineModel.dayDate(item.at, calendar), items: [item]
                ))
            }
        }
        return JournalModel(days: days, canShowEarlier: feed.canShowEarlier)
    }

    /// The rows, newest first, with each card (newest first) above the first row older than the end of its period:
    /// the events at or after that end came after the report's period.
    static func pinned(_ cards: [JournalReportCard], among rows: [JournalDay.Item]) -> [JournalDay.Item] {
        var items: [JournalDay.Item] = []
        var cards = cards[...]
        for row in rows {
            while let card = cards.first, card.at > row.at {
                items.append(.report(card))
                cards = cards.dropFirst()
            }
            items.append(row)
        }
        return items + cards.map(JournalDay.Item.report)
    }

    /// The row of `event`: the Timeline's class and glyph, what happened, who did it, and its ticket's chip.
    static func row(_ event: JournalPayload.Event, at: Date) -> JournalRow {
        let source = event.event
        let entry = TimelineEntry(
            id: source.id, kind: kind(source), at: at, title: title(source), detail: source.summary?.detail?.trimmedNonEmpty,
            actor: actor(event)
        )
        let focus = event.ticket.identifier.map { TimelineFocus(identifier: $0, eventID: source.id, runID: source.runID ?? event.by?.runId) }
        return JournalRow(entry: entry, ticket: event.ticket, focus: focus)
    }

    /// The Timeline's class of `event`; a pause set reads as a pause, its clear as a pause cleared.
    static func kind(_ event: TicketEventsPayload.Event) -> TimelineEntry.Kind {
        if TimelineModel.pauseSlot(event.type) != nil || event.type == "park.backfilled" {
            return ["pause.cleared", "hold.cleared", "pause.reason_cleared"].contains(event.type) ? .pauseCleared : .pause
        }
        return TimelineModel.kind(event)
    }

    /// What happened: the event's summary; a `rule.action` without one names its rule and what it did.
    static func title(_ event: TicketEventsPayload.Event) -> String {
        if let title = event.summary?.title?.trimmedNonEmpty { return title }
        if event.type == "rule.action" {
            return (event.payload.rule?.trimmedNonEmpty ?? "A rule") + " " + ruleDid(event.payload.action)
        }
        return event.type
    }

    /// What a rule did, in the words its row says.
    static func ruleDid(_ action: String?) -> String {
        switch action {
        case "rerun": "reran the failed checks"
        case "paused": "paused the ticket"
        case "parked": "parked the ticket"
        case "filed_ticket": "filed a fix ticket"
        case "lifted_pause": "lifted a pause"
        case "moved": "moved the ticket"
        case "updated_branch": "updated the branch"
        case "auto_merge": "turned on auto-merge"
        case "asked": "asked a question"
        default: "acted on the ticket"
        }
    }

    /// Who did it, as the Timeline names them: "Rule: CI wait", a person, "Implementation run", "Symphony".
    static func actor(_ event: JournalPayload.Event) -> String {
        guard let by = event.by else { return TimelineModel.actor(event.event, history: TicketEventsPayload()) }
        let name = by.name?.trimmedNonEmpty
        switch by.kind {
        case "rule": return "Rule: " + (name ?? "a rule")
        case "person": return name ?? TimelineModel.you
        case "run": return TicketEventsPayload.runTitle(kind: name, number: nil)
        default: return TimelineModel.symphony
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingWhitespace()
        return trimmed.isEmpty ? nil : trimmed
    }
}
