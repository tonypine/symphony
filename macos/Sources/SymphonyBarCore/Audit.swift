import Foundation

/// A local audit record as `GET /api/v1/audit` serves it: one NDJSON line, kept as it came so Export writes it
/// unchanged. Symphony writes one file per UTC day and chains each record to the one before by hash.
public struct AuditRecord: Equatable, Identifiable {
    /// The record's hash, which the chain verification names; the line itself for a record without one.
    public var id: String { recordHash ?? line }
    public var line: String
    public var eventType: String
    public var timestamp: Date?
    /// Its UTC day, "2026-10-13": the file it is in.
    public var date: String
    public var issueIdentifier: String?
    public var issueID: String?
    public var repoKey: String?
    public var runID: String?
    public var recordHash: String?
    /// "You", "Agent" or "Symphony".
    public var actor: String
    /// What happened, in a line: "Sent to Rework: QA → Rework · “The rounding is off”".
    public var summary: String
    /// The whole record, pretty-printed with sorted keys, for the inspector.
    public var prettyJSON: String

    /// The record on an NDJSON line, nil when the line isn't a JSON object with an `event_type`.
    public init?(line: String) {
        let line = line.trimmingWhitespace()
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        self.init(object: object, line: line)
    }

    init?(object: [String: Any], line: String) {
        guard let eventType = (object["event_type"] as? String)?.nonEmpty else { return nil }
        self.line = line
        self.eventType = eventType
        timestamp = (object["timestamp"] as? String).flatMap(Shipped.parseDate)
        date = (object["date"] as? String) ?? timestamp.map(Quality.isoDay) ?? ""
        issueIdentifier = (object["issue_identifier"] as? String)?.nonEmpty
        issueID = (object["issue_id"] as? String)?.nonEmpty
        repoKey = (object["repo_key"] as? String)?.nonEmpty
        runID = (object["run_id"] as? String)?.nonEmpty
        recordHash = (object["record_hash"] as? String)?.nonEmpty
        actor = Self.actor(eventType, object)
        summary = Self.summary(eventType, object)
        prettyJSON = Self.json(object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) ?? line
    }

    /// The records of an NDJSON body; lines that don't read are skipped.
    public static func records(_ data: Data) -> [AuditRecord] {
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { AuditRecord(line: String($0)) }
    }

    /// The kind's name: "Your move", "Tool call".
    public var kindTitle: String { Self.kindTitle(eventType) }

