import Foundation
import XCTest
@testable import SymphonyBarCore

final class TicketPageTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// Never used while the state has `generated_at`: ages count from Symphony's clock.
    private let wallClock = Date(timeIntervalSince1970: 0)

    // MARK: - D3 from the shipped fixtures

    func testAWorkingTicketShowsNowTheTimelineItsFactsAndTheLastMessage() throws {
        let page = try fixturePage("SHOP-305")

        XCTAssertEqual(page.title, "Checkout total rounding")
        XCTAssertEqual(page.repoKey, "web-shop")
        XCTAssertEqual(page.url, URL(string: "https://linear.app/acme/issue/SHOP-305"))
        XCTAssertEqual(page.phase, .working(stuck: true))
        XCTAssertEqual(page.badges, [TicketPage.Badge(status: .problem, word: "Needs attention"), TicketPage.Badge(status: .forced, word: "Forced")])
        XCTAssertTrue(page.isRunning)
        XCTAssertTrue(page.isTracked)
        XCTAssertEqual(page.sessionID, "session-SHOP-305")

        // J3 step 2: run 2, its turn, last activity 14 min ago and tokens against the cap.
        let now = try XCTUnwrap(page.now)
        XCTAssertEqual(now.run, "Implementation run 2")
        XCTAssertEqual(now.model, "claude-opus-5-5 · high")
        XCTAssertEqual(now.runningTime, "22 min")
        XCTAssertEqual(now.turn, 7)
        XCTAssertEqual(now.lastActivity, "14 min ago")
        XCTAssertEqual(now.workspace, "/Users/director/symphony-workspaces/web-shop/SHOP-305")
        XCTAssertEqual(now.tokens.value, "1.2M of 2M")
        XCTAssertEqual(try XCTUnwrap(now.tokens.fraction), 0.62, accuracy: 0.001)
        XCTAssertEqual(now.tokens.note, "Per-ticket cap")

        // The timeline: run 1 failed, then run 2 live.
        XCTAssertEqual(page.timeline.map(\.title), ["Implementation run 1", "Implementation run 2"])
        let failed = page.timeline[0]
        XCTAssertEqual(failed.result, .failed)
        XCTAssertEqual(failed.timeText, "13:03")
        XCTAssertEqual(failed.duration, "22 min")
        XCTAssertEqual(failed.tokensText, "860K")
        XCTAssertEqual(failed.detail, "mix test timed out after 20 min: CheckoutTotalTest hangs on the rounding test")
        XCTAssertEqual(failed.accessibilityLabel, "13:03, implementation run 1, failed, 22 minutes")
        XCTAssertEqual(page.timeline[1].result, .current)
        XCTAssertEqual(page.timeline[1].resultWord, "no activity for 14 min")

        XCTAssertEqual(page.facts, [
            TicketPage.Fact(label: "State", value: "In Progress"),
            TicketPage.Fact(label: "Type", value: "Ticket"),
            TicketPage.Fact(label: "Forced", value: "Yes"),
        ])
        XCTAssertEqual(page.lastMessage, "Waiting on npm test")
        XCTAssertEqual(page.apiPath, "api/v1/SHOP-305")
    }

    func testADoneTicketShowsItsPullRequestAndWhenItMerged() throws {
        let page = try fixturePage("SHOP-288")
        let pullRequest = try XCTUnwrap(URL(string: "https://github.com/acme/web-shop/pull/406"))
        let merged = try XCTUnwrap(TicketPage.date("2026-10-07T13:40:00Z"))

        XCTAssertEqual(page.phase, .done(pullRequest: pullRequest, mergedAt: merged))
        XCTAssertEqual(page.phaseSentence, "Done")
        XCTAssertEqual(page.mergedText, "13:40")
        XCTAssertEqual(page.badges, [TicketPage.Badge(status: .done, word: "Done")])
        XCTAssertNil(page.now)
        XCTAssertFalse(page.isRunning)
        // Symphony no longer tracks it, so its transcript is gone.
        XCTAssertFalse(page.isTracked)
        XCTAssertEqual(page.facts, [
            TicketPage.Fact(label: "State", value: "Done"),
            TicketPage.Fact(label: "Type", value: "Ticket"),
            TicketPage.Fact(label: "Pull request", value: "acme/web-shop#406", url: pullRequest),
            TicketPage.Fact(label: "Merged", value: "13:40"),
            TicketPage.Fact(label: "Forced", value: "No"),
        ])
        // The approve move shows once although both audit queries returned it.
        XCTAssertEqual(page.timeline.map(\.title), ["Implementation run 1", "Rework run 1", "Moved to Merging by you", "Merged"])
        XCTAssertEqual(page.timeline.map(\.timeText), ["10:02", "12:10", "13:12", "13:40"])
        XCTAssertEqual(page.timeline[0].accessibilityLabel, "10:02, implementation run 1, done, 29 minutes")
        XCTAssertEqual(page.timeline[3].detail, pullRequest.absoluteString)
    }

    func testAPullRequestInTheInboxShowsWhatItWaitsOnAndTheGatesVerdict() throws {
        let page = try fixturePage("DOCS-40")

        XCTAssertEqual(page.phase, .waiting(on: "you"))
        XCTAssertEqual(page.phaseSentence, "Waiting on you")
        XCTAssertEqual(page.badges, [TicketPage.Badge(status: .you, word: "Waiting on you")])
        XCTAssertEqual(page.facts.first { $0.label == "Pull request" }?.value, "acme/docs#88")
        XCTAssertEqual(page.facts.first { $0.label == "Gate verdict" }?.value, "escalate (shadow)")
        XCTAssertEqual(page.timeline.map(\.title), ["Gate: escalate (shadow)"])
        XCTAssertEqual(page.timeline[0].detail, "The quick start skips the install step the ticket asks for.")
    }

    // MARK: - Stopped by you

    func testAStopReadsStoppedByYouJoinedWithTheBacklogMoveRightAfterIt() throws {
        let audit = ndjson([
            ["event_type": "run_stopped", "issue_identifier": "SHOP-305", "timestamp": "2026-10-07T14:22:00.123456Z", "record_hash": "s1"],
            ["event_type": "director_move", "move": "backlog", "issue_identifier": "SHOP-305", "timestamp": "2026-10-07T14:22:03Z",
             "to_state": "Backlog", "comment": "Hangs on the rounding test; needs a look.", "record_hash": "m1"],
            ["event_type": "run_stopped", "issue_identifier": "SHOP-999", "timestamp": "2026-10-07T14:22:00Z", "record_hash": "s2"],
        ])
        let page = TicketPage(identifier: "SHOP-305", sources: TicketPage.Sources(state: try fixtureData("state"), audit: [audit]), now: wallClock, timeZone: utc)

        let stop = try XCTUnwrap(page.timeline.first { $0.title.hasPrefix(TicketPage.stoppedByYou) })
        XCTAssertEqual(stop.title, "Stopped by you, moved to Backlog")
        XCTAssertEqual(stop.result, .stopped)
        XCTAssertEqual(stop.detail, "Hangs on the rounding test; needs a look.")
        XCTAssertEqual(stop.accessibilityLabel, "14:22, stopped by you, moved to Backlog")
        XCTAssertEqual(page.timeline.filter { $0.title.contains("Backlog") }.count, 1)
        // The live run stays last.
        XCTAssertEqual(page.timeline.last?.result, .current)
    }

    func testAStopWithoutAMoveAndALaterMoveReadApart() throws {
        let audit = ndjson([
            ["event_type": "run_stopped", "issue_identifier": "SHOP-1", "timestamp": "2026-10-07T10:00:00Z"],
            ["event_type": "director_move", "move": "backlog", "issue_identifier": "SHOP-1", "timestamp": "2026-10-07T11:00:00Z"],
            ["event_type": "director_move", "move": "rework", "issue_identifier": "SHOP-1", "timestamp": "2026-10-07T12:00:00Z", "comment": "  "],
            ["event_type": "director_move", "move": "something_new", "issue_identifier": "SHOP-1", "timestamp": "2026-10-07T12:30:00Z", "to_state": "Todo"],
            ["event_type": "director_move", "move": "undo", "issue_identifier": "SHOP-1"],
        ])
        let page = TicketPage(identifier: "SHOP-1", sources: TicketPage.Sources(audit: [audit, Data("not json\n".utf8)]), now: date("2026-10-07T13:00:00Z"), timeZone: utc)

        XCTAssertEqual(page.timeline.map(\.title), ["Stopped by you", "Moved to Backlog by you", "Sent to Rework by you", "Moved to Todo by you"])
        XCTAssertNil(page.timeline[2].detail)
        XCTAssertEqual(page.phase, .unknown)
        XCTAssertEqual(page.phaseSentence, "Symphony isn't working on SHOP-1 right now")
        XCTAssertEqual(page.badges, [])
    }

    func testAStopMadeInTheAppShowsUntilItsRecordArrives() {
        let at = date("2026-10-07T14:22:00Z")
        let stop = TicketPage.LocalStop(identifier: "SHOP-1", at: at, movedToBacklog: true, note: "Hangs")
        let other = TicketPage.LocalStop(identifier: "SHOP-2", at: at, movedToBacklog: false)

        let before = TicketPage(identifier: "SHOP-1", sources: TicketPage.Sources(stops: [stop, other]), now: at, timeZone: utc)
        XCTAssertEqual(before.timeline.map(\.title), ["Stopped by you, moved to Backlog"])
        XCTAssertEqual(before.timeline[0].detail, "Hangs")

        let record = ndjson([["event_type": "run_stopped", "issue_identifier": "SHOP-1", "timestamp": "2026-10-07T14:22:05Z"]])
        let after = TicketPage(identifier: "SHOP-1", sources: TicketPage.Sources(audit: [record], stops: [stop]), now: at, timeZone: utc)
        XCTAssertEqual(after.timeline.count, 1)
    }

    // MARK: - What it waits on

    func testEachWaitingStateSaysWhatItWaitsOn() {
        func phase(_ state: [String: Any]) -> TicketPage.Phase {
            var state = state
            state["generated_at"] = "2026-10-07T14:20:00Z"
            return TicketPage(identifier: "T-1", sources: TicketPage.Sources(state: json(state)), now: wallClock, timeZone: utc).phase
        }
        let ticket: [String: Any] = ["issue_identifier": "T-1", "issue_id": "i-1"]
        func with(_ extra: [String: Any]) -> [[String: Any]] { [ticket.merging(extra) { $1 }] }

        XCTAssertEqual(phase(["retrying": with(["attempt": 1, "due_at": "2026-10-07T14:32:00Z"])]), .waiting(on: "a retry at 14:32"))
        XCTAssertEqual(phase(["retrying": with(["attempt": 1])]), .waiting(on: "a retry"))
        XCTAssertEqual(phase(["slot_waiting": with(["reason": "work slots full"])]), .waiting(on: "a slot (work slots full)"))
        XCTAssertEqual(phase(["slot_waiting": with([:])]), .waiting(on: "a slot"))
        XCTAssertEqual(phase(["blocked": with(["blocked_by": [["issue_identifier": "T-0", "state": "In Progress"]]])]), .waiting(on: "a blocker: T-0"))
        XCTAssertEqual(phase(["blocked": with(["reason": "waits for an app update", "blocked_by": []])]), .waiting(on: "a blocker (waits for an app update)"))
        XCTAssertEqual(phase(["blocked": with([:])]), .waiting(on: "a blocker"))
        XCTAssertEqual(phase(["watching": with(["state": "Human Review"])]), .waiting(on: "you"))
        XCTAssertEqual(phase(["watching": with(["state": "Merging"])]), .waiting(on: "CI"))
        XCTAssertEqual(phase(["watching": with(["state": "Todo"])]), .waiting(on: "Todo"))
        XCTAssertEqual(phase(["watching": with(["state": "Auto Review"]), "qa": ["running": [["identifier": "T-1"]], "queued": []]]),
                       .inReview(gate: nil, qa: "QA pass running"))
        XCTAssertEqual(phase(["watching": with(["state": "In Review"]), "qa": ["running": [], "queued": [["issue_id": "i-1"]]]]),
                       .inReview(gate: nil, qa: "QA pass queued"))
        XCTAssertEqual(phase(["shipped_today": with([:])]), .done(pullRequest: nil, mergedAt: nil))
    }

    func testInReviewShowsTheGateAndAFailingTicketSaysHowOften() throws {
        let state = json([
            "generated_at": "2026-10-07T14:20:00Z",
            "watching": [["issue_identifier": "T-1", "state": "In Review", "title": "Final verification: billing"]],
            "retrying": [["issue_identifier": "T-1", "attempt": 3, "forced": true, "error": "boom", "workspace_path": "/w/T-1"]],
            "epic_lanes": ["lanes": [["identifier": "T-0", "title": "Billing", "sub_issue": ["identifier": "T-1"]]]],
        ])
        let issue = json(["acceptance_gate": ["verdict": "rework", "mode": "enforce", "judged_at": "2026-10-07T14:00:00Z"], "last_error": "x"])
        let page = TicketPage(identifier: "T-1", sources: TicketPage.Sources(state: state, issue: issue), now: wallClock, timeZone: utc)

        XCTAssertEqual(page.phase, .inReview(gate: "Gate: rework", qa: nil))
        XCTAssertEqual(page.phaseSentence, "In review · Gate: rework")
        XCTAssertEqual(page.badges.map(\.word), ["In review", "Failed 3 times", "Forced"])
        XCTAssertEqual(page.initiative, "T-0 Billing")
        XCTAssertEqual(page.facts.map(\.label), ["State", "Type", "Initiative", "Gate verdict", "Forced"])
        XCTAssertEqual(page.facts[1].value, "Final verification")
        XCTAssertEqual(page.timeline.map(\.title), ["Gate: rework"])
        XCTAssertEqual(page.timeline[0].result, .failed)
        XCTAssertEqual(page.lastMessage, "boom")
        XCTAssertEqual(page.workspacePath, "/w/T-1")
    }

    func testAPlanAndARunWithoutACapOrAProfile() {
        let state = json([
            "generated_at": "2026-10-07T14:20:00Z",
            "running": [["issue_identifier": "P-1", "started_at": "2026-10-07T14:19:50Z", "last_event_at": "2026-10-07T14:19:58Z",
                         "pending_tool": ["name": "linear_graphql", "age_ms": 120_000], "tokens": ["total_tokens": 1200]]],
            "waiting_on_you": [["issue_identifier": "P-1", "kind": "plan"]],
            "run_history": [
                ["issue_identifier": "P-1", "run_id": "r0", "status": "running", "started_at": "2026-10-07T14:19:50Z"],
                ["issue_identifier": "P-1", "run_id": "r1", "kind": "qa", "status": "timeout", "started_at": "2026-10-07T13:00:00Z",
                 "ended_at": "2026-10-07T13:05:00Z"],
                ["issue_identifier": "P-1", "run_id": "r2", "status": "success", "started_at": "bad"],
            ],
        ])
        let runs = json(["runs": [
            ["issue_identifier": "P-1", "run_id": "r1", "status": "timeout", "started_at": "2026-10-07T13:00:00Z"],
            ["issue_identifier": "P-1", "run_id": "r3", "status": "failure", "started_at": "2026-10-07T12:00:00Z", "duration_seconds": 60,
             "pull_request_url": "https://example.com/pr"],
            ["issue_identifier": "P-1", "run_id": "r4", "status": NSNull(), "error": "x", "started_at": "2026-10-07T12:30:00Z"],
        ]])
        let page = TicketPage(identifier: "P-1", sources: TicketPage.Sources(state: state, runs: runs), now: wallClock, timeZone: utc)

        let now = try? XCTUnwrap(page.now)
        XCTAssertEqual(now?.run, "Agent run 3")
        XCTAssertNil(now?.model)
        XCTAssertEqual(now?.lastActivity, "2 s ago")
        XCTAssertEqual(now?.pendingTool, "waiting on linear_graphql for 2 min")
        XCTAssertEqual(now?.tokens.value, "1,200")
        XCTAssertNil(now?.tokens.fraction)
        XCTAssertEqual(now?.tokens.note, "No per-ticket cap")
        XCTAssertEqual(page.phaseSentence, "Working")
        XCTAssertEqual(page.facts.map(\.label), ["Type", "Pull request", "Forced"])
        XCTAssertEqual(page.facts[0].value, "Plan")
        XCTAssertEqual(page.facts.first { $0.label == "Pull request" }?.value, "https://example.com/pr")
        XCTAssertEqual(page.timeline.map(\.title), ["Agent run 1", "Agent run 2", "QA pass run 1", "Agent run 3"])
        XCTAssertEqual(page.timeline.map(\.resultWord), ["failed", "failed", "timeout", "running"])
        XCTAssertEqual(page.timeline[2].duration, "5 min")
    }

    func testARunsStatusReadsAsAResult() {
        XCTAssertEqual(TicketPage.result(nil, error: nil).0, .done)
        XCTAssertEqual(TicketPage.result(nil, error: "boom").1, "failed")
        XCTAssertEqual(TicketPage.result("success", error: "ignored").0, .done)
        XCTAssertEqual(TicketPage.result("cancelled", error: nil).0, .stopped)
        XCTAssertEqual(TicketPage.result("error", error: nil).1, "failed")
        XCTAssertEqual(TicketPage.result("turn_timeout", error: nil).1, "turn timeout")
    }

    // MARK: - Paths

    func testItsEndpointsAndLinks() throws {
        XCTAssertEqual(TicketPage.transcriptPath("SHOP-305", repoKey: "web-shop"), "api/v1/repos/web-shop/issues/SHOP-305/transcript")
        XCTAssertEqual(TicketPage.transcriptPath("SHOP-305", repoKey: nil), "api/v1/issues/SHOP-305/transcript")
        XCTAssertEqual(TicketPage.transcriptPath("SHOP-305", repoKey: ""), "api/v1/issues/SHOP-305/transcript")
        XCTAssertEqual(TicketPage.auditPaths("SHOP-305", now: date("2026-10-07T23:59:00Z")), [
            "api/v1/audit?issue=SHOP-305&type=run_stopped&from=2026-09-24&to=2026-10-07",
            "api/v1/audit?issue=SHOP-305&type=director_move&from=2026-09-24&to=2026-10-07",
        ])
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:4000"))
        XCTAssertEqual(TicketPage.auditRecordsURL("SHOP-305", base: base)?.absoluteString, "http://127.0.0.1:4000/audit?issue=SHOP-305")
        XCTAssertEqual(TicketPage.pullRequestName(try XCTUnwrap(URL(string: "https://gitlab.com/a/b/-/merge_requests/3"))), "https://gitlab.com/a/b/-/merge_requests/3")
    }

    /// The walkthrough's reads all answer from the shipped attention fixtures, query strings included.
    @MainActor
    func testTheAttentionFixturesAnswerEveryReadThePageAndTheTranscriptMake() async throws {
        let fixtures = APIFixtures(directory: fixture(), requestLog: FileManager.default.temporaryDirectory.appendingPathComponent("unused.jsonl"))
        let fetch = LiveAPIClient.fetch(base: { APIFixtures.baseURL }, transport: fixtures.transport)
        let paths = [TicketPage.issuePath("SHOP-305"), TicketPage.runsPath, TicketPage.transcriptPath("SHOP-305", repoKey: "web-shop"),
                     InboxPayload.path, TicketPage.issuePath("DOCS-40")] + TicketPage.auditPaths("SHOP-305", now: Date())
        for path in paths {
            guard case let .answered(_, statusCode) = await fetch(path) else { return XCTFail("no answer for \(path)") }
            XCTAssertEqual(statusCode, 200, path)
        }
        // A done ticket's own endpoint is gone, as on a real Symphony.
        guard case let .answered(_, statusCode) = await fetch(TicketPage.issuePath("SHOP-288")) else { return XCTFail("no answer") }
        XCTAssertEqual(statusCode, 404)
    }

    // MARK: - Helpers

    private func fixture() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/attention", isDirectory: true)
    }

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: fixture().appendingPathComponent("api/v1/\(name).json"))
    }

    /// The page as the window builds it from the fixtures: the state, the ticket's endpoint when it answers, the runs
    /// and the audit records, read twice as the two type queries do.
    private func fixturePage(_ identifier: String) throws -> TicketPage {
        let audit = try fixtureData("audit")
        return TicketPage(
            identifier: identifier,
            sources: TicketPage.Sources(
                state: try fixtureData("state"),
                issue: try? fixtureData(identifier),
                runs: try fixtureData("runs"),
                audit: [audit, audit]
            ),
            now: wallClock,
            timeZone: utc
        )
    }

    private func date(_ text: String) -> Date { TicketPage.date(text)! }

    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private func ndjson(_ records: [[String: Any]]) -> Data {
        Data(records.map { String(decoding: json($0), as: UTF8.self) }.joined(separator: "\n").utf8)
    }
}

