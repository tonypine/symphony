import SymphonyBarCore
import XCTest

final class ShippedTests: XCTestCase {
    // MARK: - Shipped (D9)

    func testTheWeekSaysWhatShippedPerDayAndByDay() throws {
        let shipped = try insightsShipped()

        XCTAssertEqual(shipped.sentence, "14 tickets shipped in the last 7 days.")
        XCTAssertEqual(shipped.context, "Half took less than 8 h 15 min from Todo to Done.")
        XCTAssertEqual(shipped.total, 14)
        XCTAssertNil(shipped.empty)
        XCTAssertEqual(shipped.chart.bars.map(\.label), ["Nov 6", "Nov 7", "Nov 8", "Nov 9", "Nov 10", "Nov 11", "Nov 12"])
        XCTAssertEqual(shipped.chart.bars.map(\.total), [2, 2, 2, 1, 2, 3, 2])
        XCTAssertEqual(shipped.groups.map(\.title), ["Today · 2", "Yesterday · 3", "Nov 10 · 2", "Nov 9 · 1", "Nov 8 · 2", "Nov 7 · 2", "Nov 6 · 2"])

        let today = try XCTUnwrap(shipped.groups.first)
        XCTAssertEqual(today.rows.map(\.identifier), ["TP-1462", "SHOP-323"])
        let first = today.rows[0]
        XCTAssertEqual(first.title, "Reports in the Journal")
        XCTAssertEqual(first.detail, "symphony · Phase 3b · PR #892")
        XCTAssertEqual(first.prTitle, "PR #892")
        XCTAssertEqual(first.prURL, URL(string: "https://github.com/tonypine/symphony/pull/892"))
        XCTAssertEqual(first.leadTime, "9 h 10 min")
        XCTAssertEqual(
            first.accessibilityLabel,
            "TP-1462, Reports in the Journal, symphony, initiative Phase 3b, PR #892, 9 hours 10 minutes from Todo to Done"
        )
        XCTAssertEqual(today.rows[1].detail, "web-shop · PR #933")
    }

    func testTheChartHasHoverValuesShowDataAndTheCountOnTheLastBar() throws {
        let chart = try insightsShipped().chart
        let last = try XCTUnwrap(chart.bars.last)

        XCTAssertEqual(chart.title, "Shipped per day")
        XCTAssertEqual(try insightsShipped().caption, "Tickets merged per day")
        XCTAssertEqual(chart.keys.map(\.tint), [.series(.series1)])
        XCTAssertEqual(chart.hoverLine(last.id), "Nov 12: Shipped 2")
        XCTAssertEqual(chart.lastValue?.text, "2")
        XCTAssertEqual(chart.dataTable.first, ["Period", "Shipped", "Total"])
        XCTAssertEqual(chart.dataTable.count, 8)
        XCTAssertEqual(chart.dataTable[1], ["Nov 6", "2", "2"])
    }

    func testAShorterUnitGroupsTheTicketsByItsBuckets() throws {
        let slice = InsightsSlice(unit: .sixHours)
        let shipped = Shipped(aggregate: try aggregate("aggregate.from=2026-11-06&to=2026-11-12&unit=6h&series=tokens,runs,verdicts,shipped"),
                              slice: slice, details: try insightsDetails(), today: "2026-11-12")
        XCTAssertEqual(shipped.chart.bars.count, 28)
        XCTAssertEqual(shipped.chart.title, "Shipped per 6 h")
        XCTAssertEqual(shipped.groups.first?.title, "Nov 12 00:00 · 2")
        XCTAssertEqual(shipped.groups.map(\.rows.count).reduce(0, +), 14)
    }

    func testATicketWithoutDetailsSaysOnlyWhatIsKnown() {
        let start = ISO8601DateFormatter().date(from: "2026-11-12T00:00:00Z")!
        let aggregate = AggregatePayload(series: ["shipped": .init(total: 2, buckets: [.init(start: start, value: 2, tickets: ["APP-1", "APP-2"])])])
        let details = ShippedPayload(days: 7, to: "2026-11-12", tickets: [
            ShippedPayload.Ticket(issueID: "i-2", identifier: "APP-2", title: "Two", initiative: "APP-100", prURL: URL(string: "https://example.com/x"), date: "2026-11-12", todoToDoneSeconds: 600),
        ])
        let shipped = Shipped(aggregate: aggregate, slice: InsightsSlice(period: .preset(.today)), details: details, today: "2026-11-12")
        let rows = shipped.groups.flatMap(\.rows)

        XCTAssertEqual(shipped.sentence, "2 tickets shipped today.")
        XCTAssertEqual(shipped.context, "Half took less than 10 min from Todo to Done.")
        XCTAssertEqual(rows[0].title, "APP-1")
        XCTAssertEqual(rows[0].detail, "")
        XCTAssertNil(rows[0].leadTime)
        XCTAssertNil(rows[0].prTitle)
        XCTAssertEqual(rows[0].accessibilityLabel, "APP-1")
        XCTAssertEqual(rows[1].detail, "APP-100 · PR")

        let nothing = Shipped(aggregate: AggregatePayload(), slice: InsightsSlice(), details: nil, today: "2026-11-12")
        XCTAssertEqual(nothing.sentence, "0 tickets shipped in the last 7 days.")
        XCTAssertEqual(nothing.context, "")
        XCTAssertEqual(nothing.empty?.actionTitle, "Show Last 30 Days")
        XCTAssertTrue(nothing.groups.isEmpty)
    }

