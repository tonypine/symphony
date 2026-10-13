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

    public init(
        days: Int,
        dailyBudget: Int? = nil,
        perTicketCap: Int? = nil,
        tokensPerDay: [Day] = [],
        tickets: [Ticket] = [],
        mergedPerDay: [(date: String, merged: Int)] = []
    ) {
        self.days = days
        self.dailyBudget = dailyBudget
        self.perTicketCap = perTicketCap
        self.tokensPerDay = tokensPerDay
        self.tickets = tickets
        self.mergedPerDay = mergedPerDay
    }

    public static func == (lhs: HistoryPayload, rhs: HistoryPayload) -> Bool {
        lhs.days == rhs.days && lhs.dailyBudget == rhs.dailyBudget && lhs.perTicketCap == rhs.perTicketCap
            && lhs.tokensPerDay == rhs.tokensPerDay && lhs.tickets == rhs.tickets
            && lhs.mergedPerDay.map(\.date) == rhs.mergedPerDay.map(\.date)
            && lhs.mergedPerDay.map(\.merged) == rhs.mergedPerDay.map(\.merged)
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
            mergedPerDay: (payload.mergedPerDay ?? []).map { (date: $0.date, merged: $0.merged ?? 0) }
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

/// D8: tokens per day by provider against the daily budget, today against the budget, the provider limits and the
/// heaviest tickets.
public struct Usage: Equatable {
    /// A provider's tokens on a day: one stacked segment of the day's bar.
    public struct Segment: Equatable, Identifiable {
        public var id: String { "\(date)-\(provider.rawValue)" }
        public var date: Date
        public var provider: UsageProvider
        public var tokens: Int
    }

    /// A row of Heaviest tickets with its meter against the cap.
    public struct TicketRow: Equatable, Identifiable {
        public var id: String { identifier }
        public var identifier: String
        public var title: String?
        public var tokens: Int
        public var attempts: Int
        /// From 0 to 1 against the cap; nil without one.
        public var fraction: Double?
        /// "182K of 500K, 2 attempts".
        public var value: String
        public var level: Overview.Meter.Level { Overview.level(fraction) }
    }

    public static let tokensTitle = "Tokens per day"
    public static let todayTitle = "Today"
    public static let limitsTitle = "Provider limits"
    public static let heaviestTitle = "Heaviest tickets"
    public static let showDataTitle = "Show Data"
    public static let heaviestLimit = 5

    public var segments: [Segment]
    /// The days the chart spans, oldest first, each once even without tokens.
    public var dates: [Date]
    /// The providers that used tokens in the period, in the fixed series order.
    public var providers: [UsageProvider]
    public var dailyBudget: Int?
    /// Today against the budget, with the per-ticket cap.
    public var today: [Overview.Meter]
    /// Each provider limit with its reset (C11).
    public var limits: [Overview.Meter]
    public var heaviest: [TicketRow]

    public init(history: HistoryPayload, snapshot: StateSnapshot?, now: Date = Date(), timeZone: TimeZone = .current) {
        let days = history.tokensPerDay.compactMap { day in Self.utcDate(day.date).map { (date: $0, day: day) } }
        dates = days.map(\.date)
        segments = days.flatMap { entry in
            entry.day.providers
                .map { (provider: UsageProvider($0.key), tokens: $0.value) }
                .reduce(into: [UsageProvider: Int]()) { $0[$1.provider, default: 0] += $1.tokens }
                .filter { $0.value > 0 }
                .sorted { $0.key < $1.key }
                .map { Segment(date: entry.date, provider: $0.key, tokens: $0.value) }
        }
        providers = Set(segments.map(\.provider)).sorted()
        dailyBudget = history.dailyBudget
        let meters = snapshot.map { Overview.meters($0, reference: now, timeZone: timeZone) } ?? []
        var today = meters.filter { $0.id == "tokens" }
        if let cap = snapshot?.budget?.perIssueLimit ?? history.perTicketCap {
            today.append(Overview.Meter(id: "cap", label: "Per-ticket cap", value: "\(Overview.tokens(cap)) tokens", fraction: nil, note: nil))
        }
        self.today = today
        limits = meters.filter { $0.id != "tokens" }
        heaviest = history.tickets
            .sorted { ($0.totalTokens, $1.identifier) > ($1.totalTokens, $0.identifier) }
            .prefix(Self.heaviestLimit)
            .map { ticket in
                let cap = ticket.cap ?? history.perTicketCap
                let attempts = ticket.attempts == 1 ? "1 attempt" : "\(ticket.attempts) attempts"
                let amount = cap.map { "\(Overview.tokens(ticket.totalTokens)) of \(Overview.tokens($0))" } ?? Overview.tokens(ticket.totalTokens)
                return TicketRow(
                    identifier: ticket.identifier, title: ticket.title, tokens: ticket.totalTokens, attempts: ticket.attempts,
                    fraction: cap.flatMap { $0 > 0 ? min(Double(ticket.totalTokens) / Double($0), 1) : nil },
                    value: "\(amount), \(attempts)"
                )
            }
    }

    /// A day's tokens over every provider.
    public func total(on date: Date) -> Int {
        segments.filter { $0.date == date }.reduce(0) { $0 + $1.tokens }
    }

    /// The hover line of a day's bar: "Oct 13: Claude 1.2M, Codex 300K; 1.5M in all".
    public func hoverLine(on date: Date) -> String {
        let parts = segments.filter { $0.date == date }.map { "\($0.provider.name) \(Overview.tokens($0.tokens))" }
        let day = Self.dayLabel(date)
        guard !parts.isEmpty else { return "\(day): no tokens" }
        return "\(day): \(parts.joined(separator: ", ")); \(Overview.tokens(total(on: date))) in all"
    }

    /// Show Data's table: a header row, then one row per day with each provider's tokens and the day's total.
    public var dataTable: [[String]] {
        let header = ["Day"] + providers.map(\.name) + ["Total"]
        let rows = dates.map { date in
            [Self.dayLabel(date)]
                + providers.map { provider in String(segments.first { $0.date == date && $0.provider == provider }?.tokens ?? 0) }
                + [String(total(on: date))]
        }
        return [header] + rows
    }

    /// The chart's accessibility summary, for its `AXChartDescriptor`.
    public var chartSummary: String {
        let totals = dates.map(total(on:))
        let budget = dailyBudget.map { " The daily budget is \(Overview.tokens($0)) tokens." } ?? ""
        guard let peak = totals.max(), peak > 0, let peakDate = dates.first(where: { total(on: $0) == peak }) else {
            return "No tokens used in the last \(dates.count) days.\(budget)"
        }
        let names = ListFormatter.localizedString(byJoining: providers.map(\.name))
        return "Tokens per day for \(names) over \(dates.count) days. The most was \(Overview.tokens(peak)) on \(Self.dayLabel(peakDate)).\(budget)"
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
