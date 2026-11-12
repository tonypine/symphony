import XCTest
@testable import SymphonyBarCore

/// The Insights control bar (TP-1463) over the `insights` fixture: Nov 6–12, 2026 by day, by 6 h and kept to epic
/// TP-1381, as `GET /api/v1/aggregate` serves them, on Symphony's day 2026-11-12.
final class InsightsTests: XCTestCase {
    private static let api = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/director-app/insights/api/v1")

    private let today = "2026-11-12"
    private let epicSlice = InsightsSlice(period: .preset(.week), unit: .day, epic: "TP-1381")

    private func data(_ name: String) throws -> Data {
        try Data(contentsOf: Self.api.appendingPathComponent("\(name).json"))
    }

    /// The fixture's answer to `slice`'s read, by the file its query names, as QA's fixtures answer it.
    private func aggregate(_ slice: InsightsSlice = InsightsSlice()) throws -> AggregatePayload {
        let query = slice.path(today: today).split(separator: "?", maxSplits: 1).last.map(String.init) ?? ""
        let file = Self.api.appendingPathComponent("aggregate.\(query).json")
        let data = try FileManager.default.fileExists(atPath: file.path) ? Data(contentsOf: file) : self.data("aggregate")
        return try XCTUnwrap(AggregatePayload.decode(data))
    }

    private func snapshot() throws -> StateSnapshot? {
        try XCTUnwrap(OverviewState.decode(data("state"))).snapshot
    }

    // MARK: - Each control and its parameter

    func testEachControlMapsToItsQueryParameter() {
        let slice = InsightsSlice()
        XCTAssertEqual(
            slice.path(today: today), "api/v1/aggregate?from=2026-11-06&to=2026-11-12&unit=day&series=tokens,runs,verdicts,shipped"
        )

        // The period: a preset ends today, a range keeps its days.
        var period = slice
        period.choose(.preset(.month), today: today)
        XCTAssertEqual(Self.value("from", period), "2026-10-14")
        XCTAssertEqual(Self.value("to", period), "2026-11-12")
        period.choose(.preset(.today), today: today)
        XCTAssertEqual(Self.value("from", period), "2026-11-12")
        period.choose(.range(from: "2026-11-09", to: "2026-11-01"), today: today)
        XCTAssertEqual(Self.value("from", period), "2026-11-01")
        XCTAssertEqual(Self.value("to", period), "2026-11-09")

        // The unit.
        for unit in InsightsUnit.allCases {
            var chosen = slice
            chosen.unit = unit
            XCTAssertEqual(Self.value("unit", chosen), unit.rawValue)
        }
        XCTAssertEqual(InsightsUnit.allCases.map(\.rawValue), ["30m", "1h", "6h", "day", "week"])

        // The repo: the control's, else the window's scope, else none.
        var repo = slice
        XCTAssertNil(Self.value("repo", repo))
        XCTAssertEqual(Self.value("repo", repo, scope: .repo("api")), "api")
        repo.repo = "symphony"
        XCTAssertEqual(Self.value("repo", repo, scope: .repo("api")), "symphony")

        // The epic.
        XCTAssertNil(Self.value("epic", slice))
        XCTAssertEqual(Self.value("epic", epicSlice), "TP-1381")
        XCTAssertEqual(
            epicSlice.path(today: today, scope: .repo("symphony")),
            "api/v1/aggregate?from=2026-11-06&to=2026-11-12&unit=day&repo=symphony&epic=TP-1381&series=tokens,runs,verdicts,shipped"
        )
    }

    func testALongPeriodMakesTheUnitCoarser() {
        var slice = InsightsSlice(period: .preset(.today), unit: .halfHour)
        XCTAssertEqual(slice.bucketCount(.halfHour, today: today), 48)
        slice.choose(.preset(.month), today: today)
        XCTAssertEqual(slice.unit, .hour, "720 hourly bars are the most a month draws")
        slice.choose(.preset(.year), today: today)
        XCTAssertEqual(slice.unit, .day)
        XCTAssertFalse(slice.allows(.sixHours, today: today))
        XCTAssertTrue(slice.allows(.week, today: today))
        slice.choose(.range(from: "2020-01-01", to: "2026-11-12"), today: today)
        XCTAssertEqual(slice.period.dayCount(today: today), InsightsPeriod.maxDays)
        XCTAssertEqual(slice.period.days(today: today).from, "2025-11-12")
    }

