import Combine
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
        XCTAssertTrue(page.isForced)
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
        XCTAssertFalse(page.isForced)
        // The approve move shows once although both audit queries returned it.
        XCTAssertEqual(page.timeline.map(\.title), ["Implementation run 1", "Rework run 1", "Moved to Merging by you", "Merged"])
        XCTAssertEqual(page.timeline.map(\.timeText), ["10:02", "12:10", "13:12", "13:40"])
        XCTAssertEqual(page.timeline[0].accessibilityLabel, "10:02, implementation run 1, done, 29 minutes")
        XCTAssertEqual(page.timeline[3].detail, pullRequest.absoluteString)
    }

    func testAPullRequestInTheInboxShowsWhatItWaitsOn() throws {
        let page = try fixturePage("DOCS-40")

        XCTAssertEqual(page.phase, .waiting(on: "you"))
        XCTAssertEqual(page.phaseSentence, "Waiting on you")
        XCTAssertEqual(page.badges, [TicketPage.Badge(status: .you, word: "Waiting on you")])
        XCTAssertEqual(page.facts.first { $0.label == "Pull request" }?.value, "acme/docs#88")
        XCTAssertNil(page.facts.first { $0.label == "Gate verdict" })
        XCTAssertEqual(page.timeline.map(\.title), [])
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

    func testTheCodeReviewApprovalShowsBeforeTheMoveThatOverturnedIt() throws {
        let page = try fixturePage("SHOP-298")
        let events = page.timeline.filter { $0.id.hasPrefix("verdict-") || $0.id.hasPrefix("move-") }

        XCTAssertEqual(events.map(\.title), ["Approved by Code Review", "Sent to Rework by you"])
        XCTAssertEqual(events.first?.result, .done)
        XCTAssertEqual(events.first?.detail, "on 9c41d27")
        XCTAssertEqual(events.first?.timeText, "12:31")
    }

    func testEachVerdictReadsAsAStepInTimeOrder() {
        let issue = json(["verdicts": [
            ["kind": "qa", "outcome": "blocked", "recorded_at": "2026-10-07T12:00:00Z"],
            ["kind": "qa", "outcome": "skip", "recorded_at": "2026-10-07T11:50:00Z"],
            ["kind": "qa", "outcome": "fail", "head_sha": "abc", "recorded_at": "2026-10-07T11:40:00Z"],
            ["kind": "qa", "outcome": "pass", "recorded_at": "2026-10-07T11:30:00Z"],
            ["kind": "code_review", "outcome": "inconclusive_escalated", "recorded_at": "2026-10-07T11:20:00Z"],
            ["kind": "code_review", "outcome": "block", "recorded_at": "2026-10-07T11:10:00Z"],
            ["kind": "code_review", "outcome": "rework", "recorded_at": "2026-10-07T11:00:00Z"],
            ["kind": "ci_fix", "outcome": "mechanical", "recorded_at": "2026-10-07T10:55:00Z"],
            ["kind": "qa", "outcome": "pass"],
        ]])
        let audit = ndjson([["event_type": "director_move", "move": "rework", "issue_identifier": "SHOP-1", "timestamp": "2026-10-07T11:45:00Z"]])
        let page = TicketPage(identifier: "SHOP-1", sources: TicketPage.Sources(issue: issue, audit: [audit]), now: date("2026-10-07T13:00:00Z"), timeZone: utc)

        XCTAssertEqual(page.timeline.map(\.title), [
            "Sent to Rework by Code Review", "Blocked by Code Review", "Code Review inconclusive escalated", "QA passed",
            "QA failed", "Sent to Rework by you", "QA skipped", "QA blocked",
        ])
        XCTAssertEqual(page.timeline.map(\.result), [.failed, .failed, .done, .done, .failed, .done, .done, .done])
        XCTAssertNil(page.timeline[0].detail)
        XCTAssertEqual(page.timeline[4].detail, "on abc")
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
        XCTAssertEqual(phase(["dispatch_skipped": with(["reason": "on a Needs Decision hold"])]), .waiting(on: "on a Needs Decision hold"))
        XCTAssertEqual(phase(["dispatch_skipped": with([:])]), .waiting(on: "a dispatch gate"))
        XCTAssertEqual(phase(["blocked": with(["blocked_by": [["issue_identifier": "T-0", "state": "In Progress"]]])]), .waiting(on: "a blocker: T-0"))
        XCTAssertEqual(phase(["blocked": with(["reason": "waits for an app update", "blocked_by": []])]), .waiting(on: "a blocker (waits for an app update)"))
        XCTAssertEqual(phase(["blocked": with([:])]), .waiting(on: "a blocker"))
        XCTAssertEqual(phase(["watching": with(["state": "Merging"])]), .waiting(on: "CI"))
        XCTAssertEqual(phase(["watching": with(["state": "Todo"])]), .waiting(on: "Todo"))
        XCTAssertEqual(phase(["watching": with(["state": "QA"]), "qa": ["running": [["identifier": "T-1"]], "queued": []]]),
                       .inReview(qa: "QA pass running"))
        XCTAssertEqual(phase(["watching": with(["state": "Code Review"]), "qa": ["running": [], "queued": [["issue_id": "i-1"]]]]),
                       .inReview(qa: "QA pass queued"))
        XCTAssertEqual(phase(["shipped_today": with([:])]), .done(pullRequest: nil, mergedAt: nil))
    }

    func testAPassedOverTicketSaysItsGateAndHasNoTranscript() {
        let reason = "priority medium is not in tickets.priorities (urgent, high)"
        let state = json([
            "generated_at": "2026-10-07T14:20:00Z",
            "dispatch_skipped": [["issue_identifier": "T-1", "title": "Webhook delivery log", "repo_key": "api", "state": "Todo",
                                  "reason": reason, "since": "2026-10-07T14:13:00Z"]],
        ])
        let issue = json(["repo_key": "api", "status": "dispatch_skipped",
                          "dispatch_skipped": ["state": "Todo", "reason": reason, "since": "2026-10-07T14:13:00Z"]])
        let page = TicketPage(identifier: "T-1", sources: TicketPage.Sources(state: state, issue: issue), now: wallClock, timeZone: utc)

        XCTAssertEqual(page.phaseSentence, "Waiting on \(reason)")
        XCTAssertEqual(page.badges.map(\.word), ["Waiting"])
        XCTAssertEqual(page.title, "Webhook delivery log")
        XCTAssertEqual(page.facts.first, TicketPage.Fact(label: "State", value: "Todo"))
        XCTAssertFalse(page.isTracked)

        let untracked = TicketPage(identifier: "T-1", sources: TicketPage.Sources(issue: json(["status": "untracked"])), now: wallClock, timeZone: utc)
        XCTAssertTrue(untracked.isTracked)
    }

    func testAMergingPullRequestWaitsOnWhatItsPRAndCICardSaysAndNoLongerReadsLandingWaits() {
        func page(_ state: [String: Any]) -> TicketPage {
            var state = state
            state["generated_at"] = "2026-10-07T14:20:00Z"
            return TicketPage(identifier: "T-2", sources: TicketPage.Sources(state: json(state)), now: wallClock, timeZone: utc)
        }
        // TP-967's landing wait is the card's now (TP-946): the page reads it no more.
        let wait: [String: Any] = ["issue_identifier": "T-2", "shared_files": 3, "waits_for": ["issue_identifier": "T-1", "state": "Merging"]]
        let competing: [String: Any] = ["rule": "R14a", "action": "wait_for_competitors", "facts": ["pr": "open", "pr_number": 2],
                                        "waits_on": [["identifier": "T-1", "kind": "competitor", "files": ["SPEC.md", "mix.exs"]]]]

        let merging = page(["watching": [["issue_identifier": "T-2", "state": "Merging"]], "landing_waits": [wait],
                            "issues": [["identifier": "T-2", "watch": competing]]])
        XCTAssertEqual(merging.phaseSentence, "Waiting on T-1 to land")
        XCTAssertEqual(merging.watch?.headline, "Waiting on T-1 to land · they change the same files (SPEC.md, mix.exs)")
        XCTAssertNil(merging.facts.first { $0.label == "Lands after" })

        let unwatched = page(["watching": [["issue_identifier": "T-2", "state": "Merging"]], "landing_waits": [wait]])
        XCTAssertEqual(unwatched.phase, .waiting(on: "CI"))
        XCTAssertNil(unwatched.watch)
        XCTAssertNil(unwatched.facts.first { $0.label == "Lands after" })
    }

    func testInReviewAndAFailingTicketSaysHowOften() throws {
        let state = json([
            "generated_at": "2026-10-07T14:20:00Z",
            "watching": [["issue_identifier": "T-1", "state": "Code Review", "title": "Final verification: billing"]],
            "retrying": [["issue_identifier": "T-1", "attempt": 3, "forced": true, "error": "boom", "workspace_path": "/w/T-1"]],
            "epic_lanes": ["lanes": [["identifier": "T-0", "title": "Billing", "sub_issue": ["identifier": "T-1"]]]],
        ])
        let issue = json(["last_error": "x"])
        let page = TicketPage(identifier: "T-1", sources: TicketPage.Sources(state: state, issue: issue), now: wallClock, timeZone: utc)

        XCTAssertEqual(page.phase, .inReview(qa: nil))
        XCTAssertEqual(page.phaseSentence, "In review")
        XCTAssertEqual(page.badges.map(\.word), ["In review", "Failed 3 times", "Forced"])
        XCTAssertEqual(page.initiative, "T-0 Billing")
        XCTAssertEqual(page.facts.map(\.label), ["State", "Type", "Initiative", "Forced"])
        XCTAssertEqual(page.facts[1].value, "Ticket")
        XCTAssertEqual(page.timeline.map(\.title), [])
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

    func testAnInconclusiveCodeReviewRunSaysItsCause() {
        let state = json([
            "generated_at": "2026-10-07T14:20:00Z",
            "run_history": [
                ["issue_identifier": "P-1", "run_id": "r1", "run_kind": "code_review", "status": "failure",
                 "error": "agent exited: {:code_review_inconclusive, ...}", "review_inconclusive_cause": "invalid_verdict",
                 "started_at": "2026-10-07T13:00:00Z", "ended_at": "2026-10-07T13:05:00Z"],
                ["issue_identifier": "P-1", "run_id": "r2", "status": "failure", "error": "boom", "review_inconclusive_cause": " ",
                 "started_at": "2026-10-07T13:10:00Z"],
            ],
        ])
        let page = TicketPage(identifier: "P-1", sources: TicketPage.Sources(state: state), now: wallClock, timeZone: utc)

        XCTAssertEqual(page.timeline.map(\.detail), ["Review inconclusive: invalid verdict", "boom"])
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

    // MARK: - What the Inbox says about it

    func testADecisionsPageShowsItsSummaryQuestionStoryAndEarlierDecisions() throws {
        let items = try decisionItems()
        let brief = try XCTUnwrap(TicketPage.Brief(identifier: "TP-892", items: items))
        let action = try XCTUnwrap(items[1].review.action)
        XCTAssertEqual(brief.title, "Your decision")
        XCTAssertEqual(brief.summary, "PR open, sent back by Code Review twice over old wording.")
        XCTAssertEqual(brief.paragraphs, [try XCTUnwrap(action.question)] + action.whyParagraphs)
        XCTAssertTrue(brief.paragraphs[1].hasPrefix("Code Review sent #448 back twice."))
        XCTAssertEqual(brief.decisions.map(\.answer), ["Remove it with the rest, in TP-880"])
        XCTAssertEqual(brief.references, items[1].references)
    }

    func testEachOtherKindsPageShowsItsBriefFoundOrReason() throws {
        let items = try decisionItems()
        let plan = try XCTUnwrap(TicketPage.Brief(identifier: "TP-923", items: items))
        XCTAssertEqual(plan.title, "Review brief")
        XCTAssertEqual(plan.paragraphs, ["TP-947: agents write decisions in your words, with trade-offs and what waits."])
        XCTAssertEqual(plan.summary, "The plan to redesign the Inbox decision screen, in ten sub-tickets.")

        let pr = try XCTUnwrap(TicketPage.Brief(identifier: "TP-895", items: items))
        XCTAssertEqual(pr.title, "Review brief")
        XCTAssertEqual(pr.paragraphs, [
            "PR #451",
            "PR #451 counts each time Code Review sends a pull request back; #448 reads 2, as TP-892's popover shows.",
            "Rebased on #448, so the two no longer touch the same lines.",
        ])

        let clarify = try XCTUnwrap(TicketPage.Brief(identifier: "TP-896", items: items))
        XCTAssertEqual(clarify.title, "What the quality gate found")
        XCTAssertEqual(clarify.paragraphs.count, 3)
        XCTAssertEqual(clarify.paragraphs.last, "Did it start with #448, or before?")

        let blocked = try XCTUnwrap(TicketPage.Brief(identifier: "TP-897", items: items))
        XCTAssertEqual(blocked.title, "Why it is blocked")
        XCTAssertEqual(blocked.paragraphs, ["The GitHub token can't comment on #448, so TP-897 can't post TP-892's QA screenshots there."])
        XCTAssertTrue(blocked.decisions.isEmpty)

        XCTAssertNil(TicketPage.Brief(identifier: "TP-999", items: items), "a ticket the Inbox doesn't hold has no brief")
    }

    func testABriefThatSaysNothingFallsBackToTheAsk() throws {
        let raw = InboxItem(id: "r", identifier: "TP-1", kind: .pr, ask: "Review it", review: InboxReview(brief: .raw("First TP-2.\n\n  \n\nThen #3.")))
        XCTAssertEqual(TicketPage.Brief(identifier: "TP-1", items: [raw])?.paragraphs, ["First TP-2.", "Then #3."])
        XCTAssertNil(TicketPage.Brief(identifier: "TP-1", items: [raw])?.summary, "the item doesn't resolve itself")

        let empty = InboxItem(id: "e", identifier: "TP-1", kind: .plan, ask: "The plan", review: InboxReview(brief: .raw("\n\n")))
        XCTAssertEqual(TicketPage.Brief(identifier: "TP-1", items: [empty])?.paragraphs, ["The plan"])
        let none = InboxItem(id: "n", identifier: "TP-1", kind: .pr, ask: "Merge it")
        XCTAssertEqual(TicketPage.Brief(identifier: "TP-1", items: [none])?.paragraphs, ["Merge it"])
        let older = InboxItem(id: "o", identifier: "TP-1", kind: .action, ask: "Add the key", review: InboxReview(
            action: InboxReview.Action(title: "Add the key", steps: ["Add it"], options: [])
        ))
        let action = try XCTUnwrap(TicketPage.Brief(identifier: "TP-1", items: [older]))
        XCTAssertEqual(action.title, "Action")
        XCTAssertEqual(action.paragraphs, ["Add the key"])
        let blocked = InboxItem(id: "b", identifier: "TP-1", kind: .blocked, ask: "The run reported a block")
        XCTAssertEqual(TicketPage.Brief(identifier: "TP-1", items: [blocked])?.paragraphs, ["The run reported a block"])
        let clarify = InboxItem(id: "c", identifier: "TP-1", kind: .clarify, ask: "Answer the gate")
        XCTAssertEqual(TicketPage.Brief(identifier: "TP-1", items: [clarify])?.paragraphs, ["Answer the gate"])
    }

    // MARK: - Helpers

    /// The `inbox-decision` fixture's items: the plan TP-923, TP-892's decision, TP-895's pull request, TP-896's
    /// clarify and TP-897's block.
    private func decisionItems() throws -> [InboxItem] {
        let url = fixture().deletingLastPathComponent().appendingPathComponent("inbox-decision/api/v1/inbox.json")
        return try XCTUnwrap(InboxPayload.decode(Data(contentsOf: url))?.items)
    }

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

    func testAPausedRepositorysTicketSaysSoInOneLine() {
        func page(_ issue: [String: Any]) -> TicketPage {
            TicketPage(identifier: "T-1", sources: TicketPage.Sources(issue: json(issue)), now: wallClock, timeZone: utc)
        }
        let paused = page(["repo_key": "web-shop", "status": "dispatch_skipped", "repository_paused": true])
        XCTAssertTrue(paused.repositoryPaused)
        XCTAssertEqual(paused.repositoryPausedNote, "The repository web-shop is paused: Symphony doesn't dispatch its tickets.")
        // Nothing else on the page changes with it.
        let dispatching = page(["repo_key": "web-shop", "status": "dispatch_skipped", "repository_paused": false])
        XCTAssertNil(dispatching.repositoryPausedNote)
        var same = paused
        same.repositoryPaused = false
        XCTAssertEqual(same, dispatching)

        XCTAssertEqual(page(["repository_paused": true]).repositoryPausedNote, "The repository is paused: Symphony doesn't dispatch its tickets.")
        // An older Symphony says nothing of it.
        XCTAssertFalse(page(["repo_key": "web-shop", "status": "dispatch_skipped"]).repositoryPaused)
        XCTAssertFalse(TicketPage(identifier: "T-1", sources: TicketPage.Sources(), now: wallClock, timeZone: utc).repositoryPaused)
    }

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
            "SHOP-305 keeps its Linear state, In Progress, but Symphony doesn't start it again: it waits in the Inbox as stopped by "
                + "you until you Unblock or Restart it, or move it on the board. Its pull request and branch stay as they are."
        )
        XCTAssertTrue(StopRunSheet(identifier: "A-1", origin: .ticketPage, isRunning: true).stays(alsoBacklog: false).hasPrefix("A-1 keeps its Linear state, but"))
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

// MARK: - The timeline from the events feed (TP-1193)

/// Answers each read of the feed with the next canned answer, the last one again once they run out; while `holding`,
/// a read waits for `release()`.
@MainActor
private final class ScriptedFeed {
    var answers: [TicketEventsResult] = []
    private(set) var paths: [String] = []
    var holding = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var get: TicketEventsReader.Get { { [unowned self] path in await answer(path) } }

    private func answer(_ path: String) async -> TicketEventsResult {
        paths.append(path)
        if holding { await withCheckedContinuation { waiting.append($0) } }
        return answers.count > 1 ? answers.removeFirst() : answers.first ?? .unsupported
    }

    func release() {
        holding = false
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// The live channel, scripted: each opening is answered with the next status code, and the test writes its body.
@MainActor
private final class ScriptedChannel: PollScheduler {
    var answers: [Int] = []
    private(set) var body: AsyncThrowingStream<Data, Error>.Continuation?
    /// The try the stream scheduled after a drop.
    private(set) var retry: (@MainActor () -> Void)?

    var connect: EventStream.Connect {
        { [unowned self] _ in
            guard !answers.isEmpty else { throw URLError(.cannotConnectToHost) }
            let (body, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            self.body = continuation
            return EventStream.Response(statusCode: answers.removeFirst(), body: body)
        }
    }

    nonisolated func schedule(after interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> PollTimer {
        MainActor.assumeIsolated { retry = action }
        return Idle()
    }

    private struct Idle: PollTimer {
        func cancel() {}
    }

    func stream() -> EventStream {
        EventStream(base: { URL(string: "http://127.0.0.1:4000") }, connect: connect, scheduler: self)
    }

    /// Symphony's notice that it wrote an event on `identifier`.
    func notice(_ identifier: String, repoKey: String? = "web-shop") {
        let repo = repoKey.map { #""repo_key":"\#($0)","# } ?? ""
        body?.yield(Data("event: ticket\ndata: {\(repo)\"issue_id\":\"i-410\",\"issue_identifier\":\"\(identifier)\",\"event_id\":\"ev-x\",\"type\":\"note\"}\n\n".utf8))
    }
}

@MainActor
final class TicketPageFeedTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var cancellables = Set<AnyCancellable>()

    private static func director(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/\(name)", isDirectory: true)
    }

    private var feedData: Data { get throws { try Data(contentsOf: TicketEventsTests.sharedFixture) } }

    /// The page as the window builds it from a QA fixture's files, with what the feed's reader read.
    private func fixturePage(_ name: String, events: TicketEventsPayload?, feedAbsence: TicketFeedAbsence = .unread) throws -> TicketPage {
        let api = Self.director(name).appendingPathComponent("api/v1")
        return TicketPage(
            identifier: "SHOP-410",
            sources: TicketPage.Sources(
                state: try Data(contentsOf: api.appendingPathComponent("state.json")),
                issue: try Data(contentsOf: api.appendingPathComponent("SHOP-410.json")),
                events: events,
                feedAbsence: feedAbsence
            ),
            timeZone: utc
        )
    }

    /// Waits for the main actor's queued work (the channel's chunk, a read's start) until `done`.
    private func settle(until done: () -> Bool) async {
        for _ in 0 ..< 500 where !done() { await Task.yield() }
    }

    /// A page of the feed with QA run 2's result: its verdict and its end.
    private static let qaRunTwoEnded = TicketEventsTests.page(nextSince: "2026-10-18T11:31:00Z", entries: [
        TicketEventsTests.run("run-qa-2", number: 2, status: "ended", exit: "ended normally", verdict: "fail", ended: "2026-10-18T11:31:00Z", events: [
            TicketEventsTests.event("ev-17", seq: 17, type: "finding.recorded", at: "2026-10-18T11:25:00Z", run: "run-qa-2", title: "QA found truncated"),
            TicketEventsTests.event("ev-18", seq: 18, type: "verdict.recorded", at: "2026-10-18T11:30:00Z", run: "run-qa-2", title: "QA verdict: fail", payload: #"{"kind":"qa","outcome":"fail"}"#),
            TicketEventsTests.event("ev-19", seq: 19, type: "run.ended", at: "2026-10-18T11:31:00Z", run: "run-qa-2", title: "QA run 2 ended", payload: #"{"exit":"ended normally"}"#),
        ]),
    ])

    // MARK: - The page

    func testWithTheFeedTheTimelineIsItsRunsAndEvents() throws {
        let page = try fixturePage("ticket-ledger", events: TicketEventsTests.sharedPayload())

        XCTAssertEqual(page.repoKey, "web-shop")
        XCTAssertEqual(page.timeline.map(\.title), [
            "Entered In Progress from Todo", "Implementation run 1", "Entered QA from Code Review", "QA run 1",
            "Entered Rework from QA", "Note by you", "Entered QA from Code Review", "QA run 2",
        ])
        let failed = try XCTUnwrap(page.timeline.first { $0.runID == "run-qa-1" })
        XCTAssertEqual(failed.resultWord, "failed")
        XCTAssertEqual(failed.children.last?.title, "QA verdict: fail")
        XCTAssertEqual(failed.children.flatMap(\.screenshots).count, 3)
        XCTAssertEqual(page.timeline.last?.resultWord, "running")
        // The state's generated_at is the reference: QA run 2 has run 9 minutes.
        XCTAssertEqual(page.timeline.last?.duration, "9 min")
    }

    func testWithoutTheFeedThePageShowsTodaysTimeline() throws {
        // An older Symphony: no feed, so the runs and the verdicts make the timeline.
        for events in [nil, TicketEventsPayload()] {
            let page = try fixturePage("ticket-ledger-no-feed", events: events)
            XCTAssertEqual(page.timeline.map(\.title), ["Implementation run 1", "QA pass run 1", "QA failed"])
            XCTAssertEqual(page.timeline[2].detail, "on bbb2222")
            XCTAssertFalse(page.timeline.contains(where: \.isGroup))
        }
    }

    func testAStopFromTheAppShowsUntilTheFeedHasCaughtUp() throws {
        func page(stoppedAt: String) throws -> TicketPage {
            TicketPage(
                identifier: "SHOP-410",
                sources: TicketPage.Sources(
                    stops: [TicketPage.LocalStop(identifier: "SHOP-410", at: try XCTUnwrap(TicketPage.date(stoppedAt)), movedToBacklog: false)],
                    events: try TicketEventsTests.sharedPayload()
                ),
                now: try XCTUnwrap(TicketPage.date("2026-10-18T11:20:00Z")),
                timeZone: utc
            )
        }
        XCTAssertEqual(try page(stoppedAt: "2026-10-18T11:15:00Z").timeline.last?.title, TicketPage.stoppedByYou)
        XCTAssertFalse(try page(stoppedAt: "2026-10-18T11:00:00Z").timeline.contains { $0.title == TicketPage.stoppedByYou })
    }

    func testTheQAFixtureServesTheFileTheElixirTestChecksIn() throws {
        let served = Self.director("ticket-ledger").appendingPathComponent("api/v1/repos/web-shop/tickets/SHOP-410/events.json")
        XCTAssertEqual(try Data(contentsOf: served), try feedData)
    }

    func testTheQAFixturesAnswerTheFeedAndItsScreenshotsThroughTheWindowsClient() async throws {
        let root = uniqueTemporaryDirectory("ticket-ledger")
        defer { try? FileManager.default.removeItem(at: root) }
        func client(_ name: String) -> LiveAPIClient {
            let fixtures = APIFixtures(directory: Self.director(name), requestLog: root.appendingPathComponent("\(name).jsonl"))
            return LiveAPIClient(fetch: LiveAPIClient.fetch(base: { APIFixtures.baseURL }, transport: fixtures.transport))
        }

        let ledger = client("ticket-ledger")
        let reader = TicketEventsReader(get: { TicketEventsResult(await ledger.answer($0)) })
        XCTAssertTrue(reader.follow(identifier: "SHOP-410", repoKey: "web-shop"))
        await reader.settle()
        let events = try XCTUnwrap(reader.events)
        XCTAssertEqual(events, try TicketEventsTests.sharedPayload())
        // Without the channel's fixture the channel is unavailable, and each state poll reads the same page again.
        reader.channelChanged(.unavailable)
        reader.statePolled()
        await reader.settle()
        XCTAssertEqual(reader.requests.count, 2)
        XCTAssertEqual(reader.events, events)

        let images = ArtifactImages(get: { await ledger.answer($0) })
        let shots = try fixturePage("ticket-ledger", events: events).timeline.flatMap(\.children).flatMap(\.screenshots)
        for shot in shots { await images.load(shot)?.value }
        XCTAssertEqual(shots.map { images.image($0) == .unavailable }, [false, false, true])
        XCTAssertEqual(shots.compactMap { if case .loaded = images.image($0) { $0.label } else { nil } },
                       ["Run header at 1440×900", "Run header at 1100×800"])

        let older = client("ticket-ledger-no-feed")
        let legacy = TicketEventsReader(get: { TicketEventsResult(await older.answer($0)) })
        legacy.follow(identifier: "SHOP-410", repoKey: "web-shop")
        await legacy.settle()
        XCTAssertNil(legacy.events)
        XCTAssertTrue(legacy.isUnsupported)
    }

    // MARK: - The note field

    /// The Director's note as the feed answers it once Symphony wrote it.
    private static func notePage(_ text: String) -> TicketEventsResult {
        .loaded(Data(TicketEventsTests.page(nextSince: "2026-10-18T11:19:00Z", entries: [
            TicketEventsTests.event(
                "ev-20", seq: 20, type: "note", at: "2026-10-18T11:19:00Z", title: "Note added", detail: text,
                payload: #"{"text":"\#(text)"}"#, actor: #"{"kind":"person","name":"the Director"}"#
            ),
        ]).utf8))
    }

    /// What the note field sent, and how often it read the feed.
    private final class NoteCalls {
        var sent: [ControlAction] = []
        var reads = 0
    }

    func testANoteGoesOnTheTicketAndShowsInTheTimelineAsTheDirectorsAtOnce() async throws {
        let feed = ScriptedFeed()
        let text = "Keep the run header visible when the pane is narrow, at both widths."
        feed.answers = [.loaded(try feedData), Self.notePage(text)]
        let reader = TicketEventsReader(get: feed.get)
        reader.follow(identifier: "SHOP-410", repoKey: "web-shop")
        await reader.settle()
        let before = try fixturePage("ticket-ledger", events: reader.events)
        XCTAssertTrue(before.acceptsNotes)
        XCTAssertEqual(before.timeline.filter { $0.title == TicketPage.noteByYou }.count, 1)

        let composer = TicketNoteComposer()
        let calls = NoteCalls()
        composer.text = "  \(text)\n"
        let written = await composer.submit(on: before, send: { action in
            calls.sent.append(action)
            return ControlAPI.result(action, statusCode: 200, data: Data(#"{"event":{"id":"ev-20","type":"note"}}"#.utf8))
        }, read: {
            calls.reads += 1
            reader.read()
        })
        await reader.settle()

        XCTAssertTrue(written)
        XCTAssertEqual(calls.sent, [.note(repoKey: "web-shop", identifier: "SHOP-410", text: text)])
        XCTAssertEqual(calls.reads, 1)
        XCTAssertEqual(composer.text, "")
        XCTAssertNil(composer.refusal)
        XCTAssertFalse(composer.sending)
        // The page read what is new in the feed: the note is in the timeline, as the Director's.
        XCTAssertEqual(feed.paths.last, "api/v1/repos/web-shop/tickets/SHOP-410/events?group=run&limit=200&since=2026-10-18T11:13:00.000000Z")
        let after = try fixturePage("ticket-ledger", events: reader.events)
        let notes = after.timeline.filter { $0.title == TicketPage.noteByYou }
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes.last?.detail, text)
    }

    func testANoteThatIsEmptyOrTooLongOrRefusedIsNotRecordedAndTheFieldSaysWhy() async throws {
        let page = try fixturePage("ticket-ledger", events: try TicketEventsTests.sharedPayload())
        let composer = TicketNoteComposer()
        let calls = NoteCalls()
        func submit(_ answer: ControlResult = .done) async -> Bool {
            await composer.submit(on: page, send: { action in
                calls.sent.append(action)
                return answer
            }, read: { calls.reads += 1 })
        }

        // Return on an empty field posts nothing, and there is nothing to say.
        for empty in ["", "  \n "] {
            composer.text = empty
            let written = await submit()
            XCTAssertFalse(written)
            XCTAssertNil(composer.refusal)
        }

        // A note over the bound is refused here, as Symphony would refuse it, and the text stays.
        let long = String(repeating: "é", count: TicketNoteComposer.maxLength + 1)
        composer.text = long
        var written = await submit()
        XCTAssertFalse(written)
        XCTAssertEqual(composer.refusal, "A note holds at most 4,000 characters; this one has 4,001")
        XCTAssertEqual(composer.text, long)
        XCTAssertEqual(calls.sent, [])
        XCTAssertNil(TicketNoteComposer.tooLong(String(repeating: "é", count: TicketNoteComposer.maxLength)))

        // Symphony's refusal: its reason under the field, the text kept, the feed not read.
        composer.text = "Keep it."
        let refusal = ControlAPI.result(
            .note(repoKey: "web-shop", identifier: "SHOP-410", text: "Keep it."), statusCode: 400,
            data: Data(#"{"error":{"code":"invalid_note","message":"A note needs text"}}"#.utf8)
        )
        written = await submit(refusal)
        XCTAssertFalse(written)
        XCTAssertEqual(calls.sent, [.note(repoKey: "web-shop", identifier: "SHOP-410", text: "Keep it.")])
        XCTAssertEqual(composer.refusal, "Couldn't add the note to SHOP-410: A note needs text (HTTP 400)")
        XCTAssertEqual(TicketNoteComposer.refusalLabel(composer.refusal!), "Note not added: Couldn't add the note to SHOP-410: A note needs text (HTTP 400)")
        XCTAssertEqual(composer.text, "Keep it.")
        XCTAssertEqual(calls.reads, 0)

        // The next note that goes through clears the reason.
        written = await submit()
        XCTAssertTrue(written)
        XCTAssertNil(composer.refusal)
    }

    func testAgainstASymphonyWithoutTheFeedTheNoteFieldIsOffAndPostsNothing() async throws {
        let root = uniqueTemporaryDirectory("ticket-note")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = APIFixtures(directory: Self.director("ticket-ledger-no-feed"), requestLog: root.appendingPathComponent("requests.jsonl"))
        let client = LiveAPIClient(fetch: LiveAPIClient.fetch(base: { APIFixtures.baseURL }, transport: fixtures.transport))
        let reader = TicketEventsReader(get: { TicketEventsResult(await client.answer($0)) })
        var told = 0
        reader.onChange = { _ in told += 1 }
        reader.follow(identifier: "SHOP-410", repoKey: "web-shop")
        await reader.settle()
        XCTAssertEqual(told, 1, "a 404 on the first read tells the page, though it holds nothing still")

        let page = try fixturePage("ticket-ledger-no-feed", events: reader.events, feedAbsence: reader.absence)
        XCTAssertFalse(page.acceptsNotes)
        XCTAssertEqual(page.feedAbsence, .unsupported)
        XCTAssertEqual(page.notesOffReason, TicketNoteComposer.unsupportedReason)
        let composer = TicketNoteComposer()
        let calls = NoteCalls()
        composer.text = "Keep it."
        let written = await composer.submit(on: page, send: { action in
            calls.sent.append(action)
            return .done
        }, read: { calls.reads += 1 })

        XCTAssertFalse(written)
        XCTAssertEqual(calls.sent, [])
        XCTAssertEqual(composer.text, "Keep it.")
        XCTAssertEqual(TicketNoteComposer.unsupportedReason, "This version of Symphony can't take notes. Update Symphony to add one.")
        XCTAssertEqual(TicketNoteComposer.fieldLabel(page.identifier), "Note on SHOP-410")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixtures.requestLog.path))

        // A feed that read but holds nothing still takes notes; a ticket whose repo isn't known doesn't.
        XCTAssertTrue(try fixturePage("ticket-ledger", events: TicketEventsPayload()).acceptsNotes)
        XCTAssertFalse(TicketPage(identifier: "SHOP-410", sources: TicketPage.Sources(events: TicketEventsPayload())).acceptsNotes)
        XCTAssertNil(try fixturePage("ticket-ledger", events: TicketEventsPayload()).notesOffReason)
    }

    func testBeforeTheFirstReadAndAfterAFailedOneTheNoteFieldIsOffWithoutBlamingSymphony() async throws {
        let feed = ScriptedFeed()
        feed.answers = [.failed("Symphony answered with HTTP 503")]
        let reader = TicketEventsReader(get: feed.get)
        func page() throws -> TicketPage {
            try fixturePage("ticket-ledger", events: reader.events, feedAbsence: reader.absence)
        }

        // The page just opened: nothing read yet.
        let opened = try page()
        XCTAssertFalse(opened.acceptsNotes)
        XCTAssertEqual(opened.feedAbsence, .unread)
        XCTAssertEqual(opened.notesOffReason, TicketNoteComposer.readingReason)

        // A 5xx: still off, and still not "update Symphony".
        reader.follow(identifier: "SHOP-410", repoKey: "web-shop")
        await reader.settle()
        let failed = try page()
        XCTAssertFalse(failed.acceptsNotes)
        XCTAssertEqual(failed.feedAbsence, .unread)
        XCTAssertEqual(failed.notesOffReason, TicketNoteComposer.readingReason)
        XCTAssertEqual(TicketNoteComposer.readingReason, "Reading the ticket's history…")

        // The next read lands: the field takes notes.
        feed.answers = [.loaded(try feedData)]
        reader.statePolled()
        await reader.settle()
        XCTAssertTrue(try page().acceptsNotes)
        XCTAssertNil(try page().notesOffReason)
    }

    func testForATicketThatHasNotRunYetTheNoteFieldIsOffAndSaysSoWithoutBlamingSymphony() async throws {
        // A current Symphony keeps no record of a ticket before its first run: the feed's own 404, not the router's.
        func answer(_ body: String, statusCode: Int = 404) -> TicketEventsResult {
            TicketEventsResult(.answered(Data(body.utf8), statusCode: statusCode))
        }
        let unknown = answer(#"{"error":{"code":"ticket_not_found","message":"No ticket SHOP-410 in web-shop"}}"#)
        XCTAssertEqual(unknown, .unknownTicket)
        XCTAssertEqual(answer(#"{"error":{"code":"not_found","message":"Route not found"}}"#), .unsupported)
        XCTAssertEqual(answer(""), .unsupported)
        XCTAssertEqual(answer("{}", statusCode: 200), .loaded(Data("{}".utf8)))
        XCTAssertEqual(answer("", statusCode: 503), .failed("Symphony answered with HTTP 503"))
        XCTAssertEqual(TicketEventsResult(.unreachable), .failed("Symphony isn't answering"))

        let feed = ScriptedFeed()
        feed.answers = [unknown, unknown, .loaded(try feedData)]
        let reader = TicketEventsReader(get: feed.get)
        var told = 0
        reader.onChange = { _ in told += 1 }
        reader.follow(identifier: "SHOP-410", repoKey: "web-shop")
        await reader.settle()
        XCTAssertEqual(told, 1, "the feed's 404 tells the page, though it holds nothing still")
        XCTAssertEqual(reader.absence, .unknownTicket)
        XCTAssertFalse(reader.isUnsupported)

        let page = try fixturePage("ticket-ledger", events: reader.events, feedAbsence: reader.absence)
        XCTAssertFalse(page.acceptsNotes)
        XCTAssertEqual(page.notesOffReason, TicketNoteComposer.unknownTicketReason)
        XCTAssertNotEqual(page.notesOffReason, TicketNoteComposer.unsupportedReason)
        XCTAssertEqual(
            TicketNoteComposer.unknownTicketReason,
            "Symphony has no history for this ticket yet. A note can go on once its first run starts."
        )
        let composer = TicketNoteComposer()
        var sent: [ControlAction] = []
        composer.text = "Keep it."
        let written = await composer.submit(on: page, send: { action in
            sent.append(action)
            return .done
        }, read: {})
        XCTAssertFalse(written)
        XCTAssertEqual(sent, [])

        // Unlike an older Symphony's 404, it reads again; the same answer doesn't redraw the page.
        reader.statePolled()
        await reader.settle()
        XCTAssertEqual(feed.paths.count, 2)
        XCTAssertEqual(told, 1)

        // The ticket's first run starts: the channel's notice reads its history, and the field takes notes.
        reader.noticed(EventStreamNotice(
            repoKey: "web-shop", issueId: "issue-410", issueIdentifier: "SHOP-410", eventId: "ev-1", type: "run.started", at: nil
        ))
        await reader.settle()
        XCTAssertEqual(told, 2)
        XCTAssertEqual(reader.absence, .unread)
        let ran = try fixturePage("ticket-ledger", events: reader.events, feedAbsence: reader.absence)
        XCTAssertTrue(ran.acceptsNotes)
        XCTAssertNil(ran.notesOffReason)

        // Another ticket opened after one the feed didn't know: its page starts from "reading" until its feed answers.
        feed.answers = [unknown]
        reader.read()
        await reader.settle()
        XCTAssertEqual(reader.absence, .unknownTicket)
        feed.holding = true
        reader.follow(identifier: "SHOP-411", repoKey: "web-shop")
        XCTAssertEqual(told, 4)
        XCTAssertEqual(reader.absence, .unread)
        feed.release()
        await reader.settle()
    }

    func testTheNoteFieldBelongsToTheTicketShownAndKeepsWhatIsTypedMeanwhile() async throws {
        let page = try fixturePage("ticket-ledger", events: try TicketEventsTests.sharedPayload())
        let composer = TicketNoteComposer()

        // Typed while the note is on its way: it stays, and a second Return meanwhile posts nothing.
        composer.text = "First."
        var nested: Bool?
        var written = await composer.submit(on: page, send: { _ in
            XCTAssertTrue(composer.sending)
            composer.text = "Second, typed meanwhile."
            nested = await composer.submit(on: page, send: { _ in .done }, read: {})
            return .done
        }, read: {})
        XCTAssertTrue(written)
        XCTAssertEqual(nested, false)
        XCTAssertEqual(composer.text, "Second, typed meanwhile.")

        // Another ticket opened while a note was on its way: its field starts empty, and the answer changes nothing.
        written = await composer.submit(on: page, send: { _ in
            composer.show("SHOP-411")
            composer.text = "On SHOP-411."
            return .failed("Couldn't add the note to SHOP-410: HTTP 502")
        }, read: {})
        XCTAssertFalse(written)
        XCTAssertEqual(composer.identifier, "SHOP-411")
        XCTAssertEqual(composer.text, "On SHOP-411.")
        XCTAssertNil(composer.refusal)
        XCTAssertFalse(composer.sending)
    }

    func testTheQAFixturesTakeTheNoteAndLogItForQA() async throws {
        let root = uniqueTemporaryDirectory("ticket-note-qa")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = APIFixtures(directory: Self.director("ticket-ledger"), requestLog: root.appendingPathComponent("requests.jsonl"))

        let result = await ControlAPI.send(
            .note(repoKey: "web-shop", identifier: "SHOP-410", text: "Keep the header."), stateRoot: root, fallback: APIFixtures.baseURL,
            token: APIFixtures.token, transport: fixtures.transport
        )

        XCTAssertEqual(result, .done)
        let line = try String(contentsOf: fixtures.requestLog, encoding: .utf8).trimmingCharacters(in: .newlines)
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(entry["path"] as? String, "/api/v1/control/note")
        XCTAssertEqual(entry["body"] as? [String: String], ["repo_key": "web-shop", "issue_identifier": "SHOP-410", "text": "Keep the header."])
    }

    // MARK: - Reading the feed

    func testOpeningReadsEveryPageForwardAndStopsAtThePageThatAddsNothing() async throws {
        func page(_ ids: [Int], next: String) -> TicketEventsResult {
            .loaded(Data(TicketEventsTests.page(nextSince: next, entries: ids.map {
                TicketEventsTests.event("e-\($0)", seq: $0, type: "note", at: String(format: "2026-10-18T10:%02d:00Z", $0), title: "Note \($0)")
            }).utf8))
        }
        let feed = ScriptedFeed()
        feed.answers = [page([1, 2], next: "2026-10-18T10:02:00Z"), page([3, 4], next: "2026-10-18T10:04:00Z"), page([3, 4], next: "2026-10-18T10:04:00Z")]
        let reader = TicketEventsReader(get: feed.get, pageLimit: 2)

        reader.follow(identifier: "SHOP-410", repoKey: "web-shop")
        await reader.settle()

        XCTAssertEqual(feed.paths, [
            "api/v1/repos/web-shop/tickets/SHOP-410/events?group=run&limit=2",
            "api/v1/repos/web-shop/tickets/SHOP-410/events?group=run&limit=2&since=2026-10-18T10:02:00Z",
            "api/v1/repos/web-shop/tickets/SHOP-410/events?group=run&limit=2&since=2026-10-18T10:04:00Z",
        ])
        XCTAssertEqual(reader.events?.events.map(\.id), ["e-1", "e-2", "e-3", "e-4"])

        // A short page is the last; and a read never asks for more than its bound.
        feed.answers = [page([5], next: "2026-10-18T10:05:00Z")]
        reader.read()
        await reader.settle()
        XCTAssertEqual(feed.paths.count, 4)
        XCTAssertEqual(feed.paths.last, "api/v1/repos/web-shop/tickets/SHOP-410/events?group=run&limit=2&since=2026-10-18T10:04:00Z")

        let endless = ScriptedFeed()
        endless.answers = (0 ..< 10).map { page([10 + 2 * $0, 11 + 2 * $0], next: "2026-10-18T11:\(10 + $0):00Z") }
        let bounded = TicketEventsReader(get: endless.get, pageLimit: 2, maxPages: 3)
        bounded.follow(identifier: "SHOP-410", repoKey: "web-shop")
        await bounded.settle()
        XCTAssertEqual(endless.paths.count, 3)
        XCTAssertEqual(bounded.events?.events.count, 6)
    }

    func testAFeedThatIsntThereLeavesTodaysTimeline() async throws {
        var told: [TicketEventsPayload?] = []
        let feed = ScriptedFeed()
        feed.answers = [.loaded(try feedData)]
        let reader = TicketEventsReader(get: feed.get)
        reader.onChange = { told.append($0) }
        reader.follow(identifier: "SHOP-410", repoKey: "web-shop")
        await reader.settle()
        XCTAssertNotNil(reader.events)

        // Unreachable, or a body that isn't a feed page: no feed; the next read starts over.
        for failure in [TicketEventsResult.failed("Symphony isn't answering"), .loaded(Data("<html>".utf8))] {
            feed.answers = [failure]
            reader.read()
            await reader.settle()
            XCTAssertNil(reader.events)
            XCTAssertFalse(reader.isUnsupported)
        }
        feed.answers = [.loaded(try feedData)]
        reader.statePolled()
        await reader.settle()
        XCTAssertNotNil(reader.events)
        XCTAssertFalse(try XCTUnwrap(feed.paths.last).contains("since="), "a read after a failure reads it all")

        // A 404: Symphony predates the feed. Nothing reads it again until the page opens anew.
        feed.answers = [.unsupported]
        reader.read()
        await reader.settle()
        XCTAssertNil(reader.events)
        XCTAssertTrue(reader.isUnsupported)
        let reads = feed.paths.count
        reader.statePolled()
        XCTAssertNil(reader.read())
        XCTAssertEqual(feed.paths.count, reads)
        XCTAssertEqual(told.map { $0 == nil }, [false, true, false, true])

        reader.follow(identifier: nil, repoKey: nil)
        feed.answers = [.loaded(try feedData)]
        XCTAssertTrue(reader.follow(identifier: "SHOP-410", repoKey: "web-shop"))
        await reader.settle()
        XCTAssertNotNil(reader.events)
    }

    func testFollowsTheShownTicketOnceItsRepoIsKnown() async throws {
        let feed = ScriptedFeed()
        feed.answers = [.loaded(try feedData)]
        let reader = TicketEventsReader(get: feed.get)

        XCTAssertFalse(reader.follow(identifier: "SHOP-410", repoKey: nil), "no read before the repo is known")
        XCTAssertNil(reader.read())
        XCTAssertTrue(reader.follow(identifier: "SHOP-410", repoKey: "web-shop"))
        await reader.settle()
        // The same ticket, its repo unknown for a moment, keeps what it read.
        XCTAssertFalse(reader.follow(identifier: "SHOP-410", repoKey: nil))
        XCTAssertFalse(reader.follow(identifier: "SHOP-410", repoKey: "web-shop"))
        XCTAssertNotNil(reader.events)

        // Another ticket while a read is out: the read's answer is dropped.
        feed.holding = true
        XCTAssertTrue(reader.follow(identifier: "SHOP-411", repoKey: "web-shop"))
        XCTAssertNil(reader.events)
        await settle { feed.paths.count == 2 }
        reader.follow(identifier: nil, repoKey: nil)
        feed.release()
        await reader.settle()
        XCTAssertNil(reader.events)
        XCTAssertNil(reader.identifier)
        XCTAssertNil(reader.repoKey)
    }

    func testARunUnderWayTurnsToItsResultWhenTheChannelSaysSomethingHappened() async throws {
        let channel = ScriptedChannel()
        channel.answers = [200]
        let stream = channel.stream()
        let feed = ScriptedFeed()
        feed.answers = [.loaded(try feedData)]
        let reader = TicketEventsReader(get: feed.get)
        reader.listen(to: stream)
        stream.start()
        await settle { stream.state == .connected }
        XCTAssertEqual(reader.channel, .connected)

        reader.follow(identifier: "SHOP-410", repoKey: "web-shop")
        await reader.settle()
        var page = try fixturePage("ticket-ledger", events: reader.events)
        XCTAssertEqual(page.timeline.last?.title, "QA run 2")
        XCTAssertEqual(page.timeline.last?.resultWord, "running")
        XCTAssertEqual(page.timeline.last?.result, .current)

        // While the channel is connected, a state poll reads nothing; another ticket's or repo's notice neither.
        reader.statePolled()
        channel.notice("SHOP-411")
        channel.notice("SHOP-410", repoKey: "api")
        await settle { false }
        XCTAssertEqual(feed.paths.count, 1)

        // QA records its result: Symphony's notice, then one read of what is newer than the cursor.
        feed.answers = [.loaded(Data(Self.qaRunTwoEnded.utf8))]
        channel.notice("SHOP-410")
        await settle { feed.paths.count == 2 }
        await reader.settle()
        XCTAssertEqual(feed.paths.last, "api/v1/repos/web-shop/tickets/SHOP-410/events?group=run&limit=200&since=2026-10-18T11:13:00.000000Z")
        page = try fixturePage("ticket-ledger", events: reader.events)
        let run = try XCTUnwrap(page.timeline.last)
        XCTAssertEqual(run.title, "QA run 2")
        XCTAssertEqual(run.resultWord, "failed")
        XCTAssertEqual(run.result, .failed)
        XCTAssertEqual(run.children.last?.title, "QA verdict: fail")
        XCTAssertEqual(run.foldAccessibilityLabel(folded: true), "Expand QA run 2, failed")
        // The fold is kept by run id, the same before and after the read.
        XCTAssertEqual(run.runID, "run-qa-2")
        stream.stop()
    }

    func testNoticesDuringAReadLeadToOneMoreReadNotOneEach() async throws {
        let channel = ScriptedChannel()
        channel.answers = [200]
        let stream = channel.stream()
        let feed = ScriptedFeed()
        feed.answers = [.loaded(try feedData)]
        let reader = TicketEventsReader(get: feed.get)
        reader.listen(to: stream)
        stream.start()
        await settle { stream.state == .connected }
        reader.follow(identifier: "SHOP-410", repoKey: "web-shop")
        await reader.settle()

        feed.holding = true
        channel.notice("SHOP-410")
        await settle { feed.paths.count == 2 }
        var heard = 0
        stream.notices.sink { _ in heard += 1 }.store(in: &cancellables)
        channel.notice("SHOP-410")
        channel.notice("SHOP-410", repoKey: nil)
        channel.notice("SHOP-410")
        await settle { heard == 3 }
        XCTAssertEqual(feed.paths.count, 2)
        feed.release()
        await reader.settle()

        XCTAssertEqual(feed.paths.count, 3)
        stream.stop()
    }

    func testReadsAfterEachStatePollOnlyWhileTheChannelIsDown() async throws {
        let channel = ScriptedChannel()
        channel.answers = [200, 200]
        let stream = channel.stream()
        let feed = ScriptedFeed()
        feed.answers = [.loaded(try feedData)]
        let reader = TicketEventsReader(get: feed.get)
        reader.listen(to: stream)
        stream.start()
        await settle { stream.state == .connected }
        reader.follow(identifier: "SHOP-410", repoKey: "web-shop")
        await reader.settle()
        reader.statePolled()
        XCTAssertEqual(feed.paths.count, 1)

        // The connection drops: each state poll reads what is new until it is back.
        channel.body?.finish()
        await settle { stream.state == .reconnecting(after: 1) }
        reader.statePolled()
        await reader.settle()
        reader.statePolled()
        await reader.settle()
        XCTAssertEqual(feed.paths.count, 3)

        // It reconnects: one read of what was written meanwhile, and no more reads on the poll.
        try XCTUnwrap(channel.retry)()
        await settle { stream.state == .connected }
        await settle { feed.paths.count == 4 }
        await reader.settle()
        XCTAssertEqual(feed.paths.count, 4)
        reader.statePolled()
        XCTAssertEqual(feed.paths.count, 4)
        stream.stop()
    }

    func testWithoutTheChannelEachStatePollReadsWhatIsNew() async throws {
        // An older Symphony answers the channel 404.
        let channel = ScriptedChannel()
        channel.answers = [404]
        let stream = channel.stream()
        let feed = ScriptedFeed()
        feed.answers = [.loaded(try feedData)]
        let reader = TicketEventsReader(get: feed.get)
        reader.listen(to: stream)
        stream.start()
        await settle { stream.state == .unavailable }
        reader.follow(identifier: "SHOP-410", repoKey: "web-shop")
        await reader.settle()

        for _ in 0 ..< 3 {
            reader.statePolled()
            await reader.settle()
        }
        XCTAssertEqual(feed.paths.count, 4)
        XCTAssertTrue(feed.paths.dropFirst().allSatisfy { $0.hasSuffix("since=2026-10-18T11:13:00.000000Z") })
    }
}
