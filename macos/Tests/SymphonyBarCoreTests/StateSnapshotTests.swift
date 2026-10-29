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

    /// The `running` entry in the recorded state.
    private let recordedRuns = [
        StateSnapshot.Run(
            issueIdentifier: "TP-237",
            repoKey: "symphony",
            url: URL(string: "https://linear.app/tonypine/issue/TP-237/show-live-symphony-status-in-the-menu-bar-icon-and-menu"),
            startedAt: Date(timeIntervalSince1970: 1_790_943_362),
            lastEventAt: Date(timeIntervalSince1970: 1_790_943_458)
        ),
    ]

    func testDecodesTheRecordedState() throws {
        XCTAssertEqual(
            SymphonyState.poll(data: try recordedState(), statusCode: 200),
            .state(StateSnapshot(running: 1, retrying: 0, pause: nil, budget: recordedBudget, runs: recordedRuns))
        )
    }

    func testDecodesTheSessionKinds() throws {
        let data = try recordedState(
            replacing: "sessions", with: [["kind": "implementation", "issue_identifier": "TP-1"], ["kind": "qa_pass"], [:]]
        )
        guard case .state(let snapshot) = SymphonyState.poll(data: data, statusCode: 200) else {
            return XCTFail("expected a state")
        }
        XCTAssertEqual(snapshot.sessionKinds, ["implementation", "qa_pass", "agent"])
    }

    func testASymphonyWithoutSessionsLeavesTheKindsUnknown() {
        guard case .state(let snapshot) = SymphonyState.poll(data: Data(#"{"counts": {"running": 0}}"#.utf8), statusCode: 200) else {
            return XCTFail("expected a state")
        }
        XCTAssertNil(snapshot.sessionKinds)
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
                    budget: .init(dailyLimit: 1_000_000_000, dailyUsed: 1_000_000_123, dailyRemaining: 0, dailyPaused: true),
                    runs: recordedRuns
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
            .state(StateSnapshot(running: 1, budget: .init(dailyUsed: 42), runs: recordedRuns))
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
                    budget: recordedBudget,
                    runs: recordedRuns
                )
            )
        )
    }

    func testDecodesAPauseWithoutReasonOrTime() throws {
        let data = try recordedState(pause: ["paused": true, "reason": NSNull(), "paused_at": NSNull()])

        XCTAssertEqual(
            SymphonyState.poll(data: data, statusCode: 200),
            .state(StateSnapshot(running: 1, retrying: 0, pause: .init(), budget: recordedBudget, runs: recordedRuns))
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
            [
                "provider": "anthropic", "scope": "all", "reason": "model_api_unreachable", "window": NSNull(),
                "phase": "paused", "resume_at": "2026-10-02T12:18:02Z", "source": "api_unreachable", "error": "ENOTFOUND",
                "banner": "Paused: Claude API unreachable (ENOTFOUND), retries ~12:18",
            ],
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
                            utilization: 1,
                            reason: "claude_usage_limit"
                        ),
                        .init(scope: "opus", window: "seven_day_opus", phase: .canary),
                        .init(provider: "openai", phase: .headroom, utilization: 0.91),
                        .init(
                            phase: .paused,
                            resumeAt: Date(timeIntervalSince1970: 1_790_943_482),
                            reason: "model_api_unreachable",
                            error: "ENOTFOUND"
                        ),
                        .init(),
                    ],
                    budget: recordedBudget,
                    runs: recordedRuns
                )
            )
        )
    }

    func testDecodesTheTicketsAnUpdateWouldUnblock() throws {
        let data = try recordedState(replacing: "app_update", with: ["unblocks": 2, "issue_identifiers": ["TP-313", "TP-332"]])
        XCTAssertEqual(SymphonyState.poll(data: data, statusCode: 200), .state(StateSnapshot(running: 1, budget: recordedBudget, updateUnblocks: 2, runs: recordedRuns)))

        let empty = try recordedState(replacing: "app_update", with: [String: Any]())
        XCTAssertEqual(SymphonyState.poll(data: empty, statusCode: 200), .state(StateSnapshot(running: 1, budget: recordedBudget, runs: recordedRuns)))
    }

    /// `app_update` as Symphony serves it: the API's tests compare `WatchPayload.app_update/2` against this file too.
    func testDecodesTheNewestReleaseFromTheSharedContract() throws {
        let contract = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../test/fixtures/api/app_update_block.json")
            .standardized
        let block = try JSONSerialization.jsonObject(with: Data(contentsOf: contract))
        let data = try recordedState(replacing: "app_update", with: block)

        let release = ReportedRelease(tag: "v0.0.1.583", publishedAt: Date(timeIntervalSince1970: 1_792_137_600))
        XCTAssertEqual(
            SymphonyState.poll(data: data, statusCode: 200),
            .state(StateSnapshot(running: 1, budget: recordedBudget, updateUnblocks: 1, latestRelease: release, runs: recordedRuns))
        )
        XCTAssertEqual(release.version, "0.0.1.583")
        XCTAssertEqual(ReportedRelease(tag: "0.0.1.583").version, "0.0.1.583")
    }

    /// `linear_webhooks` as `SymphonyElixirWeb.Presenter` serves it: the switch, the secret's presence and the counts.
    func testDecodesTheLinearWebhookDeliveries() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/linear-webhooks-block.json")
        let block = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture))
        guard case .state(let snapshot) = SymphonyState.poll(data: try recordedState(replacing: "linear_webhooks", with: block), statusCode: 200)
        else { return XCTFail("expected a state") }
        XCTAssertEqual(
            snapshot.linearWebhooks,
            LinearWebhookHealth(
                enabled: true,
                secretConfigured: true,
                total: 3,
                rejected: 1,
                lastAt: SymphonyState.parseDate("2026-10-29T08:00:48Z"),
                lastRejectedAt: SymphonyState.parseDate("2026-10-29T07:57:00Z"),
                lastRejectedReason: "bad_signature"
            )
        )
    }

    /// Off, with nothing counted yet: the nulls read as nothing.
    func testDecodesLinearWebhooksTurnedOff() throws {
        let off: [String: Any] = [
            "enabled": false, "secret_configured": false, "total": 0, "rejected": 0, "last_at": NSNull(),
            "last_rejected_at": NSNull(), "last_rejected_reason": NSNull(), "counts": [], "rejected_reasons": [], "recent": [],
        ]
        guard case .state(let snapshot) = SymphonyState.poll(data: try recordedState(replacing: "linear_webhooks", with: off), statusCode: 200)
        else { return XCTFail("expected a state") }
        XCTAssertEqual(snapshot.linearWebhooks, LinearWebhookHealth())
    }

    /// An older Symphony sends no `linear_webhooks`, and a block this app can't read is left out: the rest of the state
    /// decodes either way.
    func testAnOlderOrUnreadableLinearWebhooksBlockIsNone() throws {
        guard case .state(let older) = SymphonyState.poll(data: try recordedState(), statusCode: 200) else {
            return XCTFail("expected a state")
        }
        XCTAssertNil(older.linearWebhooks)
        XCTAssertEqual(older.runs, recordedRuns)

        let unreadable = try recordedState(replacing: "linear_webhooks", with: ["enabled": "yes", "total": "many"])
        guard case .state(let snapshot) = SymphonyState.poll(data: unreadable, statusCode: 200) else {
            return XCTFail("expected a state")
        }
        XCTAssertNil(snapshot.linearWebhooks)
        XCTAssertEqual(snapshot.runs, recordedRuns)
    }

    func testANullOrTaglessReleaseIsNone() throws {
        for latest: Any in [NSNull(), ["tag": NSNull()], ["tag": ""]] {
            let data = try recordedState(replacing: "app_update", with: ["unblocks": 0, "latest_release": latest])
            guard case .state(let snapshot) = SymphonyState.poll(data: data, statusCode: 200) else {
                return XCTFail("expected a state")
            }
            XCTAssertNil(snapshot.latestRelease)
        }

        let undated = try recordedState(replacing: "app_update", with: ["latest_release": ["tag": "v2"]])
        guard case .state(let snapshot) = SymphonyState.poll(data: undated, statusCode: 200) else {
            return XCTFail("expected a state")
        }
        XCTAssertEqual(snapshot.latestRelease, ReportedRelease(tag: "v2"))
    }

    func testDecodesTheForcedTickets() throws {
        let data = try recordedState(replacing: "forced", with: [
            [
                "issue_id": "issue-123", "issue_identifier": "TP-123", "title": "Ship it", "repo_key": "web", "state": "In Progress",
                "forced_since": "2026-10-02T12:16:02Z", "forced_for_seconds": 300, "stale": false, "position": 1,
                "waiting_on_human": false, "sub_issue": NSNull(), "phase": "implementation", "running": true,
                "waiting_on": NSNull(), "blockers": [String](), "summary": "implementation · running",
            ],
            [
                "issue_id": "issue-100", "issue_identifier": "TP-100", "state": "Todo", "forced_for_seconds": 270_000,
                "stale": true, "sub_issue": ["issue_id": "issue-101", "issue_identifier": "TP-101", "state": "Code Review"],
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
                        .init(
                            identifier: "TP-123",
                            issueID: "issue-123",
                            title: "Ship it",
                            repoKey: "web",
                            summary: "implementation · running",
                            state: "In Progress",
                            forcedForSeconds: 300
                        ),
                        .init(
                            identifier: "TP-100",
                            issueID: "issue-100",
                            summary: "waiting for a human",
                            state: "Todo",
                            forcedForSeconds: 270_000,
                            stale: true,
                            part: "TP-101"
                        ),
                        .init(identifier: "issue-7", issueID: "issue-7", state: "Todo"),
                    ],
                    runs: recordedRuns
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
            .state(StateSnapshot(running: 1, budget: recordedBudget, runs: recordedRuns))
        )

        let empty = try recordedState(replacing: "forced", with: [Any]())
        XCTAssertEqual(SymphonyState.poll(data: empty, statusCode: 200), .state(StateSnapshot(running: 1, budget: recordedBudget, runs: recordedRuns)))
    }

    func testIgnoresTheRetiredHumanReviewCount() {
        // A Symphony from before the state machine redesign still sends it; the state reads the same without it.
        XCTAssertEqual(
            SymphonyState.poll(data: Data(#"{"counts": {"running": 2, "retrying": 1, "human_review": 3}}"#.utf8), statusCode: 200),
            .state(StateSnapshot(running: 2, retrying: 1))
        )
    }

    func testDecodesWhatWaitsOnYou() throws {
        let data = try recordedState(replacing: "waiting_on_you", with: [
            [
                "issue_id": "id-1", "issue_identifier": "TP-1", "repo_key": "symphony", "title": "Research issue template",
                "url": "https://linear.app/tonypine/issue/TP-1", "state": "Plan Review", "kind": "plan",
                "headline": "The split", "waiting_since": "2026-10-02T12:16:02Z", "waiting_seconds": 7_200,
            ],
            ["issue_id": "id-2", "kind": "final_verification", "headline": NSNull(), "waiting_seconds": NSNull()],
            ["kind": "pr"],
            ["issue_identifier": "TP-3", "kind": "action"],
            ["issue_identifier": "TP-4", "kind": "pr"],
            ["issue_identifier": "TP-5"],
        ])

        guard case let .state(snapshot) = SymphonyState.poll(data: data, statusCode: 200) else {
            return XCTFail("the state should read")
        }
        XCTAssertEqual(snapshot.waitingOnYou, [
            .init(
                issueID: "id-1", identifier: "TP-1", repoKey: "symphony", title: "Research issue template",
                url: URL(string: "https://linear.app/tonypine/issue/TP-1"), kind: .plan, headline: "The split", waitingSeconds: 7_200
            ),
            .init(issueID: "id-2", identifier: "id-2", kind: .other("final_verification")),
            .init(identifier: "TP-3", kind: .action),
            .init(identifier: "TP-4", kind: .pr),
            .init(identifier: "TP-5", kind: .other("")),
        ])

        // The recorded state predates the list, which then reads as empty.
        XCTAssertEqual(
            SymphonyState.poll(data: try recordedState(), statusCode: 200),
            .state(StateSnapshot(running: 1, budget: recordedBudget, runs: recordedRuns))
        )
    }

    func testDecodesTheRunningEntries() throws {
        let data = try recordedState(replacing: "running", with: [
            [
                "issue_id": "issue-7", "issue_identifier": "TP-7", "repo_key": "api", "url": "https://linear.app/t/issue/TP-7",
                "started_at": "2026-10-02T12:00:00Z", "last_event_at": "2026-10-02T12:16:02Z", "turn_count": 3,
            ],
            // Before its first event, and without an identifier: the id names it.
            ["issue_id": "issue-8", "issue_identifier": NSNull(), "started_at": "2026-10-02T12:16:02Z", "last_event_at": NSNull()],
            ["title": "No id at all", "started_at": "2026-10-02T12:16:02Z"],
            ["issue_identifier": "TP-9", "started_at": "not a date", "url": NSNull()],
        ])

        guard case let .state(snapshot) = SymphonyState.poll(data: data, statusCode: 200) else {
            return XCTFail("expected a state")
        }
        XCTAssertEqual(snapshot.running, 1, "the count stays counts.running")
        XCTAssertEqual(
            snapshot.runs,
            [
                .init(
                    issueIdentifier: "TP-7",
                    repoKey: "api",
                    url: URL(string: "https://linear.app/t/issue/TP-7"),
                    startedAt: Date(timeIntervalSince1970: 1_790_942_400),
                    lastEventAt: Date(timeIntervalSince1970: 1_790_943_362)
                ),
                .init(issueIdentifier: "issue-8", startedAt: Date(timeIntervalSince1970: 1_790_943_362)),
                .init(issueIdentifier: "TP-9"),
            ]
        )
        XCTAssertEqual(SymphonyState.poll(data: Data(#"{"counts": {"running": 0}}"#.utf8), statusCode: 200), .state(StateSnapshot()))
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
