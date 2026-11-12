import Foundation

// MARK: - The control bar's choice

/// The control bar's unit: how wide each bar of the Insights charts is, as `GET /api/v1/aggregate`'s `unit` names it.
public enum InsightsUnit: String, CaseIterable, Codable, Identifiable {
    case halfHour = "30m"
    case hour = "1h"
    case sixHours = "6h"
    case day
    case week

    public var id: String { rawValue }

    /// The pop-up's words: "30 min", "Hourly", "6 h", "Daily", "Weekly".
    public var title: String {
        switch self {
        case .halfHour: "30 min"
        case .hour: "Hourly"
        case .sixHours: "6 h"
        case .day: "Daily"
        case .week: "Weekly"
        }
    }

    /// The summary line's words: "by day".
    public var phrase: String {
        switch self {
        case .halfHour: "by 30 min"
        case .hour: "by hour"
        case .sixHours: "by 6 h"
        case .day: "by day"
        case .week: "by week"
        }
    }

    /// A chart's title words: "per day".
    public var per: String {
        switch self {
        case .halfHour: "per 30 min"
        case .hour: "per hour"
        case .sixHours: "per 6 h"
        case .day: "per day"
        case .week: "per week"
        }
    }

    /// A bucket's length.
    public var seconds: Int {
        switch self {
        case .halfHour: 1_800
        case .hour: 3_600
        case .sixHours: 21_600
        case .day: 86_400
        case .week: 604_800
        }
    }

    /// Whether a bucket is a day or longer: its label is a date without a time.
    public var isDaily: Bool { seconds >= 86_400 }
}

/// The period pop-up's presets: whole UTC days that end today.
public enum InsightsPreset: Int, CaseIterable, Codable, Identifiable {
    case today = 1
    case week = 7
    case month = 30
    case quarter = 90
    case year = 365

    public var id: Int { rawValue }

    /// "Today", "Last 7 days".
    public var title: String { self == .today ? "Today" : "Last \(rawValue) days" }
}

/// The period: a preset, or a range of UTC days, both ends taken in.
public enum InsightsPeriod: Hashable, Codable {
    case preset(InsightsPreset)
    /// "2026-11-01" to "2026-11-07".
    case range(from: String, to: String)

    /// The most days the aggregation reads in one period.
    public static let maxDays = 366

    /// "Last 7 days", "Today", "Nov 1 – Nov 7".
    public var title: String {
        switch self {
        case let .preset(preset): preset.title
        case let .range(from, to):
            from == to ? Insights.dayLabel(from) : "\(Insights.dayLabel(from)) – \(Insights.dayLabel(to))"
        }
    }

    /// The words after "Nothing shipped": "today", "in the last 7 days", "from Nov 1 to Nov 7".
    public var phrase: String {
        switch self {
        case .preset(.today): "today"
        case let .preset(preset): "in the last \(preset.rawValue) days"
        case let .range(from, to): from == to ? "on \(Insights.dayLabel(from))" : "from \(Insights.dayLabel(from)) to \(Insights.dayLabel(to))"
        }
    }

    /// The first and the last day, "2026-11-06" and "2026-11-12", for `today`, Symphony's UTC day. A range comes in
    /// order and at most `maxDays` long, ending on its last day.
    public func days(today: String) -> (from: String, to: String) {
        switch self {
        case let .preset(preset):
            return (Insights.day(today, adding: 1 - preset.rawValue), today)
        case let .range(from, to):
            let (first, last) = from <= to ? (from, to) : (to, from)
            let earliest = Insights.day(last, adding: 1 - Self.maxDays)
            return (max(first, earliest), last)
        }
    }

    /// How many days the period spans.
    public func dayCount(today: String) -> Int {
        let (from, to) = days(today: today)
        return Insights.daysBetween(from, to) + 1
    }

    /// The period the empty state's button widens to: the shortest preset longer than this one; nil past a year.
    public func wider(today: String) -> InsightsPeriod? {
        let count = dayCount(today: today)
        return InsightsPreset.allCases.first { $0.rawValue > count }.map(InsightsPeriod.preset)
    }
}

