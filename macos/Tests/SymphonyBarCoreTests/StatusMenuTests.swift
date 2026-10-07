import XCTest
@testable import SymphonyBarCore

final class StatusMenuTests: XCTestCase {
    func testQuitItemUsesCommandQ() {
        XCTAssertEqual(StatusMenu.quitKeyEquivalent, "q")
        XCTAssertFalse(StatusMenu.quitTitle.isEmpty)
    }

    private let snapshot = StateSnapshot(running: 2, retrying: 1)
    private let utc = TimeZone(identifier: "UTC")!
    private let pausedAt = Date(timeIntervalSince1970: 1_790_943_362) // 2026-10-02 12:16:02 UTC

    private var allStatuses: [SymphonyStatus] {
        [.stopped, .starting, .running(snapshot, external: false), .paused(snapshot, external: false), .error("boom")]
    }

    func testEachStatusHasItsOwnIcon() {
        let symbols = allStatuses.map(StatusMenu.iconSymbolName(for:))

        XCTAssertEqual(Set(symbols).count, allStatuses.count)
        XCTAssertEqual(StatusMenu.iconSymbolName(for: .running(snapshot, external: true)), "music.note.list")
        XCTAssertEqual(StatusMenu.iconSymbolName(for: .paused(snapshot, external: true)), "pause.circle")
        XCTAssertEqual(StatusMenu.iconLabel(for: .running(snapshot, external: true)), "Symphony: running (external)")
        XCTAssertEqual(StatusMenu.iconLabel(for: .error("boom")), "Symphony: error")
    }

    func testSourceLineNamesTheSymphonyStartRuns() {
        let embedded = AppSettings(checkoutPath: "/src/symphony", configPath: "/s.yml")
        XCTAssertEqual(
            StatusMenu.sourceLine(embedded, appVersion: "0.1.0.42", embeddedAvailable: true),
            "Symphony v0.1.0.42 (embedded)"
        )
        XCTAssertEqual(StatusMenu.sourceLine(embedded, appVersion: nil, embeddedAvailable: true), "Symphony (embedded)")
        XCTAssertEqual(StatusMenu.sourceLine(embedded, appVersion: " ", embeddedAvailable: true), "Symphony (embedded)")
        XCTAssertEqual(
            StatusMenu.sourceLine(embedded, appVersion: "0.1.0", embeddedAvailable: false),
            "No embedded Symphony: turn on Development mode"
        )

        let development = AppSettings(checkoutPath: " /src/symphony ", developmentMode: true)
        XCTAssertEqual(
            StatusMenu.sourceLine(development, appVersion: "0.1.0", embeddedAvailable: true),
            "Development: /src/symphony"
        )
        XCTAssertEqual(
            StatusMenu.sourceLine(AppSettings(developmentMode: true), appVersion: nil, embeddedAvailable: false),
            "Development: no checkout folder set"
        )
    }

    func testStatusTitles() {
        XCTAssertEqual(StatusMenu.statusTitle(.stopped), "Symphony is stopped")
        XCTAssertEqual(StatusMenu.statusTitle(.starting), "Symphony is starting…")
        XCTAssertEqual(StatusMenu.statusTitle(.running(snapshot, external: false)), "Symphony is running")
        XCTAssertEqual(StatusMenu.statusTitle(.running(snapshot, external: true)), "Symphony is running (external)")
        XCTAssertEqual(StatusMenu.statusTitle(.paused(snapshot, external: false)), "Symphony is paused")
        XCTAssertEqual(StatusMenu.statusTitle(.paused(snapshot, external: true)), "Symphony is paused (external)")
        XCTAssertEqual(StatusMenu.statusTitle(.error("boom")), "Symphony has a problem")
    }

