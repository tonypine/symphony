import Foundation
import XCTest
@testable import SymphonyBarCore

final class InboxTests: XCTestCase {
    // MARK: - The shipped fixtures

    func testTheInboxFixtureHasOneItemOfEachKindWithItsReview() throws {
        let inbox = try payload("inbox")
        XCTAssertEqual(inbox.items.map(\.kind), [.plan, .pr, .finalVerification, .action, .clarify])

        let plan = inbox.items[0]
        XCTAssertEqual(plan.identifier, "SHOP-330")
        XCTAssertEqual(plan.repoKey, "web-shop")
        XCTAssertEqual(plan.age, "3 h 12 min")
        guard case let .parsed(brief)? = plan.review.brief else { return XCTFail("the plan's brief didn't parse") }
        XCTAssertEqual(brief.whatToReview.first?.links.first?.label, "Domain brief")
        XCTAssertEqual(brief.decisions.count, 2)
        XCTAssertEqual(brief.decisions.map(\.initialPick), [0, 0])
        XCTAssertEqual(brief.moves.map(\.move), ["approve", "change", "reject"])
        XCTAssertEqual(plan.review.subTickets.map(\.identifier), (331...337).map { "SHOP-\($0)" })

        let pr = try XCTUnwrap(inbox.items[1].review.pullRequest)
        XCTAssertEqual(pr.url?.absoluteString, "https://github.com/acme/api/pull/412")
        XCTAssertEqual(pr.ci, .passed)
        XCTAssertEqual(pr.qaVerdict, "pass")
        XCTAssertEqual(pr.qaReport?.absoluteString, "https://linear.app/acme/issue/BIL-206#comment-5d1e0a2c")
        XCTAssertEqual(pr.gateVerdict, "escalate")
        XCTAssertEqual(pr.gateMode, "shadow")
        XCTAssertEqual(pr.changeLine, "9 files, +412 −38")
        XCTAssertFalse(pr.hasRedCheck)

        guard case let .raw(text)? = inbox.items[2].review.brief else { return XCTFail("the final verification's brief should be raw") }
        XCTAssertTrue(text.hasPrefix("## Review brief"))

        let action = try XCTUnwrap(inbox.items[3].review.action)
        XCTAssertEqual(action.steps.count, 4)
        XCTAssertEqual(action.timeLine, "About 10 min")
        XCTAssertEqual(action.unblocks, "the Release workflow on main")
        XCTAssertEqual(action.copyText?.split(separator: "\n").first, "1. Export the Developer ID certificate from Keychain Access as a .p12 file.")

        let clarify = try XCTUnwrap(inbox.items[4].review.clarify)
        XCTAssertTrue(clarify.held)
        XCTAssertEqual(clarify.scoreLine, "3 of 10, passes at 6")
        XCTAssertEqual(clarify.roundLine, "Round 1 of 2")
        XCTAssertEqual(clarify.questions.count, 2)
    }

    func testTheBadgeTheMenuTheTileAndTheInboxAgreeOnTheCount() throws {
        for name in ["inbox", "inbox-empty"] {
            let inbox = try payload(name)
            let stateData = try Data(contentsOf: fixture(name).appendingPathComponent("state.json"))
            let state = try XCTUnwrap(OverviewState.decode(stateData))
            guard case let .state(snapshot) = SymphonyState.poll(data: stateData, statusCode: 200) else {
                return XCTFail("\(name)'s state doesn't read as a state")
            }
            let status = SymphonyStatus.running(snapshot, external: true)
            let overview = Overview(state: state, now: Date())
            let tile = try XCTUnwrap(overview.stages.first { $0.kind == .waitingOnYou })

            XCTAssertEqual(InboxList(items: inbox.items).totalCount, inbox.items.count, name)
            XCTAssertEqual(state.snapshot.waitingOnYou.count, inbox.items.count, name)
            XCTAssertEqual(tile.count, inbox.items.count, name)
            XCTAssertEqual(StatusMenu.badgeCount(for: status), inbox.items.isEmpty ? nil : inbox.items.count, name)
            XCTAssertEqual(StatusMenu.waitingMenu(status).tickets.map(\.identifier), Array(inbox.items.map(\.identifier).prefix(5)), name)
        }
        XCTAssertTrue(InboxList(items: try payload("inbox-empty").items).isEmpty)
    }

