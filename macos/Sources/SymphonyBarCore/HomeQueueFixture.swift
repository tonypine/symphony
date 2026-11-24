import Foundation

/// The Home read served from a generated queue (TP-1609), for the tests and QA: `<dir>/api/v1/home.queue.json` holds the
/// slots, the queue's first rows as written, and how many more rows to make (`generated`), and the fixtures answer
/// `GET /api/v1/home` from it as Symphony does: a page by `offset` and `limit`, kept to the saved view `view` read from
/// `<dir>/api/v1/views.json` (its `repo` and `phase` filters), each row with its number in the whole queue, and the
/// slot count the last `POST /api/v1/control/slots` set.
///
///     {"slots": {"total": 3, "entries": [{"slot": 1, "ticket": {…}}, …]},
///      "rows": [{"identifier": "TP-1590", "title": "…", "phase": "Code Review", "repo_key": "symphony"}, …],
///      "generated": {"count": 1240, "prefix": "TP", "first": 2000, "repos": ["symphony", "hub"], "titles": ["…"]}}
public struct HomeQueueFixture: Equatable {
    public static let fileName = "home.queue.json"

    public struct Generated: Decodable, Equatable {
        public var count: Int
        public var prefix: String?
        public var first: Int?
        public var repos: [String]?
        public var titles: [String]?
        public var phases: [String]?
    }

    /// The slots as written: their JSON, passed through.
    public var slots: [String: Any] { (try? JSONSerialization.jsonObject(with: slotsJSON)) as? [String: Any] ?? [:] }
    let slotsJSON: Data
    /// Every row of the queue, in order, as JSON objects.
    public let rows: [[String: Any]]

    public static func == (lhs: HomeQueueFixture, rhs: HomeQueueFixture) -> Bool {
        lhs.slotsJSON == rhs.slotsJSON && lhs.rows.count == rhs.rows.count
    }

    /// The fixture in `data`, nil when it doesn't read.
    public init?(_ data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        slotsJSON = (try? JSONSerialization.data(withJSONObject: root["slots"] ?? [String: Any]())) ?? Data("{}".utf8)
        var rows = (root["rows"] as? [[String: Any]]) ?? []
        if let object = root["generated"], let data = try? JSONSerialization.data(withJSONObject: object),
           let generated = try? JSONDecoder().decode(Generated.self, from: data) {
            rows += Self.generate(generated)
        }
        for index in rows.indices where rows[index]["number"] == nil {
            rows[index]["number"] = String(index + 1)
            rows[index]["path"] = [index + 1]
        }
        self.rows = rows
    }

    /// `generated.count` rows, each its own ticket: identifiers counting from `first`, titles, repos and phases in turn.
    static func generate(_ generated: Generated) -> [[String: Any]] {
        let prefix = generated.prefix ?? "TP"
        let first = generated.first ?? 1
        let repos = generated.repos?.isEmpty == false ? generated.repos! : ["symphony"]
        let titles = generated.titles?.isEmpty == false ? generated.titles! : ["A ticket of the queue"]
        let phases = generated.phases?.isEmpty == false ? generated.phases! : ["Todo"]
        return (0..<max(generated.count, 0)).map { index in
            let identifier = "\(prefix)-\(first + index)"
            return [
                "issue_id": "gen-\(first + index)", "identifier": identifier, "title": titles[index % titles.count],
                "repo_key": repos[index % repos.count], "phase": phases[index % phases.count], "parent": NSNull(),
                "situation": NSNull(), "waits_on_you": false, "move": NSNull(),
            ]
        }
    }

    /// The read's answer for `query` (`offset=0&limit=100&view=view-a`), with `views` the saved views' JSON
    /// (`views.json`) and `slotCount` the count the last slot change set, nil for the written one.
    public func answer(query: String?, views: Data?, slotCount: Int?) -> Data {
        let items = URLComponents(string: "?" + (query ?? ""))?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let offset = max(Int(value("offset") ?? "") ?? 0, 0)
        let limit = min(max(Int(value("limit") ?? "") ?? HomeRead.pageSize, 1), 500)
        let viewID = value("view")
        let kept = viewID.map { id in rows.filter { Self.matches($0, filters: Self.filters(of: id, in: views)) } } ?? rows
        let page = Array(kept.dropFirst(offset).prefix(limit))
        let next = offset + limit < kept.count ? offset + limit : nil

        var slots = self.slots
        let total = slotCount ?? (slots["total"] as? Int) ?? 0
        var entries = (slots["entries"] as? [[String: Any]]) ?? []
        let held = Set(entries.compactMap { $0["slot"] as? Int })
        if total > 0 {
            for number in 1...total where !held.contains(number) {
                entries.append(["slot": number, "empty": true, "since": NSNull(), "epic": NSNull(), "ticket": NSNull()])
            }
        }
        // A free slot past a lowered count is gone; a held one stays.
        entries = entries.filter { ($0["slot"] as? Int ?? 0) <= total || !($0["ticket"] is NSNull || $0["ticket"] == nil) }
        entries.sort { ($0["slot"] as? Int ?? 0) < ($1["slot"] as? Int ?? 0) }
        slots["total"] = total
        slots["entries"] = entries

        let queue: [String: Any] = [
            "rows": page, "count": kept.count, "total": rows.count, "offset": offset, "limit": limit,
            "next_offset": next.map { $0 as Any } ?? NSNull(), "view": viewID.map { $0 as Any } ?? NSNull(), "roots": [Any](),
        ]
        let root: [String: Any] = ["slots": slots, "queue": queue, "in_progress": [Any]()]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// The `repo` and `phase` filters of the saved view `id`, by column; none for a view `views` doesn't list.
    static func filters(of id: String, in views: Data?) -> [String: [String]] {
        guard let views, let root = (try? JSONSerialization.jsonObject(with: views)) as? [String: Any],
              let list = root["views"] as? [[String: Any]], let view = list.first(where: { $0["id"] as? String == id })
        else { return [:] }
        var filters: [String: [String]] = [:]
        for filter in (view["filters"] as? [[String: Any]]) ?? [] {
            guard let column = filter["column"] as? String else { continue }
            let raw = filter["value"]
            filters[column] = (raw as? [String]) ?? (raw as? String).map { [$0] } ?? []
        }
        return filters
    }

    static func matches(_ row: [String: Any], filters: [String: [String]]) -> Bool {
        if let repos = filters["repo"], !repos.contains(row["repo_key"] as? String ?? "") { return false }
        if let phases = filters["phase"], !phases.contains(row["phase"] as? String ?? "") { return false }
        return true
    }
}