final class StopRunSheetTests: XCTestCase {
    func testFromNeedsAttentionItStopsThenMovesToBacklogWithTheNote() {
        let sheet = StopRunSheet(identifier: "SHOP-305", origin: .needsAttention, isRunning: true, state: "In Progress")

        XCTAssertTrue(sheet.alsoBacklogByDefault)
        XCTAssertEqual(sheet.title, "Stop the run on SHOP-305?")
        XCTAssertEqual(sheet.verb, "Stop Run")
        XCTAssertEqual(sheet.id, "SHOP-305")
        XCTAssertEqual(
            sheet.happens(alsoBacklog: true),
            "Ends the agent working on SHOP-305 and removes its workspace, with any work it hasn't pushed. Then moves SHOP-305 to Backlog and posts your note on it as a comment."
        )
        XCTAssertTrue(sheet.stays(alsoBacklog: true).hasPrefix("Symphony leaves SHOP-305 alone while it is in Backlog"))
        XCTAssertEqual(sheet.actions(alsoBacklog: true, note: "  Hangs on the rounding test.\n"), [
            .stop("SHOP-305"), .backlog("SHOP-305", note: "Hangs on the rounding test."),
        ])
        XCTAssertEqual(sheet.actions(alsoBacklog: true, note: "   "), [.stop("SHOP-305"), .backlog("SHOP-305", note: nil)])
    }

