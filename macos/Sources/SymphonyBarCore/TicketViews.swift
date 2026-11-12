import Foundation

// Saved views on Work › Tickets (TP-1457): the chips, columns and sort in force kept under a name on the server
// (`GET /api/v1/views`, `POST /api/v1/control/view`, `DELETE /api/v1/control/view/:id`, `docs/control-api.md`
// § "Saved views and the tickets read"), so every client lists the same views. "All open", the table as it opens,
// is built in: always first, never renamed or deleted.

/// A saved view: its id, its name and the query it keeps.
public struct TicketView: Equatable, Identifiable {
    public var id: String
    public var name: String
    public var query: TicketsQuery
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(id: String, name: String, query: TicketsQuery, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.query = query
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The views of `GET /api/v1/views`' answer in its order (by name), nil when it isn't one.
    public static func views(fromViews data: Data, catalog: [TicketColumn] = TicketColumn.catalog) -> [TicketView]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], root["error"] == nil,
              let views = root["views"] as? [[String: Any]]
        else { return nil }
        return views.compactMap { view($0, catalog: catalog) }
    }

    /// A view as the server writes it: its filters by the filter's name, a priority as an integer and `since` as the
    /// ISO 8601 time it starts at, read back as the time window it was saved with.
    static func view(_ entry: [String: Any], catalog: [TicketColumn]) -> TicketView? {
        guard let id = entry["id"] as? String, let name = entry["name"] as? String else { return nil }
        let createdAt = (entry["created_at"] as? String).flatMap(TicketsPayload.time)
        let updatedAt = (entry["updated_at"] as? String).flatMap(TicketsPayload.time)
        let savedAt = updatedAt ?? createdAt ?? Date()
        let filters = (entry["filters"] as? [[String: Any]]) ?? []
        var chips: [TicketFilterChip] = []
        for filter in filters {
            guard let kind = (filter["column"] as? String).flatMap(TicketFilter.init(rawValue:)) else { continue }
            let values = Self.values(filter["value"], filter: kind, savedAt: savedAt)
            if !values.isEmpty { chips.append(TicketFilterChip(filter: kind, values: values)) }
        }
        let names = (entry["columns"] as? [String]) ?? TicketColumn.defaultColumns
        let columns = catalog.map(\.name).filter(names.contains)
        let sortEntry = entry["sort"] as? [String: Any]
        let column = sortEntry?["column"] as? String ?? TicketSort.default.column
        let isTime = catalog.first { $0.name == column }?.isTime ?? false
        let ascending = ((sortEntry?["direction"] as? String ?? "asc") == "asc") != isTime
        let query = TicketsQuery(chips: chips, columns: columns.isEmpty ? TicketColumn.defaultColumns : columns,
                                 sort: TicketSort(column: column, ascending: ascending))
        return TicketView(id: id, name: name, query: query, createdAt: createdAt, updatedAt: updatedAt)
    }

    static func values(_ raw: Any?, filter: TicketFilter, savedAt: Date) -> [String] {
        if filter == .since {
            guard let text = raw as? String, let start = TicketsPayload.time(text) else { return [] }
            return [TicketTimeWindow.nearest(savedAt.timeIntervalSince(start)).rawValue]
        }
        let list = (raw as? [Any]) ?? raw.map { [$0] } ?? []
        return list.compactMap { value in
            if let text = value as? String { return text }
            if let number = value as? Int { return String(number) }
            return nil
        }
    }

    /// The view in force once `views` were read: `id` while they list it, nil ("All open") once another client
    /// deleted it.
    public static func inForce(_ id: String?, in views: [TicketView]) -> String? {
        id.flatMap { id in views.contains { $0.id == id } ? id : nil }
    }

    /// The newest view named `name`: the one a Save View… of that name just made.
    public static func newest(named name: String, in views: [TicketView]) -> TicketView? {
        views.filter { $0.name == name }.max { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }
}

extension TicketTimeWindow {
    /// The window closest to `seconds`: a saved `since` read back from the time it was saved at.
    public static func nearest(_ seconds: TimeInterval) -> TicketTimeWindow {
        allCases.min { abs($0.seconds - seconds) < abs($1.seconds - seconds) } ?? .day
    }
}

extension TicketsQuery {
    /// Whether it selects, shows and sorts as `other` does: the same chips with the same values in any order, the same
    /// columns and the same sort.
    public func selectsSame(as other: TicketsQuery) -> Bool {
        func filters(_ query: TicketsQuery) -> [TicketFilter: Set<String>] {
            Dictionary(query.chips.map { ($0.filter, Set($0.values)) }, uniquingKeysWith: { first, _ in first })
        }
        return filters(self) == filters(other) && Set(columns) == Set(other.columns) && sort == other.sort
    }

    /// `GET /api/v1/tickets?view=<id>` while the bar is the view as saved, over every repo, and the view keeps no time
    /// window (a saved `since` is a fixed time, so the window is sent from now instead); the inline query otherwise.
    public func path(view: TicketView?, scope: OverviewScope, catalog: [TicketColumn] = TicketColumn.catalog, now: Date) -> String {
        if let view, selectsSame(as: view.query), scope == .all, chip(.since) == nil {
            var components = URLComponents()
            components.queryItems = [URLQueryItem(name: "view", value: view.id)]
            return TicketsPayload.path + "?" + (components.percentEncodedQuery ?? "")
        }
        return path(scope: scope, catalog: catalog, now: now)
    }
}