    func testTheSliceIsRememberedAcrossTheSession() {
        let defaults = MemoryKeyValueStore()
        XCTAssertEqual(InsightsSlice.load(from: defaults), InsightsSlice())
        let slice = InsightsSlice(period: .range(from: "2026-11-01", to: "2026-11-07"), unit: .sixHours, repo: "symphony", epic: "TP-1381")
        slice.save(to: defaults)
        XCTAssertEqual(InsightsSlice.load(from: defaults), slice)
        defaults.set(Data("nope".utf8), forKey: InsightsSlice.defaultsKey)
        XCTAssertEqual(InsightsSlice.load(from: defaults), InsightsSlice())
    }

    func testTheControlsWordsAndChoices() {
        XCTAssertEqual(InsightsPreset.allCases.map(\.title), ["Today", "Last 7 days", "Last 30 days", "Last 90 days", "Last 365 days"])
        XCTAssertEqual(InsightsUnit.allCases.map(\.title), ["30 min", "Hourly", "6 h", "Daily", "Weekly"])
        XCTAssertEqual(InsightsPeriod.range(from: "2026-11-01", to: "2026-11-07").title, "Nov 1 – Nov 7")
        XCTAssertEqual(InsightsPeriod.range(from: "2026-11-01", to: "2026-11-01").phrase, "on Nov 1")
        let values = InsightsControlValues(repos: ["web-shop", "api"], epics: ["TP-1381"], slice: InsightsSlice(repo: "gone", epic: "BIL-300"))
        XCTAssertEqual(values.repos, ["api", "gone", "web-shop"])
        XCTAssertEqual(values.epics, ["BIL-300", "TP-1381"])
    }

    func testClearShowsOnlyForARepoOrAnEpicAndKeepsThePeriodAndUnit() {
        XCTAssertFalse(InsightsSlice().isFiltered)
        XCTAssertTrue(InsightsSlice(repo: "symphony").isFiltered)
        XCTAssertTrue(InsightsSlice(epic: "TP-1381").isFiltered)
        var slice = InsightsSlice(period: .preset(.month), unit: .sixHours, repo: "symphony", epic: "TP-1381")
        slice.clear()
        XCTAssertEqual(slice, InsightsSlice(period: .preset(.month), unit: .sixHours))
        XCTAssertEqual(slice.path(today: today), InsightsSlice(period: .preset(.month), unit: .sixHours).path(today: today))
    }

    func testTheSummarySitsUnderTheControlsOnALaptopAndBesideThemOnADesktop() {
        // The laptop's page (1440 pt less the sidebar) and the desktop's (2560 pt less the sidebar).
        XCTAssertFalse(Insights.summaryBeside(width: 1440 - 200))
        XCTAssertFalse(Insights.summaryBeside(width: 1599))
        XCTAssertTrue(Insights.summaryBeside(width: 1600))
        XCTAssertTrue(Insights.summaryBeside(width: 2560 - 200))
    }

    // MARK: - The summary line and the charts

    func testTheSummaryLinesFiguresEqualTheChartsTotals() throws {
        for slice in [InsightsSlice(), InsightsSlice(unit: .sixHours), epicSlice] {
            let aggregate = try aggregate(slice)
            let usage = Usage(aggregate: aggregate, slice: slice, snapshot: nil, today: today)
            let shipped = Shipped(aggregate: aggregate, slice: slice, details: nil, today: today)
            let quality = Quality(aggregate: aggregate, slice: slice, review: .reading, today: today)
            let figures = "\(shipped.chart.total) shipped, \(Overview.tokens(usage.chart.total)) tokens, \(quality.runsChart.total) runs"
            XCTAssertEqual(Insights.summary(aggregate, slice: slice, scope: .all), "\(slice.title(scope: .all)): \(figures)")
            XCTAssertEqual(usage.chart.total, aggregate.tokens.total)
            XCTAssertEqual(shipped.chart.total, aggregate.shipped.total)
            XCTAssertEqual(quality.runsChart.total, aggregate.runs.total)
        }
        XCTAssertEqual(
            Insights.summary(try aggregate(epicSlice), slice: epicSlice, scope: .repo("symphony")),
            "Last 7 days by day, symphony, epic TP-1381: 8 shipped, 18.3M tokens, 27 runs"
        )
        XCTAssertEqual(Insights.summary(try aggregate(), slice: InsightsSlice(), scope: .all), "Last 7 days by day, all repos: 14 shipped, 31.1M tokens, 50 runs")
    }

