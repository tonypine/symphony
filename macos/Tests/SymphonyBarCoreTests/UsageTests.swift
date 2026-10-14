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

        let history = HistoryPayload(days: 1, tokensPerDay: [.init(date: "2026-10-07", totalTokens: 10, providers: ["openai": 10, "anthropic": 0])])
        let usage = Usage(history: history, snapshot: nil)
        XCTAssertEqual(usage.providers, [.openai])
        XCTAssertEqual(usage.providers.first?.series, .series2)
    }

    func testChartSeriesAreTheDesignsValidatedPairs() {
        XCTAssertEqual(DesignTokens.ChartSeries.allCases.map(\.hex.light), [0x007AFF, 0xE07800, 0xAF52DE, 0x1A9BB0])
        XCTAssertEqual(DesignTokens.ChartSeries.allCases.map(\.hex.dark), [0x3D86F5, 0xCC780A, 0xAE5ADF, 0x2A9FB4])
    }

    func testUsageFromTheShippedFixtures() throws {
        let usage = try self.usage()

        XCTAssertEqual(usage.dates.count, 14)
        XCTAssertEqual(usage.providers, [.anthropic, .openai])
        XCTAssertEqual(usage.dailyBudget, 5_000_000)
        let today = try XCTUnwrap(usage.dates.last)
        XCTAssertEqual(usage.total(on: today), 4_100_000)
        XCTAssertEqual(usage.hoverLine(on: today), "Oct 7: Claude 2.9M, Codex 1.2M; 4.1M in all")

        XCTAssertEqual(usage.today.map(\.id), ["tokens", "cap"])
        XCTAssertEqual(usage.today[0].value, "4.1M of 5M")
        XCTAssertEqual(usage.today[1].value, "2M tokens")
        XCTAssertEqual(usage.limits.count, 1)
        XCTAssertEqual(usage.limits[0].value, "100% used")
        XCTAssertEqual(usage.limits[0].note, "resets 15:40")

        XCTAssertEqual(usage.heaviest.count, Usage.heaviestLimit)
        let heaviest = usage.heaviest[0]
        XCTAssertEqual(heaviest.identifier, "SHOP-305")
        XCTAssertEqual(heaviest.value, "1.9M of 2M, 4 attempts")
        XCTAssertEqual(heaviest.level, .near)
        XCTAssertEqual(heaviest.fraction ?? 0, 0.925, accuracy: 0.0001)
        XCTAssertEqual(usage.heaviest.map(\.identifier), ["SHOP-305", "API-131", "DOCS-40", "SHOP-298", "WEB-88"])
        XCTAssertEqual(usage.heaviest[3].value, "610K of 2M, 1 attempt")
    }

    func testShowDataIsTheChartsSeriesAsATable() throws {
        let table = try usage().dataTable
        XCTAssertEqual(table.first, ["Day", "Claude", "Codex", "Total"])
        XCTAssertEqual(table.count, 15)
        XCTAssertEqual(table[2], ["Sep 25", "2600000", "0", "2600000"])
        XCTAssertEqual(table.last, ["Oct 7", "2900000", "1200000", "4100000"])
    }

    func testChartSummaryNamesTheSeriesThePeakAndTheBudget() throws {
        XCTAssertEqual(
            try usage().chartSummary,
            "Tokens per day for Claude and Codex over 14 days. The most was 4.2M on Oct 4. The daily budget is 5M tokens."
        )
        let empty = Usage(history: HistoryPayload(days: 1, tokensPerDay: [.init(date: "2026-10-07", totalTokens: 0, providers: [:])]), snapshot: nil)
        XCTAssertEqual(empty.chartSummary, "No tokens used in the last 1 days.")
        XCTAssertEqual(empty.hoverLine(on: empty.dates[0]), "Oct 7: no tokens")
        XCTAssertEqual(empty.today, [])
        XCTAssertEqual(empty.dataTable, [["Day", "Total"], ["Oct 7", "0"]])
    }

    func testATicketWithoutACapHasNoMeter() {
        let history = HistoryPayload(days: 1, tickets: [.init(issueID: "i", identifier: "A-1", totalTokens: 12_000, attempts: 2)])
        let row = Usage(history: history, snapshot: nil).heaviest[0]
        XCTAssertNil(row.fraction)
        XCTAssertEqual(row.value, "12K, 2 attempts")
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

    private func usage() throws -> Usage {
        let state = try XCTUnwrap(OverviewState.decode(fixture("state.json")))
        return Usage(history: try history(), snapshot: state.snapshot, now: wallClock, timeZone: utc)
    }
}