    func testTheMenuListsTheOldestFiveWithTheirKindSymbolAndAge() throws {
        let data = try Data(contentsOf: fixture("inbox").appendingPathComponent("state.json"))
        guard case let .state(snapshot) = SymphonyState.poll(data: data, statusCode: 200) else { return XCTFail("not a state") }
        let menu = StatusMenu.waitingMenu(.running(snapshot, external: true))
        XCTAssertEqual(menu.tickets.map(\.kind.symbol), [
            "doc.text.magnifyingglass", "arrow.triangle.pull", "checkmark.seal", "hand.raised", "questionmark.bubble",
        ])
        XCTAssertEqual(menu.tickets.first?.issueID, "i-330")
        XCTAssertEqual(menu.tickets.first?.repoKey, "web-shop")
        XCTAssertEqual(StatusMenu.waitingLine(menu.tickets[4]), "SHOP-341 · Clarify · Answer the quality gate's questions · 10m")
        XCTAssertEqual(StateSnapshot.WaitingTicket.Kind.other("audit").symbol, SymphonyView.inbox.symbol)
    }

    // MARK: - The list

    func testGroupsByKindOldestFirstAndSaysWhatTheScopeHides() {
        let items = [
            item("A-1", .pr, repo: "api", seconds: 60),
            item("W-1", .plan, repo: "web", seconds: 600),
            item("A-2", .pr, repo: "api", seconds: 3_600),
            item("A-3", .pr, repo: "api", seconds: nil),
            item("W-2", .clarify, repo: "web", seconds: 30),
            item("D-1", .action, repo: "docs", seconds: 10),
        ]
        let all = InboxList(items: items)
        XCTAssertEqual(all.groups.map(\.title), ["Plans", "Pull requests", "Actions", "Clarify"])
        XCTAssertEqual(all.groups.map(\.id), ["plan", "pr", "action", "clarify"])
        XCTAssertEqual(all.groups[1].items.map(\.identifier), ["A-2", "A-1", "A-3"])
        XCTAssertEqual(all.ordered.map(\.identifier), ["W-1", "A-2", "A-1", "A-3", "D-1", "W-2"])
        XCTAssertNil(all.hiddenLine)
        XCTAssertEqual(all.totalCount, 6)

        let api = InboxList(items: items, scope: .repo("api"))
        XCTAssertEqual(api.groups.map(\.kind), [.pr])
        XCTAssertEqual(api.hiddenCount, 3)
        XCTAssertEqual(api.hiddenLine, "3 more in other repos")
        XCTAssertEqual(api.totalCount, 6)
        XCTAssertEqual(InboxList(items: items, scope: .repo("docs")).hiddenLine, "5 more in other repos")
        XCTAssertEqual(InboxList(items: [items[0], items[5]], scope: .repo("api")).hiddenLine, "1 more in another repo")

        let none = InboxList(items: items, scope: .repo("ios"))
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(none.hiddenLine, "6 more in other repos")
    }

    func testSelectionFallsBackToTheFirstAndMovesToTheNeighbor() {
        let list = InboxList(items: [item("P-1", .plan, seconds: 9), item("R-1", .pr, seconds: 5), item("R-2", .pr, seconds: 1)])
        XCTAssertEqual(list.selection(nil)?.identifier, "P-1")
        XCTAssertEqual(list.selection("id-R-1")?.identifier, "R-1")
        XCTAssertEqual(list.selection("gone")?.identifier, "P-1")
        XCTAssertEqual(list.neighbor(of: "id-P-1")?.identifier, "R-1")
        XCTAssertEqual(list.neighbor(of: "id-R-2")?.identifier, "R-1")
        XCTAssertEqual(list.neighbor(of: "gone")?.identifier, "P-1")
        XCTAssertNil(InboxList(items: [item("P-1", .plan)]).neighbor(of: "id-P-1"))
    }

    func testVoiceOverReadsARowAsIdentifierTitleKindAndAge() {
        XCTAssertEqual(
            item("SHOP-330", .plan, title: "Gift cards", seconds: 11_520).accessibilityLabel,
            "SHOP-330, Gift cards, plan, 3 hours 12 minutes"
        )
        XCTAssertEqual(item("BIL-9", .finalVerification, title: nil, seconds: nil).accessibilityLabel, "BIL-9, final verification")
    }

    // MARK: - Actions

