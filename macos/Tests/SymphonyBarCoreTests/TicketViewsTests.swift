import Foundation
@testable import SymphonyBarCore
import XCTest

/// Saved views on Tickets (TP-1457): the views read, the body a save sends, the menu, and the round trip of save, pick,
/// update, rename and delete through the fixture server.
final class TicketViewsTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/director-app/ticket-views", isDirectory: true)

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent("api/v1/\(name)"))
    }

    private func json(_ text: String) -> Data { Data(text.utf8) }

    /// The bar of walkthrough step 1: epic TP-1400, waiting on you, the Repo and Labels columns hidden.
    private var epicSixQuery: TicketsQuery {
        var query = TicketsQuery()
        query.toggle(.epic, "TP-1400")
        query.toggle(.situation, "waiting_on_you")
        query.setColumn("repo", shown: false)
        query.setColumn("labels", shown: false)
        return query
    }

    // MARK: - The views read

    func testTheViewsReadListsEachViewWithItsChipsColumnsAndSort() throws {
        let views = try XCTUnwrap(TicketView.views(fromViews: fixture("views.json")))
        XCTAssertEqual(views.map(\.name), ["Recently updated", "Urgent first"])
        // A saved `since` reads back as the window it was saved with: an hour before the view was saved.
        let recent = views[0]
        XCTAssertEqual(recent.id, "view-7c2d")
        XCTAssertEqual(recent.query.chips, [TicketFilterChip(filter: .since, values: ["hour"])])
        XCTAssertEqual(recent.query.columns, ["identifier", "title", "phase", "situation", "updated_at"])
        // A time column's `desc` is its youngest first: ascending, as the header shows an age.
        XCTAssertEqual(recent.query.sort, TicketSort(column: "updated_at", ascending: true))
        XCTAssertEqual(recent.updatedAt, date("2026-11-11T10:00:00Z"))
        // A priority is an integer on the server and a chip's value here.
        let urgent = views[1]
        XCTAssertEqual(urgent.query.chips, [TicketFilterChip(filter: .priority, values: ["1", "2"])])
        XCTAssertEqual(urgent.query.sort, TicketSort(column: "priority", ascending: true))
        XCTAssertEqual(urgent.createdAt, date("2026-11-10T08:00:00Z"))
    }

    func testAViewTheAppCannotReadIsLeftOutAndAnErrorIsNoList() throws {
        XCTAssertNil(TicketView.views(fromViews: json(#"{"error": {"code": "unavailable"}}"#)))
        XCTAssertNil(TicketView.views(fromViews: json("[]")))
        XCTAssertNil(TicketView.views(fromViews: json(#"{"columns": []}"#)))
        let views = try XCTUnwrap(TicketView.views(fromViews: json("""
        {"views": [
          {"name": "No id"},
          {"id": "view-a", "name": "Odd", "columns": ["colour"], "sort": {"column": "title", "direction": "desc"},
           "filters": [
             {"column": "colour", "value": ["red"]}, {"column": "epic", "value": []}, {"column": "repo", "value": "web-shop"},
             {"column": "label", "value": [{"x": 1}, "agent"]}, {"column": "since", "value": "yesterday"}, {"column": "phase"},
             {"value": ["x"]}
           ]},
          {"id": "view-b", "name": "Bare"}
        ]}
        """)))
        XCTAssertEqual(views.map(\.id), ["view-a", "view-b"])
        // Unknown filters and columns go, a single value is a list of one, and no columns is the table's default.
        XCTAssertEqual(views[0].query.chips, [
            TicketFilterChip(filter: .repo, values: ["web-shop"]), TicketFilterChip(filter: .label, values: ["agent"]),
        ])
        XCTAssertEqual(views[0].query.columns, TicketColumn.defaultColumns)
        XCTAssertEqual(views[0].query.sort, TicketSort(column: "title", ascending: false))
        XCTAssertEqual(views[1].query, TicketsQuery())
        XCTAssertNil(views[1].createdAt)
    }

    func testTheNearestWindowAndTheNewestOfAName() {
        XCTAssertEqual(TicketTimeWindow.nearest(3_000), .hour)
        XCTAssertEqual(TicketTimeWindow.nearest(80_000), .day)
        XCTAssertEqual(TicketTimeWindow.nearest(6 * 86_400), .week)
        XCTAssertEqual(TicketTimeWindow.nearest(90 * 86_400), .month)
        let old = TicketView(id: "a", name: "Mine", query: TicketsQuery(), createdAt: date("2026-11-01T00:00:00Z"))
        let new = TicketView(id: "b", name: "Mine", query: TicketsQuery(), createdAt: date("2026-11-02T00:00:00Z"))
        let other = TicketView(id: "c", name: "Other", query: TicketsQuery())
        XCTAssertEqual(TicketView.newest(named: "Mine", in: [new, old, other])?.id, "b")
        XCTAssertEqual(TicketView.newest(named: "Mine", in: [old, new])?.id, "b")
        XCTAssertNil(TicketView.newest(named: "Gone", in: [old]))
        XCTAssertEqual(TicketView.inForce("a", in: [old, other]), "a")
        XCTAssertNil(TicketView.inForce("b", in: [old, other]))
        XCTAssertNil(TicketView.inForce(nil, in: [old]))
    }

    // MARK: - What a save sends

    func testASaveSendsTheChipsColumnsAndSortAsTheServerReadsThem() throws {
        var query = epicSixQuery
        query.toggle(.priority, "1")
        query.toggle(.since, "day")
        query.sort = TicketSort(column: "created_at")
        let draft = TicketViewDraft(name: "  Epic 6 needs me ", query: query, savedAt: date("2026-11-12T03:00:00Z"))
        XCTAssertEqual(draft.name, "Epic 6 needs me")
        let body = draft.body
        XCTAssertNil(body["id"])
        XCTAssertEqual(body["name"] as? String, "Epic 6 needs me")
        XCTAssertEqual(body["columns"] as? [String], ["identifier", "title", "epic", "situation", "priority", "created_at"])
        // An age's ascending is the server's `desc`.
        XCTAssertEqual(body["sort"] as? [String: String], ["column": "created_at", "direction": "desc"])
        let filters = try XCTUnwrap(body["filters"] as? [[String: Any]])
        XCTAssertEqual(filters.map { $0["column"] as? String }, ["epic", "situation", "priority", "since"])
        XCTAssertEqual(filters[0]["value"] as? [String], ["TP-1400"])
        XCTAssertEqual(filters[2]["value"] as? [Int], [1])
        XCTAssertEqual(filters[3]["value"] as? String, "2026-11-11T03:00:00Z")

        // What the server keeps reads back as the bar that saved it.
        var saved = body
        saved["id"] = "view-new"
        saved["updated_at"] = "2026-11-12T03:00:00Z"
        let view = try XCTUnwrap(TicketView.view(saved, catalog: TicketColumn.catalog))
        XCTAssertTrue(view.query.selectsSame(as: query))

        let update = TicketViewDraft(id: "view-new", name: "Mine", query: TicketsQuery(columns: []))
        XCTAssertEqual(update.body["id"] as? String, "view-new")
        XCTAssertEqual(update.body["columns"] as? [String], ["identifier"])
        XCTAssertEqual(update.body["sort"] as? [String: String], ["column": "identifier", "direction": "asc"])
    }

    func testANameIsNotBlankAndAtMostOneHundredTwentyBytes() {
        XCTAssertTrue(TicketViewDraft.canName("Epic 6 needs me"))
        XCTAssertTrue(TicketViewDraft.canName(String(repeating: "a", count: 120)))
        XCTAssertFalse(TicketViewDraft.canName(String(repeating: "a", count: 121)))
        XCTAssertFalse(TicketViewDraft.canName(String(repeating: "é", count: 61)))
        XCTAssertFalse(TicketViewDraft.canName(""))
        XCTAssertFalse(TicketViewDraft.canName("   \n"))
    }

    func testTheSameSelectionInAnyOrderAndTheViewsPath() throws {
        let view = try XCTUnwrap(TicketView.views(fromViews: fixture("views.after-view.1.json"))?.first)
        XCTAssertEqual(view.name, "Epic 6 needs me")
        XCTAssertTrue(view.query.selectsSame(as: epicSixQuery))
        var reordered = TicketsQuery(chips: epicSixQuery.chips.reversed(), columns: epicSixQuery.columns.reversed())
        XCTAssertTrue(reordered.selectsSame(as: view.query))
        reordered.sort = TicketSort(column: "identifier", ascending: false)
        XCTAssertFalse(reordered.selectsSame(as: view.query))

        let now = date("2026-11-12T03:00:00Z")
        // The view as saved, over every repo: by its id.
        XCTAssertEqual(epicSixQuery.path(view: view, scope: .all, now: now), "api/v1/tickets?view=view-e6a1")
        // Changed, under one repo's scope, or with a time window: the inline query.
        let inline = epicSixQuery.path(scope: .all, now: now)
        XCTAssertEqual(epicSixQuery.path(view: nil, scope: .all, now: now), inline)
        XCTAssertEqual(reordered.path(view: view, scope: .all, now: now), reordered.path(scope: .all, now: now))
        XCTAssertEqual(epicSixQuery.path(view: view, scope: .repo("symphony"), now: now), epicSixQuery.path(scope: .repo("symphony"), now: now))
        let recent = try XCTUnwrap(TicketView.views(fromViews: fixture("views.json"))?.first)
        XCTAssertTrue(recent.query.path(view: recent, scope: .all, now: now).contains("since="))
    }

    // MARK: - The menu

    func testTheMenuListsAllOpenThenTheViewsThenTheMoves() throws {
        let views = try XCTUnwrap(TicketView.views(fromViews: fixture("views.after-view.1.json")))
        let allOpen = TicketViewsMenu(views: views, currentID: nil, query: TicketsQuery())
        XCTAssertEqual(allOpen.title, "All open")
        XCTAssertFalse(allOpen.changed)
        XCTAssertEqual(allOpen.accessibilityLabel, "View: All open")
        XCTAssertEqual(allOpen.help, "Pick a view")
        XCTAssertEqual(allOpen.items, [
            .pick(nil, title: "All open", current: true),
            .pick(views[0], title: "Epic 6 needs me", current: false),
            .pick(views[1], title: "Recently updated", current: false),
            .pick(views[2], title: "Urgent first", current: false),
            .divider(0), .move(.save, enabled: true), .move(.update, enabled: false),
            .divider(1), .move(.rename, enabled: false), .move(.delete, enabled: false),
        ])
        XCTAssertEqual(allOpen.items.map(\.id), [
            "pick-all-open", "pick-view-e6a1", "pick-view-7c2d", "pick-view-1b9e", "divider-0", "move-save", "move-update",
            "divider-1", "move-rename", "move-delete",
        ])
        // "All open" can't be renamed, deleted or updated.
        XCTAssertFalse(allOpen.canEdit)
        XCTAssertEqual(allOpen.disabledReason(.rename), TicketViewsMenu.builtInReason)
        XCTAssertEqual(allOpen.disabledReason(.delete), TicketViewsMenu.builtInReason)
        XCTAssertEqual(allOpen.disabledReason(.update), TicketViewsMenu.builtInSaveReason)
        XCTAssertEqual(allOpen.disabledReason(.save), "")
        // The bar changed from "All open": a dot, and still no Update View.
        let filtered = TicketViewsMenu(views: views, currentID: nil, query: epicSixQuery)
        XCTAssertTrue(filtered.changed)
        XCTAssertFalse(filtered.canUpdate)

        // A saved view in force, as saved and then changed.
        let epicSix = TicketViewsMenu(views: views, currentID: "view-e6a1", query: epicSixQuery)
        XCTAssertEqual(epicSix.title, "Epic 6 needs me")
        XCTAssertFalse(epicSix.changed)
        XCTAssertFalse(epicSix.canUpdate)
        XCTAssertTrue(epicSix.canEdit)
        XCTAssertTrue(epicSix.isCurrent(views[0]))
        XCTAssertFalse(epicSix.isCurrent(nil))
        XCTAssertEqual(epicSix.disabledReason(.update), "The filters, columns and sort are the view's as saved")
        var changedQuery = epicSixQuery
        changedQuery.toggle(.priority, "1")
        let changed = TicketViewsMenu(views: views, currentID: "view-e6a1", query: changedQuery)
        XCTAssertTrue(changed.changed)
        XCTAssertTrue(changed.canUpdate)
        XCTAssertEqual(changed.accessibilityLabel, "View: Epic 6 needs me, changed")
        XCTAssertEqual(changed.help, "Pick a view. The filters, columns or sort differ from Epic 6 needs me.")
        XCTAssertEqual(changed.items[1], .pick(views[0], title: "Epic 6 needs me", current: true))

        // A view in force the server no longer lists: "All open".
        XCTAssertNil(TicketViewsMenu(views: [], currentID: "view-e6a1", query: TicketsQuery()).current)
        XCTAssertEqual(TicketViewsMenu.Move.allCases.map(\.title), ["Save View…", "Update View", "Rename…", "Delete…"])
        XCTAssertEqual(TicketViewsMenu.deleteQuestion("Mine"), "Delete the view “Mine”?")
    }

    // MARK: - The control calls

    func testSaveAndDeleteAreControlCalls() throws {
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:4000"))
        let draft = TicketViewDraft(name: "Mine", query: TicketsQuery())
        let save = ControlAPI.request(.saveView(draft), base: base, token: "secret")
        XCTAssertEqual(save.httpMethod, "POST")
        XCTAssertEqual(save.url?.path, "/api/v1/control/view")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(save.httpBody)) as? [String: Any])
        XCTAssertEqual(body["name"] as? String, "Mine")
        let delete = ControlAPI.request(.deleteView(id: "view-e6a1", name: "Mine"), base: base, token: "secret")
        XCTAssertEqual(delete.httpMethod, "DELETE")
        XCTAssertEqual(delete.url?.path, "/api/v1/control/view/view-e6a1")
        XCTAssertEqual(delete.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertNil(ControlAction.saveView(draft).moveIdentifier)
        XCTAssertNil(ControlAction.deleteView(id: "view-e6a1", name: "Mine").moveIdentifier)

        XCTAssertEqual(ControlAPI.result(.saveView(draft), statusCode: 200, data: json(#"{"view": {"id": "v"}}"#)), .done)
        XCTAssertEqual(
            ControlAPI.result(.saveView(draft), statusCode: 400,
                              data: json(#"{"error": {"code": "invalid_view", "message": "name is required"}}"#)),
            .failed("Couldn't save the view “Mine”: name is required (HTTP 400)")
        )
        XCTAssertEqual(
            ControlAPI.result(.saveView(TicketViewDraft(id: "v", name: "Mine", query: TicketsQuery())), statusCode: 404, data: Data()),
            .failed("Couldn't change the view “Mine”: HTTP 404")
        )
        XCTAssertEqual(
            ControlAPI.result(.deleteView(id: "v", name: "Mine"), statusCode: 404, data: Data()),
            .failed("Couldn't delete the view “Mine”: HTTP 404")
        )
    }

    // MARK: - The fixture server

    /// Walkthrough steps 1 and 2 against the fixture server: save the bar as "Epic 6 needs me" and find it in force,
    /// read its rows by its id, change a filter (the dot) and update it, rename it, delete it, and back to "All open".
    @MainActor
    func testWithTheFixtureServerSavePickUpdateRenameAndDeleteRoundTrip() async throws {
        let root = uniqueTemporaryDirectory("ticket-views")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = APIFixtures(directory: Self.fixtures, requestLog: root.appendingPathComponent("requests.jsonl"))
        let client = LiveAPIClient(fetch: LiveAPIClient.fetch(base: { APIFixtures.baseURL }, transport: fixtures.transport))
        func readViews() async throws -> [TicketView] {
            guard case let .loaded(data) = await client.get(TicketsPayload.viewsPath) else { throw URLError(.badServerResponse) }
            return try XCTUnwrap(TicketView.views(fromViews: data))
        }
        func send(_ action: ControlAction) async -> ControlResult {
            await ControlAPI.send(action, stateRoot: root, fallback: APIFixtures.baseURL, token: APIFixtures.token,
                                  transport: fixtures.transport)
        }
        func sent() -> [[String: Any]] {
            let text = (try? String(contentsOf: fixtures.requestLog, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }

        var views = try await readViews()
        XCTAssertEqual(views.map(\.name), ["Recently updated", "Urgent first"])
        var query = epicSixQuery
        XCTAssertTrue(TicketViewsMenu(views: views, currentID: nil, query: query).changed)

        // Step 1: Save View… as "Epic 6 needs me"; the menu lists it and it is in force.
        let draft = TicketViewDraft(name: "Epic 6 needs me", query: query)
        let result1 = await send(.saveView(draft))

        XCTAssertEqual(result1, .done)
        views = try await readViews()
        let saved = try XCTUnwrap(TicketView.newest(named: draft.name, in: views))
        XCTAssertEqual(saved.id, "view-e6a1")
        var menu = TicketViewsMenu(views: views, currentID: saved.id, query: query)
        XCTAssertEqual(menu.title, "Epic 6 needs me")
        XCTAssertFalse(menu.changed)
        XCTAssertEqual(menu.items.prefix(4).map(\.id), ["pick-all-open", "pick-view-e6a1", "pick-view-7c2d", "pick-view-1b9e"])
        let posted = try XCTUnwrap(sent().last)
        XCTAssertEqual(posted["method"] as? String, "POST")
        XCTAssertEqual(posted["path"] as? String, "/api/v1/control/view")
        let body = try XCTUnwrap(posted["body"] as? [String: Any])
        XCTAssertEqual(body["name"] as? String, "Epic 6 needs me")
        XCTAssertEqual(body["columns"] as? [String], ["identifier", "title", "epic", "situation", "priority", "created_at"])

        // Picking it reads its rows by its id.
        let path = query.path(view: menu.current, scope: .all, now: Date())
        XCTAssertEqual(path, "api/v1/tickets?view=view-e6a1")
        guard case let .loaded(rows) = await client.get(path) else { return XCTFail("No rows for the view") }
        XCTAssertEqual(TicketsPayload.decode(rows)?.rows.map(\.identifier), ["TP-1401", "TP-1405"])

        // Step 2: a filter changed marks the view; Update View saves it, and the mark goes.
        query.toggle(.priority, "1")
        menu = TicketViewsMenu(views: views, currentID: saved.id, query: query)
        XCTAssertTrue(menu.changed)
        XCTAssertTrue(menu.canUpdate)
        let result2 = await send(.saveView(TicketViewDraft(id: saved.id, name: saved.name, query: query)))

        XCTAssertEqual(result2, .done)
        XCTAssertEqual((sent().last?["body"] as? [String: Any])?["id"] as? String, "view-e6a1")
        views = try await readViews()
        menu = TicketViewsMenu(views: views, currentID: saved.id, query: query)
        XCTAssertFalse(menu.changed)

        // Rename… keeps what the view saved.
        let current = try XCTUnwrap(menu.current)
        let result3 = await send(.saveView(TicketViewDraft(id: current.id, name: "Epic 6, mine", query: current.query)))

        XCTAssertEqual(result3, .done)
        views = try await readViews()
        menu = TicketViewsMenu(views: views, currentID: saved.id, query: query)
        XCTAssertEqual(menu.title, "Epic 6, mine")
        XCTAssertFalse(menu.changed)

        // Delete…: the view goes from the list, and "All open" is in force with its bar.
        let result4 = await send(.deleteView(id: current.id, name: "Epic 6, mine"))

        XCTAssertEqual(result4, .done)
        let deleted = try XCTUnwrap(sent().last)
        XCTAssertEqual(deleted["method"] as? String, "DELETE")
        XCTAssertEqual(deleted["path"] as? String, "/api/v1/control/view/view-e6a1")
        views = try await readViews()
        XCTAssertEqual(views.map(\.id), ["view-7c2d", "view-1b9e"])
        XCTAssertNil(TicketView.inForce(saved.id, in: views))
        menu = TicketViewsMenu(views: views, currentID: TicketView.inForce(saved.id, in: views), query: TicketsQuery())
        XCTAssertEqual(menu.title, "All open")
        XCTAssertFalse(menu.changed)
        XCTAssertEqual(sent().count, 4)
    }
}
