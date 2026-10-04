import XCTest
@testable import SymphonyBarCore

final class ReposListTests: XCTestCase {
    /// `GET /api/v1/repos` in the shape Symphony serves it: a local repo with a running agent, a managed clone
    /// with an invalid `WORKFLOW.md` and a failed fetch, and a repo with no GitHub remote and no `WORKFLOW.md`.
    private func recordedRepos() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/repos-running.json")
        return try Data(contentsOf: url)
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private let running = SymphonyStatus.running(StateSnapshot(), external: false)

    private var symphony: RepoStatus {
        RepoStatus(
            key: "symphony",
            isDefault: true,
            baseBranch: "main",
            source: .local(path: "/Projects/symphony"),
            github: "tonypine/symphony",
            route: RepositoryRoute(projects: ["building-the-harness"], labels: []),
            workflow: .init(path: "/Projects/symphony/WORKFLOW.md", state: .valid),
            lastFetch: .init(at: date("2026-10-04T14:05:00Z"), succeeded: true),
            worktrees: [.init(issueIdentifier: "TP-260", path: "/Projects/symphony-workspaces/symphony/TP-260")]
        )
    }

    private var api: RepoStatus {
        RepoStatus(
            key: "api",
            source: .managed(github: "acme/api", clonePath: "/Clones/repos/acme/api", cloned: false),
            github: "acme/api",
            route: RepositoryRoute(team: "ENG", projects: ["api", "billing"], labels: ["backend"], assignee: "me"),
            workflow: .init(
                path: "/Clones/repos/acme/api/WORKFLOW.md",
                state: .invalid,
                error: "Failed to parse WORKFLOW.md: malformed yaml"
            ),
            lastFetch: .init(
                at: date("2026-10-04T12:00:00Z"),
                succeeded: false,
                error: "git fetch exited with status 128: fatal: Could not read from remote repository."
            )
        )
    }

    private var docs: RepoStatus {
        RepoStatus(
            key: "docs",
            source: .local(path: "/Projects/docs"),
            route: RepositoryRoute(projects: [], labels: ["docs"]),
            workflow: .init(path: "/Projects/docs/WORKFLOW.md", state: .missing, error: "missing_workflow_file"),
            worktrees: [
                .init(issueIdentifier: "TP-7", path: "/srv/workspaces/docs/TP-7", workerHost: "worker-1"),
                .init(issueIdentifier: "ghi789"),
            ]
        )
    }

    // MARK: - Decoding

    func testDecodesTheRecordedRepos() throws {
        XCTAssertEqual(
            ReposAPI.poll(data: try recordedRepos(), statusCode: 200),
            .repos([symphony, api, docs], warning: nil)
        )
    }

