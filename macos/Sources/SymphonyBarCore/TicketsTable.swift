import Foundation

// Work › Tickets as the table with filters (TP-1456): the ticket entity's columns as the server's catalog names them
// (`GET /api/v1/views`' `columns`), a filter chip per filterable column, the columns shown and the sort, all sent as
// `GET /api/v1/tickets`' query (`docs/control-api.md` § "The column catalog"). The server filters and sorts; the
// table shows the rows it returns, and the search field narrows them by identifier and title.

/// A column of the ticket entity's catalog: its name in the API, its type and what it holds.
public struct TicketColumn: Equatable, Hashable, Identifiable {
    public var name: String
    public var type: String
    public var description: String

    public var id: String { name }

    public init(name: String, type: String, description: String = "") {
        self.name = name
        self.type = type
        self.description = description
    }

    /// The header the table gives it: "Age" for `created_at`, which the table shows as an age.
    public var title: String {
        Self.titles[name] ?? name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// A time column shows as an age ("3 days"), so its ascending order is the youngest first: the server's `desc`.
    public var isTime: Bool { type == "time" }

    private static let titles = [
        "identifier": "Ticket", "title": "Title", "repo": "Repo", "epic": "Epic", "phase": "Phase", "situation": "Situation",
        "situation_since": "In situation", "labels": "Labels", "priority": "Priority", "assignee": "Assignee", "url": "Link",
        "created_at": "Age", "phase_at": "In phase", "updated_at": "Updated",
    ]

    /// The catalog as `docs/control-api.md` lists it, for a Symphony whose views read doesn't answer.
    public static let catalog: [TicketColumn] = [
        TicketColumn(name: "identifier", type: "identifier", description: "The ticket's identifier."),
        TicketColumn(name: "title", type: "string", description: "The ticket's title."),
        TicketColumn(name: "repo", type: "string", description: "The key of the repository the ticket lives in."),
        TicketColumn(name: "epic", type: "identifier", description: "The identifier of the epic the ticket is a sub-ticket of."),
        TicketColumn(name: "phase", type: "string", description: "The phase (state) the ticket is in."),
        TicketColumn(name: "situation", type: "situation", description: "The kind of the ticket's situation."),
        TicketColumn(name: "situation_since", type: "time", description: "Since when the ticket's situation holds."),
        TicketColumn(name: "labels", type: "list", description: "The ticket's labels."),
        TicketColumn(name: "priority", type: "integer", description: "Linear's priority: 0 none, 1 urgent, 2 high, 3 medium, 4 low."),
        TicketColumn(name: "assignee", type: "string", description: "Who the ticket is assigned to."),
        TicketColumn(name: "url", type: "string", description: "The ticket's page in Linear."),
        TicketColumn(name: "created_at", type: "time", description: "When the ticket was created."),
        TicketColumn(name: "phase_at", type: "time", description: "When the ticket entered its phase."),
        TicketColumn(name: "updated_at", type: "time", description: "When Symphony last wrote the ticket's record."),
    ]

    /// The columns the table opens with.
    public static let defaultColumns = ["identifier", "title", "repo", "epic", "situation", "priority", "labels", "created_at"]

    /// The columns every read asks for besides the ones shown: the row's menu needs the repo and the phase, the search
    /// the identifier and the title, and the filters' menus learn their values from the epic and the labels.
    public static let alwaysRead = ["identifier", "title", "repo", "phase", "epic", "labels"]

    /// The catalog in `GET /api/v1/views`' answer, nil when it isn't one.
    public static func catalog(fromViews data: Data) -> [TicketColumn]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], root["error"] == nil,
              let columns = root["columns"] as? [[String: Any]]
        else { return nil }
        let read = columns.compactMap(column)
        return read.isEmpty ? nil : read
    }

    static func column(_ entry: [String: Any]) -> TicketColumn? {
        guard let name = entry["name"] as? String, let type = entry["type"] as? String else { return nil }
        return TicketColumn(name: name, type: type, description: entry["description"] as? String ?? "")
    }
}

