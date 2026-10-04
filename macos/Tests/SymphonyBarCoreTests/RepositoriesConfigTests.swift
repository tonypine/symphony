import XCTest
@testable import SymphonyBarCore

final class RepositoriesConfigTests: XCTestCase {
    /// The shape of the repo's own `symphony.yml`, with commented-out keys inside the entry.
    private let config = """
        # Symphony operator config.
        issues:
          provider: linear

        repositories:
          - key: symphony
            # default: true
            # base_branch: main
            workflow: WORKFLOW.md  # repo-local prompt
            route:
              # team: ENG
              # labels: [backend]
              # assignee: me
              projects: ["building-the-harness"]
            workspace:
              strategy: worktree
              repo: ~/Projects/symphony
              fetch_before_dispatch: true

        workspaces:
          root: ~/Projects/symphony-workspaces

        """

    private let symphony = RepositoryEntry(
        key: "symphony",
        workflow: "WORKFLOW.md",
        route: RepositoryRoute(projects: ["building-the-harness"]),
        workspace: RepositoryWorkspace(strategy: "worktree", repo: "~/Projects/symphony", fetchBeforeDispatch: true)
    )

    /// Entries separated by blank lines, with block lists, comments and a trailing comment on a key.
    private let several = """
        repositories:
          # Main app.
          - key: web
            workflow: WORKFLOW.md
            route:
              projects: [web]

          - key: api   # backend
            route:
              labels:
                - api
                - 'back''end'
            workspace:
              repo: ~/code/api
              # keep fetching
              fetch_before_dispatch: true

          - key: docs
            route:
              team: DOCS

        workspaces:
          root: ~/w

        """

    // MARK: Reading

    func testReadsTheEntry() throws {
        XCTAssertEqual(try RepositoriesConfig.entries(in: config), [symphony])
    }

    func testReadsBlockListsQuotesAndComments() throws {
        XCTAssertEqual(try RepositoriesConfig.entries(in: several), [
            RepositoryEntry(key: "web", workflow: "WORKFLOW.md", route: RepositoryRoute(projects: ["web"])),
            RepositoryEntry(
                key: "api",
                route: RepositoryRoute(labels: ["api", "back'end"]),
                workspace: RepositoryWorkspace(repo: "~/code/api", fetchBeforeDispatch: true)
            ),
            RepositoryEntry(key: "docs", route: RepositoryRoute(team: "DOCS")),
        ])
    }

    func testReadsEveryField() throws {
        let yaml = """
            repositories:
              - key: "api"
                default: True
                base_branch: 'release/1.0'
                workflow: ./workflows/api.md
                unknown_key: kept
                route:
                  team: ENG
                  projects: [a, "b, c", 'd']
                  labels: []
                  assignee: me
                workspace:
                  strategy: clone
                  source: "https://github.com/acme/api.git"
                  fetch_before_dispatch: false
              - key: nulls
                default:
                base_branch: ~
                workflow: null
                route:
                  labels:
                  projects: ~
                workspace:
            """
        XCTAssertEqual(try RepositoriesConfig.entries(in: yaml), [
            RepositoryEntry(
                key: "api",
                isDefault: true,
                baseBranch: "release/1.0",
                workflow: "./workflows/api.md",
                route: RepositoryRoute(team: "ENG", projects: ["a", "b, c", "d"], labels: [], assignee: "me"),
                workspace: RepositoryWorkspace(strategy: "clone", source: "https://github.com/acme/api.git", fetchBeforeDispatch: false)
            ),
            RepositoryEntry(key: "nulls"),
        ])
    }

    func testDecodesDoubleQuotedEscapes() throws {
        let yaml = #"repositories:\#n  - key: "a\"b\\c\/d\n\t\r\u00e9 # not a comment"  # comment\#n"#
        XCTAssertEqual(try RepositoriesConfig.entries(in: yaml).map(\.key), ["a\"b\\c/d\n\t\ré # not a comment"])
    }

    func testMissingSectionReadsAsNoEntries() throws {
        XCTAssertEqual(try RepositoriesConfig.entries(in: "issues:\n  provider: linear\n"), [])
        XCTAssertEqual(try RepositoriesConfig.entries(in: "repositories:\n  # - key: none\n"), [])
    }

    // MARK: Round trip

