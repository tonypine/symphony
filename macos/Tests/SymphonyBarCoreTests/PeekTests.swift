import Foundation
import XCTest
@testable import SymphonyBarCore

/// N4, the peek: its navigation, where it shows, and what a ticket's page holds, against the decision fixtures.
final class PeekTests: XCTestCase {
    // MARK: - Navigation

    func testFollowingTP880InsideATP891PeekPushesBackReturnsAndEscCloses() throws {
        let item = try decision()
        var peek = PeekNavigation()
        XCTAssertFalse(peek.isShown)
        XCTAssertFalse(peek.canToggle)

        peek.open(try entry("TP-891", in: item))
        XCTAssertTrue(peek.isShown)
        XCTAssertEqual(peek.current?.title, "TP-891")
        XCTAssertFalse(peek.canGoBack)
        XCTAssertFalse(peek.goBack(), "⌘[ goes on to the window's history")

        let tp880 = try entry("TP-880", in: item)
        peek.push(tp880)
        XCTAssertEqual(peek.current, tp880)
        XCTAssertEqual(peek.root?.title, "TP-891")
        XCTAssertTrue(peek.canGoBack)
        peek.push(tp880)
        XCTAssertEqual(peek.pages.count, 2, "following the page shown changes nothing")

        XCTAssertTrue(peek.goBack())
        XCTAssertEqual(peek.current?.title, "TP-891")

        peek.close()
        XCTAssertFalse(peek.isShown, "Esc closes")
        XCTAssertFalse(peek.canGoBack)
        XCTAssertEqual(peek.current?.title, "TP-891", "its pages are kept for the toggle")
        XCTAssertTrue(peek.canToggle)
        peek.toggle()
        XCTAssertTrue(peek.isShown)
        peek.toggle()
        XCTAssertFalse(peek.isShown)
    }

    func testAChipInTheReviewStartsAFreshPeek() throws {
        let item = try decision()
        var peek = PeekNavigation()
        peek.push(try entry("TP-891", in: item))
        XCTAssertEqual(peek.pages.map(\.title), ["TP-891"], "a push with nothing open opens")
        peek.push(try entry("TP-880", in: item))
        peek.push(try entry("#448", in: item))
        XCTAssertEqual(peek.pages.map(\.title), ["TP-891", "TP-880", "#448"])

        XCTAssertTrue(peek.goBack())
        XCTAssertEqual(peek.pages.map(\.title), ["TP-891", "TP-880"])

        peek.close()
        peek.push(try entry("TP-892", in: item))
        XCTAssertEqual(peek.pages.map(\.title), ["TP-892"], "a closed peek opens afresh")
        peek.open(try entry("#448", in: item))
        XCTAssertEqual(peek.pages.map(\.title), ["#448"])
        XCTAssertTrue(peek.isShown)
    }

    func testPushingTP880WhileTP891sReadIsPendingReadsTP880AtOnce() throws {
        let item = try decision()
        var peek = PeekNavigation()
        var reads = PeekReads()
        peek.open(try entry("TP-891", in: item))
        XCTAssertNil(reads.start(peek, countsKnown: false), "nothing is read before Symphony answers")
        XCTAssertEqual(reads.start(peek, countsKnown: true), "TP-891")
        XCTAssertNil(reads.start(peek, countsKnown: true), "a state poll doesn't read TP-891 twice")

        peek.push(try entry("TP-880", in: item))
        XCTAssertEqual(reads.start(peek, countsKnown: true), "TP-880", "TP-891's pending read doesn't hold it back")
        XCTAssertEqual(reads.inFlight, ["TP-891", "TP-880"])

        reads.finish("TP-891")
        XCTAssertTrue(peek.goBack())
        XCTAssertEqual(reads.start(peek, countsKnown: true), "TP-891", "read again after each state poll")
        reads.finish("TP-891")
        reads.finish("TP-880")
        XCTAssertEqual(reads.inFlight, [])

        peek.push(try entry("#448", in: item))
        XCTAssertNil(reads.start(peek, countsKnown: true), "a pull request has no ticket page")
        peek.close()
        XCTAssertNil(reads.start(peek, countsKnown: true), "a closed peek reads nothing")
    }