    func testTheShippedPayloadDecodes() throws {
        let payload = try payload()
        XCTAssertEqual(payload.days, 14)
        XCTAssertEqual(payload.to, "2026-10-07")
        XCTAssertEqual(payload.tickets.count, 22)
        let first = try XCTUnwrap(payload.tickets.first)
        XCTAssertEqual(first.initiative, "SHOP-300")
        XCTAssertEqual(first.initiativeTitle, "Gift cards")
        XCTAssertEqual(first.mergedAt, ISO8601DateFormatter().date(from: "2026-10-07T13:40:00Z"))
        XCTAssertEqual(ShippedPayload.path(days: 30), "api/v1/shipped?days=30")
        XCTAssertEqual(ShippedPayload.maxDays, 90)

        let odd = Data(
            """
            {"days": 7, "to": "2026-10-07", "tickets": [
              {"issue_id": "i-1", "date": "2026-10-07", "pr_url": "javascript:alert(1)", "merged_at": "2026-10-07T10:00:00.123456Z"},
              {"identifier": "APP-2"}
            ]}
            """.utf8
        )
        let decoded = try XCTUnwrap(ShippedPayload.decode(odd))
        XCTAssertEqual(decoded.tickets.map(\.identifier), ["i-1"])
        XCTAssertNil(decoded.tickets[0].prURL)
        XCTAssertNotNil(decoded.tickets[0].mergedAt)
        XCTAssertNil(ShippedPayload.decode(Data(#"{"error": {"code": "invalid_days"}}"#.utf8)))
        XCTAssertNil(ShippedPayload.decode(Data("not json".utf8)))
    }

    func testLeadTimesAndPRTitles() {
        XCTAssertEqual(Shipped.leadTime(-5), "0 s")
        XCTAssertEqual(Shipped.leadTime(5_400), "1 h 30 min")
        XCTAssertEqual(Shipped.leadTime(86_400), "1 day")
        XCTAssertEqual(Shipped.leadTime(2 * 86_400 + 5 * 3_600), "2 days 5 h")
        XCTAssertEqual(Shipped.spokenLeadTime(3 * 3_600), "3 hours")
        XCTAssertEqual(Shipped.spokenLeadTime(86_400 + 3_600), "1 day 1 hour")
        XCTAssertEqual(Shipped.spokenLeadTime(2 * 86_400), "2 days")
        XCTAssertEqual(Shipped.spokenLeadTime(-1), "0 seconds")
        XCTAssertEqual(Shipped.prTitle(URL(string: "https://github.com/a/b/pull/12")!), "PR #12")
        XCTAssertEqual(Shipped.prTitle(URL(string: "https://github.com/a/b/pull/abc")!), "PR")
        XCTAssertEqual(Shipped.prTitle(URL(string: "https://github.com/a/b/pull")!), "PR")
        XCTAssertEqual(Shipped.count(1), "1 ticket")
        XCTAssertEqual(Shipped.Tab.allCases.map(\.title), ["Shipped", "Learnings"])
    }

    // MARK: - Learnings (D9)

    func testLearningsComeNewestFirstGroupedByRepo() throws {
        let learnings = Learnings(payload: try learningsPayload(), filter: Learnings.Filter(), scope: .all, now: now, timeZone: utc)

        XCTAssertNil(learnings.empty)
        XCTAssertEqual(learnings.count, 6)
        XCTAssertEqual(learnings.repos, ["api", "web-shop"])
        XCTAssertEqual(learnings.tags, ["conventions", "docs", "domain", "gift-cards", "rate-limits", "testing", "time", "ui"])
        XCTAssertEqual(learnings.groups.map(\.repoKey), ["web-shop", "api"])
        XCTAssertEqual(learnings.groups[0].rows.map(\.id), ["l-1", "l-3", "l-5"])
        XCTAssertEqual(learnings.groups[0].rows.map(\.context), ["SHOP-288 · today", "SHOP-286 · yesterday", "SHOP-284 · Oct 4"])
        XCTAssertEqual(learnings.groups[1].rows.map(\.id), ["l-2", "l-4", "l-6"])

        let record = learnings.groups[0].rows[0].record
        XCTAssertEqual(record.issueURL, URL(string: "https://linear.app/acme/issue/SHOP-288"))
        XCTAssertEqual(record.prURL, URL(string: "https://github.com/acme/web-shop/pull/912"))
        XCTAssertEqual(record.prTitle, "PR #912")
        XCTAssertEqual(Learnings.searchPrompt, "Search learnings")
    }

    func testLearningsFilterByRepoTagAndSearch() throws {
        let payload = try learningsPayload()
        func ids(_ filter: Learnings.Filter, scope: OverviewScope = .all) -> [String] {
            Learnings(payload: payload, filter: filter, scope: scope, now: now, timeZone: utc).groups.flatMap(\.rows).map(\.id)
        }

        XCTAssertEqual(ids(Learnings.Filter(tag: "testing")), ["l-2", "l-4", "l-3"])
        XCTAssertEqual(ids(Learnings.Filter(tag: "testing", search: "  Redis ")), ["l-4"])
        XCTAssertEqual(ids(Learnings.Filter(search: "midnight")), ["l-2", "l-3"])
        XCTAssertEqual(ids(Learnings.Filter(search: "api-122")), ["l-6"])
        XCTAssertEqual(ids(Learnings.Filter(search: "gift-cards")), ["l-1"])
        XCTAssertEqual(ids(Learnings.Filter(repo: "api")), ["l-2", "l-4", "l-6"])
        XCTAssertEqual(ids(Learnings.Filter(), scope: .repo("web-shop")), ["l-1", "l-3", "l-5"])
        XCTAssertEqual(Learnings(payload: payload, filter: Learnings.Filter(), scope: .repo("api"), now: now, timeZone: utc).tags, ["docs", "conventions", "rate-limits", "testing", "time"].sorted())
        XCTAssertFalse(Learnings.Filter(search: "  ").isActive)
        XCTAssertTrue(Learnings.Filter(repo: "api").isActive)
    }

    func testNoLearningsSaysSoWithAWayOut() throws {
        let payload = try learningsPayload()

        let filtered = Learnings(payload: payload, filter: Learnings.Filter(tag: "ui"), scope: .repo("api"), now: now, timeZone: utc)
        XCTAssertEqual(filtered.empty, Learnings.Empty(title: "No learnings match these filters.", action: .clearFilters))
        XCTAssertEqual(filtered.empty?.action.title, "Clear Filters")

        let otherRepo = Learnings(payload: payload, filter: Learnings.Filter(), scope: .repo("docs"), now: now, timeZone: utc)
        XCTAssertEqual(otherRepo.empty, Learnings.Empty(title: "No learnings recorded in docs yet.", action: .showAllRepos))
        XCTAssertEqual(otherRepo.empty?.action.title, "Show All Repos")

        let none = Learnings(payload: LearningsPayload(), filter: Learnings.Filter(), scope: .all, now: now, timeZone: utc)
        XCTAssertEqual(none.empty, Learnings.Empty(title: "No learnings recorded yet.", action: .showShipped))
        XCTAssertEqual(none.empty?.action.title, "Show Shipped")
    }

    func testTheLearningsPayloadDecodes() throws {
        XCTAssertEqual(try learningsPayload().records.count, 6)
        XCTAssertEqual(LearningsPayload.path, "api/v1/learnings")

        let odd = Data(
            """
            {"records": [
              {"id": "a", "repo_key": "api", "rule": "Keep it.", "pr_url": "https://github.com/a/b/pull/3", "issue_url": "ftp://x"},
              {"id": "b", "repo_key": "api"}
            ]}
            """.utf8
        )
        let decoded = try XCTUnwrap(LearningsPayload.decode(odd))
        XCTAssertEqual(decoded.records.map(\.id), ["a"])
        XCTAssertEqual(decoded.records[0].tags, [])
        XCTAssertNil(decoded.records[0].issueURL)
        XCTAssertNil(decoded.records[0].createdAt)
        XCTAssertEqual(decoded.records[0].prTitle, "PR #3")
        XCTAssertNil(LearningRecord(id: "c", repoKey: "api", rule: "r").prTitle)
        XCTAssertNil(LearningsPayload.decode(Data(#"{"error": "down"}"#.utf8)))
    }

    // MARK: - Fixtures

    private let now = ISO8601DateFormatter().date(from: "2026-10-07T18:00:00Z")!
    private let utc = TimeZone(identifier: "UTC")!

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/shipped/api/v1/\(name)")
        return try Data(contentsOf: url)
    }

    private func payload() throws -> ShippedPayload {
        try XCTUnwrap(ShippedPayload.decode(fixture("shipped.json")))
    }

    private static let insights = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/director-app/insights/api/v1")

    private func aggregate(_ name: String = "aggregate") throws -> AggregatePayload {
        try XCTUnwrap(AggregatePayload.decode(Data(contentsOf: Self.insights.appendingPathComponent("\(name).json"))))
    }

    private func insightsDetails() throws -> ShippedPayload {
        try XCTUnwrap(ShippedPayload.decode(Data(contentsOf: Self.insights.appendingPathComponent("shipped.json"))))
    }

    /// The `insights` fixture's week by day: what the aggregation counts, with `/api/v1/shipped`'s details.
    private func insightsShipped() throws -> Shipped {
        Shipped(aggregate: try aggregate(), slice: InsightsSlice(), details: try insightsDetails(), today: "2026-11-12")
    }

    private func learningsPayload() throws -> LearningsPayload {
        try XCTUnwrap(LearningsPayload.decode(fixture("learnings.json")))
    }
}
