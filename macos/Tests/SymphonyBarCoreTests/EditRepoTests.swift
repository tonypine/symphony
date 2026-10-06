import XCTest
@testable import SymphonyBarCore

final class EditRepoTests: XCTestCase {
    private let checkout = LocalCheckout(path: "/Users/me/code/web", gitHub: "acme/web")

    /// A local repo with comments inside it, the default, and a managed repo after a blank line.
    private let config = """
        # Symphony operator config.
        repositories:
          - key: symphony
            default: true
            workflow: WORKFLOW.md  # repo-local prompt
            route:
              # team: ENG
              projects: ["Harness"]
            workspace:
              strategy: worktree
              repo: ~/Projects/symphony
              fetch_before_dispatch: true

          # Opt-in only: web tickets need the web label.
          - key: web
            base_branch: develop
            route:
              team: ENG
              projects: [Web, Site]
              labels: [web]
            workspace:
              source: acme/web
              fetch_before_dispatch: false

        workspaces:
          root: ~/Projects/symphony-workspaces

        """

    private var entries: [RepositoryEntry] { (try? RepositoriesConfig.entries(in: config)) ?? [] }
    private var symphony: RepositoryEntry { entries[0] }
    private var web: RepositoryEntry { entries[1] }

    // MARK: Draft

    func testDraftOfALocalRepoKeepsItsFolderUntilAnotherIsChosen() {
        let draft = EditRepo.draft(for: symphony)
        XCTAssertEqual(draft, AddRepoDraft(mode: .localFolder, key: "symphony", baseBranch: "", project: "Harness"))
        XCTAssertEqual(EditRepo.entry(for: draft, editing: symphony, existing: entries), .success(symphony))
    }

    func testDraftOfAManagedRepo() {
        let draft = EditRepo.draft(for: web)
        XCTAssertEqual(draft, AddRepoDraft(
            mode: .gitHub, gitHubInput: "acme/web", key: "web", baseBranch: "develop", project: "Web", labels: ["web"]
        ))
        XCTAssertEqual(EditRepo.entry(for: draft, editing: web, existing: entries), .success(web))
        XCTAssertEqual(EditRepo.sheetTitle(key: "web"), "Edit web")
    }

    // MARK: Editing

    func testEditingTheProjectChangesOnlyThatEntryAndKeepsComments() throws {
        var draft = EditRepo.draft(for: symphony)
        draft.project = "Platform"
        draft.labels = ["backend"]
        let entry = try EditRepo.entry(for: draft, editing: symphony, existing: entries).get()

        var expected = symphony
        expected.route = RepositoryRoute(projects: ["Platform"], labels: ["backend"])
        XCTAssertEqual(entry, expected)
        XCTAssertFalse(EditRepo.needsRestart(from: symphony, to: entry))

        let updated = try RepositoriesConfig.updating("symphony", to: entry, in: config)
        XCTAssertEqual(updated, config.replacingOccurrences(
            of: "      projects: [\"Harness\"]\n",
            with: "      projects: [Platform]\n      labels: [backend]\n"
        ))
    }

    func testKeepsSeveralProjectsWhileTheFirstStaysPickedAndKeepsTeam() throws {
        var draft = EditRepo.draft(for: web)
        draft.labels = []
        draft.baseBranch = " "
        let entry = try EditRepo.entry(for: draft, editing: web, existing: entries).get()
        XCTAssertEqual(entry.route, RepositoryRoute(team: "ENG", projects: ["Web", "Site"]))
        XCTAssertNil(entry.baseBranch)
        XCTAssertTrue(EditRepo.needsRestart(from: web, to: entry))

        draft.project = nil
        XCTAssertEqual(try EditRepo.entry(for: draft, editing: web, existing: entries).get().route, RepositoryRoute(team: "ENG"))
    }

    func testSwitchesALocalFolderToAManagedClone() throws {
        var draft = EditRepo.draft(for: symphony)
        draft.mode = .gitHub
        draft.gitHubInput = "https://github.com/tonypine/symphony"
        let entry = try EditRepo.entry(for: draft, editing: symphony, existing: entries).get()

        XCTAssertNil(entry.workflow)
        XCTAssertEqual(entry.workspace, RepositoryWorkspace(source: "tonypine/symphony", fetchBeforeDispatch: true))
        XCTAssertTrue(EditRepo.needsRestart(from: symphony, to: entry))

        let updated = try RepositoriesConfig.updating("symphony", to: entry, in: config)
        XCTAssertEqual(updated, config
            .replacingOccurrences(of: "    workflow: WORKFLOW.md  # repo-local prompt\n", with: "")
            .replacingOccurrences(
                of: "      strategy: worktree\n      repo: ~/Projects/symphony\n",
                with: "      source: tonypine/symphony\n"
            ))
        XCTAssertEqual(try RepositoriesConfig.entries(in: updated), [entry, web])
    }

