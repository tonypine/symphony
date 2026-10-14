import Foundation
import XCTest
@testable import SymphonyBarCore

final class InboxTests: XCTestCase {
    // MARK: - The shipped fixtures

    func testTheInboxFixtureHasOneItemOfEachKindWithItsReview() throws {
        let inbox = try payload("inbox")
        XCTAssertEqual(inbox.items.map(\.kind), [.plan, .pr, .action, .clarify, .blocked])

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
        XCTAssertFalse(pr.hasRedCheck)

        let action = try XCTUnwrap(inbox.items[2].review.action)
        XCTAssertEqual(action.steps.count, 4)
        XCTAssertEqual(action.timeLine, "About 10 min")
        XCTAssertEqual(action.unblocks, "the Release workflow on main")
        XCTAssertEqual(action.copyText?.split(separator: "\n").first, "1. Export the Developer ID certificate from Keychain Access as a .p12 file.")

        let clarify = try XCTUnwrap(inbox.items[3].review.clarify)
        XCTAssertTrue(clarify.held)
        XCTAssertEqual(clarify.scoreLine, "3 of 10, passes at 6")
        XCTAssertEqual(clarify.roundLine, "Round 1 of 2")
        XCTAssertEqual(clarify.questions.count, 2)

        let blocked = try XCTUnwrap(inbox.items[4].review.blocked)
        XCTAssertEqual(blocked.reason, "The run reported a block")
        XCTAssertEqual(blocked.nextLine, "Clears when the block is resolved; a person clears an access hold.")
        XCTAssertEqual(inbox.items[4].state, "In Progress")
        XCTAssertEqual(InboxReview.Blocked(reason: "Needs a key").nextLine, "Symphony lifts the hold when what it waits on clears.")
    }

    func testTheDecisionFixtureResolvesEveryMentionAndWhereTheTicketSits() throws {
        let inbox = try payload("inbox-decision")
        XCTAssertEqual(inbox.items.map(\.identifier), ["TP-923", "TP-892"])

        let decision = inbox.items[1]
        XCTAssertEqual(Set(decision.references.keys), ["TP-891", "TP-892", "TP-880", "TP-893", "#448"])
        let action = try XCTUnwrap(decision.review.action)
        let text = [action.title, action.question, action.why, action.ifUnanswered, action.unblocks].compactMap { $0 }.joined(separator: " ")
        for mention in decision.references.keys {
            XCTAssertTrue(text.contains(mention), "\(mention) isn't in the request's text")
        }

        guard case let .ticket(ticket)? = decision.references["TP-891"] else { return XCTFail("TP-891 isn't a ticket") }
        XCTAssertEqual(ticket.title, "Remove the retired review states")
        XCTAssertEqual(ticket.state, "In Progress")
        XCTAssertEqual(ticket.parent?.identifier, "TP-870")
        XCTAssertEqual(ticket.pullRequest, .init(number: 446, url: URL(string: "https://github.com/tonypine/symphony/pull/446"), checks: .pending))
        XCTAssertNil(ticket.waitingOn)
        guard case let .ticket(blocked)? = decision.references["TP-893"] else { return XCTFail("TP-893 isn't a ticket") }
        XCTAssertEqual(blocked.waitingOn, "a blocker: TP-892")

        guard case let .pullRequest(pr)? = decision.references["#448"] else { return XCTFail("#448 isn't a pull request") }
        XCTAssertEqual(pr.number, 448)
        XCTAssertEqual(pr.reviewState, .changesRequested)
        XCTAssertEqual(pr.reviewRounds, 2)
        XCTAssertEqual([pr.files, pr.additions, pr.deletions], [14, 120, 610])
        XCTAssertEqual(pr.checks, .passed)
        XCTAssertEqual(pr.ticket, "TP-892")
        XCTAssertEqual(decision.references["#448"]?.url?.absoluteString, "https://github.com/tonypine/symphony/pull/448")

        let context = try XCTUnwrap(decision.context)
        XCTAssertEqual(context.parent?.identifier, "TP-870")
        XCTAssertEqual(context.parent?.done, 4)
        XCTAssertEqual(context.parent?.total, 7)
        XCTAssertEqual(context.parent?.children.count, 7)
        XCTAssertEqual(context.pullRequest?.number, 448)
        XCTAssertEqual(context.pullRequest?.sentBack, 2)
        XCTAssertEqual(context.pullRequest?.checks, .passed)
        XCTAssertEqual(context.blocks.map(\.identifier), ["TP-893"])
        XCTAssertEqual(context.related.map(\.identifier), ["TP-891"])
        XCTAssertEqual(context.related.first?.state, "In Progress")
        XCTAssertTrue(context.blockedBy.isEmpty)
        XCTAssertEqual(context.earlierDecisions.count, 1)
        XCTAssertEqual(context.earlierDecisions.first?.at, ISO8601DateFormatter().date(from: "2026-10-07T05:48:00Z"))
        XCTAssertEqual(context.earlierDecisions.first?.answer, "Remove it with the rest")

        let plan = inbox.items[0]
        guard case let .parsed(brief)? = plan.review.brief else { return XCTFail("the plan's brief didn't parse") }
        XCTAssertTrue(brief.whatToReview.first?.text.contains("TP-947") ?? false)
        guard case let .ticket(tp947)? = plan.references["TP-947"] else { return XCTFail("TP-947 isn't a ticket") }
        XCTAssertEqual(tp947.waitingOn, "you")
        XCTAssertEqual(plan.context, TicketContext())
    }

