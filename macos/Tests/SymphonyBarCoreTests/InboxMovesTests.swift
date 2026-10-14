import Foundation
import XCTest
@testable import SymphonyBarCore

final class InboxMovesTests: XCTestCase {
    private let linear = URL(string: "https://linear.app/acme/issue/X-1")!
    private let prURL = URL(string: "https://github.com/acme/x/pull/1")!

    // MARK: - The toolbar

    func testAPlanOffersApproveFirstSendDecisionsOnceAPickChangesAndReworkUnderMore() throws {
        let plan = try shipped("SHOP-330")

        let toolbar = InboxToolbar.toolbar(for: plan)
        XCTAssertEqual(toolbar.buttons.map(\.command.title), ["Approve Plan…", "Send Decisions", "Open in Linear"])
        XCTAssertEqual(toolbar.buttons.map(\.enabled), [true, false, true])
        XCTAssertEqual(toolbar.overflow, [.move(.sendToRework), .move(.restart)])
        XCTAssertEqual(toolbar.defaultCommand, .move(.approvePlan))

        // Picking the recommended option again changes nothing; another option turns Send Decisions on.
        XCTAssertFalse(InboxToolbar.toolbar(for: plan, picks: DecisionPicks(picks: [0: 0])).buttons[1].enabled)
        XCTAssertTrue(InboxToolbar.toolbar(for: plan, picks: DecisionPicks(picks: [0: 1])).buttons[1].enabled)

        // A plan whose brief has no decisions has no Send Decisions.
        var bare = plan
        bare.review.brief = .raw("## Review brief")
        XCTAssertEqual(InboxToolbar.toolbar(for: bare).buttons.map(\.command.title), ["Approve Plan…", "Open in Linear"])
    }

    func testAPullRequestOffersApproveAndMergeUnlessACheckIsRed() throws {
        let pr = try shipped("BIL-206")
        let shippedPR = try XCTUnwrap(pr.review.pullRequest?.url)
        let toolbar = InboxToolbar.toolbar(for: pr)
        XCTAssertEqual(toolbar.buttons.map(\.command.title), ["Approve and Merge…", "Send to Rework…", "Open PR", "Open in Linear"])
        XCTAssertEqual(toolbar.defaultCommand, .move(.approveAndMerge))
        XCTAssertEqual(toolbar.overflow, [.move(.restart)])

        var red = pr
        red.review.pullRequest?.ci = .failed
        XCTAssertEqual(InboxToolbar.toolbar(for: red).buttons.map(\.command), [
            .link(.openPR(shippedPR)), .move(.approveAndMerge), .move(.sendToRework), .link(.openInLinear(try XCTUnwrap(pr.url))),
        ])

        // A red check on a PR Symphony has no link for keeps Approve and Merge… first.
        var unlinked = red
        unlinked.review.pullRequest?.url = nil
        XCTAssertEqual(InboxToolbar.toolbar(for: unlinked).defaultCommand, .move(.approveAndMerge))
    }

    func testAPullRequestWithNoMergeConfirmationToAnswerOffersOnlyItsLinks() throws {
        // Symphony has no move of its own for a PR: without the request to answer, there is nothing to send.
        var bare = item(.pr)
        bare.review.pullRequest = InboxReview.PullRequest(url: prURL, ci: .passed)
        let toolbar = InboxToolbar.toolbar(for: bare)
        XCTAssertEqual(toolbar.buttons.map(\.command), [.link(.openPR(prURL)), .link(.openInLinear(linear))])
        XCTAssertEqual(toolbar.defaultCommand, .link(.openPR(prURL)))
        XCTAssertEqual(toolbar.overflow, [.move(.restart)])

        // Nor without the request comment to reply under, or with a request no option of which confirms.
        var uncommented = try shipped("BIL-206")
        uncommented.review.action?.commentID = nil
        XCTAssertFalse(InboxToolbar.toolbar(for: uncommented).buttons.contains { $0.command == .move(.approveAndMerge) })
        var ordinary = try shipped("BIL-206")
        ordinary.review.action?.confirm = nil
        XCTAssertNil(ordinary.review.action?.confirmingOption)
        XCTAssertEqual(InboxToolbar.toolbar(for: ordinary).buttons.map(\.command.title), ["Open PR", "Open in Linear"])
    }

    func testEveryPlanAndPROffersRestart() throws {
        XCTAssertEqual(InboxToolbar.toolbar(for: try shipped("SHOP-330")).overflow, [.move(.sendToRework), .move(.restart)])

        var pr = try shipped("BIL-206")
        XCTAssertEqual(InboxToolbar.toolbar(for: pr).overflow, [.move(.restart)])
        pr.review.pullRequest?.ci = .failed
        XCTAssertEqual(InboxToolbar.toolbar(for: pr).overflow, [.move(.restart)])
    }

    func testTheOtherKindsKeepTheirLinks() {
        XCTAssertEqual(InboxToolbar.toolbar(for: item(.action)).buttons.map(\.command), [.link(.openInLinear(linear))])
        XCTAssertEqual(InboxToolbar.toolbar(for: item(.clarify)).buttons.map(\.command), [.link(.editInLinear(linear))])
        XCTAssertEqual(InboxToolbar.toolbar(for: item(.blocked)).buttons.map(\.command), [.move(.unblock), .link(.openInLinear(linear))])
        XCTAssertEqual(InboxToolbar.toolbar(for: item(.blocked)).defaultCommand, .move(.unblock))
        XCTAssertEqual(InboxToolbar.toolbar(for: item(.blocked)).overflow, [.move(.restart)])
        XCTAssertNil(InboxToolbar(buttons: [.init(command: .move(.sendDecisions), enabled: false)], overflow: []).defaultCommand)
        XCTAssertEqual(
            InboxMove.allCases.map(\.verb),
            ["Approve Plan", "Send Decisions", "Approve and Merge", "Send to Rework", "Restart", "Send Decision", "Unblock"]
        )
        XCTAssertEqual(InboxMove.approvePlan.id, "approvePlan")
        XCTAssertEqual(InboxMove.decide.id, "decide")
        XCTAssertEqual(InboxMove.unblock.id, "unblock")
    }

