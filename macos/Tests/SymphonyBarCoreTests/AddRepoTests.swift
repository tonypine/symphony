import XCTest
@testable import SymphonyBarCore

final class AddRepoTests: XCTestCase {
    private let checkout = LocalCheckout(path: "/Users/me/code/web", gitHub: "acme/web")

    /// A `symphony.yml` with one routed repo and comments around it.
    private let config = """
        # Symphony operator config.
        issues:
          provider: linear

        repositories:
          - key: symphony
            workflow: WORKFLOW.md  # repo-local prompt
            route:
              # team: ENG
              projects: ["Harness"]
            workspace:
              repo: ~/Projects/symphony

        workspaces:
          root: ~/Projects/symphony-workspaces

        """

    // MARK: GitHub input

    func testNormalizesEverySupportedGitHubForm() {
        let inputs = [
            "acme/web",
            " acme/web \n",
            "acme/web.git",
            "https://github.com/acme/web",
            "https://github.com/acme/web/",
            "https://github.com/acme/web.git",
            "http://www.github.com/acme/web",
            "HTTPS://GitHub.com/acme/web",
            "https://github.com/acme/web/tree/main/lib?x=1#readme",
            "https://github.com/acme/web/pulls",
            "git@github.com:acme/web.git",
            "git@github.com:acme/web",
            "ssh://git@github.com/acme/web.git",
        ]
        for input in inputs {
            XCTAssertEqual(GitHubRepoInput.normalize(input), "acme/web", input)
        }
        XCTAssertEqual(GitHubRepoInput.normalize("my-org/my.repo_2"), "my-org/my.repo_2")
    }

    func testRejectsAnythingElse() {
        let inputs = [
            "",
            "acme",
            "acme/web/extra",
            "https://gitlab.com/acme/web",
            "https://github.com/acme",
            "https://example.com/github.com/acme/web",
            "github.com/acme/web",
            "git@gitlab.com:acme/web.git",
            "git@github.com:acme/web/extra.git",
            "-acme/web",
            "ac_me/web",
            "acme/we b",
            "acme/..",
            "acme/.git",
            "acme/web.git.git",
            String(repeating: "a", count: 40) + "/web",
            "acme/" + String(repeating: "r", count: 101),
            "äcme/web",
        ]
        for input in inputs {
            XCTAssertNil(GitHubRepoInput.normalize(input), input)
        }
        XCTAssertEqual(GitHubRepoInput.name("acme/web"), "web")
    }

    // MARK: Local folder

    private func git(_ answers: [String: (Int32, String)]) -> LocalCheckout.Git {
        { arguments, folder in
            let answer = answers[arguments.joined(separator: " ") + " @ " + folder] ?? (128, "")
            return (answer.0, answer.1)
        }
    }

    func testAcceptsAGitHubCheckoutWithAWorkflowFromAnyFolderInIt() {
        var checked: [String] = []
        let result = LocalCheckout.inspect(
            "/Users/me/code/web/lib",
            git: git([
                "rev-parse --show-toplevel @ /Users/me/code/web/lib": (0, "/Users/me/code/web\n"),
                "remote get-url origin @ /Users/me/code/web": (0, "git@github.com:acme/web.git\n"),
            ]),
            fileExists: { checked.append($0); return true }
        )

        XCTAssertEqual(result, .success(checkout))
        XCTAssertEqual(checked, ["/Users/me/code/web/WORKFLOW.md"])
        XCTAssertEqual(checkout.workflowPath, "/Users/me/code/web/WORKFLOW.md")
    }

