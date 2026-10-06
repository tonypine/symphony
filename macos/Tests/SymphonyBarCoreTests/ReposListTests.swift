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

    // MARK: - Repos from a running Symphony

    private let now = ISO8601DateFormatter().date(from: "2026-10-04T14:10:00Z")!

    func testDetailOfALocalRepoWithARunningAgent() {
        XCTAssertEqual(
            ReposList.detail(symphony, warning: nil, now: now),
            RepoDetail(
                key: "symphony",
                isDefault: true,
                github: "tonypine/symphony",
                subtitle: "tonypine/symphony",
                source: .init(kind: .local, path: "/Projects/symphony", baseBranch: "main"),
                routing: .init(
                    sentence: "Issues in building-the-harness go to symphony.",
                    fields: [RepoField("Project", "building-the-harness")],
                    defaultLine: "It also takes the issues no other repo's route matches."
                ),
                live: .status(
                    workflow: RepoField("Status", "Valid", detail: "/Projects/symphony/WORKFLOW.md"),
                    lastFetch: RepoField("Last fetch", "5m ago"),
                    agents: [.init(issueIdentifier: "TP-260", worktreePath: "/Projects/symphony-workspaces/symphony/TP-260")],
                    agentsProblem: nil
                ),
                health: RepoHealth(status: .healthy)
            )
        )
    }

    func testDetailOfAManagedCloneWithProblems() {
        XCTAssertEqual(
            ReposList.detail(api, warning: nil, now: now),
            RepoDetail(
                key: "api",
                github: "acme/api",
                subtitle: "acme/api",
                source: .init(kind: .managed, notCloned: true, baseBranch: "origin's default branch", managedGitHub: "acme/api"),
                routing: .init(
                    sentence: "Issues in api or billing of team ENG with label backend assigned to me go to api.",
                    fields: [
                        RepoField("Projects", "api, billing"),
                        RepoField("Label", "backend"),
                        RepoField("Team", "ENG"),
                        RepoField("Assignee", "me"),
                    ]
                ),
                live: .status(
                    workflow: RepoField(
                        "Status",
                        "Invalid",
                        detail: "Failed to parse WORKFLOW.md: malformed yaml",
                        tone: .problem
                    ),
                    lastFetch: RepoField(
                        "Last fetch",
                        "Failed 2h 10m ago",
                        detail: "git fetch exited with status 128: fatal: Could not read from remote repository.",
                        tone: .problem
                    ),
                    agents: [],
                    agentsProblem: nil
                ),
                health: RepoHealth(
                    status: .notWorking,
                    problems: [
                        .init(
                            id: "workflow",
                            severity: .error,
                            title: "WORKFLOW.md is invalid",
                            detail: "Failed to parse WORKFLOW.md: malformed yaml",
                            fixes: [.openWorkflow(URL(string: "https://github.com/acme/api/blob/HEAD/WORKFLOW.md")!)]
                        ),
                        .init(
                            id: "fetch",
                            severity: .error,
                            title: "The last fetch failed 2h 10m ago",
                            detail: "git fetch exited with status 128: fatal: Could not read from remote repository.",
                            note: "Symphony tries again before the next dispatch.",
                            fixes: [
                                .copyError("git fetch exited with status 128: fatal: Could not read from remote repository."),
                                .openOnGitHub(URL(string: "https://github.com/acme/api")!),
                            ]
                        ),
                        .init(id: "clone", severity: .info, title: "Not cloned yet: Symphony clones it on the next dispatch"),
                    ]
                )
            )
        )
    }

    func testDetailOfARepoWithoutRemoteWorkflowOrFetch() {
        let detail = ReposList.detail(docs, warning: "Snapshot timed out", now: now)

        XCTAssertNil(detail.github)
        XCTAssertNil(detail.gitHubURL)
        XCTAssertEqual(detail.subtitle, "docs")
        XCTAssertEqual(detail.routing, .init(sentence: "Issues with label docs go to docs.", fields: [RepoField("Label", "docs")]))
        XCTAssertEqual(
            detail.live,
            .status(
                workflow: RepoField("Status", "Missing", detail: "missing_workflow_file", tone: .problem),
                lastFetch: RepoField("Last fetch", "None yet"),
                agents: [.init(issueIdentifier: "TP-7", workerHost: "worker-1"), .init(issueIdentifier: "ghi789")],
                agentsProblem: "Symphony couldn't list its running agents: Snapshot timed out"
            )
        )
        XCTAssertEqual(detail.agentCount, 2)
        XCTAssertEqual(detail.accessibilityLabel, "docs, needs attention, 2 agents running")
        XCTAssertEqual(
            ReposList.detail(symphony, warning: nil, now: now).accessibilityLabel,
            "symphony, healthy, default, 1 agent running"
        )
        XCTAssertEqual(ReposList.detail(api, warning: nil, now: now).accessibilityLabel, "api, not working")
        XCTAssertEqual(
            ReposList.detail(symphony, warning: nil, now: now).gitHubURL,
            URL(string: "https://github.com/tonypine/symphony")
        )
    }

    func testFieldEdgeCases() {
        XCTAssertEqual(
            ReposList.workflowField(.init(path: "/w/WORKFLOW.md", state: .invalid)),
            RepoField("Status", "Invalid", detail: "/w/WORKFLOW.md", tone: .problem)
        )
        XCTAssertEqual(
            ReposList.workflowField(.init(path: "/w/WORKFLOW.md", state: .other("stale"))),
            RepoField("Status", "stale", detail: "/w/WORKFLOW.md")
        )
        XCTAssertEqual(
            ReposList.fetchField(.init(at: nil, succeeded: true), now: now),
            RepoField("Last fetch", "At an unknown time")
        )
        XCTAssertEqual(
            ReposList.fetchField(.init(at: nil, succeeded: false, error: "boom"), now: now),
            RepoField("Last fetch", "Failed", detail: "boom", tone: .problem)
        )
        let cloned = RepoStatus(key: "web", source: .managed(github: "acme/web", clonePath: "/Clones/acme/web", cloned: true))
        XCTAssertEqual(
            ReposList.detail(cloned, warning: nil, now: now).source,
            .init(kind: .managed, path: "/Clones/acme/web", baseBranch: "origin's default branch", managedGitHub: "acme/web")
        )
        let bare = ReposList.detail(RepoStatus(key: "web", baseBranch: " "), warning: nil, now: now)
        XCTAssertNil(bare.subtitle)
        XCTAssertEqual(bare.source, .init(kind: .local, baseBranch: "origin's default branch"))
        XCTAssertEqual(ReposList.detail(RepoStatus(key: "web", baseBranch: "trunk"), warning: nil, now: now).source.baseBranch, "trunk")
    }

    func testSourceTitles() {
        let local = RepoDetail.Source(kind: .local, path: NSHomeDirectory() + "/code/web", baseBranch: "main")
        XCTAssertEqual([local.kindTitle, local.pathLabel, local.shownPath], ["Local folder", "Folder", "~/code/web"])
        let managed = RepoDetail.Source(kind: .managed, notCloned: true, baseBranch: "main", managedGitHub: "acme/web")
        XCTAssertEqual([managed.kindTitle, managed.pathLabel], ["Managed clone", "Clone"])
        XCTAssertNil(managed.shownPath)
    }

    func testRouteSentences() {
        func sentence(_ route: RepositoryRoute, isDefault: Bool = false) -> RepoDetail.Routing {
            ReposList.routing(route, key: "web", isDefault: isDefault)
        }
        XCTAssertEqual(sentence(RepositoryRoute()), .init(sentence: "web has no Linear route of its own."))
        XCTAssertEqual(
            sentence(RepositoryRoute(team: " ", projects: [""], labels: [], assignee: ""), isDefault: true),
            .init(
                sentence: "web has no Linear route of its own.",
                defaultLine: "It takes the issues no other repo's route matches."
            )
        )
        XCTAssertEqual(
            sentence(RepositoryRoute(team: "ENG")),
            .init(sentence: "Issues in team ENG go to web.", fields: [RepoField("Team", "ENG")])
        )
        XCTAssertEqual(
            sentence(RepositoryRoute(projects: ["a", "b", "c"], labels: ["x", "y"])).sentence,
            "Issues in a, b or c with labels x and y go to web."
        )
        XCTAssertEqual(
            sentence(RepositoryRoute(labels: ["x", "y"])).fields,
            [RepoField("Labels", "x, y")]
        )
        XCTAssertEqual(
            sentence(RepositoryRoute(assignee: "me")).sentence,
            "Issues assigned to me go to web."
        )
        XCTAssertEqual(ReposList.spoken([], or: true), "")
    }

    // MARK: - Repos from symphony.yml

    private let configured = [
        RepositoryEntry(
            key: "symphony",
            isDefault: true,
            workflow: "WORKFLOW.md",
            route: RepositoryRoute(projects: ["building-the-harness"]),
            workspace: RepositoryWorkspace(strategy: "worktree", repo: "~/Projects/symphony"),
            acceptanceGateMode: "enforce"
        ),
        RepositoryEntry(
            key: "api",
            baseBranch: "develop",
            route: RepositoryRoute(team: "ENG"),
            workspace: RepositoryWorkspace(source: "git@github.com:acme/api.git")
        ),
    ]

    private var config: ReposConfig {
        ReposConfig(
            path: "/etc/symphony/symphony.yml",
            repos: .entries(configured),
            globalGate: .shadow,
            clonesRoot: URL(fileURLWithPath: "/Clones/repos")
        )
    }

    func testConfiguredReposFoldTheLiveSectionsIntoOneLine() {
        let stopped = RepoDetail.Live.folded(line: "Live status shows while Symphony runs.", canStart: true)
        let details = configured.map { ReposList.detail($0, live: stopped, config: config) { _ in false } }

        XCTAssertEqual(
            details,
            [
                RepoDetail(
                    key: "symphony",
                    isDefault: true,
                    subtitle: "symphony",
                    source: .init(
                        kind: .local,
                        path: ("~/Projects/symphony" as NSString).expandingTildeInPath,
                        baseBranch: "origin's default branch"
                    ),
                    routing: .init(
                        sentence: "Issues in building-the-harness go to symphony.",
                        fields: [RepoField("Project", "building-the-harness")],
                        defaultLine: "It also takes the issues no other repo's route matches."
                    ),
                    live: stopped
                ),
                RepoDetail(
                    key: "api",
                    github: "acme/api",
                    subtitle: "acme/api",
                    source: .init(kind: .managed, notCloned: true, baseBranch: "develop", managedGitHub: "acme/api"),
                    routing: .init(sentence: "Issues in team ENG go to api.", fields: [RepoField("Team", "ENG")]),
                    live: stopped
                ),
            ]
        )
        XCTAssertEqual(details[1].agentCount, 0)
        XCTAssertEqual(details[0].accessibilityLabel, "symphony, not checked, default")

        var asked: [String] = []
        let cloned = ReposList.detail(configured[1], live: stopped, config: config) { path in
            asked.append(path)
            return true
        }
        XCTAssertEqual(asked, ["/Clones/repos/acme/api/.git"])
        XCTAssertEqual(cloned.source.path, "/Clones/repos/acme/api")
        XCTAssertFalse(cloned.source.notCloned)

        let noFolder = ReposList.detail(RepositoryEntry(key: "web", workspace: .init(repo: " ")), live: stopped, config: config) { _ in false }
        XCTAssertNil(noFolder.source.path)
        XCTAssertNil(noFolder.subtitle)
    }

    func testReadsTheRepoOfAManagedSource() {
        for source in [
            "acme/web", "https://github.com/acme/web", "https://github.com/acme/web/", "https://github.com/acme/web.git",
            "git@github.com:acme/web.git", "ssh://git@github.com/acme/web.git",
        ] {
            XCTAssertEqual(ReposList.gitHubRepo(source), "acme/web", source)
        }
    }

    // MARK: - symphony.yml

    func testReadsSymphonyYml() throws {
        let file = root.appendingPathComponent("symphony.yml")
        try """
            workspaces:
              clones_root: clones
            auto_review:
              acceptance_gate:
                mode: enforce
            repositories:
              - key: symphony
                default: true
                route:
                  projects: [building-the-harness]
            """.write(to: file, atomically: false, encoding: .utf8)

        let read = ReposConfig.read(path: " \(file.path)\n")

        XCTAssertEqual(read.path, file.path)
        XCTAssertEqual(read.globalGate, .enforce)
        XCTAssertEqual(read.clonesRoot, root.appendingPathComponent("clones").standardizedFileURL)
        XCTAssertEqual(try read.entries.get().map(\.key), ["symphony"])
    }

    func testReadsAnEmptyFlowListAsNoRepos() throws {
        let file = root.appendingPathComponent("symphony.yml")
        try "repositories: []\n".write(to: file, atomically: false, encoding: .utf8)

        let read = ReposConfig.read(path: file.path)

        XCTAssertEqual(read.repos, .entries([]))
        XCTAssertEqual(window(.stopped, nil, config: read).content, .empty(.noRepos))
    }

    func testSaysWhySymphonyYmlCantBeRead() throws {
        let none = ReposConfig.read(path: " ")
        XCTAssertEqual(none.repos, .noPath)
        XCTAssertEqual(none.entries, .failure(AddRepoProblem("Set the symphony.yml path in Settings first.")))

        let file = root.appendingPathComponent("symphony.yml")
        try "repositories: [{key: a}]\n".write(to: file, atomically: false, encoding: .utf8)
        let unreadable = ReposConfig.read(path: file.path)
        guard case let .unreadable(message) = unreadable.repos else { return XCTFail("\(unreadable.repos)") }
        XCTAssertEqual(unreadable.shownPath, (file.path as NSString).abbreviatingWithTildeInPath)
        XCTAssertEqual(
            unreadable.entries, .failure(AddRepoProblem("Couldn't read the repos in \(unreadable.shownPath): \(message)"))
        )
        XCTAssertEqual(unreadable.globalGate, .off)

        let missing = ReposConfig.read(path: root.appendingPathComponent("missing.yml").path)
        guard case .unreadable = missing.repos else { return XCTFail("\(missing.repos)") }
        XCTAssertNil(missing.globalGate)
        XCTAssertEqual(missing.clonesRoot, ManagedClones.root(in: "", configPath: missing.path))
    }

    // MARK: - The window

    private func window(
        _ status: SymphonyStatus,
        _ poll: ReposPoll?,
        config: ReposConfig? = nil,
        cloneRemoval: @escaping (String) -> ManagedClones.Removal = { _ in .blocked("checking") }
    ) -> ReposWindow {
        ReposList.window(status: status, poll: poll, config: config ?? self.config, now: now, isDirectory: { _ in false }, cloneRemoval: cloneRemoval)
    }

    func testTheChipSaysSymphonysState() {
        let cases: [(SymphonyStatus, String, ReposChip.Dot)] = [
            (running, "Symphony running", .green),
            (.paused(StateSnapshot(), external: true), "Symphony paused", .orange),
            (.starting, "Symphony is starting…", .grey),
            (.stopped, "Symphony stopped", .grey),
            (.error("Symphony exited with status 1"), "Symphony isn't answering", .red),
        ]
        for (status, title, dot) in cases {
            XCTAssertEqual(ReposChip(status: status).title, title)
            XCTAssertEqual(ReposChip(status: status).dot, dot)
            XCTAssertEqual(window(status, nil).chip, ReposChip(status: status))
        }
    }

    func testShowsTheReposFromARunningSymphony() {
        let shown = window(running, .repos([symphony, api], warning: nil))

        XCTAssertEqual(shown.chip, .running)
        XCTAssertEqual(shown.repos.map(\.key), ["symphony", "api"])
        XCTAssertEqual(shown.repos[0].live, ReposList.detail(symphony, warning: nil, now: now).live)
        XCTAssertEqual(
            shown.repos[0].gate,
            RepoDetail.Gate(
                mode: RepoField("Mode", "Enforce"),
                record: "This Symphony doesn't report the gate's record. Update it to see it."
            )
        )
        XCTAssertEqual(
            shown.repos[1].gate,
            RepoDetail.Gate(
                mode: RepoField("Mode", "Inherit: Shadow"),
                record: "This Symphony doesn't report the gate's record. Update it to see it."
            )
        )
        XCTAssertEqual(window(running, .repos([docs], warning: nil)).repos[0].gate, nil)
        XCTAssertEqual(shown.repos.map(\.health.status), [.healthy, .notWorking])
        XCTAssertEqual(window(running, .repos([], warning: nil)).content, .empty(.noRepos))
    }

    func testJoinsTheRunningAgentsOfTheStateAndThePendingWorkflow() {
        let run = StateSnapshot.Run(
            issueIdentifier: "TP-260",
            url: URL(string: "https://linear.app/t/issue/TP-260"),
            startedAt: date("2026-10-04T13:40:00Z"),
            lastEventAt: date("2026-10-04T13:55:00Z")
        )
        let status = SymphonyStatus.running(StateSnapshot(running: 1, runs: [run]), external: false)
        let pr = URL(string: "https://github.com/acme/api/pull/9")!
        let shown = ReposList.window(
            status: status,
            poll: .repos([symphony, api], warning: nil),
            config: config,
            now: now,
            pending: { $0 == "api" ? .pullRequest(pr) : nil },
            isDirectory: { _ in false },
            cloneRemoval: { _ in .blocked("checking") }
        )

        guard case let .status(_, _, agents, _) = shown.repos[0].live else { return XCTFail("expected live status") }
        XCTAssertEqual(agents.map(\.activity), ["Running for 30m · last activity 15m ago"])
        XCTAssertEqual(shown.repos[0].health.status, .needsAttention)
        XCTAssertEqual(shown.repos[0].health.problems.map(\.id), ["stuck-TP-260"])
        XCTAssertEqual(shown.repos[1].health.problems.first { $0.id == "workflow" }?.fixes, [.viewPullRequest(pr)])
    }

    func testShowsSymphonyYmlWhileSymphonyIsStopped() {
        let shown = window(.stopped, .repos([symphony], warning: nil))

        XCTAssertEqual(shown.chip, .stopped)
        XCTAssertEqual(shown.repos.map(\.key), ["symphony", "api"])
        XCTAssertEqual(shown.repos.map(\.health), Array(repeating: .notChecked("Symphony is stopped"), count: 2))
        XCTAssertEqual(shown.repos[0].health.summary, "Not checked: Symphony is stopped")
        XCTAssertEqual(shown.repos[1].source.notCloned, true)
        XCTAssertEqual(shown.repos[1].live, .folded(line: "Live status shows while Symphony runs.", canStart: true))
        XCTAssertEqual(shown.repos[1].routing.sentence, "Issues in team ENG go to api.")
        XCTAssertEqual(
            shown.repos[1].gate,
            RepoDetail.Gate(mode: RepoField("Mode", "Inherit: Shadow"), record: "Start Symphony to see the gate's record.")
        )
    }

    func testFoldsTheLiveSectionsWithWhySymphonyDoesntShowThem() {
        let cases: [(SymphonyStatus, ReposPoll?, String, Bool)] = [
            (.starting, nil, "Symphony is starting… Live status shows once it runs.", false),
            (.error("exit 1"), nil, "Symphony isn't answering. Live status shows while Symphony runs.", true),
            (running, nil, "Asking Symphony for the repos' live status…", false),
            (running, .unreachable, "Nothing answered on Symphony's control URL.", false),
            (running, .unsupported, "Update Symphony to see live status.", false),
            (running, .failed("boom (HTTP 500)"), "Couldn't read the repos from Symphony: boom (HTTP 500)", false),
        ]
        for (status, poll, line, canStart) in cases {
            let shown = window(status, poll)
            XCTAssertEqual(shown.repos.map(\.key), ["symphony", "api"])
            XCTAssertEqual(shown.repos.map(\.live), Array(repeating: .folded(line: line, canStart: canStart), count: 2))
            XCTAssertEqual(shown.repos.map(\.health.status), [.notChecked, .notChecked])
        }
    }

    func testEmptyAndErrorStates() {
        XCTAssertEqual(
            window(.stopped, nil, config: ReposConfig(path: "", repos: .noPath)),
            ReposWindow(chip: .stopped, content: .empty(.noConfig))
        )
        XCTAssertEqual(
            window(.starting, nil, config: ReposConfig(path: "/etc/symphony.yml", repos: .unreadable("line 2: flow style"))),
            ReposWindow(chip: .starting, content: .empty(.unreadable(path: "/etc/symphony.yml", message: "line 2: flow style")))
        )
        XCTAssertEqual(
            window(.stopped, nil, config: ReposConfig(path: "/etc/symphony.yml", repos: .entries([]))),
            ReposWindow(chip: .stopped, content: .empty(.noRepos))
        )
        XCTAssertEqual(ReposWindow().repos, [])
        XCTAssertEqual(window(.stopped, nil, config: ReposConfig(path: "", repos: .noPath)).repos, [])

        XCTAssertEqual(ReposEmptyState.noRepos.title, "No repos connected")
        XCTAssertEqual(
            ReposEmptyState.noRepos.message,
            "Connect a GitHub repo or a folder on this Mac, and pick which Linear issues go to it."
        )
        XCTAssertEqual(ReposEmptyState.noConfig.title, "Symphony doesn't know where its config is.")
        XCTAssertEqual(ReposEmptyState.noConfig.message, "Set the path of symphony.yml in Settings.")
        let unreadable = ReposEmptyState.unreadable(path: NSHomeDirectory() + "/symphony.yml", message: "boom")
        XCTAssertEqual(unreadable.title, "Couldn't read symphony.yml")
        XCTAssertEqual(unreadable.message, "~/symphony.yml")
    }

    func testARunningSymphonyKeepsItsReposWhenSymphonyYmlCantBeRead() {
        let shown = window(running, .repos([symphony], warning: nil), config: ReposConfig(path: "", repos: .noPath))

        XCTAssertEqual(shown.repos.map(\.key), ["symphony"])
        XCTAssertNil(shown.repos[0].gate)
        XCTAssertEqual(
            shown.repos[0].actions,
            RepoActions(
                editProblem: "Set the symphony.yml path in Settings first.",
                disconnectProblem: "Set the symphony.yml path in Settings first."
            )
        )
    }

    func testNoFieldReadsUnavailable() {
        let polls: [ReposPoll?] = [
            nil, .unreachable, .unsupported, .failed("boom"), .repos([symphony, api, docs], warning: "timeout"),
        ]
        for status in [running, .stopped, .starting, .error("exit 1")] {
            for poll in polls {
                let text = String(describing: window(status, poll))
                XCTAssertFalse(text.lowercased().contains("unavailable"), text)
            }
        }
    }

    func testRestoresTheSelection() {
        let shown = window(.stopped, nil)
        XCTAssertEqual(ReposList.selection(saved: "api", in: shown), "api")
        XCTAssertEqual(ReposList.selection(saved: "gone", in: shown), "symphony")
        XCTAssertEqual(ReposList.selection(saved: nil, in: shown), "symphony")
        XCTAssertNil(ReposList.selection(saved: "api", in: ReposWindow(content: .empty(.noRepos))))
    }

    func testSelectsTheBannersRepoOnceTheWindowListsIt() {
        let banner = ReposBanner(key: "docs", text: "Added docs.")
        // Add Repo shows its banner before the running Symphony's next poll lists the new repo.
        let before = window(running, .repos([symphony, api], warning: nil))
        let shown = ReposList.selection(current: "api", pending: banner.key, saved: "api", in: before)
        XCTAssertEqual(shown.selection, "api")
        XCTAssertEqual(shown.pending, "docs")
        XCTAssertTrue(banner.isShown(on: shown.selection, listed: before.repos.map(\.key)))

        let after = window(running, .repos([symphony, api, docs], warning: nil))
        let listed = ReposList.selection(current: shown.selection, pending: shown.pending, saved: "api", in: after)
        XCTAssertEqual(listed.selection, "docs")
        XCTAssertNil(listed.pending)
        XCTAssertTrue(banner.isShown(on: listed.selection, listed: after.repos.map(\.key)))

        let next = ReposList.selection(current: "api", pending: listed.pending, saved: "api", in: after)
        XCTAssertEqual(next.selection, "api", "the user's next pick stays")
        // A selection the window no longer lists falls back to the saved one while the banner's repo waits.
        let gone = ReposList.selection(current: "gone", pending: "new", saved: "api", in: after)
        XCTAssertEqual(gone.selection, "api")
        XCTAssertEqual(gone.pending, "new")
    }

    // MARK: Actions

    func testActionsFollowTheConfigAndTheClone() {
        var asked: [String] = []
        let shown = window(running, .repos([symphony, api, docs], warning: nil)) { gitHub in
            asked.append(gitHub)
            return .blocked("TP-1 runs in a worktree of this clone.")
        }

        XCTAssertEqual(asked, ["acme/api"])
        XCTAssertEqual(shown.repos[0].actions, RepoActions())
        XCTAssertEqual(shown.repos[1].actions, RepoActions(cloneRemoval: .blocked("TP-1 runs in a worktree of this clone.")))
        let missing = "symphony.yml has no repo `docs`. Symphony keeps it until it restarts."
        XCTAssertEqual(shown.repos[2].actions, RepoActions(editProblem: missing, disconnectProblem: missing))

        let only = ReposConfig(path: "/etc/symphony.yml", repos: .entries([configured[0]]))
        XCTAssertEqual(
            window(.stopped, nil, config: only).repos[0].actions,
            RepoActions(disconnectProblem: "symphony is the only repo, and Symphony needs at least one.")
        )

        let unreadable = ReposConfig(path: "/etc/symphony.yml", repos: .unreadable("boom"))
        let problem = "Couldn't read the repos in /etc/symphony.yml: boom"
        XCTAssertEqual(
            window(running, .repos([api], warning: nil), config: unreadable) { _ in .allowed(path: "/clones/acme/api") }.repos[0].actions,
            RepoActions(editProblem: problem, disconnectProblem: problem, cloneRemoval: .allowed(path: "/clones/acme/api"))
        )
    }
}