    func testAnEntryIsTitledByItsTicketOrPullRequest() throws {
        let item = try decision()
        let pullRequest = try entry("#448", in: item)
        XCTAssertEqual(pullRequest.title, "#448")
        XCTAssertNil(pullRequest.ticketIdentifier)
        XCTAssertEqual(pullRequest.id, "#448")
        XCTAssertEqual(try entry("TP-891", in: item).ticketIdentifier, "TP-891")
        let mention = try XCTUnwrap(Mentions.find(in: "See #448.", references: item.references).first)
        XCTAssertEqual(PeekEntry(mention), pullRequest)
        XCTAssertEqual(ReferencePopover(key: "#448", kind: .pullRequest, reference: pullRequest.reference), ReferencePopover(mention))
        let missing = PeekEntry(key: "TP-999", kind: .ticket, reference: .missing(url: nil))
        XCTAssertEqual(missing.title, "TP-999")
        XCTAssertNil(missing.ticketIdentifier)
    }

    // MARK: - Picks

    func testOpeningAndClosingThePeekLeavesTheSelectedOptionAndTheWriteInAsTheyWere() throws {
        let item = try decision()
        let action = try XCTUnwrap(item.review.action)
        var picks = InboxPicks()
        picks.pick(2, decision: 0, itemID: item.id)
        picks.writeIn("Not this one", itemID: "i-923")
        let before = picks

        var peek = PeekNavigation()
        peek.open(try entry("TP-891", in: item))
        peek.push(try entry("TP-880", in: item))
        peek.goBack()
        peek.close()
        peek.toggle()
        peek.close()

        XCTAssertEqual(picks, before)
        XCTAssertEqual(action.pickedIndex(picks[item.id]), 2, "option 3 still reads selected")
        XCTAssertEqual(picks["i-923"].writeIn, "Not this one")
    }

    // MARK: - Presentation

    func testANarrowWindowPresentsThePeekAsASheet() {
        // The Inbox is its 340 pt list column, a divider and the review; the review beside the inspector decides.
        // A 1200 pt window: 1000 pt of Inbox leaves the review 259 pt beside a 400 pt inspector, so a sheet.
        XCTAssertEqual(PeekPresentation.choose(inboxWidth: 1000, inspectorShown: false), .sheet)
        XCTAssertEqual(PeekPresentation.choose(inboxWidth: 760, inspectorShown: false), .sheet)
        // A window wide enough for the review at 560 pt beside the inspector at its widest.
        XCTAssertEqual(PeekPresentation.choose(inboxWidth: 341 + 560 + 400, inspectorShown: false), .inspector)
        XCTAssertEqual(PeekPresentation.choose(inboxWidth: 341 + 559 + 400, inspectorShown: false), .sheet)
        // Measured with the inspector open.
        XCTAssertEqual(PeekPresentation.choose(inboxWidth: 341 + 560, inspectorShown: true), .inspector)
        XCTAssertEqual(PeekPresentation.choose(inboxWidth: 341 + 559, inspectorShown: true), .sheet)
        // Narrowed under 560 beside a 340 pt inspector, it turns into a sheet, and the wider Inbox the closed
        // inspector leaves keeps it one.
        XCTAssertEqual(PeekPresentation.choose(inboxWidth: 341 + 559 + 340, inspectorShown: false), .sheet)
        XCTAssertEqual(PeekPresentation.minDetailWidth, DesignTokens.Layout.narrowReviewWidth)
        XCTAssertLessThanOrEqual(PeekPresentation.minInspectorWidth, PeekPresentation.idealInspectorWidth)
        XCTAssertLessThanOrEqual(PeekPresentation.idealInspectorWidth, PeekPresentation.maxInspectorWidth)
    }

    // MARK: - A ticket's page