    func testDetailLines() {
        var paused = snapshot
        paused.pause = .init(reason: "deploy freeze", since: pausedAt)
        let now = pausedAt.addingTimeInterval(600)

        XCTAssertEqual(StatusMenu.detailLines(.stopped), [])
        XCTAssertEqual(StatusMenu.detailLines(.starting), [])
        XCTAssertEqual(StatusMenu.detailLines(.running(snapshot, external: true)), ["2 running · 1 retrying"])
        XCTAssertEqual(
            StatusMenu.detailLines(.paused(paused, external: false), now: now, timeZone: utc),
            ["2 running · 1 retrying", "Paused since 12:16: deploy freeze"]
        )
        XCTAssertEqual(StatusMenu.detailLines(.paused(snapshot, external: false)), ["2 running · 1 retrying"])
        XCTAssertEqual(StatusMenu.detailLines(.error("Symphony exited with status 1")), ["Symphony exited with status 1"])
    }

    func testDetailLinesSayHowManyTicketsAnUpdateWouldUnblock() {
        let held = StateSnapshot(running: 2, retrying: 1, updateUnblocks: 2)

        XCTAssertEqual(
            StatusMenu.detailLines(.running(held, external: false)),
            ["2 running · 1 retrying", "Update to unblock 2 tickets"]
        )
        XCTAssertEqual(StatusMenu.updateUnblocksLine(1), "Update to unblock 1 ticket")
        XCTAssertNil(StatusMenu.updateUnblocksLine(0))
        XCTAssertNil(StatusMenu.updateUnblocksLine(-1))
    }

    func testDetailLinesLeaveWhatWaitsOnYouToItsItems() {
        var waiting = StateSnapshot(
            running: 2, retrying: 1, updateUnblocks: 1, humanReview: 3,
            waitingOnYou: [.init(identifier: "TP-1", kind: .pr, waitingSeconds: 60)]
        )
        waiting.pause = .init(reason: "deploy freeze", since: pausedAt)

        XCTAssertEqual(
            StatusMenu.detailLines(.paused(waiting, external: false), now: pausedAt.addingTimeInterval(600), timeZone: utc),
            ["2 running · 1 retrying", "Paused since 12:16: deploy freeze", "Update to unblock 1 ticket"]
        )
    }

    func testWaitingMenuListsUpToTheLimitThenOpensTheDashboardForTheRest() {
        let tickets = (1...7).map { StateSnapshot.WaitingTicket(identifier: "TP-\($0)") }
        let snapshot = StateSnapshot(running: 1, waitingOnYou: tickets)

        XCTAssertEqual(
            StatusMenu.waitingMenu(.running(snapshot, external: false)),
            .init(tickets: Array(tickets.prefix(5)), moreTitle: "2 more…")
        )
        XCTAssertEqual(
            StatusMenu.waitingMenu(.paused(snapshot, external: true), limit: 7),
            .init(tickets: tickets, moreTitle: nil)
        )
        XCTAssertEqual(StatusMenu.waitingMenu(.running(StateSnapshot(running: 1), external: false)), .init(tickets: [], moreTitle: nil))
        for status in [SymphonyStatus.stopped, .starting, .error("boom")] {
            XCTAssertEqual(StatusMenu.waitingMenu(status), .init(tickets: [], moreTitle: nil))
        }
    }

    func testWaitingLineShowsKindHeadlineAndHowLongItWaited() {
        let plan = StateSnapshot.WaitingTicket(
            identifier: "TP-123", title: "Research issue template", kind: .plan,
            headline: "  Split the importer\ninto four sub-tickets ", waitingSeconds: 7_300
        )
        XCTAssertEqual(StatusMenu.waitingLine(plan), "TP-123 · Plan · Split the importer into four sub-tickets · 2h")

        // Without a brief the title stands in; without either, only what is known shows.
        XCTAssertEqual(
            StatusMenu.waitingLine(.init(identifier: "TP-2", title: "Fix the poller", kind: .pr, headline: " ", waitingSeconds: 30)),
            "TP-2 · PR · Fix the poller · 30s"
        )
        XCTAssertEqual(StatusMenu.waitingLine(.init(identifier: "TP-3", kind: .finalVerification)), "TP-3 · Final verification")
        XCTAssertEqual(StatusMenu.waitingLine(.init(identifier: "TP-4", kind: .action, waitingSeconds: 200_000)), "TP-4 · Action · 2d")
        XCTAssertEqual(StatusMenu.waitingLine(.init(identifier: "TP-5", kind: .other("audit"), waitingSeconds: 900)), "TP-5 · Review · 15m")

        let long = StatusMenu.waitingLine(.init(identifier: "TP-6", headline: String(repeating: "a", count: 80)))
        XCTAssertEqual(long, "TP-6 · PR · " + String(repeating: "a", count: 59) + "…")
        XCTAssertEqual(StatusMenu.waitedLabel(-5), "0s")
    }