/// A filter of the catalog, by its name in the query.
public enum TicketFilter: String, CaseIterable, Identifiable {
    case epic, repo, phase, situation, label, priority, since

    public var id: String { rawValue }

    /// "Epic", "Updated": the chip's first word and the Add Filter menu's item.
    public var title: String {
        switch self {
        case .epic: "Epic"
        case .repo: "Repo"
        case .phase: "Phase"
        case .situation: "Situation"
        case .label: "Label"
        case .priority: "Priority"
        case .since: "Updated"
        }
    }

    /// The catalog's column it reads.
    public var column: String {
        switch self {
        case .label: "labels"
        case .since: "updated_at"
        default: rawValue
        }
    }

    /// Whether the chip holds one value, picked in place of the last; the others hold any number.
    public var isSingle: Bool { self == .since }

    /// How the chip writes `value`: a kind's word, a priority's name, a time window's words, or the value itself.
    public func word(_ value: String) -> String {
        switch self {
        case .situation: DesignTokens.SituationKind(apiKind: value)?.word ?? value
        case .priority: Int(value).map(TicketsRow.priorityName) ?? value
        case .since: TicketTimeWindow(rawValue: value)?.title ?? value
        default: value
        }
    }
}

/// The time windows the Updated chip offers: the tickets whose record was written within it.
public enum TicketTimeWindow: String, CaseIterable {
    case hour, day, week, month

    public var title: String {
        switch self {
        case .hour: "in the last hour"
        case .day: "in the last 24 hours"
        case .week: "in the last 7 days"
        case .month: "in the last 30 days"
        }
    }

    public var seconds: TimeInterval {
        switch self {
        case .hour: 3_600
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        }
    }
}

/// One filter set: its values, any of which lets a ticket through.
public struct TicketFilterChip: Equatable, Identifiable {
    public var filter: TicketFilter
    public var values: [String]

    public var id: String { filter.rawValue }

    public init(filter: TicketFilter, values: [String]) {
        self.filter = filter
        self.values = values
    }

    /// What the chip reads: "Epic is TP-1400", "Situation is Waiting for CI or Working", "Updated in the last 24 hours".
    public var text: String {
        let words = values.map(filter.word)
        if filter == .since { return "\(filter.title) \(words.joined())" }
        return "\(filter.title) is \(Self.either(words))"
    }

    /// Its × button's name for VoiceOver.
    public var removeLabel: String { "Remove filter \(text)" }

    /// Its query parameter: the filter's name and its values, comma-separated; the time window as the ISO 8601 time it
    /// starts at, from `now`.
    public func parameter(now: Date) -> URLQueryItem {
        if filter == .since {
            let window = values.first.flatMap(TicketTimeWindow.init(rawValue:)) ?? .day
            let formatter = ISO8601DateFormatter()
            return URLQueryItem(name: filter.rawValue, value: formatter.string(from: now.addingTimeInterval(-window.seconds)))
        }
        return URLQueryItem(name: filter.rawValue, value: values.joined(separator: ","))
    }

    static func either(_ words: [String]) -> String {
        switch words.count {
        case 0: ""
        case 1: words[0]
        case 2: "\(words[0]) or \(words[1])"
        default: words.dropLast().joined(separator: ", ") + " or " + words[words.count - 1]
        }
    }
}

/// The table's sort as its header shows it: a column, ascending or not.
public struct TicketSort: Equatable {
    public var column: String
    public var ascending: Bool

    public init(column: String, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }

    /// The server's `direction`: a time column shows as an age, so its ascending ages are its descending times.
    public func direction(isTime: Bool) -> String {
        ascending != isTime ? "asc" : "desc"
    }

    public static let `default` = TicketSort(column: "identifier")
}

/// What the Tickets table asks the server for: the chips, the columns shown and the sort.
public struct TicketsQuery: Equatable {
    public var chips: [TicketFilterChip]
    public var columns: [String]
    public var sort: TicketSort

    public init(chips: [TicketFilterChip] = [], columns: [String] = TicketColumn.defaultColumns, sort: TicketSort = .default) {
        self.chips = chips
        self.columns = columns
        self.sort = sort
    }

