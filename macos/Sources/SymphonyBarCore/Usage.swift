import Foundation

/// What the crew used and shipped over the last days, as `GET /api/v1/history` serves it. Symphony reads its run
/// records to answer, so reading it costs no Linear request.
public struct HistoryPayload: Equatable {
    public static let path = "api/v1/history"
    public static let defaultDays = 14

    /// One UTC day's tokens, by provider.
    public struct Day: Equatable {
        public var date: String
        public var totalTokens: Int
        public var providers: [String: Int]

        public init(date: String, totalTokens: Int, providers: [String: Int]) {
            self.date = date
            self.totalTokens = totalTokens
            self.providers = providers
        }
    }

    /// A ticket's tokens in the period, over its attempts, against the per-ticket cap.
    public struct Ticket: Equatable {
        public var issueID: String
        public var identifier: String
        public var title: String?
        public var repoKey: String?
        public var totalTokens: Int
        public var attempts: Int
        public var cap: Int?

        public init(issueID: String, identifier: String, title: String? = nil, repoKey: String? = nil, totalTokens: Int, attempts: Int, cap: Int? = nil) {
            self.issueID = issueID
            self.identifier = identifier
            self.title = title
            self.repoKey = repoKey
            self.totalTokens = totalTokens
            self.attempts = attempts
            self.cap = cap
        }
    }

    public var days: Int
    public var dailyBudget: Int?
    public var perTicketCap: Int?
    public var tokensPerDay: [Day]
    public var tickets: [Ticket]
    /// Tickets merged per UTC day, by date.
    public var mergedPerDay: [(date: String, merged: Int)]
    /// How far the Code Review agent can be trusted; nil from a Symphony that doesn't serve it.
    public var review: ReviewHistory?

    public init(
        days: Int,
        dailyBudget: Int? = nil,
        perTicketCap: Int? = nil,
        tokensPerDay: [Day] = [],
        tickets: [Ticket] = [],
        mergedPerDay: [(date: String, merged: Int)] = [],
        review: ReviewHistory? = nil
    ) {
        self.days = days
        self.dailyBudget = dailyBudget
        self.perTicketCap = perTicketCap
        self.tokensPerDay = tokensPerDay
        self.tickets = tickets
        self.mergedPerDay = mergedPerDay
        self.review = review
    }

    public static func == (lhs: HistoryPayload, rhs: HistoryPayload) -> Bool {
        lhs.days == rhs.days && lhs.dailyBudget == rhs.dailyBudget && lhs.perTicketCap == rhs.perTicketCap
            && lhs.tokensPerDay == rhs.tokensPerDay && lhs.tickets == rhs.tickets
            && lhs.mergedPerDay.map(\.date) == rhs.mergedPerDay.map(\.date)
            && lhs.mergedPerDay.map(\.merged) == rhs.mergedPerDay.map(\.merged) && lhs.review == rhs.review
    }

    /// The path that asks for `days` days.
    public static func path(days: Int) -> String { "\(path)?days=\(days)" }

    /// The history in a payload, nil when it isn't one (an error, or not JSON).
    public static func decode(_ data: Data) -> HistoryPayload? {
        guard let payload = try? InboxPayload.decoder.decode(Payload.self, from: data), let days = payload.days else { return nil }
        return HistoryPayload(
            days: days,
            dailyBudget: payload.dailyBudget,
            perTicketCap: payload.perTicketCap,
            tokensPerDay: (payload.tokensPerDay ?? []).map { Day(date: $0.date, totalTokens: $0.totalTokens ?? 0, providers: $0.providers ?? [:]) },
            tickets: (payload.tickets ?? []).compactMap { ticket in
                guard let identifier = ticket.identifier else { return nil }
                return Ticket(
                    issueID: ticket.issueId ?? identifier, identifier: identifier, title: ticket.title, repoKey: ticket.repoKey,
                    totalTokens: ticket.totalTokens ?? 0, attempts: ticket.attempts ?? 0, cap: ticket.cap
                )
            },
            mergedPerDay: (payload.mergedPerDay ?? []).map { (date: $0.date, merged: $0.merged ?? 0) },
            review: payload.review?.review
        )
    }

    struct Payload: Decodable {
        struct Day: Decodable {
            let date: String
            let totalTokens: Int?
            let providers: [String: Int]?
        }

        struct Ticket: Decodable {
            let issueId: String?
            let identifier: String?
            let title: String?
            let repoKey: String?
            let totalTokens: Int?
            let attempts: Int?
            let cap: Int?
        }

