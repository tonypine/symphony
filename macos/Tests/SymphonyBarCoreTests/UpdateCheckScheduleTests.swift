import XCTest
@testable import SymphonyBarCore

final class UpdateCheckScheduleTests: XCTestCase {
    private let sixHours: TimeInterval = 6 * 60 * 60

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: hour, minute: minute, second: second))!
    }

    private func release(build: Int = 42) -> Release {
        Release(
            version: "0.0.1.\(build)",
            build: build,
            notes: "",
            pageURL: URL(string: "https://github.com/tonypine/symphony/releases/tag/v0.0.1.\(build)")!,
            changes: nil
        )
    }

    private let rateLimited = UpdateCheckResult.failed(
        "Couldn't check for updates: GitHub's rate limit is reached; try again later"
    )

    // MARK: - Interval

    func testOnReleaseChecksEveryConfiguredMinutesAndTheOtherModesEverySixHours() {
        XCTAssertEqual(UpdateChecker.interval(for: .onRelease, releaseCheckMinutes: 5), 5 * 60)
        XCTAssertEqual(UpdateChecker.interval(for: .onRelease, releaseCheckMinutes: 17), 17 * 60)
        for mode in [UpdateMode.manual, .whenIdle, .atTime] {
            XCTAssertEqual(UpdateChecker.interval(for: mode, releaseCheckMinutes: 5), sixHours, mode.rawValue)
            XCTAssertEqual(UpdateChecker.interval(for: mode, releaseCheckMinutes: 1), sixHours, mode.rawValue)
        }
    }

    func testTheIntervalKeepsTheMinutesInRange() {
        XCTAssertEqual(UpdateChecker.interval(for: .onRelease, releaseCheckMinutes: 0), 60)
        XCTAssertEqual(UpdateChecker.interval(for: .onRelease, releaseCheckMinutes: 120), 60 * 60)
        XCTAssertEqual(UpdateCheckSchedule(mode: .onRelease, releaseCheckMinutes: 0).releaseCheckMinutes, 1)
    }

    func testTheScheduleFollowsTheModeAndTheMinutes() {
        XCTAssertEqual(UpdateCheckSchedule(mode: .onRelease, releaseCheckMinutes: 5).interval, 5 * 60)
        XCTAssertEqual(UpdateCheckSchedule(mode: .onRelease, releaseCheckMinutes: 10).interval, 10 * 60)
        XCTAssertEqual(UpdateCheckSchedule(mode: .manual, releaseCheckMinutes: 10).interval, sixHours)
    }

    func testTheOverrideWinsInEveryMode() {
        for mode in UpdateMode.allCases {
            let schedule = UpdateCheckSchedule(mode: mode, releaseCheckMinutes: 5, override: 30)
            XCTAssertEqual(schedule.interval, 30, mode.rawValue)
        }
    }

    // MARK: - Back-off

    func testAFailedCheckBacksOffToSixHoursUntilACheckSucceeds() {
        var schedule = UpdateCheckSchedule(mode: .onRelease, releaseCheckMinutes: 5)

        schedule.began()
        schedule.finished(rateLimited, at: at(14, 5))
        XCTAssertTrue(schedule.backingOff)
        XCTAssertEqual(schedule.interval, sixHours)

        schedule.began()
        schedule.finished(rateLimited, at: at(20, 5))
        XCTAssertEqual(schedule.interval, sixHours, "still failing")

        schedule.began()
        schedule.finished(.upToDate(release()), at: at(20, 6))
        XCTAssertFalse(schedule.backingOff)
        XCTAssertEqual(schedule.interval, 5 * 60, "back to the configured interval")
    }

    func testTheBackOffWinsOverTheOverride() {
        var schedule = UpdateCheckSchedule(mode: .onRelease, releaseCheckMinutes: 5, override: 30)

        schedule.finished(rateLimited, at: at(14, 5))
        XCTAssertEqual(schedule.interval, sixHours)

        schedule.finished(.available(release(build: 43)), at: at(14, 6))
        XCTAssertEqual(schedule.interval, 30)
    }

    // MARK: - Settings changes

    func testSwitchingToOnReleaseOrChangingItsMinutesChecksNow() {
        var schedule = UpdateCheckSchedule(mode: .manual, releaseCheckMinutes: 5)

        XCTAssertTrue(schedule.configure(mode: .onRelease, releaseCheckMinutes: 5))
        XCTAssertEqual(schedule.interval, 5 * 60)

        XCTAssertFalse(schedule.configure(mode: .onRelease, releaseCheckMinutes: 5), "nothing changed")

        XCTAssertTrue(schedule.configure(mode: .onRelease, releaseCheckMinutes: 10))
        XCTAssertEqual(schedule.interval, 10 * 60)

        XCTAssertTrue(schedule.configure(mode: .onRelease, releaseCheckMinutes: 99))
        XCTAssertEqual(schedule.releaseCheckMinutes, 60)
        XCTAssertFalse(schedule.configure(mode: .onRelease, releaseCheckMinutes: 60), "99 was 60 already")
    }

    func testSwitchingAwayFromOnReleaseGoesBackToSixHoursWithoutACheck() {
        var schedule = UpdateCheckSchedule(mode: .onRelease, releaseCheckMinutes: 5)

        XCTAssertFalse(schedule.configure(mode: .whenIdle, releaseCheckMinutes: 5))
        XCTAssertEqual(schedule.interval, sixHours)

        XCTAssertFalse(schedule.configure(mode: .manual, releaseCheckMinutes: 30), "the minutes only matter on release")
        XCTAssertEqual(schedule.interval, sixHours)
    }

    // MARK: - Settings' last-check line

    func testTheLastCheckLineBeforeTheFirstCheckAndWhileChecking() {
        var schedule = UpdateCheckSchedule(mode: .onRelease, releaseCheckMinutes: 5)
        XCTAssertEqual(schedule.settingsLine(now: at(14, 0), calendar: utc), "Not checked yet.")

        schedule.began()
        XCTAssertTrue(schedule.isChecking)
        XCTAssertEqual(schedule.settingsLine(now: at(14, 0), calendar: utc), "Checking for a new release…")

        schedule.finished(.upToDate(release()), at: at(14, 0))
        schedule.began()
        XCTAssertEqual(schedule.settingsLine(now: at(14, 5), calendar: utc), "Checking for a new release…")
    }

    func testTheLastCheckLineAfterACheckThatFoundNothingNew() {
        var schedule = UpdateCheckSchedule(mode: .onRelease, releaseCheckMinutes: 5)
        schedule.began()
        schedule.finished(.upToDate(release()), at: at(14, 3))

        XCTAssertFalse(schedule.isChecking)
        XCTAssertEqual(
            schedule.settingsLine(now: at(14, 5), calendar: utc),
            "● Checked 2 min ago: v0.0.1.42 is the newest release."
        )
        XCTAssertEqual(
            schedule.settingsLine(now: at(14, 3, 40), calendar: utc),
            "● Checked just now: v0.0.1.42 is the newest release."
        )
    }

    func testTheLastCheckLineAfterACheckThatFoundARelease() {
        var schedule = UpdateCheckSchedule(mode: .onRelease, releaseCheckMinutes: 5)
        schedule.finished(.available(release(build: 43)), at: at(14, 0))

        XCTAssertEqual(
            schedule.settingsLine(now: at(14, 12), calendar: utc),
            "● Checked 12 min ago: v0.0.1.43 is available."
        )
    }

    func testTheLastCheckLineAfterAFailedCheck() {
        var schedule = UpdateCheckSchedule(mode: .onRelease, releaseCheckMinutes: 5)
        schedule.finished(rateLimited, at: at(14, 5))

        XCTAssertEqual(
            schedule.settingsLine(now: at(14, 6), calendar: utc),
            "▲ Couldn't check at 14:05: GitHub's rate limit is reached; try again later. Next check in 6 hours."
        )
    }

    func testTheClampedNote() {
        XCTAssertEqual(
            UpdateCheckSchedule.clampedLine(typed: 0, to: 1),
            "Between 1 and 60 minutes. 0 was changed to 1."
        )
        XCTAssertEqual(
            UpdateCheckSchedule.clampedLine(typed: 120, to: 60),
            "Between 1 and 60 minutes. 120 was changed to 60."
        )
    }

    func testTheFailureReasonDropsThePrefix() {
        XCTAssertEqual(
            UpdateChecker.failureReason("Couldn't check for updates: couldn't reach GitHub"),
            "couldn't reach GitHub"
        )
        XCTAssertEqual(UpdateChecker.failureReason("something else"), "something else")
    }

    // MARK: - The menu's up-to-date line

    func testTheMenuSaysUpToDateOnlyOnReleaseAfterACheckThatFoundNothingNew() {
        var schedule = UpdateCheckSchedule(mode: .onRelease, releaseCheckMinutes: 5)
        XCTAssertNil(schedule.menuLine(now: at(14, 0)), "not checked yet")

        schedule.finished(.upToDate(release()), at: at(14, 3))
        XCTAssertEqual(schedule.menuLine(now: at(14, 5)), "Up to date: v0.0.1.42, checked 2 min ago")
        XCTAssertEqual(schedule.menuLine(now: at(14, 3, 10)), "Up to date: v0.0.1.42, checked just now")
        XCTAssertEqual(schedule.menuLine(now: at(16, 3)), "Up to date: v0.0.1.42, checked 2 h ago")

        _ = schedule.configure(mode: .manual, releaseCheckMinutes: 5)
        XCTAssertNil(schedule.menuLine(now: at(14, 5)), "other modes keep the menu as it was")
    }

    func testTheMenuSaysNothingAfterAFailedCheckOrARelease() {
        var schedule = UpdateCheckSchedule(mode: .onRelease, releaseCheckMinutes: 5)

        schedule.finished(rateLimited, at: at(14, 3))
        XCTAssertNil(schedule.menuLine(now: at(14, 5)))

        schedule.finished(.available(release(build: 43)), at: at(14, 4))
        XCTAssertNil(schedule.menuLine(now: at(14, 5)))
    }
}