    func testBadgeCountsWhatWaitsOnYouWhileSymphonyAnswers() {
        let waiting = StateSnapshot(running: 1, waitingOnYou: [.init(identifier: "TP-1"), .init(identifier: "TP-2")])

        XCTAssertEqual(StatusMenu.badgeCount(for: .running(waiting, external: false)), 2)
        XCTAssertEqual(StatusMenu.badgeCount(for: .paused(waiting, external: false)), 2)
        XCTAssertNil(StatusMenu.badgeCount(for: .running(StateSnapshot(running: 1), external: false)))
        XCTAssertNil(StatusMenu.badgeCount(for: .stopped))
        XCTAssertNil(StatusMenu.badgeCount(for: .error("boom")))

        let running = SymphonyStatus.running(waiting, external: false)
        XCTAssertEqual(StatusMenu.iconLabel(for: running, badge: 2), "Symphony: running, 2 tickets wait on you")
        XCTAssertEqual(StatusMenu.iconLabel(for: running, badge: 1), "Symphony: running, 1 ticket waits on you")
        XCTAssertEqual(StatusMenu.iconLabel(for: running, badge: nil), "Symphony: running")
    }

    func testForcedTicketsShowOnlyWhileSymphonyAnswers() {
        let ticket = StateSnapshot.ForcedTicket(identifier: "TP-123", summary: "implementation · running")
        let forced = StateSnapshot(running: 1, forced: [ticket])

        XCTAssertEqual(StatusMenu.forcedTickets(.running(forced, external: false)), [ticket])
        XCTAssertEqual(StatusMenu.forcedTickets(.paused(forced, external: true)), [ticket])
        XCTAssertEqual(StatusMenu.forcedTickets(.running(snapshot, external: false)), [])
        for status in [SymphonyStatus.stopped, .starting, .error("boom")] {
            XCTAssertEqual(StatusMenu.forcedTickets(status), [], "\(status)")
        }
    }

    func testForceIsOfferedWhileSymphonyAnswers() {
        XCTAssertTrue(StatusMenu.canForce(.running(snapshot, external: false)))
        XCTAssertTrue(StatusMenu.canForce(.running(snapshot, external: true)))
        XCTAssertTrue(StatusMenu.canForce(.paused(snapshot, external: false)))
        XCTAssertFalse(StatusMenu.canForce(.stopped))
        XCTAssertFalse(StatusMenu.canForce(.starting))
        XCTAssertFalse(StatusMenu.canForce(.error("boom")))
    }

    func testForcedLines() {
        XCTAssertEqual(
            StatusMenu.forcedLine(.init(identifier: "TP-123", summary: "implementation · running", forcedForSeconds: 45)),
            "⚡ TP-123 · implementation · running · forced 45s"
        )
        XCTAssertEqual(
            StatusMenu.forcedLine(.init(identifier: "TP-123", summary: "implementation · running")),
            "⚡ TP-123 · implementation · running"
        )
        XCTAssertEqual(
            StatusMenu.forcedLine(
                .init(identifier: "TP-100", summary: "waiting for a human", forcedForSeconds: 270_000, stale: true, part: "TP-101")
            ),
            "⚡ TP-100 → TP-101 · waiting for a human · forced 3d 3h · stale"
        )
        // Without a summary, the ticket's state says where it is.
        XCTAssertEqual(StatusMenu.forcedLine(.init(identifier: "TP-7", state: "Todo", forcedForSeconds: 720)), "⚡ TP-7 · Todo · forced 12m")
        XCTAssertEqual(StatusMenu.forcedLine(.init(identifier: "TP-7")), "⚡ TP-7")
        XCTAssertEqual(StatusMenu.stopForcingTitle("TP-123"), "Stop forcing TP-123")
    }

