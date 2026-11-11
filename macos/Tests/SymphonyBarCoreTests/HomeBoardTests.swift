import Foundation
import XCTest
@testable import SymphonyBarCore

/// Home's board (TP-1453): every open ticket Symphony works, from the dispatch order, grouped by situation in the
/// precedence, each group in dispatch order with why a candidate is or is not next.
final class HomeBoardTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// Never used while a fixture has `generated_at`: ages count from Symphony's clock.
    private let wallClock = Date(timeIntervalSince1970: 0)

    // MARK: - The board from the dispatch order

    /// Walkthrough step 1: three tickets running and five waiting, each once under its situation with its line and
    /// age, the waiting ones in the order Symphony starts them, with why.
    func testEveryOpenTicketShowsOnceUnderItsSituationInDispatchOrder() throws {
        let board = try board("home")

        XCTAssertTrue(board.hasOrder)
        XCTAssertEqual(board.groups.map(\.kind), [.you, .retrying, .blocked, .paused, .ci, .build, .slot, .working])
        XCTAssertEqual(board.groups.map(\.title), [
            "Waiting on you", "Retrying", "Blocked by a ticket", "Paused by a rule", "Waiting for CI", "Waiting for a build",
            "Waiting for a slot", "Working",
        ])
        XCTAssertEqual(board.rowIDs.count, Set(board.rowIDs).count, "each ticket once")
        XCTAssertEqual(board.count, 16)

        let slot = try XCTUnwrap(board.groups.first { $0.kind == .slot })
        XCTAssertEqual(slot.rows.map(\.identifier), ["SHOP-325", "SHOP-320", "API-133"])
        XCTAssertEqual(slot.rows.map(\.reason), ["Next: the forced slot is taken", "2nd: behind SHOP-325", "3rd: behind SHOP-320"])
        XCTAssertEqual(slot.rows.map(\.forced), [true, false, false])
        XCTAssertEqual(slot.hint, "oldest 30 min")

        let first = slot.rows[1]
        XCTAssertEqual(first.title, "Order history filters")
        XCTAssertEqual(first.repoKey, "web-shop")
        XCTAssertEqual(SituationText(first.situation, reference: board.reference).age, "30 min")
        XCTAssertEqual(
            first.accessibilityLabel(reference: board.reference),
            "SHOP-320, Order history filters, web-shop, Waiting for a slot, for 30 minutes: Both work slots are taken., 2nd: behind SHOP-325"
        )

        let working = try XCTUnwrap(board.groups.first { $0.kind == .working })
        XCTAssertEqual(working.rows.map(\.identifier), ["SHOP-305", "API-131", "SHOP-298", "API-127"])
        XCTAssertTrue(working.rows.allSatisfy { $0.reason == nil }, "a running ticket says nothing of the queue")
        XCTAssertEqual(working.hint, "longest 22 min")

        // A gate's reason that only repeats the line's cause is left out; another one says why it is not next.
        let blocked = try XCTUnwrap(board.groups.first { $0.kind == .blocked }?.rows.first)
        XCTAssertEqual(blocked.reason, "Not next: Waiting for BIL-206 to finish")
        XCTAssertNil(board.groups.first { $0.kind == .paused }?.rows.first?.reason)
        // Not a candidate: no reason line.
        XCTAssertNil(board.groups.first { $0.kind == .you }?.rows.first?.reason)
        XCTAssertNil(board.pauseSentence)
        XCTAssertFalse(board.showsResume)
    }

    /// Every group's heading count is the number of rows it shows, under every scope.
    func testEachGroupsCountIsItsRowCount() throws {
        for name in ["home", "home-quiet", "tickets"] {
            for scope in [OverviewScope.all, .repo("web-shop"), .repo("api"), .repo("mobile")] {
                let board = try board(name, scope: scope)
                for group in board.groups {
                    XCTAssertEqual(group.count, group.rows.count, "\(name) \(group.kind)")
                    XCTAssertEqual(group.isEmpty, group.rows.isEmpty)
                }
                XCTAssertEqual(board.count, board.rowIDs.count, name)
            }
        }
    }

    func testAnEmptyGroupIsOneQuietHeading() throws {
        let board = try board("home-quiet")
        XCTAssertEqual(board.groups.map(\.kind), HomeBoard.kinds)
        XCTAssertEqual(board.groups.filter { !$0.isEmpty }.map(\.kind), [.working])
        let you = board.groups[0]
        XCTAssertNil(you.hint)
        XCTAssertEqual(you.accessibilityLabel, "Waiting on you, none right now")
        XCTAssertEqual(board.groups.last?.accessibilityLabel, "Working, 1")
        XCTAssertEqual(HomeBoard.emptyHint, "None right now")
    }

    func testTheScopeKeepsOnlyItsReposRows() throws {
        let board = try board("home", scope: .repo("api"))
        XCTAssertEqual(board.groups.first { $0.kind == .slot }?.rows.map(\.identifier), ["API-133"])
        XCTAssertTrue(board.groups.flatMap(\.rows).allSatisfy { $0.repoKey == "api" })
        XCTAssertEqual(board.groups.map(\.kind), HomeBoard.kinds, "every kind keeps its heading")
    }

    /// Walkthrough step 2: when a run ends, its ticket moves to its new group on the next state; nothing leaves the
    /// board.
    func testATicketWhoseRunEndedMovesToItsNewGroup() throws {
        let data = try Data(contentsOf: fixture("home").appendingPathComponent("state.json"))
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var order = try XCTUnwrap(object["order"] as? [String: Any])
        var groups = try XCTUnwrap(order["groups"] as? [[String: Any]])
        let workingIndex = try XCTUnwrap(groups.firstIndex { $0["kind"] as? String == "working" })
        let ciIndex = try XCTUnwrap(groups.firstIndex { $0["kind"] as? String == "waiting_for_ci" })
        var working = try XCTUnwrap(groups[workingIndex]["tickets"] as? [[String: Any]])
        var ended = working.removeFirst()
        ended["outcome"] = "not_a_candidate"
        ended["situation"] = ["kind": "waiting_for_ci", "cause": "Checks are running on PR #745.", "since": "2026-10-07T14:19:00Z"]
        groups[workingIndex]["tickets"] = working
        groups[ciIndex]["tickets"] = [ended] + (groups[ciIndex]["tickets"] as? [[String: Any]] ?? [])
        order["groups"] = groups
        object["order"] = order
        let state = try XCTUnwrap(OverviewState.decode(JSONSerialization.data(withJSONObject: object)))

        let before = try board("home")
        let after = HomeBoard(state: state, now: wallClock, timeZone: utc)
        XCTAssertEqual(Set(after.rowIDs), Set(before.rowIDs), "nothing disappears")
        XCTAssertEqual(after.groups.first { $0.kind == .ci }?.rows.first?.identifier, "SHOP-305")
        XCTAssertFalse(after.groups.first { $0.kind == .working }?.rows.contains { $0.identifier == "SHOP-305" } ?? true)
    }

    // MARK: - The arrow keys

    func testTheArrowKeysWalkTheRowsAcrossGroups() throws {
        let board = try board("home")
        let ids = board.rowIDs
        XCTAssertEqual(board.row(from: nil, offset: 1), ids.first)
        XCTAssertEqual(board.row(from: nil, offset: -1), ids.last)
        XCTAssertEqual(board.row(from: "SHOP-290", offset: 1), "SHOP-311", "from the last of a group to the first of the next")
        XCTAssertEqual(board.row(from: "SHOP-311", offset: -1), "SHOP-290")
        XCTAssertEqual(board.row(from: ids.first, offset: -1), ids.first, "it stays at the top")
        XCTAssertEqual(board.row(from: ids.last, offset: 1), ids.last, "and at the bottom")
        XCTAssertEqual(board.row(from: "GONE-1", offset: 1), ids.first)
        XCTAssertNil(HomeBoard(state: OverviewState(), now: wallClock).row(from: nil, offset: 1))
    }

    // MARK: - Reasons

    func testWhyACandidateIsOrIsNotNext() {
        func reason(_ outcome: DispatchOrder.Outcome?, _ reason: String?, forced: Bool = false, cause: String = "") -> String? {
            HomeBoard.reasonLine(DispatchOrder.Ticket(identifier: "T-1", outcome: outcome, reason: reason, forced: forced), cause: cause)
        }
        XCTAssertEqual(reason(.starts, "next: a slot is free"), "Next: a slot is free")
        XCTAssertEqual(reason(.starts, "2nd: a slot is free"), "2nd: a slot is free")
        XCTAssertEqual(reason(.starts, "forced", forced: true), "Next: forced, it starts on its own allowance")
        XCTAssertEqual(reason(.waits, "next: work slots full"), "Next: work slots full")
        XCTAssertEqual(reason(.paused, "dispatch is paused: updating to v0.0.1.825"), "Not next: dispatch is paused: updating to v0.0.1.825")
        XCTAssertEqual(reason(.held, "Waiting for TP-1399 to finish", cause: "TP-1399 is in QA."), "Not next: Waiting for TP-1399 to finish")
        XCTAssertNil(reason(.held, "Waiting for TP-1399 to finish", cause: "waiting for TP-1399 to finish."))
        XCTAssertNil(reason(.running, "already running"))
        XCTAssertNil(reason(.notACandidate, "In Backlog."))
        XCTAssertNil(reason(nil, "next: a slot is free"))
        XCTAssertNil(reason(.waits, "  "))
        XCTAssertNil(reason(.waits, nil))
    }

    // MARK: - Reading the order

    func testTheOrderReadsFromStateAndFromItsOwnRead() throws {
        let data = try Data(contentsOf: fixture("home").appendingPathComponent("state.json"))
        let fromState = try XCTUnwrap(DispatchOrder.decode(data))
        XCTAssertEqual(fromState.next, "SHOP-325")
        XCTAssertEqual(fromState.computedAt, SymphonyState.parseDate("2026-10-07T14:19:58Z"))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let own = try JSONSerialization.data(withJSONObject: try XCTUnwrap(root["order"]))
        XCTAssertEqual(DispatchOrder.decode(own), fromState)
        XCTAssertEqual(try XCTUnwrap(OverviewState.decode(data)).order, fromState)

        let shp325 = try XCTUnwrap(fromState.groups.flatMap(\.tickets).first { $0.identifier == "SHOP-325" })
        XCTAssertEqual(shp325.outcome, .waits)
        XCTAssertEqual(shp325.position, 1)
        XCTAssertEqual(shp325.issueID, "i-325")
        XCTAssertEqual(shp325.state, "Todo")
        XCTAssertTrue(shp325.forced)
        XCTAssertNil(DispatchOrder.decode(Data("nope".utf8)))
        XCTAssertNil(DispatchOrder.decode(Data(#"{"generated_at":"2026-10-07T14:20:00Z"}"#.utf8)))
    }

    func testAnEntryWithoutAKnownKindOrSituationStillReads() throws {
        let json = #"""
        {"groups": [
          {"kind": "someday", "tickets": [{"identifier": "X-1"}]},
          {"kind": "waiting_for_slot", "tickets": [
            {"issue_identifier": "X-2", "outcome": "waits", "position": 1, "reason": "next: work slots full"},
            {"title": "no identifier"},
            {"identifier": "X-2", "outcome": "waits"}
          ]}
        ]}
        """#
        let order = try XCTUnwrap(DispatchOrder.decode(Data(json.utf8)))
        XCTAssertEqual(order.groups.map(\.kind), [.slot])
        let board = HomeBoard(state: OverviewState(order: order), now: wallClock)
        let slot = try XCTUnwrap(board.groups.first { $0.kind == .slot })
        XCTAssertEqual(slot.rows.map(\.identifier), ["X-2"], "each ticket once")
        XCTAssertEqual(slot.rows.first?.situation, Situation(kind: .slot, cause: "next: work slots full"))
        XCTAssertNil(slot.hint, "no row says since when")
    }

    func testShippedAndCancelledJoinOnlyWithRowsAndAnOlderSymphonyHasNoOrder() {
        let order = DispatchOrder(groups: [
            .init(kind: .done, tickets: [.init(identifier: "D-1", situation: Situation(kind: .done, cause: "Merged.", since: wallClock))]),
            .init(kind: .cancelled, tickets: []),
        ])
        let board = HomeBoard(state: OverviewState(order: order), now: wallClock)
        XCTAssertEqual(board.groups.map(\.kind), HomeBoard.kinds + [.done])
        XCTAssertNil(board.groups.last?.hint, "a shipped ticket has no age")

        let older = HomeBoard(state: OverviewState(), now: wallClock)
        XCTAssertFalse(older.hasOrder)
        XCTAssertTrue(older.groups.allSatisfy(\.isEmpty))
        XCTAssertEqual(older.count, 0)
    }

    // MARK: - The pause

    func testAPausedFactorySaysSoAndOffersResume() throws {
        let board = try board("home-quiet")
        XCTAssertEqual(board.pauseSentence, "Dispatch is paused since 13:40: Deploy freeze.")
        XCTAssertTrue(board.showsResume)
        XCTAssertFalse(try self.board("home-quiet", updating: true).showsResume, "Cancel Update resumes it")
    }

    func testAPauseWithoutAReasonOrTime() {
        var snapshot = StateSnapshot()
        snapshot.pause = StateSnapshot.Pause()
        XCTAssertEqual(HomeBoard(state: OverviewState(snapshot: snapshot), now: wallClock, timeZone: utc).pauseSentence, "Dispatch is paused.")
        snapshot.pause = StateSnapshot.Pause(reason: "Release.", since: Date(timeIntervalSince1970: 0))
        let other = HomeBoard(state: OverviewState(snapshot: snapshot, generatedAt: Date(timeIntervalSince1970: 90_000)), now: wallClock, timeZone: utc)
        XCTAssertEqual(other.pauseSentence, "Dispatch is paused since Jan 1, 00:00: Release.")
    }

    /// Each reason of Symphony's pause has its own line under the sentence (TP-1251).
    func testThePausesReasonsAreLinesUnderTheSentence() {
        let since = Date(timeIntervalSince1970: 1_000_000)
        var snapshot = StateSnapshot(pause: .init(reason: "Deploy freeze", since: since))
        snapshot.pauseReasons = [
            .init(kind: .person, text: "Deploy freeze", since: since),
            .init(kind: .build, text: "updating to v0.0.1.700", since: since, version: "0.0.1.700"),
            .init(kind: .other("environment"), text: "Claude's usage limit until 14:30", since: since),
        ]
        let board = HomeBoard(state: OverviewState(snapshot: snapshot, generatedAt: since), now: since, timeZone: utc)
        XCTAssertEqual(board.pauseSentence, "Dispatch is paused.")
        XCTAssertEqual(board.pauseLines, ["Paused by you since 13:46: Deploy freeze", "Updating to v0.0.1.700", "Claude's usage limit until 14:30"])
        XCTAssertTrue(board.showsResume, "no update is under way, so the pause it left behind can be resumed")
    }

    /// A usage limit alone holding runs shows the notice with Try Now and no Resume Dispatch, which would lift nothing
    /// (TP-1471).
    func testAUsageLimitAloneOffersTryNowNotResume() {
        let resumeAt = Date(timeIntervalSince1970: 1_000_000)
        let limit = StateSnapshot.UsageLimit(window: "five_hour", phase: .paused, resumeAt: resumeAt)
        let board = HomeBoard(state: OverviewState(snapshot: StateSnapshot(usageLimits: [limit]), generatedAt: resumeAt), now: resumeAt, timeZone: utc)
        XCTAssertEqual(board.pauseSentence, HomeBoard.heldSentence)
        XCTAssertEqual(board.pauseLines, ["Paused: Claude limit, resumes ~13:46"])
        XCTAssertTrue(board.showsTryNow)
        XCTAssertEqual(board.tryNow, limit)
        XCTAssertFalse(board.showsResume)

        // While the limit is checked, it is no longer offered, and nothing else holds runs.
        var canary = limit
        canary.phase = .canary
        let checking = HomeBoard(state: OverviewState(snapshot: StateSnapshot(usageLimits: [canary])), now: resumeAt, timeZone: utc)
        XCTAssertNil(checking.pauseSentence)
        XCTAssertFalse(checking.showsTryNow)

        // Beside the Director's pause, both are offered.
        let both = HomeBoard(state: OverviewState(snapshot: StateSnapshot(pause: .init(), usageLimits: [limit])), now: resumeAt, timeZone: utc)
        XCTAssertTrue(both.showsResume)
        XCTAssertTrue(both.showsTryNow)
    }

    /// Every repository paused adds its line, whether or not Symphony itself is.
    func testEveryRepositoryPausedAddsItsLine() {
        let repositoryPause = StateSnapshot.RepositoryPause(reasons: ["You paused this repository"])
        let repositories: [StateSnapshot.Repository] = [.init(key: "web-shop", pause: repositoryPause)]
        let board = HomeBoard(state: OverviewState(snapshot: StateSnapshot(repositories: repositories)), now: wallClock, timeZone: utc)
        XCTAssertNil(board.pauseSentence)
        XCTAssertEqual(board.pauseLines, ["All repositories paused"])
    }

    // MARK: - The sidebar

    func testTheSidebarCallsItHome() {
        XCTAssertEqual(SymphonyView.overview.title, "Home")
        XCTAssertEqual(SymphonyView.overview.symbol, "house")
        XCTAssertEqual(SymphonyView.overview.rawValue, "overview", "the view the window remembers still opens")
        XCTAssertEqual(InboxList.openOverviewTitle, "Open Home")
    }

    // MARK: - Helpers

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/\(name)/api/v1", isDirectory: true)
    }

    private func board(_ name: String, scope: OverviewScope = .all, updating: Bool = false) throws -> HomeBoard {
        let data = try Data(contentsOf: fixture(name).appendingPathComponent("state.json"))
        return HomeBoard(state: try XCTUnwrap(OverviewState.decode(data)), scope: scope, updating: updating, now: wallClock, timeZone: utc)
    }
}