    func testFromTheTicketPageItOnlyStopsAndTheTicketKeepsItsState() {
        let sheet = StopRunSheet(identifier: "SHOP-305", origin: .ticketPage, isRunning: true, state: "In Progress")

        XCTAssertFalse(sheet.alsoBacklogByDefault)
        XCTAssertEqual(sheet.happens(alsoBacklog: false), "Ends the agent working on SHOP-305 and removes its workspace, with any work it hasn't pushed.")
        XCTAssertEqual(
            sheet.stays(alsoBacklog: false),
            "SHOP-305 keeps its Linear state, In Progress, so Symphony starts it again on its next poll. Its pull request and branch stay as they are."
        )
        XCTAssertTrue(StopRunSheet(identifier: "A-1", origin: .ticketPage, isRunning: true).stays(alsoBacklog: false).hasPrefix("A-1 keeps its Linear state, so"))
        XCTAssertTrue(sheet.canSend(alsoBacklog: false))
        XCTAssertEqual(sheet.actions(alsoBacklog: false, note: "ignored"), [.stop("SHOP-305")])
    }

    func testWithNothingRunningOnlyTheBacklogMoveIsLeft() {
        let sheet = StopRunSheet(identifier: "API-7", origin: .needsAttention, isRunning: false)

        XCTAssertEqual(sheet.title, "Move API-7 to Backlog?")
        XCTAssertEqual(sheet.verb, "Move to Backlog")
        XCTAssertTrue(sheet.happens(alsoBacklog: true).hasPrefix("No agent runs on API-7 right now"))
        XCTAssertFalse(sheet.canSend(alsoBacklog: false))
        XCTAssertEqual(sheet.actions(alsoBacklog: true, note: "flaky"), [.backlog("API-7", note: "flaky")])
        XCTAssertEqual(sheet.actions(alsoBacklog: false, note: ""), [])
    }
}