    func testRoundTripOfTheReposOwnConfigsKeepsEveryByte() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["symphony.yml", "symphony.claude.yml"] {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            let entries = try RepositoriesConfig.entries(in: text)
            XCTAssertFalse(entries.isEmpty, name)
            for entry in entries {
                XCTAssertEqual(try RepositoriesConfig.updating(entry.key, to: entry, in: text), text, name)
            }
        }
    }

    func testRoundTripKeepsEveryByte() throws {
        for yaml in [config, several, config.replacingOccurrences(of: "\n", with: "\r\n")] {
            for entry in try RepositoriesConfig.entries(in: yaml) {
                XCTAssertEqual(try RepositoriesConfig.updating(entry.key, to: entry, in: yaml), yaml)
            }
        }
    }

    // MARK: Adding

    func testAddsALocalFolderAfterTheLastEntry() throws {
        let web = RepositoryEntry(
            key: "web",
            workflow: "WORKFLOW.md",
            route: RepositoryRoute(projects: ["web-platform"]),
            workspace: RepositoryWorkspace(strategy: "worktree", repo: "~/code/web", fetchBeforeDispatch: true)
        )
        let expected = config.replacingOccurrences(of: """
                  fetch_before_dispatch: true

            workspaces:
            """, with: """
                  fetch_before_dispatch: true
              - key: web
                workflow: WORKFLOW.md
                route:
                  projects: [web-platform]
                workspace:
                  strategy: worktree
                  repo: ~/code/web
                  fetch_before_dispatch: true

            workspaces:
            """)

        let updated = try RepositoriesConfig.adding(web, to: config)

        XCTAssertEqual(updated, expected)
        XCTAssertEqual(try RepositoriesConfig.entries(in: updated), [symphony, web])
    }

    func testAddsAManagedSource() throws {
        let api = RepositoryEntry(
            key: "api",
            isDefault: true,
            baseBranch: "main",
            route: RepositoryRoute(team: "ENG", labels: ["api", "on"]),
            workspace: RepositoryWorkspace(strategy: "clone", source: "https://github.com/acme/api.git", fetchBeforeDispatch: false)
        )
        let expected = config.replacingOccurrences(of: """
                  fetch_before_dispatch: true

            """, with: """
                  fetch_before_dispatch: true
              - key: api
                default: true
                base_branch: main
                route:
                  team: ENG
                  labels: [api, "on"]
                workspace:
                  strategy: clone
                  source: https://github.com/acme/api.git
                  fetch_before_dispatch: false

            """)

        let updated = try RepositoriesConfig.adding(api, to: config)

        XCTAssertEqual(updated, expected)
        XCTAssertEqual(try RepositoriesConfig.entries(in: updated).last, api)
    }

    func testAddKeepsBlankLinesBetweenEntries() throws {
        let expected = several.replacingOccurrences(of: """
                  team: DOCS

            """, with: """
                  team: DOCS

              - key: new
                workflow: "1.md"

            """)
        XCTAssertEqual(try RepositoriesConfig.adding(RepositoryEntry(key: "new", workflow: "1.md"), to: several), expected)
    }

    func testAddFollowsTheFilesIndentation() throws {
        let yaml = "repositories:\n- key: a\n  route:\n      team: A\nagent:\n  runtime: codex\n"
        let entry = RepositoryEntry(key: "b", route: RepositoryRoute(team: "B"))
        XCTAssertEqual(
            try RepositoriesConfig.adding(entry, to: yaml),
            "repositories:\n- key: a\n  route:\n      team: A\n- key: b\n  route:\n      team: B\nagent:\n  runtime: codex\n"
        )
    }

    func testAddCreatesTheSectionWhenMissing() throws {
        let entry = RepositoryEntry(key: "web", workspace: RepositoryWorkspace(repo: "~/code/web"))
        let section = "repositories:\n  - key: web\n    workspace:\n      repo: ~/code/web\n"
        XCTAssertEqual(try RepositoriesConfig.adding(entry, to: "issues:\n  provider: linear\n"), "issues:\n  provider: linear\n\n" + section)
        XCTAssertEqual(try RepositoriesConfig.adding(entry, to: "issues:\n  provider: linear\n\n"), "issues:\n  provider: linear\n\n" + section)
        XCTAssertEqual(try RepositoriesConfig.adding(entry, to: ""), section)
        XCTAssertEqual(
            try RepositoriesConfig.adding(entry, to: "issues: {}"),
            "issues: {}\n\n" + section.dropLast()
        )
    }

    func testAddToAnEmptySectionGoesRightUnderIt() throws {
        XCTAssertEqual(
            try RepositoriesConfig.adding(RepositoryEntry(key: "a"), to: "repositories:\n  # none yet\nagent: {}\n"),
            "repositories:\n  - key: a\n  # none yet\nagent: {}\n"
        )
    }

    func testAddKeepsWindowsLineEndings() throws {
        let yaml = config.replacingOccurrences(of: "\n", with: "\r\n")
        let updated = try RepositoriesConfig.adding(RepositoryEntry(key: "web"), to: yaml)
        XCTAssertEqual(updated, yaml.replacingOccurrences(of: "true\r\n\r\nworkspaces", with: "true\r\n  - key: web\r\n\r\nworkspaces"))
    }

    func testAddRejectsADuplicateKey() {
        XCTAssertThrowsError(try RepositoriesConfig.adding(RepositoryEntry(key: "symphony"), to: config)) { error in
            XCTAssertEqual(error as? RepositoriesConfigError, .duplicateKey("symphony"))
        }
    }

    func testAddRejectsAnEmptyKey() {
        XCTAssertThrowsError(try RepositoriesConfig.adding(RepositoryEntry(key: "  "), to: config)) { error in
            XCTAssertEqual(error as? RepositoriesConfigError, .invalidEntry("A repository needs a key."))
        }
    }

    // MARK: Updating

    func testSwitchesALocalFolderToAManagedSource() throws {
        var entry = symphony
        entry.workspace = RepositoryWorkspace(strategy: "clone", source: "git@github.com:acme/symphony.git")
        let expected = config.replacingOccurrences(of: """
                  strategy: worktree
                  repo: ~/Projects/symphony
                  fetch_before_dispatch: true
            """, with: """
                  strategy: clone
                  source: git@github.com:acme/symphony.git
            """)

        let updated = try RepositoriesConfig.updating("symphony", to: entry, in: config)

        XCTAssertEqual(updated, expected)
        XCTAssertEqual(try RepositoriesConfig.entries(in: updated), [entry])

        // And back again.
        XCTAssertEqual(try RepositoriesConfig.updating("symphony", to: symphony, in: updated), config)
    }

    func testChangesRoutingAndKeepsTheCommentsInside() throws {
        var entry = symphony
        entry.route = RepositoryRoute(team: "ENG", projects: ["building-the-harness", "web"], assignee: "me")
        entry.workflow = "docs/WORKFLOW.md"
        let expected = config.replacingOccurrences(of: """
                workflow: WORKFLOW.md  # repo-local prompt
                route:
                  # team: ENG
                  # labels: [backend]
                  # assignee: me
                  projects: ["building-the-harness"]
            """, with: """
                workflow: docs/WORKFLOW.md  # repo-local prompt
                route:
                  team: ENG
                  # team: ENG
                  # labels: [backend]
                  # assignee: me
                  projects: [building-the-harness, web]
                  assignee: me
            """)

        XCTAssertEqual(try RepositoriesConfig.updating("symphony", to: entry, in: config), expected)
    }

    func testSetsAndClearsTopLevelFields() throws {
        var entry = symphony
        entry.isDefault = true
        entry.baseBranch = "main"
        entry.workflow = nil
        let expected = config.replacingOccurrences(of: """
              - key: symphony
                # default: true
                # base_branch: main
                workflow: WORKFLOW.md  # repo-local prompt

            """, with: """
              - key: symphony
                default: true
                base_branch: main
                # default: true
                # base_branch: main

            """)

        XCTAssertEqual(try RepositoriesConfig.updating("symphony", to: entry, in: config), expected)
    }

    func testRemovesAnEmptiedBlockWithItsComments() throws {
        var entry = symphony
        entry.route = RepositoryRoute()
        let expected = config.replacingOccurrences(of: """
                route:
                  # team: ENG
                  # labels: [backend]
                  # assignee: me
                  projects: ["building-the-harness"]

            """, with: "")

        XCTAssertEqual(try RepositoriesConfig.updating("symphony", to: entry, in: config), expected)
    }

    func testKeepsABlockThatStillHoldsUnknownKeys() throws {
        let yaml = "repositories:\n  - key: a\n    route:\n      team: A\n      future: x\n"
        XCTAssertEqual(
            try RepositoriesConfig.updating("a", to: RepositoryEntry(key: "a"), in: yaml),
            "repositories:\n  - key: a\n    route:\n      future: x\n"
        )
    }

    func testAddsAMissingBlockInKeyOrder() throws {
        let entry = RepositoryEntry(key: "docs", workflow: "W.md", route: RepositoryRoute(team: "DOCS"), workspace: RepositoryWorkspace(repo: "~/d"))
        let expected = several.replacingOccurrences(of: """
              - key: docs
                route:
                  team: DOCS

            """, with: """
              - key: docs
                workflow: W.md
                route:
                  team: DOCS
                workspace:
                  repo: ~/d

            """)

        XCTAssertEqual(try RepositoriesConfig.updating("docs", to: entry, in: several), expected)
    }

    func testFillsAnEmptyBlock() throws {
        let yaml = "repositories:\n  - key: a\n    route:\n      # team: X\n    workspace:\n"
        let entry = RepositoryEntry(key: "a", route: RepositoryRoute(team: "A"), workspace: RepositoryWorkspace(repo: "~/a"))
        XCTAssertEqual(
            try RepositoriesConfig.updating("a", to: entry, in: yaml),
            "repositories:\n  - key: a\n    route:\n      team: A\n      # team: X\n    workspace:\n      repo: ~/a\n"
        )
    }

    func testRewritesBlockListsInPlace() throws {
        var api = try XCTUnwrap(RepositoriesConfig.entries(in: several).first { $0.key == "api" })

        api.route.labels = ["api", "infra"]
        XCTAssertEqual(
            try RepositoriesConfig.updating("api", to: api, in: several),
            several.replacingOccurrences(of: "        - 'back''end'\n", with: "        - infra\n")
        )

        api.route.labels = []
        XCTAssertEqual(
            try RepositoriesConfig.updating("api", to: api, in: several),
            several.replacingOccurrences(of: "      labels:\n        - api\n        - 'back''end'\n", with: "      labels: []\n")
        )
    }

    func testFillsANullValue() throws {
        let yaml = "repositories:\n  - key: a\n    base_branch:   # pick one\n    workflow: ~\n"
        XCTAssertEqual(
            try RepositoriesConfig.updating("a", to: RepositoryEntry(key: "a", baseBranch: "main"), in: yaml),
            "repositories:\n  - key: a\n    base_branch: main # pick one\n    workflow: ~\n"
        )
    }

    func testRenamesAnEntry() throws {
        var entry = symphony
        entry.key = "harness"
        XCTAssertEqual(
            try RepositoriesConfig.updating("symphony", to: entry, in: config),
            config.replacingOccurrences(of: "- key: symphony", with: "- key: harness")
        )
        XCTAssertEqual(
            try RepositoriesConfig.updating("api", to: RepositoryEntry(key: "API 2"), in: several)
                .contains("  - key: \"API 2\"   # backend\n"),
            true
        )
    }

    func testRenameRejectsADuplicateKey() {
        XCTAssertThrowsError(try RepositoriesConfig.updating("api", to: RepositoryEntry(key: "web"), in: several)) { error in
            XCTAssertEqual(error as? RepositoriesConfigError, .duplicateKey("web"))
        }
    }

    func testUpdateChangesOnlyTheTargetedEntry() throws {
        let updated = try RepositoriesConfig.updating("api", to: RepositoryEntry(key: "api"), in: several)
        XCTAssertEqual(updated, several.replacingOccurrences(of: """
              - key: api   # backend
                route:
                  labels:
                    - api
                    - 'back''end'
                workspace:
                  repo: ~/code/api
                  # keep fetching
                  fetch_before_dispatch: true

            """, with: """
              - key: api   # backend

            """))
    }

    func testUpdateOfAMissingKeyFails() {
        XCTAssertThrowsError(try RepositoriesConfig.updating("nope", to: RepositoryEntry(key: "nope"), in: config)) { error in
            XCTAssertEqual(error as? RepositoriesConfigError, .notFound("nope"))
        }
    }

    // MARK: Removing

    func testRemovesAMiddleEntryAndOneSeparator() throws {
        XCTAssertEqual(try RepositoriesConfig.removing("api", from: several), """
            repositories:
              # Main app.
              - key: web
                workflow: WORKFLOW.md
                route:
                  projects: [web]

              - key: docs
                route:
                  team: DOCS

            workspaces:
              root: ~/w

            """)
    }

    func testRemovesTheFirstEntryWithTheCommentAttachedAboveIt() throws {
        let updated = try RepositoriesConfig.removing("web", from: several)
        XCTAssertEqual(updated, several.replacingOccurrences(of: """
              # Main app.
              - key: web
                workflow: WORKFLOW.md
                route:
                  projects: [web]


            """, with: ""))
    }

    /// The shape of Tony's own config: entries separated by blank lines, an opt-in repo last with a comment
    /// block attached above it, and a commented-out key under the entry before it.
    func testRemovesAnEntryWithItsCommentBlockAndNoDoubledBlankLine() throws {
        let tonys = """
            repositories:
              - key: symphony
                default: true
                workflow: WORKFLOW.md
                route:
                  projects: ["building-the-harness"]
                workspace:
                  repo: ~/Projects/symphony
                  # source: tonypine/symphony

              # Opt-in only: Job Search Hub tickets need the job-search label,
              # so they never land in symphony.
              - key: job-search-hub
                route:
                  labels: [job-search]
                workspace:
                  repo: ~/Projects/job-search-hub

            # Unrelated comment above the next section.
            workspaces:
              root: ~/Projects/symphony-workspaces

            """
        let expected = """
            repositories:
              - key: symphony
                default: true
                workflow: WORKFLOW.md
                route:
                  projects: ["building-the-harness"]
                workspace:
                  repo: ~/Projects/symphony
                  # source: tonypine/symphony

            # Unrelated comment above the next section.
            workspaces:
              root: ~/Projects/symphony-workspaces

            """
        XCTAssertEqual(try RepositoriesConfig.removing("job-search-hub", from: tonys), expected)

        // In the middle too: the comment block goes, one blank line separates the neighbours.
        let middle = tonys.replacingOccurrences(of: "\n# Unrelated", with: """

              - key: docs
                route:
                  team: DOCS

            # Unrelated
            """)
        let removed = try RepositoriesConfig.removing("job-search-hub", from: middle)
        XCTAssertFalse(removed.contains("Opt-in"))
        XCTAssertFalse(removed.contains("\n\n\n"))
        XCTAssertTrue(removed.contains("# source: tonypine/symphony\n\n  - key: docs\n"))
        XCTAssertEqual(try RepositoriesConfig.entries(in: removed).map(\.key), ["symphony", "docs"])
    }

    func testKeepsCommentsSeparatedByABlankLineOrIndentedUnderThePreviousEntry() throws {
        let yaml = """
            repositories:
              # About every repo.

              - key: a
                route:
                  team: A
                # trailing note on a
              - key: b
                route:
                  team: B
            """
        XCTAssertEqual(try RepositoriesConfig.removing("b", from: yaml), """
            repositories:
              # About every repo.

              - key: a
                route:
                  team: A
                # trailing note on a
            """)
        XCTAssertEqual(try RepositoriesConfig.removing("a", from: yaml), """
            repositories:
              # About every repo.

              - key: b
                route:
                  team: B
            """)
    }

    func testRemovesTheLastEntry() throws {
        XCTAssertEqual(
            try RepositoriesConfig.removing("docs", from: several),
            several.replacingOccurrences(of: "\n  - key: docs\n    route:\n      team: DOCS\n", with: "")
        )
        let atEnd = "repositories:\n  - key: a\n\n  - key: b\n"
        XCTAssertEqual(try RepositoriesConfig.removing("b", from: atEnd), "repositories:\n  - key: a\n")
        XCTAssertEqual(try RepositoriesConfig.removing("a", from: atEnd), "repositories:\n  - key: b\n")
        XCTAssertEqual(try RepositoriesConfig.removing("a", from: "repositories:\n- key: a\n- key: b"), "repositories:\n- key: b")
    }

    func testRefusesToRemoveTheOnlyEntry() {
        XCTAssertThrowsError(try RepositoriesConfig.removing("symphony", from: config)) { error in
            XCTAssertEqual(error as? RepositoriesConfigError, .lastRepository("symphony"))
        }
        XCTAssertThrowsError(try RepositoriesConfig.removing("nope", from: config)) { error in
            XCTAssertEqual(error as? RepositoriesConfigError, .notFound("nope"))
        }
    }

    // MARK: Unsupported YAML

    func testRejectsUnsupportedShapes() {
        let cases: [(String, Int)] = [
            ("repositories: [{key: a}]\n", 1),
            ("repositories: []\n", 1),
            ("repositories: &repos\n  - key: a\n", 1),
            ("repositories:\n  - key: &k a\n", 2),
            ("repositories:\n  - key: a\n    route: *shared\n", 3),
            ("repositories:\n  - key: a\n    <<: *defaults\n", 3),
            ("repositories:\n  - key: a\n    workflow: !!str W.md\n", 3),
            ("repositories:\n  - key: a\n    workflow: |\n      W.md\n", 3),
            ("repositories:\n  - key: a\n    route: {team: ENG}\n", 3),
            ("repositories:\n  - key: a\n    extra:\n      deep: &x 1\n", 4),
            ("repositories:\n  - key: a\n    key: b\n", 3),
            ("repositories:\n  - key: a\n    route:\n      team: A\n      team: B\n", 5),
            ("repositories:\n  - key: a\n\tworkflow: W.md\n", 3),
            ("repositories:\n  - key: a\n    workflow: one\n      two\n", 4),
            ("repositories:\n  - key: \"a\n", 2),
            ("repositories:\n  - key: a\n    route:\n      projects: [a,\n        b]\n", 4),
            ("repositories:\n  - key: a\n    route:\n      projects: [[a]]\n", 4),
            ("repositories:\n  - key: a\n    route:\n      projects: [a: b]\n", 4),
            ("repositories:\n  - key: a\n    route:\n      projects: [a, , b]\n", 4),
            ("repositories:\n  - key: a\n    route:\n      projects: [*alias]\n", 4),
            ("repositories:\n  - key: a\n    just text\n", 3),
            ("repositories:\n  - key: a\n    route:\n      projects: a\n", 4),
            ("repositories:\n  - key: a\n    route:\n      labels:\n        - x: y\n", 5),
            ("repositories:\n  - key: a\n    route:\n      labels:\n        -\n", 5),
            ("repositories:\n  - key: a\n    route:\n      labels:\n        - a\n          - b\n", 6),
            ("repositories:\n  - key: a\n    route:\n      team: [A]\n", 4),
            ("repositories:\n  - key: a\n    route:\n      team:\n        name: A\n", 5),
            ("repositories:\n  - key: a\n    route:\n      - team: A\n", 4),
            ("repositories:\n  - key: a\n    route: x\n", 3),
            ("repositories:\n  - key: a\n    default: maybe\n", 3),
            ("repositories:\n  - key: a\n    workflow: \"\\q\"\n", 3),
            ("repositories:\n  - key: a\n    workflow: \"\\u12\"\n", 3),
            ("repositories:\n  - key: a\n    workflow: \"x\\\"\n", 3),
            ("repositories:\n  - key: a\n    workflow: \"a\" b\n", 3),
            ("repositories:\n  - key: a\n    workflow: - x\n", 3),
            ("repositories:\n  - key: a\n    workflow: a: b\n", 3),
            ("repositories:\n  - key: a\n    \"quoted\": b\n", 3),
            ("repositories:\n  - key: a\n   workflow: W.md\n", 3),
            ("repositories:\n  - key: a\n  workflow: W.md\n", 3),
            ("repositories:\n  - key: a\n - key: b\n", 3),
            ("repositories:\n  key: a\n", 2),
            ("repositories:\n  -\n    key: a\n", 2),
            ("repositories:\n  - # first\n    key: a\n", 2),
            ("repositories:\n  - workflow: W.md\n", 2),
            ("repositories:\n  - key: ''\n", 2),
            ("repositories:\n  - key: a\nrepositories:\n  - key: b\n", 3),
        ]
        for (yaml, line) in cases {
            XCTAssertThrowsError(try RepositoriesConfig.entries(in: yaml), yaml) { error in
                guard case .unsupported(let errorLine, _)? = error as? RepositoriesConfigError else {
                    return XCTFail("\(yaml): \(error)")
                }
                XCTAssertEqual(errorLine, line, yaml)
            }
            XCTAssertThrowsError(try RepositoriesConfig.adding(RepositoryEntry(key: "new"), to: yaml), yaml)
            XCTAssertThrowsError(try RepositoriesConfig.removing("a", from: yaml), yaml)
            XCTAssertThrowsError(try RepositoriesConfig.updating("a", to: RepositoryEntry(key: "a"), in: yaml), yaml)
        }
    }

    func testRejectsDuplicateRepositoryKeysInTheFile() {
        XCTAssertThrowsError(try RepositoriesConfig.entries(in: "repositories:\n  - key: a\n  - key: a\n")) { error in
            XCTAssertEqual(error as? RepositoriesConfigError, .duplicateKey("a"))
        }
    }

    func testIgnoresUnsupportedYAMLOutsideTheSection() throws {
        let yaml = "defaults: &d\n  x: 1\nrepositories:\n  - key: a\nagent:\n  <<: *d\n"
        XCTAssertEqual(try RepositoriesConfig.entries(in: yaml), [RepositoryEntry(key: "a")])
    }

    func testErrorDescriptions() {
        XCTAssertEqual(
            RepositoriesConfigError.unsupported(line: 3, reason: "`a` appears twice").errorDescription,
            "symphony.yml line 3: `a` appears twice. Edit repositories by hand."
        )
        XCTAssertEqual(RepositoriesConfigError.duplicateKey("a").errorDescription, "A repository with key `a` already exists.")
        XCTAssertEqual(RepositoriesConfigError.notFound("a").errorDescription, "symphony.yml has no repository with key `a`.")
        XCTAssertEqual(RepositoriesConfigError.invalidEntry("Nope.").errorDescription, "Nope.")
        XCTAssertEqual(
            RepositoriesConfigError.lastRepository("a").errorDescription,
            "`a` is the only repository, and Symphony needs at least one."
        )
    }

    // MARK: Scalars

    func testWritesPlainScalarsOnlyWhenTheyReadBackTheSame() throws {
        let plain = ["main", "~/code/web", "./WORKFLOW.md", "../w.md", "/abs/path", "_x", "https://github.com/a/b.git", "git@github.com:a/b.git", "TP-259"]
        for string in plain {
            XCTAssertEqual(RepositoriesConfig.scalar(string), string)
        }
        let quoted = [
            "": #""""#, "123": #""123""#, "yes": #""yes""#, "Off": #""Off""#, "~": #""~""#, "a b": #""a b""#,
            "a:": #""a:""#, "#x": ##""#x""##, "-x": #""-x""#, ".5": #"".5""#, "é": #""é""#,
            "say \"hi\" \\ bye": #""say \"hi\" \\ bye""#, "a\nb\tc\rd\u{1}": #""a\nb\tc\rd\u0001""#,
        ]
        for (string, expected) in quoted {
            XCTAssertEqual(RepositoriesConfig.scalar(string), expected, string)
        }
        // Whatever is written reads back as the same string.
        for string in plain + Array(quoted.keys) where !string.isEmpty {
            let yaml = try RepositoriesConfig.adding(RepositoryEntry(key: string, route: RepositoryRoute(labels: [string])), to: "")
            XCTAssertEqual(try RepositoriesConfig.entries(in: yaml), [RepositoryEntry(key: string, route: RepositoryRoute(labels: [string]))])
        }
    }

    // MARK: File

    func testFileAddsUpdatesAndRemovesAtomically() throws {
        let url = try temporaryConfig(several)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = SymphonyConfigFile(path: url.path)

        try file.addRepository(RepositoryEntry(key: "new"))
        XCTAssertEqual(try file.readRepositories().map(\.key), ["web", "api", "docs", "new"])
        try file.updateRepository("new", to: RepositoryEntry(key: "new", workflow: "W.md"))
        XCTAssertEqual(try file.readRepositories().last, RepositoryEntry(key: "new", workflow: "W.md"))
        try file.removeRepository("new")

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), several)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testFileIsNotWrittenWhenAnEditFails() throws {
        let unsupported = "repositories:\n  - key: a\n    route: {team: A}\n"
        for (text, edit) in [
            (unsupported, { (file: SymphonyConfigFile) in try file.addRepository(RepositoryEntry(key: "b")) }),
            (config, { file in try file.addRepository(RepositoryEntry(key: "symphony")) }),
            (config, { file in try file.removeRepository("symphony") }),
            (config, { file in try file.updateRepository("nope", to: RepositoryEntry(key: "nope")) }),
        ] {
            let url = try temporaryConfig(text)
            let before = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int

            XCTAssertThrowsError(try edit(SymphonyConfigFile(path: url.path)))

            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int, before)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["symphony.yml"])
        }
    }

    private func temporaryConfig(_ text: String) throws -> URL {
        let directory = uniqueTemporaryDirectory("repositories-config")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("symphony.yml")
        try text.write(to: url, atomically: false, encoding: .utf8)
        return url
    }
}
