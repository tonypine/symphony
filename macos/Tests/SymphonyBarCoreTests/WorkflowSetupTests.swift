import XCTest
@testable import SymphonyBarCore

final class WorkflowSetupTests: XCTestCase {
    private let text = "---\nhooks: {}\n---\n\nWork the ticket.\n"

    // MARK: Fake gh

    /// One answer of the fake `gh`: when its arguments, joined by spaces, match the shell `pattern`, it prints
    /// `output` and `error` and exits with `status`.
    private struct Answer {
        var pattern: String
        var output = ""
        var error = ""
        var status: Int32 = 0
    }

    /// A `gh` script that logs each call's arguments, one per line after a `--` line, and answers from `answers`.
    private func fakeGH(_ answers: [Answer]) throws -> (cli: GitHubCLI, calls: () -> [[String]]) {
        let folder = uniqueTemporaryDirectory("fake-gh")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("calls.log")
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
        let cases = answers.map { answer in
            "  \(answer.pattern)) printf '%s' \(quoted(answer.output)); printf '%s' \(quoted(answer.error)) >&2; exit \(answer.status) ;;"
        }
        let script = """
            #!/bin/sh
            { echo --; for argument in "$@"; do printf '%s\\n' "$argument"; done; } >> \(quoted(log.path))
            case "$*" in
            \(cases.joined(separator: "\n"))
              *) echo "fake gh: unexpected $*" >&2; exit 2 ;;
            esac
            """
        let gh = folder.appendingPathComponent("gh")
        try script.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        let calls = { () -> [[String]] in
            let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").components(separatedBy: "\n")
            return lines.split(separator: "--", omittingEmptySubsequences: true).map { Array($0).filter { !$0.isEmpty } }
        }
        return (GitHubCLI.process(gh.path), calls)
    }

    private let baseRef = Answer(pattern: "'api repos/acme/web/git/ref/heads/main --jq .object.sha'", output: "abc123\n")
    private let commit = Answer(pattern: "'api -X PUT repos/acme/web/contents/WORKFLOW.md '*", output: "{}")
    private let pullRequest = Answer(
        pattern: "'pr create --repo acme/web --base main --head symphony/add-workflow'*",
        output: "Creating pull request for symphony/add-workflow into main in acme/web\n\nhttps://github.com/acme/web/pull/7\n"
    )

    private func newBranch(_ name: String, exists: Bool = false) -> Answer {
        Answer(
            pattern: "'api -X POST repos/acme/web/git/refs -f ref=refs/heads/\(name) -f sha=abc123'",
            output: exists ? #"{"message":"Reference already exists"}"# : "{}",
            error: exists ? "gh: Reference already exists (HTTP 422)\n" : "",
            status: exists ? 1 : 0
        )
    }

    // MARK: Pull request