    /// The walkthrough: Usage on the last 7 days by day and epic TP-1381 draws seven bars of the epic's spend, and
    /// Shipped, on the same slice, the same seven days.
    func testTheEpicsWeekShowsSevenDailyBarsOnUsageAndShipped() throws {
        let aggregate = try aggregate(epicSlice)
        let usage = Usage(aggregate: aggregate, slice: epicSlice, snapshot: try snapshot(), today: today)
        XCTAssertEqual(usage.chart.bars.map(\.label), ["Nov 6", "Nov 7", "Nov 8", "Nov 9", "Nov 10", "Nov 11", "Nov 12"])
        XCTAssertEqual(usage.chart.title, "Tokens per day")
        XCTAssertEqual(usage.chart.total, 18_300_000)
        let shipped = Shipped(aggregate: aggregate, slice: epicSlice, details: nil, today: today)
        XCTAssertEqual(shipped.chart.bars.map(\.id), usage.chart.bars.map(\.id))
        XCTAssertTrue(shipped.groups.flatMap(\.rows).allSatisfy { $0.identifier.hasPrefix("TP-") })
    }

    func testTheUnitSetsTheChartsGranularity() throws {
        let daily = Usage(aggregate: try aggregate(), slice: InsightsSlice(), snapshot: nil, today: today)
        let sixHours = InsightsSlice(unit: .sixHours)
        let fine = Usage(aggregate: try aggregate(sixHours), slice: sixHours, snapshot: nil, today: today)
        XCTAssertEqual(daily.chart.bars.count, 7)
        XCTAssertEqual(fine.chart.bars.count, 28)
        XCTAssertEqual(fine.chart.title, "Tokens per 6 h")
        XCTAssertEqual(fine.chart.bars[1].label, "Nov 6 06:00")
        // The axis labels every fourth 6 h bar, each a day's start, by its short day; a bar inside a day reads its time.
        XCTAssertEqual(fine.chart.labelled.map(fine.chart.axisLabel), ["Nov 6", "Nov 7", "Nov 8", "Nov 9", "Nov 10", "Nov 11", "Nov 12"])
        XCTAssertEqual(fine.chart.axisLabel(fine.chart.bars[1].id), "06:00")
        XCTAssertEqual(fine.chart.axisLabel("nope"), "nope")
        XCTAssertEqual(daily.chart.axisLabel(daily.chart.bars[2].id), "Nov 8")
        XCTAssertEqual(fine.chart.total, daily.chart.total)
        XCTAssertEqual(Insights.bucketLabel(fine.chart.bars[0].start, unit: .week), "Nov 6")
        XCTAssertEqual(InsightsUnit.allCases.map(\.per), ["per 30 min", "per hour", "per 6 h", "per day", "per week"])
        XCTAssertEqual(InsightsUnit.allCases.map(\.phrase), ["by 30 min", "by hour", "by 6 h", "by day", "by week"])
    }

