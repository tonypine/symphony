import Foundation

/// The tickets merged over the last days, as `GET /api/v1/shipped` serves them. Symphony reads its run records to
/// answer, so reading it costs no Linear request. Days are the host's local days, as the Overview's Shipped today
/// counts them.
public struct ShippedPayload: Equatable {
    public static let path = "api/v1/shipped"

    /// A merged ticket.
    public struct Ticket: Equatable, Identifiable {
        public var id: String { issueID }
        public var issueID: String
        public var identifier: String
        public var title: String?
        public var repoKey: String?
        /// The plan ticket it belongs to, "BIL-200".
        public var initiative: String?
        public var initiativeTitle: String?
        public var prURL: URL?
        public var mergedAt: Date?
        /// Its local day, "2026-10-13".
        public var date: String
        public var todoToDoneSeconds: Int?

        public init(
            issueID: String, identifier: String, title: String? = nil, repoKey: String? = nil, initiative: String? = nil,
            initiativeTitle: String? = nil, prURL: URL? = nil, mergedAt: Date? = nil, date: String, todoToDoneSeconds: Int? = nil
        ) {
            self.issueID = issueID
            self.identifier = identifier
            self.title = title
            self.repoKey = repoKey
            self.initiative = initiative
            self.initiativeTitle = initiativeTitle
            self.prURL = prURL
            self.mergedAt = mergedAt
            self.date = date
            self.todoToDoneSeconds = todoToDoneSeconds
        }
    }

    public var days: Int
    /// Symphony's today, "2026-10-13": the period ends on it.
    public var to: String
    public var tickets: [Ticket]

    public init(days: Int, to: String, tickets: [Ticket] = []) {
        self.days = days
        self.to = to
        self.tickets = tickets
    }

    /// The path that asks for `days` days.
    public static func path(days: Int) -> String { "\(path)?days=\(days)" }

    /// The most days the read serves, as `/api/v1/history`'s.
    public static let maxDays = 90

    /// The merged tickets in a payload, nil when it isn't one (an error, or not JSON).
    public static func decode(_ data: Data) -> ShippedPayload? {
        guard let payload = try? InboxPayload.decoder.decode(Payload.self, from: data), let days = payload.days, let to = payload.to
        else { return nil }
        return ShippedPayload(
            days: days,
            to: to,
            tickets: (payload.tickets ?? []).compactMap { ticket in
                guard let identifier = ticket.identifier ?? ticket.issueId, let date = ticket.date else { return nil }
                return Ticket(
                    issueID: ticket.issueId ?? identifier, identifier: identifier, title: ticket.title, repoKey: ticket.repoKey,
                    initiative: ticket.initiative?.identifier, initiativeTitle: ticket.initiative?.title,
                    prURL: ticket.prUrl.flatMap(Shipped.webURL), mergedAt: ticket.mergedAt.flatMap(Shipped.parseDate), date: date,
                    todoToDoneSeconds: ticket.todoToDoneSeconds
                )
            }
        )
    }

    struct Payload: Decodable {
        struct Initiative: Decodable {
            let identifier: String?
            let title: String?
        }

        struct Ticket: Decodable {
            let issueId: String?
            let identifier: String?
            let title: String?
            let repoKey: String?
            let initiative: Initiative?
            let prUrl: String?
            let mergedAt: String?
            let date: String?
            let todoToDoneSeconds: Int?
        }

        let days: Int?
        let to: String?
        let tickets: [Ticket]?
    }
}

