import Foundation

/// The Home read served from a generated queue (TP-1609), for the tests and QA: `<dir>/api/v1/home.queue.json` holds the
/// slots, the queue's first rows as written, and how many more rows to make (`generated`), and the fixtures answer
/// `GET /api/v1/home` from it as Symphony does: a page by `offset` and `limit`, kept to the saved view `view` read from
/// `<dir>/api/v1/views.json` (its `repo` and `phase` filters), each row with its number in the whole queue, and the
/// slot count the last `POST /api/v1/control/slots` set. Home's drag and drop (TP-1610) changes the queue as Symphony
/// does: each `POST /api/v1/control/queue/move` the fixtures took moves its ticket, and each `POST /api/v1/control/start`
/// with a `slot` puts its ticket in that slot and the one that held it at the queue's top. `refuse` names the tickets
/// whose move Symphony refuses, with its reason: such a move is answered 409 and changes nothing. A row may name its
/// `parent` (an epic's sub-ticket follows its epic and is numbered inside it, "6.1"), its `dependencies` (each with its
/// `identifier`, `kind` done or released, and whether it is `met`), and an epic its `sub_tickets` and
/// `done_sub_tickets` (TP-1645). A move keeps its ticket's block together and inside its scope, and the fixtures refuse,
/// in the engine's words, a move that puts a ticket above one it waits for and a Start of a ticket that waits; a saved
/// view keeps an epic's row above its matching sub-rows. `recently_done` holds
/// the tickets done in the last 7 days, most recent first, each marked `today` when it finished today (TP-1644); the
/// read gives the range `done_range` asks for (today by default) from `done_offset`, at most `done_limit`, with both
/// counts, as Symphony does. A slot's `epic` (TP-1646) is passed through with its `done_sub_tickets` and
/// `open_sub_tickets`; a queue move of one of its open sub-tickets moves it among them, a Start of one swaps it with the
/// sub-ticket in work, which becomes the first to come, and both are refused as in the queue.
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
    /// The tickets done in the last 7 days, most recent first, as JSON objects; `today` marks those done today.
    public let done: [[String: Any]]

    public static func == (lhs: HomeQueueFixture, rhs: HomeQueueFixture) -> Bool {
        lhs.slotsJSON == rhs.slotsJSON && lhs.rows.count == rhs.rows.count && lhs.refuse == rhs.refuse && lhs.done.count == rhs.done.count
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
        if rows.contains(where: { $0["number"] == nil }) { rows = Self.numbered(rows) }
        self.rows = rows
        refuse = (root["refuse"] as? [String: String]) ?? [:]
        done = ((root["recently_done"] as? [String: Any])?["entries"] as? [[String: Any]]) ?? []
    }

    /// The read's `recently_done` for the query's `done_range`, `done_offset` and `done_limit`.
    func recentlyDone(_ value: (String) -> String?) -> [String: Any] {
        let range = value("done_range") == "week" ? "week" : "today"
        let offset = max(Int(value("done_offset") ?? "") ?? 0, 0)
        let limit = min(max(Int(value("done_limit") ?? "") ?? RecentlyDoneList.pageSize, 1), RecentlyDoneList.maxLimit)
        let today = done.filter { $0["today"] as? Bool == true }
        let kept = range == "week" ? done : today
        let page = kept.dropFirst(offset).prefix(limit).map { entry in entry.filter { $0.key != "today" } }
        let next = offset + page.count < kept.count ? offset + page.count : nil
        return [
            "range": range, "counts": ["today": today.count, "week": done.count], "entries": Array(page), "offset": offset, "limit": limit,
            "next_offset": next.map { $0 as Any } ?? NSNull(),
        ]
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

    /// Symphony's refusal of the POST to `path` with `body` once `moves`, the POSTs before it, are made, in the engine's
    /// words: the reason `refuse` gives for a queue move of its ticket; for a move that would put a ticket above one it
    /// depends on, "TP-978 depends on TP-977 and must stay below it."; for a Start of a ticket with an unmet dependency,
    /// "TP-977 depends on TP-976 and can't start before it is done." (or "released."). Nil for any other.
    public func refusal(path: String, body: [String: Any]?, after moves: [Move] = []) -> String? {
        guard let identifier = body?["issue_identifier"] as? String else { return nil }
        let (rows, entries) = applying(moves, to: slotEntries)
        return refusal(path: path, identifier: identifier, body: body ?? [:], in: rows, entries: entries)
    }

    /// The slots' entries as written.
    var slotEntries: [[String: Any]] { (slots["entries"] as? [[String: Any]]) ?? [] }

    /// The refusal of a POST to `path` for `identifier` with `body`, on the queue `rows` and the slots' `entries`: a
    /// ticket among a slot epic's open sub-tickets (TP-1646) is judged among them.
    func refusal(path: String, identifier: String, body: [String: Any], in rows: [[String: Any]], entries: [[String: Any]] = []) -> String? {
        let rows = Self.slotEpic(of: identifier, in: entries).map { Self.openSubTickets(entries[$0]) } ?? rows
        if path == Self.startPath {
            guard let row = rows.first(where: { $0["identifier"] as? String == identifier }),
                  let unmet = Self.unmet(row).first
            else { return nil }
            let kind = unmet["kind"] as? String == "released" ? "released" : "done"
            return "\(identifier) depends on \(unmet["identifier"] as? String ?? "") and can't start before it is \(kind)."
        }
        guard path == Self.movePath else { return nil }
        if let reason = refuse[identifier] { return reason }
        guard let moved = Self.moving(identifier, body: body, in: rows) else { return nil }
        let before = Self.belowDependencies(rows)
        return Self.belowDependencies(moved).first { !before.contains($0) }.map { "\($0.dependent) depends on \($0.on) and must stay below it." }
    }

    /// The unmet dependencies of `row`, as the read writes them.
    static func unmet(_ row: [String: Any]) -> [[String: Any]] {
        ((row["dependencies"] as? [[String: Any]]) ?? []).filter { $0["met"] as? Bool != true }
    }

    /// Each pair of `rows` where a ticket stands above one it depends on and waits for.
    static func belowDependencies(_ rows: [[String: Any]]) -> [Pair] {
        let index = Dictionary(rows.enumerated().compactMap { offset, row in (row["identifier"] as? String).map { ($0, offset) } }, uniquingKeysWith: { a, _ in a })
        return rows.enumerated().flatMap { offset, row -> [Pair] in
            unmet(row).compactMap { dependency in
                guard let on = dependency["identifier"] as? String, let at = index[on], at > offset else { return nil }
                return Pair(dependent: row["identifier"] as? String ?? "", on: on)
            }
        }
    }

    struct Pair: Equatable {
        var dependent: String
        var on: String
    }

    /// The queue's rows and the slots' entries once `moves`, oldest first, are made: a queue move of a ticket in the
    /// queue (with its block, inside its scope), a start of one on a slot. Every other move, and one Symphony refuses,
    /// changes nothing. The rows are numbered again once one changed.
    func applying(_ moves: [Move], to entries: [[String: Any]]) -> (rows: [[String: Any]], entries: [[String: Any]]) {
        var rows = self.rows
        var entries = entries
        var changed = false
        for move in moves {
            guard let identifier = move.body["issue_identifier"] as? String,
                  refusal(path: move.path, identifier: identifier, body: move.body, in: rows, entries: entries) == nil
            else { continue }
            if let at = Self.slotEpic(of: identifier, in: entries) {
                entries[at] = Self.applying(move, identifier: identifier, toSlot: entries[at])
                continue
            }
            guard let from = rows.firstIndex(where: { $0["identifier"] as? String == identifier }) else { continue }
            if move.path == Self.movePath, let moved = Self.moving(identifier, body: move.body, in: rows) {
                rows = moved
                changed = true
            } else if move.path == Self.startPath, let slot = move.body["slot"] as? Int {
                let block = Self.block(at: from, in: rows)
                let row = rows[from]
                rows.removeSubrange(block)
                let index = entries.firstIndex { $0["slot"] as? Int == slot }
                let held = index.flatMap { entries[$0]["ticket"] as? [String: Any] }
                let since = index.flatMap { entries[$0]["since"] as? String } ?? Self.startedAt
                if let held { rows.insert(Self.stopped(held, since: since), at: 0) }
                let entry: [String: Any] = ["slot": slot, "empty": false, "since": since, "epic": NSNull(), "ticket": Self.started(row, since: since)]
                if let index { entries[index] = entry } else { entries.append(entry) }
                changed = true
            }
        }
        return (changed ? Self.numbered(rows) : rows, entries)
    }

    /// The index of the slot entry whose epic lists `identifier` among its open sub-tickets (TP-1646), nil for none.
    static func slotEpic(of identifier: String, in entries: [[String: Any]]) -> Int? {
        entries.firstIndex { openSubTickets($0).contains { $0["identifier"] as? String == identifier } }
    }

    /// A slot entry's epic's open sub-tickets, in their order.
    static func openSubTickets(_ entry: [String: Any]) -> [[String: Any]] {
        ((entry["epic"] as? [String: Any])?["open_sub_tickets"] as? [[String: Any]]) ?? []
    }

    /// The slot `entry` once `move` of its epic's open sub-ticket `identifier` is made, as the engine does: a queue
    /// move puts it at its place among the epic's open sub-tickets; a Start swaps it with the sub-ticket in work, which
    /// stops and becomes the first to come. Any other move changes nothing.
    static func applying(_ move: Move, identifier: String, toSlot entry: [String: Any]) -> [String: Any] {
        guard var epic = entry["epic"] as? [String: Any] else { return entry }
        var entry = entry
        var subs = openSubTickets(entry)
        if move.path == movePath, let moved = moving(identifier, body: move.body, in: subs) {
            subs = moved
        } else if move.path == startPath, let from = subs.firstIndex(where: { $0["identifier"] as? String == identifier }) {
            let row = subs.remove(at: from)
            // The sub-ticket in work leaves the card when the other starts: the card's time starts again from its own.
            let since = (entry["ticket"] as? [String: Any])?["since"] as? String ?? startedAt
            if let held = entry["ticket"] as? [String: Any] {
                var back = stopped(held, since: since)
                back["parent"] = epic["identifier"] ?? NSNull()
                back["dependencies"] = [Any]()
                subs.insert(back, at: 0)
            }
            entry["ticket"] = started(row, since: since)
        } else {
            return entry
        }
        epic["open_sub_tickets"] = subs
        entry["epic"] = epic
        return entry
    }

    /// The parent a row names, nil at the top level.
    static func parent(_ row: [String: Any]) -> String? { row["parent"] as? String }

    /// The indexes of the block that starts at `index`: the row and the rows under it that follow it.
    static func block(at index: Int, in rows: [[String: Any]]) -> Range<Int> {
        var under: Set<String> = [rows[index]["identifier"] as? String ?? ""]
        var end = index + 1
        while end < rows.count, let parent = Self.parent(rows[end]), under.contains(parent) {
            under.insert(rows[end]["identifier"] as? String ?? "")
            end += 1
        }
        return index..<end
    }

    /// `rows` once the ticket `identifier` moves, with its block, to the place `body` names inside its scope (the top
    /// level, or its parent's sub-tickets): `position` top or end, or `after` or `before` a ticket of the same scope. Nil
    /// for a place that names no ticket of its scope.
    static func moving(_ identifier: String, body: [String: Any], in rows: [[String: Any]]) -> [[String: Any]]? {
        guard let from = rows.firstIndex(where: { $0["identifier"] as? String == identifier }) else { return nil }
        let scope = Self.parent(rows[from])
        let block = Self.block(at: from, in: rows)
        let moved = Array(rows[block])
        var rest = rows
        rest.removeSubrange(block)
        func sibling(_ name: Any?) -> Int? {
            guard let name = name as? String else { return nil }
            return rest.firstIndex { $0["identifier"] as? String == name && Self.parent($0) == scope }
        }
        let siblings = rest.indices.filter { Self.parent(rest[$0]) == scope }
        let to: Int?
        switch body["position"] as? String {
        case "top":
            to = scope == nil ? 0 : siblings.first
        case "end":
            to = scope == nil ? rest.count : siblings.last.map { Self.block(at: $0, in: rest).upperBound }
        default:
            if let after = sibling(body["after"]) {
                to = Self.block(at: after, in: rest).upperBound
            } else {
                to = sibling(body["before"])
            }
        }
        guard let to else { return nil }
        rest.insert(contentsOf: moved, at: min(to, rest.count))
        return rest
    }

    /// `rows` with their numbers: the top-level ones counted from 1, and a sub-ticket its parent's and its own place
    /// among its parent's ("6.1"), as the read gives them.
    static func numbered(_ rows: [[String: Any]]) -> [[String: Any]] {
        var paths: [String: [Int]] = [:]
        var counts: [String: Int] = [:]
        return rows.map { row in
            var row = row
            let parent = Self.parent(row).flatMap { paths[$0] != nil ? $0 : nil }
            let key = parent ?? ""
            counts[key, default: 0] += 1
            let path = (parent.flatMap { paths[$0] } ?? []) + [counts[key]!]
            if let identifier = row["identifier"] as? String { paths[identifier] = path }
            row["number"] = path.map(String.init).joined(separator: ".")
            row["path"] = path
            return row
        }
    }

    /// The time a ticket started on a slot that had no time takes.
    static let startedAt = "2026-10-07T14:00:00Z"

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
        let kept = viewID.map { id in Self.keeping(rows, filters: Self.filters(of: id, in: views)) } ?? rows
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
        let root: [String: Any] = ["slots": slots, "queue": queue, "in_progress": [Any](), "recently_done": recentlyDone(value)]
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

    /// The rows `filters` match and every row above one of them, so an epic's row stays while one of its sub-tickets
    /// matches, with only the matching sub-rows under it; in their order, with their real numbers.
    static func keeping(_ rows: [[String: Any]], filters: [String: [String]]) -> [[String: Any]] {
        let byIdentifier = Dictionary(rows.compactMap { row in (row["identifier"] as? String).map { ($0, row) } }, uniquingKeysWith: { a, _ in a })
        var kept: Set<String> = []
        for row in rows where Self.matches(row, filters: filters) {
            var next: [String: Any]? = row
            while let current = next, let identifier = current["identifier"] as? String, kept.insert(identifier).inserted {
                next = Self.parent(current).flatMap { byIdentifier[$0] }
            }
        }
        return rows.filter { kept.contains($0["identifier"] as? String ?? "") }
    }

    static func matches(_ row: [String: Any], filters: [String: [String]]) -> Bool {
        if let repos = filters["repo"], !repos.contains(row["repo_key"] as? String ?? "") { return false }
        if let phases = filters["phase"], !phases.contains(row["phase"] as? String ?? "") { return false }
        return true
    }
}
