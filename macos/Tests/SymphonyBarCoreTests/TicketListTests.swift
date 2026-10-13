import Foundation
import XCTest
@testable import SymphonyBarCore

final class TicketListTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    // MARK: - Rows

    func testListsEveryTrackedTicketWithItsStageAndWhatItWaitsOn() throws {
        let list = try tickets("tickets")
        let rows = Dictionary(uniqueKeysWithValues: list.rows.map { ($0.identifier, $0) })

        XCTAssertEqual(list.rows.count, 19)
        XCTAssertEqual(rows["SHOP-305"]?.stage, .working)
        XCTAssertEqual(rows["SHOP-305"]?.waitsOn, "the agent")
        XCTAssertEqual(rows["SHOP-305"]?.sinceText, "22 min")
        XCTAssertEqual(rows["SHOP-301"]?.stage, .review)
        XCTAssertEqual(rows["SHOP-301"]?.waitsOn, "a QA pass")
        XCTAssertEqual(rows["API-127"]?.waitsOn, "the reviewer")
        XCTAssertEqual(rows["DOCS-40"]?.stage, .waitingOnYou)
        XCTAssertEqual(rows["DOCS-40"]?.waitsOn, "you")
        XCTAssertEqual(rows["DOCS-40"]?.sinceText, "3 h 12 min")
        XCTAssertEqual(rows["API-119"]?.stage, .merging)
        XCTAssertEqual(rows["API-119"]?.waitsOn, "CI")
        XCTAssertEqual(rows["SHOP-298"]?.waitsOn, "landing")
        XCTAssertEqual(rows["SHOP-320"]?.stage, .queued)
        XCTAssertEqual(rows["SHOP-320"]?.waitsOn, "a slot")
        XCTAssertEqual(rows["API-134"]?.waitsOn, "retry at 14:35")
        XCTAssertEqual(rows["SHOP-322"]?.waitsOn, "BIL-206")
        XCTAssertEqual(rows["API-140"]?.stage, .queued)
        XCTAssertEqual(rows["API-140"]?.waitsOn, "priority medium is not in tickets.priorities (urgent, high)")
        XCTAssertEqual(rows["API-140"]?.sinceText, "7 min")
        XCTAssertEqual(rows["DOCS-41"]?.waitsOn, "one repo label")
        XCTAssertEqual(rows["SHOP-288"]?.stage, .shipped)
        // Stage by stage, oldest first.
        XCTAssertEqual(list.rows.first?.identifier, "SHOP-320")
        XCTAssertEqual(list.rows.last?.identifier, "SHOP-288")
    }

    func testForcedAndAttentionRowsCarryTheirFlagsAndFacts() throws {
        let list = try tickets("tickets")
        let forced = try XCTUnwrap(list.row("shop-325"))
        XCTAssertTrue(forced.forced)
        XCTAssertTrue(forced.facts.contains(TicketList.Fact(label: "Forced", value: "Yes")))
        XCTAssertTrue(forced.facts.contains(TicketList.Fact(label: "Forced status", value: "implementation · waiting for a forced slot")))
        XCTAssertEqual(forced.facts.first, TicketList.Fact(label: "Stage", value: "Queued"))
        XCTAssertTrue(forced.accessibilityLabel.hasPrefix("SHOP-325, Express checkout, Queued, forced, waits on a slot"))

        XCTAssertTrue(try XCTUnwrap(list.row("SHOP-311")).needsAttention, "3 failed attempts")
        XCTAssertFalse(try XCTUnwrap(list.row("API-134")).needsAttention)
        XCTAssertTrue(try XCTUnwrap(list.row("DOCS-41")).needsAttention, "routed to two repos")
        XCTAssertEqual(list.row("SHOP-311")?.facts.last, TicketList.Fact(label: "Last error", value: "mix test failed: 4 failures"))
    }

    func testAPassedOverTicketWaitsOnItsDispatchGate() throws {
        let state = try XCTUnwrap(OverviewState.decode(Data(contentsOf: fixture("tickets").appendingPathComponent("state.json"))))
        XCTAssertEqual(state.dispatchSkipped, [OverviewState.Waiting(
            issueID: "i-140", identifier: "API-140", title: "Webhook delivery log", repoKey: "api", state: "Todo",
            reason: "priority medium is not in tickets.priorities (urgent, high)",
            since: SymphonyState.parseDate("2026-10-07T14:13:00Z")
        )])

        // The inspector's facts: the reason it waits on and since when.
        let row = try XCTUnwrap(TicketList(state: state, now: Date(), timeZone: utc).row("API-140"))
        XCTAssertEqual(row.facts, [
            TicketList.Fact(label: "Stage", value: "Queued"),
            TicketList.Fact(label: "State", value: "Todo"),
            TicketList.Fact(label: "Repo", value: "api"),
            TicketList.Fact(label: "Waits on", value: "priority medium is not in tickets.priorities (urgent, high)"),
            TicketList.Fact(label: "Since", value: "7 min ago"),
            TicketList.Fact(label: "Forced", value: "No"),
        ])
    }

    func testTheScopeBarSearchAndRepoScopeFilter() throws {
        let list = try tickets("tickets")
        XCTAssertEqual(list.rows(filter: .working, search: "").map(\.identifier), ["SHOP-305", "API-131"])
        XCTAssertEqual(list.rows(filter: .review, search: "").count, 2)
        XCTAssertEqual(list.rows(filter: .waitingOnYou, search: "").map(\.identifier), ["DOCS-40", "SHOP-290"])
        XCTAssertEqual(list.rows(filter: .merging, search: "").count, 2)
        XCTAssertEqual(list.count(.queued), 8)
        XCTAssertEqual(list.rows(filter: .needsAttention, search: "").map(\.identifier), ["DOCS-41", "SHOP-311"])
        XCTAssertEqual(list.rows(filter: .forced, search: "").map(\.identifier), ["SHOP-325"])
        XCTAssertEqual(list.count(.shipped), 3)
        XCTAssertEqual(list.count(.all), 19)

        XCTAssertEqual(list.rows(filter: .all, search: "bil-206").map(\.identifier), ["SHOP-322"])
        XCTAssertEqual(list.rows(filter: .all, search: "  checkout  express ").map(\.identifier), ["SHOP-325"])
        XCTAssertEqual(list.rows(filter: .working, search: "api").map(\.identifier), ["API-131"])
        XCTAssertTrue(list.rows(filter: .forced, search: "nothing like this").isEmpty)

        let scoped = try tickets("tickets", scope: .repo("api"))
        XCTAssertEqual(Set(scoped.rows.compactMap(\.repoKey)), ["api"])
        XCTAssertEqual(scoped.rows(filter: .working, search: "").map(\.identifier), ["API-131"])
    }

    func testSortsOnEveryColumnBothWays() throws {
        let list = try tickets("tickets")
        let rows = list.rows(filter: .waitingOnYou, search: "") + list.rows(filter: .working, search: "")
        let ids: ([KeyPathComparator<TicketList.Row>]) -> [String] = { rows.sorted(using: $0).map(\.identifier) }
        XCTAssertEqual(ids([KeyPathComparator(\.identifier)]), ["API-131", "DOCS-40", "SHOP-290", "SHOP-305"])
        XCTAssertEqual(ids([KeyPathComparator(\.identifier, order: .reverse)]), ["SHOP-305", "SHOP-290", "DOCS-40", "API-131"])
        XCTAssertEqual(ids([KeyPathComparator(\.titleText)]).first, "SHOP-290")
        XCTAssertEqual(ids([KeyPathComparator(\.repoText)]).first, "API-131")
        XCTAssertEqual(ids([KeyPathComparator(\.waitsOn, order: .reverse)]).first, "DOCS-40")
        XCTAssertEqual(ids([KeyPathComparator(\.sinceSort)]).first, "DOCS-40")
        XCTAssertEqual(ids(TicketList.defaultSort), ["SHOP-305", "API-131", "DOCS-40", "SHOP-290"])
        XCTAssertEqual(list.rows.sorted(using: TicketList.defaultSort).map(\.stage), list.rows.map(\.stage))
    }

    func testTheScopeBarFoldsIntoMoreWhileTheInspectorIsOpen() {
        XCTAssertEqual(TicketList.Filter.bar(inspectorShown: false).map(\.title),
                       ["All", "Working", "Review", "Waiting on you", "Merging", "Queued", "Needs attention", "Forced"])
        XCTAssertEqual(TicketList.Filter.more(inspectorShown: false), [.shipped])
        XCTAssertEqual(TicketList.Filter.bar(inspectorShown: true), [.all, .working, .review, .waitingOnYou])
        XCTAssertEqual(TicketList.Filter.more(inspectorShown: true), [.merging, .queued, .needsAttention, .forced, .shipped])
    }

    func testEachFlowTileOpensItsStageAndWaitingOnYouOpensTheInbox() {
        XCTAssertEqual(TicketList.Filter(stage: .queued), .queued)
        XCTAssertEqual(TicketList.Filter(stage: .working), .working)
        XCTAssertEqual(TicketList.Filter(stage: .review), .review)
        XCTAssertNil(TicketList.Filter(stage: .waitingOnYou))
        XCTAssertEqual(TicketList.Filter(stage: .merging), .merging)
        XCTAssertEqual(TicketList.Filter(stage: .shippedToday), .shipped)
        XCTAssertEqual(TicketList.Stage.allCases.map(\.status), [.idle, .working, .working, .you, .working, .done])
        XCTAssertEqual(TicketList.Stage.allCases.map(\.title), ["Queued", "Working", "Review", "Waiting on you", "Merging", "Shipped"])
    }

    func testATicketOnlyForcedTakesItsTitleAndRepoFromTheForcedEntry() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let state = OverviewState(
            snapshot: StateSnapshot(forced: [
                .init(identifier: "TP-1", issueID: "issue-1", title: "Fix the release", repoKey: "web", summary: "implementation · waiting for a forced slot", state: "Todo"),
            ]),
            generatedAt: now
        )
        let list = TicketList(state: state, now: now, timeZone: utc)

        let forced = try XCTUnwrap(list.row("TP-1"))
        XCTAssertEqual(forced.issueID, "issue-1")
        XCTAssertEqual(forced.title, "Fix the release")
        XCTAssertEqual(forced.repoKey, "web")
        XCTAssertTrue(forced.facts.contains(TicketList.Fact(label: "Repo", value: "web")))
        XCTAssertEqual(list.rows(filter: .all, search: "release").map(\.identifier), ["TP-1"])
        XCTAssertEqual(TicketList(state: state, scope: .repo("web"), now: now, timeZone: utc).rows.map(\.identifier), ["TP-1"])
        XCTAssertEqual(ForceSheet.summary("TP-1", in: list), "Fix the release\nTodo · Queued · already forced")
    }

    func testRowsFromTheOtherListsAndTheirEdges() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let state = OverviewState(
            snapshot: StateSnapshot(forced: [
                .init(identifier: "TP-1", summary: "implementation · running", state: "In Progress", forcedForSeconds: 60, stale: true, part: "TP-2"),
                .init(identifier: "TP-3", summary: "waiting for a human"),
                .init(identifier: "TP-4"),
            ]),
            generatedAt: now,
            running: [.init(identifier: "TP-5", repoKey: "r", runKind: "plan_revision", turnCount: 2, lastMessage: "Hi", lastEventAt: now.addingTimeInterval(-Overview.stuckAfter), totalTokens: 1_200)],
            watching: [.init(identifier: "TP-6", state: "QA"), .init(identifier: "TP-5", title: "From watching", repoKey: "other", url: URL(string: "https://x.test/TP-5"))],
            retrying: [.init(identifier: "TP-7")],
            dispatchSkipped: [.init(identifier: "TP-12"), .init(identifier: "TP-9", reason: "blocked by TP-1", since: now)],
            blocked: [.init(identifier: "TP-8", reason: "waits for the app update"), .init(identifier: "TP-9")],
            autoMerge: [.init(identifier: "TP-10", state: "ci_failure", status: "auto-merge off"), .init(identifier: "TP-11")]
        )
        let list = TicketList(state: state, now: now, timeZone: utc)

        let forced = list.row("TP-1")
        XCTAssertEqual(forced?.stage, .working)
        XCTAssertEqual(forced?.waitsOn, "the agent")
        XCTAssertEqual(forced?.needsAttention, true)
        XCTAssertEqual(forced?.facts.last, TicketList.Fact(label: "Working through", value: "TP-2"))
        XCTAssertEqual(list.row("TP-3")?.waitsOn, "a human")
        XCTAssertEqual(list.row("TP-4")?.waitsOn, "a forced slot")

        let stuck = list.row("TP-5")
        XCTAssertEqual(stuck?.waitsOn, "a stuck run")
        XCTAssertEqual(stuck?.needsAttention, true)
        XCTAssertEqual(stuck?.title, "From watching", "a later list fills in what the first lacks")
        XCTAssertEqual(stuck?.repoKey, "r", "but never replaces it")
        XCTAssertEqual(stuck?.url, URL(string: "https://x.test/TP-5"))
        XCTAssertEqual(stuck?.facts.map(\.label), ["Stage", "Repo", "Waits on", "Forced", "Run", "Turn", "Last activity", "Tokens", "Last message"])
        XCTAssertEqual(stuck?.facts.first { $0.label == "Run" }?.value, "Plan revision")

        XCTAssertEqual(list.row("TP-6")?.waitsOn, "a QA pass")
        XCTAssertEqual(list.row("TP-7")?.waitsOn, "a retry")
        XCTAssertEqual(list.row("TP-8")?.waitsOn, "an app update")
        XCTAssertEqual(list.row("TP-9")?.waitsOn, "its blockers")
        XCTAssertEqual(list.row("TP-9")?.since, now, "a blocked ticket takes its since from dispatch_skipped")
        XCTAssertEqual(list.row("TP-12")?.waitsOn, "a dispatch gate")
        XCTAssertEqual(list.row("TP-10")?.waitsOn, "ci failure")
        XCTAssertEqual(list.row("TP-10")?.needsAttention, true)
        XCTAssertEqual(list.row("TP-11")?.waitsOn, "CI")
        XCTAssertNil(list.row("TP-404"))
        XCTAssertEqual(TicketList.forcedWaitsOn("plan · paused"), "paused")
    }

    func testDecodesBlockedAutoMergeAndShippedTimes() throws {
        let data = Data("""
        {"generated_at":"2026-10-07T14:20:00Z","counts":{"running":0},"running":[],"retrying":[],
         "blocked":[{"issue_id":"i-1","issue_identifier":"A-1","title":"T","state":"Todo","reason":null,"blocked_by":[{"issue_identifier":"B-2","state":"Todo"}]},{"title":"no id"}],
         "auto_merge":[{"issue_id":"i-3","issue_identifier":"A-3","state":"enabled","status":"on","updated_at":"2026-10-07T14:00:00Z"},{}],
         "shipped_today":[{"issue_identifier":"A-4","completed_at":"2026-10-07T13:00:00Z"}]}
        """.utf8)
        let state = try XCTUnwrap(OverviewState.decode(data))
        XCTAssertEqual(state.blocked, [.init(issueID: "i-1", identifier: "A-1", title: "T", state: "Todo", blockers: ["B-2"])])
        XCTAssertEqual(state.autoMerge.map(\.identifier), ["A-3"])
        XCTAssertEqual(state.autoMerge.first?.status, "on")
        XCTAssertNotNil(state.autoMerge.first?.updatedAt)
        XCTAssertNotNil(state.shippedToday.first?.completedAt)
    }

    // MARK: - Helpers

    private func tickets(_ name: String, scope: OverviewScope = .all) throws -> TicketList {
        let data = try Data(contentsOf: fixture(name).appendingPathComponent("state.json"))
        return TicketList(state: try XCTUnwrap(OverviewState.decode(data)), scope: scope, now: Date(), timeZone: utc)
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/\(name)/api/v1", isDirectory: true)
    }
}