/// What `POST /api/v1/control/view` sends: a new view without an `id`, or the view of `id` replaced.
public struct TicketViewDraft: Equatable {
    /// The longest name the server takes, in bytes.
    public static let maxNameBytes = 120

    public var id: String?
    public var name: String
    public var query: TicketsQuery
    /// The time a time window is counted back from.
    public var savedAt: Date

    public init(id: String? = nil, name: String, query: TicketsQuery, savedAt: Date = Date()) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = query
        self.savedAt = savedAt
    }

    /// Whether `name` can name a view: not blank, and at most 120 bytes once trimmed.
    public static func canName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf8.count <= maxNameBytes
    }

    /// The body: the name, each chip as a filter of its name and values (a priority as an integer, a time window as
    /// the ISO 8601 time it starts at), the columns and the sort with the server's direction.
    public var body: [String: Any] {
        let filters: [[String: Any]] = TicketFilter.allCases.compactMap { filter in
            guard let chip = query.chip(filter) else { return nil }
            let value: Any = switch filter {
            case .since: chip.parameter(now: savedAt).value ?? ""
            case .priority: chip.values.compactMap(Int.init)
            default: chip.values
            }
            return ["column": filter.rawValue, "value": value]
        }
        let isTime = TicketColumn.catalog.first { $0.name == query.sort.column }?.isTime ?? false
        var body: [String: Any] = [
            "name": name,
            "filters": filters,
            "columns": query.columns.isEmpty ? ["identifier"] : query.columns,
            "sort": ["column": query.sort.column, "direction": query.sort.direction(isTime: isTime)],
        ]
        if let id { body["id"] = id }
        return body
    }
}

/// The views menu at the left of the filter bar: "All open" and the saved views to pick, the view in force with a
/// dot when the bar differs from it, and the moves on it.
public struct TicketViewsMenu: Equatable {
    public static let allOpenTitle = "All open"
    public static let saveTitle = "Save View…"
    public static let updateTitle = "Update View"
    public static let renameTitle = "Rename…"
    public static let deleteTitle = "Delete…"
    /// Why Rename… and Delete… are off on "All open".
    public static let builtInReason = "All open is built in: it can't be renamed or deleted"
    /// Why Update View is off on "All open".
    public static let builtInSaveReason = "All open is built in: Save View… keeps the bar under a name"

    public var views: [TicketView]
    /// The view in force, nil for "All open".
    public var current: TicketView?
    public var query: TicketsQuery

    public init(views: [TicketView], currentID: String?, query: TicketsQuery) {
        self.views = views
        current = currentID.flatMap { id in views.first { $0.id == id } }
        self.query = query
    }

    /// The menu button's label: the view's name.
    public var title: String { current?.name ?? Self.allOpenTitle }

    /// Whether the bar differs from the view in force.
    public var changed: Bool { !query.selectsSame(as: current?.query ?? TicketsQuery()) }

    /// Update View saves the bar into the view in force, a saved one only, when it changed.
    public var canUpdate: Bool { current != nil && changed }

    /// Rename… and Delete… act on a saved view, never on "All open".
    public var canEdit: Bool { current != nil }

    /// What VoiceOver reads for the button: "View: Epic 6 needs me, changed".
    public var accessibilityLabel: String { "View: \(title)" + (changed ? ", changed" : "") }

    /// The help on the button.
    public var help: String { changed ? "Pick a view. The filters, columns or sort differ from \(title)." : "Pick a view" }

    /// Whether the menu shows `view` (nil for "All open") as the one in force.
    public func isCurrent(_ view: TicketView?) -> Bool { view?.id == current?.id }

    /// A move of the menu on the view in force.
    public enum Move: String, CaseIterable {
        case save, update, rename, delete

        public var title: String {
            switch self {
            case .save: TicketViewsMenu.saveTitle
            case .update: TicketViewsMenu.updateTitle
            case .rename: TicketViewsMenu.renameTitle
            case .delete: TicketViewsMenu.deleteTitle
            }
        }
    }

    /// A line of the menu: a view to pick (nil for "All open"), a separator, or a move.
    public enum Item: Equatable, Identifiable {
        case pick(TicketView?, title: String, current: Bool)
        case divider(Int)
        case move(Move, enabled: Bool)

        public var id: String {
            switch self {
            case let .pick(view, _, _): "pick-\(view?.id ?? "all-open")"
            case let .divider(index): "divider-\(index)"
            case let .move(move, _): "move-\(move.rawValue)"
            }
        }
    }

    /// "All open", the saved views by name, then Save View… and Update View, then Rename… and Delete…, the
    /// destructive last under a separator.
    public var items: [Item] {
        var items: [Item] = [.pick(nil, title: Self.allOpenTitle, current: current == nil)]
        items += views.map { .pick($0, title: $0.name, current: isCurrent($0)) }
        items += [
            .divider(0), .move(.save, enabled: true), .move(.update, enabled: canUpdate),
            .divider(1), .move(.rename, enabled: canEdit), .move(.delete, enabled: canEdit),
        ]
        return items
    }

    /// Why `move` is off: "All open" is built in, or the bar is the view as saved.
    public func disabledReason(_ move: Move) -> String {
        switch move {
        case .save: ""
        case .update: canEdit ? "The filters, columns and sort are the view's as saved" : Self.builtInSaveReason
        case .rename, .delete: Self.builtInReason
        }
    }

    /// Delete…'s confirmation.
    public static func deleteQuestion(_ name: String) -> String { "Delete the view “\(name)”?" }
    public static let deleteMessage = "It goes from every Director. The tickets stay as they are."
}
