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
        XCTAssertEqual(toolbar.overflow, [.move(.sendToRework)])
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
        let toolbar = InboxToolbar.toolbar(for: pr)
        XCTAssertEqual(toolbar.buttons.map(\.command.title), ["Approve and Merge…", "Send to Rework…", "Open PR", "Open in Linear"])
        XCTAssertEqual(toolbar.defaultCommand, .move(.approveAndMerge))
        XCTAssertEqual(toolbar.overflow, [])

        var red = item(.pr)
        red.review.pullRequest = InboxReview.PullRequest(url: prURL, ci: .failed)
        XCTAssertEqual(InboxToolbar.toolbar(for: red).buttons.map(\.command), [
            .link(.openPR(prURL)), .move(.approveAndMerge), .move(.sendToRework), .link(.openInLinear(linear)),
        ])

        // A red check on a PR Symphony has no link for keeps Approve and Merge… first.
        var unlinked = red
        unlinked.review.pullRequest?.url = nil
        XCTAssertEqual(InboxToolbar.toolbar(for: unlinked).defaultCommand, .move(.approveAndMerge))
    }

    func testAFinalVerificationOffersSignOffAndTheOtherKindsKeepTheirLinks() {
        XCTAssertEqual(InboxToolbar.toolbar(for: item(.finalVerification)).buttons.map(\.command), [.move(.signOff), .link(.openInLinear(linear))])
        XCTAssertEqual(InboxToolbar.toolbar(for: item(.action)).buttons.map(\.command), [.link(.openInLinear(linear))])
        XCTAssertEqual(InboxToolbar.toolbar(for: item(.clarify)).buttons.map(\.command), [.link(.editInLinear(linear))])
        XCTAssertNil(InboxToolbar(buttons: [.init(command: .move(.sendDecisions), enabled: false)], overflow: []).defaultCommand)
        XCTAssertEqual(InboxMove.allCases.map(\.verb), ["Approve Plan", "Send Decisions", "Approve and Merge", "Send to Rework", "Sign Off"])
        XCTAssertEqual(InboxMove.approvePlan.id, "approvePlan")
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
        XCTAssertEqual(sheet.banner, InboxBanner(itemID: "i-330", identifier: "SHOP-330", text: "Moved to Waiting on sub-tickets", undo: true))
        XCTAssertEqual(sheet.id, "i-330:approvePlan")

        XCTAssertTrue(ConsequenceSheet(move: .approvePlan, item: plan, picks: DecisionPicks(picks: [0: 1])).stays.contains("your changed picks are not sent"))

        var one = plan
        one.review.subTickets = [.init(identifier: "SHOP-331", title: nil, state: "Backlog", url: nil), .init(identifier: "SHOP-332", title: nil, state: "Todo", url: nil)]
        XCTAssertEqual(ConsequenceSheet(move: .approvePlan, item: one).happens, "Moves SHOP-330 to Waiting on sub-tickets and promotes its sub-ticket to Todo; SHOP-331 starts first.")
        one.review.subTickets = []
        XCTAssertEqual(ConsequenceSheet(move: .approvePlan, item: one).happens, "Moves SHOP-330 to Waiting on sub-tickets.")
    }

    func testSendDecisionsPostsThePicksAndMovesAPlanInHumanReviewToInReview() throws {
        var plan = try shipped("SHOP-330")
        let picks = DecisionPicks(picks: [0: 1])
        let sheet = ConsequenceSheet(move: .sendDecisions, item: plan, picks: picks)
        XCTAssertEqual(sheet.title, "Send your decisions on SHOP-330?")
        XCTAssertEqual(sheet.happens, "Posts one comment on SHOP-330 with your picks, and Symphony revises the plan from it.")
        XCTAssertNil(sheet.targetState)
        XCTAssertEqual(sheet.picks.map(\.answer), ["On a separate page", "The store's currency"])
        XCTAssertEqual(sheet.action(), .decisions("SHOP-330", picks: sheet.picks))
        XCTAssertEqual(sheet.banner, InboxBanner(itemID: "i-330", identifier: "SHOP-330", text: "Sent your decisions", undo: false))

        plan.state = "Human Review"
        let humanReview = ConsequenceSheet(move: .sendDecisions, item: plan, picks: picks)
        XCTAssertEqual(humanReview.targetState, "In Review")
        XCTAssertTrue(humanReview.happens.hasPrefix("Moves SHOP-330 from Human Review to In Review, then posts one comment"))
        XCTAssertEqual(humanReview.banner.text, "Moved to In Review")
        XCTAssertTrue(humanReview.banner.undo)
    }

    func testApproveAndMergeSaysGitHubMergesOnceChecksPass() throws {
        let sheet = ConsequenceSheet(move: .approveAndMerge, item: try shipped("BIL-206"))
        XCTAssertEqual(sheet.title, "Move BIL-206 to Merging?")
        XCTAssertEqual(sheet.happens, "Symphony turns on auto-merge, and GitHub merges the pull request once checks pass.")
        XCTAssertEqual(sheet.action(), .approvePR("BIL-206"))
        XCTAssertEqual(sheet.banner.text, "Moved to Merging")
    }

    func testSendToReworkNeedsAReasonAndIsDestructive() throws {
        let sheet = ConsequenceSheet(move: .sendToRework, item: try shipped("BIL-206"))
        XCTAssertEqual(sheet.title, "Send BIL-206 to Rework?")
        XCTAssertEqual(sheet.happens, "Posts your reason on BIL-206 and moves it to Rework: Symphony closes the PR and starts over.")
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

    func testSignOffMovesTheFinalVerificationToDone() throws {
        let sheet = ConsequenceSheet(move: .signOff, item: try shipped("BIL-213"))
        XCTAssertEqual(sheet.title, "Sign off BIL-213?")
        XCTAssertEqual(sheet.happens, "Moves BIL-213 to Done; the parent's close-out run follows.")
        XCTAssertEqual(sheet.action(), .signOff("BIL-213"))
        XCTAssertTrue(sheet.canSend(reason: ""))
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
            (.approvePR("BIL-206"), "approve_pr", ["issue_identifier": "BIL-206"]),
            (.rework("BIL-206", reason: "No"), "rework", ["issue_identifier": "BIL-206", "reason": "No"]),
            (.decisions("SHOP-330", picks: picks), "decisions", ["issue_identifier": "SHOP-330", "picks": [["question": "Where?", "answer": "B"]]]),
            (.signOff("BIL-213"), "sign_off", ["issue_identifier": "BIL-213"]),
            (.backlog("BIL-206", note: "Later"), "backlog", ["issue_identifier": "BIL-206", "note": "Later"]),
            (.backlog("BIL-206", note: nil), "backlog", ["issue_identifier": "BIL-206"]),
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
        let body = Data(#"{"error":{"code":"move_not_allowed","message":"BIL-206 is Merging; the Director answers it only from In Review or Human Review"}}"#.utf8)
        XCTAssertEqual(
            ControlAPI.result(.approvePR("BIL-206"), statusCode: 409, data: body),
            .failed("Couldn't move BIL-206 to Merging: BIL-206 is Merging; the Director answers it only from In Review or Human Review (HTTP 409)")
        )
        let prefixes = [
            ControlAction.approvePlan("X"), .rework("X", reason: "r"), .decisions("X", picks: []), .signOff("X"), .backlog("X", note: nil), .undo("X"),
        ].map { ControlAPI.result($0, statusCode: 500, data: Data()) }
        XCTAssertEqual(prefixes, [
            .failed("Couldn't approve the plan of X: HTTP 500"),
            .failed("Couldn't send X to Rework: HTTP 500"),
            .failed("Couldn't send the decisions on X: HTTP 500"),
            .failed("Couldn't sign off X: HTTP 500"),
            .failed("Couldn't move X to Backlog: HTTP 500"),
            .failed("Couldn't undo the move on X: HTTP 500"),
        ])
    }

    /// The walkthrough's requests, as QA mode records them in `api-requests.jsonl`.
    func testTheInboxFixtureAnswersEachMoveAndLogsItsRequest() async throws {
        let root = uniqueTemporaryDirectory("inbox-moves")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = APIFixtures(directory: fixture().deletingLastPathComponent().deletingLastPathComponent(), requestLog: root.appendingPathComponent("api-requests.jsonl"))
        let plan = try shipped("SHOP-330")
        let pr = try shipped("BIL-206")

        let actions = [
            try XCTUnwrap(ConsequenceSheet(move: .sendDecisions, item: plan, picks: DecisionPicks(picks: [0: 1])).action()),
            try XCTUnwrap(ConsequenceSheet(move: .approvePlan, item: plan).action()),
            .undo("SHOP-330"),
            try XCTUnwrap(ConsequenceSheet(move: .approveAndMerge, item: pr).action()),
            try XCTUnwrap(ConsequenceSheet(move: .sendToRework, item: pr).action(reason: "The proration rounds the wrong way")),
            .signOff("BIL-213"),
            .backlog("BIL-206", note: nil),
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
            "/api/v1/control/decisions", "/api/v1/control/approve_plan", "/api/v1/control/undo", "/api/v1/control/approve_pr",
            "/api/v1/control/rework", "/api/v1/control/sign_off", "/api/v1/control/backlog",
        ])
        let decisions = try XCTUnwrap(entries[0]["body"] as? [String: Any])
        XCTAssertEqual(decisions["picks"] as? [[String: String]], [
            ["question": "Where are gift cards bought?", "answer": "On a separate page"],
            ["question": "Which currency does a card hold?", "answer": "The store's currency"],
        ])
        XCTAssertEqual(entries[4]["body"] as? [String: String], ["issue_identifier": "BIL-206", "reason": "The proration rounds the wrong way"])
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
