import XCTest
@testable import SymphonyBarCore

final class PullRequestPageTests: XCTestCase {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/pull-request/api/v1", isDirectory: true)
    }

    func testDecodesPR448FromTheFixture() throws {
        let data = try Data(contentsOf: fixture.appendingPathComponent("pull_requests/symphony/448.json"))
        let page = try XCTUnwrap(PullRequestPage.decode(data))

        XCTAssertEqual(page.number, 448)
        XCTAssertEqual(page.url, URL(string: "https://github.com/tonypine/symphony/pull/448"))
        XCTAssertEqual(page.title, "TP-892 Retire two old review steps")
        XCTAssertEqual(page.repoKey, "symphony")
        XCTAssertEqual(page.ticket, .init(identifier: "TP-892", title: "Retire two old review steps", state: "Rework", waitingOn: "you"))
        XCTAssertTrue(page.gitHubAvailable)
        XCTAssertEqual(page.state, .open)
        XCTAssertEqual(page.reviewState, .changesRequested)
        XCTAssertEqual(page.openedAt, ISO8601DateFormatter().date(from: "2026-10-05T16:10:00Z"))
        XCTAssertEqual(page.lastPushedAt, ISO8601DateFormatter().date(from: "2026-10-07T09:30:00Z"))
        XCTAssertNil(page.mergedAt)
        XCTAssertEqual(page.summary?.hasPrefix("The Final verification and Supervisor check steps are gone"), true)

        XCTAssertEqual(page.reviewHistory.map(\.kind), [.codeReview, .codeReview])
        XCTAssertEqual(page.reviewHistory.map(\.verdict), ["request_changes", "request_changes"])
        XCTAssertEqual(page.reviewHistory.first?.reason, "The review instructions still describe the Final verification step.")
        XCTAssertLessThan(try XCTUnwrap(page.reviewHistory.first?.at), try XCTUnwrap(page.reviewHistory.last?.at))

        XCTAssertEqual(page.areas.map(\.name), ["Agent instructions", "Server", "Documentation", "Tests"])
        XCTAssertEqual(page.areas.map(\.files).reduce(0, +), 14)
        XCTAssertEqual(page.areas.first, .init(name: "Agent instructions", files: 5, additions: 18, deletions: 240))

        XCTAssertEqual(page.health.checks, .init(state: .passed, passed: 9, failed: 0, pending: 0))
        XCTAssertEqual(page.health.codeReview, .init(verdict: "request_changes", round: 2))
        XCTAssertNil(page.health.qa)
        XCTAssertEqual(page.health.overlaps, [.init(number: 446, ticket: "TP-891")])
        XCTAssertEqual(page.size, .init(files: 14, additions: 120, deletions: 610, commits: 3))
    }

    func testThePullRequestFixtureServesThePageAndTheInbox() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("pull-request-\(UUID()).jsonl")
        let fixtures = APIFixtures(directory: fixture.deletingLastPathComponent().deletingLastPathComponent(), requestLog: log)
        let request = { (path: String) in URLRequest(url: APIFixtures.baseURL.appendingPathComponent(path)) }

        let page = fixtures.answer(request(PullRequestPage.path(repoKey: "symphony", number: 448)))
        XCTAssertEqual(page.1.statusCode, 200)
        XCTAssertNotNil(PullRequestPage.decode(page.0))
        let inbox = try XCTUnwrap(InboxPayload.decode(fixtures.answer(request(InboxPayload.path)).0))
        XCTAssertTrue(inbox.items.contains { $0.identifier == "TP-892" })

        let missing = fixtures.answer(request(PullRequestPage.path(repoKey: "symphony", number: 1)))
        XCTAssertEqual(PullRequestPageResult(.answered(missing.0, statusCode: missing.1.statusCode)), .notFound)
    }

    func testAPageWithoutGitHubCarriesWhatSymphonyKnows() throws {
        let json = """
        {"number": 448, "github": "unavailable", "state": null, "review_state": "changes_requested",
         "ticket": {"identifier": "TP-892", "state": "Rework", "waiting_on": "you"},
         "review_history": [{"at": "2026-10-06T11:40:00Z", "kind": "code_review", "verdict": "request_changes", "reason": null},
                            {"kind": "acceptance", "verdict": "pass"}, {"kind": "qa"}],
         "areas": [], "health": {"checks": null, "code_review": {"verdict": "request_changes", "round": 1}, "qa": null, "overlaps": []},
         "size": null}
        """
        let page = try XCTUnwrap(PullRequestPage.decode(Data(json.utf8)))
        XCTAssertFalse(page.gitHubAvailable)
        XCTAssertNil(page.state)
        XCTAssertNil(page.size)
        XCTAssertNil(page.health.checks)
        XCTAssertEqual(page.ticket?.identifier, "TP-892")
        XCTAssertEqual(page.reviewHistory.count, 1)
        XCTAssertNil(page.reviewHistory.first?.reason)
    }

    func testToleratesMissingAndUnknownFields() throws {
        let json = """
        {"number": 7, "state": "draft", "review_state": "weird", "ticket": {"title": "No id"},
         "areas": [{"files": 2}, {"name": "Server"}],
         "health": {"code_review": {"round": 2}, "overlaps": [{"ticket": "TP-1"}, {"number": 9}]}}
        """
        let page = try XCTUnwrap(PullRequestPage.decode(Data(json.utf8)))
        XCTAssertEqual(page.number, 7)
        XCTAssertTrue(page.gitHubAvailable)
        XCTAssertNil(page.state)
        XCTAssertEqual(page.reviewState, .open)
        XCTAssertNil(page.ticket)
        XCTAssertEqual(page.areas, [.init(name: "Server", files: 0, additions: 0, deletions: 0)])
        XCTAssertNil(page.health.codeReview)
        XCTAssertEqual(page.health.overlaps, [.init(number: 9, ticket: nil)])
        XCTAssertEqual(page.reviewHistory, [])

        XCTAssertNil(PullRequestPage.decode(Data(#"{"error": {"code": "not_found"}}"#.utf8)))
        XCTAssertNil(PullRequestPage.decode(Data(#"{"title": "No number"}"#.utf8)))
        XCTAssertNil(PullRequestPage.decode(Data("not json".utf8)))
    }

    func testPathEncodesTheRepoKey() {
        XCTAssertEqual(PullRequestPage.path(repoKey: "symphony", number: 448), "api/v1/pull_requests/symphony/448")
        XCTAssertEqual(PullRequestPage.path(repoKey: "web shop/x", number: 1), "api/v1/pull_requests/web%20shop%2Fx/1")
    }

    func testResults() {
        let page = Data(#"{"number": 448}"#.utf8)
        guard case let .loaded(loaded) = PullRequestPageResult(.answered(page, statusCode: 200)) else { return XCTFail("not loaded") }
        XCTAssertEqual(loaded.number, 448)
        XCTAssertEqual(PullRequestPageResult(.answered(Data("{}".utf8), statusCode: 200)), .failed("Symphony sent a pull request page that couldn't be read"))
        XCTAssertEqual(PullRequestPageResult(.answered(Data(#"{"error":{"code":"unknown_repo"}}"#.utf8), statusCode: 404)), .notFound)
        XCTAssertEqual(PullRequestPageResult(.answered(Data(#"{"error":{"code":"not_found"}}"#.utf8), statusCode: 404)), .notFound)
        // An older Symphony has no such route.
        XCTAssertEqual(PullRequestPageResult(.answered(Data(#"{"error":{"code":"request_failed"}}"#.utf8), statusCode: 404)), .unsupported)
        XCTAssertEqual(PullRequestPageResult(.answered(Data("Not Found".utf8), statusCode: 404)), .unsupported)
        XCTAssertEqual(PullRequestPageResult(.answered(Data(), statusCode: 500)), .failed("Symphony answered with HTTP 500"))
        XCTAssertEqual(PullRequestPageResult(.unreachable), .failed("Symphony isn't answering"))
    }
}
