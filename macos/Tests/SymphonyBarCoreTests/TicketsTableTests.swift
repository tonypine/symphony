import Foundation
import XCTest
@testable import SymphonyBarCore

/// Work › Tickets as the table with filters (TP-1456): each chip's query parameter, the columns and the sort sent to
/// `GET /api/v1/tickets`, and its answer read into rows.
final class TicketsTableTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-07T14:20:00Z")!

    // MARK: - Each chip maps to its query parameter

    func testEachChipMapsToItsQueryParameter() {
        let chips: [(TicketFilterChip, String, String)] = [
            (TicketFilterChip(filter: .epic, values: ["TP-1400"]), "epic", "TP-1400"),
            (TicketFilterChip(filter: .repo, values: ["api", "web-shop"]), "repo", "api,web-shop"),
            (TicketFilterChip(filter: .phase, values: ["Code Review"]), "phase", "Code Review"),
            (TicketFilterChip(filter: .situation, values: ["waiting_for_ci", "waiting_for_build"]), "situation", "waiting_for_ci,waiting_for_build"),
            (TicketFilterChip(filter: .label, values: ["agent"]), "label", "agent"),
            (TicketFilterChip(filter: .priority, values: ["1", "2"]), "priority", "1,2"),
            (TicketFilterChip(filter: .since, values: ["day"]), "since", "2026-10-06T14:20:00Z"),
        ]
        for (chip, name, value) in chips {
            XCTAssertEqual(chip.parameter(now: now), URLQueryItem(name: name, value: value), chip.text)
        }
        XCTAssertEqual(Set(chips.map(\.0.filter)), Set(TicketFilter.allCases), "every filter of the catalog has a chip")
    }

    func testEveryTimeWindowStartsItsSinceThatLongBeforeNow() {
        let formatter = ISO8601DateFormatter()
        for window in TicketTimeWindow.allCases {
            let value = TicketFilterChip(filter: .since, values: [window.rawValue]).parameter(now: now).value
            XCTAssertEqual(value, formatter.string(from: now.addingTimeInterval(-window.seconds)))
        }
        // A window the app doesn't know reads as the last day.
        XCTAssertEqual(TicketFilterChip(filter: .since, values: []).parameter(now: now).value, "2026-10-06T14:20:00Z")
    }

    func testTheChipReadsItsValue() {
        XCTAssertEqual(TicketFilterChip(filter: .epic, values: ["TP-1400"]).text, "Epic is TP-1400")
        XCTAssertEqual(TicketFilterChip(filter: .situation, values: ["waiting_for_ci"]).text, "Situation is Waiting for CI")
        XCTAssertEqual(TicketFilterChip(filter: .priority, values: ["1", "2"]).text, "Priority is Urgent or High")
        XCTAssertEqual(TicketFilterChip(filter: .label, values: ["a", "b", "c"]).text, "Label is a, b or c")
        XCTAssertEqual(TicketFilterChip(filter: .since, values: ["week"]).text, "Updated in the last 7 days")
        XCTAssertEqual(TicketFilterChip(filter: .epic, values: []).text, "Epic is ")
        XCTAssertEqual(TicketFilterChip(filter: .epic, values: ["TP-1400"]).removeLabel, "Remove filter Epic is TP-1400")
        XCTAssertEqual(TicketFilter.situation.word("unknown_kind"), "unknown_kind")
        XCTAssertEqual(TicketFilter.priority.word("high"), "high")
        XCTAssertEqual(TicketFilter.since.word("year"), "year")
        XCTAssertEqual(TicketFilter.allCases.map(\.title), ["Epic", "Repo", "Phase", "Situation", "Label", "Priority", "Updated"])
        XCTAssertEqual(TicketFilter.allCases.map(\.column), ["epic", "repo", "phase", "situation", "labels", "priority", "updated_at"])
        XCTAssertEqual(TicketFilter.label.id, "label")
    }

    // MARK: - The query

    /// Walkthrough step 1: epic TP-1400 and waiting for CI, the Repo column hidden.
    func testTheWalkthroughsFiltersAndColumnsGoToTheServer() {
        var query = TicketsQuery()
        query.toggle(.epic, "TP-1400")
        query.toggle(.situation, "waiting_for_ci")
        query.setColumn("repo", shown: false)

        XCTAssertEqual(query.chips.map(\.text), ["Epic is TP-1400", "Situation is Waiting for CI"])
        XCTAssertEqual(
            query.path(scope: .all, now: now),
            "api/v1/tickets?epic=TP-1400&situation=waiting_for_ci&columns=identifier,title,repo,epic,phase,situation,labels,priority,created_at"
                + "&sort=identifier&direction=asc"
        )
        XCTAssertEqual(query.shownColumns(catalog: TicketColumn.catalog, scope: .all).map(\.title),
                       ["Ticket", "Title", "Epic", "Situation", "Labels", "Priority", "Age"])
    }

    /// Walkthrough step 2: Age sorts youngest first, then oldest first.
    func testSortingByAgeSendsTheSortAndReversesTheDirection() {
        var query = TicketsQuery()
        query.sort = TicketSort(column: "created_at", ascending: true)
        XCTAssertTrue(query.path(scope: .all, now: now).hasSuffix("&sort=created_at&direction=desc"))
        query.sort = TicketSort(column: "created_at", ascending: false)
        XCTAssertTrue(query.path(scope: .all, now: now).hasSuffix("&sort=created_at&direction=asc"))
        query.sort = TicketSort(column: "priority", ascending: false)
        XCTAssertTrue(query.path(scope: .all, now: now).hasSuffix("&sort=priority&direction=desc"))
        // A column the catalog doesn't have sorts by the identifier.
        query.sort = TicketSort(column: "colour")
        XCTAssertTrue(query.path(scope: .all, now: now).hasSuffix("&sort=identifier&direction=asc"))
    }

    func testAChipTakesValuesAndGoesWithItsLast() {
        var query = TicketsQuery()
        query.toggle(.priority, "1")
        query.toggle(.priority, "2")
        XCTAssertTrue(query.holds(.priority, "2"))
        XCTAssertEqual(query.chip(.priority)?.values, ["1", "2"])
        query.toggle(.priority, "1")
        query.toggle(.priority, "2")
        XCTAssertNil(query.chip(.priority))
        XCTAssertFalse(query.holds(.priority, "2"))

        query.toggle(.since, "day")
        query.toggle(.since, "week")
        XCTAssertEqual(query.chip(.since)?.values, ["week"], "the time window holds one value")
        query.toggle(.label, "agent")
        query.remove(.since)
        XCTAssertEqual(query.chips.map(\.filter), [.label])
    }

    func testTheColumnsKeepTheCatalogsOrderAndTheIdentifier() {
        var query = TicketsQuery(columns: ["title"])
        query.setColumn("created_at", shown: true)
        query.setColumn("identifier", shown: false)
        query.setColumn("identifier", shown: true)
        XCTAssertEqual(query.columns, ["title", "created_at"])
        query.setColumn("identifier", shown: false)
        XCTAssertEqual(query.columns, ["title", "created_at"], "the identifier can't be hidden")
        query = TicketsQuery(columns: ["identifier"])
        for column in TicketColumn.catalog { query.setColumn(column.name, shown: true) }
        XCTAssertEqual(query.columns, TicketColumn.catalog.map(\.name))
        XCTAssertEqual(query.shownColumns(catalog: TicketColumn.catalog, scope: .all).count, 14)
    }

    func testTheRepoColumnHidesWhileOneRepoIsFiltered() {
        var query = TicketsQuery()
        XCTAssertNil(query.repo(scope: .all))
        XCTAssertEqual(query.repo(scope: .repo("api")), "api")
        XCTAssertFalse(query.shownColumns(catalog: TicketColumn.catalog, scope: .repo("api")).map(\.name).contains("repo"))
        // The window's repo scope is the query's repo while no Repo chip is set.
        XCTAssertTrue(query.path(scope: .repo("api"), now: now).hasPrefix("api/v1/tickets?repo=api&columns="))
        query.toggle(.repo, "web-shop")
        XCTAssertEqual(query.repo(scope: .repo("api")), "web-shop")
        XCTAssertTrue(query.path(scope: .repo("api"), now: now).hasPrefix("api/v1/tickets?repo=web-shop&columns="))
        query.toggle(.repo, "docs")
        XCTAssertNil(query.repo(scope: .all))
        XCTAssertTrue(query.shownColumns(catalog: TicketColumn.catalog, scope: .all).map(\.name).contains("repo"))
    }

    func testTheQueryEncodesItsValuesAndReadsTheColumnsItNeeds() {
        var query = TicketsQuery(columns: ["identifier"])
        query.toggle(.label, "needs review")
        XCTAssertEqual(query.path(scope: .all, now: now),
                       "api/v1/tickets?label=needs%20review&columns=identifier,title,repo,epic,phase,labels&sort=identifier&direction=asc")
        // A catalog that has none of the columns the read needs still asks for them.
        let other = [TicketColumn(name: "colour", type: "string")]
        XCTAssertEqual(query.queryItems(scope: .all, catalog: other, now: now).first { $0.name == "columns" }?.value,
                       TicketColumn.alwaysRead.joined(separator: ","))
    }

    // MARK: - The catalog

    func testTheColumnsHaveTheirHeaders() {
        XCTAssertEqual(TicketColumn.catalog.map(\.title), [
            "Ticket", "Title", "Repo", "Epic", "Phase", "Situation", "In situation", "Labels", "Priority", "Assignee", "Link", "Age",
            "In phase", "Updated",
        ])
        XCTAssertEqual(TicketColumn(name: "lead_time", type: "time").title, "Lead Time")
        XCTAssertTrue(TicketColumn(name: "lead_time", type: "time").isTime)
        XCTAssertEqual(TicketColumn.catalog[0].id, "identifier")
    }

    func testTheCatalogIsReadFromTheViewsRead() throws {
        let catalog = try XCTUnwrap(TicketColumn.catalog(fromViews: try fixture("views.json")))
        XCTAssertEqual(catalog, TicketColumn.catalog)
        XCTAssertNil(TicketColumn.catalog(fromViews: Data(#"{"error":{"code":"not_found"}}"#.utf8)))
        XCTAssertNil(TicketColumn.catalog(fromViews: Data(#"{"columns":[{"name":1}]}"#.utf8)))
        XCTAssertNil(TicketColumn.catalog(fromViews: Data("not json".utf8)))
    }

    // MARK: - The rows

    func testTheAnswerReadsIntoRowsInTheServersOrder() throws {
        let payload = try XCTUnwrap(TicketsPayload.decode(try fixture("tickets.json")))
        XCTAssertEqual(payload.count, 16)
        XCTAssertEqual(payload.columns, TicketColumn.catalog)
        XCTAssertNil(payload.error)
        let row = try XCTUnwrap(payload.rows.first { $0.identifier == "SHOP-301" })
        XCTAssertEqual(row.issueID, "issue-shop-301")
        XCTAssertEqual(row.title, "Saved carts")
        XCTAssertEqual(row.repoKey, "web-shop")
        XCTAssertEqual(row.epic, "SHOP-280")
        XCTAssertEqual(row.phase, "Code Review")
        XCTAssertEqual(row.labels, ["checkout", "agent"])
        XCTAssertEqual(row.number("priority"), 2)
        XCTAssertEqual(row.situationKind, .ci)
        XCTAssertEqual(row.url, URL(string: "https://linear.app/example/issue/SHOP-301"))
        XCTAssertEqual(row.time("created_at"), ISO8601DateFormatter().date(from: "2026-10-01T08:30:00Z"))

        let column = { (name: String) in try XCTUnwrap(TicketColumn.catalog.first { $0.name == name }) }
        XCTAssertEqual(row.cell(try column("situation"), reference: now), "Waiting for CI")
        XCTAssertEqual(row.cell(try column("priority"), reference: now), "High")
        XCTAssertEqual(row.cell(try column("labels"), reference: now), "checkout, agent")
        XCTAssertEqual(row.cell(try column("created_at"), reference: now), "6 days")
        XCTAssertEqual(row.cell(try column("title"), reference: now), "Saved carts")
        XCTAssertEqual(row.cell(TicketColumn(name: "missing", type: "string"), reference: now), "")
        XCTAssertNil(row.text("labels"))
        XCTAssertEqual(row.list("title"), [])
        XCTAssertNil(row.time("title"))
        XCTAssertNil(row.number("title"))
    }

    func testAValueTheTypeDoesntSayReadsAsItCame() {
        let data = Data(#"""
        {"count": 1, "error": "snapshot_timeout",
         "columns": [{"name": "identifier", "type": "identifier"}, {"name": "situation", "type": "situation"}],
         "tickets": [
           {"issue_id": "a", "identifier": "TP-1", "situation": "nobody_knows", "estimate": 3, "created_at": "2026-10-07T14:00:00.123456Z",
            "phase_at": "yesterday", "assignee": null},
           {"title": "No identifier"}
         ]}
        """#.utf8)
        guard let payload = TicketsPayload.decode(data) else { return XCTFail("the answer didn't read") }
        XCTAssertEqual(payload.error, "snapshot_timeout")
        XCTAssertEqual(payload.rows.map(\.identifier), ["TP-1"])
        let row = payload.rows[0]
        XCTAssertNil(row.situationKind)
        XCTAssertEqual(row.cell(TicketColumn(name: "situation", type: "situation"), reference: now), "nobody_knows")
        XCTAssertEqual(row.cell(TicketColumn(name: "estimate", type: "integer"), reference: now), "3")
        let created = try? XCTUnwrap(row.time("created_at"))
        XCTAssertEqual(created.map { Int($0.timeIntervalSince(now)) }, -1_199, "a time with fractional seconds reads")
        XCTAssertNil(row.values["phase_at"], "a time that doesn't read is left out")
        XCTAssertNil(row.values["assignee"])
        XCTAssertNil(TicketsPayload.decode(Data(#"{"error":{"code":"invalid_query"},"tickets":[]}"#.utf8)))
        XCTAssertNil(TicketsPayload.decode(Data("[]".utf8)))
    }

    func testThePriorityNames() {
        XCTAssertEqual((0...5).map(TicketsRow.priorityName), ["No priority", "Urgent", "High", "Medium", "Low", "No priority"])
    }

    func testTheSearchFindsTheIdentifierAndTheTitle() throws {
        let payload = try XCTUnwrap(TicketsPayload.decode(try fixture("tickets.json")))
        XCTAssertEqual(payload.rows(matching: "").count, 16)
        XCTAssertEqual(payload.rows(matching: " shop-30 ").map(\.identifier), ["SHOP-301", "SHOP-305"])
        XCTAssertEqual(payload.rows(matching: "webhook").map(\.identifier), ["API-119", "API-140"])
        XCTAssertEqual(payload.rows(matching: "web-shop"), [], "the repo isn't searched")
    }

    func testTheSituationIsTheStatesWhenItAgrees() {
        let since = now.addingTimeInterval(-600)
        let row = TicketsRow(identifier: "TP-1", values: ["situation": .text("waiting_for_ci"), "situation_since": .time(since)])
        let tracked = Situation(kind: .ci, cause: "Checks are running on PR #741.", since: since)
        XCTAssertEqual(row.situation(tracked: tracked), tracked)
        XCTAssertEqual(row.situation(tracked: nil), Situation(kind: .ci, cause: "", since: since))
        XCTAssertEqual(row.situation(tracked: Situation(kind: .working, cause: "")), Situation(kind: .ci, cause: "", since: since))
        let bare = TicketsRow(identifier: "TP-2", values: [:])
        XCTAssertNil(bare.situation(tracked: nil))
        XCTAssertEqual(bare.situation(tracked: tracked), tracked)
    }

    func testAnUntrackedTicketReadsAsAnInspectorRow() throws {
        let payload = try XCTUnwrap(TicketsPayload.decode(try fixture("tickets.json")))
        let source = try XCTUnwrap(payload.rows.first { $0.identifier == "API-140" })
        let row = TicketList.Row(source, columns: payload.columns, reference: now)
        XCTAssertEqual(row.identifier, "API-140")
        XCTAssertEqual(row.titleText, "Webhook delivery log")
        XCTAssertEqual(row.state, "Todo")
        XCTAssertEqual(row.repoKey, "api")
        XCTAssertEqual(row.kind, .paused)
        XCTAssertEqual(row.stage, .queued)
        XCTAssertFalse(row.forced)
        XCTAssertEqual(row.facts.first, TicketList.Fact(label: "Repo", value: "api"))
        XCTAssertFalse(row.facts.contains { $0.label == "Title" || $0.label == "Ticket" })
        XCTAssertEqual(
            [nil, .working, .ci, .build, .you, .done, .slot, .blocked, .paused, .retrying, .cancelled].map(TicketList.Stage.init(kind:)),
            [.queued, .working, .working, .working, .waitingOnYou, .shipped, .queued, .queued, .queued, .queued, .queued]
        )
    }

    // MARK: - The filters' values

    func testTheFiltersOfferWhatTheRowsRead() throws {
        let payload = try XCTUnwrap(TicketsPayload.decode(try fixture("tickets.json")))
        var values = TicketFilterValues()
        values.learn(payload.rows, repos: ["billing"])
        XCTAssertEqual(values.values(.repo), ["api", "billing", "docs", "web-shop"])
        XCTAssertEqual(values.values(.epic), ["API-100", "SHOP-280"])
        XCTAssertEqual(values.values(.phase), ["Code Review", "In Progress", "Merging", "QA", "Todo"])
        XCTAssertTrue(values.values(.label).contains("checkout"))
        XCTAssertEqual(values.values(.situation), DesignTokens.SituationKind.allCases.map(\.apiKind))
        XCTAssertEqual(values.values(.priority), ["1", "2", "3", "4", "0"])
        XCTAssertEqual(values.values(.since), ["hour", "day", "week", "month"])
        // A value the query holds is offered even before a row reads it.
        var query = TicketsQuery()
        query.toggle(.epic, "TP-1400")
        XCTAssertEqual(values.values(.epic, query: query), ["API-100", "SHOP-280", "TP-1400"])
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/tickets/api/v1/\(name)"))
    }
}