    func testAChartStacksItsKeysWithTheValueOnTheLastBar() throws {
        let usage = Usage(aggregate: try aggregate(), slice: InsightsSlice(), snapshot: try snapshot(), today: today)
        let chart = usage.chart
        XCTAssertEqual(chart.keys.map(\.name), ["Claude", "Codex"])
        XCTAssertEqual(chart.keys.map(\.tint), [.series(.series1), .series(.series2)])
        XCTAssertEqual(chart.reference, InsightsChart.Reference(title: "Daily budget", value: 5_000_000))
        XCTAssertEqual(chart.lastValue?.text, "3.1M")
        XCTAssertEqual(chart.hoverLine(chart.bars[0].id), "Nov 6: Claude 3.1M, Codex 900K; 4M in all")
        XCTAssertEqual(chart.hoverLine(chart.bars[3].id), "Nov 9: Claude 3.9M")
        XCTAssertEqual(chart.hoverLine("nope"), "")
        XCTAssertEqual(chart.dataTable.first, ["Period", "Claude", "Codex", "Total"])
        XCTAssertEqual(chart.dataTable[1], ["Nov 6", "3100000", "900000", "4000000"])
        XCTAssertEqual(chart.segments.filter(\.isTop).count, 7)
        XCTAssertEqual(chart.labelled.count, 7)
        XCTAssertEqual(chart.label(chart.bars[2].id), "Nov 8")
        XCTAssertEqual(chart.label("nope"), "nope")
        XCTAssertTrue(chart.summary.hasPrefix("Tokens per day for Claude and Codex over 7 bars, 31.1M in all. The most was 6.5M on Nov 10."))
        XCTAssertTrue(chart.summary.hasSuffix("The daily budget is 5M."))

        // By 6 h the daily budget draws no line.
        let fine = Usage(aggregate: try aggregate(InsightsSlice(unit: .sixHours)), slice: InsightsSlice(unit: .sixHours), snapshot: try snapshot(), today: today)
        XCTAssertNil(fine.chart.reference)
    }

    func testABucketWithoutKeysStacksUnderItsFallback() {
        let series = AggregatePayload.Series(total: 3, buckets: [
            .init(start: Date(timeIntervalSince1970: 0), value: 3), .init(start: Date(timeIntervalSince1970: 86_400), value: 0),
        ])
        let chart = InsightsChart.build(series, unit: .day, title: "Runs per day", measure: "Runs", format: .count, fallback: "other") {
            InsightsChart.Key(key: $0, name: $0.capitalized, tint: .status(.idle))
        }
        XCTAssertEqual(chart.bars.map(\.values), [["other": 3], [:]])
        XCTAssertNil(InsightsChart(title: "t", measure: "m", keys: [], bars: [chart.bars[1]], format: .count).lastValue)
        XCTAssertEqual(chart.hoverLine(chart.bars[1].id), "Jan 2: none")
        XCTAssertEqual(chart.value(1_500_000), "1500000")
        let empty = InsightsChart(title: "Runs per day", measure: "Runs", keys: [], bars: [chart.bars[1]], format: .count)
        XCTAssertEqual(empty.summary, "Runs per day: none over 1 bars.")
    }

    // MARK: - The read

