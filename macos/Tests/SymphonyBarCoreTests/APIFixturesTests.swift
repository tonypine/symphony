import XCTest
@testable import SymphonyBarCore

final class APIFixturesTests: XCTestCase {
    private var root: URL!
    private var fixtures: APIFixtures!

    override func setUpWithError() throws {
        root = uniqueTemporaryDirectory("api-fixtures")
        let directory = root.appendingPathComponent("fixtures/api/v1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"counts":{"running":2}}"#.utf8).write(to: directory.appendingPathComponent("state.json"))
        fixtures = APIFixtures(
            directory: root.appendingPathComponent("fixtures"),
            requestLog: root.appendingPathComponent("qa/api-requests.jsonl")
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func request(_ path: String, method: String = "GET", body: [String: String]? = nil) -> URLRequest {
        var request = URLRequest(url: APIFixtures.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        return request
    }

    /// The shipped fixtures QA points `SYMPHONY_BAR_QA_API_FIXTURES` at.
    static var shippedRunning: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/running", isDirectory: true)
    }

    func testGetReadsThePathsFile() {
        let (data, response) = fixtures.answer(request("api/v1/state"))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"counts":{"running":2}}"#)
    }

    func testGetAnswers404WithoutAFile() {
        XCTAssertEqual(fixtures.answer(request("api/v1/inbox")).1.statusCode, 404)
    }

    func testGetAnswersAScreenshotsBytesWithItsImageType() throws {
        let artifacts = root.appendingPathComponent("fixtures/api/v1/artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let png = try TicketEventsTests.png()
        try png.write(to: artifacts.appendingPathComponent("a1.png"))
        try Data([0xFF, 0xD8, 0xFF]).write(to: artifacts.appendingPathComponent("b2.jpg"))
        try Data(#"{"error":{"code":"artifact_expired"}}"#.utf8).write(to: artifacts.appendingPathComponent("c3.410.json"))
        // A `.json` answers first, as for any other path.
        try Data(#"{"id":"d4"}"#.utf8).write(to: artifacts.appendingPathComponent("d4.json"))
        try png.write(to: artifacts.appendingPathComponent("d4.png"))

        let image = fixtures.answer(request("api/v1/artifacts/a1"))
        XCTAssertEqual(image.1.statusCode, 200)
        XCTAssertEqual(image.1.value(forHTTPHeaderField: "Content-Type"), "image/png")
        XCTAssertEqual(image.0, png)
        let jpeg = fixtures.answer(request("api/v1/artifacts/b2"))
        XCTAssertEqual(jpeg.1.statusCode, 200)
        XCTAssertEqual(jpeg.1.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        let gone = fixtures.answer(request("api/v1/artifacts/c3"))
        XCTAssertEqual(gone.1.statusCode, 410)
        XCTAssertEqual(String(decoding: gone.0, as: UTF8.self), #"{"error":{"code":"artifact_expired"}}"#)
        XCTAssertEqual(fixtures.answer(request("api/v1/artifacts/d4")).1.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(fixtures.answer(request("api/v1/artifacts/e5")).1.statusCode, 404)
    }

    func testTheLiveChannelWithoutAFixtureIsUnavailable() async throws {
        // No `api/v1/stream.json`: a 404, so the window reads the ticket's feed after each state poll.
        let connect = EventStream.buffered(fixtures.transport)
        let response = try await connect(request(EventStream.path))
        XCTAssertEqual(response.statusCode, 404)
    }

    func testPathsCantLeaveTheDirectory() {
        XCTAssertNil(fixtures.file(forPath: "/api/../../secrets"))
        XCTAssertNil(fixtures.file(forPath: "/"))
        XCTAssertEqual(fixtures.answer(request("api/../../secrets")).1.statusCode, 404)
    }

    func testPostIsLoggedAndAnswered200() throws {
        let date = Date(timeIntervalSince1970: 1_791_000_000)
        let first = fixtures.answer(request("api/v1/control/pause", method: "POST", body: ["reason": "test"]), now: date)
        _ = fixtures.answer(request("api/v1/control/resume", method: "POST"), now: date)

        XCTAssertEqual(first.1.statusCode, 200)
        let lines = try String(contentsOf: fixtures.requestLog, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(entry["method"] as? String, "POST")
        XCTAssertEqual(entry["path"] as? String, "/api/v1/control/pause")
        XCTAssertEqual(entry["body"] as? [String: String], ["reason": "test"])
        XCTAssertEqual(entry["at"] as? String, "2026-10-03T04:00:00Z")
    }

    func testControlActionsGoToTheFixtures() async throws {
        let result = await ControlAPI.send(
            .pause,
            stateRoot: root,
            fallback: APIFixtures.baseURL,
            token: APIFixtures.token,
            transport: fixtures.transport
        )
        XCTAssertEqual(result, .done)
        XCTAssertTrue(try String(contentsOf: fixtures.requestLog, encoding: .utf8).contains("/api/v1/control/pause"))
    }

    func testShippedRunningFixturesServeStateAndRepos() async {
        let shipped = APIFixtures(directory: Self.shippedRunning, requestLog: root.appendingPathComponent("log.jsonl"))
        let base = APIFixtures.baseURL
        let state = shipped.answer(URLRequest(url: SymphonyState.stateURL(base: base)))
        XCTAssertEqual(state.1.statusCode, 200)
        guard case .state = SymphonyState.poll(data: state.0, statusCode: 200) else {
            return XCTFail("the shipped state fixture doesn't read as a state")
        }
        let repos = await ReposAPI.fetch(stateRoot: root, fallback: base, transport: shipped.transport)
        guard case .repos = repos else { return XCTFail("the shipped repos fixture doesn't read as repos: \(repos)") }
    }

    func testTheInboxFixturesServeTheirInboxStateAndRepos() async {
        for name in ["inbox", "inbox-empty", "inbox-decision", "inbox-paused"] {
            let directory = Self.shippedRunning.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
            let shipped = APIFixtures(directory: directory, requestLog: root.appendingPathComponent("api-requests.jsonl"))
            let inbox = shipped.answer(request(InboxPayload.path))
            XCTAssertEqual(inbox.1.statusCode, 200, name)
            XCTAssertNotNil(InboxPayload.decode(inbox.0), name)
            XCTAssertNotNil(OverviewState.decode(shipped.answer(request("api/v1/state")).0), name)
            let repos = await ReposAPI.fetch(stateRoot: root, fallback: APIFixtures.baseURL, transport: shipped.transport)
            guard case .repos = repos else { return XCTFail("\(name)'s repos fixture doesn't read as repos: \(repos)") }
        }
    }

    func testTheOverviewFixturesServeTheirStateAndLogTheOverviewsControls() async throws {
        for name in ["flowing", "attention", "paused", "idle"] {
            let directory = Self.shippedRunning.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
            let shipped = APIFixtures(directory: directory, requestLog: root.appendingPathComponent("api-requests.jsonl"))
            let state = shipped.answer(URLRequest(url: SymphonyState.stateURL(base: APIFixtures.baseURL)))
            XCTAssertNotNil(OverviewState.decode(state.0), name)
            XCTAssertNotNil(DiagnosticsPayload.decode(state.0), name)
            let repos = await ReposAPI.fetch(stateRoot: root, fallback: APIFixtures.baseURL, transport: shipped.transport)
            guard case .repos = repos else { return XCTFail("\(name)'s repos fixture doesn't read as repos: \(repos)") }
        }

        // Resume Dispatch and Stop Forcing, as the Overview sends them.
        let shipped = APIFixtures(
            directory: Self.shippedRunning.deletingLastPathComponent().appendingPathComponent("attention", isDirectory: true),
            requestLog: root.appendingPathComponent("api-requests.jsonl")
        )
        for action in [ControlAction.stopForcing("SHOP-305"), .resume] {
            let result = await ControlAPI.send(action, stateRoot: root, fallback: APIFixtures.baseURL, token: APIFixtures.token, transport: shipped.transport)
            XCTAssertEqual(result, .done)
        }
        let lines = try String(contentsOf: shipped.requestLog, encoding: .utf8).split(separator: "\n")
        let entries = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(entries.map { $0["path"] as? String }, ["/api/v1/control/force", "/api/v1/control/resume"])
        XCTAssertEqual(entries[0]["body"] as? [String: String], ["identifier": "SHOP-305", "clear": "true"])
    }

    /// Every shipped fixture directory, so one added later is decoded too.
    static var shippedDirectories: [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: shippedRunning.deletingLastPathComponent(),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )) ?? []
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testEveryShippedFixtureServesAStateAndReposTheAppReads() async {
        let directories = Self.shippedDirectories
        XCTAssertTrue(directories.contains { $0.lastPathComponent == "update-paused" })
        for directory in directories {
            let name = directory.lastPathComponent
            let shipped = APIFixtures(directory: directory, requestLog: root.appendingPathComponent("api-requests.jsonl"))
            let state = shipped.answer(URLRequest(url: SymphonyState.stateURL(base: APIFixtures.baseURL)))
            XCTAssertEqual(state.1.statusCode, 200, name)
            XCTAssertNotNil(OverviewState.decode(state.0), name)
            XCTAssertNotNil(DiagnosticsPayload.decode(state.0), name)
            let repos = await ReposAPI.fetch(stateRoot: root, fallback: APIFixtures.baseURL, transport: shipped.transport)
            guard case .repos = repos else { return XCTFail("\(name)'s repos fixture doesn't read as repos: \(repos)") }
        }
    }

    /// The fixture behind a walkthrough where Symphony reports the release pair's N+1 (`make -C macos release-pair`'s
    /// default build), so a launch on N hears of N+1 on its first poll and checks at once instead of on its timer.
    func testTheUpdateReportedFixtureReportsTheReleasePairsNextRelease() throws {
        let directory = Self.shippedRunning.deletingLastPathComponent().appendingPathComponent("update-reported", isDirectory: true)
        let shipped = APIFixtures(directory: directory, requestLog: root.appendingPathComponent("api-requests.jsonl"))
        let data = shipped.answer(URLRequest(url: SymphonyState.stateURL(base: APIFixtures.baseURL))).0
        guard case .state(let snapshot) = SymphonyState.poll(data: data, statusCode: 200) else {
            return XCTFail("the update-reported fixture doesn't read as a state")
        }
        XCTAssertEqual(
            snapshot.latestRelease,
            ReportedRelease(tag: "v0.0.1.90002", publishedAt: Date(timeIntervalSince1970: 1_792_137_600))
        )
    }

    /// The fixtures QA reads the status-bar menu's release build line in (TP-1307): a ticket held for an update whose
    /// build isn't published yet, queued (`update-build-queued`) or rerun after GitHub cancelled it (`update-build-rerun`).
    func testTheUpdateBuildFixturesSayWhatTheReleaseBuildIsAt() throws {
        let expected = [
            "update-build-queued": "Waiting for the v0.0.1.750 build with TP-1238's fix: queued on GitHub for 23 min",
            "update-build-rerun": "Waiting for the v0.0.1.750 build with TP-1238's fix: queued on GitHub for 4 min; "
                + "cancelled for lack of a machine, rerun 1 of 2",
        ]
        for (name, line) in expected {
            let directory = Self.shippedRunning.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
            let shipped = APIFixtures(directory: directory, requestLog: root.appendingPathComponent("api-requests.jsonl"))
            let data = shipped.answer(URLRequest(url: SymphonyState.stateURL(base: APIFixtures.baseURL))).0
            guard case let .state(snapshot) = SymphonyState.poll(data: data, statusCode: 200) else {
                return XCTFail("the \(name) fixture doesn't read as a state")
            }
            XCTAssertEqual(snapshot.updateUnblocks, 1, name)
            XCTAssertEqual(StatusMenu.detailLines(.running(snapshot, external: false)).last, line, name)
        }
    }

    /// The update fixtures QA launches with the update feed's `--fake-release 9.9.9 9999`: dispatch paused for an
    /// update to v9.9.9, with two runs finishing (`update-paused`) or none (`update-paused-idle`).
    func testTheUpdateFixturesReadAsDispatchPausedForAnUpdate() throws {
        let utc = TimeZone(identifier: "UTC")!
        let expected = [
            "update-paused": "2 runs are finishing. Symphony updates and resumes dispatch when they end; no new run starts until then.",
            "update-paused-idle": "Nothing is running. Symphony updates and resumes dispatch next; no new run starts until then.",
        ]
        for (name, context) in expected {
            let directory = Self.shippedRunning.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
            let shipped = APIFixtures(directory: directory, requestLog: root.appendingPathComponent("api-requests.jsonl"))
            let data = shipped.answer(URLRequest(url: SymphonyState.stateURL(base: APIFixtures.baseURL))).0
            let state = try XCTUnwrap(OverviewState.decode(data), name)
            XCTAssertEqual(state.snapshot.updatePauseVersion, "9.9.9", name)

            let control = DispatchControl(window: .connected, paused: true, state: state, now: Date(), timeZone: utc)
            XCTAssertEqual(control.word, "Paused · Updating to v9.9.9", name)
            XCTAssertEqual(control.accessibilityLabel, "Dispatch paused, updating to v9.9.9", name)
            XCTAssertEqual(control.pauseFacts.first, TicketList.Fact(label: "By", value: "an update to v9.9.9"), name)

            let overview = Overview(state: state, now: Date(), timeZone: utc)
            XCTAssertEqual(overview.mood, .paused, name)
            XCTAssertEqual(overview.context, context, name)
        }
    }

    /// The header's lines QA reads in the update fixtures (TP-1251): one reason while idle, three while runs finish.
    func testTheUpdateFixturesGiveOneLinePerReasonOfThePause() throws {
        let utc = TimeZone(identifier: "UTC")!
        let expected = [
            "update-paused": ["Updating to v9.9.9", "Paused by you since 14:05: Deploy freeze", "Claude's 5-hour usage limit until 16:30"],
            "update-paused-idle": ["Updating to v9.9.9"],
        ]
        for (name, lines) in expected {
            let directory = Self.shippedRunning.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
            let shipped = APIFixtures(directory: directory, requestLog: root.appendingPathComponent("api-requests.jsonl"))
            let data = shipped.answer(URLRequest(url: SymphonyState.stateURL(base: APIFixtures.baseURL))).0
            let state = try XCTUnwrap(OverviewState.decode(data), name)
            let now = Date(timeIntervalSince1970: 1_791_385_200) // 2026-10-07 15:00 UTC, the fixtures' day
            XCTAssertEqual(Overview(state: state, now: now, timeZone: utc).pauseLines, lines, name)
            XCTAssertEqual(Array(StatusMenu.detailLines(.paused(state.snapshot, external: false), now: now, timeZone: utc).dropFirst()), lines, name)
        }
    }

    /// The fixture QA walks Pause this repository with (TP-1238): `symphony` paused with the Director's reason, the
    /// others dispatching, its running ticket saying its repository is paused, and a checked setup so Setup shows its
    /// Repositories card.
    func testTheRepoPausedFixtureShowsOneRepositoryPaused() throws {
        let directory = Self.shippedRunning.deletingLastPathComponent().appendingPathComponent("repo-paused", isDirectory: true)
        let shipped = APIFixtures(directory: directory, requestLog: root.appendingPathComponent("api-requests.jsonl"))
        let data = shipped.answer(URLRequest(url: SymphonyState.stateURL(base: APIFixtures.baseURL))).0
        guard case let .state(snapshot) = SymphonyState.poll(data: data, statusCode: 200) else {
            return XCTFail("the repo-paused fixture doesn't read as a state")
        }
        XCTAssertEqual(RepoPauseControl.all(snapshot: snapshot).map(\.isPaused), [true, false, false])
        XCTAssertEqual(snapshot.repository("symphony")?.pause?.reasons, ["focusing on Symphony this week"])
        // Setup checks its setup, so its page shows, with the Repositories card.
        XCTAssertEqual(SetupPage(payload: snapshot.setup, now: Date()).mood, .healthy)

        let issue = shipped.answer(URLRequest(url: APIFixtures.baseURL.appendingPathComponent(TicketPage.issuePath("TP-237")))).0
        let page = TicketPage(identifier: "TP-237", sources: TicketPage.Sources(state: data, issue: issue))
        XCTAssertEqual(page.repositoryPausedNote, "The repository symphony is paused: Symphony doesn't dispatch its tickets.")
    }
}