    public static func kindTitle(_ eventType: String) -> String {
        if let title = kindTitles[eventType] { return title }
        let words = eventType.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The kinds Symphony writes, so the kind pop-up lists them before a record of each is read.
    public static let knownKinds = Array(kindTitles.keys)

    static let kindTitles = [
        "director_move": "Your move",
        "run_stopped": "Run stopped",
        "linear_state_change": "State change",
        "linear_comment": "Linear comment",
        "tool_call": "Tool call",
        "file_change": "File change",
        "prompt_sent": "Prompt sent",
        "pr_opened": "PR opened",
        "token_usage_delta": "Token usage",
        "refused_agent_action": "Refused agent action",
        "poller_degraded": "Poller degraded",
        "poller_recovered": "Poller recovered",
        "auto_merge_disabled": "Auto-merge off",
    ]

    /// Who acted: the Director's moves and stops are "You", records of a run are its agent's, the rest Symphony's.
    static func actor(_ eventType: String, _ object: [String: Any]) -> String {
        if let actor = (object["actor"] as? String)?.nonEmpty { return actor }
        switch eventType {
        case "director_move", "run_stopped": return "You"
        case "prompt_sent": return "Symphony"
        default: return object["run_id"] is String || object["session_id"] is String ? "Agent" : "Symphony"
        }
    }

    static func summary(_ eventType: String, _ object: [String: Any]) -> String {
        func text(_ key: String) -> String? { (object[key] as? String)?.nonEmpty }
        let transition = text("to_state").map { to in text("from_state").map { "\($0) → \(to)" } ?? "to \(to)" }
        switch eventType {
        case "director_move":
            let move = text("move").map(moveTitle) ?? "Moved"
            let comment = text("comment").map { "“\($0)”" }
            return [[move, transition].compactMap(\.self).joined(separator: ": "), comment].compactMap(\.self).joined(separator: " · ")
        case "run_stopped":
            return "Stopped the run"
        case "linear_state_change":
            return transition ?? "State changed"
        case "tool_call":
            let tool = text("tool_name") ?? text("command") ?? (object["command"] as? [Any])?.map { "\($0)" }.joined(separator: " ")
            return [tool ?? "Tool call", text("status")].compactMap(\.self).joined(separator: " · ")
        case "file_change":
            let paths = (object["paths"] as? [Any])?.compactMap { $0 as? String } ?? []
            guard let first = paths.first else { return "Changed files" }
            return paths.count == 1 ? first : "\(first) and \(paths.count - 1) more"
        case "pr_opened":
            return text("url").map { "Opened \($0)" } ?? "Opened a PR"
        case "prompt_sent":
            let turn = (object["turn_number"] as? Int).map { "Turn \($0)" }
            return [turn, text("prompt_preview").map { String($0.prefix(120)) }].compactMap(\.self).joined(separator: " · ")
        case "token_usage_delta":
            let total = (object["token_usage_delta"] as? [String: Any])?["total_tokens"] as? Int
            return total.map { "\(DiagnosticsReport.formatted($0)) tokens" } ?? "Token usage"
        default:
            return preview(object)
        }
    }

    /// A Director move's name: "Approved the PR".
    static func moveTitle(_ move: String) -> String {
        switch move {
        case "approve_plan": "Approved the plan"
        // A move Symphony retired; older audit records still name it.
        case "approve_pr": "Approved the PR"
        case "rework": "Sent to Rework"
        case "decisions": "Sent decisions"
        case "decide": "Decided"
        case "sign_off": "Signed off"
        case "backlog": "Moved to Backlog"
        case "restart": "Restarted"
        case "unblock": "Unblocked"
        case "undo": "Undid a move"
        default: kindTitle(move)
        }
    }

    /// The record's own fields as compact JSON, without the ones every record has, as the web `/audit` previews it.
    static func preview(_ object: [String: Any]) -> String {
        let common: Set = ["timestamp", "event_type", "issue_id", "issue_identifier", "repo_key", "run_id", "date", "previous_hash", "record_hash"]
        let body = object.filter { !common.contains($0.key) }
        guard !body.isEmpty, let json = json(body, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return json.count > 160 ? String(json.prefix(159)) + "…" : json
    }

    static func json(_ object: Any, options: JSONSerialization.WritingOptions) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// What `GET /api/v1/audit/verify` says of each day's hash chain: verified, or the first record that breaks it.
public struct AuditVerification: Equatable {
    public static let path = "api/v1/audit/verify"

    public struct Day: Equatable {
        public var date: String
        public var verified: Bool
        public var broken: Broken?

        public init(date: String, verified: Bool, broken: Broken? = nil) {
            self.date = date
            self.verified = verified
            self.broken = broken
        }
    }

    /// The first record that breaks a day's chain.
    public struct Broken: Equatable {
        /// Its line in the day's file, from 1.
        public var line: Int
        public var recordHash: String?
        /// "chain_break", or "invalid_record" for a line that isn't a record.
        public var reason: String
        /// The record, nil when its line doesn't read.
        public var record: AuditRecord?

        public init(line: Int, recordHash: String? = nil, reason: String, record: AuditRecord? = nil) {
            self.line = line
            self.recordHash = recordHash
            self.reason = reason
            self.record = record
        }
    }

    public var days: [Day]

    public init(days: [Day]) {
        self.days = days
    }

    /// The days of a payload, nil when it isn't one.
    public static func decode(_ data: Data) -> AuditVerification? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let days = object["days"] as? [[String: Any]]
        else { return nil }
        return AuditVerification(
            days: days.compactMap { day in
                guard let date = day["date"] as? String, let verified = day["verified"] as? Bool else { return nil }
                let broken = (day["broken"] as? [String: Any]).map { broken in
                    let record = (broken["record"] as? [String: Any]).flatMap { object in
                        AuditRecord.json(object, options: [.sortedKeys, .withoutEscapingSlashes]).flatMap { AuditRecord(object: object, line: $0) }
                    }
                    return Broken(
                        line: broken["line"] as? Int ?? 0, recordHash: broken["record_hash"] as? String,
                        reason: broken["reason"] as? String ?? "chain_break", record: record
                    )
                }
                return Day(date: date, verified: verified, broken: verified ? nil : broken)
            }
        )
    }
}

/// D10: the local audit records under the kind, date, ticket and scope filters and the search, newest first, with
/// each shown day's chain verification.
public struct Audit: Equatable {
    /// The date pop-up: the last days, or one of them.
    public enum DateFilter: Hashable {
        case recent
        case day(String)
    }

    public struct Filter: Equatable {
        /// An `event_type`, nil for every kind.
        public var kind: String?
        public var date: DateFilter
        /// A ticket identifier, from a ticket page's Show Audit Records.
        public var ticket: String?
        public var search: String

        public init(kind: String? = nil, date: DateFilter = .recent, ticket: String? = nil, search: String = "") {
            self.kind = kind
            self.date = date
            self.ticket = ticket
            self.search = search
        }

        public var isActive: Bool { kind != nil || date != .recent || ticket != nil || !search.trimmingWhitespace().isEmpty }

        /// The filters the API applies: a change in them reads again; the search filters what was read.
        public var query: Filter { Filter(kind: kind, date: date, ticket: ticket) }
    }

    /// A kind in the pop-up.
    public struct Kind: Equatable, Identifiable {
        public var id: String
        public var title: String
    }

    /// A record's row in the table (C19).
    public struct Row: Equatable, Identifiable {
        public var id: String { record.id }
        public var record: AuditRecord
        /// "13:12:44" today, "Oct 12 13:12:44" before.
        public var timeText: String
        public var timeSort: Date
        public var kindTitle: String
        public var ticketText: String
        public var repoText: String
        public var actor: String
        public var summary: String
        /// Whether the day's chain breaks at this record.
        public var breaksChain: Bool
        public var accessibilityLabel: String
        /// The inspector's facts, in order.
        public var facts: [(label: String, value: String)]

        public static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.record == rhs.record && lhs.timeText == rhs.timeText && lhs.breaksChain == rhs.breaksChain
        }
    }

    /// A shown day's verification: "Chain verified", or which record broke it.
    public struct ChainLine: Equatable, Identifiable {
        public var id: String { date }
        public var date: String
        /// "Today", "Yesterday", "Oct 11".
        public var day: String
        public var verified: Bool
        /// "Chain verified", or "Chain broken at line 2: Your move on SHOP-298 at 12:40:10."
        public var text: String
        public var symbol: String { verified ? Audit.verifiedSymbol : Audit.brokenSymbol }
        public var accessibilityLabel: String { "\(day): \(text)" }
    }

    public struct Empty: Equatable {
        public enum Action: Equatable {
            case clearFilters, showAllRepos

            public var title: String {
                switch self {
                case .clearFilters: "Clear Filters"
                case .showAllRepos: "Show All Repos"
                }
            }
        }

        public var title: String
        public var action: Action?
    }

    public static let recentDays = 7
    /// The most records one read asks for: the newest ones, so a busy day still reads quickly.
    public static let maxRecords = 1_000
    public static let searchPrompt = "Search audit records"
    public static let exportTitle = "Export…"
    public static let emptyTitle = "No audit records match."
    public static let verifiedText = "Chain verified"
    public static let verifiedSymbol = "checkmark.seal.fill"
    public static let brokenSymbol = "xmark.seal.fill"

    public var rows: [Row]
    public var kinds: [Kind]
    /// The days the date pop-up offers, newest first: Symphony's today and the days before.
    public var days: [String]
    public var chain: [ChainLine]
    /// "42 records"; with the cap, "The newest 1,000 records".
    public var countText: String
    /// Nil while a record shows.
    public var empty: Empty?

    /// `today` is Symphony's UTC day, "2026-10-13", so the days match its files whatever the Mac's clock says.
    public init(
        records: [AuditRecord], verification: AuditVerification?, filter: Filter, scope: OverviewScope, today: String,
        now: Date = Date(), timeZone: TimeZone = .current
    ) {
        days = Self.days(today: today)
        let range = Self.range(filter.date, today: today)
        let shown = records.enumerated()
            .filter { Self.matches($0.element, filter: filter, scope: scope, range: range) }
            .sorted { ($0.element.timestamp ?? .distantPast, $0.offset) > ($1.element.timestamp ?? .distantPast, $1.offset) }
            .map(\.element)

        let brokenHashes = Set((verification?.days ?? []).compactMap { $0.broken?.recordHash })
        let clock = Self.clock(now: now, timeZone: timeZone)
        rows = shown.map { Self.row($0, breaksChain: $0.recordHash.map(brokenHashes.contains) ?? false, clock: clock) }

        let kindIDs = Set(AuditRecord.knownKinds + records.map(\.eventType) + [filter.kind].compactMap(\.self))
        kinds = kindIDs.map { Kind(id: $0, title: AuditRecord.kindTitle($0)) }.sorted { $0.title < $1.title }

        // Every day of the range that has records under the scope, or breaks, or is the one day asked for.
        let daysWithRecords = Set(records.filter { scope.includes($0.repoKey) }.map(\.date))
        chain = (verification?.days ?? [])
            .filter { $0.date >= range.from && $0.date <= range.to }
            .filter { !$0.verified || daysWithRecords.contains($0.date) || range.from == range.to }
            .sorted { $0.date > $1.date }
            .map { day in
                ChainLine(
                    date: day.date, day: Self.dayTitle(day.date, today: today), verified: day.verified,
                    text: day.verified ? Self.verifiedText : Self.brokenText(day.broken, clock: clock)
                )
            }

        let count = rows.count
        countText = records.count >= Self.maxRecords && count > 0
            ? "The newest \(DiagnosticsReport.formatted(Self.maxRecords)) records; narrow the filters to see older ones"
            : "\(DiagnosticsReport.formatted(count)) \(count == 1 ? "record" : "records")"

        if count > 0 {
            empty = nil
        } else {
            empty = Empty(title: Self.emptyTitle, action: filter.isActive ? .clearFilters : scope == .all ? nil : .showAllRepos)
        }
    }

    /// The date pop-up's title for a choice.
    public static func title(_ date: DateFilter, today: String) -> String {
        switch date {
        case .recent: "Last \(recentDays) Days"
        case let .day(day): dayTitle(day, today: today)
        }
    }

    /// The inclusive UTC days a choice reads.
    public static func range(_ date: DateFilter, today: String) -> (from: String, to: String) {
        switch date {
        case .recent: (days(today: today).last ?? today, today)
        case let .day(day): (day, day)
        }
    }

    /// The records' read: the newest `maxRecords` under the filters the API applies.
    public static func path(_ filter: Filter, scope: OverviewScope, today: String) -> String {
        "api/v1/audit?" + query(filter, scope: scope, today: today) + "&last=\(maxRecords)"
    }

    /// The chain verification of the days the date filter reads.
    public static func verifyPath(_ filter: Filter, today: String) -> String {
        let range = range(filter.date, today: today)
        return "\(AuditVerification.path)?from=\(range.from)&to=\(range.to)"
    }

    /// Export's read: every record under the filters, from the API's NDJSON export.
    public static func exportPath(_ filter: Filter, scope: OverviewScope, today: String) -> String {
        "api/v1/audit?" + query(filter, scope: scope, today: today) + "&download=1"
    }

    /// The lines of an export body that the filters and the search keep, as they came, one record per line.
    public static func exportLines(_ data: Data, filter: Filter, scope: OverviewScope, today: String) -> [String] {
        let range = range(filter.date, today: today)
        return AuditRecord.records(data).filter { matches($0, filter: filter, scope: scope, range: range) }.map(\.line)
    }

    /// The export file's bytes: one record per line, each line ending in a newline.
    public static func exportBody(_ lines: [String]) -> Data {
        Data(lines.map { $0 + "\n" }.joined().utf8)
    }

    /// What Export says when the records couldn't be read.
    public static func exportError(_ result: EndpointResult) -> String {
        switch result {
        case .loaded: ""
        case .unsupported: "Couldn't export: \(EndpointPlaceholder.updateSymphony)"
        case let .failed(message): "Couldn't export: \(message)."
        }
    }

    /// The file Export suggests: "symphony-audit-2026-10-07-2026-10-13.ndjson", with the ticket when filtered to one.
    public static func exportFileName(_ filter: Filter, today: String) -> String {
        let range = range(filter.date, today: today)
        let days = range.from == range.to ? range.from : "\(range.from)-\(range.to)"
        return (["symphony-audit", filter.ticket, days].compactMap(\.self).joined(separator: "-")) + ".ndjson"
    }

    /// Symphony's today: the UTC day of its last state, else of the Mac's clock.
    public static func today(generatedAt: Date?, now: Date = Date()) -> String {
        Quality.isoDay(generatedAt ?? now)
    }

    static func matches(_ record: AuditRecord, filter: Filter, scope: OverviewScope, range: (from: String, to: String)) -> Bool {
        let search = filter.search.trimmingWhitespace().lowercased()
        return record.date >= range.from && record.date <= range.to
            && (filter.kind.map { record.eventType == $0 } ?? true)
            && (filter.ticket.map { ticket in [record.issueIdentifier, record.issueID].contains { $0?.caseInsensitiveCompare(ticket) == .orderedSame } } ?? true)
            && scope.includes(record.repoKey)
            && (search.isEmpty || searchText(record).contains(search))
    }

    /// What the search reads: the ticket, kind, repo, actor and summary, lowercased.
    static func searchText(_ record: AuditRecord) -> String {
        [record.issueIdentifier, record.eventType, record.kindTitle, record.repoKey, record.actor, record.summary]
            .compactMap(\.self).joined(separator: "\n").lowercased()
    }

    static func query(_ filter: Filter, scope: OverviewScope, today: String) -> String {
        let range = range(filter.date, today: today)
        let items = [("from", range.from), ("to", range.to)] + [("type", filter.kind), ("issue", filter.ticket), ("repo", scope.stored)]
            .compactMap { name, value in value.map { (name, $0) } }
        return items.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $1)" }.joined(separator: "&")
    }

