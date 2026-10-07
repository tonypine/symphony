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
}