    func testAWatchedTicketOutsideTheInboxShowsConnectedFromItsEndpoint() throws {
        let item = try decision()
        let peek = TicketPeek(try ticket("TP-891", in: item), references: item.references, sources: try sources(issue: "TP-891"), now: now)

        XCTAssertTrue(peek.isTracked, "its endpoint answers: Symphony watches its pull request")
        XCTAssertEqual(peek.head.identifier, "TP-891")
        XCTAssertEqual(peek.head.repoKey, "symphony")
        XCTAssertEqual(peek.head.title, "Remove the retired review states and the version switch from the code")
        XCTAssertEqual(peek.head.badge?.word, "Code Review")
        XCTAssertEqual(peek.head.facts, [], "Now and Connected say it instead")
        XCTAssertEqual(peek.now, TicketPeek.Now(stage: "Code Review", waitingOn: nil, pullRequest: "PR #446 · checks running"))
        XCTAssertEqual(peek.references["PR #446"], .missing(url: URL(string: "https://github.com/tonypine/symphony/pull/446")))
        XCTAssertFalse(try payload().items.contains { $0.identifier == "TP-891" }, "it isn't in the Inbox")
        let connected = try XCTUnwrap(peek.connected, "its endpoint's connected")
        XCTAssertEqual(connected.parent?.text, "TP-880 (Remove the Supervisor check)")
        XCTAssertEqual(connected.parent?.progress, "1 of 2 done")
        XCTAssertEqual(connected.parent?.children, [.done, .working])
        XCTAssertEqual(connected.groups.map(\.label), ["Blocked by", "Blocks"])
        XCTAssertEqual(
            connected.blockedBy, [TicketPeek.Row(text: "TP-892 (Retire two old review steps)", state: "Rework")],
            "the endpoint names no title: the Inbox's reference does"
        )
        XCTAssertEqual(connected.blocks, [TicketPeek.Row(text: "TP-893 (Show the new review steps in the app)", state: "Todo")])
        XCTAssertEqual(
            Mentions.find(in: connected.blockedBy[0].text, references: peek.references).map(\.isMissing), [false],
            "the blocker is a chip"
        )
        guard case let .ticket(parent)? = peek.references["TP-880"] else { return XCTFail("TP-880 is a chip") }
        XCTAssertEqual(parent.state, "Done", "the item's own reference, not a made-up one")
        XCTAssertNil(peek.headline)
        XCTAssertEqual(peek.linearURL, URL(string: "https://linear.app/tonypine/issue/TP-891"))

        // Its parent's chip inside the peek finds the reference.
        let mentions = Mentions.find(in: connected.parent?.text ?? "", references: peek.references)
        XCTAssertEqual(mentions.map(\.chipText), ["TP-880 · Remove the Supervisor check"])
        XCTAssertFalse(mentions[0].isMissing)
    }

    func testTheInboxContextComesBeforeTheEndpointsConnected() throws {
        let issue = json([
            "status": "watching",
            "connected": [
                "parent": ["identifier": "P-9", "title": "Elsewhere", "done": 0, "total": 1, "children": ["unstarted"]],
                "sub_tickets": [["identifier": "S-9", "title": NSNull(), "state": "Todo"]],
                "blocked_by": [["identifier": "B-9", "title": "Endpoint blocker", "state": "Todo"]],
                "blocks": [["identifier": "K-9", "title": NSNull(), "state": NSNull()]],
                "related": [["identifier": "R-9", "title": "Endpoint related", "state": "Done"]],
            ],
        ])
        let item = try decision()
        var inbox = try payload().items
        let tp892 = try XCTUnwrap(inbox.firstIndex { $0.identifier == "TP-892" })
        inbox[tp892].context?.blockedBy = [TicketContext.Connected(identifier: "TP-880", title: nil, state: "Done")]
        let peek = TicketPeek(try ticket("TP-892", in: item), references: item.references, sources: PeekSources(inbox: inbox, issue: issue), now: now)
        let connected = try XCTUnwrap(peek.connected)
        XCTAssertEqual(connected.parent?.text, "TP-870 (Simplify the review flow)", "the Inbox's parent")
        XCTAssertEqual(connected.blockedBy.map(\.text), ["TP-880"], "the Inbox's blockers, as it names them")
        XCTAssertEqual(connected.blocks.map(\.text), ["TP-893 (Show the new review steps in the app)"])
        XCTAssertEqual(connected.related.map(\.state), ["Code Review"])
        XCTAssertEqual(connected.subTickets, [TicketPeek.Row(text: "S-9", state: "Todo")], "the Inbox has none: the endpoint's")

        // A ticket the Inbox doesn't hold takes every group from its endpoint.
        let watched = TicketPeek(Reference.Ticket(identifier: "W-1", title: nil), sources: PeekSources(issue: issue), now: now)
        XCTAssertEqual(watched.connected?.parent?.text, "P-9 (Elsewhere)")
        XCTAssertEqual(watched.connected?.groups.map(\.label), ["Sub-tickets", "Blocked by", "Blocks", "Related"])
        XCTAssertEqual(watched.connected?.blocks, [TicketPeek.Row(text: "K-9", state: nil)])
        XCTAssertNil(TicketPeek.endpointConnected(json(["status": "untracked"])), "an untracked ticket's endpoint has none")
    }

