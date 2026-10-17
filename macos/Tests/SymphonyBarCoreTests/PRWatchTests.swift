import Foundation
import XCTest
@testable import SymphonyBarCore

/// S15, S16, S17: the PR and CI watcher's block as the app decodes it, the ticket page's PR and CI card, the silent
/// wait in Needs attention, the evidence behind a watcher decision and Check Now.
final class PRWatchTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let reference = SymphonyState.parseDate("2026-10-16T12:04:12Z")!

    // MARK: - Decoding

    func testTheAppDecodesTheAPIsWatchBlockContract() throws {
        // `test/fixtures/api/watch_block.json` is the block the API's tests compare against.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("test/fixtures/api/watch_block.json")
        let watch = try XCTUnwrap(WatchBlock.decode(try Data(contentsOf: url)))

        XCTAssertEqual(watch.phase, "rework")
        XCTAssertEqual(watch.head, "abc123")
        XCTAssertEqual(watch.prURL, URL(string: "https://github.com/acme/app/pull/42"))
        XCTAssertEqual(watch.source, "poll")
        XCTAssertEqual(watch.rule, "R26")
        XCTAssertEqual(watch.action, "dispatch")
        XCTAssertEqual(watch.owner, "symphony")
        XCTAssertEqual(watch.clearsWhen, "a run starts on the ticket")
        XCTAssertEqual(watch.since, SymphonyState.parseDate("2026-10-16T11:59:30Z"))
        XCTAssertEqual(watch.readAt, SymphonyState.parseDate("2026-10-16T12:00:00Z"))
        XCTAssertEqual(watch.summary, "PR #42 open · CI green · no conflict")
        XCTAssertEqual(watch.facts.pr, "open")
        XCTAssertEqual(watch.facts.prNumber, 42)
        XCTAssertEqual(watch.facts.ci, "green")
        XCTAssertEqual(watch.facts.mergeable, "clean")
        XCTAssertEqual(watch.facts.redAttempts, 0)
        XCTAssertEqual(watch.facts.maxRedAttempts, 10)
        XCTAssertEqual(watch.facts.conflictAttempts, 0)
        XCTAssertEqual(watch.actions, [WatchBlock.Action(rule: "R21", action: "ci_fix", head: "abc000", at: SymphonyState.parseDate("2026-10-16T11:50:00Z"), source: "poll")])
        XCTAssertEqual(watch.silent, WatchBlock.Silent(
            since: SymphonyState.parseDate("2026-10-16T11:59:30Z"), ticks: 2, bound: nil,
            reason: "R26 decided `dispatch`, but no run started and no wait is recorded"
        ))
        XCTAssertEqual(watch.waitsOn, [])

        let card = try XCTUnwrap(PRWatchCard(watch: watch, reference: reference, timeZone: utc))
        XCTAssertEqual(card.status, .problem)
        XCTAssertEqual(card.word, "Needs attention")
        XCTAssertEqual(card.headline, "Rework: PR #42 is not red and not conflicting, and no run is active")
        XCTAssertEqual(card.warning, "nothing is running and nothing says why")
        XCTAssertEqual(card.next, "Symphony acts next")
        XCTAssertEqual(card.clears, "until a run starts on the ticket")
        XCTAssertEqual(card.age, "4 min")
        XCTAssertEqual(card.updated, "Updated 4 min ago · check")
        XCTAssertEqual(card.help, "Rule R26: Rework: PR #42 is not red and not conflicting, and no run is active")
    }

    func testTheStateGivesEachWatchedTicketsBlockItsSilentWaitsAndGitHubsRateLimit() throws {
        let state = WatchState.decode(json([
            "issues": [
                ["issue_id": "i-1", "identifier": "T-1", "repo_key": "web", "watch": block(["rule": "R24"])],
                ["issue_id": "i-2", "identifier": "T-2", "watch": NSNull()],
            ],
            "silent_waits": [
                ["issue_id": "i-5", "identifier": "T-5", "repo_key": "web", "phase": "rework", "pr_url": "https://github.com/acme/web/pull/5",
                 "since": "2026-10-16T12:00:00Z", "rule": "R26", "bound": NSNull(), "reason": "quiet"],
                ["phase": "qa"],
            ],
            "rate_limit": ["remaining": 4_321, "limit": 5_000, "reset": "2026-10-16T13:00:00Z"],
        ]))

        XCTAssertEqual(Array(state.watches.keys), ["T-1"])
        XCTAssertEqual(state.watches["T-1"]?.rule, "R24")
        XCTAssertEqual(state.silentWaits, [WatchState.SilentWait(
            issueID: "i-5", identifier: "T-5", repoKey: "web", phase: "rework", prURL: URL(string: "https://github.com/acme/web/pull/5"),
            since: SymphonyState.parseDate("2026-10-16T12:00:00Z"), rule: "R26", bound: nil, reason: "quiet"
        )])
        XCTAssertEqual(state.rateLimit, WatchState.RateLimit(remaining: 4_321, limit: 5_000, reset: SymphonyState.parseDate("2026-10-16T13:00:00Z")))

        // A Symphony that predates the watcher, or no JSON at all.
        XCTAssertEqual(WatchState.decode(json(["running": []])), WatchState())
        XCTAssertEqual(WatchState.decode(Data("nope".utf8)), WatchState())
        XCTAssertNil(WatchBlock.decode(Data("nope".utf8)))
        XCTAssertNil(WatchBlock.decode(carriedIn: json(["watch": NSNull()])))
    }

    func testTheNewestReadWinsAndAnUndatedBlockLosesToADatedOne() {
        let old = WatchBlock(readAt: reference.addingTimeInterval(-60), rule: "R24")
        let new = WatchBlock(readAt: reference, rule: "R27")
        XCTAssertEqual(WatchBlock.newest([old, nil, new])?.rule, "R27")
        XCTAssertEqual(WatchBlock.newest([new, old])?.rule, "R27")
        XCTAssertEqual(WatchBlock.newest([WatchBlock(rule: "R1"), old])?.rule, "R24")
        XCTAssertEqual(WatchBlock.newest([WatchBlock(rule: "R1"), WatchBlock(rule: "R2")])?.rule, "R1")
        XCTAssertNil(WatchBlock.newest([nil]))
    }

    func testPhaseNamesReadAsLinearStates() {
        XCTAssertEqual(WatchBlock.phaseName("in_progress"), "In Progress")
        XCTAssertEqual(WatchBlock.phaseName("code_review"), "Code Review")
        XCTAssertEqual(WatchBlock.phaseName("qa"), "QA")
        XCTAssertEqual(WatchBlock.phaseName("ci_fix"), "CI Fix")
        XCTAssertEqual(WatchBlock.phaseName("rework"), "Rework")
        XCTAssertEqual(WatchBlock.phaseName("merging"), "Merging")
        XCTAssertNil(WatchBlock.phaseName(nil))
        XCTAssertNil(WatchBlock.phaseName(""))
    }

    // MARK: - S15: the PR and CI card

    func testWaitingForCISaysOnWhichHeadWhoActsNextAndBothFixAttemptCounts() throws {
        let card = try card([
            "phase": "code_review", "rule": "R24", "action": "wait", "owner": "ci", "clears_when": "the checks finish",
            "head": "9f8e7d6c5b4a", "since": "2026-10-16T12:00:00Z", "read_at": "2026-10-16T12:04:00Z", "source": "webhook",
            "reason": "Checks are running on PR #42's head",
            "actions": [
                ["rule": "R21", "action": "ci_fix", "head": "1111111aaaa", "at": "2026-10-16T11:30:00Z", "source": "poll"],
                ["rule": "R14", "action": "ci_fix", "head": "2222222bbbb", "at": "2026-10-16T11:45:00Z", "source": "webhook"],
            ],
        ], facts: ["ci": "pending", "mergeable": "clean", "red_attempts": 2, "max_red_attempts": 10, "conflict_attempts": 1])

        XCTAssertEqual(card.status, .idle)
        XCTAssertEqual(card.word, "Waiting")
        XCTAssertEqual(card.headline, "Waiting for CI on 9f8e7d6")
        XCTAssertNil(card.warning)
        XCTAssertEqual(card.next, "CI acts next")
        XCTAssertEqual(card.clears, "until the checks finish")
        XCTAssertEqual(card.age, "4 min")
        XCTAssertEqual(card.updated, "Updated 12 s ago · instant update")
        XCTAssertEqual(card.waitingOn, "CI")
        XCTAssertEqual(card.facts.map(\.label), ["PR", "Head", "Checks", "Merge", "Fix attempts"])
        XCTAssertEqual(fact(card, "PR"), "PR #42 · open")
        XCTAssertEqual(card.facts.first?.url, URL(string: "https://github.com/acme/web/pull/42"))
        XCTAssertEqual(fact(card, "Head"), "9f8e7d6")
        XCTAssertEqual(fact(card, "Checks"), "running")
        XCTAssertEqual(fact(card, "Merge"), "no conflict")
        // The newest CI Fix run was for the conflict.
        XCTAssertEqual(fact(card, "Fix attempts"), "Checks 2 of 10 · conflict 1 of 3 · last: conflict with main")
        XCTAssertEqual(card.actions.map(\.text), ["Sent to CI Fix for the conflict", "Sent to CI Fix for the red checks"])
        XCTAssertEqual(card.actions.map(\.source), ["instant update", "check"])
        XCTAssertEqual(card.actions.map(\.timeText), ["11:45", "11:30"])
        XCTAssertEqual(card.actions.first?.help, "Rule R14 on 2222222")
        XCTAssertEqual(card.actions.first?.accessibilityLabel, "11:45, sent to CI Fix for the conflict, by an instant update")
        XCTAssertEqual(card.actions.last?.accessibilityLabel, "11:30, sent to CI Fix for the red checks, by a check")
        XCTAssertEqual(card.buttons, [.checkNow, .openPR(URL(string: "https://github.com/acme/web/pull/42")!)])
        XCTAssertEqual(card.buttons.map(\.title), ["Check Now", "Open PR"])
        XCTAssertEqual(
            card.accessibilityLabel,
            "Waiting. Waiting for CI on 9f8e7d6. CI acts next, until the checks finish. For 4 minutes. Updated 12 s ago · instant update"
        )
    }

    func testTheFixAttemptsNameTheCheckOfTheLastRedRun() throws {
        let red = try card(["rule": "R24", "owner": "ci", "actions": [["rule": "R21", "action": "ci_fix", "at": "2026-10-16T11:30:00Z"]]],
                           facts: ["ci": "pending", "red_attempts": 3, "max_red_attempts": 5, "conflict_attempts": 3,
                                   "fix_failures": [["check": "test", "error": "1 test failed", "head_sha": "abc"]]])
        XCTAssertEqual(fact(red, "Fix attempts"), "Checks 3 of 5 · conflict 3 of 3 · last: test failed")
        XCTAssertEqual(fact(red, "Last failure"), "test: 1 test failed")

        // A red run before any failure was read, and no run at all.
        let unnamed = try card(["actions": [["rule": "R21", "action": "ci_fix"]]], facts: [:])
        XCTAssertEqual(fact(unnamed, "Fix attempts"), "Checks 0 of 10 · conflict 0 of 3 · last: a check failed")
        let failures = try card([:], facts: ["fix_failures": [["check": "lint", "error": "trailing space"]]])
        XCTAssertEqual(fact(failures, "Fix attempts"), "Checks 0 of 10 · conflict 0 of 3 · last: lint failed")
        let none = try card([:], facts: [:])
        XCTAssertEqual(fact(none, "Fix attempts"), "Checks 0 of 10 · conflict 0 of 3")
    }

    func testAWaitOnACompetingTicketNamesItAndTheFileTheyShare() throws {
        let card = try card([
            "phase": "merging", "rule": "R14a", "action": "wait_for_competitors", "owner": "symphony",
            "clears_when": "every PR ahead lands or leaves the race",
            "waits_on": [["identifier": "T-1", "kind": "competitor", "pr_url": "https://github.com/acme/web/pull/1", "shared_files": 1, "files": ["SPEC.md"]]],
        ], facts: ["mergeable": "dirty", "hold": "blocked"])

        XCTAssertEqual(card.headline, "Waiting on T-1 to land · they change the same file (SPEC.md)")
        XCTAssertEqual(card.waitingOn, "T-1 to land")
        XCTAssertEqual(card.status, .idle)
        XCTAssertEqual(card.next, "Symphony acts next")
        XCTAssertEqual(card.clears, "until every PR ahead lands or leaves the race")
        XCTAssertEqual(card.competitors, [])
        XCTAssertEqual(fact(card, "Merge"), "conflicts with the base branch")
        XCTAssertEqual(fact(card, "Auto-merge"), "off")
        XCTAssertEqual(card.buttons.last, .openTicket("T-1"))
        XCTAssertEqual(card.buttons.last?.title, "Open T-1")

        let twoFiles = try self.card(["waits_on": [["identifier": "T-1", "kind": "competitor", "files": ["SPEC.md", "README.md"]]]], facts: [:])
        XCTAssertEqual(twoFiles.headline, "Waiting on T-1 to land · they change the same files (SPEC.md, README.md)")
    }

    func testAWaitOnTwoCompetingTicketsListsEachWithItsSharedFiles() throws {
        let card = try card([
            "rule": "R15", "action": "wait_for_competitors",
            "waits_on": [
                ["identifier": "T-1", "kind": "competitor", "pr_url": "https://github.com/acme/web/pull/1", "files": ["SPEC.md"]],
                ["identifier": "PR #12", "kind": "competitor", "pr_url": "https://github.com/acme/web/pull/12", "files": ["SPEC.md", "lib/a.ex"]],
                ["identifier": "PR #13", "kind": "competitor", "files": ["lib/b.ex"]],
            ],
        ], facts: ["mergeable": "dirty"])

        XCTAssertEqual(card.headline, "Waiting on T-1, PR #12 and PR #13 to land · they change the same files")
        XCTAssertEqual(card.competitors, [
            PRWatchCard.Competitor(name: "T-1", files: ["SPEC.md"]),
            PRWatchCard.Competitor(name: "PR #12", files: ["SPEC.md", "lib/a.ex"]),
            PRWatchCard.Competitor(name: "PR #13", files: ["lib/b.ex"]),
        ])
        // A person's PR opens on GitHub; one with no URL gets no button.
        XCTAssertEqual(Array(card.buttons.dropFirst(2)), [
            .openTicket("T-1"), .openPullRequest("PR #12", URL(string: "https://github.com/acme/web/pull/12")!),
        ])
        XCTAssertEqual(card.buttons.map(\.title).suffix(2), ["Open T-1", "Open PR #12"])
    }

    func testAWaitOnACIFixTicketNamesTheTicketAndTheCheck() throws {
        let card = try card([
            "rule": "R4", "action": "wait", "owner": "symphony", "clears_when": "what it waits on is done and the hold clears",
            "reason": "CI keeps failing: waiting on T-9, a fix ticket for the `test` check",
            "decision": ["args": ["fix_ticket": "T-9", "check": "test"]],
            "waits_on": [["identifier": "T-9", "kind": "fix_ticket"]],
        ], facts: ["hold": "blocked", "ci": "red", "failing_check": "build", "red_attempts": 10, "same_failure_streak": 3])

        XCTAssertEqual(card.headline, "CI keeps failing: waiting on T-9, a fix ticket for the test check")
        XCTAssertEqual(card.status, .problem)
        XCTAssertEqual(card.word, "Held")
        XCTAssertEqual(card.waitingOn, "T-9, a CI fix ticket")
        XCTAssertEqual(card.help, "Rule R4: CI keeps failing: waiting on T-9, a fix ticket for the `test` check")
        XCTAssertEqual(fact(card, "Checks"), "build failing")
        XCTAssertEqual(card.buttons.last, .openTicket("T-9"))
        XCTAssertEqual(card.buttons.last?.title, "Open T-9")

        // Without the decision's check, the last fix run's, then the failing one.
        let fromFailures = try self.card(["waits_on": [["identifier": "T-9", "kind": "fix_ticket"]]],
                                         facts: ["failing_check": "build", "fix_failures": [["check": "lint", "error": "x"]]])
        XCTAssertEqual(fromFailures.headline, "CI keeps failing: waiting on T-9, a fix ticket for the lint check")
        let fromFacts = try self.card(["waits_on": [["identifier": "T-9", "kind": "fix_ticket"]]], facts: ["failing_check": "build"])
        XCTAssertEqual(fromFacts.headline, "CI keeps failing: waiting on T-9, a fix ticket for the build check")
        let unknown = try self.card(["waits_on": [["identifier": "T-9", "kind": "fix_ticket"], ["identifier": "", "kind": "competitor"]]], facts: [:])
        XCTAssertEqual(unknown.headline, "CI keeps failing: waiting on T-9, a fix ticket for the failing check")
    }

    func testOnHoldForADecisionWaitsOnYouAndOpensTheInbox() throws {
        let held = try card(["rule": "R4", "action": "wait", "owner": "person", "clears_when": "a person answers and the hold clears"],
                            facts: ["hold": "needs_decision"])
        XCTAssertEqual(held.status, .you)
        XCTAssertEqual(held.word, "Waiting on you")
        XCTAssertEqual(held.headline, "On hold: waiting on your decision")
        XCTAssertEqual(held.next, "You act next")
        XCTAssertEqual(held.waitingOn, "you")
        XCTAssertTrue(held.buttons.contains(.openInInbox))
        XCTAssertEqual(PRWatchCard.Button.openInInbox.title, "Open in Inbox")

        let asked = try card(["rule": "R18", "action": "decision", "owner": "person",
                              "reason": "Only `protected paths` is red on PR #42, and only a person can clear it"],
                             facts: ["ci": "red", "red_kind": "human_only", "failing_check": "protected paths"], inboxDecision: true)
        XCTAssertEqual(asked.headline, "Waiting on your decision: Only protected paths is red on PR #42, and only a person can clear it")
        XCTAssertEqual(fact(asked, "Checks"), "protected paths failed; only a person clears it")
        XCTAssertTrue(asked.buttons.contains(.openInInbox))
        let unexplained = try card(["action": "decision", "reason": NSNull()], facts: [:])
        XCTAssertEqual(unexplained.headline, "Waiting on your decision: a question in the Inbox")
        XCTAssertFalse(unexplained.buttons.contains(.openInInbox))

        let blocked = try card(["rule": "R4", "owner": "symphony"], facts: ["hold": "blocked"])
        XCTAssertEqual(blocked.headline, "On hold until what it waits on is done")
        XCTAssertEqual(blocked.status, .problem)
        XCTAssertEqual(blocked.word, "Held")
    }

    func testAClosedPRIsSentBackToReworkWithoutAQuestion() throws {
        let card = try card(["phase": "code_review", "rule": "R8", "action": "to_rework", "reason": "PR #42 was closed without merging"],
                            facts: ["pr": "closed"])
        XCTAssertEqual(card.headline, "PR #42 was closed without merging. Sent back to Rework, where the next run opens a new PR from main.")
        XCTAssertEqual(card.status, .problem)
        XCTAssertEqual(card.word, "PR closed")
        XCTAssertEqual(fact(card, "PR"), "PR #42 · closed without merging")
        XCTAssertNil(card.facts.first { $0.label == "Checks" })
        XCTAssertEqual(card.buttons, [.checkNow, .openPR(URL(string: "https://github.com/acme/web/pull/42")!)])

        let inProgress = try self.card(["phase": "in_progress", "rule": "R8", "action": "dispatch"], facts: ["pr": "closed"])
        XCTAssertEqual(inProgress.headline, "PR #42 was closed without merging. The next run opens a new PR from main.")
        let running = try self.card(["rule": "R8", "action": "wait", "owner": "agent"], facts: ["pr": "closed", "run": "active"])
        XCTAssertEqual(running.headline, "PR #42 was closed without merging. The run under way ends first.")
        let unnumbered = try self.card([:], facts: ["pr": "closed", "pr_number": NSNull()])
        XCTAssertEqual(unnumbered.headline, "The PR was closed without merging. Sent back to Rework, where the next run opens a new PR from main.")
    }

    func testAConflictBackAfterThreeFixesWithNoCompetitorIsSentToRework() throws {
        let card = try card(["phase": "code_review", "rule": "R15a", "action": "to_rework"], facts: ["mergeable": "dirty", "conflict_attempts": 3])
        XCTAssertEqual(card.headline, "The conflict with main came back after 3 fix runs and no PR competes: conflict sent to Rework")
        XCTAssertEqual(card.word, "Sent to Rework")
        XCTAssertEqual(fact(card, "Fix attempts"), "Checks 0 of 10 · conflict 3 of 3")
    }

    func testTheOtherRowsSayWhatTheWatcherDoes() throws {
        let run = try card(["rule": "R9", "action": "wait", "owner": "agent", "clears_when": "the run ends"], facts: ["run": "active"])
        XCTAssertEqual(run.headline, "A run is working on it")
        XCTAssertEqual(run.status, .working)
        XCTAssertEqual(run.next, "An agent acts next")

        let base = try card(["rule": "R23", "owner": "ci"], facts: ["ci": "red", "red_kind": "also_red_on_base", "failing_check": "test"])
        XCTAssertEqual(base.headline, "The test check is red on the base branch too: waiting for it to go green there")
        XCTAssertEqual(fact(base, "Checks"), "test failing, on the base branch too")
        let unnamedBase = try card(["rule": "R23"], facts: ["base_ref": "release"])
        XCTAssertEqual(unnamedBase.headline, "A check is red on release too: waiting for it to go green there")

        let fix = try card(["rule": "R21", "action": "ci_fix", "reason": "test failed on PR #42: CI Fix run 3 of 10"], facts: ["ci": "red", "failing_check": "test"])
        XCTAssertEqual(fix.headline, "test failed on PR #42: CI Fix run 3 of 10")
        XCTAssertEqual(fix.word, "Fixing")
        XCTAssertEqual(try card(["action": "ci_fix", "reason": NSNull()], facts: [:]).headline, "Sent to CI Fix")

        let dispatch = try card(["rule": "R27", "action": "dispatch", "owner": "symphony", "reason": "The head is green, so the reviewer runs"], facts: [:])
        XCTAssertEqual(dispatch.headline, "The head is green, so the reviewer runs")
        XCTAssertEqual(dispatch.word, "Moving on")
        XCTAssertEqual(try card(["action": "return_to_origin", "reason": NSNull()], facts: [:]).headline, "Symphony acts on it")

        let merging = try card(["phase": "merging", "rule": "R33", "action": "wait", "owner": "github",
                                "reason": "Branch protection holds PR #42: auto-merge lands it once it is satisfied"],
                               facts: ["mergeable": "blocked", "auto_merge": "armed", "ci": "green"])
        XCTAssertEqual(merging.headline, "Branch protection holds PR #42: auto-merge lands it once it is satisfied")
        XCTAssertEqual(merging.next, "GitHub acts next")
        XCTAssertEqual(fact(merging, "Auto-merge"), "on")
        XCTAssertEqual(fact(merging, "Checks"), "passing")
        XCTAssertEqual(fact(merging, "Merge"), "blocked by branch protection")

        let merged = try card(["rule": "R2", "action": "close_out"], facts: ["pr": "merged"])
        XCTAssertEqual(merged.headline, "PR #42 was merged")
        XCTAssertEqual(merged.status, .done)
        XCTAssertEqual(try card(["rule": "R2"], facts: ["pr": "merged", "pr_number": NSNull()]).headline, "The PR was merged")

        let summary = try card(["reason": NSNull(), "summary": "PR #42 open · CI green"], facts: [:])
        XCTAssertEqual(summary.headline, "PR #42 open · CI green")
        let nothing = try card(["reason": NSNull()], facts: ["pr": "missing"])
        XCTAssertEqual(nothing.headline, "Watching the PR")
        XCTAssertNil(nothing.facts.first { $0.label == "PR" })
        XCTAssertEqual(try card(["reason": NSNull()], facts: [:]).headline, "Watching PR #42")
    }

    func testGitHubsSpentRateLimitSaysWhenItReadsAgain() throws {
        let card = try card(["rule": "R1", "owner": "github"], facts: ["github": "rate_limited", "github_reset_at": "2026-10-16T13:00:00Z"])
        XCTAssertEqual(card.headline, "GitHub's request limit is spent: reading the PR again at 13:00")
        XCTAssertEqual(card.waitingOn, "GitHub's request limit")

        let fromState = try XCTUnwrap(PRWatchCard(
            watch: WatchBlock.decode(json(block(["rule": "R1"]))),
            rateLimit: WatchState.RateLimit(reset: SymphonyState.parseDate("2026-10-16T13:30:00Z")),
            reference: reference, timeZone: utc
        ))
        XCTAssertEqual(fromState.headline, "GitHub's request limit is spent: reading the PR again at 13:30")
        XCTAssertEqual(try self.card(["rule": "R1"], facts: [:]).headline, "GitHub's request limit is spent")
    }

    func testTheFactsTableNamesEveryCheckAndMergeState() throws {
        func checks(_ facts: [String: Any]) throws -> String? { fact(try card([:], facts: facts), "Checks") }
        func merge(_ mergeable: String) throws -> String? { fact(try card([:], facts: ["mergeable": mergeable]), "Merge") }

        XCTAssertEqual(try checks(["ci": "none"]), "no CI (counts as passing)")
        XCTAssertEqual(try checks(["ci": "none", "no_ci": "not_reported"]), "none reported (counts as passing)")
        XCTAssertEqual(try checks(["ci": "required_missing", "missing_checks": ["build", "lint"]]), "build and lint never reported")
        XCTAssertEqual(try checks(["ci": "required_missing"]), "a required check never reported")
        XCTAssertEqual(try checks(["ci": "red", "red_kind": "cancelled", "failing_check": "test"]), "test cancelled")
        XCTAssertEqual(try checks(["ci": "red"]), "a check failing")
        XCTAssertNil(try checks(["ci": "weird"]))
        XCTAssertEqual(try merge("behind"), "behind the base branch")
        XCTAssertEqual(try merge("unstable"), "unstable: a check that isn't required failed")
        XCTAssertEqual(try merge("unknown"), "GitHub is still checking")
        XCTAssertNil(try merge("weird"))
        XCTAssertEqual(fact(try card([:], facts: ["pr": "draft"]), "PR"), "PR #42 · a draft")
        XCTAssertEqual(fact(try card([:], facts: ["pr": "weird"]), "PR"), "PR #42")
        XCTAssertEqual(fact(try card([:], facts: ["head_origin": "person"]), "Head"), "9f8e7d6 · pushed by a person")
    }

    func testTheCardListsTheLastFiveActionsNewestFirst() throws {
        let kinds = ["dispatch", "to_rework", "to_code_review", "to_in_progress", "return_to_origin", "wait_for_competitors", "decision",
                     "rerun_failed", "file_fix_ticket", "update_branch", "merge_now", "arm", "disarm", "land_agent", "close_out", "some_new_kind"]
        let actions: [[String: Any]] = kinds.enumerated().map { index, kind in
            ["rule": "R\(index)", "action": kind, "at": "2026-10-16T11:\(String(format: "%02d", index)):00Z", "source": index.isMultiple(of: 2) ? "poll" : "webhook"]
        }
        let card = try card(["actions": actions + [["action": NSNull()]]], facts: ["failing_check": "test"])
        XCTAssertEqual(card.actions.count, 5)
        XCTAssertEqual(card.actions.map(\.text), ["Some new kind", "Closed out the merged PR", "Started the landing agent", "Turned auto-merge off", "Turned auto-merge on"])

        let all = kinds.map { kind in try? self.card(["actions": [["action": kind]]], facts: ["failing_check": "test"]).actions.first?.text }
        XCTAssertEqual(all, [
            "Started a run", "Sent to Rework", "Sent back to Code Review", "Sent back to In Progress", "Returned with its approvals",
            "Waited on the competing PRs", "Asked you", "Reran the failed checks", "Filed a fix ticket for the test check",
            "Updated the branch from main", "Merged the PR", "Turned auto-merge on", "Turned auto-merge off", "Started the landing agent",
            "Closed out the merged PR", "Some new kind",
        ])
        let undated = try self.card(["actions": [["source": "other"]]], facts: [:]).actions.first
        XCTAssertEqual(undated?.text, "Acted")
        XCTAssertEqual(undated?.timeText, "")
        XCTAssertNil(undated?.source)
        XCTAssertNil(undated?.help)
        XCTAssertEqual(undated?.accessibilityLabel, "acted")
        XCTAssertEqual(try self.card(["actions": [["action": "file_fix_ticket"]]], facts: [:]).actions.first?.text, "Filed a fix ticket for the failing check")
    }

    func testAJustReadBlockSaysJustNowAndABlockWithoutTimesSaysNothingOfThem() throws {
        let fresh = try card(["read_at": "2026-10-16T12:04:12Z", "source": "check"], facts: [:])
        XCTAssertEqual(fresh.updated, "Updated just now · check")
        let bare = try XCTUnwrap(PRWatchCard(watch: WatchBlock(reason: "Something"), reference: reference))
        XCTAssertNil(bare.updated)
        XCTAssertNil(bare.age)
        XCTAssertNil(bare.next)
        XCTAssertNil(bare.clears)
        XCTAssertEqual(bare.help, "Something")
        XCTAssertEqual(bare.buttons, [.checkNow])
        XCTAssertEqual(bare.accessibilityLabel, "Waiting. Something")
    }

    func testAnUnwatchedTicketHasNoCard() {
        XCTAssertNil(PRWatchCard(watch: nil, reference: reference))
    }

    func testASilentWaitSaysWhyByItsBound() {
        XCTAssertEqual(PRWatchCard.silentSentence(bound: nil), "nothing is running and nothing says why")
        XCTAssertEqual(PRWatchCard.silentSentence(bound: "ci.merging_wait_timeout_ms"), "CI has been running longer than the wait allows, and nothing says why")
        XCTAssertEqual(PRWatchCard.silentSentence(bound: "rate_limit_reset"), "GitHub's request limit should have reset by now, and nothing has read the PR since")
    }

    // MARK: - The ticket page

    func testTheTicketPageShowsTheNewestBlockAndItsWaitInTheMergingLine() throws {
        let competing = block([
            "phase": "merging", "rule": "R14a", "read_at": "2026-10-16T12:00:00Z",
            "waits_on": [["identifier": "T-1", "kind": "competitor", "files": ["SPEC.md"]]],
        ])
        let state = json([
            "generated_at": "2026-10-16T12:04:12Z",
            "watching": [["issue_identifier": "T-2", "state": "Merging"]],
            "issues": [["identifier": "T-2", "watch": competing]],
        ])
        let page = TicketPage(identifier: "T-2", sources: TicketPage.Sources(state: state), timeZone: utc)
        XCTAssertEqual(page.watch?.headline, "Waiting on T-1 to land · they change the same file (SPEC.md)")
        XCTAssertEqual(page.phaseSentence, "Waiting on T-1 to land")
        XCTAssertNil(page.facts.first { $0.label == "Lands after" })

        // The ticket's own endpoint read later wins, and Check Now's answer, newer still, wins over both.
        let issue = json(["watch": block(["phase": "merging", "rule": "R32", "owner": "ci", "read_at": "2026-10-16T12:02:00Z"], facts: ["ci": "pending"])])
        let check = json(["issue_identifier": "T-2", "watch": block(["rule": "R29", "action": "merge_now", "reason": "PR #42 is green and can merge", "read_at": "2026-10-16T12:04:10Z"])])
        let fromIssue = TicketPage(identifier: "T-2", sources: TicketPage.Sources(state: state, issue: issue), timeZone: utc)
        XCTAssertEqual(fromIssue.watch?.headline, "Waiting for CI on 9f8e7d6")
        XCTAssertEqual(fromIssue.phaseSentence, "Waiting on CI")
        let checked = TicketPage(identifier: "T-2", sources: TicketPage.Sources(state: state, issue: issue, check: check, inboxDecision: true), timeZone: utc)
        XCTAssertEqual(checked.watch?.headline, "PR #42 is green and can merge")
        XCTAssertEqual(checked.watch?.updated, "Updated 2 s ago · check")
        XCTAssertTrue(checked.watch?.buttons.contains(.openInInbox) == true)

        let unwatched = TicketPage(identifier: "T-3", sources: TicketPage.Sources(state: state), timeZone: utc)
        XCTAssertNil(unwatched.watch)
    }

    // MARK: - S17: the silent wait in Needs attention

    func testASilentWaitIsAnAttentionRowWithCheckNowFirst() {
        let state = OverviewState(
            generatedAt: reference,
            silentWaits: [
                WatchState.SilentWait(identifier: "T-5", repoKey: "web", phase: "rework", since: reference.addingTimeInterval(-300), rule: "R26"),
                WatchState.SilentWait(identifier: "T-6", repoKey: "api", phase: "merging", bound: "ci.merging_wait_timeout_ms"),
                WatchState.SilentWait(identifier: "T-7", bound: "rate_limit_reset"),
            ]
        )
        let overview = Overview(state: state, now: reference)
        XCTAssertEqual(overview.mood, .attention)
        XCTAssertEqual(overview.sentence, "3 things need attention.")
        XCTAssertEqual(overview.problems.map(\.sentence), [
            "T-5 in Rework: nothing is running and nothing says why.",
            "T-6 in Merging: CI has been running longer than the wait allows, and nothing says why.",
            "T-7: GitHub's request limit should have reset by now, and nothing has read the PR since.",
        ])
        let row = overview.problems[0]
        XCTAssertEqual(row.kinds, [.silentWait])
        XCTAssertEqual(row.severity, .problem)
        XCTAssertEqual(row.age, "5 min")
        XCTAssertEqual(row.fixes, [.checkNow("T-5"), .openTicket("T-5")])
        XCTAssertEqual(row.fixes.map(\.title), ["Check Now", "Open Ticket"])
        XCTAssertEqual(row.ticketIdentifier, "T-5")

        // Under one repo's scope only its own; the badge counts every repo.
        let scoped = Overview(state: state, scope: .repo("web"), now: reference)
        XCTAssertEqual(scoped.problems.map(\.id), ["T-5", "T-7"])
        XCTAssertEqual(scoped.sentence, "2 things need attention.")
        XCTAssertEqual(Overview.badgeCount(state, now: reference), 3)

        let one = Overview(state: OverviewState(generatedAt: reference, silentWaits: [state.silentWaits[0]]), now: reference)
        XCTAssertEqual(one.sentence, "1 thing needs attention.")
    }

    func testTheOverviewReadsSilentWaitsFromTheState() throws {
        let data = try XCTUnwrap(try? Data(contentsOf: fixtureDirectory("attention").appendingPathComponent("state.json")))
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["silent_waits"] = [["identifier": "SHOP-400", "phase": "rework", "repo_key": "web-shop"]]
        let state = try XCTUnwrap(OverviewState.decode(json(object)))
        XCTAssertEqual(state.silentWaits.map(\.identifier), ["SHOP-400"])
        XCTAssertTrue(Overview(state: state, now: reference).problems.contains { $0.id == "SHOP-400" && $0.kinds == [.silentWait] })
    }

    // MARK: - S16: a watcher decision's evidence, and items that leave by themselves

    func testAProtectedPathsDecisionShowsTheFailingCheckAndTheFilesThePRChanges() throws {
        let watch = try XCTUnwrap(WatchBlock.decode(json(block(
            ["rule": "R4", "actions": [["rule": "R18", "action": "decision", "at": "2026-10-16T11:58:00Z"]]],
            facts: ["hold": "needs_decision", "ci": "red", "red_kind": "human_only", "failing_check": "protected paths",
                    "protected_files": ["WORKFLOW.md", "config/settings_ui_exempt.yml"]]
        ))))
        let evidence = try XCTUnwrap(WatcherEvidence(item: decision("T-4"), watch: watch))
        XCTAssertEqual(evidence.subject, "Protected files changed")
        XCTAssertEqual(evidence.help, "Rule R18")
        XCTAssertEqual(evidence.rows, [
            WatcherEvidence.Row(label: "Failing check", values: ["protected paths on 9f8e7d6"]),
            WatcherEvidence.Row(label: "Protected files the PR changes", values: ["WORKFLOW.md", "config/settings_ui_exempt.yml"], monospaced: true),
        ])
        XCTAssertEqual(evidence.rows[1].accessibilityLabel, "Protected files the PR changes: WORKFLOW.md, config/settings_ui_exempt.yml")

        // A Symphony that doesn't list the files yet still names the check.
        let unlisted = try XCTUnwrap(WatcherEvidence(item: decision("T-4"), watch: WatchBlock(head: nil, rule: "R18", action: "decision")))
        XCTAssertEqual(unlisted.rows, [WatcherEvidence.Row(label: "Failing check", values: ["protected paths"])])
    }

    func testTheOtherWatcherDecisionsShowTheirEvidence() throws {
        let missing = try XCTUnwrap(WatcherEvidence(item: decision("T-4"), watch: WatchBlock(
            head: "abcdef1234", rule: "R17", action: "decision", facts: WatchBlock.Facts(missingChecks: ["build", "lint"])
        )))
        XCTAssertEqual(missing.subject, "A required check never reported")
        XCTAssertEqual(missing.rows, [
            WatcherEvidence.Row(label: "Required checks that never reported", values: ["build", "lint"]),
            WatcherEvidence.Row(label: "Head", values: ["abcdef1"], monospaced: true),
        ])
        let unnamed = try XCTUnwrap(WatcherEvidence(item: decision("T-4"), watch: WatchBlock(rule: "R17", action: "decision")))
        XCTAssertEqual(unnamed.rows, [WatcherEvidence.Row(label: "Required checks that never reported", values: ["a required check"])])

        let base = try XCTUnwrap(WatcherEvidence(item: decision("T-4"), watch: WatchBlock(
            rule: "R7", action: "decision", facts: WatchBlock.Facts(prNumber: 42, baseRef: "release")
        )))
        XCTAssertEqual(base.subject, "The PR merges into another branch")
        XCTAssertEqual(base.rows, [WatcherEvidence.Row(label: "PR #42 merges into", values: ["release"], monospaced: true)])
        let unnamedBase = try XCTUnwrap(WatcherEvidence(item: decision("T-4"), watch: WatchBlock(rule: "R7", action: "decision")))
        XCTAssertEqual(unnamedBase.rows, [WatcherEvidence.Row(label: "The pull request merges into", values: ["another branch"], monospaced: true)])

        let noPR = try XCTUnwrap(WatcherEvidence(item: decision("T-4"), watch: WatchBlock(rule: "R6", action: "decision")))
        XCTAssertEqual(noPR.subject, "No pull request")
        XCTAssertEqual(noPR.rows, [WatcherEvidence.Row(label: "Pull request", values: ["None found for the ticket"])])
    }

    func testTheSelfHealEscalationShowsEachFixRunsErrorLine() throws {
        let watch = WatchBlock(
            rule: "R4",
            facts: WatchBlock.Facts(hold: "needs_decision", redAttempts: 3, maxRedAttempts: 10, fixFailures: [
                WatchBlock.Failure(check: "test", error: "1 test failed", head: "aaaaaaa111"),
                WatchBlock.Failure(check: "test", error: nil, head: nil),
                WatchBlock.Failure(check: "test", error: "1 test failed", head: "bbbbbbb222"),
            ]),
            actions: [WatchBlock.Action(rule: "R20", action: "file_fix_ticket", at: reference)]
        )
        let evidence = try XCTUnwrap(WatcherEvidence(item: decision("T-4"), watch: watch))
        XCTAssertEqual(evidence.subject, "The same check failed again after its fix landed")
        XCTAssertEqual(evidence.help, "Rule R20")
        XCTAssertEqual(evidence.rows, [
            WatcherEvidence.Row(label: "Failing check", values: ["test"]),
            WatcherEvidence.Row(label: "Error lines", values: ["aaaaaaa · 1 test failed", "bbbbbbb · 1 test failed"], monospaced: true),
            WatcherEvidence.Row(label: "CI Fix runs", values: ["3 of 10"]),
        ])

        let bare = try XCTUnwrap(WatcherEvidence(item: decision("T-4"), watch: WatchBlock(
            facts: WatchBlock.Facts(hold: "needs_decision"), actions: [WatchBlock.Action(action: "file_fix_ticket")]
        )))
        XCTAssertEqual(bare.rows, [WatcherEvidence.Row(label: "Failing check", values: ["a check"]), WatcherEvidence.Row(label: "CI Fix runs", values: ["0 of 10"])])
    }

    func testOnlyAWatcherDecisionHasEvidence() {
        let watch = WatchBlock(rule: "R18", action: "decision")
        XCTAssertNil(WatcherEvidence(item: decision("T-4"), watch: nil))
        XCTAssertNil(WatcherEvidence(item: InboxItem(id: "i-4", identifier: "T-4", kind: .action, ask: "Do this"), watch: watch))
        XCTAssertNil(WatcherEvidence(item: decision("T-4"), watch: WatchBlock(rule: "R24", action: "wait")))
        XCTAssertNil(WatcherEvidence(item: decision("T-4"), watch: WatchBlock(rule: "R99", action: "decision")))
    }

    func testAWatcherDecisionThatClearedByItselfLeavesWithTheReason() {
        let watches = [
            "T-4": WatchBlock(reason: "Checks are running on PR #42's head"),
            "T-6": WatchBlock(),
        ]
        let previous = [decision("T-4"), decision("T-5"), decision("T-6"), decision("T-7"), InboxItem(id: "i-8", identifier: "T-8", kind: .plan, ask: "Review")]
        let banners = WatcherDeparture.banners(
            previous: previous, current: [decision("T-7")], answered: ["i-5"], watches: watches.merging(["T-5": WatchBlock(), "T-8": WatchBlock()]) { $1 }
        )
        XCTAssertEqual(banners, [
            InboxBanner(itemID: "i-4", identifier: "T-4", text: "No longer needs you: Checks are running on PR #42's head", undo: false, style: .info),
            InboxBanner(itemID: "i-6", identifier: "T-6", text: "No longer needs you", undo: false, style: .info),
        ])
    }

    func testSendingAWatcherDecisionSelectsTheNextItemThoughTheTicketStaysInPlace() {
        var item = decision("T-4")
        item.review.action?.commentID = "c-4"
        let sheet = ConsequenceSheet(move: .decide, item: item, picks: DecisionPicks(picks: [0: 0]))
        XCTAssertFalse(sheet.expectedOutcome.moved)
        XCTAssertTrue(sheet.selectsNext(after: sheet.expectedOutcome))
        // A move that isn't an answer selects the next item only once the ticket moved.
        let unblock = ConsequenceSheet(move: .unblock, item: InboxItem(id: "i-9", identifier: "T-9", kind: .blocked, ask: "Unblock"))
        XCTAssertFalse(unblock.selectsNext(after: unblock.expectedOutcome))
        XCTAssertTrue(unblock.selectsNext(after: MoveOutcome(moved: true, toState: "Todo")))
    }

    // MARK: - Check Now

    func testCheckNowPostsToTheTicketsWatchAndReadsTheAnswer() async throws {
        XCTAssertEqual(WatchCheck.path("TP-946"), "api/v1/issues/TP-946/watch/check")
        XCTAssertEqual(WatchCheck.path("a/b c"), "api/v1/issues/a%2Fb%20c/watch/check")
        let request = WatchCheck.request("TP-946", base: URL(string: "http://127.0.0.1:4000")!)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:4000/api/v1/issues/TP-946/watch/check")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let body = json(["watch": block([:])])
        XCTAssertEqual(WatchCheck.result("T-1", statusCode: 200, data: body), .checked(body))
        XCTAssertEqual(WatchCheck.result("T-1", statusCode: 404, data: Data()), .failed("Couldn't check T-1 now: Symphony doesn't watch its pull request"))
        XCTAssertEqual(
            WatchCheck.result("T-1", statusCode: 503, data: json(["error": ["message": "Watcher is busy"]])),
            .failed("Couldn't check T-1 now: Watcher is busy (HTTP 503)")
        )
        XCTAssertEqual(WatchCheck.result("T-1", statusCode: 500, data: Data()), .failed("Couldn't check T-1 now: (HTTP 500)"))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sent = await WatchCheck.send("T-1", stateRoot: root, fallback: URL(string: "http://symphony.invalid")!) { request in
            XCTAssertEqual(request.url?.path, "/api/v1/issues/T-1/watch/check")
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertEqual(sent, .checked(body))
        let unreachable = await WatchCheck.send("T-1", stateRoot: root, fallback: URL(string: "http://symphony.invalid")!) { _ in throw URLError(.cannotConnectToHost) }
        XCTAssertEqual(unreachable, .failed("Couldn't check T-1 now: nothing answered at http://symphony.invalid"))
        let nowhere = await WatchCheck.send("T-1", stateRoot: root, fallback: nil) { _ in throw URLError(.cannotConnectToHost) }
        XCTAssertEqual(nowhere, .failed("Couldn't check T-1 now: Symphony hasn't said where it listens"))
    }

    func testTheAPIFixturesAnswerCheckNowWithTheirCheckFile() throws {
        let directory = fixtureDirectory("pr-watch").deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = APIFixtures(directory: directory, requestLog: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl"))
        let (data, response) = fixtures.answer(WatchCheck.request("TP-701", base: APIFixtures.baseURL))
        XCTAssertEqual(response.statusCode, 200)
        let watch = try XCTUnwrap(WatchBlock.decode(carriedIn: data))
        XCTAssertEqual(watch.rule, "R24")
    }

    // MARK: - The QA fixture

    func testTheQAFixtureShowsEveryWalkthroughState() throws {
        let api = fixtureDirectory("pr-watch")
        let state = try Data(contentsOf: api.appendingPathComponent("state.json"))
        let inbox = try XCTUnwrap(InboxPayload.decode(try Data(contentsOf: api.appendingPathComponent("inbox.json"))))
        func page(_ identifier: String, check: Data? = nil) throws -> PRWatchCard {
            let issue = try Data(contentsOf: api.appendingPathComponent("\(identifier).json"))
            let decision = inbox.items.contains { $0.identifier == identifier && $0.isDecision }
            return try XCTUnwrap(TicketPage(
                identifier: identifier, sources: TicketPage.Sources(state: state, issue: issue, check: check, inboxDecision: decision), timeZone: utc
            ).watch)
        }

        // Step 1 and 2: waiting for CI, then Check Now's answer.
        let ci = try page("TP-701")
        XCTAssertEqual(ci.headline, "Waiting for CI on 9f8e7d6")
        XCTAssertEqual([ci.next, ci.clears, ci.age], ["CI acts next", "until the checks finish", "4 min"])
        XCTAssertEqual(fact(ci, "Fix attempts"), "Checks 2 of 10 · conflict 1 of 3 · last: conflict with main")
        XCTAssertEqual(ci.updated, "Updated 4 min ago · check")
        let check = try Data(contentsOf: api.appendingPathComponent("issues/TP-701/watch/check.json"))
        XCTAssertEqual(try page("TP-701", check: check).updated, "Updated 3 s ago · check")

        // Step 3: the silent Rework ticket.
        let overview = Overview(state: try XCTUnwrap(OverviewState.decode(state)), now: reference)
        XCTAssertEqual(overview.sentence, "1 thing needs attention.")
        XCTAssertEqual(overview.problems.map(\.sentence), ["TP-702 in Rework: nothing is running and nothing says why."])
        XCTAssertEqual(overview.problems.first?.fixes.map(\.title), ["Check Now", "Open Ticket"])

        // Step 4: the protected-paths decision, its evidence, and the next item after it.
        let list = InboxList(items: inbox.items)
        XCTAssertEqual(list.groups.map(\.title), ["Decisions"])
        let protected = try XCTUnwrap(inbox.items.first { $0.identifier == "TP-703" })
        let watches = WatchState.decode(state).watches
        let evidence = try XCTUnwrap(WatcherEvidence(item: protected, watch: watches["TP-703"]))
        XCTAssertEqual(evidence.rows.last?.values, ["WORKFLOW.md", "config/settings_ui_exempt.yml"])
        XCTAssertEqual(protected.review.action?.options.first { $0.recommended }?.label, "Drop the change in Rework")
        XCTAssertEqual(list.neighbor(of: protected.id)?.identifier, "TP-706")
        XCTAssertTrue(try page("TP-703").buttons.contains(.openInInbox))

        // Steps 5 to 7: no Inbox item for any of them.
        let competing = try page("TP-704")
        XCTAssertEqual(competing.headline, "Waiting on TP-705 to land · they change the same file (SPEC.md)")
        XCTAssertTrue(competing.buttons.contains(.openTicket("TP-705")))
        let fixTicket = try page("TP-707")
        XCTAssertEqual(fixTicket.headline, "CI keeps failing: waiting on TP-708, a fix ticket for the test check")
        XCTAssertTrue(fixTicket.buttons.contains(.openTicket("TP-708")))
        let closed = try page("TP-709")
        XCTAssertEqual(closed.headline, "PR #709 was closed without merging. Sent back to Rework, where the next run opens a new PR from main.")
        XCTAssertTrue(closed.buttons.contains(.openPR(URL(string: "https://github.com/tonypine/symphony/pull/709")!)))
        XCTAssertFalse(inbox.items.contains { ["TP-704", "TP-707", "TP-709"].contains($0.identifier) })
    }

    // MARK: - Helpers

    /// A watch block as the API serves it, on PR #42 of acme/web, with `overrides` and the facts' `facts` merged in.
    private func block(_ overrides: [String: Any], facts: [String: Any] = [:]) -> [String: Any] {
        var factsObject: [String: Any] = ["pr": "open", "pr_number": 42]
        factsObject.merge(facts) { $1 }
        var object: [String: Any] = [
            "phase": "code_review", "head": "9f8e7d6c5b4a", "pr_url": "https://github.com/acme/web/pull/42", "source": "poll",
            "read_at": "2026-10-16T12:04:00Z", "reason": "Something", "facts": factsObject, "actions": [],
        ]
        object.merge(overrides) { $1 }
        return object
    }

    private func card(_ overrides: [String: Any], facts: [String: Any], inboxDecision: Bool = false) throws -> PRWatchCard {
        try XCTUnwrap(PRWatchCard(watch: WatchBlock.decode(json(block(overrides, facts: facts))), inboxDecision: inboxDecision, reference: reference, timeZone: utc))
    }

    private func fact(_ card: PRWatchCard, _ label: String) -> String? { card.facts.first { $0.label == label }?.value }

    /// A watcher decision in the Inbox on ticket `identifier`.
    private func decision(_ identifier: String) -> InboxItem {
        InboxItem(
            id: "i-\(identifier.dropFirst(2))", identifier: identifier, kind: .action, ask: "Decide",
            review: InboxReview(action: InboxReview.Action(
                title: "Protected files changed", question: "How should it continue?", why: nil, unblocks: nil, steps: [],
                options: [InboxReview.Action.Option(label: "Drop the change in Rework", effect: nil, recommended: true)]
            ))
        )
    }

    private func fixtureDirectory(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/\(name)/api/v1")
    }

    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
}
