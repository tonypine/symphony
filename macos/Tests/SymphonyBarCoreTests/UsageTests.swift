import XCTest
@testable import SymphonyBarCore

final class UsageTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let wallClock = ISO8601DateFormatter().date(from: "2026-10-07T14:20:00Z")!

    func testDecodesTheShippedHistory() throws {
        let history = try self.history()
        XCTAssertEqual(history.days, 14)
        XCTAssertEqual(history.dailyBudget, 5_000_000)
        XCTAssertEqual(history.perTicketCap, 2_000_000)
        XCTAssertEqual(history.tokensPerDay.count, 14)
        XCTAssertEqual(history.tokensPerDay.last, HistoryPayload.Day(date: "2026-10-07", totalTokens: 4_100_000, providers: ["anthropic": 2_900_000, "openai": 1_200_000]))
        XCTAssertEqual(history.tickets.first?.identifier, "SHOP-305")
        XCTAssertEqual(history.mergedPerDay.count, 14)
        XCTAssertEqual(history.mergedPerDay.last?.merged, 2)
        XCTAssertEqual(HistoryPayload.path(days: 14), "api/v1/history?days=14")
    }

    func testRejectsAPayloadThatIsNotHistory() {
        XCTAssertNil(HistoryPayload.decode(Data(#"{"error":{"code":"invalid_days"}}"#.utf8)))
        XCTAssertNil(HistoryPayload.decode(Data("nope".utf8)))
    }

    func testDecodesMissingFieldsAsEmpty() throws {
        let payload = try XCTUnwrap(HistoryPayload.decode(Data(#"""
            {"days": 1, "tokens_per_day": [{"date": "2026-10-07"}], "tickets": [{"identifier": "A-1"}, {"title": "no id"}],
             "merged_per_day": [{"date": "2026-10-07"}]}
            """#.utf8)))
        XCTAssertEqual(payload.tokensPerDay, [HistoryPayload.Day(date: "2026-10-07", totalTokens: 0, providers: [:])])
        XCTAssertEqual(payload.tickets, [HistoryPayload.Ticket(issueID: "A-1", identifier: "A-1", totalTokens: 0, attempts: 0)])
        XCTAssertEqual(payload.mergedPerDay.map(\.merged), [0])
        XCTAssertNotEqual(payload, HistoryPayload(days: 1))
    }

    func testProvidersKeepTheirFixedSeriesWhateverThePeriodShows() {
        XCTAssertEqual(UsageProvider.allCases.map(\.series), [.series1, .series2, .series3, .series4])
        XCTAssertEqual(UsageProvider.allCases.map(\.name), ["Claude", "Codex", "OpenRouter", "Other"])
        XCTAssertEqual(UsageProvider("mystery"), .unknown)

        let aggregate = AggregatePayload(series: ["tokens": .init(total: 15, buckets: [
            .init(start: Date(timeIntervalSince1970: 0), value: 15, by: ["openai": 10, "anthropic": 0, "mystery": 3, "other": 2]),
        ])])
        let usage = Usage(aggregate: aggregate, slice: InsightsSlice(), snapshot: nil, today: "1970-01-01")
        XCTAssertEqual(usage.chart.keys.map(\.key), ["openai", "unknown"])
        XCTAssertEqual(usage.chart.keys.first?.tint, .series(.series2))
        XCTAssertEqual(usage.chart.bars[0].values, ["openai": 10, "unknown": 5])
        XCTAssertNil(usage.chart.reference, "no budget without a state")
        XCTAssertEqual(usage.today, [])
    }

    func testChartSeriesAreTheDesignsValidatedPairs() {
        XCTAssertEqual(DesignTokens.ChartSeries.allCases.map(\.hex.light), [0x007AFF, 0xE07800, 0xAF52DE, 0x1A9BB0])
        XCTAssertEqual(DesignTokens.ChartSeries.allCases.map(\.hex.dark), [0x3D86F5, 0xCC780A, 0xAE5ADF, 0x2A9FB4])
    }

    func testUsageOverTheInsightsSlice() throws {
        let usage = try insightsUsage()
        XCTAssertEqual(usage.chart.bars.count, 7)
        XCTAssertEqual(usage.chart.keys.map(\.key), ["anthropic", "openai"])
        XCTAssertEqual(usage.chart.reference?.value, 5_000_000)
        XCTAssertEqual(usage.today.last?.id, "cap")
        XCTAssertEqual(usage.today.last?.value, "2M tokens")

        XCTAssertEqual(usage.heaviest.map(\.identifier), ["TP-1459", "SHOP-322", "TP-1460", "TP-1458", "TP-1461"])
        let heaviest = usage.heaviest[0]
        XCTAssertEqual(heaviest.value, "4.1M of 2M")
        XCTAssertEqual(heaviest.fraction, 1)
        XCTAssertEqual(heaviest.level, .atLimit)
    }

    func testATicketWithoutACapHasNoMeter() {
        let aggregate = AggregatePayload(series: ["tokens": .init(total: 12_000, tickets: ["A-1": 12_000])])
        let row = Usage(aggregate: aggregate, slice: InsightsSlice(), snapshot: nil, today: "2026-11-12").heaviest[0]
        XCTAssertNil(row.fraction)
        XCTAssertEqual(row.value, "12K")
        XCTAssertEqual(row.level, .normal)
    }

    // MARK: - Helpers

    private func fixture(_ file: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/attention/api/v1/\(file)"))
    }

    private func history() throws -> HistoryPayload {
        try XCTUnwrap(HistoryPayload.decode(fixture("history.json")))
    }

    private func insightsUsage() throws -> Usage {
        let api = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/insights/api/v1")
        let state = try XCTUnwrap(OverviewState.decode(Data(contentsOf: api.appendingPathComponent("state.json"))))
        let aggregate = try XCTUnwrap(AggregatePayload.decode(Data(contentsOf: api.appendingPathComponent("aggregate.json"))))
        return Usage(aggregate: aggregate, slice: InsightsSlice(), snapshot: state.snapshot, today: "2026-11-12", now: wallClock, timeZone: utc)
    }
}