    func testDurationLabelsMatchTheDashboards() {
        XCTAssertEqual(StatusMenu.durationLabel(-5), "0s")
        XCTAssertEqual(StatusMenu.durationLabel(0), "0s")
        XCTAssertEqual(StatusMenu.durationLabel(59), "59s")
        XCTAssertEqual(StatusMenu.durationLabel(60), "1m")
        XCTAssertEqual(StatusMenu.durationLabel(3_599), "59m")
        XCTAssertEqual(StatusMenu.durationLabel(3_600), "1h 0m")
        XCTAssertEqual(StatusMenu.durationLabel(11_100), "3h 5m")
        XCTAssertEqual(StatusMenu.durationLabel(86_399), "23h 59m")
        XCTAssertEqual(StatusMenu.durationLabel(86_400), "1d 0h")
        XCTAssertEqual(StatusMenu.durationLabel(187_200), "2d 4h")
    }

    func testForcePrompt() {
        XCTAssertEqual(StatusMenu.forceTitle, "Force a ticket…")
        XCTAssertEqual(StatusMenu.forcingTitle("TP-123"), "Forcing TP-123…")
        XCTAssertEqual(StatusMenu.forceIdentifier(" TP-123\n"), "TP-123")
        XCTAssertNil(StatusMenu.forceIdentifier(""))
        XCTAssertNil(StatusMenu.forceIdentifier("  \n"))
    }

    func testDetailLinesEndWithTheControlError() {
        XCTAssertEqual(
            StatusMenu.detailLines(.running(snapshot, external: false), controlError: "Couldn't pause Symphony: HTTP 500"),
            ["2 running · 1 retrying", "Couldn't pause Symphony: HTTP 500"]
        )
        XCTAssertEqual(StatusMenu.detailLines(.stopped, controlError: "Couldn't resume Symphony"), ["Couldn't resume Symphony"])
    }

    func testDetailLinesShowTheRestartBeforeTheControlError() {
        XCTAssertEqual(
            StatusMenu.detailLines(
                .running(snapshot, external: false),
                restartLine: "Waiting for 2 agent runs…",
                controlError: "Couldn't pause Symphony"
            ),
            ["2 running · 1 retrying", "Waiting for 2 agent runs…", "Couldn't pause Symphony"]
        )
    }

    func testDetailLinesSaySymphonyIsSlowToAnswerUnderItsLastAnswer() {
        XCTAssertEqual(
            StatusMenu.detailLines(
                .running(snapshot, external: false),
                slowToAnswer: true,
                waitingForKeychain: true,
                controlError: "Couldn't pause Symphony: HTTP 500"
            ),
            [
                "2 running · 1 retrying", "Symphony is slow to answer", "Waiting for Keychain access…",
                "Couldn't pause Symphony: HTTP 500",
            ]
        )
        // Still running, not a problem.
        XCTAssertEqual(StatusMenu.statusTitle(.running(snapshot, external: false)), "Symphony is running")
    }

    func testDetailLinesShowTheKeychainWaitBeforeTheRestart() {
        XCTAssertEqual(StatusMenu.detailLines(.stopped, waitingForKeychain: true), ["Waiting for Keychain access…"])
        XCTAssertEqual(
            StatusMenu.detailLines(
                .running(snapshot, external: false),
                waitingForKeychain: true,
                restartLine: "Restarting: starting Symphony…"
            ),
            ["2 running · 1 retrying", "Waiting for Keychain access…", "Restarting: starting Symphony…"]
        )
    }