    func testSwitchesAManagedCloneToALocalFolder() throws {
        var draft = EditRepo.draft(for: web)
        draft.mode = .localFolder
        XCTAssertEqual(
            EditRepo.entry(for: draft, editing: web, existing: entries),
            .failure(AddRepoProblem("Choose the folder of a git checkout."))
        )
        draft.folder = .failure(AddRepoProblem("~/x isn't a git checkout."))
        XCTAssertEqual(EditRepo.entry(for: draft, editing: web, existing: entries), .failure(AddRepoProblem("~/x isn't a git checkout.")))
        // Only Add Repo drafts a WORKFLOW.md.
        draft.folder = .success(LocalCheckout(path: "/Users/me/code/web", gitHub: "acme/web", hasWorkflow: false))
        XCTAssertEqual(EditRepo.entry(for: draft, editing: web, existing: entries), .failure(checkout.missingWorkflowProblem))

        draft.folder = .success(checkout)
        let entry = try EditRepo.entry(for: draft, editing: web, existing: entries).get()
        XCTAssertEqual(entry.workflow, "/Users/me/code/web/WORKFLOW.md")
        XCTAssertEqual(entry.workspace, RepositoryWorkspace(strategy: "worktree", repo: "/Users/me/code/web", fetchBeforeDispatch: false))
        XCTAssertEqual(entry.route, web.route)

        let updated = try RepositoriesConfig.updating("web", to: entry, in: config)
        XCTAssertTrue(updated.contains("""
                  # Opt-in only: web tickets need the web label.
                  - key: web
                    base_branch: develop
                    workflow: /Users/me/code/web/WORKFLOW.md
                """))
        XCTAssertTrue(updated.contains("""
                    workspace:
                      strategy: worktree
                      repo: /Users/me/code/web
                      fetch_before_dispatch: false
                """))
        XCTAssertFalse(updated.contains("source:"))
        XCTAssertEqual(try RepositoriesConfig.entries(in: updated), [symphony, entry])

        // And back to the same clone.
        var back = EditRepo.draft(for: entry)
        back.mode = .gitHub
        back.gitHubInput = "git@github.com:acme/web.git"
        let managed = try EditRepo.entry(for: back, editing: entry, existing: [symphony, entry]).get()
        XCTAssertEqual(managed.workspace, RepositoryWorkspace(source: "acme/web", fetchBeforeDispatch: false))
        XCTAssertNil(managed.workflow)
    }

    func testAnUnchangedSourceKeepsItsSpelling() throws {
        var entry = web
        entry.workspace.source = "https://github.com/acme/web.git"
        var draft = EditRepo.draft(for: entry)
        draft.gitHubInput = "acme/web"
        XCTAssertEqual(try EditRepo.entry(for: draft, editing: entry, existing: [symphony, entry]).get(), entry)
    }

    func testRefusesInvalidInput() {
        var draft = EditRepo.draft(for: web)
        draft.gitHubInput = " "
        XCTAssertEqual(
            EditRepo.entry(for: draft, editing: web, existing: entries),
            .failure(AddRepoProblem("Paste a GitHub repo URL or owner/repo."))
        )
        draft.gitHubInput = "gitlab.com/acme/web"
        XCTAssertEqual(
            EditRepo.entry(for: draft, editing: web, existing: entries),
            .failure(AddRepoProblem(
                "Use a GitHub repo as https://github.com/owner/repo, git@github.com:owner/repo.git or owner/repo."
            ))
        )
    }

    func testANonDefaultRepoNeedsARouteUnlessItIsTheOnlyOne() throws {
        var unrouted = web
        unrouted.route = RepositoryRoute(projects: ["Web"])
        var draft = EditRepo.draft(for: unrouted)
        draft.project = nil
        XCTAssertEqual(
            EditRepo.entry(for: draft, editing: unrouted, existing: [symphony, unrouted]),
            .failure(AddRepoProblem("Pick a project or labels. Symphony needs a route for every repo but the default one."))
        )
        XCTAssertNoThrow(try EditRepo.entry(for: draft, editing: unrouted, existing: [unrouted]).get())

        // The default repo takes the issues no route matches, so it may have none.
        var defaultDraft = EditRepo.draft(for: symphony)
        defaultDraft.project = nil
        XCTAssertEqual(try EditRepo.entry(for: defaultDraft, editing: symphony, existing: entries).get().route, RepositoryRoute())
    }