/// D9: what shipped over the chosen period and scope. The sentence, shipped per day (C12) and the merged tickets
/// grouped by day, each with its initiative, PR and time from Todo to Done.
public struct Shipped: Equatable {
    /// The toolbar's segmented control.
    public enum Tab: String, CaseIterable, Equatable, Identifiable {
        case shipped, learnings

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .shipped: "Shipped"
            case .learnings: "Learnings"
            }
        }
    }

    /// A merged ticket's row.
    public struct Row: Equatable, Identifiable {
        public var id: String { identifier }
        public var identifier: String
        public var title: String
        /// "billing-api · Invoices v2 · PR #479", what is known of it.
        public var detail: String
        public var prURL: URL?
        /// "PR #479", or "PR" when the link names no number.
        public var prTitle: String?
        /// "1 day 4 h"; nil when Symphony doesn't know when it left Todo.
        public var leadTime: String?
        public var accessibilityLabel: String
    }

    /// A bucket's merged tickets, newest bucket first.
    public struct DayGroup: Equatable, Identifiable {
        /// The bucket's bar.
        public var id: String
        /// "Today · 5", "Yesterday · 3", "Nov 9 · 2"; "Nov 9 06:00 · 2" for a unit other than a day.
        public var title: String
        public var rows: [Row]
    }

    public static let showDataTitle = Quality.showDataTitle

    /// Tickets merged per bucket, in one hue, with the count on the last bar.
    public var chart: InsightsChart
    /// The chart's caption: "Tickets merged per day".
    public var caption: String
    /// "14 tickets shipped in the last 7 days."
    public var sentence: String
    /// "Half took less than 1 day 4 h from Todo to Done."; empty when no lead time is known.
    public var context: String
    public var groups: [DayGroup]
    public var total: Int { chart.total }
    /// Nil while something shipped.
    public var empty: InsightsEmpty?

    /// Shipped over the Insights slice (TP-1463): the aggregation's `shipped` series counts and names the tickets; the
    /// merged tickets `/api/v1/shipped` lists (`details`) give each its title, PR and time from Todo to Done.
    public init(aggregate: AggregatePayload, slice: InsightsSlice, details: ShippedPayload?, today: String) {
        let unit = aggregate.unit
        chart = InsightsChart.build(
            aggregate.shipped, unit: unit, title: "Shipped \(unit.per)", measure: "Tickets", format: .count, fallback: "shipped"
        ) { _ in InsightsChart.Key(key: "shipped", name: "Shipped", tint: .series(.series1)) }
        caption = "Tickets merged \(unit.per)"
        let known = Dictionary((details?.tickets ?? []).map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let todayDate = Usage.utcDate(today) ?? Date()
        groups = aggregate.shipped.buckets.reversed().compactMap { bucket in
            guard !bucket.tickets.isEmpty else { return nil }
            let label = unit == .day ? Self.dayTitle(bucket.start, today: todayDate) : Insights.bucketLabel(bucket.start, unit: unit)
            let rows = bucket.tickets.map { identifier in
                Self.row(known[identifier] ?? ShippedPayload.Ticket(issueID: identifier, identifier: identifier, date: today))
            }
            return DayGroup(id: Insights.iso(bucket.start), title: "\(label) · \(rows.count)", rows: rows)
        }
        sentence = "\(Self.count(chart.total)) shipped \(slice.period.phrase)."
        let leadTimes = groups.flatMap(\.rows).compactMap { known[$0.identifier]?.todoToDoneSeconds }.sorted()
        context = leadTimes.isEmpty ? "" : "Half took less than \(Self.leadTime(Self.median(leadTimes))) from Todo to Done."
        empty = chart.total > 0 ? nil : slice.empty("Nothing shipped", today: today)
    }

    /// "1 ticket", "14 tickets".
    public static func count(_ count: Int) -> String { "\(count) \(count == 1 ? "ticket" : "tickets")" }

    /// Time from Todo to Done, short and exact: "35 min", "6 h", "1 day 4 h", "3 days".
    public static func leadTime(_ seconds: Int) -> String {
        let seconds = max(seconds, 0)
        guard seconds >= 86_400 else { return Overview.duration(seconds) }
        let days = seconds / 86_400
        let hours = seconds % 86_400 / 3_600
        return "\(days) \(days == 1 ? "day" : "days")" + (hours == 0 ? "" : " \(hours) h")
    }

    /// The same time as VoiceOver reads it: "1 day 4 hours".
    public static func spokenLeadTime(_ seconds: Int) -> String {
        let seconds = max(seconds, 0)
        guard seconds >= 86_400 else { return Overview.spokenDuration(seconds) }
        let days = seconds / 86_400
        let hours = seconds % 86_400 / 3_600
        return "\(days) \(days == 1 ? "day" : "days")" + (hours == 0 ? "" : " \(hours) \(hours == 1 ? "hour" : "hours")")
    }

    /// "PR #479" for a GitHub pull request link, else "PR".
    public static func prTitle(_ url: URL) -> String {
        let parts = url.pathComponents
        if let index = parts.lastIndex(of: "pull"), index + 1 < parts.count, Int(parts[index + 1]) != nil {
            return "PR #\(parts[index + 1])"
        }
        return "PR"
    }

    /// An `http(s)` link, nil for anything else.
    static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingWhitespace()), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// Symphony writes whole-second UTC timestamps; fractional seconds read too.
    static func parseDate(_ text: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    static func median(_ sorted: [Int]) -> Int {
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// "Today", "Yesterday", else "Oct 9".
    static func dayTitle(_ date: Date, today: Date) -> String {
        switch calendar.dateComponents([.day], from: date, to: today).day {
        case 0: "Today"
        case 1: "Yesterday"
        default: Usage.dayLabel(date)
        }
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func row(_ ticket: ShippedPayload.Ticket) -> Row {
        let prTitle = ticket.prURL.map(Self.prTitle)
        let detail = [ticket.repoKey, ticket.initiativeTitle ?? ticket.initiative, prTitle].compactMap(\.self).joined(separator: " · ")
        let spoken = [
            ticket.identifier, ticket.title, ticket.repoKey, (ticket.initiativeTitle ?? ticket.initiative).map { "initiative \($0)" }, prTitle,
            ticket.todoToDoneSeconds.map { "\(spokenLeadTime($0)) from Todo to Done" },
        ]
        return Row(
            identifier: ticket.identifier, title: ticket.title ?? ticket.identifier, detail: detail, prURL: ticket.prURL, prTitle: prTitle,
            leadTime: ticket.todoToDoneSeconds.map(leadTime), accessibilityLabel: spoken.compactMap(\.self).joined(separator: ", ")
        )
    }
}

/// A learning as `GET /api/v1/learnings` serves it: a rule the crew drew from a merged PR, with its evidence.
public struct LearningRecord: Equatable, Identifiable {
    public var id: String
    public var repoKey: String
    public var rule: String
    public var tags: [String]
    public var evidence: String?
    public var issueIdentifier: String?
    public var issueURL: URL?
    public var prNumber: Int?
    public var prURL: URL?
    public var createdAt: Date?

    public init(
        id: String, repoKey: String, rule: String, tags: [String] = [], evidence: String? = nil, issueIdentifier: String? = nil,
        issueURL: URL? = nil, prNumber: Int? = nil, prURL: URL? = nil, createdAt: Date? = nil
    ) {
        self.id = id
        self.repoKey = repoKey
        self.rule = rule
        self.tags = tags
        self.evidence = evidence
        self.issueIdentifier = issueIdentifier
        self.issueURL = issueURL
        self.prNumber = prNumber
        self.prURL = prURL
        self.createdAt = createdAt
    }

    /// "PR #41", or "PR" when only the link is known; nil without a link.
    public var prTitle: String? {
        guard let prURL else { return nil }
        return prNumber.map { "PR #\($0)" } ?? Shipped.prTitle(prURL)
    }
}

/// Every learning Symphony stored, newest first. The app filters them itself, so the filters answer as you type.
public struct LearningsPayload: Equatable {
    public static let path = "api/v1/learnings"

    public var records: [LearningRecord]

    public init(records: [LearningRecord] = []) {
        self.records = records
    }

    /// The learnings in a payload, nil when it isn't one.
    public static func decode(_ data: Data) -> LearningsPayload? {
        guard let payload = try? InboxPayload.decoder.decode(Payload.self, from: data), let records = payload.records else { return nil }
        return LearningsPayload(
            records: records.compactMap { record in
                guard let id = record.id, let repoKey = record.repoKey, let rule = record.rule else { return nil }
                return LearningRecord(
                    id: id, repoKey: repoKey, rule: rule, tags: record.tags ?? [], evidence: record.evidenceQuote,
                    issueIdentifier: record.issueIdentifier, issueURL: record.issueUrl.flatMap(Shipped.webURL), prNumber: record.prNumber,
                    prURL: record.prUrl.flatMap(Shipped.webURL), createdAt: record.createdAt.flatMap(Shipped.parseDate)
                )
            }
        )
    }

    struct Payload: Decodable {
        struct Record: Decodable {
            let id: String?
            let repoKey: String?
            let rule: String?
            let tags: [String]?
            let evidenceQuote: String?
            let issueIdentifier: String?
            let issueUrl: String?
            let prNumber: Int?
            let prUrl: String?
            let createdAt: String?
        }

        let records: [Record]?
    }
}

/// D9's Learnings tab: the records newest first, grouped by repo, under the repo and tag filters and the search.
public struct Learnings: Equatable {
    /// The tab's filters; the window's scope narrows them further.
    public struct Filter: Equatable {
        public var repo: String?
        public var tag: String?
        public var search: String

        public init(repo: String? = nil, tag: String? = nil, search: String = "") {
            self.repo = repo
            self.tag = tag
            self.search = search
        }

        public var isActive: Bool { repo != nil || tag != nil || !search.trimmingWhitespace().isEmpty }
    }

    /// A repo's records, newest first.
    public struct Group: Equatable, Identifiable {
        public var id: String { repoKey }
        public var repoKey: String
        public var rows: [Row]
    }

    /// A record and its line of context.
    public struct Row: Equatable, Identifiable {
        public var id: String { record.id }
        public var record: LearningRecord
        /// "BIL-204 · today".
        public var context: String
    }

    /// What the tab says when no record shows, and its way out.
    public struct Empty: Equatable {
        public enum Action: Equatable {
            case clearFilters, showAllRepos, showShipped

            public var title: String {
                switch self {
                case .clearFilters: "Clear Filters"
                case .showAllRepos: "Show All Repos"
                case .showShipped: "Show Shipped"
                }
            }
        }

        public var title: String
        public var action: Action

        public init(title: String, action: Action) {
            self.title = title
            self.action = action
        }
    }

    public static let searchPrompt = "Search learnings"

    /// The repos and tags under the scope, for the filters' pop-ups.
    public var repos: [String]
    public var tags: [String]
    public var groups: [Group]
    public var count: Int
    /// Nil while a record shows.
    public var empty: Empty?

    public init(payload: LearningsPayload, filter: Filter, scope: OverviewScope, now: Date = Date(), timeZone: TimeZone = .current) {
        let inScope = payload.records.filter { scope.includes($0.repoKey) }
        repos = Set(inScope.map(\.repoKey)).sorted()
        tags = Set(inScope.flatMap(\.tags)).sorted()
        let search = filter.search.trimmingWhitespace().lowercased()
        let shown = inScope
            .filter { record in
                (filter.repo.map { record.repoKey == $0 } ?? true) && (filter.tag.map(record.tags.contains) ?? true)
                    && (search.isEmpty || Self.text(of: record).contains(search))
            }
            .sorted { ($0.createdAt ?? .distantPast, $0.id) > ($1.createdAt ?? .distantPast, $1.id) }
        count = shown.count

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Repos follow their newest record, so the newest record comes first.
        var order: [String] = []
        for record in shown where !order.contains(record.repoKey) {
            order.append(record.repoKey)
        }
        groups = order.map { repoKey in
            Group(
                repoKey: repoKey,
                rows: shown.filter { $0.repoKey == repoKey }.map { record in
                    let day = record.createdAt.map { Self.dayWord($0, now: now, calendar: calendar) }
                    return Row(record: record, context: [record.issueIdentifier, day].compactMap(\.self).joined(separator: " · "))
                }
            )
        }

        if !shown.isEmpty {
            empty = nil
        } else if filter.isActive {
            empty = Empty(title: "No learnings match these filters.", action: .clearFilters)
        } else if !payload.records.isEmpty {
            empty = Empty(title: "No learnings recorded in \(scope.title) yet.", action: .showAllRepos)
        } else {
            empty = Empty(title: "No learnings recorded yet.", action: .showShipped)
        }
    }

    /// A record's searchable text: its rule, evidence, tags and ticket, lowercased.
    static func text(of record: LearningRecord) -> String {
        ([record.rule, record.evidence, record.issueIdentifier].compactMap(\.self) + record.tags).joined(separator: "\n").lowercased()
    }

    /// "today", "yesterday", else "Oct 4".
    static func dayWord(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