/// The Insights control bar's choice (TP-1463): the period, the unit, the repo and the epic. Quality, Usage and
/// Shipped read the same slice from `GET /api/v1/aggregate`, so the choice travels between the three pages; the app
/// remembers it across relaunches under `defaultsKey`.
public struct InsightsSlice: Equatable, Codable {
    public static let defaultsKey = "SymphonyInsightsSlice"
    public static let path = "api/v1/aggregate"
    /// The series the three pages draw, read at once so a page switch reads nothing.
    public static let series = ["tokens", "runs", "verdicts", "shipped"]
    /// The most bars a chart draws: a finer unit over a longer period is offered no more.
    public static let maxBuckets = 750
    public static let allEpics = "All epics"

    public var period: InsightsPeriod
    public var unit: InsightsUnit
    /// A repository's key; nil reads the window's scope.
    public var repo: String?
    /// An epic's identifier: the epic and its sub-tickets.
    public var epic: String?

    public init(period: InsightsPeriod = .preset(.week), unit: InsightsUnit = .day, repo: String? = nil, epic: String? = nil) {
        self.period = period
        self.unit = unit
        self.repo = repo
        self.epic = epic
    }

    /// Whether the slice narrows to a repo or an epic: the bar's Clear shows only then.
    public var isFiltered: Bool { repo != nil || epic != nil }

    /// Clear: back to every repo (the window's scope) and every epic; the period and the unit stay.
    public mutating func clear() {
        repo = nil
        epic = nil
    }

    /// The read's parameters, in a fixed order: `from`, `to`, `unit`, `repo`, `epic`, `series`. The repo control wins
    /// over the window's `scope`.
    public func parameters(today: String, scope: OverviewScope = .all) -> [(name: String, value: String)] {
        let (from, to) = period.days(today: today)
        var parameters: [(name: String, value: String)] = [("from", from), ("to", to), ("unit", unit.rawValue)]
        if let repo = repo ?? scope.stored { parameters.append(("repo", repo)) }
        if let epic { parameters.append(("epic", epic)) }
        parameters.append(("series", Self.series.joined(separator: ",")))
        return parameters
    }

    /// `api/v1/aggregate?from=…&to=…&unit=day&series=tokens,runs,verdicts,shipped`.
    public func path(today: String, scope: OverviewScope = .all) -> String {
        Self.path + "?" + parameters(today: today, scope: scope).map { "\($0.name)=\(JournalQuery.encode($0.value))" }.joined(separator: "&")
    }

    /// How many bars `unit` draws over the period.
    public func bucketCount(_ unit: InsightsUnit, today: String) -> Int {
        let seconds = period.dayCount(today: today) * 86_400
        // A week starts on a Monday, so a period can touch one more week than it holds.
        return unit == .week ? seconds / unit.seconds + 2 : seconds / unit.seconds
    }

    /// The days `/api/v1/history` and `/api/v1/shipped` read for the slice: from its first day to today, at most the
    /// 90 they serve, and the day before for a merge near midnight (they count the host's days).
    public func daysBack(today: String) -> Int {
        let (from, _) = period.days(today: today)
        return min(max(Insights.daysBetween(from, today) + 2, 1), ShippedPayload.maxDays)
    }

    /// Whether the unit pop-up offers `unit` for this period.
    public func allows(_ unit: InsightsUnit, today: String) -> Bool {
        bucketCount(unit, today: today) <= Self.maxBuckets
    }

    /// Sets the period, and makes the unit coarser when the new period would draw too many bars at it.
    public mutating func choose(_ period: InsightsPeriod, today: String) {
        self.period = period
        if !allows(unit, today: today) {
            unit = InsightsUnit.allCases.first { $0.seconds > unit.seconds && allows($0, today: today) } ?? .week
        }
    }

    /// The repo the read keeps to, the control's or the window's scope; nil for all repos.
    public func repoKey(scope: OverviewScope) -> String? { repo ?? scope.stored }