    func testRejectsAFolderThatIsNotAGitHubCheckoutWithAWorkflow() {
        let top = ["rev-parse --show-toplevel @ /tmp/web": (Int32(0), "/tmp/web\n")]
        let cases: [([String: (Int32, String)], Bool, String)] = [
            ([:], true, "/tmp/web isn't a git checkout."),
            (["rev-parse --show-toplevel @ /tmp/web": (0, "\n")], true, "/tmp/web isn't a git checkout."),
            (top, true, "/tmp/web has no origin remote. Symphony pushes agent branches to a GitHub origin."),
            (top.merging(["remote get-url origin @ /tmp/web": (0, "")]) { $1 }, true,
             "/tmp/web has no origin remote. Symphony pushes agent branches to a GitHub origin."),
            (top.merging(["remote get-url origin @ /tmp/web": (0, "https://gitlab.com/acme/web.git\n")]) { $1 }, true,
             "The origin of /tmp/web isn't a GitHub repo: https://gitlab.com/acme/web.git"),
            (top.merging(["remote get-url origin @ /tmp/web": (0, "https://github.com/acme/web\n")]) { $1 }, false,
             "/tmp/web has no WORKFLOW.md. Add one before connecting the repo."),
        ]
        for (answers, hasWorkflow, message) in cases {
            let result = LocalCheckout.inspect("/tmp/web", git: git(answers), fileExists: { _ in hasWorkflow })
            XCTAssertEqual(result, .failure(AddRepoProblem(message)), message)
        }
    }

    func testRunsGitInTheFolder() throws {
        let folder = uniqueTemporaryDirectory("add-repo-git")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        let notGit = LocalCheckout.runGit(["rev-parse", "--show-toplevel"], in: folder.path)
        XCTAssertNotEqual(notGit.status, 0)

        XCTAssertEqual(LocalCheckout.runGit(["init", "-q"], in: folder.path).status, 0)
        XCTAssertEqual(LocalCheckout.runGit(["remote", "add", "origin", "git@github.com:acme/web.git"], in: folder.path).status, 0)
        try "Work the ticket.\n".write(to: folder.appendingPathComponent("WORKFLOW.md"), atomically: false, encoding: .utf8)

        guard case let .success(found) = LocalCheckout.inspect(folder.path) else { return XCTFail("expected a checkout") }
        XCTAssertEqual(found.gitHub, "acme/web")
        // The temporary folder may sit behind a symlink, such as /var → /private/var.
        XCTAssertEqual(URL(fileURLWithPath: found.path).resolvingSymlinksInPath(), folder.resolvingSymlinksInPath())
        XCTAssertEqual(LocalCheckout.runGit(["status"], in: folder.appendingPathComponent("missing").path).status, 128)
    }

    // MARK: Key

    func testSuggestsAFreeKeyFromTheRepoName() {
        XCTAssertEqual(AddRepo.suggestedKey(for: "web", existing: []), "web")
        XCTAssertEqual(AddRepo.suggestedKey(for: "web", existing: ["web", "web-2"]), "web-3")
        XCTAssertEqual(AddRepo.suggestedKey(for: "Hello-World", existing: ["web"]), "hello-world")
        XCTAssertEqual(AddRepo.suggestedKey(for: "Web", existing: ["WEB"]), "web-2")
        XCTAssertEqual(AddRepo.suggestedKey(for: ".dot files", existing: []), "dot-files")
        XCTAssertEqual(AddRepo.suggestedKey(for: "...", existing: []), "repo")
    }

    func testKeyProblems() {
        XCTAssertNil(AddRepo.keyProblem("web.app_2-x", existing: ["api"]))
        XCTAssertEqual(AddRepo.keyProblem("  ", existing: []), AddRepoProblem("Enter a repo key."))
        let characters = AddRepoProblem("A repo key starts with a letter or digit and holds only letters, digits, `.`, `_` and `-`.")
        XCTAssertEqual(AddRepo.keyProblem("my repo", existing: []), characters)
        XCTAssertEqual(AddRepo.keyProblem("-web", existing: []), characters)
        XCTAssertEqual(AddRepo.keyProblem("..", existing: []), characters)
        XCTAssertEqual(AddRepo.keyProblem("web", existing: ["web"]), AddRepoProblem("A repo with key `web` already exists."))
        XCTAssertEqual(AddRepo.keyProblem("WEB", existing: ["web"]), AddRepoProblem("A repo with key `WEB` already exists."))
        // Symphony names workspaces `my_web` for both.
        XCTAssertEqual(AddRepo.keyProblem("my_web", existing: ["my web"]), AddRepoProblem("A repo with key `my_web` already exists."))
    }

    // MARK: Entry

