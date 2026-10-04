import XCTest
@testable import SymphonyBarCore

final class StateSnapshotTests: XCTestCase {
    /// `GET /api/v1/state` recorded from a running Symphony, with `run_history` trimmed to one entry.
    private func recordedState() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/state-running.json")
        return try Data(contentsOf: url)
    }

    /// The recorded state with its `pause` object replaced, as Symphony reports it after a dashboard pause.
    private func recordedState(pause: [String: Any]) throws -> Data {
        try recordedState(replacing: "pause", with: pause)
    }

    private func recordedState(replacing key: String, with value: Any) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: recordedState()) as? [String: Any])
        object[key] = value
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// The `budget` in the recorded state.
    private let recordedBudget = StateSnapshot.Budget(
        dailyLimit: 1_000_000_000,
        dailyUsed: 156_465_114,
        dailyRemaining: 843_534_886,
        dailyPaused: false,
        perIssueLimit: 100_000_000
    )

    func testDecodesTheRecordedState() throws {
        XCTAssertEqual(
            SymphonyState.poll(data: try recordedState(), statusCode: 200),
            .state(StateSnapshot(running: 1, retrying: 0, pause: nil, budget: recordedBudget))
        )
    }

    func testDecodesABudgetPausedOnTheDailyCap() throws {
        let data = try recordedState(replacing: "budget", with: [
            "daily_limit": 1_000_000_000, "daily_used": 1_000_000_123, "daily_remaining": 0, "daily_paused": true,
            "per_issue_limit": NSNull(),
        ])

        XCTAssertEqual(
            SymphonyState.poll(data: data, statusCode: 200),
            .state(
                StateSnapshot(
                    running: 1,
                    budget: .init(dailyLimit: 1_000_000_000, dailyUsed: 1_000_000_123, dailyRemaining: 0, dailyPaused: true)
                )
            )
        )
    }

    func testDecodesABudgetWithTheCapsOff() throws {
        let data = try recordedState(replacing: "budget", with: [
            "daily_limit": NSNull(), "daily_used": 42, "daily_remaining": NSNull(), "daily_paused": false,
            "per_issue_limit": NSNull(),
        ])

        XCTAssertEqual(
            SymphonyState.poll(data: data, statusCode: 200),
            .state(StateSnapshot(running: 1, budget: .init(dailyUsed: 42)))
        )
    }

    func testAnEmptyBudgetReadsAsNothingUsed() {
        XCTAssertEqual(
            SymphonyState.poll(data: Data(#"{"counts": {"running": 0}, "budget": {}}"#.utf8), statusCode: 200),
            .state(StateSnapshot(budget: .init()))
        )
    }

    func testDecodesAPause() throws {
        let data = try recordedState(pause: ["paused": true, "reason": "deploy freeze", "paused_at": "2026-10-02T12:16:02Z"])

        XCTAssertEqual(
            SymphonyState.poll(data: data, statusCode: 200),
            .state(
                StateSnapshot(
                    running: 1,
                    retrying: 0,
                    pause: .init(reason: "deploy freeze", since: Date(timeIntervalSince1970: 1_790_943_362)),
                    budget: recordedBudget
                )
            )
        )
    }

    func testDecodesAPauseWithoutReasonOrTime() throws {
        let data = try recordedState(pause: ["paused": true, "reason": NSNull(), "paused_at": NSNull()])

        XCTAssertEqual(
            SymphonyState.poll(data: data, statusCode: 200),
            .state(StateSnapshot(running: 1, retrying: 0, pause: .init(), budget: recordedBudget))
        )
    }

    func testDecodesUsageLimits() throws {
        let data = try recordedState(replacing: "usage_limits", with: [
            [
                "provider": "anthropic", "scope": "all", "reason": "claude_usage_limit", "window": "five_hour",
                "phase": "paused", "since": "2026-10-02T12:00:00Z", "resets_at": "2026-10-02T12:16:02Z",
                "resume_at": "2026-10-02T12:18:02Z", "source": "rate_limit_event", "utilization": 1.0,
                "issue_identifier": "TP-1",
            ],
            ["provider": "anthropic", "scope": "opus", "window": "seven_day_opus", "phase": "canary", "resume_at": NSNull()],
            ["provider": "openai", "scope": "all", "phase": "headroom", "utilization": 0.91],
            ["phase": "something_new"],
        ])

        XCTAssertEqual(
            SymphonyState.poll(data: data, statusCode: 200),
            .state(
                StateSnapshot(
                    running: 1,
                    usageLimits: [
                        .init(
                            window: "five_hour",
                            phase: .paused,
                            resetsAt: Date(timeIntervalSince1970: 1_790_943_362),
                            resumeAt: Date(timeIntervalSince1970: 1_790_943_482),
                            utilization: 1
                        ),
                        .init(scope: "opus", window: "seven_day_opus", phase: .canary),
                        .init(provider: "openai", phase: .headroom, utilization: 0.91),
                        .init(),
                    ],
                    budget: recordedBudget
                )
            )
        )
    }

    func testDecodesTheTicketsAnUpdateWouldUnblock() throws {
        let data = try recordedState(replacing: "app_update", with: ["unblocks": 2, "issue_identifiers": ["TP-313", "TP-332"]])
        XCTAssertEqual(SymphonyState.poll(data: data, statusCode: 200), .state(StateSnapshot(running: 1, budget: recordedBudget, updateUnblocks: 2)))

        let empty = try recordedState(replacing: "app_update", with: [String: Any]())
        XCTAssertEqual(SymphonyState.poll(data: empty, statusCode: 200), .state(StateSnapshot(running: 1, budget: recordedBudget)))
    }

    func testDecodesTheForcedTickets() throws {
        let data = try recordedState(replacing: "forced", with: [
            [
                "issue_id": "issue-123", "issue_identifier": "TP-123", "title": "Ship it", "state": "In Progress",
                "forced_since": "2026-10-02T12:16:02Z", "forced_for_seconds": 300, "stale": false, "position": 1,
                "waiting_on_human": false, "sub_issue": NSNull(), "phase": "implementation", "running": true,
                "waiting_on": NSNull(), "blockers": [String](), "summary": "implementation · running",
            ],
            [
                "issue_id": "issue-100", "issue_identifier": "TP-100", "state": "Todo", "forced_for_seconds": 270_000,
                "stale": true, "sub_issue": ["issue_id": "issue-101", "issue_identifier": "TP-101", "state": "In Review"],
                "phase": "waiting_for_human", "summary": "waiting for a human",
            ],
            // Without a phase Symphony sends no summary; without an identifier, the id names it.
            ["issue_id": "issue-7", "issue_identifier": NSNull(), "state": "Todo", "phase": NSNull(), "summary": NSNull()],
            ["title": "No id at all"],
        ])

        XCTAssertEqual(
            SymphonyState.poll(data: data, statusCode: 200),
            .state(
                StateSnapshot(
                    running: 1,
                    budget: recordedBudget,
                    forced: [
                        .init(identifier: "TP-123", summary: "implementation · running", state: "In Progress", forcedForSeconds: 300),
                        .init(
                            identifier: "TP-100",
                            summary: "waiting for a human",
                            state: "Todo",
                            forcedForSeconds: 270_000,
                            stale: true,
                            part: "TP-101"
                        ),
                        .init(identifier: "issue-7", state: "Todo"),
                    ]
                )
            )
        )
    }

    func testOlderSymphonyWithoutForcedTicketsDecodesWithNone() throws {
        // The recorded state predates `forced`.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: recordedState()) as? [String: Any])
        XCTAssertNil(object["forced"])
        XCTAssertEqual(
            SymphonyState.poll(data: try recordedState(), statusCode: 200),
            .state(StateSnapshot(running: 1, budget: recordedBudget))
        )

        let empty = try recordedState(replacing: "forced", with: [Any]())
        XCTAssertEqual(SymphonyState.poll(data: empty, statusCode: 200), .state(StateSnapshot(running: 1, budget: recordedBudget)))
    }

    func testDecodesTheHumanReviewCount() throws {
        // The recorded state predates the Human Review count, which then reads as none.
        XCTAssertEqual(
            SymphonyState.poll(data: Data(#"{"counts": {"running": 2, "retrying": 1, "human_review": 3}}"#.utf8), statusCode: 200),
            .state(StateSnapshot(running: 2, retrying: 1, humanReview: 3))
        )
        XCTAssertEqual(
            SymphonyState.poll(data: try recordedState(), statusCode: 200),
            .state(StateSnapshot(running: 1, budget: recordedBudget, humanReview: 0))
        )
    }

    func testRetryingDefaultsToZero() {
        XCTAssertEqual(
            SymphonyState.poll(data: Data(#"{"counts": {"running": 2}}"#.utf8), statusCode: 200),
            .state(StateSnapshot(running: 2))
        )
    }

    func testAnErrorPayloadFails() {
        let body = #"{"generated_at": "2026-10-02T12:16:02Z", "error": {"code": "snapshot_timeout", "message": "Snapshot timed out"}}"#

        XCTAssertEqual(SymphonyState.poll(data: Data(body.utf8), statusCode: 200), .failed("Snapshot timed out"))
        XCTAssertEqual(
            SymphonyState.poll(data: Data(#"{"error": {"code": "snapshot_unavailable"}}"#.utf8), statusCode: 200),
            .failed("snapshot_unavailable")
        )
        XCTAssertEqual(
            SymphonyState.poll(data: Data(#"{"error": {}}"#.utf8), statusCode: 200),
            .failed("Symphony reported an error")
        )
    }

    func testOtherStatusCodesFail() throws {
        XCTAssertEqual(SymphonyState.poll(data: try recordedState(), statusCode: 500), .failed("Symphony answered with HTTP 500"))
    }

    func testOtherBodiesFail() {
        for body in ["", "[]", "{}", #"{"counts": {}}"#, "<html>"] {
            XCTAssertEqual(
                SymphonyState.poll(data: Data(body.utf8), statusCode: 200),
                .failed("Symphony's state couldn't be read"),
                body
            )
        }
    }
}