    func testEachKindOffersItsActions() {
        let linear = URL(string: "https://linear.app/acme/issue/X-1")!
        let prURL = URL(string: "https://github.com/acme/x/pull/1")!

        var plan = item("X-1", .plan)
        plan.url = linear
        XCTAssertEqual(InboxAction.actions(for: plan), [.openInLinear(linear)])

        var pr = item("X-1", .pr)
        pr.url = linear
        pr.review.pullRequest = InboxReview.PullRequest(url: prURL, ci: .failed)
        XCTAssertEqual(InboxAction.actions(for: pr), [.openPR(prURL), .openInLinear(linear)])
        XCTAssertTrue(pr.review.pullRequest?.hasRedCheck == true)

        var action = item("X-1", .action)
        action.url = linear
        action.review.action = InboxReview.Action(steps: [], options: [.init(label: "Add it", effect: "Releases sign.", recommended: true), .init(label: "Drop it", effect: nil, recommended: false)])
        XCTAssertEqual(InboxAction.actions(for: action), [.openInLinear(linear), .copySteps("1. Add it: Releases sign.\n2. Drop it")])
        action.review.action = InboxReview.Action(steps: [], options: [])
        XCTAssertEqual(InboxAction.actions(for: action), [.openInLinear(linear)])

        var clarify = item("X-1", .clarify)
        clarify.url = linear
        XCTAssertEqual(InboxAction.actions(for: clarify), [.editInLinear(linear)])
        XCTAssertEqual(InboxAction.actions(for: item("X-2", .clarify)), [])

        XCTAssertEqual([InboxAction.openInLinear(linear), .openPR(prURL), .copySteps(""), .editInLinear(linear)].map(\.title), [
            "Open in Linear", "Open PR", "Copy Steps", "Edit in Linear",
        ])
    }