    func testAnItemFromAnOlderSymphonyOrWithAnUnknownReferenceStillDecodes() throws {
        let json = """
        {"items": [
          {"issue_id": "i-1", "identifier": "TP-1", "kind": "action", "ask": "Decide"},
          {"issue_id": "i-2", "identifier": "TP-2", "kind": "action", "ask": "Decide",
           "references": {
             "TP-3": {"kind": "epic", "url": "https://linear.app/x/issue/TP-3"},
             "TP-4": {"kind": "missing", "url": null},
             "TP-5": {"kind": "ticket"},
             "#6": {"kind": "pull_request", "number": 6, "review_state": "reverted"},
             "TP-7": {"kind": "ticket", "identifier": "TP-7", "parent": {"title": "No id"}, "pull_request": {"url": "u"}}
           },
           "context": {"parent": {"title": "No id"}, "pull_request": {"url": "u"}, "related": [{"title": "No id"}],
                       "earlier_decisions": [{"at": "yesterday", "title": "T", "answer": "A"}]}}
        ]}
        """
        let inbox = try XCTUnwrap(InboxPayload.decode(Data(json.utf8)))

        XCTAssertEqual(inbox.items[0].references, [:])
        XCTAssertNil(inbox.items[0].context)

        let references = inbox.items[1].references
        XCTAssertEqual(references["TP-3"], .missing(url: URL(string: "https://linear.app/x/issue/TP-3")))
        XCTAssertEqual(references["TP-4"], .missing(url: nil))
        XCTAssertEqual(references["TP-5"], .missing(url: nil))
        guard case let .pullRequest(pr)? = references["#6"] else { return XCTFail("#6 isn't a pull request") }
        XCTAssertEqual(pr.reviewState, .open)
        XCTAssertEqual(pr.reviewRounds, 0)
        XCTAssertNil(pr.checks)
        guard case let .ticket(ticket)? = references["TP-7"] else { return XCTFail("TP-7 isn't a ticket") }
        XCTAssertNil(ticket.parent)
        XCTAssertNil(ticket.pullRequest)

        let context = try XCTUnwrap(inbox.items[1].context)
        XCTAssertNil(context.parent)
        XCTAssertNil(context.pullRequest)
        XCTAssertTrue(context.related.isEmpty)
        XCTAssertNil(context.earlierDecisions.first?.at)
        XCTAssertEqual(context.earlierDecisions.first?.answer, "A")
    }