    func testAnActionAskingADecisionOffersSendDecisionAndARedirectUnderMore() {
        var action = item(.action)
        XCTAssertEqual(InboxToolbar.toolbar(for: action).buttons.map(\.command), [.link(.openInLinear(linear))])

        // A request with options is answered; steps alone (an older hand-written action) are not.
        action.review.action = InboxReview.Action(steps: [], options: options, commentID: "c-1")
        XCTAssertEqual(InboxToolbar.toolbar(for: action).buttons.map(\.command), [.move(.decide), .link(.openInLinear(linear))])
        XCTAssertEqual(InboxToolbar.toolbar(for: action).defaultCommand, .move(.decide))
        XCTAssertEqual(InboxToolbar.toolbar(for: action).overflow, [.move(.sendToRework)])

        // Without the request comment there is nothing to reply under.
        action.review.action?.commentID = nil
        XCTAssertEqual(InboxToolbar.toolbar(for: action).buttons.map(\.command), [.link(.openInLinear(linear))])
    }

    // MARK: - Deciding

    func testSendDecisionAnswersTheRequestInPlaceAndReworkRedirectsIt() {
        var action = item(.action)
        action.state = "In Progress"
        action.review.action = InboxReview.Action(question: "Close TP-612 as a duplicate?", steps: [], options: options, commentID: "c-1")
        XCTAssertEqual(action.review.action?.decision?.question, "Close TP-612 as a duplicate?")
        XCTAssertEqual(action.review.action?.decision?.options, ["Close as duplicate", "Keep it open"])
        XCTAssertEqual(action.review.action?.decision?.initialPick, 1)

        // The sheet names the pick; an option without an effect says what sending does.
        let sheet = ConsequenceSheet(move: .decide, item: action)
        XCTAssertEqual(sheet.title, "Send \"Keep it open\"?")
        XCTAssertEqual(sheet.happens, "Records your answer on X-1 as a reply to its request and clears the `Needs Decision` label.")
        XCTAssertEqual(sheet.stays, "X-1 stays in In Progress until its next run picks up your answer.")
        XCTAssertFalse(sheet.listsPicks)
        XCTAssertNil(sheet.targetState)
        XCTAssertFalse(sheet.needsReason)
        XCTAssertTrue(sheet.canSend(reason: ""))
        XCTAssertTrue(sheet.isDecision)
        XCTAssertEqual(sheet.picks.map(\.answer), ["Keep it open"])
        XCTAssertEqual(
            sheet.action(),
            .decide("X-1", requestCommentID: "c-1", picks: [.init(question: "Close TP-612 as a duplicate?", answer: "Keep it open")], move: nil)
        )
        XCTAssertEqual(sheet.banner(after: sheet.expectedOutcome).text, "Sent your decision")
        XCTAssertEqual(sheet.expectedOutcome, MoveOutcome(moved: false, toState: nil))
        XCTAssertEqual(sheet.id, "id-X-1:decide")

        // A merge confirmation's Decide moves the ticket to the state its hold names.
        var merge = action
        merge.review.action?.confirm = "Merging"
        let confirm = ConsequenceSheet(move: .decide, item: merge)
        XCTAssertEqual(confirm.targetState, "Merging")
        XCTAssertEqual(confirm.happens, "Records your answer on X-1 as a reply to its request, clears the `Needs Decision` label and moves X-1 to Merging.")
        XCTAssertEqual(confirm.stays, "Nothing merges while a check is red or pending. Your answer stays on the ticket as the recorded decision.")
        XCTAssertEqual(confirm.expectedOutcome, MoveOutcome(moved: true, toState: "Merging"))
        XCTAssertEqual(confirm.banner(after: confirm.expectedOutcome).text, "Moved to Merging")
        XCTAssertEqual(confirm.action(), sheet.action())

        // The redirect is the same answer with the move Rework named.
        let redirect = ConsequenceSheet(move: .sendToRework, item: action)
        XCTAssertTrue(redirect.isDecision)
        XCTAssertTrue(redirect.isDestructive)
        XCTAssertEqual(redirect.happens, "Records your answer on X-1 and moves it to Rework through the guard.")
        XCTAssertNil(redirect.action(reason: " "))
        XCTAssertEqual(
            redirect.action(reason: " Send it back \n"),
            .decide("X-1", requestCommentID: "c-1", picks: [.init(question: "Close TP-612 as a duplicate?", answer: "Send it back")], move: "rework")
        )
        XCTAssertEqual(redirect.banner(after: redirect.expectedOutcome).text, "Moved to Rework")

        // A PR with no request to answer has nothing to reply under either.
        XCTAssertEqual(ConsequenceSheet(move: .sendToRework, item: item(.pr)).isDecision, false)
        // And a request without its comment id answers nothing.
        var unanswerable = action
        unanswerable.review.action?.commentID = nil
        XCTAssertFalse(ConsequenceSheet(move: .decide, item: unanswerable).isDecision)
        XCTAssertNil(ConsequenceSheet(move: .decide, item: unanswerable).action())
    }