    /// The last `recentDays` UTC days, newest first.
    static func days(today: String) -> [String] {
        guard let date = Usage.utcDate(today) else { return [today] }
        return (0..<recentDays).compactMap { Shipped.calendar.date(byAdding: .day, value: -$0, to: date).map(Quality.isoDay) }
    }

    /// "Today", "Yesterday", else "Oct 11".
    static func dayTitle(_ day: String, today: String) -> String {
        guard let date = Usage.utcDate(day), let todayDate = Usage.utcDate(today) else { return day }
        return Shipped.dayTitle(date, today: todayDate)
    }

    static func brokenText(_ broken: AuditVerification.Broken?, clock: (Date) -> String) -> String {
        guard let broken else { return "Chain broken" }
        let at = "Chain broken at line \(broken.line)"
        guard let record = broken.record else {
            return broken.reason == "invalid_record" ? "\(at): the line isn't an audit record." : "\(at)."
        }
        let what = [record.kindTitle, record.issueIdentifier.map { "on \($0)" }, record.timestamp.map { "at \(clock($0))" }]
            .compactMap(\.self).joined(separator: " ")
        return "\(at): \(what)."
    }

    /// "13:12:44" on `now`'s day, else "Oct 12 13:12:44", in `timeZone`.
    static func clock(now: Date, timeZone: TimeZone) -> (Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.timeZone = timeZone
        time.dateFormat = "HH:mm:ss"
        let dated = DateFormatter()
        dated.locale = time.locale
        dated.timeZone = timeZone
        dated.dateFormat = "MMM d HH:mm:ss"
        return { date in calendar.isDate(date, inSameDayAs: now) ? time.string(from: date) : dated.string(from: date) }
    }

