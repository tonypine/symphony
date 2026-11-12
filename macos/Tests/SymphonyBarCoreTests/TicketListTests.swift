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
        // Situation kind by kind, oldest first.
        XCTAssertEqual(list.rows.first?.identifier, "DOCS-40")
        XCTAssertEqual(list.rows.last?.identifier, "SHOP-288")
    }

    func testEachRowReadsTheSituationSymphonyServesForIt() throws {
        let list = try tickets("tickets")
        let ci = try XCTUnwrap(list.row("SHOP-301"))
        XCTAssertEqual(ci.situation?.kind, .ci)
        XCTAssertEqual(ci.kind, .ci)
        XCTAssertEqual(ci.line.cause, "Checks are running on PR #741.")
        XCTAssertEqual(SituationText(ci.line, reference: list.reference).sentence,
                       "Waiting for CI · Checks are running on PR #741. · QA starts when they pass. · for 6 min")
        XCTAssertEqual(list.row("SHOP-311")?.kind, .retrying)
        XCTAssertEqual(list.row("SHOP-322")?.line.word, "Blocked by BIL-206")
        XCTAssertEqual(list.row("API-140")?.kind, .paused)

        // A ticket the state holds no situation for reads the kind its stage is closest to, its wait as the cause.
        let conflict = try XCTUnwrap(list.row("DOCS-41"))
        XCTAssertNil(conflict.situation)
        XCTAssertEqual(conflict.line, Situation(kind: .slot, cause: "Waits on one repo label."))
        let shipped = try XCTUnwrap(list.row("SHOP-288"))
        XCTAssertEqual(shipped.kind, .done)
        XCTAssertEqual(shipped.line.cause, "")
        // Review, QA and landing have a reviewer, a QA pass or the landing at work: never Waiting for CI.
        XCTAssertEqual(TicketList.Stage.allCases.map(\.kind), [.slot, .working, .working, .you, .working, .done])
        var review = conflict
        review.stage = .review
        review.waitsOn = "the reviewer"
        XCTAssertEqual(review.line, Situation(kind: .working, cause: "Waits on the reviewer."))
        XCTAssertEqual(review.kind, .working)
    }

    func testForcedAndAttentionRowsCarryTheirFlagsAndFacts() throws {
        let list = try tickets("tickets")
        let forced = try XCTUnwrap(list.row("shop-325"))
        XCTAssertTrue(forced.forced)
        XCTAssertTrue(forced.facts.contains(TicketList.Fact(label: "Forced", value: "Yes")))
        XCTAssertTrue(forced.facts.contains(TicketList.Fact(label: "Forced status", value: "implementation · waiting for a forced slot")))
        XCTAssertFalse(forced.facts.contains { ["Stage", "State", "Waits on", "Failed attempts"].contains($0.label) })
        let label = forced.accessibilityLabel(reference: list.reference)
        XCTAssertTrue(label.hasPrefix("SHOP-325, Express checkout, Waiting for a slot, for 12 minutes"), label)
        XCTAssertTrue(label.hasSuffix("The forced slot is taken. Forced."), label)

        XCTAssertTrue(try XCTUnwrap(list.row("SHOP-311")).needsAttention, "3 failed attempts")
        XCTAssertFalse(try XCTUnwrap(list.row("API-134")).needsAttention)
        XCTAssertTrue(try XCTUnwrap(list.row("DOCS-41")).needsAttention, "routed to two repos")
        XCTAssertTrue(try XCTUnwrap(list.row("DOCS-41")).accessibilityLabel(reference: list.reference).contains("needs attention"))
        XCTAssertEqual(list.row("SHOP-311")?.facts.last, TicketList.Fact(label: "Last error", value: "mix test failed: 4 failures"))
        XCTAssertFalse(list.row("SHOP-311")?.facts.contains { $0.label == "Failed attempts" } ?? true)
    }

    func testAPassedOverTicketWaitsOnItsDispatchGate() throws {
        let state = try XCTUnwrap(OverviewState.decode(Data(contentsOf: fixture("tickets").appendingPathComponent("state.json"))))
        XCTAssertEqual(state.dispatchSkipped, [OverviewState.Waiting(
            issueID: "i-140", identifier: "API-140", title: "Webhook delivery log", repoKey: "api", state: "Todo",
            reason: "priority medium is not in tickets.priorities (urgent, high)",
            since: SymphonyState.parseDate("2026-10-07T14:13:00Z")
        )])

        // The inspector's facts beside its situation line, which says the gate and since when.
        let row = try XCTUnwrap(TicketList(state: state, now: Date(), timeZone: utc).row("API-140"))
        XCTAssertEqual(row.facts, [
            TicketList.Fact(label: "Repo", value: "api"),
            TicketList.Fact(label: "Forced", value: "No"),
        ])
        XCTAssertEqual(row.line.word, "Paused")
    }

    func testTheRepoScopeFiltersTheRowsAndTheDefaultOrderIsByKindThenOldest() throws {
        let list = try tickets("tickets")
        XCTAssertEqual(list.rows.count, 19)
        let order = list.rows.map { ($0.kindSort, $0.sinceSort) }
        XCTAssertEqual(order.map(\.0), order.map(\.0).sorted())
        XCTAssertEqual(list.rows.prefix(2).map(\.identifier), ["DOCS-40", "SHOP-290"])

        let scoped = try tickets("tickets", scope: .repo("api"))
        XCTAssertEqual(Set(scoped.rows.compactMap(\.repoKey)), ["api"])
    }

    func testEachStageHasItsStatusAndTitle() {
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
        XCTAssertEqual(list.rows.map(\.identifier), ["TP-1"])
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
        XCTAssertEqual(stuck?.facts.map(\.label), ["Repo", "Forced", "Run", "Turn", "Last activity", "Tokens", "Last message"])
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