    func testSendDecisionNamesThePickedOptionAndItsEffectAndPostsItsLabel() throws {
        let inbox = try XCTUnwrap(InboxPayload.decode(Data(contentsOf: decisionFixture)))
        let item = inbox.items[1]
        let request = try XCTUnwrap(item.review.action?.decision)

        // The recommended option goes when nothing is picked.
        let recommended = ConsequenceSheet(move: .decide, item: item)
        XCTAssertEqual(recommended.title, "Send \"Leave them to TP-891\"?")
        XCTAssertEqual(recommended.happens, "TP-892 goes back to Code Review with a note that TP-891 removes the old instructions.")

        // Pressing 2 picks the second option, and the sheet and the answer follow it.
        var picks = DecisionPicks()
        picks.picks[0] = try XCTUnwrap(item.optionIndex(forKey: "2"))
        let sheet = ConsequenceSheet(move: .decide, item: item, picks: picks)
        XCTAssertEqual(sheet.title, "Send \"Update them in TP-892 now\"?")
        XCTAssertEqual(sheet.happens, "The next run removes Final verification from the old instructions, and TP-892 goes back to Code Review.")
        XCTAssertEqual(sheet.stays, "TP-892 stays in Rework until its next run picks up your answer.")
        XCTAssertEqual(
            sheet.action(),
            .decide("TP-892", requestCommentID: "c-892-request", picks: [.init(question: request.question, answer: "Update them in TP-892 now")], move: nil)
        )

        // A request with no state, and nothing picked or recommended, falls back to plain words.
        var unpicked = item
        unpicked.state = nil
        for index in unpicked.review.action!.options.indices { unpicked.review.action!.options[index].recommended = false }
        XCTAssertNil(unpicked.review.action?.pickedOption(DecisionPicks()))
        let plain = ConsequenceSheet(move: .decide, item: unpicked)
        XCTAssertEqual(plain.title, "Send your decision on TP-892?")
        XCTAssertEqual(plain.stays, "TP-892 stays in its phase until its next run picks up your answer.")
    }

    // MARK: - The write-in (N11)

    private let ownWords = "Leave them to TP-891, and add a note on TP-891 so its run removes the mention too."

    func testTheWriteInIsTheLastCardOfARequestTheInboxAnswersAndPlansHaveNone() throws {
        let inbox = try XCTUnwrap(InboxPayload.decode(Data(contentsOf: decisionFixture)))
        let action = try XCTUnwrap(inbox.items[1].review.action)

        let cards = OptionCard.cards(for: action, writeIn: true)
        XCTAssertEqual(cards.map(\.label), ["Leave them to TP-891", "Update them in TP-892 now", "Wait for TP-891 to land first", "Answer in my own words…"])
        XCTAssertEqual(cards.map(\.isWriteIn), [false, false, false, true])
        XCTAssertEqual(cards.map(\.count), [4, 4, 4, 4])
        let writeIn = try XCTUnwrap(cards.last)
        XCTAssertEqual(writeIn.number, 4)
        XCTAssertEqual(writeIn.index, action.writeInIndex)
        XCTAssertEqual(writeIn.effect, "Tell the agent what to do instead.")
        XCTAssertEqual(writeIn.accessibilityLabel(selected: true), "Option 4 of 4, Answer in my own words…, selected. Tell the agent what to do instead.")

        // A request the Inbox can't answer, and one with no options, has none.
        XCTAssertEqual(OptionCard.cards(for: action).map(\.isWriteIn), [false, false, false])
        XCTAssertEqual(OptionCard.cards(for: InboxReview.Action(steps: ["Add the key."], options: []), writeIn: true), [])

        // A plan's decisions (C16) take no write-in: the plan's Change move already takes free text.
        let decision = InboxReview.Decision(question: "Where?", options: ["A", "B"], recommendation: "A is closer.", recommended: 0)
        XCTAssertEqual(OptionCard.cards(for: decision).map(\.isWriteIn), [false, false])
    }

    func testPickingTheWriteInTurnsSendDecisionOffUntilItHoldsWords() throws {
        let inbox = try XCTUnwrap(InboxPayload.decode(Data(contentsOf: decisionFixture)))
        let item = inbox.items[1]
        let action = try XCTUnwrap(item.review.action)
        XCTAssertTrue(InboxToolbar.toolbar(for: item).buttons[0].enabled)

        // Pressing 4 picks the write-in: no option is picked, and there is nothing to send yet.
        var picks = DecisionPicks()
        picks.picks[0] = try XCTUnwrap(item.optionIndex(forKey: "4"))
        XCTAssertTrue(action.isWriteIn(picks))
        XCTAssertEqual(action.pickedIndex(picks), 3)
        XCTAssertNil(action.pickedOption(picks))
        XCTAssertNil(action.answer(picks))
        let blank = InboxToolbar.toolbar(for: item, picks: picks)
        XCTAssertEqual(blank.buttons.map(\.command.title), ["Send Decision…", "Open in Linear"])
        XCTAssertEqual(blank.buttons.map(\.enabled), [false, true])
        XCTAssertNil(blank.defaultCommand)

        let blankSheet = ConsequenceSheet(move: .decide, item: item, picks: picks)
        XCTAssertEqual(blankSheet.title, "Send your answer?")
        XCTAssertTrue(blankSheet.isWriteIn)
        XCTAssertNil(blankSheet.quote)
        XCTAssertFalse(blankSheet.canSend(reason: ""))
        XCTAssertNil(blankSheet.action())

        // Spaces and new lines alone are still blank.
        picks.writeIn = "  \n "
        XCTAssertFalse(InboxToolbar.toolbar(for: item, picks: picks).buttons[0].enabled)

        // Words turn it on; the sheet quotes them and sends them as the answer.
        picks.writeIn = "\n\(ownWords)  "
        XCTAssertTrue(InboxToolbar.toolbar(for: item, picks: picks).buttons[0].enabled)
        XCTAssertEqual(InboxToolbar.toolbar(for: item, picks: picks).defaultCommand, .move(.decide))
        let sheet = ConsequenceSheet(move: .decide, item: item, picks: picks)
        XCTAssertEqual(sheet.title, "Send your answer?")
        XCTAssertEqual(sheet.quote, ownWords)
        XCTAssertEqual(sheet.happens, "Records your answer on TP-892 as a reply to its request and clears the `Needs Decision` label.")
        XCTAssertEqual(sheet.stays, "TP-892 stays in Rework until its next run picks up your answer.")
        XCTAssertFalse(sheet.listsPicks)
        XCTAssertNil(sheet.targetState)
        XCTAssertTrue(sheet.canSend(reason: ""))
        XCTAssertEqual(
            sheet.action(),
            .decide("TP-892", requestCommentID: "c-892-request", picks: [.init(question: try XCTUnwrap(action.question), answer: ownWords)], move: nil)
        )
        XCTAssertEqual(sheet.banner(after: sheet.expectedOutcome).text, "Sent your decision")

        // Picking an option again leaves the words aside: the option goes, and the sheet names it.
        picks.picks[0] = 1
        XCTAssertFalse(action.isWriteIn(picks))
        XCTAssertEqual(ConsequenceSheet(move: .decide, item: item, picks: picks).title, "Send \"Update them in TP-892 now\"?")
        XCTAssertNil(ConsequenceSheet(move: .decide, item: item, picks: picks).quote)

        // On a confirmation, words that pick none of its options ask for a change: the ticket goes to In Progress.
        var confirmation = item
        confirmation.review.action?.confirm = "Merging"
        picks.picks[0] = action.writeInIndex
        let change = ConsequenceSheet(move: .decide, item: confirmation, picks: picks)
        XCTAssertEqual(change.targetState, "In Progress")
        XCTAssertEqual(
            change.happens,
            "Records your answer on TP-892 as a reply to its request, clears the `Needs Decision` label and moves TP-892 to In Progress, where its next run takes up your answer."
        )
        XCTAssertEqual(change.stays, "Nothing merges, and the pull request stays open.")
        XCTAssertEqual(change.action(), sheet.action())
    }