    func testRestartIsOfferedOnlyForTheAppsAnsweringSymphony() {
        XCTAssertEqual(allStatuses.map(StatusMenu.canRestart), [false, false, true, true, false])
        XCTAssertFalse(StatusMenu.canRestart(.running(snapshot, external: true)))
        XCTAssertFalse(StatusMenu.canRestart(.paused(snapshot, external: true)))
    }

    func testRestartPathStopsAndStartsTheAppsSymphonyThatDoesntAnswer() {
        let error = SymphonyStatus.error("Symphony isn't answering")
        XCTAssertEqual(StatusMenu.restartPath(error, appRunsSymphony: true), .stopAndStart)
        XCTAssertEqual(StatusMenu.restartPath(error, appRunsSymphony: false), .start)
        XCTAssertEqual(StatusMenu.restartPath(.stopped, appRunsSymphony: false), .start)
        XCTAssertNil(StatusMenu.restartPath(.stopped, appRunsSymphony: true))
        XCTAssertEqual(StatusMenu.restartPath(.running(snapshot, external: false), appRunsSymphony: true), .graceful)
        XCTAssertEqual(StatusMenu.restartPath(.paused(snapshot, external: false), appRunsSymphony: true), .graceful)
        XCTAssertNil(StatusMenu.restartPath(.running(snapshot, external: true), appRunsSymphony: false))
        XCTAssertNil(StatusMenu.restartPath(.paused(snapshot, external: true), appRunsSymphony: false))
        XCTAssertNil(StatusMenu.restartPath(.starting, appRunsSymphony: true))
        XCTAssertNil(StatusMenu.restartPath(.starting, appRunsSymphony: false))
    }

    func testRestartTitles() {
        XCTAssertEqual(StatusMenu.restartTitle, "Restart Symphony")
        XCTAssertEqual(StatusMenu.restartingTitle, "Restarting Symphony…")
        XCTAssertEqual(StatusMenu.restartNowTitle, "Restart Now Anyway")
        XCTAssertEqual(StatusMenu.cancelRestartTitle, "Cancel Restart")
    }

    func testPauseIsOfferedWhileRunningAndResumeWhilePaused() {
        let offered = allStatuses.map { (StatusMenu.canPause($0), StatusMenu.canResume($0)) }

        XCTAssertEqual(offered.map(\.0), [false, false, true, false, false])
        XCTAssertEqual(offered.map(\.1), [false, false, false, true, false])
        // An external Symphony is paused and resumed through its control API too.
        XCTAssertTrue(StatusMenu.canPause(.running(snapshot, external: true)))
        XCTAssertTrue(StatusMenu.canResume(.paused(snapshot, external: true)))
    }

    func testPauseTitleSaysActiveRunsContinue() {
        XCTAssertEqual(StatusMenu.pauseTitle, "Pause Dispatch (active runs continue)")
        XCTAssertEqual(StatusMenu.pausingTitle, "Pausing Dispatch…")
        XCTAssertEqual(StatusMenu.resumeTitle, "Resume Dispatch")
        XCTAssertEqual(StatusMenu.resumingTitle, "Resuming Dispatch…")
    }

    func testPauseLine() {
        let sameDay = pausedAt.addingTimeInterval(3600)
        let nextDay = pausedAt.addingTimeInterval(86_400)

        XCTAssertEqual(StatusMenu.pauseLine(.init(reason: " lunch ", since: pausedAt), now: sameDay, timeZone: utc), "Paused since 12:16: lunch")
        XCTAssertEqual(StatusMenu.pauseLine(.init(reason: nil, since: pausedAt), now: nextDay, timeZone: utc), "Paused since Oct 2, 12:16")
        XCTAssertEqual(StatusMenu.pauseLine(.init(reason: "lunch", since: nil), now: sameDay, timeZone: utc), "Paused: lunch")
        XCTAssertEqual(StatusMenu.pauseLine(.init(reason: "  ", since: nil), now: sameDay, timeZone: utc), "Paused")
    }