    /// The summary line's slice: "Last 7 days by day, symphony, epic TP-1381".
    public func title(scope: OverviewScope) -> String {
        var parts = ["\(period.title) \(unit.phrase)", repoKey(scope: scope) ?? OverviewScope.allTitle.lowercased()]
        if let epic { parts.append("epic \(epic)") }
        return parts.joined(separator: ", ")
    }

    /// What a page says when its slice holds nothing, with the period one step wider as its one way out.
    public func empty(_ nothing: String, today: String) -> InsightsEmpty {
        InsightsEmpty(title: "\(nothing) \(period.phrase).", widen: period.wider(today: today))
    }

    /// The slice remembered in `defaults`, the last 7 days by day when none is.
    public static func load(from defaults: KeyValueStore) -> InsightsSlice {
        guard let data = defaults.object(forKey: defaultsKey) as? Data, let slice = try? JSONDecoder().decode(Self.self, from: data) else {
            return InsightsSlice()
        }
        return slice
    }

    /// Remembers the slice in `defaults`.
    public func save(to defaults: KeyValueStore) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}

/// The repo and epic pop-ups' choices: the repos Symphony has tickets in and the epics it lists, sorted. A picked one
/// Symphony no longer lists stays a choice, so a remembered slice is never silently dropped.
public struct InsightsControlValues: Equatable {
    public var repos: [String]
    public var epics: [String]

    public init(repos: [String] = [], epics: [String] = [], slice: InsightsSlice = InsightsSlice()) {
        self.repos = Set(repos + [slice.repo].compactMap(\.self)).sorted()
        self.epics = Set(epics + [slice.epic].compactMap(\.self)).sorted()
    }
}

/// What a page says when its slice holds nothing, and its one way out: a wider period.
public struct InsightsEmpty: Equatable {
    public var title: String
    /// The period the button widens to; nil when no preset is wider.
    public var widen: InsightsPeriod?

    public init(title: String, widen: InsightsPeriod?) {
        self.title = title
        self.widen = widen
    }

    /// "Show Last 30 Days".
    public var actionTitle: String? {
        widen.map { "Show \($0.title.capitalized)" }
    }
}

// MARK: - The read

/// `GET /api/v1/aggregate`'s answer: each series' total over the period, by key and by ticket, and one bucket per unit.
public struct AggregatePayload: Equatable {
    public struct Bucket: Equatable {
        public var start: Date
        public var value: Int
        public var by: [String: Int]
        /// The tickets of the bucket, for `shipped`.
        public var tickets: [String]

        public init(start: Date, value: Int, by: [String: Int] = [:], tickets: [String] = []) {
            self.start = start
            self.value = value
            self.by = by
            self.tickets = tickets
        }
    }

    public struct Series: Equatable {
        public var total: Int
        public var by: [String: Int]
        public var tickets: [String: Int]
        public var buckets: [Bucket]

        public init(total: Int = 0, by: [String: Int] = [:], tickets: [String: Int] = [:], buckets: [Bucket] = []) {
            self.total = total
            self.by = by
            self.tickets = tickets
            self.buckets = buckets
        }
    }

    public var unit: InsightsUnit
    public var series: [String: Series]

    public init(unit: InsightsUnit = .day, series: [String: Series] = [:]) {
        self.unit = unit
        self.series = series
    }

    public var tokens: Series { series["tokens"] ?? Series() }
    public var runs: Series { series["runs"] ?? Series() }
    public var verdicts: Series { series["verdicts"] ?? Series() }
    public var shipped: Series { series["shipped"] ?? Series() }