    func testRefusesTheRouteOfAnotherRepo() {
        var draft = EditRepo.draft(for: symphony)
        draft.project = "Web"
        let other = RepositoryEntry(key: "other", route: RepositoryRoute(projects: ["Web"]))
        XCTAssertEqual(
            EditRepo.entry(for: draft, editing: symphony, existing: [symphony, other]),
            .failure(AddRepoProblem(
                "`other` already takes the issues of this project and labels. Pick other labels or another project."
            ))
        )
    }

    func testApplyAndMessages() {
        var busy = StateSnapshot()
        busy.running = 2
        let running = SymphonyStatus.running(busy, external: false)
        var moved = web
        moved.workspace = RepositoryWorkspace(strategy: "worktree", repo: "/x")
        var routed = web
        routed.route.labels = ["api"]

        XCTAssertNil(EditRepo.apply(status: running, from: web, to: routed))
        XCTAssertEqual(EditRepo.apply(status: running, from: web, to: moved), .askToRestart(runs: 2))
        XCTAssertEqual(EditRepo.apply(status: .stopped, from: web, to: moved), .onNextStart)

        XCTAssertEqual(
            EditRepo.savedMessage(key: "web", apply: nil),
            "Saved web. Symphony reads the change from symphony.yml, so its next poll uses it."
        )
        XCTAssertEqual(EditRepo.savedMessage(key: "web", apply: .restart), "Saved web. Symphony restarts to apply it.")
        XCTAssertEqual(EditRepo.savedMessage(key: "web", apply: .askToRestart(runs: 1)), "Saved web. Symphony restarts to apply it.")
        XCTAssertEqual(EditRepo.savedMessage(key: "web", apply: .onNextStart), "Saved web. Symphony uses it when it starts.")
        XCTAssertEqual(EditRepo.savedMessage(key: "web", apply: .restartManually), "Saved web. Restart Symphony to apply it.")
        XCTAssertEqual(EditRepo.restartQuestion(key: "web", runs: 1).title, "Restart Symphony to apply the change to web?")
        XCTAssertTrue(EditRepo.restartQuestion(key: "web", runs: 1).message.hasPrefix("1 agent run is active. Restart pauses"))
    }

    // MARK: Disconnect

    func testDisconnectProblems() {
        XCTAssertNil(DisconnectRepo.problem(key: "web", entries: entries))
        XCTAssertEqual(
            DisconnectRepo.problem(key: "web", entries: [web]),
            "web is the only repo, and Symphony needs at least one."
        )
        XCTAssertEqual(
            DisconnectRepo.problem(key: "gone", entries: entries),
            "symphony.yml has no repo `gone`. Symphony keeps it until it restarts."
        )
    }

    func testDisconnectsARepoWithItsCommentAndNoDoubledBlankLine() throws {
        XCTAssertNil(DisconnectRepo.defaultCandidates(key: "web", entries: entries))
        let updated = try DisconnectRepo.removing("web", newDefault: nil, from: config)
        XCTAssertEqual(updated, """
            # Symphony operator config.
            repositories:
              - key: symphony
                default: true
                workflow: WORKFLOW.md  # repo-local prompt
                route:
                  # team: ENG
                  projects: ["Harness"]
                workspace:
                  strategy: worktree
                  repo: ~/Projects/symphony
                  fetch_before_dispatch: true

            workspaces:
              root: ~/Projects/symphony-workspaces

            """)
    }

    func testDisconnectingTheDefaultMakesThePickedRepoTheDefault() throws {
        XCTAssertEqual(DisconnectRepo.defaultCandidates(key: "symphony", entries: entries), ["web"])
        XCTAssertThrowsError(try DisconnectRepo.removing("symphony", newDefault: nil, from: config)) { error in
            XCTAssertEqual(
                error as? RepositoriesConfigError,
                .invalidEntry("Pick the repo that becomes the default in place of `symphony`.")
            )
        }
        XCTAssertThrowsError(try DisconnectRepo.removing("symphony", newDefault: "symphony", from: config))
        XCTAssertThrowsError(try DisconnectRepo.removing("symphony", newDefault: "nope", from: config))

        let updated = try DisconnectRepo.removing("symphony", newDefault: "web", from: config)
        XCTAssertEqual(updated, """
            # Symphony operator config.
            repositories:
              # Opt-in only: web tickets need the web label.
              - key: web
                default: true
                base_branch: develop
                route:
                  team: ENG
                  projects: [Web, Site]
                  labels: [web]
                workspace:
                  source: acme/web
                  fetch_before_dispatch: false

            workspaces:
              root: ~/Projects/symphony-workspaces

            """)
    }