    public func chip(_ filter: TicketFilter) -> TicketFilterChip? {
        chips.first { $0.filter == filter }
    }

    /// Whether the chip of `filter` holds `value`.
    public func holds(_ filter: TicketFilter, _ value: String) -> Bool {
        chip(filter)?.values.contains(value) ?? false
    }

    /// Adds `value` to the chip of `filter`, adding the chip when there is none, or takes it out when the chip holds it;
    /// a chip left without values goes. A single-value chip takes the value in place of its own.
    public mutating func toggle(_ filter: TicketFilter, _ value: String) {
        guard let index = chips.firstIndex(where: { $0.filter == filter }) else {
            chips.append(TicketFilterChip(filter: filter, values: [value]))
            return
        }
        if chips[index].values.contains(value) {
            chips[index].values.removeAll { $0 == value }
            if chips[index].values.isEmpty { chips.remove(at: index) }
        } else if filter.isSingle {
            chips[index].values = [value]
        } else {
            chips[index].values.append(value)
        }
    }

    /// The chip's ×.
    public mutating func remove(_ filter: TicketFilter) {
        chips.removeAll { $0.filter == filter }
    }

    /// Shows or hides the column `name`, keeping the catalog's order; the identifier always shows.
    public mutating func setColumn(_ name: String, shown: Bool, catalog: [TicketColumn] = TicketColumn.catalog) {
        guard name != "identifier" else { return }
        var names = Set(columns)
        if shown { names.insert(name) } else { names.remove(name) }
        columns = catalog.map(\.name).filter(names.contains)
    }

    /// The repo the rows are narrowed to, one only: the Repo chip's single value, or the window's scope.
    public func repo(scope: OverviewScope) -> String? {
        if let chip = chip(.repo) { return chip.values.count == 1 ? chip.values[0] : nil }
        if case let .repo(key) = scope { return key }
        return nil
    }

    /// The columns the table draws, in the catalog's order: the Repo column hides while one repo is filtered, as every
    /// row would read the same.
    public func shownColumns(catalog: [TicketColumn], scope: OverviewScope) -> [TicketColumn] {
        let hidesRepo = repo(scope: scope) != nil
        return catalog.filter { columns.contains($0.name) && !(hidesRepo && $0.name == "repo") }
    }

    /// The query string: each chip's parameter in the catalog's filter order (the window's repo scope when there is no
    /// Repo chip), the columns to read, the sort and its direction.
    public func queryItems(scope: OverviewScope, catalog: [TicketColumn] = TicketColumn.catalog, now: Date) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        for filter in TicketFilter.allCases {
            if let chip = chip(filter) {
                items.append(chip.parameter(now: now))
            } else if filter == .repo, case let .repo(key) = scope {
                items.append(URLQueryItem(name: "repo", value: key))
            }
        }
        let known = Set(catalog.map(\.name))
        let read = catalog.map(\.name).filter { TicketColumn.alwaysRead.contains($0) || columns.contains($0) }
        items.append(URLQueryItem(name: "columns", value: (read.isEmpty ? TicketColumn.alwaysRead : read).joined(separator: ",")))
        let order = known.contains(sort.column) ? sort : .default
        let isTime = catalog.first { $0.name == order.column }?.isTime ?? false
        items.append(URLQueryItem(name: "sort", value: order.column))
        items.append(URLQueryItem(name: "direction", value: order.direction(isTime: isTime)))
        return items
    }

    /// `GET /api/v1/tickets` with the query.
    public func path(scope: OverviewScope, catalog: [TicketColumn] = TicketColumn.catalog, now: Date) -> String {
        var components = URLComponents()
        components.queryItems = queryItems(scope: scope, catalog: catalog, now: now)
        return TicketsPayload.path + "?" + (components.percentEncodedQuery ?? "")
    }
}

/// A value of a row's column, as the server sent it.
public enum TicketValue: Equatable {
    case text(String)
    case number(Int)
    case list([String])
    case time(Date)
}