    /// The answer in `data`, nil when it isn't one (an error, or not JSON). Read without the snake-case keys: the
    /// series' keys (`code_review:approve`, a repo's key) are data.
    public static func decode(_ data: Data) -> AggregatePayload? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data), let series = payload.series else { return nil }
        return AggregatePayload(
            unit: payload.unit.flatMap(InsightsUnit.init(rawValue:)) ?? .day,
            series: series.mapValues { series in
                Series(
                    total: series.total ?? 0, by: series.by ?? [:], tickets: series.tickets ?? [:],
                    buckets: (series.buckets ?? []).compactMap { bucket in
                        guard let start = bucket.start.flatMap(Shipped.parseDate) else { return nil }
                        return Bucket(start: start, value: bucket.value ?? 0, by: bucket.by ?? [:], tickets: bucket.tickets ?? [])
                    }
                )
            }
        )
    }

    struct Payload: Decodable {
        struct Bucket: Decodable {
            let start: String?
            let value: Int?
            let by: [String: Int]?
            let tickets: [String]?
        }

        struct Series: Decodable {
            let total: Int?
            let by: [String: Int]?
            let tickets: [String: Int]?
            let buckets: [Bucket]?
        }

        let unit: String?
        let series: [String: Series]?
    }
}

/// What the window knows of the aggregate read (TP-1463): the last answer and the read it answers, and the read that
/// last failed with what it got. A slice is read again when it changes, or at most once per interval: a failing read
/// waits the interval like any other, so it isn't sent again on every poll.
public struct AggregateRead: Equatable {
    /// What an Insights page shows for a read.
    public enum Shown: Equatable {
        /// The read hasn't answered yet.
        case reading
        case loaded(AggregatePayload)
        /// Symphony predates the read (`EndpointPlaceholder.updateSymphony`).
        case unsupported
        /// The read failed, with what went wrong; Try Again reads it again.
        case failed(String)
    }

    public static let undecodable = "Symphony's answer couldn't be read"

    public private(set) var payload: AggregatePayload?
    /// The read `payload` answers.
    public private(set) var path: String?
    /// The read that last failed, and what it got.
    public private(set) var failedPath: String?
    public private(set) var failure: Shown?
    /// The last read, answered or failed, and when.
    public private(set) var readPath: String?
    public private(set) var readAt: Date?

    public init() {}

    /// Whether `path` is due a read at `now`: never read, another read than the last, or the last is `interval` old.
    public func isDue(_ path: String, now: Date, interval: TimeInterval) -> Bool {
        guard let readAt, path == readPath else { return true }
        return now.timeIntervalSince(readAt) >= interval
    }

    /// Keeps what `path`'s read got at `now`.
    public mutating func record(_ path: String, _ result: EndpointResult, now: Date) {
        if case let .loaded(data) = result, let payload = AggregatePayload.decode(data) {
            self.payload = payload
            self.path = path
            if failedPath == path { (failedPath, failure) = (nil, nil) }
        } else {
            failedPath = path
            failure = switch result {
            case let .failed(message): .failed(message)
            case .unsupported: .unsupported
            case .loaded: .failed(Self.undecodable)
            }
        }
        readPath = path
        readAt = now
    }

    /// Makes the next check read again at once (Try Again, a page opened).
    public mutating func expire() { readAt = nil }

    /// What a page drawing `path` shows: its answer, else its failure, else that it is reading.
    public func shown(_ path: String) -> Shown {
        if path == self.path, let payload { return .loaded(payload) }
        guard path == failedPath, let failure else { return .reading }
        return failure
    }
}

// MARK: - A chart

/// C12 over a series of the aggregate: one bar per bucket, stacked by key, at most one reference line, the value on the
/// last bar, hover values, Show Data and a chart description. Quality, Usage and Shipped draw theirs with it.
public struct InsightsChart: Equatable {
    /// A key's color: a series color for categories (providers), a status color for outcomes.
    public enum Tint: Hashable {
        case series(DesignTokens.ChartSeries)
        case status(DesignTokens.Status)
    }

    /// A stacked key, with its legend name and color.
    public struct Key: Hashable, Identifiable {
        public var id: String { key }
        public var key: String
        public var name: String
        public var tint: Tint

        public init(key: String, name: String, tint: Tint) {
            self.key = key
            self.name = name
            self.tint = tint
        }
    }

    /// A bucket's bar.
    public struct Bar: Equatable, Identifiable {
        /// The bucket's start, "2026-11-06T00:00:00Z": unique, so the chart plots it as a category.
        public var id: String
        public var start: Date
        /// "Nov 6", or "Nov 6 14:00" for a unit shorter than a day.
        public var label: String
        public var values: [String: Int]