final class NavigationHistoryTests: XCTestCase {
    func testBackAndForwardMoveBetweenTheViewsAndTicketPagesShown() {
        var history = NavigationHistory(current: .view(.overview))
        XCTAssertFalse(history.canGoBack)
        XCTAssertNil(history.goBack())
        XCTAssertNil(history.goForward())

        history.visit(.ticket("SHOP-305"))
        history.visit(.ticket("SHOP-305"))
        XCTAssertEqual(history.back, [.view(.overview)])

        XCTAssertEqual(history.goBack(), .view(.overview))
        XCTAssertEqual(history.current, .view(.overview))
        XCTAssertTrue(history.canGoForward)
        XCTAssertEqual(history.goForward(), .ticket("SHOP-305"))
        XCTAssertFalse(history.canGoForward)

        history.goBack()
        history.visit(.view(.inbox))
        XCTAssertFalse(history.canGoForward, "a new place clears the forward list")
        XCTAssertEqual(history.back, [.view(.overview)])
    }
}

final class TicketRowTests: XCTestCase {
    func testOnlyRowsAboutATicketOpenAPage() {
        func problem(_ kinds: [Overview.ProblemKind]) -> Overview.Problem {
            Overview.Problem(id: "X-1", kinds: kinds, severity: .warning, sentence: "", fixes: [])
        }
        XCTAssertEqual(problem([.stuck]).ticketIdentifier, "X-1")
        XCTAssertEqual(problem([.usageLimit]).ticketIdentifier, nil)
        XCTAssertEqual(problem([.strayProcesses]).ticketIdentifier, nil)
        XCTAssertEqual(problem([.conflict]).ticketIdentifier, "X-1")
    }

    func testAPathKeepsItsQueryString() throws {
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:4000"))
        XCTAssertEqual(LiveAPIClient.url("api/v1/audit?issue=SHOP-305&type=run_stopped", base: base)?.absoluteString,
                       "http://127.0.0.1:4000/api/v1/audit?issue=SHOP-305&type=run_stopped")
        XCTAssertEqual(LiveAPIClient.url("api/v1/state", base: base)?.absoluteString, "http://127.0.0.1:4000/api/v1/state")
    }
}
