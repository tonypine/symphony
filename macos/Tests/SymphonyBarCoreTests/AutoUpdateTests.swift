import XCTest
@testable import SymphonyBarCore

final class AutoUpdateTests: XCTestCase {
    private typealias Context = AutoUpdater.Context

    private let restartTimeout: TimeInterval = 30 * 60
    private let blocker = "Updates are off in Development mode"

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 5 October 2026 at `hour`:`minute` UTC, or the next days with `day`.
    private func at(_ hour: Int, _ minute: Int, second: Int = 0, day: Int = 5) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
    }

    private func release(build: Int = 42) -> Release {
        Self.release(build: build)
    }

    private static func release(build: Int = 42) -> Release {
        Release(
            version: "0.0.1.\(build)",
            build: build,
            notes: "",
            pageURL: URL(string: "https://github.com/tonypine/symphony/releases/tag/v0.0.1.\(build)")!,
            changes: nil
        )
    }

    private func context(
        _ mode: UpdateMode,
        offer: UpdateOffer? = .available(AutoUpdateTests.release()),
        blocker: String? = nil,
        activity: SymphonyActivity = .running(activeRuns: 0),
        time: TimeOfDay = .defaultUpdateTime
    ) -> Context {
        Context(mode: mode, time: time, offer: offer, blocker: blocker, activity: activity, runsTimeout: restartTimeout)
    }

    private func snapshot(running: Int, paused: Bool) -> StateSnapshot {
        StateSnapshot(running: running, pause: paused ? .init(reason: ControlAction.pauseReason) : nil)
    }

    /// An updater in Automatically at a set time whose next attempt is 03:00 on 5 October.
    private func scheduledAtThree() -> AutoUpdater {
        var updater = AutoUpdater()
        XCTAssertNil(updater.tick(context(.atTime), now: at(1, 0), calendar: utc))
        XCTAssertEqual(updater.nextSetTime, at(3, 0))
        return updater
    }

    // MARK: Activity

    func testIdleMeansNoActiveAgentRuns() {
        XCTAssertTrue(SymphonyActivity.running(activeRuns: 0).isIdle)
        XCTAssertFalse(SymphonyActivity.running(activeRuns: 1).isIdle)
        XCTAssertTrue(SymphonyActivity.notRunning.isIdle, "with Symphony stopped the app counts as idle")
        XCTAssertFalse(SymphonyActivity.busy.isIdle)
    }

    func testPausedWithRunsActiveIsNotIdle() {
        let paused = SymphonyActivity(
            status: .paused(snapshot(running: 2, paused: true), external: false),
            symphonyRunning: true,
            busy: false
        )
        XCTAssertEqual(paused, .running(activeRuns: 2))
        XCTAssertFalse(paused.isIdle)

        let pausedAndIdle = SymphonyActivity(
            status: .paused(snapshot(running: 0, paused: true), external: false),
            symphonyRunning: true,
            busy: false
        )
        XCTAssertTrue(pausedAndIdle.isIdle)
    }

    func testActivityFromTheStatus() {
        XCTAssertEqual(
            SymphonyActivity(
                status: .running(snapshot(running: 3, paused: false), external: true),
                symphonyRunning: false,
                busy: false
            ),
            .running(activeRuns: 3),
            "a Symphony started from the CLI counts with its runs"
        )
        XCTAssertEqual(SymphonyActivity(status: .stopped, symphonyRunning: false, busy: false), .notRunning)
        XCTAssertEqual(SymphonyActivity(status: .starting, symphonyRunning: true, busy: false), .busy)
        XCTAssertEqual(
            SymphonyActivity(status: .error("Symphony isn't answering"), symphonyRunning: true, busy: false),
            .busy,
            "runs are unknown while the app's Symphony doesn't answer"
        )
        XCTAssertEqual(
            SymphonyActivity(status: .error("Symphony exited with status 1"), symphonyRunning: false, busy: false),
            .notRunning
        )
        XCTAssertEqual(
            SymphonyActivity(
                status: .running(snapshot(running: 0, paused: false), external: false),
                symphonyRunning: true,
                busy: true
            ),
            .busy,
            "a restart, an update, a start or a stop under way"
        )
    }

    // MARK: Automatically when idle

    func testIdleModeInstallsOnACheckWhenIdle() {
        var updater = AutoUpdater()

        let action = updater.checked(.available(release()), context(.whenIdle))

        XCTAssertEqual(action, .install(release(), runsTimeout: 0), "gives up at once if a run starts during the drain")
    }

    func testIdleModeWaitsForRunsAndInstallsAtTheFirstIdlePoll() {
        var updater = AutoUpdater()
        let busy = context(.whenIdle, activity: .running(activeRuns: 1))
        XCTAssertNil(updater.checked(.available(release()), busy), "nothing is paused or interrupted")
        XCTAssertNil(updater.tick(busy, now: at(10, 0), calendar: utc))
        XCTAssertNil(updater.tick(context(.whenIdle, activity: .busy), now: at(10, 1), calendar: utc))

        let action = updater.tick(context(.whenIdle), now: at(10, 2), calendar: utc)

        XCTAssertEqual(action, .install(release(), runsTimeout: 0))
        XCTAssertNil(updater.nextSetTime, "no set time outside Automatically at a set time")
    }

    func testIdleModeDoesNotInstallWhilePausedWithRunsActive() {
        var updater = AutoUpdater()
        let paused = SymphonyActivity(
            status: .paused(snapshot(running: 1, paused: true), external: false),
            symphonyRunning: true,
            busy: false
        )

        XCTAssertNil(updater.checked(.available(release()), context(.whenIdle, activity: paused)))
        XCTAssertNil(updater.tick(context(.whenIdle, activity: paused), now: at(10, 0), calendar: utc))
    }

    func testIdleModeInstallsWithSymphonyStopped() {
        var updater = AutoUpdater()

        let action = updater.tick(context(.whenIdle, activity: .notRunning), now: at(10, 0), calendar: utc)

        XCTAssertEqual(action, .install(release(), runsTimeout: 0))
    }

    func testAFailedInstallIsRetriedAtTheNextCheck() {
        var updater = AutoUpdater()
        XCTAssertEqual(updater.tick(context(.whenIdle), now: at(10, 0), calendar: utc), .install(release(), runsTimeout: 0))

        // The install failed (download, verification, symphony.yml): later polls don't try again.
        XCTAssertNil(updater.tick(context(.whenIdle), now: at(10, 1), calendar: utc))
        XCTAssertNil(updater.checked(.failed("Couldn't check for updates: couldn't reach GitHub"), context(.whenIdle)))
        XCTAssertNil(updater.tick(context(.whenIdle), now: at(10, 2), calendar: utc), "a failed check doesn't count")

        XCTAssertEqual(updater.checked(.available(release()), context(.whenIdle)), .install(release(), runsTimeout: 0))
    }

    func testAPostponedInstallIsRetriedAtTheNextIdleMoment() {
        var updater = AutoUpdater()
        XCTAssertEqual(updater.tick(context(.whenIdle), now: at(10, 0), calendar: utc), .install(release(), runsTimeout: 0))

        // A run started before dispatch paused: the drain gave up and resumed dispatch.
        updater.postponed()
        XCTAssertNil(updater.tick(context(.whenIdle, activity: .running(activeRuns: 1)), now: at(10, 1), calendar: utc))

        XCTAssertEqual(updater.tick(context(.whenIdle), now: at(10, 20), calendar: utc), .install(release(), runsTimeout: 0))
    }

    func testIdleModeNeverInstallsASkippedRelease() {
        var updater = AutoUpdater()
        let skipped = context(.whenIdle, offer: .skipped(release(), .skipped))

        XCTAssertNil(updater.checked(.available(release()), skipped))
        XCTAssertNil(updater.tick(skipped, now: at(10, 0), calendar: utc))
        let rolledBack = context(.whenIdle, offer: .skipped(release(), .rolledBack))
        XCTAssertNil(updater.tick(rolledBack, now: at(10, 1), calendar: utc))
    }

    func testANewerReleaseThanTheSkippedOneInstalls() {
        var updater = AutoUpdater()
        let newer = release(build: 43)

        let action = updater.checked(.available(newer), context(.whenIdle, offer: .available(newer)))

        XCTAssertEqual(action, .install(newer, runsTimeout: 0))
    }

    func testNothingInstallsWhileUpdatesAreBlocked() {
        for reason in [
            "Updates need a release build of Symphony.app",
            blocker,
            "This build has no update signing key",
            "Move Symphony.app to a folder you can write to, such as ~/Applications",
        ] {
            var updater = AutoUpdater()
            XCTAssertNil(updater.checked(.available(release()), context(.whenIdle, blocker: reason)), reason)
            XCTAssertNil(updater.tick(context(.whenIdle, blocker: reason), now: at(10, 0), calendar: utc), reason)

            var atTime = scheduledAtThree()
            XCTAssertNil(atTime.tick(context(.atTime, blocker: reason), now: at(3, 0), calendar: utc), reason)
            XCTAssertNil(atTime.checked(.available(release()), context(.atTime, blocker: reason)), reason)
        }
    }

    func testNoReleaseNoInstall() {
        var updater = AutoUpdater()

        XCTAssertNil(updater.checked(.upToDate(release(build: 41)), context(.whenIdle, offer: nil)))
        XCTAssertNil(updater.tick(context(.whenIdle, offer: nil), now: at(10, 0), calendar: utc))
    }

    // MARK: Manual

    func testManualNeverInstallsByItself() {
        var updater = AutoUpdater()

        XCTAssertNil(updater.checked(.available(release()), context(.manual)))
        XCTAssertNil(updater.tick(context(.manual), now: at(3, 0), calendar: utc))
        XCTAssertNil(updater.tick(context(.manual, activity: .notRunning), now: at(3, 0, day: 6), calendar: utc))
        XCTAssertNil(updater.nextSetTime)
    }

    // MARK: Automatically at a set time

    func testSetTimeChecksAtTheTimeThenInstallsWaitingForRuns() {
        var updater = scheduledAtThree()
        XCTAssertNil(updater.tick(context(.atTime), now: at(2, 59, second: 59), calendar: utc))

        XCTAssertEqual(updater.tick(context(.atTime), now: at(3, 0), calendar: utc), .check)
        XCTAssertEqual(updater.nextSetTime, at(3, 0, day: 6), "the next attempt is the next day's time")

        let running = context(.atTime, activity: .running(activeRuns: 2))
        let action = updater.checked(.available(release()), running)
        XCTAssertEqual(action, .install(release(), runsTimeout: restartTimeout), "pauses dispatch and waits for the runs")
    }

    func testSetTimeInstallsWithNoRunsActive() {
        var updater = scheduledAtThree()
        XCTAssertEqual(updater.tick(context(.atTime), now: at(3, 0, second: 4), calendar: utc), .check)

        XCTAssertEqual(updater.checked(.available(release()), context(.atTime)), .install(release(), runsTimeout: restartTimeout))
    }

    func testSetTimeInstallsOnlyAfterItsOwnCheck() {
        var updater = scheduledAtThree()

        XCTAssertNil(updater.checked(.available(release()), context(.atTime)), "a background check at 01:00 waits for 03:00")

        XCTAssertEqual(updater.tick(context(.atTime), now: at(3, 0), calendar: utc), .check)
        XCTAssertNotNil(updater.checked(.available(release()), context(.atTime)))
        XCTAssertNil(updater.checked(.available(release()), context(.atTime)), "a later check installs nothing")
    }

    func testSetTimeWithNothingNewOrAFailedCheckWaitsForTheNextDay() {
        var updater = scheduledAtThree()
        XCTAssertEqual(updater.tick(context(.atTime, offer: nil), now: at(3, 0), calendar: utc), .check)
        XCTAssertNil(updater.checked(.upToDate(release(build: 41)), context(.atTime, offer: nil)))

        XCTAssertEqual(updater.tick(context(.atTime), now: at(3, 0, day: 6), calendar: utc), .check)
        XCTAssertNil(updater.checked(.failed("Couldn't check for updates: couldn't reach GitHub"), context(.atTime)))
        XCTAssertNil(updater.checked(.available(release()), context(.atTime)), "the next check isn't the set time's")
        XCTAssertEqual(updater.nextSetTime, at(3, 0, day: 7))
    }

    func testSetTimeNeverInstallsASkippedRelease() {
        var updater = scheduledAtThree()
        XCTAssertEqual(updater.tick(context(.atTime), now: at(3, 0), calendar: utc), .check)

        XCTAssertNil(updater.checked(.available(release()), context(.atTime, offer: .skipped(release(), .skipped))))
    }

    func testSetTimeSkipsADayWhenSymphonyIsBusy() {
        var updater = scheduledAtThree()
        XCTAssertEqual(updater.tick(context(.atTime), now: at(3, 0), calendar: utc), .check)

        XCTAssertNil(updater.checked(.available(release()), context(.atTime, activity: .busy)))
        XCTAssertEqual(updater.nextSetTime, at(3, 0, day: 6))
    }

    func testAMissedSetTimeWaitsForTheNextDay() {
        // The Mac slept through 03:00 and woke at 08:00: no attempt in the middle of the day.
        var updater = scheduledAtThree()
        XCTAssertNil(updater.tick(context(.atTime), now: at(8, 0), calendar: utc))
        XCTAssertEqual(updater.nextSetTime, at(3, 0, day: 6))
        XCTAssertNil(updater.tick(context(.atTime), now: at(8, 1), calendar: utc))

        XCTAssertEqual(updater.tick(context(.atTime), now: at(3, 0, day: 6), calendar: utc), .check)
    }

    func testASetTimeAttemptMayStartALittleLate() {
        var updater = scheduledAtThree()
        XCTAssertEqual(updater.tick(context(.atTime), now: at(3, 9, second: 59), calendar: utc), .check)

        updater = scheduledAtThree()
        XCTAssertNil(updater.tick(context(.atTime), now: at(3, 10), calendar: utc), "10 minutes late is missed")
    }

    func testAnAppOpenedAfterTheTimeWaitsForTheNextDay() {
        var updater = AutoUpdater()

        XCTAssertNil(updater.tick(context(.atTime), now: at(3, 2), calendar: utc))

        XCTAssertEqual(updater.nextSetTime, at(3, 0, day: 6))
    }

    func testANewTimeInSettingsMovesTheNextAttempt() {
        var updater = scheduledAtThree()
        let later = TimeOfDay(hour: 4, minute: 30)

        XCTAssertNil(updater.tick(context(.atTime, time: later), now: at(3, 5), calendar: utc), "03:00 no longer counts")
        XCTAssertEqual(updater.nextSetTime, at(4, 30))
        XCTAssertEqual(updater.tick(context(.atTime, time: later), now: at(4, 30), calendar: utc), .check)
    }

    func testLeavingSetTimeModeClearsTheSchedule() {
        var updater = scheduledAtThree()

        XCTAssertNil(updater.tick(context(.manual), now: at(2, 0), calendar: utc))
        XCTAssertNil(updater.nextSetTime)

        // Back to the set time after it passed: tomorrow's.
        XCTAssertNil(updater.tick(context(.atTime), now: at(3, 1), calendar: utc))
        XCTAssertEqual(updater.nextSetTime, at(3, 0, day: 6))
    }

    func testSetTimeModeDoesNotInstallWhenIdle() {
        var updater = scheduledAtThree()

        XCTAssertNil(updater.checked(.available(release()), context(.atTime, activity: .notRunning)))
        XCTAssertNil(updater.tick(context(.atTime, activity: .notRunning), now: at(2, 0), calendar: utc))
    }

    func testNextDateFollowsTheTimeZoneAndTheDay() {
        let time = TimeOfDay(hour: 3, minute: 0)

        XCTAssertEqual(time.nextDate(after: at(2, 59), calendar: utc), at(3, 0))
        XCTAssertEqual(time.nextDate(after: at(3, 0), calendar: utc), at(3, 0, day: 6), "strictly after now")
        XCTAssertEqual(time.nextDate(after: at(23, 0), calendar: utc), at(3, 0, day: 6))

        var saoPaulo = Calendar(identifier: .gregorian)
        saoPaulo.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        XCTAssertEqual(time.nextDate(after: at(2, 0), calendar: saoPaulo), at(6, 0), "03:00 in UTC-3 is 06:00 UTC")
    }
}