    func testAGitHubURLBecomesAManagedSource() {
        let draft = AddRepoDraft(
            gitHubInput: "https://github.com/acme/web",
            key: " web ",
            baseBranch: " develop ",
            project: "Web platform",
            labels: ["frontend", " ", "api"]
        )

        let result = AddRepo.entry(for: draft, existing: [])

        XCTAssertEqual(result, .success(RepositoryEntry(
            key: "web",
            baseBranch: "develop",
            route: RepositoryRoute(projects: ["Web platform"], labels: ["frontend", "api"]),
            workspace: RepositoryWorkspace(source: "acme/web")
        )))
        XCTAssertEqual(draft.gitHub, "acme/web")
    }

    func testALocalFolderBecomesAWorktreeSourceWithItsWorkflow() {
        let draft = AddRepoDraft(mode: .localFolder, folder: .success(checkout), key: "web", project: "Web")

        let result = AddRepo.entry(for: draft, existing: [])

        XCTAssertEqual(result, .success(RepositoryEntry(
            key: "web",
            baseBranch: "main",
            workflow: "/Users/me/code/web/WORKFLOW.md",
            route: RepositoryRoute(projects: ["Web"]),
            workspace: RepositoryWorkspace(strategy: "worktree", repo: "/Users/me/code/web")
        )))
        XCTAssertEqual(draft.gitHub, "acme/web")
    }

    func testBlocksInvalidInput() {
        let valid = AddRepoDraft(gitHubInput: "acme/web", key: "web", project: "Web")
        let existing = [RepositoryEntry(key: "api", route: RepositoryRoute(projects: ["Web"], labels: ["api"]))]
        func problem(_ change: (inout AddRepoDraft) -> Void) -> String? {
            var draft = valid
            change(&draft)
            guard case let .failure(problem) = AddRepo.entry(for: draft, existing: existing) else { return nil }
            return problem.message
        }

        XCTAssertNil(problem { _ in })
        XCTAssertEqual(problem { $0.gitHubInput = " " }, "Paste a GitHub repo URL or owner/repo.")
        XCTAssertEqual(
            problem { $0.gitHubInput = "https://gitlab.com/acme/web" },
            "Use a GitHub repo as https://github.com/owner/repo, git@github.com:owner/repo.git or owner/repo."
        )
        XCTAssertEqual(problem { $0.mode = .localFolder }, "Choose the folder of a git checkout.")
        XCTAssertEqual(problem { $0.mode = .localFolder; $0.folder = .failure(AddRepoProblem("Not git.")) }, "Not git.")
        XCTAssertEqual(problem { $0.key = "api" }, "A repo with key `api` already exists.")
        XCTAssertEqual(problem { $0.key = "" }, "Enter a repo key.")
        XCTAssertEqual(problem { $0.baseBranch = "" }, "Enter a base branch, such as main.")
        XCTAssertEqual(problem { $0.project = nil }, "Pick the Linear project whose issues go to this repo.")
        XCTAssertEqual(problem { $0.project = " " }, "Pick the Linear project whose issues go to this repo.")
        XCTAssertEqual(
            problem { $0.labels = ["api"] },
            "`api` already takes the issues of this project and labels. Pick other labels or another project."
        )
        XCTAssertNil(problem { $0.labels = ["api", "frontend"] })
        XCTAssertEqual(valid.gitHub, "acme/web")
        XCTAssertNil(AddRepoDraft(mode: .localFolder).gitHub)
    }

    // MARK: Writing

    func testAddingKeepsCommentsAndOtherEntries() throws {
        let entry = RepositoryEntry(
            key: "web",
            baseBranch: "main",
            route: RepositoryRoute(projects: ["Web platform"], labels: ["frontend"]),
            workspace: RepositoryWorkspace(source: "acme/web")
        )

        let result = try AddRepo.adding(entry, to: config)

        XCTAssertNil(result.madeDefault)
        XCTAssertEqual(result.text, """
            # Symphony operator config.
            issues:
              provider: linear

            repositories:
              - key: symphony
                workflow: WORKFLOW.md  # repo-local prompt
                route:
                  # team: ENG
                  projects: ["Harness"]
                workspace:
                  repo: ~/Projects/symphony
              - key: web
                base_branch: main
                route:
                  projects: ["Web platform"]
                  labels: [frontend]
                workspace:
                  source: acme/web

            workspaces:
              root: ~/Projects/symphony-workspaces

            """)
    }

