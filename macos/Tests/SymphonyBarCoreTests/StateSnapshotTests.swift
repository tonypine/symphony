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

    /// Symphony's pause carries its reasons (TP-1236): each one's kind, line, time and, for an update's, the version
    /// as a field; the usage-limit holds' come even while nothing else pauses dispatch.
    func testDecodesThePausesReasonsWithTheUpdatesVersionAsAField() throws {
        let data = try recordedState(pause: [
            "paused": true, "reason": "updating to v0.0.1.700", "paused_at": "2026-10-02T12:16:02Z",
            "reasons": [
                ["kind": "build", "text": "updating to v0.0.1.700", "since": "2026-10-02T12:16:02Z", "waits_on": ["version": "0.0.1.700"]],
                ["kind": "person", "text": " Deploy freeze ", "since": NSNull(), "waits_on": ["action": "unblock"]],
                ["kind": "environment", "text": "Claude's usage limit until 14:30", "waits_on": ["condition": "usage_limit:anthropic:all"]],
                ["kind": "build", "waits_on": ["version": " "]],
                [:],
            ],
        ])
        guard case let .state(snapshot) = SymphonyState.poll(data: data, statusCode: 200) else { return XCTFail("not a state") }

        XCTAssertEqual(snapshot.pauseReasons, [
            .init(kind: .build, text: "updating to v0.0.1.700", since: Date(timeIntervalSince1970: 1_790_943_362), version: "0.0.1.700"),
            .init(kind: .person, text: "Deploy freeze"),
            .init(kind: .other("environment"), text: "Claude's usage limit until 14:30"),
            .init(kind: .build),
            .init(kind: .other("")),
        ])
        XCTAssertEqual(snapshot.updatePauseVersion, "0.0.1.700")

        let limited = try recordedState(pause: [
            "paused": false, "reason": NSNull(), "paused_at": NSNull(),
            "reasons": [["kind": "environment", "text": "Claude's usage limit until 14:30", "waits_on": ["condition": "usage_limit:anthropic:all"]]],
        ])
        guard case let .state(held) = SymphonyState.poll(data: limited, statusCode: 200) else { return XCTFail("not a state") }
        XCTAssertNil(held.pause)
        XCTAssertEqual(held.pauseReasons, [.init(kind: .other("environment"), text: "Claude's usage limit until 14:30")])
        XCTAssertNil(held.updatePauseVersion)
    }

    /// A Symphony that predates the reasons leaves them unknown, and its update's pause names no version field: the
    /// app no longer reads one out of the reason's text.
    func testAnOlderSymphonysPauseHasNoReasons() throws {
        let data = try recordedState(pause: ["paused": true, "reason": "updating to v0.0.1.42", "paused_at": NSNull()])
        guard case let .state(snapshot) = SymphonyState.poll(data: data, statusCode: 200) else { return XCTFail("not a state") }

        XCTAssertEqual(snapshot.pause, .init(reason: "updating to v0.0.1.42"))
        XCTAssertNil(snapshot.pauseReasons)
        XCTAssertNil(snapshot.updatePauseVersion)
    }

    func testEveryRepositoryPausedIsKnownOnlyWhenEachListedOneIs() {
        let paused = StateSnapshot.RepositoryPause(reasons: ["You paused this repository"])
        XCTAssertTrue(StateSnapshot(repositories: [.init(key: "a", pause: paused), .init(key: "b", pause: paused)]).allRepositoriesPaused)
        XCTAssertFalse(StateSnapshot(repositories: [.init(key: "a", pause: paused), .init(key: "b")]).allRepositoriesPaused)
        XCTAssertFalse(StateSnapshot(repositories: []).allRepositoriesPaused)
        XCTAssertFalse(StateSnapshot().allRepositoriesPaused)
    }

    func testDecodesTheRepositoriesAndTheirPauses() throws {
        let data = try recordedState(replacing: "repositories", with: [
            [
                "repo_key": "web-shop", "paused": true,
                "pause": [
                    "since": "2026-10-02T12:16:02Z", "set_by": ["kind": "person", "name": "Director"],
                    "reasons": [
                        ["kind": "person", "text": "focusing on Symphony this week", "releasable": true, "set_at": "2026-10-02T12:16:02Z"],
                        ["kind": "person", "text": "  "],
                        ["kind": "person"],
                    ],
                ],
            ],
            ["repo_key": "api", "paused": false, "pause": NSNull()],
            ["repo_key": "", "paused": false],
            ["paused": true],
        ])
        guard case let .state(snapshot) = SymphonyState.poll(data: data, statusCode: 200) else { return XCTFail("not a state") }

        XCTAssertEqual(snapshot.repositories, [
            .init(key: "web-shop", pause: .init(reasons: ["focusing on Symphony this week"], since: Date(timeIntervalSince1970: 1_790_943_362))),
            .init(key: "api"),
        ])
        XCTAssertEqual(snapshot.repository("api"), .init(key: "api"))
        XCTAssertNil(snapshot.repository("docs"))
    }

    func testAnOlderSymphonyListsNoRepositories() throws {
        guard case let .state(snapshot) = SymphonyState.poll(data: try recordedState(), statusCode: 200) else { return XCTFail("not a state") }

        XCTAssertNil(snapshot.repositories)
        XCTAssertNil(snapshot.repository("web-shop"))
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

    /// `dispatch_shadow` as `SymphonyElixirWeb.Presenter` serves it: the source, the window, the counts and the last
    /// differences, a priority's number and a state's name read as text.
    func testDecodesTheDispatchShadowReport() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/dispatch-shadow-block.json")
        let block = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture))
        guard case .state(let snapshot) = SymphonyState.poll(data: try recordedState(replacing: "dispatch_shadow", with: block), statusCode: 200)
        else { return XCTFail("expected a state") }
        XCTAssertEqual(
            snapshot.dispatchShadow,
            DispatchShadowReport(
                source: .poll,
                window: 20,
                cyclesCompared: 140,
                cyclesWithDifferences: 2,
                windowCycles: 20,
                windowDifferences: 3,
                recent: [
                    .init(identifier: "TP-1221", side: .both, field: "priority", poll: "1", record: "2", at: SymphonyState.parseDate("2026-10-29T18:00:48Z")),
                    .init(identifier: "TP-1222", side: .record, field: "candidate", record: "Todo", at: SymphonyState.parseDate("2026-10-29T17:58:30Z")),
                    .init(identifier: "TP-1223", side: .poll, field: "candidate", poll: "Todo", at: SymphonyState.parseDate("2026-10-29T17:57:00Z")),
                ]
            )
        )
        XCTAssertEqual(snapshot.dispatchShadow?.lastDifferenceAt, SymphonyState.parseDate("2026-10-29T18:00:48Z"))
        XCTAssertEqual(snapshot.runs, recordedRuns)
    }

    /// Dispatch from the record before any cycle, and a difference with no identifier, an unknown side and no time.
    func testDecodesARecordSourceWithNothingComparedYet() throws {
        let record: [String: Any] = [
            "source": "record", "window": 5, "cycles_compared": 0, "cycles_with_differences": 0, "window_cycles": 0,
            "window_differences": 0,
            "recent": [["identifier": NSNull(), "issue_id": "issue-9", "side": "elsewhere", "field": "state", "poll": NSNull(), "record": NSNull()]],
        ]
        guard case .state(let snapshot) = SymphonyState.poll(data: try recordedState(replacing: "dispatch_shadow", with: record), statusCode: 200)
        else { return XCTFail("expected a state") }
        XCTAssertEqual(
            snapshot.dispatchShadow,
            DispatchShadowReport(source: .record, window: 5, recent: [.init(identifier: "issue-9", side: .other("elsewhere"), field: "state")])
        )
        XCTAssertNil(snapshot.dispatchShadow?.lastDifferenceAt)

        let bare: [String: Any] = ["recent": [["side": "poll", "field": "candidate"]]]
        guard case .state(let sparse) = SymphonyState.poll(data: try recordedState(replacing: "dispatch_shadow", with: bare), statusCode: 200)
        else { return XCTFail("expected a state") }
        XCTAssertEqual(sparse.dispatchShadow, DispatchShadowReport(recent: [.init(identifier: "?", side: .poll, field: "candidate")]))
    }

    /// An older Symphony sends no `dispatch_shadow`, and a block this app can't read is left out: the rest of the state
    /// decodes either way.
    func testAnOlderOrUnreadableDispatchShadowBlockIsNone() throws {
        guard case .state(let older) = SymphonyState.poll(data: try recordedState(), statusCode: 200) else {
            return XCTFail("expected a state")
        }
        XCTAssertNil(older.dispatchShadow)
        XCTAssertEqual(older.runs, recordedRuns)

        let unreadable = try recordedState(replacing: "dispatch_shadow", with: ["window": "twenty", "recent": "none"])
        guard case .state(let snapshot) = SymphonyState.poll(data: unreadable, statusCode: 200) else {
            return XCTFail("expected a state")
        }
        XCTAssertNil(snapshot.dispatchShadow)
        XCTAssertEqual(snapshot.runs, recordedRuns)
    }

    /// `reconcile` as `SymphonyElixirWeb.Presenter` serves it: the last run, the interval, the counts and the last
    /// drift with both states and the outcome.
    func testDecodesTheReconcileReport() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/reconcile-block.json")
        let block = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture))
        guard case .state(let snapshot) = SymphonyState.poll(data: try recordedState(replacing: "reconcile", with: block), statusCode: 200)
        else { return XCTFail("expected a state") }
        XCTAssertEqual(
            snapshot.reconcile,
            ReconcileReport(
                lastRunAt: SymphonyState.parseDate("2026-10-29T18:00:00Z"),
                intervalMs: 300_000,
                applied: 3,
                reapplied: 1,
                unobservedFilled: 2,
                detected: 2,
                reverted: 1,
                revertFailed: 1,
                recent: [
                    .init(identifier: "TP-1301", recordPhase: "Code Review", linearPhase: "Done", outcome: .failed,
                          at: SymphonyState.parseDate("2026-10-29T17:59:10Z")),
                    .init(identifier: "TP-1300", recordPhase: "QA", linearPhase: "In Progress", outcome: .reverted,
                          at: SymphonyState.parseDate("2026-10-29T17:50:00Z")),
                ]
            )
        )
        XCTAssertEqual(snapshot.runs, recordedRuns)

        let sparse: [String: Any] = ["last_run_at": NSNull(), "recent": [["identifier": NSNull(), "outcome": "skipped"], [:]]]
        guard case .state(let bare) = SymphonyState.poll(data: try recordedState(replacing: "reconcile", with: sparse), statusCode: 200)
        else { return XCTFail("expected a state") }
        XCTAssertEqual(
            bare.reconcile,
            ReconcileReport(recent: [.init(identifier: "?", outcome: .other("skipped")), .init(identifier: "?", outcome: .other("unknown"))])
        )
    }

    /// An older Symphony sends no `reconcile`, and a block this app can't read is left out: the rest of the state
    /// decodes either way.
    func testAnOlderOrUnreadableReconcileBlockIsNone() throws {
        guard case .state(let older) = SymphonyState.poll(data: try recordedState(), statusCode: 200) else {
            return XCTFail("expected a state")
        }
        XCTAssertNil(older.reconcile)
        XCTAssertEqual(older.runs, recordedRuns)

        let unreadable = try recordedState(replacing: "reconcile", with: ["interval_ms": "five minutes", "recent": "none"])
        guard case .state(let snapshot) = SymphonyState.poll(data: unreadable, statusCode: 200) else {
            return XCTFail("expected a state")
        }
        XCTAssertNil(snapshot.reconcile)
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