    func testTheBadgeTheMenuTheTileAndTheInboxAgreeOnTheCount() throws {
        for name in ["inbox", "inbox-empty", "inbox-decision"] {
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
            "doc.text.magnifyingglass", "arrow.triangle.pull", "hand.raised", "questionmark.bubble", "hand.raised.slash",
        ])
        XCTAssertEqual(menu.tickets.first?.issueID, "i-330")
        XCTAssertEqual(menu.tickets.first?.repoKey, "web-shop")
        XCTAssertEqual(StatusMenu.waitingLine(menu.tickets[3]), "SHOP-341 · Clarify · Answer the quality gate's questions · 10m")
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
            item("W-3", .blocked, repo: "web", seconds: 900),
        ]
        let all = InboxList(items: items)
        XCTAssertEqual(all.groups.map(\.title), ["Plans", "Pull requests", "Actions", "Clarify", "Blocked"])
        XCTAssertEqual(all.groups.map(\.id), ["plan", "pr", "action", "clarify", "blocked"])
        XCTAssertEqual(all.groups[1].items.map(\.identifier), ["A-2", "A-1", "A-3"])
        XCTAssertEqual(all.ordered.map(\.identifier), ["W-1", "A-2", "A-1", "A-3", "D-1", "W-2", "W-3"])
        XCTAssertNil(all.hiddenLine)
        XCTAssertEqual(all.totalCount, 7)

        let api = InboxList(items: items, scope: .repo("api"))
        XCTAssertEqual(api.groups.map(\.kind), [.pr])
        XCTAssertEqual(api.hiddenCount, 4)
        XCTAssertEqual(api.hiddenLine, "4 more in other repos")
        XCTAssertEqual(api.totalCount, 7)
        XCTAssertEqual(InboxList(items: items, scope: .repo("docs")).hiddenLine, "6 more in other repos")
        XCTAssertEqual(InboxList(items: [items[0], items[5]], scope: .repo("api")).hiddenLine, "1 more in another repo")

        let none = InboxList(items: items, scope: .repo("ios"))
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(none.hiddenLine, "7 more in other repos")
    }

    func testTheDecisionFixtureReadsQuestionFirstWithItsStoryAndThreeOptionCards() throws {
        let inbox = try payload("inbox-decision")
        let list = InboxList(items: inbox.items)
        XCTAssertEqual(list.groups.map(\.title), ["Plans", "Decisions"])
        XCTAssertEqual(list.groups.map(\.id), ["plan", "decision"])

        let decision = inbox.items[1]
        XCTAssertTrue(decision.isDecision)
        XCTAssertTrue(decision.answerable)
        XCTAssertEqual(decision.kindWord, "Decision")
        XCTAssertEqual(decision.ask, "Update the old workflow's instructions now, or leave them to TP-891?")
        XCTAssertEqual(decision.accessibilityLabel, "TP-892, Retire two old review steps, decision, 1 hour")

        let action = try XCTUnwrap(decision.review.action)
        XCTAssertEqual(action.whyParagraphs.count, 2)
        XCTAssertTrue(action.whyParagraphs[0].hasPrefix("Code Review sent #448 back twice."))
        XCTAssertTrue(action.whyParagraphs[1].hasPrefix("TP-880 already removed the Supervisor check."))
        XCTAssertNotNil(action.ifUnanswered)
        XCTAssertEqual(action.keyHint, "Press 1–3 to pick · ⌘↩ to send")

        let cards = OptionCard.cards(for: action)
        XCTAssertEqual(cards.map(\.label), ["Leave them to TP-891", "Update them in TP-892 now", "Wait for TP-891 to land first"])
        XCTAssertEqual(cards.map(\.recommended), [true, false, false])
        XCTAssertEqual(cards.map(\.reason), [action.recommendationReason, nil, nil])
        XCTAssertEqual(cards.map(\.count), [3, 3, 3])
        XCTAssertEqual(action.pickedIndex(DecisionPicks()), 0)
        XCTAssertEqual(
            cards[1].accessibilityLabel(selected: false),
            "Option 2 of 3, Update them in TP-892 now. The next run removes Final verification from the old instructions, and TP-892 goes back to Code Review. Cost: Another review round, about half a day. Risk: TP-891 then has to work around the change and may conflict with it."
        )
        XCTAssertEqual(
            cards[0].accessibilityLabel(selected: true),
            "Option 1 of 3, Leave them to TP-891, recommended, selected. TP-892 goes back to Code Review with a note that TP-891 removes the old instructions. Good: TP-892 can merge today, and TP-893 can start. Risk: The old instructions stay until TP-891 lands, about two days. Why we recommend it: TP-891 removes these instructions this week, so updating them twice adds work without changing what you see."
        )
    }

    func testDecisionsAndOlderActionsAreListedApart() {
        var decision = item("D-1", .action, seconds: 10)
        decision.review.action = InboxReview.Action(steps: [], options: [.init(label: "Yes", effect: nil, recommended: true)])
        var steps = item("S-1", .action, seconds: 20)
        steps.review.action = InboxReview.Action(steps: ["Add the key."], options: [])
        let list = InboxList(items: [steps, decision, item("P-1", .plan)])
        XCTAssertEqual(list.groups.map(\.title), ["Plans", "Decisions", "Actions"])
        XCTAssertEqual(list.ordered.map(\.identifier), ["P-1", "D-1", "S-1"])
        XCTAssertEqual([decision.kindWord, steps.kindWord], ["Decision", "Action"])
        XCTAssertFalse(steps.isDecision)
        // A plan's decisions don't make it a decision item.
        XCTAssertFalse(item("P-2", .plan).isDecision)
        XCTAssertEqual(InboxList(items: [steps]).groups.map(\.id), ["action"])
    }

    func testTheStoryKeepsTwoParagraphsSplitOnBlankLines() {
        func paragraphs(_ why: String?) -> [String] { InboxReview.Action(why: why, steps: [], options: []).whyParagraphs }
        XCTAssertEqual(paragraphs("One.\n  \nTwo,\nstill two.\n\n\nThree."), ["One.", "Two,\nstill two."])
        XCTAssertEqual(paragraphs("  Just one.  "), ["Just one."])
        XCTAssertEqual(paragraphs(nil), [])
        XCTAssertEqual(paragraphs("\n \n"), [])
    }

    func testNumberKeysPickTheOptionWithThatNumber() {
        func action(_ count: Int) -> InboxReview.Action {
            InboxReview.Action(steps: [], options: (1...max(count, 1)).prefix(count).map { .init(label: "O\($0)", effect: nil, recommended: false) }, commentID: "c-1")
        }
        XCTAssertNil(action(0).keyHint)
        XCTAssertEqual(action(1).keyHint, "Press 1 to pick · ⌘↩ to send")
        XCTAssertEqual(action(12).keyHint, "Press 1–9 to pick · ⌘↩ to send")
        XCTAssertEqual(action(3).optionIndex(forKey: "2"), 1)
        XCTAssertEqual(action(3).optionIndex(forKey: "3"), 2)
        XCTAssertNil(action(3).optionIndex(forKey: "4"))
        XCTAssertNil(action(3).optionIndex(forKey: "0"))
        XCTAssertNil(action(3).optionIndex(forKey: "a"))
        XCTAssertNil(action(0).optionIndex(forKey: "1"))

        var request = item("D-1", .action)
        request.review.action = action(3)
        XCTAssertEqual(request.optionIndex(forKey: "1"), 0)
        // Only a request the Inbox answers takes the keys.
        request.review.action?.commentID = nil
        XCTAssertNil(request.optionIndex(forKey: "1"))
        var pr = item("P-1", .pr)
        pr.review.action = action(3)
        XCTAssertNil(pr.optionIndex(forKey: "1"))
    }

    func testAnOptionCardReadsItsNumberLabelAndStateThenItsEffectAndTags() {
        let plain = OptionCard(number: 2, count: 2, label: "Keep it open")
        XCTAssertEqual(plain.accessibilityLabel(selected: false), "Option 2 of 2, Keep it open.")
        XCTAssertEqual(plain.id, 2)
        XCTAssertEqual(plain.index, 1)
        let full = OptionCard(
            number: 1,
            count: 2,
            label: "Close it!",
            effect: "  ",
            recommended: true,
            tradeoffs: [.init(kind: .cost, text: "Half a day")],
            reason: "It is a duplicate?"
        )
        XCTAssertEqual(full.accessibilityLabel(selected: true), "Option 1 of 2, Close it!, recommended, selected. Cost: Half a day. Why we recommend it: It is a duplicate?")

        XCTAssertEqual([InboxReview.Action.Tradeoff.Kind.good, .cost, .risk].map(\.word), ["Good", "Cost", "Risk"])
        XCTAssertEqual([InboxReview.Action.Tradeoff.Kind.good, .cost, .risk].map(\.symbol), ["checkmark.circle", "exclamationmark.triangle", "xmark.circle"])
        XCTAssertEqual([InboxReview.Action.Tradeoff.Kind.good, .cost, .risk].map(\.status), [.done, .you, .problem])
    }

    func testAPlanDecisionDrawsTheSameCardsWithTheBriefsRecommendationAsTheReason() {
        let decision = InboxReview.Decision(question: "Where?", options: ["A", "B"], recommendation: "B, because it is quicker.", recommended: 1)
        let cards = OptionCard.cards(for: decision)
        XCTAssertEqual(cards.map(\.label), ["A", "B"])
        XCTAssertEqual(cards.map(\.effect), [nil, nil])
        XCTAssertEqual(cards.map(\.recommended), [false, true])
        XCTAssertEqual(cards.map(\.reason), [nil, "B, because it is quicker."])
        XCTAssertEqual(cards[1].accessibilityLabel(selected: true), "Option 2 of 2, B, recommended, selected. Why we recommend it: B, because it is quicker.")
        XCTAssertTrue(OptionCard.cards(for: InboxReview.Decision(question: "Q", options: [], recommendation: nil, recommended: nil)).isEmpty)
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
        XCTAssertEqual(item("BIL-9", .pr, title: nil, seconds: nil).accessibilityLabel, "BIL-9, pull request")
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

        var blocked = item("X-1", .blocked)
        blocked.url = linear
        XCTAssertEqual(InboxAction.actions(for: blocked), [.openInLinear(linear)])
        XCTAssertEqual(InboxAction.actions(for: item("X-2", .blocked)), [])

        XCTAssertEqual([InboxAction.openInLinear(linear), .openPR(prURL), .copySteps(""), .editInLinear(linear)].map(\.title), [
            "Open in Linear", "Open PR", "Copy Steps", "Edit in Linear",
        ])
    }

    func testReadsADecisionsWhatWaitsTradeOffsAndWhyRecommendedAndAnOlderOneWithout() throws {
        let json = """
        {"items": [
          {"identifier": "TP-892", "kind": "action", "review": {"comment_id": "c-1", "question": "Leave the old text to TP-891?",
            "if_unanswered": "TP-892 stays in Rework.", "recommendation_reason": "It is one line of text.",
            "options": [
              {"label": "Leave it to TP-891", "effect": "TP-892 goes back to Code Review.", "recommended": true,
               "tradeoffs": [{"kind": "good", "text": "TP-892 can merge today."}, {"kind": "cost", "text": "The old text stays a while."},
                             {"kind": "nice", "text": "An unknown kind is skipped."}, {"kind": "risk"}]},
              {"label": "Remove it now", "tradeoffs": [{"kind": "risk", "text": "It clashes with PR #454."}]}
            ]}},
          {"identifier": "NOTE-90", "kind": "action", "review": {"est_minutes": 10, "options": [{"label": "Add it", "recommended": true}, {"label": "Drop it"}]}}
        ]}
        """
        let inbox = try XCTUnwrap(InboxPayload.decode(Data(json.utf8)))

        let action = try XCTUnwrap(inbox.items[0].review.action)
        XCTAssertEqual(action.ifUnanswered, "TP-892 stays in Rework.")
        XCTAssertEqual(action.recommendationReason, "It is one line of text.")
        XCTAssertEqual(action.options[0].tradeoffs, [
            .init(kind: .good, text: "TP-892 can merge today."),
            .init(kind: .cost, text: "The old text stays a while."),
        ])
        XCTAssertEqual(action.options[1].tradeoffs, [.init(kind: .risk, text: "It clashes with PR #454.")])
        XCTAssertNil(action.estMinutes)

        let older = try XCTUnwrap(inbox.items[1].review.action)
        XCTAssertNil(older.ifUnanswered)
        XCTAssertNil(older.recommendationReason)
        XCTAssertEqual(older.options.map(\.tradeoffs), [[], []])
        XCTAssertEqual(older.estMinutes, 10)
    }

    func testReadsAnItemWithMissingFieldsAndSkipsOneWithoutAKind() throws {
        let json = """
        {"items": [
          {"issue_id": "i-1", "identifier": "X-1", "kind": "pr", "review": {"brief": {"format": "raw", "markdown": "Just read it."},
            "pull_request": {"ci": "failed", "qa": {"verdict": "blocked"}}}},
          {"issue_id": "i-2", "kind": "pr"},
          {"identifier": "X-3", "kind": "audit"},
          {"identifier": "X-4", "kind": "clarify", "review": {"held": false, "found": "Empty."}},
          {"identifier": "X-5", "kind": "plan", "review": {"brief": {"format": "parsed", "decisions": [{"question": "Q?", "options": ["A"], "recommended": 3}, {"options": []}],
            "moves": [{"move": "approve"}], "what_to_review": [{"links": [{"url": "https://example.com/a"}]}]}, "sub_tickets": [{"title": "no id"}]}},
          {"identifier": "X-6", "kind": "action", "review": {"comment_id": "c-6", "options": [{"label": "Merge", "recommended": true}], "confirm": "Merging"}}
        ]}
        """
        let inbox = try XCTUnwrap(InboxPayload.decode(Data(json.utf8)))
        XCTAssertEqual(inbox.items.map(\.identifier), ["X-1", "i-2", "X-4", "X-5", "X-6"])
        XCTAssertEqual(inbox.items[4].review.action?.confirm, "Merging")
        XCTAssertEqual(inbox.items[4].review.action?.commentID, "c-6")
        XCTAssertEqual(inbox.items[0].review.brief, .raw("Just read it."))
        XCTAssertEqual(inbox.items[0].review.pullRequest?.ci, .failed)
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

    func testWaitsForSymphonysFirstInboxReadBeforeRememberingWhatIsThere() {
        var notifier = InboxNotifier()
        let already = [waiting("P-1", .plan), waiting("R-1", .pr)]
        // Symphony has just started: its Inbox is empty until it reads Linear, so nothing is remembered yet.
        XCTAssertEqual(notifier.notices(waiting: [], problems: [], preferences: .init(), inboxRead: false), [])
        XCTAssertNil(notifier.remembered)

        // Its first read lists what already waited: remembered, not notified.
        XCTAssertEqual(notifier.notices(waiting: already, problems: [], preferences: .init(), inboxRead: true), [])
        XCTAssertEqual(notifier.remembered, ["plan:id-P-1", "pr:id-R-1"])
        XCTAssertEqual(notifier.notices(waiting: already, problems: [], preferences: .init()), [])

        // Once remembered, a Symphony restart's empty Inbox doesn't make them new again.
        XCTAssertEqual(notifier.notices(waiting: [], problems: [], preferences: .init(), inboxRead: false), [])
        XCTAssertEqual(notifier.notices(waiting: already, problems: [], preferences: .init()), [])
    }

    func testReadsWhetherSymphonyHasReadTheInbox() throws {
        let unread = Data(#"{"counts": {"running": 0}, "waiting_on_you": [], "inbox_read": false}"#.utf8)
        guard case .state(let snapshot) = SymphonyState.poll(data: unread, statusCode: 200) else { return XCTFail("no state") }
        XCTAssertFalse(snapshot.inboxRead)

        // A Symphony that predates the field has read it as far as the app can tell.
        guard case .state(let older) = SymphonyState.poll(data: Data(#"{"counts": {"running": 0}}"#.utf8), statusCode: 200) else { return XCTFail("no state") }
        XCTAssertTrue(older.inboxRead)
    }

    func testABlockedTicketReadsAsItsOwnKindEverywhere() {
        let blocked = waiting("SHOP-360", .blocked, headline: "The run reported a block")
        XCTAssertEqual(blocked.kind.inboxKind, .blocked)
        XCTAssertEqual(blocked.kind.symbol, "hand.raised.slash")
        XCTAssertEqual(NoticeKind(blocked.kind)?.settingsTitle, "Blocked tickets to unblock")

        let notice = InboxNotifier.notice(blocked)
        XCTAssertEqual(notice?.key, "blocked:id-SHOP-360")
        XCTAssertEqual(notice?.kind, .blocked)
        XCTAssertEqual(notice?.body, "Blocked: The run reported a block")
        XCTAssertEqual(notice?.offersApproveAndMerge, false)

        XCTAssertEqual(StatusMenu.kindLabel(.blocked), "Blocked")
        XCTAssertEqual(StatusMenu.waitingLine(blocked), "SHOP-360 · Blocked · The run reported a block")
        XCTAssertEqual(InboxItem.Kind.blocked.groupTitle, "Blocked")
        XCTAssertEqual(InboxItem.Kind.blocked.word, "Blocked")
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