    private static func row(_ record: AuditRecord, breaksChain: Bool, clock: (Date) -> String) -> Row {
        let time = record.timestamp.map(clock) ?? record.date
        let facts: [(String, String?)] = [
            ("Time", record.timestamp.map(ISO8601DateFormatter().string)), ("Kind", record.kindTitle), ("Type", record.eventType),
            ("Ticket", record.issueIdentifier), ("Repo", record.repoKey), ("Actor", record.actor), ("Run", record.runID),
            ("Hash", record.recordHash),
        ]
        let spoken = [
            time, record.kindTitle, record.issueIdentifier, record.repoKey, "by \(record.actor)", record.summary.nonEmpty,
            breaksChain ? "breaks the chain" : nil,
        ]
        return Row(
            record: record, timeText: time, timeSort: record.timestamp ?? .distantPast, kindTitle: record.kindTitle,
            ticketText: record.issueIdentifier ?? "", repoText: record.repoKey ?? "", actor: record.actor, summary: record.summary,
            breaksChain: breaksChain, accessibilityLabel: spoken.compactMap(\.self).joined(separator: ", "),
            facts: facts.compactMap { label, value in value.map { (label, $0) } }
        )
    }
}

extension CharacterSet {
    /// What a query value may hold unescaped: `&`, `=`, `+` and `#` are escaped.
    static let urlQueryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