        public var total: Int { values.values.reduce(0, +) }
    }

    /// How a value reads.
    public enum Format: Equatable {
        case tokens
        case count
    }

    /// A line across the chart: the daily budget.
    public struct Reference: Equatable {
        public var title: String
        public var value: Int
    }

    public var title: String
    /// The value axis: "Tokens", "Runs".
    public var measure: String
    public var keys: [Key]
    public var bars: [Bar]
    public var format: Format
    public var reference: Reference?

    /// Builds the chart of `series`, each raw key of a bucket's `by` mapped to its stacked key by `key`; the keys come
    /// in `order`'s order, then by name. A bucket without a `by` stacks its value under `fallback`.
    public static func build(
        _ series: AggregatePayload.Series, unit: InsightsUnit, title: String, measure: String, format: Format,
        reference: Reference? = nil, fallback: String, order: [String] = [], key: (String) -> Key
    ) -> InsightsChart {
        var keys: [String: Key] = [:]
        let bars = series.buckets.map { bucket in
            var values: [String: Int] = [:]
            let by = bucket.by.isEmpty && bucket.value != 0 ? [fallback: bucket.value] : bucket.by
            for (raw, value) in by where value != 0 {
                let mapped = key(raw)
                keys[mapped.key] = mapped
                values[mapped.key, default: 0] += value
            }
            return Bar(id: Insights.iso(bucket.start), start: bucket.start, label: Insights.bucketLabel(bucket.start, unit: unit), values: values)
        }
        let sorted = keys.values.sorted { lhs, rhs in
            let (left, right) = (order.firstIndex(of: lhs.key) ?? order.count, order.firstIndex(of: rhs.key) ?? order.count)
            return left == right ? lhs.name < rhs.name : left < right
        }
        return InsightsChart(title: title, measure: measure, keys: sorted, bars: bars, format: format, reference: reference)
    }

    /// A key's part of a bar: one stacked mark, bottom first in the keys' order.
    public struct Segment: Equatable, Identifiable {
        public var id: String { "\(bar)-\(key.key)" }
        public var bar: String
        public var key: Key
        public var value: Int
        /// The bar's top mark, which carries the last bar's value.
        public var isTop: Bool
    }

    /// The marks the chart stacks.
    public var segments: [Segment] {
        bars.flatMap { bar in
            let parts = keys.compactMap { key in bar.values[key.key].map { (key, $0) } }
            return parts.enumerated().map { index, part in
                Segment(bar: bar.id, key: part.0, value: part.1, isTop: index == parts.count - 1)
            }
        }
    }

    /// Every bar's total: the figure the summary line gives for this chart.
    public var total: Int { bars.reduce(0) { $0 + $1.total } }

    /// "1.2M" for tokens, "14" for a count.
    public func value(_ value: Int) -> String {
        switch format {
        case .tokens: Overview.tokens(value)
        case .count: String(value)
        }
    }

    /// The last bar, which carries its value (C12), when it has one.
    public var lastValue: (id: String, text: String)? {
        guard let last = bars.last, last.total > 0 else { return nil }
        return (last.id, value(last.total))
    }

    /// The hover line of a bar: "Nov 6: Claude 1.2M, Codex 300K; 1.5M in all".
    public func hoverLine(_ id: String) -> String {
        guard let bar = bars.first(where: { $0.id == id }) else { return "" }
        let parts = keys.compactMap { key in bar.values[key.key].map { "\(key.name) \(value($0))" } }
        guard !parts.isEmpty else { return "\(bar.label): none" }
        guard parts.count > 1 else { return "\(bar.label): \(parts[0])" }
        return "\(bar.label): \(parts.joined(separator: ", ")); \(value(bar.total)) in all"
    }

    /// Show Data's table: a header row, then one row per bar with each key's value and the bar's total.
    public var dataTable: [[String]] {
        let header = [Insights.bucketColumn] + keys.map(\.name) + ["Total"]
        let rows = bars.map { bar in [bar.label] + keys.map { String(bar.values[$0.key] ?? 0) } + [String(bar.total)] }
        return [header] + rows
    }