        struct Merged: Decodable {
            let date: String
            let merged: Int?
        }

        let days: Int?
        let dailyBudget: Int?
        let perTicketCap: Int?
        let tokensPerDay: [Day]?
        let tickets: [Ticket]?
        let mergedPerDay: [Merged]?
        let review: ReviewHistory.Payload?
    }
}

/// A provider as a chart series: its place in the fixed categorical order (design system §3.3) never changes, so
/// Claude is always `chart.series1` whichever providers a period has.
public enum UsageProvider: String, CaseIterable, Equatable, Comparable {
    case anthropic, openai, openrouter, unknown

    public init(_ raw: String) {
        self = UsageProvider(rawValue: raw) ?? .unknown
    }

    public var name: String {
        switch self {
        case .anthropic: "Claude"
        case .openai: "Codex"
        case .openrouter: "OpenRouter"
        case .unknown: "Other"
        }
    }

    public var series: DesignTokens.ChartSeries {
        switch self {
        case .anthropic: .series1
        case .openai: .series2
        case .openrouter: .series3
        case .unknown: .series4
        }
    }

    public static func < (lhs: UsageProvider, rhs: UsageProvider) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// D8: tokens per bucket by provider for the Insights slice (TP-1463), against the daily budget by day, today against the
/// budget, the provider limits and the slice's heaviest tickets.
public struct Usage: Equatable {
    /// A row of Heaviest tickets with its meter against the cap.
    public struct TicketRow: Equatable, Identifiable {
        public var id: String { identifier }
        public var identifier: String
        public var tokens: Int
        /// From 0 to 1 against the cap; nil without one.
        public var fraction: Double?
        /// "182K of 500K".
        public var value: String
        public var level: Overview.Meter.Level { Overview.level(fraction) }
    }

    public static let todayTitle = "Today"
    public static let limitsTitle = "Provider limits"
    public static let heaviestTitle = "Heaviest tickets"
    public static let showDataTitle = "Show Data"
    public static let heaviestLimit = 5

    /// Tokens per bucket, stacked by provider in the fixed series order; the daily budget's line by day.
    public var chart: InsightsChart
    /// Today against the budget, with the per-ticket cap.
    public var today: [Overview.Meter]
    /// Each provider limit with its reset (C11).
    public var limits: [Overview.Meter]
    public var heaviest: [TicketRow]
    /// Nil while the slice used tokens.
    public var empty: InsightsEmpty?

    public init(
        aggregate: AggregatePayload, slice: InsightsSlice, snapshot: StateSnapshot?, today day: String, now: Date = Date(),
        timeZone: TimeZone = .current
    ) {
        let budget = slice.unit == .day ? snapshot?.budget?.dailyLimit.map { InsightsChart.Reference(title: "Daily budget", value: $0) } : nil
        chart = InsightsChart.build(
            aggregate.tokens, unit: aggregate.unit, title: "Tokens \(aggregate.unit.per)", measure: "Tokens", format: .tokens,
            reference: budget, fallback: UsageProvider.unknown.rawValue, order: UsageProvider.allCases.map(\.rawValue)
        ) { raw in
            let provider = UsageProvider(raw)
            return InsightsChart.Key(key: provider.rawValue, name: provider.name, tint: .series(provider.series))
        }
        let meters = snapshot.map { Overview.meters($0, reference: now, timeZone: timeZone) } ?? []
        var today = meters.filter { $0.id == "tokens" }
        let cap = snapshot?.budget?.perIssueLimit
        if let cap {
            today.append(Overview.Meter(id: "cap", label: "Per-ticket cap", value: "\(Overview.tokens(cap)) tokens", fraction: nil, note: nil))
        }
        self.today = today
        limits = meters.filter { $0.id != "tokens" }
        heaviest = aggregate.tokens.tickets
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(Self.heaviestLimit)
            .map { identifier, tokens in
                TicketRow(
                    identifier: identifier, tokens: tokens,
                    fraction: cap.flatMap { $0 > 0 ? min(Double(tokens) / Double($0), 1) : nil },
                    value: cap.map { "\(Overview.tokens(tokens)) of \(Overview.tokens($0))" } ?? Overview.tokens(tokens)
                )
            }
        empty = chart.total > 0 ? nil : slice.empty("No tokens used", today: day)
    }

    /// "Oct 13".
    public static func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    static func utcDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}
