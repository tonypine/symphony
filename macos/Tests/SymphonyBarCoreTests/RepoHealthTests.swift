import XCTest
@testable import SymphonyBarCore

final class RepoHealthTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-04T14:10:00Z")!

    private func ago(_ seconds: TimeInterval) -> Date {
        now.addingTimeInterval(-seconds)
    }

    private func repo(
        source: RepoStatus.Source = .local(path: "/Projects/app"),
        baseBranch: String? = "main",
        github: String? = "acme/app",
        workflow: RepoStatus.Workflow = .init(path: "/Projects/app/WORKFLOW.md", state: .valid),
        lastFetch: RepoStatus.Fetch? = nil,
        worktrees: [RepoStatus.Worktree] = []
    ) -> RepoStatus {
        RepoStatus(
            key: "app",
            baseBranch: baseBranch,
            source: source,
            github: github,
            workflow: workflow,
            lastFetch: lastFetch,
            worktrees: worktrees
        )
    }

    private func health(
        _ repo: RepoStatus,
        warning: String? = nil,
        runs: [StateSnapshot.Run] = [],
        pending: PendingWorkflow? = nil
    ) -> RepoHealth {
        RepoHealth.of(repo, warning: warning, runs: runs, pending: pending, now: now)
    }

    // MARK: - Status and summary

    func testAHealthyRepo() {
        let healthy = health(repo(lastFetch: .init(at: ago(60), succeeded: true)))

        XCTAssertEqual(healthy, RepoHealth(status: .healthy))
        XCTAssertEqual(healthy.summary, "Healthy")
        XCTAssertFalse(healthy.showsBox)
        XCTAssertEqual(healthy.status.spoken, "healthy")
    }

    func testCountsProblemsButNotInformation() {
        let one = health(repo(workflow: .init(state: .missing)), warning: "Snapshot timed out")
        XCTAssertEqual(one.status, .needsAttention)
        XCTAssertEqual(one.problemCount, 1)
        XCTAssertEqual(one.summary, "1 problem")
        XCTAssertTrue(one.showsBox)

        let two = health(repo(workflow: .init(state: .invalid, error: "bad"), lastFetch: .init(succeeded: false)))
        XCTAssertEqual(two.status, .notWorking)
        XCTAssertEqual(two.summary, "2 problems")
    }

    func testInformationAloneIsHealthyAndShowsNoBox() {
        let shown = health(
            repo(source: .managed(github: "acme/app", clonePath: nil, cloned: false)),
            warning: "Snapshot timed out"
        )

        XCTAssertEqual(shown.status, .healthy)
        XCTAssertEqual(shown.summary, "Healthy")
        XCTAssertFalse(shown.showsBox)
        XCTAssertEqual(
            shown.problems,
            [
                .init(id: "agents", severity: .info, title: "Symphony couldn't list its running agents", detail: "Snapshot timed out"),
                .init(id: "clone", severity: .info, title: "Not cloned yet: Symphony clones it on the next dispatch"),
            ]
        )
    }

    func testOrdersErrorsThenWarningsThenInformation() {
        let shown = health(
            repo(
                workflow: .init(state: .missing),
                lastFetch: .init(succeeded: false),
                worktrees: [.init(issueIdentifier: "TP-1")]
            ),
            warning: "partial",
            runs: [.init(issueIdentifier: "TP-1", lastEventAt: ago(3_600))]
        )

        XCTAssertEqual(shown.problems.map(\.id), ["fetch", "workflow", "stuck-TP-1", "agents"])
        XCTAssertEqual(shown.status, .notWorking)
        XCTAssertEqual(shown.status.spoken, "not working")
    }

    // MARK: - WORKFLOW.md

    func testAMissingWorkflowIsAWarningWithoutAFixYet() {
        XCTAssertEqual(
            health(repo(workflow: .init(state: .missing, error: "missing_workflow_file"))).problems,
            [.init(id: "workflow", severity: .warning, title: "WORKFLOW.md is missing", detail: "Symphony found no WORKFLOW.md on main.")]
        )
        XCTAssertEqual(
            health(repo(baseBranch: " ", workflow: .init(state: .missing))).problems.first?.detail,
            "Symphony found no WORKFLOW.md on the default branch."
        )
        XCTAssertEqual(health(repo(workflow: .init(state: .missing))).status.spoken, "needs attention")
    }

    func testAnInvalidLocalWorkflowOpensTheFile() {
        XCTAssertEqual(
            health(repo(workflow: .init(path: "/Projects/app/WORKFLOW.md", state: .invalid, error: "malformed yaml"))).problems,
            [
                .init(
                    id: "workflow",
                    severity: .error,
                    title: "WORKFLOW.md is invalid",
                    detail: "malformed yaml",
                    fixes: [.openWorkflow(URL(fileURLWithPath: "/Projects/app/WORKFLOW.md"))]
                ),
            ]
        )
        // Without the file's path, the folder's WORKFLOW.md; without either, no fix.
        XCTAssertEqual(
            health(repo(workflow: .init(state: .invalid))).problems.first?.fixes,
            [.openWorkflow(URL(fileURLWithPath: "/Projects/app/WORKFLOW.md"))]
        )
        XCTAssertEqual(health(repo(source: .local(path: nil), workflow: .init(state: .invalid))).problems.first?.fixes, [])
    }

    func testAnInvalidManagedWorkflowOpensTheFileOnGitHubAtTheBaseBranch() {
        let managed = RepoStatus.Source.managed(github: "acme/app", clonePath: "/Clones/acme/app", cloned: true)
        XCTAssertEqual(
            health(repo(source: managed, baseBranch: "release/2", workflow: .init(path: "/Clones/acme/app/ops/WORKFLOW.md", state: .invalid)))
                .problems.first?.fixes,
            [.openWorkflow(URL(string: "https://github.com/acme/app/blob/release/2/ops/WORKFLOW.md")!)]
        )
        XCTAssertEqual(
            health(repo(source: managed, baseBranch: nil, workflow: .init(path: "/elsewhere/WORKFLOW.md", state: .invalid)))
                .problems.first?.fixes,
            [.openWorkflow(URL(string: "https://github.com/acme/app/blob/HEAD/WORKFLOW.md")!)]
        )
    }

    func testAWorkflowStatusItDoesNotKnowIsNoProblem() {
        XCTAssertEqual(health(repo(workflow: .init(state: .other("loading")))).status, .healthy)
    }

    func testAPendingWorkflowTakesThePlaceOfMissing() {
        let pr = URL(string: "https://github.com/acme/app/pull/12")!
        XCTAssertEqual(
            health(repo(workflow: .init(state: .missing)), pending: .pullRequest(pr)).problems,
            [
                .init(
                    id: "workflow",
                    severity: .warning,
                    title: "WORKFLOW.md is waiting on its pull request",
                    note: "Symphony uses it once the pull request merges into main.",
                    fixes: [.viewPullRequest(pr)]
                ),
            ]
        )
        XCTAssertEqual(
            health(repo(workflow: .init(state: .missing)), pending: .written(path: "/Projects/app/WORKFLOW.md")).problems,
            [
                .init(
                    id: "workflow",
                    severity: .warning,
                    title: "WORKFLOW.md is written but not pushed",
                    detail: "/Projects/app/WORKFLOW.md",
                    note: "Symphony uses it once it is on main.",
                    fixes: [.revealInFinder(path: "/Projects/app/WORKFLOW.md")]
                ),
            ]
        )
    }

    // MARK: - Last fetch

    func testAFailedFetchShowsTheErrorWithCopyAndGitHub() {
        XCTAssertEqual(
            health(repo(lastFetch: .init(at: ago(180), succeeded: false, error: "fatal: Could not read from remote repository."))).problems,
            [
                .init(
                    id: "fetch",
                    severity: .error,
                    title: "The last fetch failed 3m ago",
                    detail: "fatal: Could not read from remote repository.",
                    note: "Symphony tries again before the next dispatch.",
                    fixes: [
                        .copyError("fatal: Could not read from remote repository."),
                        .openOnGitHub(URL(string: "https://github.com/acme/app")!),
                    ]
                ),
            ]
        )
        // Without a time, an error or a GitHub remote.
        XCTAssertEqual(
            health(repo(github: nil, lastFetch: .init(succeeded: false))).problems,
            [.init(id: "fetch", severity: .error, title: "The last fetch failed", note: RepoHealth.fetchRetryNote)]
        )
    }

    func testNoFetchYetIsNoProblem() {
        XCTAssertEqual(health(repo(lastFetch: nil)).status, .healthy)
    }

    // MARK: - Stuck runs

    private let worktree = RepoStatus.Worktree(issueIdentifier: "TP-7", path: "/ws/TP-7")
    private let linear = URL(string: "https://linear.app/t/issue/TP-7")!

    func testARunIsStuckAfterTenMinutesWithoutActivity() {
        let atThreshold = health(
            repo(worktrees: [worktree]),
            runs: [.init(issueIdentifier: "TP-7", url: linear, startedAt: ago(3_600), lastEventAt: ago(600))]
        )
        XCTAssertEqual(
            atThreshold.problems,
            [
                .init(
                    id: "stuck-TP-7",
                    severity: .warning,
                    title: "TP-7 has shown no activity for 10m",
                    note: "Symphony's stall timeout should have restarted it, so it looks stuck.",
                    fixes: [.stopRun(issueIdentifier: "TP-7"), .openInLinear(linear), .revealWorktree(path: "/ws/TP-7")]
                ),
            ]
        )
        XCTAssertEqual(atThreshold.status, .needsAttention)

        let justUnder = health(
            repo(worktrees: [worktree]),
            runs: [.init(issueIdentifier: "TP-7", startedAt: ago(3_600), lastEventAt: ago(599))]
        )
        XCTAssertEqual(justUnder.status, .healthy)
        XCTAssertTrue(justUnder.problems.isEmpty)
    }

    func testARunWithoutEventsCountsFromItsStart() {
        XCTAssertEqual(
            health(repo(worktrees: [worktree]), runs: [.init(issueIdentifier: "TP-7", startedAt: ago(601))]).problems.map(\.id),
            ["stuck-TP-7"]
        )
        XCTAssertEqual(health(repo(worktrees: [worktree]), runs: [.init(issueIdentifier: "TP-7", startedAt: ago(30))]).status, .healthy)
        // Neither time known: nothing to judge.
        XCTAssertEqual(health(repo(worktrees: [worktree]), runs: [.init(issueIdentifier: "TP-7")]).status, .healthy)
    }

    func testARemoteStuckRunHasNoWorktreeToRevealAndNoLinearLinkWithoutAURL() {
        let remote = RepoStatus.Worktree(issueIdentifier: "TP-7", path: "/srv/TP-7", workerHost: "worker-1")
        XCTAssertEqual(
            health(repo(worktrees: [remote]), runs: [.init(issueIdentifier: "TP-7", lastEventAt: ago(7_200))]).problems.first?.fixes,
            [.stopRun(issueIdentifier: "TP-7")]
        )
    }

    func testOnlyTheRepoWorktreesAreJoined() {
        // A stuck run on another repo, and a worktree the state doesn't list.
        let shown = health(
            repo(worktrees: [.init(issueIdentifier: "TP-8")]),
            runs: [.init(issueIdentifier: "TP-7", lastEventAt: ago(7_200))]
        )
        XCTAssertEqual(shown.status, .healthy)
    }

    func testTheProblemGoesOnceItClears() {
        let stuck = health(repo(worktrees: [worktree]), runs: [.init(issueIdentifier: "TP-7", lastEventAt: ago(900))])
        XCTAssertEqual(stuck.status, .needsAttention)

        // The next poll: the agent spoke again, or stopped and left its worktree.
        XCTAssertEqual(health(repo(worktrees: [worktree]), runs: [.init(issueIdentifier: "TP-7", lastEventAt: ago(5))]), RepoHealth(status: .healthy))
        XCTAssertEqual(health(repo(), runs: []), RepoHealth(status: .healthy))
    }

    func testStopRunAsksFirst() {
        let question = RepoHealth.stopQuestion(issueIdentifier: "TP-7")
        XCTAssertEqual(question.title, "Stop the run on TP-7?")
        XCTAssertTrue(question.message.hasPrefix("Symphony stops the agent now."))
        XCTAssertEqual(RepoHealth.stoppedMessage(issueIdentifier: "TP-7"), "Stopped the run on TP-7.")
    }

    // MARK: - Not checked

    func testNotCheckedSaysWhy() {
        let running = SymphonyStatus.running(StateSnapshot(), external: false)
        let cases: [(SymphonyStatus, ReposPoll?, String)] = [
            (.stopped, nil, "Not checked: Symphony is stopped"),
            (.starting, nil, "Not checked: Symphony is starting"),
            (.error("exit 1"), nil, "Not checked: Symphony isn't answering"),
            (running, nil, "Not checked: asking Symphony"),
            (running, .repos([], warning: nil), "Not checked: asking Symphony"),
            (running, .unreachable, "Not checked: Symphony isn't answering"),
            (running, .unsupported, "Not checked: Symphony is too old to report it"),
            (.paused(StateSnapshot(), external: true), .failed("boom"), "Not checked: Symphony couldn't list the repos"),
        ]
        for (status, poll, summary) in cases {
            let health = RepoHealth.notChecked(status: status, poll: poll)
            XCTAssertEqual(health.status, .notChecked)
            XCTAssertEqual(health.summary, summary)
            XCTAssertFalse(health.showsBox)
        }
        XCTAssertEqual(RepoHealth(status: .notChecked).summary, "Not checked")
        XCTAssertEqual(RepoHealth.Status.notChecked.spoken, "not checked")
    }

    // MARK: - Fixes

    func testFixTitles() {
        let url = URL(string: "https://example.com")!
        XCTAssertEqual(
            [
                RepoHealth.Fix.openWorkflow(url), .viewPullRequest(url), .revealInFinder(path: "/a"), .copyError("e"),
                .openOnGitHub(url), .stopRun(issueIdentifier: "TP-1"), .openInLinear(url), .revealWorktree(path: "/a"),
            ].map(\.title),
            [
                "Open WORKFLOW.md", "View Pull Request", "Reveal in Finder", "Copy Error", "Open on GitHub", "Stop Run…",
                "Open in Linear", "Reveal Worktree",
            ]
        )
    }

    // MARK: - Activity lines

    func testActivityLines() {
        XCTAssertEqual(
            ReposList.activityLine(.init(issueIdentifier: "TP-1", startedAt: ago(3_900), lastEventAt: ago(120)), now: now),
            "Running for 1h 5m · last activity 2m ago"
        )
        XCTAssertEqual(ReposList.activityLine(.init(issueIdentifier: "TP-1", startedAt: ago(30)), now: now), "Running for 30s · no activity yet")
        XCTAssertEqual(ReposList.activityLine(.init(issueIdentifier: "TP-1", lastEventAt: ago(60)), now: now), "Last activity 1m ago")
        XCTAssertNil(ReposList.activityLine(.init(issueIdentifier: "TP-1"), now: now))
    }
}