    /// The chart's accessibility summary, for its `AXChartDescriptor`.
    public var summary: String {
        let reference = reference.map { " The \($0.title.lowercased()) is \(value($0.value))." } ?? ""
        guard let peak = bars.max(by: { $0.total < $1.total }), peak.total > 0 else {
            return "\(title): none over \(bars.count) bars.\(reference)"
        }
        let names = ListFormatter.localizedString(byJoining: keys.map(\.name))
        return "\(title) for \(names) over \(bars.count) bars, \(value(total)) in all. The most was \(value(peak.total)) on \(peak.label).\(reference)"
    }

    /// The bars that carry an axis label: about seven, whatever the unit.
    public var labelled: [String] {
        let step = max(bars.count / 7, 1)
        return bars.enumerated().filter { $0.offset % step == 0 }.map(\.element.id)
    }

    /// A bar's label by its id.
    public func label(_ id: String) -> String {
        bars.first { $0.id == id }?.label ?? id
    }

    /// A bar's label under the axis, short enough to fit between the labelled bars: its day ("Nov 6") when it starts
    /// a UTC day, its time ("06:00") otherwise.
    public func axisLabel(_ id: String) -> String {
        guard let bar = bars.first(where: { $0.id == id }) else { return id }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let time = utc.dateComponents([.hour, .minute], from: bar.start)
        guard time.hour != 0 || time.minute != 0 else { return Insights.bucketLabel(bar.start, unit: .day) }
        return String(format: "%02d:%02d", time.hour ?? 0, time.minute ?? 0)
    }
}

// MARK: - The summary line

public enum Insights {
    public static let bucketColumn = "Period"

    /// The control bar's width from which the summary sits beside the controls (a desktop); under it, the summary has
    /// its own line under them (a laptop), as the catalog's Control bar section draws it.
    public static let summaryBesideWidth: Double = 1600

    /// Whether a control bar `width` wide draws the summary beside its controls.
    public static func summaryBeside(width: Double) -> Bool { width >= summaryBesideWidth }

    /// The summary line under the controls: "Last 7 days by day, symphony, epic TP-1381: 14 shipped, 31M tokens, 52 runs".
    /// Its figures are the charts' totals, read from the same buckets the charts draw.
    public static func summary(_ aggregate: AggregatePayload, slice: InsightsSlice, scope: OverviewScope) -> String {
        let shipped = bucketTotal(aggregate.shipped)
        let tokens = bucketTotal(aggregate.tokens)
        let runs = bucketTotal(aggregate.runs)
        let figures = "\(shipped) shipped, \(Overview.tokens(tokens)) tokens, \(runs) \(runs == 1 ? "run" : "runs")"
        return "\(slice.title(scope: scope)): \(figures)"
    }

    /// A series' value over its buckets.
    public static func bucketTotal(_ series: AggregatePayload.Series) -> Int {
        series.buckets.reduce(0) { $0 + $1.value }
    }

    /// Symphony's UTC day of `date`, "2026-11-12": the day the presets end on.
    public static func today(_ date: Date) -> String { Quality.isoDay(date) }

    /// "Nov 6" for a day, "Nov 6 14:00" for a shorter bucket, in UTC as the aggregation buckets.
    public static func bucketLabel(_ start: Date, unit: InsightsUnit) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = unit.isDaily ? "MMM d" : "MMM d HH:mm"
        return formatter.string(from: start)
    }

    /// "Nov 6" for "2026-11-06".
    static func dayLabel(_ day: String) -> String {
        Usage.utcDate(day).map(Usage.dayLabel) ?? day
    }

    /// The UTC day `days` after `day`.
    static func day(_ day: String, adding days: Int) -> String {
        guard let date = Usage.utcDate(day), let moved = Shipped.calendar.date(byAdding: .day, value: days, to: date) else { return day }
        return Quality.isoDay(moved)
    }

    static func daysBetween(_ from: String, _ to: String) -> Int {
        guard let start = Usage.utcDate(from), let end = Usage.utcDate(to) else { return 0 }
        return Shipped.calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