    func testReadsAnItemWithMissingFieldsAndSkipsOneWithoutAKind() throws {
        let json = """
        {"items": [
          {"issue_id": "i-1", "identifier": "X-1", "kind": "pr", "review": {"brief": {"format": "raw", "markdown": "Just read it."},
            "pull_request": {"ci": "failed", "qa": {"verdict": "blocked"}, "gate": {"verdict": "rework"}}}},
          {"issue_id": "i-2", "kind": "pr"},
          {"identifier": "X-3", "kind": "audit"},
          {"identifier": "X-4", "kind": "clarify", "review": {"held": false, "found": "Empty."}},
          {"identifier": "X-5", "kind": "plan", "review": {"brief": {"format": "parsed", "decisions": [{"question": "Q?", "options": ["A"], "recommended": 3}, {"options": []}],
            "moves": [{"move": "approve"}], "what_to_review": [{"links": [{"url": "https://example.com/a"}]}]}, "sub_tickets": [{"title": "no id"}]}}
        ]}
        """
        let inbox = try XCTUnwrap(InboxPayload.decode(Data(json.utf8)))
        XCTAssertEqual(inbox.items.map(\.identifier), ["X-1", "i-2", "X-4", "X-5"])
        XCTAssertEqual(inbox.items[0].review.brief, .raw("Just read it."))
        XCTAssertEqual(inbox.items[0].review.pullRequest?.ci, .failed)
        XCTAssertNil(inbox.items[0].review.pullRequest?.changeLine)
        XCTAssertEqual(inbox.items[1].ask, "i-2")
        XCTAssertNil(inbox.items[0].age)
        let clarify = try XCTUnwrap(inbox.items[2].review.clarify)
        XCTAssertNil(clarify.scoreLine)
        XCTAssertNil(clarify.roundLine)
        XCTAssertTrue(clarify.nextLine.hasPrefix("Symphony skips the ticket"))
        XCTAssertTrue(InboxReview.Clarify(held: true, questions: []).nextLine.hasPrefix("Symphony scores the ticket again"))
        guard case let .parsed(brief)? = inbox.items[3].review.brief else { return XCTFail("not parsed") }
        XCTAssertEqual(brief.decisions.count, 1)
        XCTAssertNil(brief.decisions[0].initialPick)
        XCTAssertEqual(brief.moves, [])
        XCTAssertEqual(brief.whatToReview.first?.links.first?.label, "https://example.com/a")
        XCTAssertEqual(inbox.items[3].review.subTickets, [])

        XCTAssertNil(InboxPayload.decode(Data(#"{"error": {"code": "snapshot_timeout"}}"#.utf8)))
        XCTAssertNil(InboxPayload.decode(Data("not json".utf8)))
        XCTAssertEqual(
            InboxReview.PullRequest(files: 1, additions: nil, deletions: 2).changeLine,
            "1 file, +0 −2"
        )
    }

    // MARK: - Notifications

    func testNotifiesEachNewItemAndProblemOnceAndNotTheOnesAlreadyThere() {
        var notifier = InboxNotifier()
        let first = [waiting("P-1", .plan), waiting("R-1", .pr)]
        // The first poll ever only remembers what is there.
        XCTAssertEqual(notifier.notices(waiting: first, problems: [], preferences: .init()), [])

        let notices = notifier.notices(waiting: first + [waiting("R-2", .pr, headline: "The retry fix")], problems: [problem("SHOP-305")], preferences: .init())
        XCTAssertEqual(notices.map(\.key), ["pr:id-R-2", "problem:SHOP-305:stuck"])
        XCTAssertEqual(notices[0].title, "R-2 waits on you")
        XCTAssertEqual(notices[0].body, "Pull request: The retry fix")
        XCTAssertEqual(notices[0].issueID, "id-R-2")
        XCTAssertEqual(notices[1].title, "SHOP-305 shows no agent activity for 14 min.")
        XCTAssertEqual(notices[1].body, "Needs attention")
        XCTAssertNil(notices[1].issueID)

        // Never twice, even once it left and came back.
        XCTAssertEqual(notifier.notices(waiting: first, problems: [], preferences: .init()), [])
        XCTAssertEqual(notifier.notices(waiting: first + [waiting("R-2", .pr)], problems: [problem("SHOP-305")], preferences: .init()), [])
        // A kind this app doesn't know never notifies.
        XCTAssertEqual(notifier.notices(waiting: [waiting("Z-1", .other("audit"))], problems: [], preferences: .init()), [])
    }

    func testAKindTurnedOffDoesntNotifyAndIsntOwedLater() {
        var notifier = InboxNotifier(remembered: [])
        var preferences = NotificationPreferences()
        preferences.set(.clarify, on: false)
        preferences.set(.problem, on: false)
        XCTAssertFalse(preferences.isOn(.clarify))

        let notices = notifier.notices(waiting: [waiting("C-1", .clarify), waiting("A-1", .action)], problems: [problem("X-1")], preferences: preferences)
        XCTAssertEqual(notices.map(\.kind), [.action])

        preferences.set(.clarify, on: true)
        XCTAssertTrue(preferences.isOn(.clarify))
        XCTAssertEqual(notifier.notices(waiting: [waiting("C-1", .clarify)], problems: [], preferences: preferences), [])
    }

    func testRemembersNotifiedKeysAndPreferencesAcrossRelaunches() {
        let defaults = MemoryKeyValueStore()
        XCTAssertEqual(InboxNotifier.load(from: defaults), InboxNotifier(remembered: nil))
        XCTAssertEqual(NotificationPreferences.load(from: defaults), NotificationPreferences())

        var notifier = InboxNotifier(remembered: [])
        _ = notifier.notices(waiting: [waiting("P-1", .plan)], problems: [], preferences: .init())
        notifier.save(to: defaults)
        XCTAssertEqual(InboxNotifier.load(from: defaults).remembered, ["plan:id-P-1"])

        var preferences = NotificationPreferences()
        preferences.set(.problem, on: false)
        preferences.set(.pr, on: false)
        preferences.save(to: defaults)
        XCTAssertEqual(defaults.object(forKey: NotificationPreferences.defaultsKey) as? [String], ["pr", "problem"])
        XCTAssertEqual(NotificationPreferences.load(from: defaults).off, [.pr, .problem])

        XCTAssertEqual(NoticeKind.allCases.map(\.settingsTitle).count, 6)
    }

    func testKeepsOnlyTheNewestKeys() {
        var notifier = InboxNotifier(remembered: (0..<InboxNotifier.keyLimit).map { "old-\($0)" })
        let notices = notifier.notices(waiting: [waiting("N-1", .action)], problems: [], preferences: .init())
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notifier.remembered?.count, InboxNotifier.keyLimit)
        XCTAssertEqual(notifier.remembered?.last, "action:id-N-1")
        XCTAssertEqual(notifier.remembered?.first, "old-1")
    }

    // MARK: - Helpers

    private func item(_ identifier: String, _ kind: InboxItem.Kind, repo: String? = nil, title: String? = "Title", seconds: Int? = nil) -> InboxItem {
        InboxItem(id: "id-\(identifier)", identifier: identifier, title: title, repoKey: repo, kind: kind, ask: "Ask", waitingSeconds: seconds)
    }

    private func waiting(_ identifier: String, _ kind: StateSnapshot.WaitingTicket.Kind, headline: String? = nil) -> StateSnapshot.WaitingTicket {
        .init(issueID: "id-\(identifier)", identifier: identifier, title: "Title of \(identifier)", kind: kind, headline: headline)
    }

    private func problem(_ id: String) -> Overview.Problem {
        Overview.Problem(id: id, kinds: [.stuck], severity: .problem, sentence: "\(id) shows no agent activity for 14 min.", ageSeconds: 840, note: nil, fixes: [])
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/\(name)/api/v1", isDirectory: true)
    }

    private func payload(_ name: String) throws -> InboxPayload {
        try XCTUnwrap(InboxPayload.decode(Data(contentsOf: fixture(name).appendingPathComponent("inbox.json"))))
    }
}