/// A row of `GET /api/v1/tickets`: the ticket's issue id and the columns asked for.
public struct TicketsRow: Equatable, Identifiable {
    public var issueID: String?
    public var identifier: String
    public var values: [String: TicketValue]

    public var id: String { identifier }

    public init(issueID: String? = nil, identifier: String, values: [String: TicketValue]) {
        self.issueID = issueID
        self.identifier = identifier
        self.values = values
    }

    public func text(_ column: String) -> String? {
        if case let .text(value)? = values[column] { return value }
        return nil
    }

    public func list(_ column: String) -> [String] {
        if case let .list(value)? = values[column] { return value }
        return []
    }

    public func time(_ column: String) -> Date? {
        if case let .time(value)? = values[column] { return value }
        return nil
    }

    public func number(_ column: String) -> Int? {
        if case let .number(value)? = values[column] { return value }
        return nil
    }

    public var title: String { text("title") ?? "" }
    public var repoKey: String? { text("repo") }
    public var phase: String? { text("phase") }
    public var epic: String? { text("epic") }
    public var labels: [String] { list("labels") }
    public var url: URL? { text("url").flatMap(URL.init(string:)) }

    /// The situation's kind, nil when the read didn't ask for it.
    public var situationKind: DesignTokens.SituationKind? {
        text("situation").flatMap(DesignTokens.SituationKind.init(apiKind:))
    }

    /// The row's situation as a line: the state's own for a ticket Symphony tracks (`tracked`), or one of the server's
    /// kind since its `situation_since`.
    public func situation(tracked: Situation?) -> Situation? {
        if let tracked, situationKind == nil || tracked.kind == situationKind { return tracked }
        return situationKind.map { Situation(kind: $0, cause: "", since: time("situation_since")) }
    }

    /// What a cell of `column` reads, measured against `reference` for an age: "3 days", "Urgent", "agent, backend".
    public func cell(_ column: TicketColumn, reference: Date) -> String {
        switch values[column.name] {
        case let .text(value)?:
            column.name == "situation" ? DesignTokens.SituationKind(apiKind: value)?.word ?? value : value
        case let .number(value)?:
            column.name == "priority" ? Self.priorityName(value) : "\(value)"
        case let .list(value)?:
            value.joined(separator: ", ")
        case let .time(value)?:
            Overview.duration(Int(reference.timeIntervalSince(value)))
        case nil:
            ""
        }
    }

    /// Linear's priority by its number: 0 none, 1 urgent, 2 high, 3 medium, 4 low.
    public static func priorityName(_ value: Int) -> String {
        switch value {
        case 1: TicketPriority.urgent.title
        case 2: TicketPriority.high.title
        case 3: TicketPriority.medium.title
        case 4: TicketPriority.low.title
        default: TicketPriority.none.title
        }
    }

    /// Whether the search field's `text` finds it: in its identifier or its title, in any case.
    public func matches(_ search: String) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return identifier.localizedCaseInsensitiveContains(needle) || title.localizedCaseInsensitiveContains(needle)
    }

    /// The inspector's facts for a ticket the state doesn't list: each column read, by its header.
    public func facts(columns: [TicketColumn], reference: Date) -> [TicketList.Fact] {
        columns.filter { $0.name != "identifier" && $0.name != "title" }.compactMap { column in
            let value = cell(column, reference: reference)
            return value.isEmpty ? nil : TicketList.Fact(label: column.title, value: value)
        }
    }
}

/// `GET /api/v1/tickets`' answer: the columns it read, the rows in the server's order, and why the situations come
/// from the records alone when the orchestrator couldn't answer.
public struct TicketsPayload: Equatable {
    public static let path = "api/v1/tickets"
    public static let viewsPath = "api/v1/views"

    public var columns: [TicketColumn]
    public var rows: [TicketsRow]
    public var count: Int
    public var error: String?

    public init(columns: [TicketColumn], rows: [TicketsRow], count: Int? = nil, error: String? = nil) {
        self.columns = columns
        self.rows = rows
        self.count = count ?? rows.count
        self.error = error
    }

    /// The rows the search field finds.
    public func rows(matching search: String) -> [TicketsRow] {
        rows.filter { $0.matches(search) }
    }

