import SymphonyBarCore
import XCTest

final class ShippedTests: XCTestCase {
    // MARK: - Shipped (D9)

    func testTheWeekSaysWhatShippedPerDayAndByDay() throws {
        let shipped = Shipped(payload: try payload(), period: .week, scope: .all)

        XCTAssertEqual(shipped.sentence, "14 tickets shipped in the last 7 days.")
        XCTAssertEqual(shipped.context, "3 today. Half took less than 14 h 30 min from Todo to Done.")
        XCTAssertEqual(shipped.total, 14)
        XCTAssertNil(shipped.empty)
        XCTAssertEqual(shipped.bars.map { Usage.dayLabel($0.date) }, ["Oct 1", "Oct 2", "Oct 3", "Oct 4", "Oct 5", "Oct 6", "Oct 7"])
        XCTAssertEqual(shipped.bars.map(\.shipped), [2, 2, 1, 3, 1, 2, 3])
        XCTAssertEqual(shipped.groups.map(\.title), ["Today · 3", "Yesterday · 2", "Oct 5 · 1", "Oct 4 · 3", "Oct 3 · 1", "Oct 2 · 2", "Oct 1 · 2"])

        let today = try XCTUnwrap(shipped.groups.first)
        XCTAssertEqual(today.rows.map(\.identifier), ["SHOP-288", "API-125", "SHOP-287"])
        let first = today.rows[0]
        XCTAssertEqual(first.title, "Gift card balance on the cart")
        XCTAssertEqual(first.detail, "web-shop · Gift cards · PR #912")
        XCTAssertEqual(first.prTitle, "PR #912")
        XCTAssertEqual(first.prURL, URL(string: "https://github.com/acme/web-shop/pull/912"))
        XCTAssertEqual(first.leadTime, "4 h 20 min")
        XCTAssertEqual(
            first.accessibilityLabel,
            "SHOP-288, Gift card balance on the cart, web-shop, initiative Gift cards, PR #912, 4 hours 20 minutes from Todo to Done"
        )
        XCTAssertEqual(today.rows[1].detail, "api · PR #341")
        XCTAssertEqual(today.rows[1].leadTime, "1 day 4 h")
    }

    func testTheChartHasHoverValuesShowDataAndASummary() throws {
        let shipped = Shipped(payload: try payload(), period: .week, scope: .all)
        let lastDay = try XCTUnwrap(shipped.bars.last?.date)

        XCTAssertEqual(Shipped.chartTitle, "Shipped per day")
        XCTAssertEqual(shipped.hoverLine(on: lastDay), "Oct 7: 3 tickets")
        XCTAssertEqual(shipped.hoverLine(on: Date(timeIntervalSince1970: 0)), "Jan 1: 0 tickets")
        XCTAssertEqual(shipped.dataTable.first, ["Day", "Shipped"])
        XCTAssertEqual(shipped.dataTable.count, 8)
        XCTAssertEqual(shipped.dataTable[1], ["Oct 1", "2"])
        XCTAssertEqual(shipped.chartSummary, "14 tickets shipped over 7 days. The most was 3 on Oct 4.")
    }

    func testThePeriodAndTheScopeChooseTheTickets() throws {
        let month = Shipped(payload: try payload(), period: .month, scope: .all)
        XCTAssertEqual(month.sentence, "22 tickets shipped in the last 30 days.")
        XCTAssertEqual(month.bars.count, 30)
        XCTAssertEqual(month.bars.map(\.shipped).reduce(0, +), 22)
        XCTAssertEqual(month.groups.count, 14)

        let api = Shipped(payload: try payload(), period: .week, scope: .repo("api"))
        XCTAssertEqual(api.sentence, "6 tickets shipped in the last 7 days.")
        XCTAssertEqual(api.groups.flatMap(\.rows).map(\.identifier), ["API-125", "API-124", "API-123", "API-122", "API-121", "API-119"])
        XCTAssertEqual(api.groups.first?.rows.first?.leadTime, "1 day 4 h")
    }

    func testNothingShippedSaysSoWithAWayOut() {
        let empty = ShippedPayload(days: 7, to: "2026-10-07")

        let week = Shipped(payload: empty, period: .week, scope: .all)
        XCTAssertEqual(week.empty, Shipped.Empty(title: "Nothing shipped in the last 7 days.", action: .widen(.month)))
        XCTAssertEqual(week.empty?.action?.title, "Show Last 30 Days")
        XCTAssertEqual(week.sentence, "0 tickets shipped in the last 7 days.")
        XCTAssertEqual(week.context, "")
        XCTAssertEqual(week.chartSummary, "Nothing shipped in the last 7 days.")
        XCTAssertTrue(week.groups.isEmpty)

        let quarter = Shipped(payload: empty, period: .quarter, scope: .repo("api"))
        XCTAssertEqual(quarter.empty, Shipped.Empty(title: "Nothing shipped in the last 90 days.", action: .showAllRepos))
        XCTAssertEqual(quarter.empty?.action?.title, "Show All Repos")
        XCTAssertNil(Shipped(payload: empty, period: .quarter, scope: .all).empty?.action)
    }

    func testATicketWithoutAStartOrAPRSaysOnlyWhatIsKnown() {
        let payload = ShippedPayload(
            days: 7, to: "2026-10-07",
            tickets: [
                ShippedPayload.Ticket(issueID: "i-1", identifier: "APP-1", date: "2026-10-07"),
                ShippedPayload.Ticket(issueID: "i-2", identifier: "APP-2", title: "Two", initiative: "APP-100", prURL: URL(string: "https://example.com/x"), date: "2026-10-06", todoToDoneSeconds: 600),
            ]
        )
        let shipped = Shipped(payload: payload, period: .week, scope: .all)
        let rows = shipped.groups.flatMap(\.rows)

        XCTAssertEqual(shipped.context, "1 today. Half took less than 10 min from Todo to Done.")
        XCTAssertEqual(rows[0].title, "APP-1")
        XCTAssertEqual(rows[0].detail, "")
        XCTAssertNil(rows[0].leadTime)
        XCTAssertNil(rows[0].prTitle)
        XCTAssertEqual(rows[0].accessibilityLabel, "APP-1")
        XCTAssertEqual(rows[1].detail, "APP-100 · PR")
        XCTAssertFalse(Shipped(payload: payload, period: .week, scope: .repo("web")).groups.contains { !$0.rows.isEmpty })
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

    private func learningsPayload() throws -> LearningsPayload {
        try XCTUnwrap(LearningsPayload.decode(fixture("learnings.json")))
    }
}