    // 2026-10-02 12:16:02 UTC is the reset; resumes two minutes after.
    private var claudeLimit: StateSnapshot.UsageLimit {
        .init(window: "five_hour", phase: .paused, resetsAt: pausedAt, resumeAt: pausedAt.addingTimeInterval(120))
    }

    func testUsageLimitLines() {
        let sameDay = pausedAt.addingTimeInterval(-3600)
        let dayBefore = pausedAt.addingTimeInterval(-86_400)

        XCTAssertEqual(StatusMenu.usageLimitLine(claudeLimit, now: sameDay, timeZone: utc), "Paused: Claude limit, resumes ~12:18")
        XCTAssertEqual(
            StatusMenu.usageLimitLine(claudeLimit, now: dayBefore, timeZone: utc),
            "Paused: Claude limit, resumes ~Oct 2 12:18"
        )
        XCTAssertEqual(
            StatusMenu.usageLimitLine(claudeLimit, now: sameDay, timeZone: TimeZone(identifier: "America/Sao_Paulo")!),
            "Paused: Claude limit, resumes ~09:18"
        )
        XCTAssertEqual(StatusMenu.usageLimitLine(.init(resumeAt: nil), now: sameDay, timeZone: utc), "Paused: Claude limit")

        var canary = claudeLimit
        canary.phase = .canary
        XCTAssertEqual(StatusMenu.usageLimitLine(canary, now: sameDay, timeZone: utc), "Resuming: checking Claude limit…")

        let headroom = StateSnapshot.UsageLimit(window: "five_hour", phase: .headroom, resetsAt: pausedAt, utilization: 0.906)
        XCTAssertEqual(
            StatusMenu.usageLimitLine(headroom, now: sameDay, timeZone: utc),
            "Holding new runs: Claude at 91%, resets ~12:16"
        )
        XCTAssertEqual(
            StatusMenu.usageLimitLine(.init(provider: "openai", phase: .headroom), now: sameDay, timeZone: utc),
            "Holding new runs: Codex"
        )
    }

    func testAPIUnreachableLines() {
        let sameDay = pausedAt.addingTimeInterval(-3600)
        var outage = StateSnapshot.UsageLimit(
            phase: .paused, resumeAt: pausedAt.addingTimeInterval(120), reason: "model_api_unreachable", error: "ENOTFOUND"
        )

        XCTAssertEqual(
            StatusMenu.usageLimitLine(outage, now: sameDay, timeZone: utc),
            "Paused: Claude API unreachable (ENOTFOUND), retries ~12:18"
        )
        outage.error = nil
        outage.resumeAt = nil
        XCTAssertEqual(StatusMenu.usageLimitLine(outage, now: sameDay, timeZone: utc), "Paused: Claude API unreachable")

        outage.phase = .canary
        XCTAssertEqual(StatusMenu.usageLimitLine(outage, now: sameDay, timeZone: utc), "Resuming: checking Claude API…")

        var usageLimit = claudeLimit
        usageLimit.reason = "claude_usage_limit"
        XCTAssertEqual(StatusMenu.usageLimitLine(usageLimit, now: sameDay, timeZone: utc), "Paused: Claude limit, resumes ~12:18")
        usageLimit.phase = .canary
        XCTAssertEqual(StatusMenu.usageLimitLine(usageLimit, now: sameDay, timeZone: utc), "Resuming: checking Claude limit…")
    }