    func testRefusesToDisconnectTheLastOrAMissingRepo() {
        let one = "repositories:\n  - key: a\n    default: true\n"
        XCTAssertThrowsError(try DisconnectRepo.removing("a", newDefault: nil, from: one)) { error in
            XCTAssertEqual(error as? RepositoriesConfigError, .lastRepository("a"))
        }
        XCTAssertThrowsError(try DisconnectRepo.removing("nope", newDefault: nil, from: config)) { error in
            XCTAssertEqual(error as? RepositoriesConfigError, .notFound("nope"))
        }
    }

    func testDisconnectQuestionsAndMessages() {
        let local = DisconnectRepo.question(for: symphony, newDefaultNeeded: true)
        XCTAssertEqual(local.title, "Disconnect symphony?")
        XCTAssertEqual(local.message, "Symphony stops taking issues for symphony, and its entry and comment leave symphony.yml. "
            + "The folder ~/Projects/symphony and its branches stay as they are. symphony is the default repo: pick the "
            + "repo that takes the issues no route matches.")
        XCTAssertEqual(
            DisconnectRepo.question(for: web, newDefaultNeeded: false).message,
            "Symphony stops taking issues for web, and its entry and comment leave symphony.yml. Symphony's clone of "
                + "acme/web stays on disk: to delete it, use Remove Clone… before disconnecting."
        )
        XCTAssertEqual(
            DisconnectRepo.question(for: RepositoryEntry(key: "bare"), newDefaultNeeded: false).message,
            "Symphony stops taking issues for bare, and its entry and comment leave symphony.yml."
        )

        XCTAssertEqual(
            DisconnectRepo.message(key: "web", apply: .restart, newDefault: nil),
            "Disconnected web. Symphony restarts to drop it."
        )
        XCTAssertEqual(
            DisconnectRepo.message(key: "web", apply: .askToRestart(runs: 2), newDefault: "api"),
            "Disconnected web. Symphony restarts to drop it. api is now the default repo."
        )
        XCTAssertEqual(DisconnectRepo.message(key: "web", apply: .onNextStart, newDefault: nil), "Disconnected web.")
        XCTAssertEqual(
            DisconnectRepo.message(key: "web", apply: .restartManually, newDefault: nil),
            "Disconnected web. Restart Symphony to drop it."
        )
        XCTAssertEqual(DisconnectRepo.restartQuestion(key: "web", runs: 2).title, "Restart Symphony to drop web?")
        XCTAssertTrue(DisconnectRepo.restartQuestion(key: "web", runs: 2).message.hasPrefix("2 agent runs are active."))
    }

    /// Disconnecting a local repo rewrites only `symphony.yml`: its folder, files and git branches stay.
    func testDisconnectingALocalRepoLeavesItsFolderUntouched() throws {
        let directory = uniqueTemporaryDirectory("disconnect-repo")
        let folder = directory.appendingPathComponent("web")
        let files = FileManager.default
        try files.createDirectory(at: folder.appendingPathComponent(".git/refs/heads"), withIntermediateDirectories: true)
        addTeardownBlock { try? files.removeItem(at: directory) }
        try "ref: refs/heads/main\n".write(to: folder.appendingPathComponent(".git/HEAD"), atomically: false, encoding: .utf8)
        try "abc\n".write(to: folder.appendingPathComponent(".git/refs/heads/feature"), atomically: false, encoding: .utf8)
        try "# Web\n".write(to: folder.appendingPathComponent("WORKFLOW.md"), atomically: false, encoding: .utf8)
        let configURL = directory.appendingPathComponent("symphony.yml")
        try config.replacingOccurrences(of: "~/Projects/symphony\n", with: folder.path + "\n")
            .write(to: configURL, atomically: false, encoding: .utf8)
        let before = try snapshot(directory, except: "symphony.yml")

        try SymphonyConfigFile(path: configURL.path).disconnectRepository("symphony", newDefault: "web")

        XCTAssertEqual(try snapshot(directory, except: "symphony.yml"), before)
        XCTAssertEqual(try SymphonyConfigFile(path: configURL.path).readRepositories().map(\.key), ["web"])
    }

    /// Every path under `directory` with its contents, but `except`.
    private func snapshot(_ directory: URL, except: String) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(atPath: directory.path)
        while let path = enumerator?.nextObject() as? String {
            guard path != except else { continue }
            let url = directory.appendingPathComponent(path)
            result[path] = ManagedClones.isDirectory(url.path) ? Data() : try Data(contentsOf: url)
        }
        XCTAssertFalse(result.isEmpty)
        return result
    }
}