    func testTheWriteInKeepsItsWordsWhileTheDirectorLooksAtAnotherItem() throws {
        let inbox = try XCTUnwrap(InboxPayload.decode(Data(contentsOf: decisionFixture)))
        let plan = inbox.items[0]
        let request = inbox.items[1]
        let action = try XCTUnwrap(request.review.action)

        var store = InboxPicks()
        XCTAssertEqual(store[request.id], DecisionPicks())
        store.pick(action.writeInIndex, decision: 0, itemID: request.id)
        store.writeIn(ownWords, itemID: request.id)

        // Selecting the plan and picking there leaves the request's words and pick as they were.
        store.pick(1, decision: 0, itemID: plan.id)
        XCTAssertEqual(store[plan.id], DecisionPicks(picks: [0: 1]))
        XCTAssertEqual(store[request.id], DecisionPicks(picks: [0: 3], writeIn: ownWords))
        XCTAssertEqual(ConsequenceSheet(move: .decide, item: request, picks: store[request.id]).quote, ownWords)

        // Writing before picking keeps the words too; sending forgets them.
        store.writeIn("Draft", itemID: "other")
        XCTAssertEqual(store["other"].writeIn, "Draft")
        store.clear(request.id)
        XCTAssertEqual(store[request.id], DecisionPicks())
        XCTAssertEqual(store[plan.id], DecisionPicks(picks: [0: 1]))
    }