    func testKeepsTheReposWhenTheSnapshotTimedOut() {
        let data = Data(#"""
            {"repos": [{"key": "web"}], "error": {"code": "snapshot_timeout", "message": "Snapshot timed out"}}
            """#.utf8)

        XCTAssertEqual(
            ReposAPI.poll(data: data, statusCode: 200),
            .repos([RepoStatus(key: "web", workflow: .init(state: .other("unknown")))], warning: "Snapshot timed out")
        )
    }

    func testKeepsAWorkflowStatusItDoesNotKnow() {
        let data = Data(#"{"repos": [{"key": "web", "workflow": {"status": "stale"}}]}"#.utf8)

        guard case let .repos(repos, _) = ReposAPI.poll(data: data, statusCode: 200) else { return XCTFail() }
        XCTAssertEqual(repos.first?.workflow.state, .other("stale"))
    }

    func testAManagedSourceWithoutItsRepoReadsAsLocal() {
        let data = Data(#"{"repos": [{"key": "web", "source": {"kind": "managed"}}]}"#.utf8)

        guard case let .repos(repos, _) = ReposAPI.poll(data: data, statusCode: 200) else { return XCTFail() }
        XCTAssertEqual(repos.first?.source, .local(path: nil))
    }

    func testAnOlderSymphonyAnswers404() {
        XCTAssertEqual(ReposAPI.poll(data: Data("Not Found".utf8), statusCode: 404), .unsupported)
    }

    func testConfigUnavailableCarriesSymphonysMessage() {
        let data = Data(#"{"error": {"code": "config_unavailable", "message": "repositories is invalid"}}"#.utf8)

        XCTAssertEqual(ReposAPI.poll(data: data, statusCode: 503), .failed("repositories is invalid (HTTP 503)"))
        XCTAssertEqual(
            ReposAPI.poll(data: Data(#"{"error": {"code": "boom"}}"#.utf8), statusCode: 500),
            .failed("boom (HTTP 500)")
        )
        XCTAssertEqual(ReposAPI.poll(data: Data(), statusCode: 502), .failed("Symphony answered with HTTP 502"))
    }

    func testAnUnreadableBodyFails() {
        XCTAssertEqual(ReposAPI.poll(data: Data("<html>".utf8), statusCode: 200), .failed("Symphony's repos couldn't be read"))
        XCTAssertEqual(ReposAPI.poll(data: Data("{}".utf8), statusCode: 200), .failed("Symphony's repos couldn't be read"))
    }

    // MARK: - Fetching

    private var root: URL!

    override func setUpWithError() throws {
        root = uniqueTemporaryDirectory("repos-list")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFetchAsksTheControlURLInTheStateRoot() async throws {
        try "http://127.0.0.1:4010\n".write(to: root.appendingPathComponent("control_url"), atomically: false, encoding: .utf8)
        let body = try recordedRepos()
        var sent: URLRequest?

        let poll = await ReposAPI.fetch(stateRoot: root, fallback: nil) { request in
            sent = request
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        XCTAssertEqual(sent?.url?.absoluteString, "http://127.0.0.1:4010/api/v1/repos")
        XCTAssertEqual(sent?.httpMethod, "GET")
        XCTAssertNil(sent?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(poll, .repos([symphony, api, docs], warning: nil))
    }

    func testFetchIsUnreachableWithoutAControlURLOrAnAnswer() async {
        let noURL = await ReposAPI.fetch(stateRoot: root, fallback: nil) { _ in
            XCTFail("nothing to ask")
            throw URLError(.badURL)
        }
        XCTAssertEqual(noURL, .unreachable)

        let noAnswer = await ReposAPI.fetch(stateRoot: root, fallback: URL(string: "http://127.0.0.1:4010")!) { _ in
            throw URLError(.cannotConnectToHost)
        }
        XCTAssertEqual(noAnswer, .unreachable)
    }

    // MARK: - Rows from a running Symphony

    private let now = ISO8601DateFormatter().date(from: "2026-10-04T14:10:00Z")!

    func testFormatsALocalRepoWithARunningAgent() {
        XCTAssertEqual(
            ReposList.row(symphony, now: now),
            RepoRow(
                key: "symphony",
                isDefault: true,
                fields: [
                    RepoField("Source", "Local folder", detail: "/Projects/symphony"),
                    RepoField("GitHub", "tonypine/symphony"),
                    RepoField("Linear", "project building-the-harness"),
                    RepoField("WORKFLOW.md", "found, valid", detail: "/Projects/symphony/WORKFLOW.md"),
                    RepoField("Last fetch", "5m ago, ok"),
                    RepoField("Agents", "TP-260", detail: "/Projects/symphony-workspaces/symphony/TP-260"),
                ]
            )
        )
    }

    func testFormatsAManagedCloneWithProblems() {
        XCTAssertEqual(
            ReposList.row(api, now: now),
            RepoRow(
                key: "api",
                isDefault: false,
                fields: [
                    RepoField(
                        "Source",
                        "Managed clone of acme/api",
                        detail: "not cloned yet: Symphony clones it on the first dispatch"
                    ),
                    RepoField("GitHub", "acme/api"),
                    RepoField("Linear", "team ENG · projects api, billing · label backend · assignee me"),
                    RepoField(
                        "WORKFLOW.md",
                        "found, invalid",
                        detail: "Failed to parse WORKFLOW.md: malformed yaml",
                        tone: .problem
                    ),
                    RepoField(
                        "Last fetch",
                        "2h 10m ago, failed",
                        detail: "git fetch exited with status 128: fatal: Could not read from remote repository.",
                        tone: .problem
                    ),
                    RepoField("Agents", "none"),
                ],
                managedGitHub: "acme/api"
            )
        )
    }

    func testFormatsARepoWithoutRemoteWorkflowOrFetch() {
        XCTAssertEqual(
            ReposList.row(docs, now: now).fields,
            [
                RepoField("Source", "Local folder", detail: "/Projects/docs"),
                RepoField("GitHub", "no GitHub remote"),
                RepoField("Linear", "label docs"),
                RepoField("WORKFLOW.md", "missing", detail: "missing_workflow_file", tone: .problem),
                RepoField("Last fetch", "none yet"),
                RepoField("Agents", "TP-7 (on worker-1), ghi789", detail: "/srv/workspaces/docs/TP-7"),
            ]
        )
    }

    func testFieldEdgeCases() {
        XCTAssertEqual(ReposList.linearField(RepositoryRoute()).value, "no route")
        XCTAssertEqual(
            ReposList.linearField(RepositoryRoute(team: " ", projects: ["a"], labels: ["x", "y"])).value,
            "project a · labels x, y"
        )
        XCTAssertEqual(
            ReposList.sourceField(.managed(github: "acme/api", clonePath: "/Clones/repos/acme/api", cloned: true)),
            RepoField("Source", "Managed clone of acme/api", detail: "/Clones/repos/acme/api")
        )
        XCTAssertEqual(
            ReposList.workflowField(.init(path: "/w/WORKFLOW.md", state: .invalid)),
            RepoField("WORKFLOW.md", "found, invalid", detail: "/w/WORKFLOW.md", tone: .problem)
        )
        XCTAssertEqual(
            ReposList.workflowField(.init(path: "/w/WORKFLOW.md", state: .other("stale"))),
            RepoField("WORKFLOW.md", "stale", detail: "/w/WORKFLOW.md")
        )
        XCTAssertEqual(
            ReposList.fetchField(.init(at: nil, succeeded: true), now: now),
            RepoField("Last fetch", "at an unknown time, ok")
        )
        XCTAssertEqual(ReposList.agentsField([.init(issueIdentifier: "TP-1")]), RepoField("Agents", "TP-1"))
    }

    // MARK: - Rows from symphony.yml

    private let configured = [
        RepositoryEntry(
            key: "symphony",
            isDefault: true,
            workflow: "WORKFLOW.md",
            route: RepositoryRoute(projects: ["building-the-harness"]),
            workspace: RepositoryWorkspace(strategy: "worktree", repo: "~/Projects/symphony")
        ),
        RepositoryEntry(
            key: "api",
            route: RepositoryRoute(team: "ENG"),
            workspace: RepositoryWorkspace(source: "git@github.com:acme/api.git")
        ),
    ]

    func testConfiguredRowsMarkLiveFieldsUnavailable() {
        XCTAssertEqual(
            configured.map(ReposList.row),
            [
                RepoRow(
                    key: "symphony",
                    isDefault: true,
                    fields: [
                        RepoField("Source", "Local folder", detail: "~/Projects/symphony"),
                        RepoField("GitHub", "unavailable", tone: .unavailable),
                        RepoField("Linear", "project building-the-harness"),
                        RepoField("WORKFLOW.md", "unavailable", detail: "WORKFLOW.md", tone: .unavailable),
                        RepoField("Last fetch", "unavailable", tone: .unavailable),
                        RepoField("Agents", "unavailable", tone: .unavailable),
                    ]
                ),
                RepoRow(
                    key: "api",
                    isDefault: false,
                    fields: [
                        RepoField("Source", "Managed clone of acme/api"),
                        RepoField("GitHub", "acme/api"),
                        RepoField("Linear", "team ENG"),
                        RepoField("WORKFLOW.md", "unavailable", detail: "WORKFLOW.md", tone: .unavailable),
                        RepoField("Last fetch", "unavailable", tone: .unavailable),
                        RepoField("Agents", "unavailable", tone: .unavailable),
                    ],
                    managedGitHub: "acme/api"
                ),
            ]
        )
        XCTAssertEqual(
            ReposList.row(RepositoryEntry(key: "web", workspace: RepositoryWorkspace(repo: " "))).fields.first,
            RepoField("Source", "Local folder")
        )
    }

    func testReadsTheRepoOfAManagedSource() {
        for source in [
            "acme/web", "https://github.com/acme/web", "https://github.com/acme/web/", "https://github.com/acme/web.git",
            "git@github.com:acme/web.git", "ssh://git@github.com/acme/web.git",
        ] {
            XCTAssertEqual(ReposList.gitHubRepo(source), "acme/web", source)
        }
    }

    // MARK: - The window

    private func display(
        _ status: SymphonyStatus,
        _ poll: ReposPoll?,
        configPath: String = "/etc/symphony/symphony.yml",
        readConfig: ((String) throws -> [RepositoryEntry])? = nil
    ) -> ReposDisplay {
        ReposList.display(
            status: status,
            poll: poll,
            configPath: configPath,
            readConfig: readConfig ?? { _ in self.configured },
            now: now
        )
    }

    func testShowsTheReposFromARunningSymphony() {
        XCTAssertEqual(
            display(running, .repos([symphony], warning: nil)),
            ReposDisplay(rows: [ReposList.row(symphony, now: now)])
        )
        XCTAssertEqual(
            display(.paused(StateSnapshot(), external: true), .repos([symphony], warning: "Snapshot timed out")).notice,
            "Symphony couldn't list its running agents: Snapshot timed out"
        )
        XCTAssertEqual(display(running, .repos([], warning: nil)), ReposDisplay(notice: "Symphony lists no repos."))
    }

    func testShowsSymphonyYmlWhileSymphonyIsStopped() {
        let shown = display(.stopped, .repos([symphony], warning: nil))

        XCTAssertEqual(
            shown.notice,
            "Symphony is stopped. Showing the repos in /etc/symphony/symphony.yml; live fields are unavailable."
        )
        XCTAssertEqual(shown.rows, configured.map(ReposList.row))
    }

    func testSaysWhyTheReposComeFromSymphonyYml() {
        let cases: [(SymphonyStatus, ReposPoll?, String)] = [
            (.starting, nil, "Symphony is starting"),
            (.error("Symphony exited with status 1"), nil, "Symphony isn't answering"),
            (running, nil, "Asking Symphony for the repos' status"),
            (running, .unreachable, "Nothing answered on Symphony's control URL"),
            (running, .unsupported, "This Symphony doesn't list its repos; update it to see their live status"),
            (running, .failed("boom (HTTP 500)"), "Couldn't read the repos from Symphony: boom (HTTP 500)"),
        ]
        for (status, poll, reason) in cases {
            XCTAssertEqual(
                display(status, poll).notice,
                "\(reason). Showing the repos in /etc/symphony/symphony.yml; live fields are unavailable."
            )
        }
    }

    func testSaysWhenSymphonyYmlHasNoRepos() {
        XCTAssertEqual(
            display(.stopped, nil, configPath: " "),
            ReposDisplay(notice: "Symphony is stopped. No symphony.yml is set in Settings.")
        )
        XCTAssertEqual(
            display(.stopped, nil, readConfig: { _ in [] }),
            ReposDisplay(notice: "Symphony is stopped. /etc/symphony/symphony.yml has no repositories: section.")
        )
        XCTAssertEqual(
            display(.stopped, nil) { _ in throw RepositoriesConfigError.unsupported(line: 2, reason: "flow style") },
            ReposDisplay(
                notice: "Symphony is stopped. Couldn't read the repos in /etc/symphony/symphony.yml: "
                    + "symphony.yml line 2: flow style. Edit repositories by hand."
            )
        )
    }

    func testReadsTheConfigPathFromSettings() throws {
        let file = root.appendingPathComponent("symphony.yml")
        try """
            repositories:
              - key: symphony
                default: true
                route:
                  projects: [building-the-harness]
            """.write(to: file, atomically: false, encoding: .utf8)

        let shown = ReposList.display(status: .stopped, poll: nil, configPath: file.path) { path in
            try SymphonyConfigFile(path: path).readRepositories()
        }

        XCTAssertEqual(shown.rows.map(\.key), ["symphony"])
        XCTAssertEqual(shown.rows.first?.fields[2], RepoField("Linear", "project building-the-harness"))
    }

    // MARK: Actions

    func testRowsKnowTheirManagedSource() {
        XCTAssertNil(ReposList.row(symphony).managedGitHub)
        XCTAssertEqual(ReposList.row(api).managedGitHub, "acme/api")
        XCTAssertEqual(ReposList.row(RepositoryEntry(key: "web", workspace: .init(source: "https://github.com/acme/web.git"))).managedGitHub, "acme/web")
        XCTAssertNil(ReposList.row(RepositoryEntry(key: "web", workspace: .init(repo: "~/web"))).managedGitHub)
    }

    func testActionsFollowTheConfigAndTheClone() {
        let display = ReposDisplay(rows: [ReposList.row(symphony), ReposList.row(api), ReposList.row(docs)])
        let entries = [RepositoryEntry(key: "symphony", isDefault: true), RepositoryEntry(key: "api")]
        var asked: [String] = []
        let shown = ReposList.withActions(display, entries: .success(entries)) { gitHub in
            asked.append(gitHub)
            return .blocked("TP-1 runs in a worktree of this clone.")
        }

        XCTAssertEqual(asked, ["acme/api"])
        XCTAssertEqual(shown.rows[0].actions, RepoActions())
        XCTAssertEqual(shown.rows[1].actions, RepoActions(cloneRemoval: .blocked("TP-1 runs in a worktree of this clone.")))
        XCTAssertEqual(shown.rows[1].actions.notes, ["TP-1 runs in a worktree of this clone."])
        let missing = "symphony.yml has no repo `docs`. Symphony keeps it until it restarts."
        XCTAssertEqual(shown.rows[2].actions, RepoActions(editProblem: missing, disconnectProblem: missing))
        XCTAssertEqual(shown.rows[2].actions.notes, [missing])

        let only = ReposList.withActions(ReposDisplay(rows: [ReposList.row(symphony)]), entries: .success([entries[0]])) { _ in
            .allowed(path: "/x")
        }
        XCTAssertEqual(only.rows[0].actions, RepoActions(disconnectProblem: "symphony is the only repo, and Symphony needs at least one."))

        let unreadable = ReposList.withActions(display, entries: .failure(AddRepoProblem("Couldn't read symphony.yml"))) { _ in
            .allowed(path: "/clones/acme/api")
        }
        XCTAssertEqual(unreadable.rows[1].actions, RepoActions(
            editProblem: "Couldn't read symphony.yml",
            disconnectProblem: "Couldn't read symphony.yml",
            cloneRemoval: .allowed(path: "/clones/acme/api")
        ))
        XCTAssertEqual(unreadable.rows[1].actions.notes, ["Couldn't read symphony.yml"])
    }
}