    func testAnUnroutedOnlyRepoBecomesTheDefault() throws {
        let unrouted = "repositories:\n  - key: app\n    workflow: WORKFLOW.md\n"
        let entry = RepositoryEntry(key: "web", route: RepositoryRoute(projects: ["Web"]), workspace: RepositoryWorkspace(source: "acme/web"))

        let result = try AddRepo.adding(entry, to: unrouted)

        XCTAssertEqual(result.madeDefault, "app")
        XCTAssertEqual(try RepositoriesConfig.entries(in: result.text).map(\.isDefault), [true, nil])

        // Nothing changes for a repo that is routed or already the default, or with more than one repo.
        for yaml in [
            "repositories:\n  - key: app\n    default: true\n",
            "repositories:\n  - key: app\n    route:\n      team: ENG\n",
            "repositories:\n  - key: app\n    default: true\n  - key: api\n    route:\n      labels: [api]\n",
        ] {
            XCTAssertNil(try AddRepo.adding(entry, to: yaml).madeDefault, yaml)
        }
    }

    func testAddingADuplicateKeyThrows() {
        XCTAssertThrowsError(try AddRepo.adding(RepositoryEntry(key: "symphony"), to: config)) { error in
            XCTAssertEqual(error as? RepositoriesConfigError, .duplicateKey("symphony"))
        }
    }

    func testConnectsARepoInTheFile() throws {
        let directory = uniqueTemporaryDirectory("add-repo")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("symphony.yml")
        try "repositories:\n  - key: app\n".write(to: url, atomically: false, encoding: .utf8)
        let file = SymphonyConfigFile(path: url.path)
        let entry = RepositoryEntry(key: "web", route: RepositoryRoute(projects: ["Web"]), workspace: RepositoryWorkspace(source: "acme/web"))

        XCTAssertEqual(try file.connectRepository(entry), "app")
        XCTAssertEqual(try file.readRepositories().map(\.key), ["app", "web"])
        XCTAssertThrowsError(try file.connectRepository(entry))
        XCTAssertEqual(try file.readRepositories().map(\.key), ["app", "web"])
    }

    // MARK: Applying

    func testAppliesBySymphonysStatus() {
        let idle = StateSnapshot()
        var busy = StateSnapshot()
        busy.running = 2

        XCTAssertEqual(AddRepo.apply(status: .running(idle, external: false)), .restart)
        XCTAssertEqual(AddRepo.apply(status: .paused(idle, external: false)), .restart)
        XCTAssertEqual(AddRepo.apply(status: .running(busy, external: false)), .askToRestart(runs: 2))
        XCTAssertEqual(AddRepo.apply(status: .running(idle, external: true)), .restartManually)
        XCTAssertEqual(AddRepo.apply(status: .starting), .restartManually)
        XCTAssertEqual(AddRepo.apply(status: .stopped), .onNextStart)
        XCTAssertEqual(AddRepo.apply(status: .error("exited")), .onNextStart)
    }

    func testRestartQuestionAndSavedMessages() {
        let one = AddRepo.restartQuestion(key: "web", runs: 1)
        XCTAssertEqual(one.title, "Restart Symphony to connect web?")
        XCTAssertTrue(one.message.hasPrefix("1 agent run is active. Restart pauses dispatch, waits for them to finish"))
        XCTAssertTrue(AddRepo.restartQuestion(key: "web", runs: 3).message.hasPrefix("3 agent runs are active."))

        XCTAssertEqual(AddRepo.savedMessage(key: "web", apply: .restart, madeDefault: nil), "Added web. Symphony restarts to connect it.")
        XCTAssertEqual(
            AddRepo.savedMessage(key: "web", apply: .askToRestart(runs: 1), madeDefault: nil),
            "Added web. Symphony restarts to connect it."
        )
        XCTAssertEqual(
            AddRepo.savedMessage(key: "web", apply: .onNextStart, madeDefault: "app"),
            "Added web. Symphony connects it when it starts. app is now the default repo, so it keeps the issues no route matches."
        )
        XCTAssertEqual(
            AddRepo.savedMessage(key: "web", apply: .restartManually, madeDefault: nil),
            "Added web. Restart Symphony to connect it."
        )
    }
}
