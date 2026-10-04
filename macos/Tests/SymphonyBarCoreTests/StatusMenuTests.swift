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
        XCTAssertEqual(StatusMenu.openDashboardTitle, "Open Dashboard")
        XCTAssertEqual(StatusMenu.openLogsTitle, "Open Logs")
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