    /// The answer in `data`, nil when it isn't one (an error, or not JSON).
    public static func decode(_ data: Data) -> TicketsPayload? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tickets = root["tickets"] as? [[String: Any]]
        else { return nil }
        // A refusal is an error object; a snapshot the server couldn't read is a code beside the rows.
        if root["error"] is [String: Any] { return nil }
        let columns = (root["columns"] as? [[String: Any]])?.compactMap(TicketColumn.column) ?? []
        let types = Dictionary(columns.map { ($0.name, $0.type) }, uniquingKeysWith: { first, _ in first })
        let rows = tickets.compactMap { row(from: $0, types: types) }
        return TicketsPayload(columns: columns, rows: rows, count: root["count"] as? Int, error: root["error"] as? String)
    }

    static func row(from entry: [String: Any], types: [String: String]) -> TicketsRow? {
        guard let identifier = entry["identifier"] as? String else { return nil }
        var values: [String: TicketValue] = [:]
        for (name, raw) in entry where name != "issue_id" {
            if let value = value(raw, type: types[name] ?? TicketColumn.catalog.first { $0.name == name }?.type) {
                values[name] = value
            }
        }
        return TicketsRow(issueID: entry["issue_id"] as? String, identifier: identifier, values: values)
    }

    static func value(_ raw: Any, type: String?) -> TicketValue? {
        switch raw {
        case let text as String where type == "time":
            return Self.time(text).map(TicketValue.time)
        case let text as String:
            return .text(text)
        case let number as Int:
            return .number(number)
        case let list as [Any]:
            return .list(list.compactMap { $0 as? String })
        default:
            return nil
        }
    }

    static func time(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// The values each filter's menu offers: the situation kinds, the priorities and the time windows always, and the
/// repos, epics, phases and labels the rows read this session.
public struct TicketFilterValues: Equatable {
    private var seen: [TicketFilter: Set<String>] = [:]

    public init() {}

    /// Keeps the repos, epics, phases and labels of `rows`, and the window's `repos`.
    public mutating func learn(_ rows: [TicketsRow], repos: [String] = []) {
        for row in rows {
            if let repo = row.repoKey { seen[.repo, default: []].insert(repo) }
            if let epic = row.epic { seen[.epic, default: []].insert(epic) }
            if let phase = row.phase { seen[.phase, default: []].insert(phase) }
            seen[.label, default: []].formUnion(row.labels)
        }
        seen[.repo, default: []].formUnion(repos)
    }

    /// The values the menu of `filter` lists, with the ones `query` holds.
    public func values(_ filter: TicketFilter, query: TicketsQuery = TicketsQuery()) -> [String] {
        switch filter {
        case .situation: return DesignTokens.SituationKind.allCases.map(\.apiKind)
        case .priority: return ["1", "2", "3", "4", "0"]
        case .since: return TicketTimeWindow.allCases.map(\.rawValue)
        default:
            let held = query.chip(filter)?.values ?? []
            return seen[filter, default: []].union(held).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }
}

extension TicketList.Row {
    /// A ticket the state doesn't list, as the server's columns read it, for the drawer and the row's menu: its
    /// situation from the server's kind, its facts each column read.
    public init(_ row: TicketsRow, columns: [TicketColumn], reference: Date) {
        self.init(
            identifier: row.identifier, issueID: row.issueID, title: row.text("title"), repoKey: row.repoKey, state: row.phase,
            stage: TicketList.Stage(kind: row.situationKind), situation: row.situation(tracked: nil), waitsOn: "nothing",
            since: row.time("situation_since"), forced: false, needsAttention: false, url: row.url,
            facts: row.facts(columns: columns, reference: reference)
        )
    }
}

extension TicketList.Stage {
    /// The stage a situation kind reads as: queued for a ticket that waits on something other than you.
    public init(kind: DesignTokens.SituationKind?) {
        switch kind {
        case .working?, .ci?, .build?: self = .working
        case .you?: self = .waitingOnYou
        case .done?: self = .shipped
        default: self = .queued
        }
    }
}