    func testAnUntrackedTicketShowsOnlyTheReferenceFacts() throws {
        let item = try decision()
        let peek = TicketPeek(try ticket("TP-880", in: item), references: item.references, sources: try sources(issue: nil), now: now)

        XCTAssertFalse(peek.isTracked)
        XCTAssertNil(peek.now)
        XCTAssertNil(peek.connected)
        XCTAssertNil(peek.headline)
        XCTAssertEqual(peek.head.title, "Remove the Supervisor check")
        XCTAssertEqual(peek.head.badge?.word, "Done")
        XCTAssertEqual(peek.head.facts, [
            ReferencePopover.Fact(label: "Part of", value: "TP-870 (Simplify the review flow)"),
            ReferencePopover.Fact(label: "Work", value: "PR #431 · checks passed"),
        ])
        XCTAssertEqual(peek.references["TP-870"], .ticket(Reference.Ticket(identifier: "TP-870", title: "Simplify the review flow")))

        let untracked = TicketPeek(try ticket("TP-893", in: item), references: item.references, sources: PeekSources(issue: json(["status": "untracked"])), now: now)
        XCTAssertFalse(untracked.isTracked, "an endpoint that only keeps its verdicts")
        XCTAssertEqual(untracked.head.facts.map(\.label), ["Part of", "Waiting on"])
        XCTAssertEqual(untracked.head.facts.last?.value, "a blocker: TP-892")
    }

    func testATicketWaitingOnTheDirectorBringsWhereItSits() throws {
        let item = try decision()
        let peek = TicketPeek(try ticket("TP-892", in: item), references: item.references, sources: try sources(issue: nil), now: now)

        XCTAssertTrue(peek.isTracked, "it waits on you in the Inbox")
        XCTAssertEqual(peek.now, TicketPeek.Now(stage: "Rework · for 1 h", waitingOn: "Waiting on you", pullRequest: "PR #448 · checks passed"))
        guard case .pullRequest? = peek.references["PR #448"] else { return XCTFail("the pull request's own reference") }
        let connected = try XCTUnwrap(peek.connected)
        XCTAssertEqual(connected.parent?.text, "TP-870 (Simplify the review flow)")
        XCTAssertEqual(connected.parent?.progress, "4 of 7 done")
        XCTAssertEqual(connected.parent?.children, [.done, .done, .done, .done, .working, .idle, .idle])
        XCTAssertEqual(connected.groups.map(\.label), ["Blocks", "Related"])
        XCTAssertEqual(connected.blocks, [TicketPeek.Row(text: "TP-893 (Show the new review steps in the app)", state: "Todo")])
        XCTAssertEqual(connected.related.map(\.text), ["TP-891 (Remove the retired review states and the version switch from the code)"])
        XCTAssertNil(peek.headline, "a request has no review brief")

        let plan = try XCTUnwrap(try payload().items.first { $0.identifier == "TP-923" })
        let reference = Reference.Ticket(identifier: "TP-923", title: nil)
        let planPeek = TicketPeek(reference, sources: try sources(issue: nil), now: now)
        XCTAssertEqual(planPeek.head.title, plan.title, "the item's title when the reference has none")
        XCTAssertEqual(planPeek.head.badge?.word, "Plan Review")
        XCTAssertEqual(planPeek.headline, "The plan to redesign the Inbox decision screen.")
        XCTAssertEqual(planPeek.connected?.subTickets, [TicketPeek.Row(text: "TP-947 (Write decisions in the Director's words)", state: "Backlog")])
        XCTAssertEqual(planPeek.linearURL, plan.url)
    }

    func testTheInitiativesGiveAPlansSubTicketsAndASubTicketsParentAndBlockers() throws {
        let initiatives = try XCTUnwrap(InitiativesPayload.decode(json(["initiatives": [[
            "issue_id": "p-1", "identifier": "P-1", "title": "Gift cards", "state": "Waiting on sub-tickets",
            "url": "https://linear.app/acme/issue/P-1", "group": "active",
            "sub_tickets": [
                ["identifier": "S-1", "title": "Store balances", "state": "Done", "blocked_by": [], "waits_on": "done"],
                ["identifier": "S-2", "title": "Redeem at checkout", "state": "Todo", "blocked_by": ["S-1", "X-9"], "waits_on": "blocker", "waiting_for": ["X-9"]],
            ],
        ]]]))).initiatives
        let waiting = json(["status": "slot_waiting"])

        let sub = TicketPeek(Reference.Ticket(identifier: "S-2", title: "Redeem at checkout"), sources: PeekSources(initiatives: initiatives, issue: waiting), now: now)
        XCTAssertTrue(sub.isTracked)
        let connected = try XCTUnwrap(sub.connected)
        XCTAssertEqual(connected.parent?.text, "P-1 (Gift cards)")
        XCTAssertEqual(connected.parent?.progress, "1 of 2 done")
        XCTAssertEqual(connected.parent?.children.count, 2)
        XCTAssertEqual(connected.blockedBy, [
            TicketPeek.Row(text: "S-1 (Store balances)", state: "Done"),
            TicketPeek.Row(text: "X-9", state: nil),
        ])
        XCTAssertEqual(sub.references["P-1"], .ticket(Reference.Ticket(identifier: "P-1", title: "Gift cards", state: "Waiting on sub-tickets", url: URL(string: "https://linear.app/acme/issue/P-1"))))
        XCTAssertNil(sub.now?.stage, "nothing says its stage")
        XCTAssertNil(sub.now?.pullRequest)

        let plan = TicketPeek(Reference.Ticket(identifier: "P-1", title: "Gift cards"), sources: PeekSources(initiatives: initiatives, issue: waiting), now: now)
        XCTAssertEqual(plan.connected?.subTickets.map(\.text), ["S-1 (Store balances)", "S-2 (Redeem at checkout)"])
        XCTAssertNil(plan.connected?.parent)

        let alone = TicketPeek(Reference.Ticket(identifier: "Q-1", title: nil), sources: PeekSources(issue: waiting), now: now)
        XCTAssertTrue(alone.isTracked)
        XCTAssertNil(alone.connected, "nothing connected, no section")
    }