    func testLimitNames() {
        let names = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "monthly", nil].map {
            StatusMenu.limitName(.init(window: $0))
        }
        XCTAssertEqual(names, [
            "Claude 5-hour limit", "Claude weekly limit", "Claude weekly Opus limit", "Claude weekly Sonnet limit",
            "Claude monthly limit", "Claude usage limit",
        ])
        XCTAssertEqual(StatusMenu.limitName(.init(provider: "openrouter", window: "five_hour")), "OpenRouter 5-hour limit")
        XCTAssertEqual(StatusMenu.limitName(.init(provider: "acme")), "acme usage limit")
    }

    func testAUsageLimitHoldShowsAsPausedWithPauseStillOffered() {
        var held = snapshot
        held.usageLimits = [claudeLimit]
        let status = SymphonyStatus.running(held, external: false)

        XCTAssertEqual(StatusMenu.iconSymbolName(for: status), "pause.circle")
        XCTAssertEqual(StatusMenu.statusTitle(status), "Symphony is paused")
        XCTAssertEqual(StatusMenu.iconLabel(for: .running(held, external: true)), "Symphony: paused (external)")
        XCTAssertEqual(
            StatusMenu.detailLines(status, now: pausedAt, timeZone: utc),
            ["2 running · 1 retrying", "Paused: Claude limit, resumes ~12:18"]
        )
        // Pause and Resume only control the operator pause.
        XCTAssertTrue(StatusMenu.canPause(status))
        XCTAssertFalse(StatusMenu.canResume(status))
    }

    func testTheOperatorPauseShowsBeforeTheUsageLimitHold() {
        var both = snapshot
        both.pause = .init(reason: "deploy freeze", since: pausedAt)
        both.usageLimits = [claudeLimit]
        let status = SymphonyStatus.paused(both, external: false)

        XCTAssertEqual(
            StatusMenu.detailLines(status, now: pausedAt, timeZone: utc),
            ["2 running · 1 retrying", "Paused since 12:16: deploy freeze", "Paused: Claude limit, resumes ~12:18"]
        )
        XCTAssertFalse(StatusMenu.canPause(status))
        XCTAssertTrue(StatusMenu.canResume(status))
    }

    func testOpenItemTitles() {
        XCTAssertEqual(StatusMenu.openSymphonyTitle, "Open Symphony")
        XCTAssertEqual(StatusMenu.openSymphonyKeyEquivalent, "o")
        XCTAssertEqual(StatusMenu.developerTitle, "Developer")
        XCTAssertEqual(StatusMenu.openTerminalDashboardTitle, "Open Dashboard in Terminal")
        XCTAssertEqual(StatusMenu.openLogsTitle, "Open Logs")
        XCTAssertEqual(StatusMenu.openWebDashboardTitle, "Open Web Dashboard")
        XCTAssertFalse(StatusMenu.accessibilityLabel.isEmpty)
    }

    func testSettingsItemUsesCommandComma() {
        XCTAssertEqual(StatusMenu.settingsKeyEquivalent, ",")
        XCTAssertEqual(StatusMenu.settingsTitle, "Settings…")
    }

    func testStartAndStopTitles() {
        XCTAssertEqual(StatusMenu.startTitle, "Start Symphony")
        XCTAssertEqual(StatusMenu.stopTitle, "Stop Symphony")
        XCTAssertEqual(StatusMenu.stoppingTitle, "Stopping Symphony…")
    }

    func testQuitIsConfirmedOnlyWhenRunsAreActiveOrUnknown() {
        XCTAssertNil(StatusMenu.quitConfirmation(activeRuns: 0))
        XCTAssertEqual(
            StatusMenu.quitConfirmation(activeRuns: 1),
            "1 agent run is active. Quitting stops Symphony and ends it."
        )
        XCTAssertEqual(
            StatusMenu.quitConfirmation(activeRuns: 3),
            "3 agent runs are active. Quitting stops Symphony and ends them."
        )
        XCTAssertTrue(StatusMenu.quitConfirmation(activeRuns: nil)?.contains("couldn't be checked") == true)
    }

    func testUnexpectedExitMessageNamesTheLog() {
        XCTAssertEqual(
            StatusMenu.unexpectedExitMessage(.exited(1), logPath: "~/Library/Logs/symphony/menubar-child.log"),
            "Symphony exited with status 1. See ~/Library/Logs/symphony/menubar-child.log."
        )
    }
}