    func testTheAggregateDecodesWithItsKeysAsServed() throws {
        let aggregate = try aggregate(epicSlice)
        XCTAssertEqual(aggregate.unit, .day)
        XCTAssertEqual(aggregate.verdicts.by["code_review:request_changes"], 1)
        XCTAssertEqual(aggregate.shipped.buckets.last?.tickets, ["TP-1462"])
        XCTAssertEqual(aggregate.tokens.tickets["TP-1459"], 4_100_000)
        XCTAssertNil(AggregatePayload.decode(Data("nope".utf8)))
        XCTAssertNil(AggregatePayload.decode(Data(#"{"error":{"code":"invalid_query"}}"#.utf8)))
        let sparse = try XCTUnwrap(AggregatePayload.decode(Data(#"{"unit":"1h","series":{"runs":{"buckets":[{"start":"bad"},{"start":"2026-11-12T01:00:00Z"}]}}}"#.utf8)))
        XCTAssertEqual(sparse.unit, .hour)
        XCTAssertEqual(sparse.runs.buckets.count, 1)
        XCTAssertEqual(sparse.runs.total, 0)
        XCTAssertEqual(sparse.tokens, AggregatePayload.Series())
    }

    // MARK: - An empty slice

    func testAnEmptySliceSaysSoWithOneWayOutThatWidensThePeriod() throws {
        let nothing = AggregatePayload(series: ["tokens": .init(buckets: [.init(start: Date(timeIntervalSince1970: 0), value: 0)])])
        let week = InsightsSlice()
        let usage = Usage(aggregate: nothing, slice: week, snapshot: nil, today: today)
        XCTAssertEqual(usage.empty, InsightsEmpty(title: "No tokens used in the last 7 days.", widen: .preset(.month)))
        XCTAssertEqual(usage.empty?.actionTitle, "Show Last 30 Days")
        let shipped = Shipped(aggregate: nothing, slice: InsightsSlice(period: .preset(.today)), details: nil, today: today)
        XCTAssertEqual(shipped.empty, InsightsEmpty(title: "Nothing shipped today.", widen: .preset(.week)))
        let quality = Quality(aggregate: nothing, slice: InsightsSlice(period: .range(from: "2026-11-01", to: "2026-11-30")), review: .reading, today: today)
        XCTAssertEqual(quality.empty?.title, "No runs or verdicts from Nov 1 to Nov 30.")
        XCTAssertEqual(quality.empty?.widen, .preset(.quarter))
        let year = Usage(aggregate: nothing, slice: InsightsSlice(period: .preset(.year)), snapshot: nil, today: today)
        XCTAssertNil(year.empty?.widen)
        XCTAssertNil(year.empty?.actionTitle)
        XCTAssertNil(Usage(aggregate: try aggregate(), slice: week, snapshot: nil, today: today).empty)
    }

    func testTheDetailReadsCoverTheSlicesDays() {
        XCTAssertEqual(InsightsSlice().daysBack(today: today), 8)
        XCTAssertEqual(InsightsSlice(period: .preset(.year)).daysBack(today: today), 90)
        XCTAssertEqual(InsightsSlice(period: .range(from: "2026-11-01", to: "2026-11-03")).daysBack(today: today), 13)
        XCTAssertEqual(Insights.today(ISO8601DateFormatter().date(from: "2026-11-12T23:59:00Z")!), "2026-11-12")
    }

    private static func value(_ name: String, _ slice: InsightsSlice, scope: OverviewScope = .all) -> String? {
        slice.parameters(today: "2026-11-12", scope: scope).first { $0.name == name }?.value
    }

    /// A failed read shows its failure, not the spinner, and waits the read interval before it is sent again; Try Again
    /// (`expire`) and another slice read at once, and an answer replaces the failure.
    func testAFailedReadShowsItsFailureAndWaitsTheIntervalBeforeReadingAgain() throws {
        let path = InsightsSlice().path(today: today)
        let other = epicSlice.path(today: today)
        let now = Date(timeIntervalSince1970: 1_794_470_000)
        var read = AggregateRead()
        XCTAssertTrue(read.isDue(path, now: now, interval: 60))
        XCTAssertEqual(read.shown(path), .reading)

        read.record(path, .failed("Symphony answered with HTTP 400"), now: now)
        XCTAssertEqual(read.shown(path), .failed("Symphony answered with HTTP 400"))
        XCTAssertEqual(read.shown(other), .reading)
        XCTAssertFalse(read.isDue(path, now: now.addingTimeInterval(2), interval: 60), "a failing read waits, not every poll")
        XCTAssertTrue(read.isDue(path, now: now.addingTimeInterval(60), interval: 60))
        XCTAssertTrue(read.isDue(other, now: now.addingTimeInterval(2), interval: 60))

        read.expire()
        XCTAssertTrue(read.isDue(path, now: now.addingTimeInterval(2), interval: 60), "Try Again reads at once")

        read.record(path, .loaded(Data("not json".utf8)), now: now)
        XCTAssertEqual(read.shown(path), .failed(AggregateRead.undecodable))
        read.record(path, .unsupported, now: now)
        XCTAssertEqual(read.shown(path), .unsupported)

        let answer = try data("aggregate")
        read.record(path, .loaded(answer), now: now)
        XCTAssertEqual(read.shown(path), .loaded(try XCTUnwrap(AggregatePayload.decode(answer))))
        XCTAssertNil(read.failure)

        // A later failed refresh keeps the slice's answer on screen.
        read.record(path, .failed("Symphony isn't answering"), now: now.addingTimeInterval(60))
        XCTAssertEqual(read.shown(path), .loaded(try XCTUnwrap(AggregatePayload.decode(answer))))
    }
}
