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
        XCTAssertEqual(draft, AddRepoDraft(mode: .localFolder, key: "symphony", baseBranch: "", project: "Harness", isDefault: true))
        XCTAssertEqual(EditRepo.entry(for: draft, editing: symphony, existing: entries), .success(symphony))
    }

    func testDraftOfAManagedRepo() {
        let draft = EditRepo.draft(for: web)
        XCTAssertEqual(draft, AddRepoDraft(
            mode: .gitHub, gitHubInput: "acme/web", key: "web", baseBranch: "develop", project: "Web", labels: ["web"]
        ))
        XCTAssertEqual(EditRepo.entry(for: draft, editing: web, existing: entries), .success(web))
    }

    // MARK: Sections

    func testEachSectionHasItsOwnSheetThatFitsA768ptScreen() {
        XCTAssertEqual(EditRepo.Section.allCases.map { $0.sheetTitle(key: "web") }, [
            "Source of web", "Linear routing of web", "Review of web",
        ])
        XCTAssertEqual(EditRepo.Section.allCases.map(\.menuTitle), ["Edit Source…", "Edit Linear Routing…", "Edit Review…"])
        XCTAssertTrue(EditRepo.Section.allCases.allSatisfy { !$0.help.isEmpty })
        // A 1024×768 screen less the menu bar and the window's title bar, where a sheet hangs.
        for section in EditRepo.Section.allCases {
            XCTAssertLessThanOrEqual(section.sheetSize.height, 520, section.rawValue)
            XCTAssertLessThanOrEqual(section.sheetSize.width, 520, section.rawValue)
        }
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

    func testManualReviewChangesOnlyWhenItsPickerMoved() throws {
        let yaml = config.replacingOccurrences(of: "  - key: web\n", with: "  - key: web\n    manual_review: on\n")
        let on = try XCTUnwrap(RepositoriesConfig.entries(in: yaml).first { $0.key == "web" })
        XCTAssertEqual(EditRepo.draft(for: on).manualReview, .on)

        // The picker unmoved, on a value Symphony writes itself: the entry keeps it.
        let unchanged = try EditRepo.entry(for: EditRepo.draft(for: on), editing: on, existing: entries).get()
        XCTAssertEqual(unchanged.manualReview, "on")

        // Off is the default, so picking it removes the key, and the returned entry is a runtime config the
        // restart check ignores: the setting is read from symphony.yml while Symphony runs.
        var draft = EditRepo.draft(for: on)
        draft.manualReview = .off
        let off = try EditRepo.entry(for: draft, editing: on, existing: entries).get()
        XCTAssertNil(off.manualReview)
        XCTAssertFalse(EditRepo.needsRestart(from: on, to: off))

        // A value Symphony rejects stays until another one is picked.
        let rejected = try XCTUnwrap(RepositoriesConfig.entries(in: config.replacingOccurrences(
            of: "  - key: web\n", with: "  - key: web\n    manual_review: maybe\n"
        )).first { $0.key == "web" })
        XCTAssertEqual(EditRepo.draft(for: rejected).manualReview, .off)
        XCTAssertEqual(try EditRepo.entry(for: EditRepo.draft(for: rejected), editing: rejected, existing: entries).get().manualReview,
                       "maybe")
    }

    func testTheBuiltInTicketPatternsPickerWritesTheReposOverride() throws {
        let yaml = config.replacingOccurrences(
            of: "  - key: web\n",
            with: "  - key: web\n    acceptance_gate:\n      escalate:\n        ticket_patterns_builtin: false\n"
        )
        let off = try XCTUnwrap(RepositoriesConfig.entries(in: yaml).first { $0.key == "web" })
        XCTAssertEqual(EditRepo.draft(for: off).ticketPatternsBuiltIn, .off)
        XCTAssertEqual(try EditRepo.entry(for: EditRepo.draft(for: off), editing: off, existing: entries).get(), off)

        // Same as Settings removes the key; the setting is read from symphony.yml while Symphony runs.
        var draft = EditRepo.draft(for: off)
        draft.ticketPatternsBuiltIn = .inherit
        let inherit = try EditRepo.entry(for: draft, editing: off, existing: entries).get()
        XCTAssertNil(inherit.ticketPatternsBuiltIn)
        XCTAssertFalse(EditRepo.needsRestart(from: off, to: inherit))
        XCTAssertEqual(try EditRepo.updating(off, to: inherit, in: yaml), config)

        draft.ticketPatternsBuiltIn = .on
        XCTAssertEqual(try EditRepo.entry(for: draft, editing: off, existing: entries).get().ticketPatternsBuiltIn, true)
    }

    func testTheDetailShowsTheReposManualReview() throws {
        let yaml = config.replacingOccurrences(of: "  - key: web\n", with: "  - key: web\n    manual_review: on\n")
        let entry = try XCTUnwrap(RepositoriesConfig.entries(in: yaml).first { $0.key == "web" })
        XCTAssertEqual(ManualReview.repoField(entry).value, "On")
        XCTAssertEqual(ManualReview.repoField(symphony).value, "Off")
        XCTAssertEqual(ManualReview.repoField(symphony).detail, "The default.")
        XCTAssertEqual(ManualReview.repoField(RepositoryEntry(key: "a", manualReview: "maybe")).tone, .problem)
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
        XCTAssertEqual(
            EditRepo.savedMessage(key: "web", apply: nil, madeDefault: true, previousDefault: "symphony"),
            "Saved web. Symphony reads the change from symphony.yml, so its next poll uses it. "
                + "web is now the default repo in place of symphony."
        )
        XCTAssertEqual(
            EditRepo.savedMessage(key: "web", apply: .onNextStart, madeDefault: true),
            "Saved web. Symphony uses it when it starts. web is now the default repo."
        )
        XCTAssertEqual(EditRepo.restartQuestion(key: "web", runs: 1).title, "Restart Symphony to apply the change to web?")
        XCTAssertTrue(EditRepo.restartQuestion(key: "web", runs: 1).message.hasPrefix("1 agent run is active. Restart pauses"))
    }

    // MARK: Make Default

    func testMakeDefaultMovesTheDefaultInOneWriteKeepingComments() throws {
        var draft = EditRepo.draft(for: web)
        XCTAssertFalse(draft.isDefault)
        XCTAssertEqual(
            EditRepo.defaultOption(editing: web, existing: entries, isOn: false),
            EditRepo.DefaultOption(isEnabled: true, caption: "symphony is the default repo now.")
        )
        draft.isDefault = true
        draft.labels = ["web", "frontend"]
        XCTAssertEqual(
            EditRepo.defaultOption(editing: web, existing: entries, isOn: true),
            EditRepo.DefaultOption(isEnabled: true, caption: "Saving moves the default from symphony to web.")
        )
        let entry = try EditRepo.entry(for: draft, editing: web, existing: entries).get()
        XCTAssertEqual(entry.isDefault, true)
        XCTAssertFalse(EditRepo.needsRestart(from: web, to: entry))
        XCTAssertEqual(EditRepo.previousDefault(from: web, to: entry, existing: entries), "symphony")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("edit-default-\(UUID().uuidString).yml")
        defer { try? FileManager.default.removeItem(at: url) }
        try config.write(to: url, atomically: true, encoding: .utf8)
        try SymphonyConfigFile(path: url.path).editRepository(web, to: entry)

        let updated = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(updated, config
            .replacingOccurrences(of: "  - key: symphony\n    default: true\n", with: "  - key: symphony\n")
            .replacingOccurrences(of: "  - key: web\n", with: "  - key: web\n    default: true\n")
            .replacingOccurrences(of: "      labels: [web]\n", with: "      labels: [web, frontend]\n"))
        var former = symphony
        former.isDefault = nil
        XCTAssertEqual(try RepositoriesConfig.entries(in: updated), [former, entry])
    }

    func testMakeDefaultWithNoDefaultYet() throws {
        var routed = symphony
        routed.isDefault = nil
        let existing = [routed, web]
        XCTAssertEqual(
            EditRepo.defaultOption(editing: web, existing: existing, isOn: false),
            EditRepo.DefaultOption(isEnabled: true, caption: nil)
        )
        XCTAssertEqual(
            EditRepo.defaultOption(editing: web, existing: existing, isOn: true),
            EditRepo.DefaultOption(isEnabled: true, caption: "Saving makes web the default repo.")
        )
        var draft = EditRepo.draft(for: web)
        draft.isDefault = true
        // The default takes the issues no route matches, so it may drop its own route.
        draft.project = nil
        draft.labels = []
        let entry = try EditRepo.entry(for: draft, editing: web, existing: existing).get()
        XCTAssertEqual(entry.isDefault, true)
        XCTAssertEqual(entry.route, RepositoryRoute(team: "ENG"))
        XCTAssertNil(EditRepo.previousDefault(from: web, to: entry, existing: existing))
        XCTAssertNil(EditRepo.previousDefault(from: web, to: web, existing: existing))
    }

    func testTheDefaultReposOwnCheckboxStaysOn() {
        XCTAssertTrue(EditRepo.draft(for: symphony).isDefault)
        XCTAssertEqual(
            EditRepo.defaultOption(editing: symphony, existing: entries, isOn: true),
            EditRepo.DefaultOption(
                isEnabled: false,
                caption: "symphony is the default repo. To move the default, turn this on in another repo's Linear routing."
            )
        )
    }

    func testMakeDefaultIsRefusedWhileTheOldDefaultHasNoRoute() throws {
        let yaml = config.replacingOccurrences(of: "    route:\n      # team: ENG\n      projects: [\"Harness\"]\n", with: "")
        let existing = try RepositoriesConfig.entries(in: yaml)
        let unrouted = try XCTUnwrap(existing.first)
        XCTAssertEqual(unrouted.route, RepositoryRoute())
        XCTAssertEqual(unrouted.isDefault, true)
        let problem = "symphony has no Linear route of its own, so it stays the default. Give it a project or labels first."

        XCTAssertEqual(
            EditRepo.defaultOption(editing: web, existing: existing, isOn: false),
            EditRepo.DefaultOption(isEnabled: false, caption: problem)
        )
        var draft = EditRepo.draft(for: web)
        draft.isDefault = true
        XCTAssertEqual(EditRepo.entry(for: draft, editing: web, existing: existing), .failure(AddRepoProblem(problem)))

        // The write refuses it too, and leaves the file as it is.
        var forced = web
        forced.isDefault = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("edit-default-\(UUID().uuidString).yml")
        defer { try? FileManager.default.removeItem(at: url) }
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SymphonyConfigFile(path: url.path).editRepository(web, to: forced)) { error in
            XCTAssertEqual(error as? RepositoriesConfigError, .invalidEntry(problem))
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), yaml)
    }

    func testTheRoutePreviewReadsAsTheDetailWill() {
        var draft = EditRepo.draft(for: web)
        XCTAssertEqual(EditRepo.routePreview(for: draft, editing: web), ["Issues in Web or Site of team ENG with label web go to web."])
        draft.project = "Mobile"
        draft.labels = []
        draft.isDefault = true
        XCTAssertEqual(EditRepo.routePreview(for: draft, editing: web), [
            "Issues in Mobile of team ENG go to web.", "It also takes the issues no other repo's route matches.",
        ])
    }

    // MARK: Source

    func testTheSourceCaptionSaysWhatSwitchingDoesOnDisk() {
        // A managed repo.
        var draft = EditRepo.draft(for: web)
        XCTAssertTrue(EditRepo.isSourceUnchanged(draft, editing: web))
        XCTAssertEqual(EditRepo.sourceCaption(for: draft, editing: web), "Symphony keeps its own clone. Your checkouts aren't touched.")
        draft.gitHubInput = "acme/site"
        XCTAssertFalse(EditRepo.isSourceUnchanged(draft, editing: web))
        XCTAssertEqual(
            EditRepo.sourceCaption(for: draft, editing: web),
            "Symphony makes its own clone of the new repo on the next start. Its clone of acme/web stays on disk."
        )
        draft.mode = .localFolder
        XCTAssertFalse(EditRepo.isSourceUnchanged(draft, editing: web))
        let choose = "Agents work in worktrees of this checkout. It needs a GitHub origin and a WORKFLOW.md."
        XCTAssertEqual(EditRepo.sourceCaption(for: draft, editing: web), choose)
        draft.folder = .failure(AddRepoProblem("~/x isn't a git checkout."))
        XCTAssertEqual(EditRepo.sourceCaption(for: draft, editing: web), choose)
        draft.folder = .success(checkout)
        XCTAssertEqual(
            EditRepo.sourceCaption(for: draft, editing: web),
            "Agents work in worktrees of this folder from the next start. The folder stays as it is, and Symphony's clone "
                + "of acme/web stays on disk."
        )

        // A local folder repo.
        var local = EditRepo.draft(for: symphony)
        XCTAssertTrue(EditRepo.isSourceUnchanged(local, editing: symphony))
        XCTAssertEqual(EditRepo.sourceCaption(for: local, editing: symphony), choose)
        local.folder = .success(LocalCheckout(path: "~/Projects/symphony", gitHub: "tonypine/symphony"))
        XCTAssertTrue(EditRepo.isSourceUnchanged(local, editing: symphony))
        local.folder = .success(checkout)
        XCTAssertFalse(EditRepo.isSourceUnchanged(local, editing: symphony))
        XCTAssertEqual(
            EditRepo.sourceCaption(for: local, editing: symphony),
            "Agents work in worktrees of this folder from the next start. Both folders stay as they are."
        )
        local.mode = .gitHub
        XCTAssertFalse(EditRepo.isSourceUnchanged(local, editing: symphony))
        local.gitHubInput = "tonypine/symphony"
        XCTAssertEqual(
            EditRepo.sourceCaption(for: local, editing: symphony),
            "Symphony makes its own clone on the next start. Your folder stays as it is."
        )
    }

    // MARK: Review

    func testTheReviewSheetSavesManualReviewOnlyOnceSymphonyCheckPasses() async throws {
        var draft = EditRepo.draft(for: web)
        draft.manualReview = .on
        let entry = try EditRepo.entry(for: draft, editing: web, existing: entries).get()
        XCTAssertEqual(ManualReview.checkboxTitle, "Ask me before merging (a merge-confirmation hold after QA)")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("edit-review-\(UUID().uuidString).yml")
        defer { try? FileManager.default.removeItem(at: url) }
        try config.write(to: url, atomically: true, encoding: .utf8)
        let file = SymphonyConfigFile(path: url.path)

        let rejected = try await file.rewrite({ try EditRepo.updating(web, to: entry, in: $0) }) { _ in
            .failed("Config error in /x/.symphony.yml.123: repositories[web].manual_review is invalid")
        }
        XCTAssertEqual(rejected, .failed("Config error in /x/.symphony.yml.123: repositories[web].manual_review is invalid"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), config)

        let passed = try await file.rewrite({ try EditRepo.updating(web, to: entry, in: $0) }) { _ in .passed }
        XCTAssertEqual(passed, .passed)
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            config.replacingOccurrences(of: "    base_branch: develop\n", with: "    base_branch: develop\n    manual_review: \"on\"\n")
        )
    }

    // MARK: Disconnect

    func testDisconnectProblems() {
        XCTAssertNil(DisconnectRepo.problem(key: "web", entries: entries))
        XCTAssertEqual(
            DisconnectRepo.problem(key: "web", entries: [web]),
            "Symphony needs at least one repo."
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
                + "acme/web stays on disk unless you delete it too."
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

    func testTheSheetPicksTheNewDefaultOnlyForTheDefaultRepo() {
        let local = DisconnectRepo.Sheet(entry: symphony, entries: entries)
        XCTAssertEqual(local.key, "symphony")
        XCTAssertEqual(local.title, "Disconnect symphony?")
        XCTAssertEqual(local.message, DisconnectRepo.question(for: symphony, newDefaultNeeded: true).message)
        XCTAssertEqual(local.candidates, ["web"])
        XCTAssertNil(local.gitHub)

        let managed = DisconnectRepo.Sheet(entry: web, entries: entries)
        XCTAssertNil(managed.candidates)
        XCTAssertEqual(managed.gitHub, "acme/web")
        XCTAssertEqual(managed.message, DisconnectRepo.question(for: web, newDefaultNeeded: false).message)
    }

    func testTheCloneCheckboxIsOnOnlyWhileTheCloneCanBeDeleted() {
        let home = NSHomeDirectory()
        var repo = RepoDetail(
            key: "web",
            source: RepoDetail.Source(kind: .managed, path: home + "/clones/acme/web", baseBranch: "main", managedGitHub: "acme/web"),
            routing: RepoDetail.Routing(sentence: ""),
            live: .folded(line: "", canStart: false),
            actions: RepoActions(cloneRemoval: .allowed(path: home + "/clones/acme/web"))
        )
        XCTAssertEqual(
            DisconnectRepo.cloneOption(for: repo),
            DisconnectRepo.CloneOption(title: "Also delete Symphony's clone (~/clones/acme/web)", path: home + "/clones/acme/web")
        )
        XCTAssertEqual(DisconnectRepo.cloneOption(for: repo)?.isEnabled, true)

        repo.actions.cloneRemoval = .blocked("TP-1 runs in a worktree of this clone.")
        let blocked = DisconnectRepo.cloneOption(for: repo)
        XCTAssertEqual(blocked?.title, "Also delete Symphony's clone (~/clones/acme/web)")
        XCTAssertEqual(blocked?.reason, "TP-1 runs in a worktree of this clone.")
        XCTAssertEqual(blocked?.isEnabled, false)

        // Symphony didn't report the path: the title has none.
        repo.source.path = nil
        XCTAssertEqual(DisconnectRepo.cloneOption(for: repo)?.title, "Also delete Symphony's clone")

        // No checkbox before the first clone, for a local folder, or without a removal state.
        repo.source.notCloned = true
        XCTAssertNil(DisconnectRepo.cloneOption(for: repo))
        repo.source = RepoDetail.Source(kind: .local, path: "/Users/me/web", baseBranch: "main")
        XCTAssertNil(DisconnectRepo.cloneOption(for: repo))
        repo.source = RepoDetail.Source(kind: .managed, path: "/c", baseBranch: "main", managedGitHub: "acme/web")
        repo.actions.cloneRemoval = nil
        XCTAssertNil(DisconnectRepo.cloneOption(for: repo))
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