    func testSendingTheWriteInPostsItsWordsAsTheAnswer() throws {
        let inbox = try XCTUnwrap(InboxPayload.decode(Data(contentsOf: decisionFixture)))
        let item = inbox.items[1]
        let picks = DecisionPicks(picks: [0: 3], writeIn: ownWords)
        let action = try XCTUnwrap(ConsequenceSheet(move: .decide, item: item, picks: picks).action())

        let request = ControlAPI.request(action, base: URL(string: "http://127.0.0.1:4000")!, token: "t")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:4000/api/v1/control/decide")
        XCTAssertEqual(request.httpMethod, "POST")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? NSDictionary)
        XCTAssertEqual(
            sent,
            [
                "issue_identifier": "TP-892",
                "request_comment_id": "c-892-request",
                "picks": [["question": try XCTUnwrap(item.review.action?.question), "answer": ownWords]],
            ] as NSDictionary
        )
    }

    private var decisionFixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/inbox-decision/api/v1/inbox.json")
    }

    private var options: [InboxReview.Action.Option] {
        [.init(label: "Close as duplicate", effect: "TP-612 moves to Done.", recommended: false), .init(label: "Keep it open", effect: nil, recommended: true)]
    }

    // MARK: - Picks

    func testPicksStartAtTheRecommendationAndListEachAnswer() throws {
        let decisions = try shipped("SHOP-330").review.decisions
        let picks = DecisionPicks(picks: [1: 1])
        XCTAssertEqual(picks.pick(0, in: decisions[0]), 0)
        XCTAssertEqual(picks.pick(1, in: decisions[1]), 1)
        XCTAssertTrue(picks.changed(decisions))
        XCTAssertEqual(picks.answers(decisions), [
            .init(question: "Where are gift cards bought?", answer: "In the checkout"),
            .init(question: "Which currency does a card hold?", answer: "The buyer's currency"),
        ])

        // A decision with no recommendation and no pick is left out; any pick of it is a change.
        let open = InboxReview.Decision(question: "Who pays?", options: ["A", "B"], recommendation: nil, recommended: nil)
        XCTAssertEqual(DecisionPicks().answers([open]), [])
        XCTAssertFalse(DecisionPicks().changed([open]))
        XCTAssertTrue(DecisionPicks(picks: [0: 0]).changed([open]))
        XCTAssertEqual(DecisionPicks(picks: [0: 5]).answers([open]), [])
    }

    // MARK: - The consequence sheets

    func testApprovePlanNamesTheMoveAndTheSubTicketsItPromotes() throws {
        let plan = try shipped("SHOP-330")
        let sheet = ConsequenceSheet(move: .approvePlan, item: plan)
        XCTAssertEqual(sheet.title, "Approve the plan of SHOP-330?")
        XCTAssertEqual(sheet.happens, "Moves SHOP-330 to Waiting on sub-tickets and promotes its 7 sub-tickets to Todo; SHOP-331 starts first.")
        XCTAssertEqual(sheet.stays, "The plan stays as written. To change it, send decisions or comment on it in Linear instead.")
        XCTAssertEqual(sheet.verb, "Approve Plan")
        XCTAssertFalse(sheet.isDestructive)
        XCTAssertEqual(sheet.action(), .approvePlan("SHOP-330"))
        XCTAssertEqual(sheet.banner(after: sheet.expectedOutcome), InboxBanner(itemID: "i-330", identifier: "SHOP-330", text: "Moved to Waiting on sub-tickets", undo: true))
        XCTAssertEqual(sheet.id, "i-330:approvePlan")

        XCTAssertTrue(ConsequenceSheet(move: .approvePlan, item: plan, picks: DecisionPicks(picks: [0: 1])).stays.contains("your changed picks are not sent"))

        var one = plan
        one.review.subTickets = [.init(identifier: "SHOP-331", title: nil, state: "Backlog", url: nil), .init(identifier: "SHOP-332", title: nil, state: "Todo", url: nil)]
        XCTAssertEqual(ConsequenceSheet(move: .approvePlan, item: one).happens, "Moves SHOP-330 to Waiting on sub-tickets and promotes its sub-ticket to Todo; SHOP-331 starts first.")
        one.review.subTickets = []
        XCTAssertEqual(ConsequenceSheet(move: .approvePlan, item: one).happens, "Moves SHOP-330 to Waiting on sub-tickets.")
    }

    func testSendDecisionsPostsThePicksAndLeavesThePlanInPlanReview() throws {
        var plan = try shipped("SHOP-330")
        let picks = DecisionPicks(picks: [0: 1])
        let sheet = ConsequenceSheet(move: .sendDecisions, item: plan, picks: picks)
        XCTAssertEqual(sheet.title, "Send your decisions on SHOP-330?")
        XCTAssertEqual(sheet.happens, "Posts one comment on SHOP-330 with your picks, and Symphony revises the plan from it.")
        XCTAssertNil(sheet.targetState)
        XCTAssertEqual(sheet.picks.map(\.answer), ["On a separate page", "The store's currency"])
        XCTAssertTrue(sheet.listsPicks)
        XCTAssertEqual(sheet.action(), .decisions("SHOP-330", picks: sheet.picks))
        XCTAssertEqual(sheet.banner(after: sheet.expectedOutcome), InboxBanner(itemID: "i-330", identifier: "SHOP-330", text: "Sent your decisions", undo: false))
        XCTAssertEqual(sheet.stays, "The plan stays in Plan Review and isn't approved: it comes back to the Inbox once Symphony has revised it.")

        // The workflow's Plan Review state under another name; the sheet names the state the plan is in.
        plan.state = "Plan review (design)"
        XCTAssertNil(ConsequenceSheet(move: .sendDecisions, item: plan, picks: picks).targetState)
        XCTAssertTrue(ConsequenceSheet(move: .sendDecisions, item: plan, picks: picks).stays.hasPrefix("The plan stays in Plan review (design) and"))
        plan.state = nil
        XCTAssertTrue(ConsequenceSheet(move: .sendDecisions, item: plan, picks: picks).stays.hasPrefix("The plan stays in Plan Review and"))
    }

    func testTheBannerFollowsSymphonysAnswerNotTheSheetsGuess() throws {
        let sheet = ConsequenceSheet(move: .sendDecisions, item: try shipped("SHOP-330"), picks: DecisionPicks(picks: [0: 1]))
        XCTAssertNil(sheet.targetState)
        let moved = sheet.banner(after: MoveOutcome(moved: true, toState: "Rework"))
        XCTAssertEqual(moved, InboxBanner(itemID: "i-330", identifier: "SHOP-330", text: "Moved to Rework", undo: true))
        XCTAssertEqual(sheet.banner(after: MoveOutcome(moved: false, toState: "Plan Review")).text, "Sent your decisions")

        let decisions = ControlAction.decisions("SHOP-330", picks: [])
        let answer = Data(#"{"move":"decisions","moved":true,"to_state":"Rework","undo_window_ms":10000}"#.utf8)
        XCTAssertEqual(ControlAPI.result(decisions, statusCode: 200, data: answer), .moved(MoveOutcome(moved: true, toState: "Rework")))
        XCTAssertEqual(ControlAPI.result(decisions, statusCode: 200, data: Data()), .done)
        XCTAssertEqual(ControlAPI.result(.undo("SHOP-330"), statusCode: 200, data: answer), .done)
        XCTAssertNil(ControlResult.done.moveOutcome)
    }

    func testApproveAndMergeAnswersTheMergeConfirmationAndSaysGitHubMergesOnceChecksPass() throws {
        let pr = try shipped("BIL-206")
        let sheet = ConsequenceSheet(move: .approveAndMerge, item: pr)
        XCTAssertEqual(sheet.title, "Move BIL-206 to Merging?")
        XCTAssertEqual(
            sheet.happens,
            "Records your answer on BIL-206 as a reply to its merge request, clears the `Needs Decision` label and moves BIL-206 to Merging: Symphony turns on auto-merge, and GitHub merges the pull request once checks pass."
        )
        XCTAssertEqual(sheet.stays, "Nothing merges while a check is red or pending, and the diff stays on GitHub.")
        XCTAssertTrue(sheet.isDecision)
        XCTAssertFalse(sheet.isDestructive)
        XCTAssertFalse(sheet.needsReason)
        XCTAssertEqual(sheet.targetState, "Merging")
        XCTAssertEqual(sheet.requestCommentID, "c-206-merge")
        // It picks the option that moves the ticket to the state the hold carries, so Symphony continues it there.
        let pick = ControlAction.DecisionPick(question: "Merge BIL-206 (Prorate plan changes mid-cycle) into its base branch?", answer: "Merge")
        XCTAssertEqual(sheet.picks, [pick])
        XCTAssertEqual(sheet.action(), .decide("BIL-206", requestCommentID: "c-206-merge", picks: [pick], move: nil))
        XCTAssertEqual(sheet.banner(after: sheet.expectedOutcome), InboxBanner(itemID: "i-206", identifier: "BIL-206", text: "Moved to Merging", undo: true))

        // The confirmation's option is found by what it does, not by where it sits or whether it is recommended.
        var reordered = pr
        let flipped = (pr.review.action?.options ?? []).reversed().map { option in
            var option = option
            option.recommended.toggle()
            return option
        }
        reordered.review.action?.options = flipped
        XCTAssertEqual(ConsequenceSheet(move: .approveAndMerge, item: reordered).picks.map(\.answer), ["Merge"])

        // The hold names the state, so a repo that calls it something else is moved there.
        var renamed = pr
        renamed.review.action?.confirm = "Ready to Merge"
        renamed.review.action?.options[0].effect = "the ticket moves to Ready to Merge and Symphony merges its pull request"
        XCTAssertEqual(ConsequenceSheet(move: .approveAndMerge, item: renamed).title, "Move BIL-206 to Ready to Merge?")
        XCTAssertEqual(ConsequenceSheet(move: .approveAndMerge, item: renamed).targetState, "Ready to Merge")

        // With nothing to answer, nothing is sent.
        XCTAssertNil(ConsequenceSheet(move: .approveAndMerge, item: item(.pr)).action())
        var ordinary = pr
        ordinary.review.action?.confirm = nil
        XCTAssertNil(ConsequenceSheet(move: .approveAndMerge, item: ordinary).action())
    }

    func testAPullRequestsSendToReworkRedirectsItsMergeConfirmation() throws {
        let sheet = ConsequenceSheet(move: .sendToRework, item: try shipped("BIL-206"))
        XCTAssertTrue(sheet.isDecision)
        XCTAssertTrue(sheet.isDestructive)
        XCTAssertEqual(sheet.happens, "Records your answer on BIL-206 and moves it to Rework through the guard.")
        XCTAssertNil(sheet.action(reason: " "))
        XCTAssertEqual(
            sheet.action(reason: " Totals are off \n"),
            .decide(
                "BIL-206",
                requestCommentID: "c-206-merge",
                picks: [.init(question: "Merge BIL-206 (Prorate plan changes mid-cycle) into its base branch?", answer: "Totals are off")],
                move: "rework"
            )
        )
        XCTAssertEqual(sheet.banner(after: sheet.expectedOutcome).text, "Moved to Rework")
    }

    func testSendToReworkNeedsAReasonAndIsDestructive() throws {
        var pr = item(.pr)
        pr.identifier = "BIL-206"
        let sheet = ConsequenceSheet(move: .sendToRework, item: pr)
        XCTAssertEqual(sheet.title, "Send BIL-206 to Rework?")
        XCTAssertEqual(sheet.happens, "Posts your reason on BIL-206 and moves it to Rework: Symphony continues on the same pull request. Restart instead closes the pull request and starts over from main.")
        XCTAssertTrue(sheet.isDestructive)
        XCTAssertTrue(sheet.needsReason)
        XCTAssertEqual(sheet.reasonPrompt, "Why does BIL-206 go back?")
        XCTAssertFalse(sheet.canSend(reason: "  \n"))
        XCTAssertNil(sheet.action(reason: " "))
        XCTAssertNil(sheet.action())
        XCTAssertTrue(sheet.canSend(reason: "Totals are off"))
        XCTAssertEqual(sheet.action(reason: " Totals are off \n"), .rework("BIL-206", reason: "Totals are off"))

        let plan = ConsequenceSheet(move: .sendToRework, item: try shipped("SHOP-330"))
        XCTAssertTrue(plan.happens.contains("cancels the plan's sub-tickets still in Backlog and plans again"))
    }

    func testRestartResetsFromMainAndSaysWhatItDoes() throws {
        let pr = try shipped("BIL-206")
        let sheet = ConsequenceSheet(move: .restart, item: pr)
        XCTAssertEqual(sheet.title, "Restart BIL-206 from main?")
        XCTAssertEqual(
            sheet.happens,
            "Closes BIL-206's open pull request, removes its workspace so the next run branches fresh from main, supersedes the workpad, and moves BIL-206 to In Progress."
        )
        XCTAssertEqual(sheet.stays, "The issue and its comments stay, and the previous attempt stays in the workpad under a Superseded heading.")
        XCTAssertEqual(sheet.targetState, "In Progress")
        XCTAssertEqual(sheet.verb, "Restart")
        XCTAssertTrue(sheet.isDestructive)
        XCTAssertTrue(sheet.needsReason)
        XCTAssertEqual(sheet.reasonPrompt, "Why does BIL-206 start over?")
        XCTAssertNil(sheet.action())
        XCTAssertEqual(sheet.action(reason: " The approach is wrong \n"), .restart("BIL-206", reason: "The approach is wrong"))
        XCTAssertEqual(sheet.banner(after: sheet.expectedOutcome).text, "Moved to In Progress")
        // A restart can't be undone, so its banner must not offer Undo.
        XCTAssertEqual(sheet.banner(after: sheet.expectedOutcome).undo, false)
        XCTAssertEqual(sheet.id, "i-206:restart")

        // Rework keeps its own prompt, and is destructive too.
        let rework = ConsequenceSheet(move: .sendToRework, item: pr)
        XCTAssertEqual(rework.reasonPrompt, "Why does BIL-206 go back?")
        XCTAssertTrue(rework.isDestructive)
    }

    func testUnblockClearsTheHoldAndTheTicketContinuesInPlace() throws {
        let sheet = ConsequenceSheet(move: .unblock, item: try shipped("SHOP-360"))
        XCTAssertEqual(sheet.title, "Unblock SHOP-360?")
        XCTAssertEqual(sheet.happens, "Clears the hold on SHOP-360 and notes it on the ticket; SHOP-360 continues from where it stopped.")
        XCTAssertEqual(sheet.stays, "The ticket keeps its state. Nothing else changes in Linear.")
        XCTAssertEqual(sheet.verb, "Unblock")
        XCTAssertFalse(sheet.isDestructive)
        XCTAssertFalse(sheet.needsReason)
        XCTAssertTrue(sheet.canSend(reason: ""))
        XCTAssertEqual(sheet.action(), .unblock("SHOP-360"))
        XCTAssertNil(sheet.targetState)
        XCTAssertEqual(sheet.id, "i-360:unblock")

        // Unblock moves nothing, so its banner says what it did rather than a state it went to, and offers no Undo.
        XCTAssertEqual(sheet.expectedOutcome, MoveOutcome(moved: false, toState: nil))
        XCTAssertEqual(sheet.banner(after: sheet.expectedOutcome), InboxBanner(itemID: "i-360", identifier: "SHOP-360", text: "Hold cleared", undo: false))
        XCTAssertEqual(sheet.banner(after: MoveOutcome(moved: false, toState: "In Progress")).text, "Hold cleared")
    }

    func testBannersSayWhatHappenedAndOfferUndoOnlyAfterAMove() {
        let moved = InboxBanner(itemID: "i-1", identifier: "BIL-206", text: "Moved to Merging", undo: true)
        XCTAssertEqual(moved.announcement, "BIL-206: Moved to Merging. Undo is available for 10 seconds.")
        XCTAssertEqual(InboxBanner.duration, 10)
        let undone = InboxBanner.undone(itemID: "i-1", identifier: "BIL-206")
        XCTAssertEqual(undone.announcement, "BIL-206: Moved back")
        XCTAssertEqual(undone.style, .info)
        XCTAssertFalse(undone.undo)
        XCTAssertEqual(InboxBanner.failed(itemID: "i-1", identifier: "BIL-206", message: "No").style, .error)
        XCTAssertNotEqual(moved, undone)
    }

    // MARK: - The list after a move

    func testAfterApprovingThePlanTheSelectionMovesToThePullRequest() throws {
        XCTAssertEqual(InboxList(items: try payload().items).neighbor(of: "i-330")?.identifier, "BIL-206")
    }

    // MARK: - Requests

    func testEachMoveSendsItsRequest() throws {
        let base = URL(string: "http://127.0.0.1:4000")!
        let picks = [ControlAction.DecisionPick(question: "Where?", answer: "B")]
        let cases: [(ControlAction, String, [String: Any])] = [
            (.approvePlan("SHOP-330"), "approve_plan", ["issue_identifier": "SHOP-330"]),
            (.rework("BIL-206", reason: "No"), "rework", ["issue_identifier": "BIL-206", "reason": "No"]),
            (.restart("BIL-206", reason: "No"), "restart", ["issue_identifier": "BIL-206", "reason": "No"]),
            (.decisions("SHOP-330", picks: picks), "decisions", ["issue_identifier": "SHOP-330", "picks": [["question": "Where?", "answer": "B"]]]),
            (.backlog("BIL-206", note: "Later"), "backlog", ["issue_identifier": "BIL-206", "note": "Later"]),
            (.backlog("BIL-206", note: nil), "backlog", ["issue_identifier": "BIL-206"]),
            (
                .decide("NOTE-90", requestCommentID: "c-1", picks: picks, move: nil),
                "decide",
                ["issue_identifier": "NOTE-90", "request_comment_id": "c-1", "picks": [["question": "Where?", "answer": "B"]]]
            ),
            (
                .decide("NOTE-90", requestCommentID: "c-1", picks: picks, move: "rework"),
                "decide",
                ["issue_identifier": "NOTE-90", "request_comment_id": "c-1", "picks": [["question": "Where?", "answer": "B"]], "move": "rework"]
            ),
            (.unblock("SHOP-360"), "unblock", ["issue_identifier": "SHOP-360"]),
            (.undo("BIL-206"), "undo", ["issue_identifier": "BIL-206"]),
        ]
        for (action, path, body) in cases {
            let request = ControlAPI.request(action, base: base, token: "t")
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:4000/api/v1/control/\(path)")
            XCTAssertEqual(request.httpMethod, "POST")
            let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? NSDictionary)
            XCTAssertEqual(sent, body as NSDictionary, path)
            XCTAssertNotNil(action.moveIdentifier)
        }
        XCTAssertNil(ControlAction.pause.moveIdentifier)
    }

    func testARefusedMoveSaysWhy() {
        let body = Data(#"{"error":{"code":"move_not_allowed","message":"BIL-206 is not waiting on a decision"}}"#.utf8)
        XCTAssertEqual(
            ControlAPI.result(.decide("BIL-206", requestCommentID: "c-206-merge", picks: [], move: nil), statusCode: 409, data: body),
            .failed("Couldn't send the decision on BIL-206: BIL-206 is not waiting on a decision (HTTP 409)")
        )
        let prefixes = [
            ControlAction.approvePlan("X"), .rework("X", reason: "r"), .restart("X", reason: "r"), .decisions("X", picks: []),
            .backlog("X", note: nil), .decide("X", requestCommentID: "c-1", picks: [], move: nil), .unblock("X"), .undo("X"),
        ].map { ControlAPI.result($0, statusCode: 500, data: Data()) }
        XCTAssertEqual(prefixes, [
            .failed("Couldn't approve the plan of X: HTTP 500"),
            .failed("Couldn't send X to Rework: HTTP 500"),
            .failed("Couldn't restart X: HTTP 500"),
            .failed("Couldn't send the decisions on X: HTTP 500"),
            .failed("Couldn't move X to Backlog: HTTP 500"),
            .failed("Couldn't send the decision on X: HTTP 500"),
            .failed("Couldn't unblock X: HTTP 500"),
            .failed("Couldn't undo the move on X: HTTP 500"),
        ])
    }

    func testUnblockReadsSymphonysAnswerAndItsRefusal() {
        let answer = Data(#"{"move":"unblock","issue_id":"i-360","issue_identifier":"SHOP-360","from_state":"In Progress","to_state":"In Progress","moved":false,"commented":true,"undo_window_ms":null}"#.utf8)
        XCTAssertEqual(ControlAPI.result(.unblock("SHOP-360"), statusCode: 200, data: answer), .moved(MoveOutcome(moved: false, toState: "In Progress")))

        let refused = Data(#"{"error":{"code":"move_not_allowed","message":"SHOP-360 is not waiting on an access hold"}}"#.utf8)
        XCTAssertEqual(
            ControlAPI.result(.unblock("SHOP-360"), statusCode: 409, data: refused),
            .failed("Couldn't unblock SHOP-360: SHOP-360 is not waiting on an access hold (HTTP 409)")
        )
    }

    /// The walkthrough's requests, as QA mode records them in `api-requests.jsonl`.
    func testTheInboxFixtureAnswersEachMoveAndLogsItsRequest() async throws {
        let root = uniqueTemporaryDirectory("inbox-moves")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = APIFixtures(directory: fixture().deletingLastPathComponent().deletingLastPathComponent(), requestLog: root.appendingPathComponent("api-requests.jsonl"))
        let plan = try shipped("SHOP-330")
        let pr = try shipped("BIL-206")
        let blocked = try shipped("SHOP-360")

        let actions = [
            try XCTUnwrap(ConsequenceSheet(move: .sendDecisions, item: plan, picks: DecisionPicks(picks: [0: 1])).action()),
            try XCTUnwrap(ConsequenceSheet(move: .approvePlan, item: plan).action()),
            .undo("SHOP-330"),
            try XCTUnwrap(ConsequenceSheet(move: .approveAndMerge, item: pr).action()),
            try XCTUnwrap(ConsequenceSheet(move: .sendToRework, item: pr).action(reason: "The proration rounds the wrong way")),
            try XCTUnwrap(ConsequenceSheet(move: .restart, item: pr).action(reason: "The proration rounds the wrong way")),
            .backlog("BIL-206", note: nil),
            try XCTUnwrap(ConsequenceSheet(move: .unblock, item: blocked).action()),
        ]
        for action in actions {
            let (data, response) = fixtures.answer(ControlAPI.request(action, base: APIFixtures.baseURL, token: APIFixtures.token))
            XCTAssertEqual(response.statusCode, 200)
            let answer = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(answer["issue_identifier"] as? String, action.moveIdentifier)
        }

        let lines = try String(contentsOf: fixtures.requestLog, encoding: .utf8).split(separator: "\n")
        let entries = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(entries.map { $0["path"] as? String }, [
            "/api/v1/control/decisions", "/api/v1/control/approve_plan", "/api/v1/control/undo", "/api/v1/control/decide",
            "/api/v1/control/decide", "/api/v1/control/restart", "/api/v1/control/backlog", "/api/v1/control/unblock",
        ])
        let decisions = try XCTUnwrap(entries[0]["body"] as? [String: Any])
        XCTAssertEqual(decisions["picks"] as? [[String: String]], [
            ["question": "Where are gift cards bought?", "answer": "On a separate page"],
            ["question": "Which currency does a card hold?", "answer": "The store's currency"],
        ])
        let question = "Merge BIL-206 (Prorate plan changes mid-cycle) into its base branch?"
        XCTAssertEqual(entries[3]["body"] as? NSDictionary, [
            "issue_identifier": "BIL-206", "request_comment_id": "c-206-merge", "picks": [["question": question, "answer": "Merge"]],
        ] as NSDictionary)
        XCTAssertEqual(entries[4]["body"] as? NSDictionary, [
            "issue_identifier": "BIL-206", "request_comment_id": "c-206-merge",
            "picks": [["question": question, "answer": "The proration rounds the wrong way"]], "move": "rework",
        ] as NSDictionary)
        XCTAssertEqual(entries[5]["body"] as? [String: String], ["issue_identifier": "BIL-206", "reason": "The proration rounds the wrong way"])
    }

    // MARK: - The notification

    func testAGreenPullRequestsNotificationOffersApproveAndMerge() throws {
        let data = try Data(contentsOf: fixture().appendingPathComponent("state.json"))
        guard case let .state(snapshot) = SymphonyState.poll(data: data, statusCode: 200) else { return XCTFail("the state doesn't read") }
        XCTAssertEqual(snapshot.waitingOnYou.filter(\.checksGreen).map(\.identifier), ["BIL-206"])

        let notices = snapshot.waitingOnYou.compactMap(InboxNotifier.notice)
        XCTAssertEqual(notices.filter(\.offersApproveAndMerge).map(\.title), ["BIL-206 waits on you"])
        XCTAssertEqual(InboxNotice.approveAndMergeTitle, "Approve and Merge…")

        // Only a pull request offers it.
        let plan = StateSnapshot.WaitingTicket(issueID: "i-1", identifier: "X-1", kind: .plan, checksGreen: true)
        XCTAssertEqual(InboxNotifier.notice(plan)?.offersApproveAndMerge, false)
    }

    // MARK: - Helpers

    private func item(_ kind: InboxItem.Kind) -> InboxItem {
        InboxItem(id: "id-X-1", identifier: "X-1", kind: kind, ask: "Ask", url: linear)
    }

    private func fixture() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/inbox/api/v1", isDirectory: true)
    }

    private func payload() throws -> InboxPayload {
        try XCTUnwrap(InboxPayload.decode(Data(contentsOf: fixture().appendingPathComponent("inbox.json"))))
    }

    private func shipped(_ identifier: String) throws -> InboxItem {
        try XCTUnwrap(payload().items.first { $0.identifier == identifier })
    }
}
