import Foundation
@testable import SymphonyBarCore
import XCTest

/// The ticket read's `pull_request` and `connected` as the facts rail's Pull request and Connected panels say them,
/// from the fixtures in `Tests/Fixtures/facts-rail`: a green PR, a red PR with three workflows, and a ticket in a
/// chain with one blocker resolved yesterday and one still open, which is the only one the panel lists.
final class FactsRailTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/facts-rail")

    private let reference = ISO8601DateFormatter().date(from: "2026-11-10T15:00:00Z")!

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func read(_ name: String) throws -> TicketFactsRead {
        try XCTUnwrap(TicketFactsRead.decode(Data(contentsOf: Self.fixtures.appendingPathComponent("\(name).json"))))
    }

    private func panel(_ name: String) throws -> PullRequestPanelModel {
        try XCTUnwrap(PullRequestPanelModel.build(try read(name).pullRequest))
    }

    private func connected(_ name: String) throws -> ConnectedPanelModel {
        ConnectedPanelModel.build(try read(name).connected)
    }

    // MARK: - Decoding

    func testThePullRequestFixtureDecodesItsSizeAndEveryCheckByWorkflow() throws {
        let pr = try XCTUnwrap(try read("red-pr").pullRequest)
        XCTAssertEqual(pr.number, 741)
        XCTAssertEqual(pr.headShort, "8b03e51")
        XCTAssertEqual(pr.base, "main")
        XCTAssertEqual([pr.filesChanged, pr.additions, pr.deletions], [9, 486, 52])
        XCTAssertEqual(pr.checks.map(\.workflow), ["Mac app", "Elixir checks", "Docs"])
        XCTAssertEqual(pr.checks[1].checks[2], TicketPullRequest.Check(
            name: "Tests, part 1 of 4", state: .failed, startedAt: ISO8601DateFormatter().date(from: "2026-11-10T10:00:00Z"),
            durationMs: 372_000, url: URL(string: "https://github.com/acme/app/actions/runs/100/job/3"), required: true
        ))
        XCTAssertEqual(pr.readAt, ISO8601DateFormatter().date(from: "2026-11-10T10:06:30Z"))
    }

    func testTheConnectedFixtureDecodesTheEpicTheBlockersAndTheHeldTickets() throws {
        let connected = try XCTUnwrap(try read("blockers").connected)
        XCTAssertEqual(connected.epic?.identifier, "TP-1381")
        XCTAssertEqual(connected.epic?.tickets.count, 6)
        XCTAssertEqual(connected.epic?.tickets[3].situation, .ci)
        XCTAssertEqual(connected.epic?.tickets[4].current, true)
        XCTAssertEqual(connected.blockedBy, [
            TicketConnected.Blocker(
                identifier: "TP-1445", title: "The Lifecycle section and the Phase path", state: "Done", resolved: true,
                resolvedAt: ISO8601DateFormatter().date(from: "2026-11-09T22:37:00Z")
            ),
            TicketConnected.Blocker(identifier: "TP-1446", title: "The facts rail's Pull request and Connected panels", state: "Code Review"),
        ])
        XCTAssertEqual(connected.blocks, [
            TicketConnected.Ticket(identifier: "TP-1448", title: "The ticket page's layout on a laptop", state: "Todo", situation: .blocked),
        ])
    }

    func testAnOlderReadWithoutEitherFieldDecodesToNothingAndMissingValuesTakeTheirDefaults() throws {
        let older = try XCTUnwrap(TicketFactsRead.decode(Data(#"{"identifier": "TP-1"}"#.utf8)))
        XCTAssertEqual(older, TicketFactsRead(pullRequest: nil, connected: nil))
        XCTAssertNil(TicketFactsRead.decode(Data("[]".utf8)))

        let sparse = try XCTUnwrap(TicketFactsRead.decode(Data(#"""
        {"pull_request": {"number": 5, "head_sha": "0123456789abcdef", "checks": [{"workflow": null, "checks": [{"name": "ci/x", "state": "brand_new"}, {"name": "ci/y"}]}, {}]},
         "connected": {"epic": {"identifier": "TP-9"}, "blocked_by": [{"identifier": "TP-8"}], "blocks": [{"identifier": "TP-7", "situation": "nonsense"}]}}
        """#.utf8)))
        XCTAssertEqual(sparse.pullRequest, TicketPullRequest(
            number: 5, headShort: "0123456",
            checks: [
                TicketPullRequest.Workflow(workflow: nil, checks: [
                    TicketPullRequest.Check(name: "ci/x", state: .waiting), TicketPullRequest.Check(name: "ci/y", state: .waiting),
                ]),
                TicketPullRequest.Workflow(workflow: nil, checks: []),
            ]
        ))
        XCTAssertEqual(sparse.connected, TicketConnected(
            epic: TicketConnected.Epic(identifier: "TP-9"),
            blockedBy: [TicketConnected.Blocker(identifier: "TP-8")],
            blocks: [TicketConnected.Ticket(identifier: "TP-7")]
        ))
        let empty = try XCTUnwrap(TicketFactsRead.decode(Data(#"{"connected": {}}"#.utf8)))
        XCTAssertEqual(empty.connected, TicketConnected())
    }

    // MARK: - The Pull request panel

    func testAGreenPullRequestSaysItsNumberStateHeadSizeAndChecksPassing() throws {
        let model = try panel("green-pr")
        XCTAssertEqual(model.name, "PR #868")
        XCTAssertEqual(model.state, "Open")
        XCTAssertEqual(model.stateStatus, .working)
        XCTAssertEqual(model.head, "4c1d2e9 → main")
        XCTAssertEqual(model.size, "14 files · +412 −88")
        XCTAssertEqual(model.checksBadge, "Checks passing")
        XCTAssertEqual(model.checksStatus, .done)
        XCTAssertEqual(model.checksLine, "4 passed · 1 skipped")
        XCTAssertEqual(model.groups.map(\.name), ["Elixir checks", "Mac app"])
        XCTAssertEqual(model.groups[0].checks.map(\.duration), ["42 s", "1 min 4 s", "6 min 12 s"])
        XCTAssertEqual(model.groups[1].checks.map(\.word), ["Passed", "Skipped"])
        XCTAssertNil(model.groups[1].checks[1].duration)
        XCTAssertEqual(model.accessibilityLabel, "Pull request 868, open, 14 files, 412 lines added, 88 removed, checks passing")
    }

    func testARedPullRequestReadsItsFailedCheckFirstByItsWorkflowWithHowLongItRan() throws {
        let model = try panel("red-pr")
        XCTAssertEqual(model.checksBadge, "1 check failed")
        XCTAssertEqual(model.checksStatus, .problem)
        XCTAssertEqual(model.checksLine, "1 failed · 1 running · 3 passed · 1 waiting · 1 skipped")
        XCTAssertEqual(model.groups.map(\.name), ["Elixir checks", "Mac app", "Docs"])
        let failed = try XCTUnwrap(model.groups.first?.checks.first)
        XCTAssertEqual(failed.name, "Tests, part 1 of 4")
        XCTAssertEqual(failed.word, "Failed")
        XCTAssertEqual(failed.status, .problem)
        XCTAssertEqual(failed.duration, "6 min 12 s")
        XCTAssertEqual(failed.url, URL(string: "https://github.com/acme/app/actions/runs/100/job/3"))
        XCTAssertEqual(failed.accessibilityLabel, "Tests, part 1 of 4, failed, 6 minutes 12 seconds")
        XCTAssertEqual(model.groups[0].checks.map(\.name), ["Tests, part 1 of 4", "Format", "Dialyzer", "Coverage report"])
        XCTAssertEqual(model.groups[1].checks.map(\.word), ["Passed", "Running"])
        XCTAssertEqual(model.groups[2].checks.map(\.status), [.idle])
        XCTAssertEqual(Set(model.groups.map(\.id)).count, 3)
    }

    func testAPullRequestLessTicketHasNoPanelModelAndThePanelSaysSoInAPlainLine() throws {
        XCTAssertNil(PullRequestPanelModel.build(try read("blockers").pullRequest))
        XCTAssertEqual(PullRequestPanelModel.emptyLine, "No pull request yet: the first run opens one, and its checks appear here.")
    }

    func testEachStateOfThePullRequestAndOfItsChecksHasItsWordAndStatus() {
        func state(_ pr: TicketPullRequest) -> (String, DesignTokens.Status)? {
            PullRequestPanelModel.build(pr).map { ($0.state, $0.stateStatus) }
        }
        XCTAssertEqual(state(TicketPullRequest(number: 1, state: "merged"))?.0, "Merged")
        XCTAssertEqual(state(TicketPullRequest(number: 1, state: "merged"))?.1, .done)
        XCTAssertEqual(state(TicketPullRequest(number: 1, state: "closed"))?.0, "Closed")
        XCTAssertEqual(state(TicketPullRequest(number: 1, draft: true))?.0, "Draft")

        let bare = try? XCTUnwrap(PullRequestPanelModel.build(TicketPullRequest(number: 2)))
        XCTAssertNil(bare?.head)
        XCTAssertNil(bare?.size)
        XCTAssertNil(bare?.checksLine)
        XCTAssertEqual(bare?.checksBadge, "No checks yet")
        XCTAssertEqual(bare?.accessibilityLabel, "Pull request 2, open, no checks yet")

        let sized = PullRequestPanelModel.build(TicketPullRequest(number: 3, headShort: "abc1234", filesChanged: 1))
        XCTAssertEqual(sized?.head, "abc1234")
        XCTAssertEqual(sized?.size, "1 file")

        let checks: [TicketPullRequest.Check] = [
            .init(name: "a", state: .failed), .init(name: "b", state: .failed), .init(name: "c", state: .cancelledNoMachine),
            .init(name: "d", state: .waiting, durationMs: 840), .init(name: "e", state: .passed, durationMs: 120_000),
            .init(name: "f", state: .passed, durationMs: 3_840_000),
        ]
        let model = PullRequestPanelModel.build(TicketPullRequest(number: 4, checks: [.init(workflow: "CI", checks: checks)]))
        XCTAssertEqual(model?.checksBadge, "2 checks failed")
        XCTAssertEqual(model?.checksLine, "2 failed · 2 passed · 1 waiting · 1 without a machine")
        XCTAssertEqual(model?.groups.first?.checks.map(\.word), ["Failed", "Failed", "No machine", "Waiting", "Passed", "Passed"])
        XCTAssertEqual(model?.groups.first?.checks.map(\.duration), [nil, nil, nil, "840 ms", "2 min", "1 h 4 min"])
        XCTAssertEqual(model?.groups.first?.checks.map(\.accessibilityLabel).suffix(2), ["e, passed, 2 minutes", "f, passed, 1 hour 4 minutes"])

        let running = PullRequestPanelModel.build(TicketPullRequest(number: 5, checks: [.init(workflow: nil, checks: [.init(name: "x", state: .waiting)])]))
        XCTAssertEqual(running?.checksBadge, "Checks running")
        XCTAssertEqual(running?.groups.map(\.name), ["Other checks"])
    }

    // MARK: - The Connected panel

    func testTheEpicSaysItsProgressWhereThisTicketSitsAndTheTicketsAroundIt() throws {
        let epic = try XCTUnwrap(try connected("blockers").epic)
        XCTAssertEqual(epic.identifier, "TP-1381")
        XCTAssertEqual(epic.title, "Phase 3b: the Director redesigned around a ticket's situation")
        XCTAssertEqual(epic.progress, "3 of 6 done")
        XCTAssertEqual(epic.place, "this is the 5th")
        XCTAssertEqual(epic.progressLine, "3 of 6 done · this is the 5th")
        XCTAssertEqual(epic.strip?.segments, [.done, .done, .done, .working, .notStarted, .notStarted])
        XCTAssertEqual(
            epic.accessibilityLabel,
            "Epic TP-1381, Phase 3b: the Director redesigned around a ticket's situation, 3 of 6 sub-tickets done, this is the 5th"
        )
        // The one before it, this one, and the next ones the chain has.
        XCTAssertEqual(epic.tickets.map(\.identifier), ["TP-1446", "TP-1447", "TP-1448"])
        XCTAssertEqual(epic.tickets.map(\.current), [false, true, false])
        XCTAssertEqual(epic.tickets.map(\.badge), ["Waiting for CI", "Blocked", "Blocked"])
        XCTAssertEqual(epic.tickets.map(\.status), [.working, .idle, .idle])
        XCTAssertEqual(
            epic.tickets[1].accessibilityLabel, "This ticket, TP-1447, The facts rail's Note, Decisions and Details panels, Blocked"
        )
        XCTAssertEqual(epic.tickets[0].accessibilityLabel, "TP-1446, The facts rail's Pull request and Connected panels, Waiting for CI")
    }

    func testALargeEpicListsOnlyTheTicketBeforeThisOneAndTheNextTwo() {
        let tickets = (1 ... 40).map { TicketConnected.Ticket(identifier: "TP-\($0)", state: "Todo", current: $0 == 21) }
        let epic = ConnectedPanelModel.build(TicketConnected(epic: .init(identifier: "TP-0", done: 20, total: 40, tickets: tickets))).epic
        XCTAssertEqual(epic?.tickets.map(\.identifier), ["TP-20", "TP-21", "TP-22", "TP-23"])
        XCTAssertEqual(epic?.tickets.map(\.badge), ["Todo", "Todo", "Todo", "Todo"])
        XCTAssertEqual(epic?.progressLine, "20 of 40 done · this is the 21st")

        let first = ConnectedPanelModel.build(TicketConnected(epic: .init(identifier: "TP-0", tickets: Array(tickets[20...])))).epic
        XCTAssertEqual(first?.tickets.map(\.identifier), ["TP-21", "TP-22", "TP-23"])
        XCTAssertEqual(first?.place, "this is the 1st")

        let last = ConnectedPanelModel.build(TicketConnected(epic: .init(identifier: "TP-0", tickets: Array(tickets[..<21])))).epic
        XCTAssertEqual(last?.tickets.map(\.identifier), ["TP-20", "TP-21"])
    }

    func testAnEpicWhoseListDoesNotHoldThisTicketSaysOnlyItsProgress() {
        let epic = ConnectedPanelModel.build(TicketConnected(epic: .init(identifier: "TP-9", done: 1, total: 1))).epic
        XCTAssertNil(epic?.strip)
        XCTAssertNil(epic?.place)
        XCTAssertEqual(epic?.tickets, [])
        XCTAssertEqual(epic?.title, "TP-9")
        XCTAssertEqual(epic?.progressLine, "1 of 1 done")
        XCTAssertEqual(epic?.accessibilityLabel, "Epic TP-9, TP-9, 1 of 1 sub-ticket done")
    }

    func testWaitingOnListsOnlyWhatBlocksItNowAndHoldingUpWhatItBlocks() throws {
        let model = try connected("blockers")
        // TP-1445 resolved yesterday: what it waited on before is the timeline's, not the panel's.
        XCTAssertEqual(model.waitingOn.map(\.identifier), ["TP-1446"])
        let open = model.waitingOn[0]
        XCTAssertEqual(open.badge, "Waiting for CI")
        XCTAssertEqual(open.status, .working)
        XCTAssertFalse(open.current)
        XCTAssertEqual(open.accessibilityLabel, "TP-1446, The facts rail's Pull request and Connected panels, holds this one up, Waiting for CI")
        XCTAssertEqual(model.holdingUp.map(\.identifier), ["TP-1448"])
        XCTAssertEqual(model.holdingUp[0].badge, "Blocked")
        XCTAssertEqual(model.holdingUp[0].accessibilityLabel, "TP-1448, The ticket page's layout on a laptop, waits on this one, Blocked")
        XCTAssertFalse(model.isEmpty)
    }

    func testATicketConnectedToNothingHasNoPanelAndOneWithOnlyResolvedBlockersNeither() {
        XCTAssertTrue(ConnectedPanelModel.build(nil).isEmpty)
        let resolved = ConnectedPanelModel.build(TicketConnected(blockedBy: [TicketConnected.Blocker(identifier: "TP-8", resolved: true)]))
        XCTAssertTrue(resolved.waitingOn.isEmpty)
        XCTAssertTrue(resolved.isEmpty)
        XCTAssertFalse(ConnectedPanelModel.build(TicketConnected(blocks: [TicketConnected.Ticket(identifier: "TP-4")])).isEmpty)
        XCTAssertFalse(ConnectedPanelModel.build(TicketConnected(epic: .init(identifier: "TP-9"))).isEmpty)
        XCTAssertFalse(ConnectedPanelModel.build(TicketConnected(subTickets: [TicketConnected.Ticket(identifier: "TP-3")])).isEmpty)
        XCTAssertFalse(ConnectedPanelModel.build(TicketConnected(blockedBy: [TicketConnected.Blocker(identifier: "TP-8")])).isEmpty)
    }

    func testTheSubTicketsFixtureDecodesTheSubTicketsInTheirOrderWithTheDoneOneKept() throws {
        let connected = try XCTUnwrap(try read("sub-tickets").connected)
        XCTAssertEqual(connected.subTickets.map(\.identifier), ["TP-1644", "TP-1645", "TP-1646", "TP-1647"])
        XCTAssertEqual(connected.subTickets.map(\.state), ["Done", "In Progress", "Todo", "Todo"])
        XCTAssertEqual(connected.subTickets.map(\.situation), [.done, .working, .slot, .blocked])
        XCTAssertEqual(connected.subTickets[0].title, "Home: the Recently done section and the done row")
    }

    func testTheSubTicketsAreOneLineEachInTheirOrderAndEachOpensItsPage() throws {
        let model = try connected("sub-tickets")
        XCTAssertEqual(model.subTickets.map(\.identifier), ["TP-1644", "TP-1645", "TP-1646", "TP-1647"])
        XCTAssertEqual(model.subTickets.map(\.title), [
            "Home: the Recently done section and the done row",
            "Home queue: epic rows with sub-rows and done rows, dependency markers",
            "Home: the epic slot card",
            "Home: a click on a ticket's title opens the ticket's page",
        ])
        let kinds: [DesignTokens.SituationKind] = [.done, .working, .slot, .blocked]
        XCTAssertEqual(model.subTickets.map(\.status), kinds.map(\.status))
        XCTAssertEqual(model.subTickets.map(\.badge), kinds.map(\.word))
        // None is this ticket, so each line opens its ticket's page.
        XCTAssertEqual(model.subTickets.map(\.current), [false, false, false, false])
        XCTAssertEqual(
            model.subTickets[0].accessibilityLabel,
            "TP-1644, Home: the Recently done section and the done row, sub-ticket of this one, \(DesignTokens.SituationKind.done.word)"
        )
    }

    func testATicketThatIsASubTicketAndAParentShowsItsEpicAndItsSubTickets() throws {
        let model = try connected("sub-tickets")
        let epic = try XCTUnwrap(model.epic)
        XCTAssertEqual(epic.identifier, "TP-1597")
        XCTAssertEqual(epic.progressLine, "3 of 5 done · this is the 4th")
        XCTAssertNotNil(epic.strip)
        XCTAssertEqual(model.subTickets.count, 4)
        // Its only dependency is met: no Waiting on lines, and the panel is still drawn.
        XCTAssertTrue(model.waitingOn.isEmpty)
        XCTAssertFalse(model.isEmpty)
    }

    func testAnEpicWithOnlySubTicketsAndAMetDependencyStillHasItsPanel() {
        let connected = TicketConnected(
            subTickets: [TicketConnected.Ticket(identifier: "TP-2", title: "Done part", state: "Done", situation: .done)],
            blockedBy: [TicketConnected.Blocker(identifier: "TP-8", resolved: true)]
        )
        let model = ConnectedPanelModel.build(connected)
        XCTAssertEqual(model.subTickets.map(\.identifier), ["TP-2"])
        XCTAssertFalse(model.isEmpty)
        let blocker = ConnectedPanelModel.build(TicketConnected(
            subTickets: [TicketConnected.Ticket(identifier: "TP-2", situation: .done)],
            blockedBy: [TicketConnected.Blocker(identifier: "TP-2")]
        ))
        // A blocker that is also a sub-ticket takes its situation from the sub-tickets' list.
        XCTAssertEqual(blocker.waitingOn.map(\.status), [DesignTokens.SituationKind.done.status])
    }

    func testTicketsWithoutTheirFactsStillReadInWords() {
        let connected = TicketConnected(
            blockedBy: [TicketConnected.Blocker(identifier: "TP-8"), TicketConnected.Blocker(identifier: "TP-7", state: "In Progress")],
            blocks: [TicketConnected.Ticket(identifier: "TP-4")]
        )
        let model = ConnectedPanelModel.build(connected)
        XCTAssertEqual(model.waitingOn.map(\.title), ["TP-8", "TP-7"])
        XCTAssertEqual(model.waitingOn.map(\.badge), [nil, "In Progress"])
        XCTAssertEqual(model.waitingOn[0].status, .idle)
        XCTAssertEqual(model.waitingOn[0].accessibilityLabel, "TP-8, TP-8, holds this one up")
        XCTAssertNil(model.holdingUp[0].badge)
        XCTAssertEqual(model.holdingUp[0].accessibilityLabel, "TP-4, TP-4, waits on this one")
    }

    func testOrdinalsReadInEnglish() {
        let numbers = [1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101, 111, 112]
        XCTAssertEqual(
            numbers.map(ConnectedPanelModel.ordinal),
            ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "101st", "111th", "112th"]
        )
    }

    // MARK: - A blocker as the Initiatives page lists it

    func testAResolvedBlockerIsStruckThroughWithItsDayAndAnOpenOneSaysWhereItStands() throws {
        let blockers = try read("blockers").connected?.blockedBy ?? []
        let resolved = ConnectedPanelModel.row(blockers[0], situation: nil, reference: reference, calendar: utc)
        XCTAssertTrue(resolved.struck)
        XCTAssertEqual(resolved.detail, "Resolved yesterday, Mon 9 Nov")
        XCTAssertEqual(resolved.status, .done)
        XCTAssertEqual(resolved.accessibilityLabel, "TP-1445, The Lifecycle section and the Phase path, no longer holds this one up, resolved yesterday, Mon 9 Nov")
        let open = ConnectedPanelModel.row(blockers[1], situation: .ci, reference: reference, calendar: utc)
        XCTAssertFalse(open.struck)
        XCTAssertEqual(open.detail, "Waiting for CI · Code Review")
        XCTAssertEqual(open.status, .working)
        XCTAssertEqual(open.accessibilityLabel, "TP-1446, The facts rail's Pull request and Connected panels, holds this one up, Waiting for CI, Code Review")

        func row(_ blocker: TicketConnected.Blocker) -> ConnectedPanelModel.Row {
            ConnectedPanelModel.row(blocker, situation: nil, reference: reference, calendar: utc)
        }
        let date = ISO8601DateFormatter()
        XCTAssertEqual(row(.init(identifier: "TP-8")).detail, "Open")
        XCTAssertEqual(row(.init(identifier: "TP-8")).accessibilityLabel, "TP-8, TP-8, holds this one up")
        XCTAssertEqual(row(.init(identifier: "TP-7", resolved: true)).detail, "Resolved")
        XCTAssertEqual(row(.init(identifier: "TP-6", resolved: true, resolvedAt: date.date(from: "2026-11-10T09:05:00Z"))).detail, "Resolved today 09:05")
        XCTAssertEqual(row(.init(identifier: "TP-5", resolved: true, resolvedAt: date.date(from: "2026-11-06T09:05:00Z"))).detail, "Resolved Fri 6 Nov")
    }

    func testAnEpicTicketsSegmentFollowsItsStateAndSituation() {
        func segment(_ state: String?, _ situation: DesignTokens.SituationKind? = nil) -> SubTicketStrip.Segment {
            SubTicketStrip.Segment(ticket: TicketConnected.Ticket(identifier: "TP-1", state: state, situation: situation))
        }
        XCTAssertEqual(segment("Done"), .done)
        XCTAssertEqual(segment("Merging", .done), .done)
        XCTAssertEqual(segment("Code Review", .you), .waitingOnYou)
        XCTAssertEqual(segment("In Progress", .working), .working)
        XCTAssertEqual(segment("Todo"), .notStarted)
        XCTAssertEqual(segment(nil), .notStarted)
    }
}
