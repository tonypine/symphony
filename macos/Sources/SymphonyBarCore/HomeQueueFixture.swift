import Foundation

/// The Home read served from a generated queue (TP-1609), for the tests and QA: `<dir>/api/v1/home.queue.json` holds the
/// slots, the queue's first rows as written, and how many more rows to make (`generated`), and the fixtures answer
/// `GET /api/v1/home` from it as Symphony does: a page by `offset` and `limit`, kept to the saved view `view` read from
/// `<dir>/api/v1/views.json` (its `repo` and `phase` filters), each row with its number in the whole queue, and the
/// slot count the last `POST /api/v1/control/slots` set. Home's drag and drop (TP-1610) changes the queue as Symphony
/// does: each `POST /api/v1/control/queue/move` the fixtures took moves its ticket, and each `POST /api/v1/control/start`
/// with a `slot` puts its ticket in that slot and the one that held it at the queue's top. `refuse` names the tickets
/// whose move Symphony refuses, with its reason: such a move is answered 409 and changes nothing.
///
///     {"slots": {"total": 3, "entries": [{"slot": 1, "ticket": {…}}, …]},
///      "rows": [{"identifier": "TP-1590", "title": "…", "phase": "Code Review", "repo_key": "symphony"}, …],
///      "generated": {"count": 1240, "prefix": "TP", "first": 2000, "repos": ["symphony", "hub"], "titles": ["…"]},
///      "refuse": {"TP-1596": "TP-1596 depends on TP-1590 and must stay below it."}}
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
    /// The tickets whose queue move Symphony refuses, with its reason.
    public let refuse: [String: String]

    public static func == (lhs: HomeQueueFixture, rhs: HomeQueueFixture) -> Bool {
        lhs.slotsJSON == rhs.slotsJSON && lhs.rows.count == rhs.rows.count && lhs.refuse == rhs.refuse
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
        refuse = (root["refuse"] as? [String: String]) ?? [:]
    }

    /// A move the request log holds: its path and its body.
    public struct Move {
        public var path: String
        public var body: [String: Any]

        public init(path: String, body: [String: Any]) {
            self.path = path
            self.body = body
        }
    }

    static let movePath = "/" + ControlAction.queueMove("", place: .top).path
    static let startPath = "/" + ControlAction.start("", note: nil).path

    /// Symphony's refusal of the POST to `path` with `body`: the reason `refuse` gives for a queue move of its ticket,
    /// nil for any other.
    public func refusal(path: String, body: [String: Any]?) -> String? {
        guard path == Self.movePath, let identifier = body?["issue_identifier"] as? String else { return nil }
        return refuse[identifier]
    }

    /// The queue's rows and the slots' entries once `moves`, oldest first, are made: a queue move of a ticket in the
    /// queue, a start of one on a slot. Every other move, and one Symphony refuses, changes nothing. The rows are
    /// numbered again from 1 once one changed.
    func applying(_ moves: [Move], to entries: [[String: Any]]) -> (rows: [[String: Any]], entries: [[String: Any]]) {
        var rows = self.rows
        var entries = entries
        var changed = false
        for move in moves where refusal(path: move.path, body: move.body) == nil {
            guard let identifier = move.body["issue_identifier"] as? String,
                  let from = rows.firstIndex(where: { $0["identifier"] as? String == identifier })
            else { continue }
            if move.path == Self.movePath, let to = Self.place(of: move.body, in: rows, moving: from) {
                let row = rows.remove(at: from)
                rows.insert(row, at: min(to, rows.count))
                changed = true
            } else if move.path == Self.startPath, let slot = move.body["slot"] as? Int {
                let row = rows.remove(at: from)
                let index = entries.firstIndex { $0["slot"] as? Int == slot }
                let held = index.flatMap { entries[$0]["ticket"] as? [String: Any] }
                let since = index.flatMap { entries[$0]["since"] as? String } ?? Self.startedAt
                if let held { rows.insert(Self.stopped(held, since: since), at: 0) }
                let entry: [String: Any] = ["slot": slot, "empty": false, "since": since, "epic": NSNull(), "ticket": Self.started(row, since: since)]
                if let index { entries[index] = entry } else { entries.append(entry) }
                changed = true
            }
        }
        if changed {
            for index in rows.indices {
                rows[index]["number"] = String(index + 1)
                rows[index]["path"] = [index + 1]
            }
        }
        return (rows, entries)
    }

    /// The time a ticket started on a slot that had no time takes.
    static let startedAt = "2026-10-07T14:00:00Z"

    /// The index the ticket at `from` goes to once taken out of `rows`, for a queue move's `body`: `position` top or
    /// end, or `after` or `before` another ticket; nil for a place that names no ticket of the queue.
    static func place(of body: [String: Any], in rows: [[String: Any]], moving from: Int) -> Int? {
        var rest = rows
        rest.remove(at: from)
        func index(of identifier: Any?) -> Int? {
            guard let identifier = identifier as? String else { return nil }
            return rest.firstIndex { $0["identifier"] as? String == identifier }
        }
        switch body["position"] as? String {
        case "top": return 0
        case "end": return rest.count
        default: break
        }
        if let after = index(of: body["after"]) { return after + 1 }
        return index(of: body["before"])
    }

    /// The slot's ticket for the queue row `row`, started at `since`: working in Coding.
    static func started(_ row: [String: Any], since: String) -> [String: Any] {
        let names = [("coding", "Coding"), ("code_review", "Code Review"), ("qa", "QA"), ("merging", "Merging"), ("done", "Done")]
        let stages: [[String: Any]] = names.map { id, name in
            ["id": id, "name": name, "state": id == "coding" ? "current" : "not_yet", "tokens": 0, "runs": 0]
        }
        return [
            "issue_id": row["issue_id"] ?? NSNull(), "identifier": row["identifier"] ?? "", "title": row["title"] ?? NSNull(),
            "repo_key": row["repo_key"] ?? NSNull(), "phase": "In Progress",
            "situation": ["kind": "working", "word": "Coding", "cause": "Started from Home.", "since": since],
            "since": since, "working": true, "waits_on_you": false, "move": NSNull(), "current_stage": "coding", "stages": stages,
            "tokens": ["used": 0, "budget": 100_000_000], "plan": NSNull(), "checks": NSNull(), "pull_request": NSNull(),
        ]
    }

    /// The queue row of a slot's ticket `ticket` stopped at `since` so another took its slot.
    static func stopped(_ ticket: [String: Any], since: String) -> [String: Any] {
        [
            "issue_id": ticket["issue_id"] ?? NSNull(), "identifier": ticket["identifier"] ?? "", "title": ticket["title"] ?? NSNull(),
            "repo_key": ticket["repo_key"] ?? NSNull(), "phase": ticket["phase"] ?? NSNull(), "parent": NSNull(),
            "situation": ["kind": "paused_by_rule", "word": "Stopped", "cause": "Another ticket took its slot.", "since": since],
            "waits_on_you": false, "move": NSNull(),
        ]
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
    /// (`views.json`), `slotCount` the count the last slot change set, nil for the written one, and `moves` the moves the
    /// request log holds, oldest first.
    public func answer(query: String?, views: Data?, slotCount: Int?, moves: [Move] = []) -> Data {
        let items = URLComponents(string: "?" + (query ?? ""))?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let offset = max(Int(value("offset") ?? "") ?? 0, 0)
        let limit = min(max(Int(value("limit") ?? "") ?? HomeRead.pageSize, 1), 500)
        let viewID = value("view")
        var slots = self.slots
        let (rows, moved) = applying(moves, to: (slots["entries"] as? [[String: Any]]) ?? [])
        let kept = viewID.map { id in rows.filter { Self.matches($0, filters: Self.filters(of: id, in: views)) } } ?? rows
        let page = Array(kept.dropFirst(offset).prefix(limit))
        let next = offset + limit < kept.count ? offset + limit : nil

        let total = slotCount ?? (slots["total"] as? Int) ?? 0
        var entries = moved
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