    func testOpensAPullRequestThatAddsTheWorkflow() throws {
        let gh = try fakeGH([baseRef, newBranch("symphony/add-workflow"), commit, pullRequest])

        let result = gh.cli.openWorkflowPullRequest("acme/web", baseBranch: "main", text: text, summary: "Elixir · Mix")

        XCTAssertEqual(result, .success(.pullRequest(url: "https://github.com/acme/web/pull/7")))
        let calls = gh.calls()
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls[0], ["api", "repos/acme/web/git/ref/heads/main", "--jq", ".object.sha"])
        XCTAssertEqual(calls[1], ["api", "-X", "POST", "repos/acme/web/git/refs", "-f", "ref=refs/heads/symphony/add-workflow", "-f", "sha=abc123"])
        XCTAssertEqual(Array(calls[2].prefix(6)), ["api", "-X", "PUT", "repos/acme/web/contents/WORKFLOW.md", "-f", "message=Add WORKFLOW.md for Symphony"])
        XCTAssertEqual(calls[2].last, "branch=symphony/add-workflow")
        let content = try XCTUnwrap(calls[2].first { $0.hasPrefix("content=") }?.dropFirst("content=".count))
        XCTAssertEqual(Data(base64Encoded: String(content)).map { String(decoding: $0, as: UTF8.self) }, text)
        XCTAssertEqual(Array(calls[3].prefix(10)), [
            "pr", "create", "--repo", "acme/web", "--base", "main", "--head", "symphony/add-workflow",
            "--title", "Add WORKFLOW.md for Symphony",
        ])
        XCTAssertEqual(calls[3][10], "--body")
        XCTAssertTrue(calls.joined().contains { $0.contains("(Elixir · Mix)") })
    }

    func testUsesTheNextFreeBranch() throws {
        let gh = try fakeGH([
            baseRef, newBranch("symphony/add-workflow", exists: true), newBranch("symphony/add-workflow-2"), commit,
            Answer(pattern: "'pr create --repo acme/web --base main --head symphony/add-workflow-2'*", output: "https://github.com/acme/web/pull/8\n"),
        ])

        let result = gh.cli.openWorkflowPullRequest("acme/web", baseBranch: "main", text: text, summary: "")

        XCTAssertEqual(result, .success(.pullRequest(url: "https://github.com/acme/web/pull/8")))
        XCTAssertEqual(gh.calls()[3].last, "branch=symphony/add-workflow-2")
    }

    func testSaysWhyThePullRequestCouldNotBeOpened() throws {
        let taken = (1...5).map { newBranch($0 == 1 ? "symphony/add-workflow" : "symphony/add-workflow-\($0)", exists: true) }
        let cases: [([Answer], String)] = [
            ([Answer(pattern: "*", error: "To get started with GitHub CLI, please run:  gh auth login\n", status: 4)],
             "Couldn't read main of acme/web: gh isn't logged in to GitHub. Run `gh auth login`, then try again."),
            ([Answer(pattern: "'api repos/acme/web/git/ref/heads/main'*", output: "\n")],
             "Couldn't read main of acme/web: gh exited with status 0"),
            ([baseRef, Answer(pattern: "'api -X POST'*", error: "gh: Resource not accessible by integration (HTTP 403)\nmore\n", status: 1)],
             "Couldn't make the branch symphony/add-workflow on acme/web: gh: Resource not accessible by integration (HTTP 403)"),
            ([baseRef] + taken,
             "acme/web already has branches symphony/add-workflow to symphony/add-workflow-5. Delete the old ones first."),
            ([baseRef, newBranch("symphony/add-workflow"), Answer(pattern: "'api -X PUT'*", error: "gh: Invalid request (HTTP 422)", status: 1)],
             "Couldn't commit WORKFLOW.md to symphony/add-workflow of acme/web: gh: Invalid request (HTTP 422)"),
            ([baseRef, newBranch("symphony/add-workflow"), commit, Answer(pattern: "'pr create'*", error: "a pull request already exists", status: 1)],
             "Committed WORKFLOW.md to symphony/add-workflow of acme/web, but couldn't open the pull request: a pull request already exists"),
            ([baseRef, newBranch("symphony/add-workflow"), commit, Answer(pattern: "'pr create'*", output: "done\n")],
             "Committed WORKFLOW.md to symphony/add-workflow of acme/web, but couldn't open the pull request: gh exited with status 0"),
        ]
        for (answers, message) in cases {
            let gh = try fakeGH(answers)
            XCTAssertEqual(
                gh.cli.openWorkflowPullRequest("acme/web", baseBranch: "main", text: text, summary: ""),
                .failure(AddRepoProblem(message)),
                message
            )
        }
    }

    func testReportsAGhThatDoesNotRun() {
        let result = GitHubCLI.process("/nonexistent/gh").run(["--version"])
        XCTAssertEqual(result.status, -1)
        XCTAssertTrue(result.error.hasPrefix("Couldn't run /nonexistent/gh:"), result.error)
    }

    // MARK: Probe

    private func cli(_ answers: [String: (Int32, String, String)]) -> (GitHubCLI, () -> [String]) {
        var calls: [String] = []
        let cli = GitHubCLI { arguments in
            let call = arguments.joined(separator: " ")
            calls.append(call)
            return answers[call] ?? (1, "", "gh: Not Found (HTTP 404)\n")
        }
        return (cli, { calls })
    }

    func testProbesTheDefaultBranchAndGuessesTheStack() {
        let (gh, calls) = cli([
            "api repos/acme/web --jq .default_branch": (0, "trunk\n", ""),
            "api repos/acme/web/contents?ref=trunk --jq .[].name": (0, "package.json\npnpm-lock.yaml\nsrc\n", ""),
            "api repos/acme/web/contents/package.json?ref=trunk -H Accept: application/vnd.github.raw":
                (0, #"{"scripts": {"test": "vitest"}}"#, ""),
        ])

        guard case let .success(probe) = gh.probe("acme/web", branch: nil) else { return XCTFail("expected a probe") }

        XCTAssertEqual(probe.defaultBranch, "trunk")
        XCTAssertEqual(probe.branch, "trunk")
        XCTAssertFalse(probe.hasWorkflow)
        XCTAssertEqual(probe.stack.buildTool, "pnpm")
        XCTAssertEqual(probe.stack.test, "pnpm test")
        XCTAssertEqual(calls().count, 3)
    }

    func testProbesTheBranchAskedForAndFindsTheWorkflow() {
        let (gh, _) = cli([
            "api repos/acme/web --jq .default_branch": (0, "main\n", ""),
            "api repos/acme/web/contents?ref=release/2.0 --jq .[].name": (0, "WORKFLOW.md\nmix.exs\n", ""),
        ])

        guard case let .success(probe) = gh.probe("acme/web", branch: " release/2.0 ") else { return XCTFail("expected a probe") }

        XCTAssertEqual(probe.branch, "release/2.0")
        XCTAssertTrue(probe.hasWorkflow)
        XCTAssertEqual(probe.stack.language, "Elixir")
    }

    func testSaysWhyTheRepoCouldNotBeProbed() {
        let (missing, _) = cli([:])
        XCTAssertEqual(missing.probe("acme/web", branch: nil), .failure(AddRepoProblem("Couldn't check acme/web on GitHub: gh: Not Found (HTTP 404)")))

        let (noBranch, _) = cli(["api repos/acme/web --jq .default_branch": (0, "main\n", "")])
        XCTAssertEqual(
            noBranch.probe("acme/web", branch: "dev"),
            .failure(AddRepoProblem("Couldn't list the files on dev of acme/web: gh: Not Found (HTTP 404)"))
        )
    }

    // MARK: Locate

    func testLocatesGh() {
        let executables: Set<String> = ["/fake/gh", "/usr/local/bin/gh", "/home/bin/gh"]
        func locate(_ environment: [String: String]) -> String? {
            GitHubCLI.locate(environment: environment) { executables.contains($0) }
        }

        XCTAssertEqual(locate(["SYMPHONY_BAR_GH": "/fake/gh", "PATH": "/home/bin"]), "/fake/gh")
        XCTAssertNil(locate(["SYMPHONY_BAR_GH": "/missing/gh", "PATH": "/home/bin"]))
        XCTAssertEqual(locate(["SYMPHONY_BAR_GH": " ", "PATH": "/usr/bin:/home/bin"]), "/home/bin/gh")
        XCTAssertEqual(locate(["PATH": "/usr/bin:/bin"]), "/usr/local/bin/gh")
        XCTAssertEqual(locate([:]), "/usr/local/bin/gh")
        XCTAssertNil(GitHubCLI.locate(environment: [:]) { _ in false })
    }

    // MARK: Landing

    func testLandsTheWorkflowTheWayPicked() throws {
        let folder = uniqueTemporaryDirectory("workflow-landing")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let checkout = LocalCheckout(path: folder.path, gitHub: "acme/web", hasWorkflow: false)

        XCTAssertNil(WorkflowLanding.skip.land(text, gitHub: "acme/web", baseBranch: "main", summary: "", checkout: checkout, cli: nil))
        XCTAssertEqual(
            WorkflowLanding.pullRequest.land(text, gitHub: "acme/web", baseBranch: "main", summary: "", checkout: checkout, cli: nil),
            .failure(AddRepoProblem(GitHubCLI.missingMessage))
        )
        XCTAssertEqual(
            WorkflowLanding.localFile.land(text, gitHub: "acme/web", baseBranch: "main", summary: "", checkout: nil, cli: nil),
            .failure(AddRepoProblem("Choose the folder of a git checkout."))
        )

        let written = WorkflowLanding.localFile.land(text, gitHub: "acme/web", baseBranch: "main", summary: "", checkout: checkout, cli: nil)
        XCTAssertEqual(written, .success(.localFile(path: checkout.workflowPath)))
        XCTAssertEqual(try String(contentsOfFile: checkout.workflowPath, encoding: .utf8), text)

        // Never over an existing file.
        let again = checkout.writeWorkflow("other")
        XCTAssertEqual(again, .failure(AddRepoProblem("\((checkout.workflowPath as NSString).abbreviatingWithTildeInPath) already exists, so Symphony left it as it is.")))
        XCTAssertEqual(try String(contentsOfFile: checkout.workflowPath, encoding: .utf8), text)

        let gone = LocalCheckout(path: folder.appendingPathComponent("missing").path, gitHub: "acme/web")
        guard case let .failure(problem) = gone.writeWorkflow(text) else { return XCTFail("expected a failure") }
        XCTAssertTrue(problem.message.hasPrefix("Couldn't write "), problem.message)

        let gh = try fakeGH([baseRef, newBranch("symphony/add-workflow"), commit, pullRequest])
        XCTAssertEqual(
            WorkflowLanding.pullRequest.land(text, gitHub: "acme/web", baseBranch: "main", summary: "", checkout: nil, cli: gh.cli),
            .success(.pullRequest(url: "https://github.com/acme/web/pull/7"))
        )
    }

    func testOffersWritingIntoACheckoutOnlyForALocalFolder() {
        XCTAssertEqual(WorkflowLanding.choices(for: .gitHub), [.pullRequest, .skip])
        XCTAssertEqual(WorkflowLanding.choices(for: .localFolder), [.pullRequest, .localFile, .skip])
        XCTAssertTrue(WorkflowLanding.pullRequest.help(baseBranch: "main").contains("against main"))
        XCTAssertTrue(WorkflowLanding.localFile.help(baseBranch: "dev").contains("Commit and push it to dev"))
        XCTAssertTrue(WorkflowLanding.skip.help(baseBranch: "main").contains("missing"))
    }

    func testSaysWhatIsMissing() {
        XCTAssertEqual(
            WorkflowCheck.missing(WorkflowStack(), branch: "main").missingMessage(source: "acme/web"),
            "acme/web has no WORKFLOW.md on main. Symphony runs no agent on a repo without one, so the sheet drafted one from its files."
        )
        XCTAssertEqual(
            WorkflowCheck.missing(WorkflowStack(), branch: nil).missingMessage(source: "~/code/web")?.hasPrefix("~/code/web has no WORKFLOW.md. "),
            true
        )
        XCTAssertNil(WorkflowCheck.present.missingMessage(source: "acme/web"))
    }

    // MARK: Pending

    func testKeepsPendingWorkflowsByRepo() {
        let defaults = MemoryKeyValueStore()
        let store = PendingWorkflowStore(defaults: defaults)

        store.record(.pullRequest(url: "https://github.com/acme/web/pull/7"), for: "web")
        store.record(.localFile(path: "/code/api/WORKFLOW.md"), for: "api")
        XCTAssertEqual(PendingWorkflowStore(defaults: defaults).all, [
            "web": .pullRequest(url: "https://github.com/acme/web/pull/7"),
            "api": .localFile(path: "/code/api/WORKFLOW.md"),
        ])

        store.clear("web")
        store.clear("unknown")
        XCTAssertEqual(store.all, ["api": .localFile(path: "/code/api/WORKFLOW.md")])
        store.clear("api")
        XCTAssertNil(defaults.values[PendingWorkflowStore.key])

        defaults.values[PendingWorkflowStore.key] = ["odd": "text", "empty": [String: String]()]
        XCTAssertEqual(store.all, [:])
    }

    func testShowsAPendingWorkflowUntilSymphonyReadsIt() {
        let missing = RepoStatus(key: "web", workflow: RepoStatus.Workflow(state: .missing, error: "no WORKFLOW.md"))
        let valid = RepoStatus(key: "api")
        let display = ReposDisplay(rows: [ReposList.row(missing), ReposList.row(valid), ReposList.row(RepositoryEntry(key: "docs"))])
        let pending: [String: PendingWorkflow] = [
            "web": .pullRequest(url: "https://github.com/acme/web/pull/7"),
            "api": .pullRequest(url: "https://github.com/acme/api/pull/1"),
            "docs": .localFile(path: "/code/docs/WORKFLOW.md"),
        ]

        let shown = ReposList.withPendingWorkflows(display, pending: pending)

        func workflow(_ row: Int) -> RepoField? { shown.rows[row].fields.first { $0.label == ReposList.workflowLabel } }
        XCTAssertEqual(workflow(0), RepoField("WORKFLOW.md", "pending: pull request open", detail: "https://github.com/acme/web/pull/7"))
        XCTAssertEqual(workflow(1)?.value, "found, valid")
        XCTAssertEqual(workflow(2), RepoField(
            "WORKFLOW.md", "pending: written, not pushed", detail: "/code/docs/WORKFLOW.md: commit and push it to the base branch."
        ))
        XCTAssertEqual(shown.rows[0].fields.count, display.rows[0].fields.count)
        XCTAssertEqual(ReposList.withPendingWorkflows(display, pending: [:]), display)

        XCTAssertEqual(ReposList.validWorkflows(.repos([missing, valid], warning: nil)), ["api"])
        XCTAssertEqual(ReposList.validWorkflows(.unreachable), [])
        XCTAssertEqual(ReposList.validWorkflows(nil), [])
    }

    func testSaysWhatSaveAdded() {
        XCTAssertEqual(
            AddRepo.savedMessage(key: "web", apply: .onNextStart, madeDefault: nil, workflow: .pullRequest(url: "https://github.com/acme/web/pull/7")),
            "Added web. Symphony connects it when it starts. Opened https://github.com/acme/web/pull/7 to add its WORKFLOW.md."
        )
        XCTAssertEqual(
            AddRepo.savedMessage(key: "web", apply: .onNextStart, madeDefault: nil, workflow: .localFile(path: "/code/web/WORKFLOW.md")),
            "Added web. Symphony connects it when it starts. Wrote /code/web/WORKFLOW.md; commit and push it to the base branch."
        )
    }
}