    func testARunningTicketsNowComesFromTheTicketPage() throws {
        let state = json([
            "generated_at": "2026-10-07T14:20:00Z",
            "running": [[
                "issue_identifier": "T-1", "title": "Checkout total", "state": "In Progress", "repo_key": "web-shop",
                "url": "https://linear.app/acme/issue/T-1", "started_at": "2026-10-07T14:10:00Z", "last_event_at": "2026-10-07T14:18:00Z",
                "pull_request_url": "https://github.com/acme/web-shop/pull/12",
            ]],
        ])
        let peek = TicketPeek(Reference.Ticket(identifier: "T-1", title: nil), sources: PeekSources(state: state), now: now)
        XCTAssertTrue(peek.isTracked)
        XCTAssertEqual(peek.head.title, "Checkout total")
        XCTAssertEqual(peek.head.repoKey, "web-shop")
        XCTAssertNil(peek.head.badge, "the reference says no stage")
        XCTAssertEqual(peek.now, TicketPeek.Now(stage: "In Progress · for 10 min", waitingOn: "Working", pullRequest: "PR #12"))
        XCTAssertEqual(peek.references["PR #12"], .missing(url: nil))
        XCTAssertEqual(peek.linearURL, URL(string: "https://linear.app/acme/issue/T-1"))
    }

    func testAMentionCarriesAShortNameOnlyWhenItReadsAsOne() {
        XCTAssertEqual(TicketPeek.mention("TP-1", "Fix it"), "TP-1 (Fix it)")
        XCTAssertEqual(TicketPeek.mention("TP-1", nil), "TP-1")
        XCTAssertEqual(TicketPeek.mention("TP-1", "  "), "TP-1")
        XCTAssertEqual(TicketPeek.mention("TP-1", "Fix (again)"), "TP-1", "brackets would end the short name early")
        XCTAssertEqual(TicketPeek.mention("TP-1", String(repeating: "a", count: 81)), "TP-1")
        XCTAssertNil(TicketPeek.pullRequestNumber(URL(string: "https://github.com/acme/web-shop/issues/12")!))
        XCTAssertEqual(TicketPeek.pullRequestNumber(URL(string: "https://github.com/acme/web-shop/pull/12")!), 12)
        XCTAssertEqual(TicketPeek.status(stateType: "triage"), .idle)
    }

    // MARK: - Fixtures

    private let now = TicketPage.date("2026-10-07T14:20:00Z")!

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/inbox-decision/api/v1/\(name).json")
    }

    private func payload() throws -> InboxPayload {
        try XCTUnwrap(InboxPayload.decode(Data(contentsOf: fixture("inbox"))))
    }

    private func decision() throws -> InboxItem {
        try XCTUnwrap(try payload().items.first { $0.identifier == "TP-892" })
    }

    private func sources(issue: String?) throws -> PeekSources {
        PeekSources(
            inbox: try payload().items,
            state: try Data(contentsOf: fixture("state")),
            issue: try issue.map { try Data(contentsOf: fixture($0)) }
        )
    }

    private func entry(_ key: String, in item: InboxItem) throws -> PeekEntry {
        let reference = try XCTUnwrap(item.references[key], "\(key) is in TP-892's references")
        return PeekEntry(key: key, kind: Mentions.isPullRequest(key) ? .pullRequest : .ticket, reference: reference)
    }

    private func ticket(_ key: String, in item: InboxItem) throws -> Reference.Ticket {
        guard case let .ticket(ticket)? = item.references[key] else { throw XCTSkip("\(key) is not a ticket") }
        return ticket
    }

    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
}
