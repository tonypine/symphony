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

    /// GitHub's rate limit, lifted at `retryAt`.
    private func rateLimited(until retryAt: Date) -> UpdateCheckResult {
        .failed("Couldn't check for updates: GitHub's rate limit is reached; try again later", retryAt: retryAt)
    }

    private let unreachable = UpdateCheckResult.failed("Couldn't check for updates: couldn't reach GitHub")

    // MARK: - Interval

    func testOnReleaseChecksEveryConfiguredMinutesAndTheOtherModesEverySixHours() {
        XCTAssertEqual(UpdateChecker.interval(for: .onRelease, releaseCheckMinutes: 5), 5 * 60)
        XCTAssertEqual(UpdateChecker.interval(for: .onRelease, releaseCheckMinutes: 17), 17 * 60)
        for mode in [UpdateMode.manual, .whenIdle, .atTime] {
            XCTAssertEqual(UpdateChecker.interval(for: mode, releaseCheckMinutes: 5), sixHours, mode.rawValue)
            XCTAssertEqual(UpdateChecker.interval(for: mode, releaseCheckMinutes: 2), sixHours, mode.rawValue)
        }
    }

    func testTheIntervalKeepsTheMinutesInRange() {
        XCTAssertEqual(UpdateChecker.interval(for: .onRelease, releaseCheckMinutes: 0), 2 * 60)
        XCTAssertEqual(UpdateChecker.interval(for: .onRelease, releaseCheckMinutes: 1), 2 * 60)
        XCTAssertEqual(UpdateChecker.interval(for: .onRelease, releaseCheckMinutes: 120), 60 * 60)
        XCTAssertEqual(UpdateCheckSchedule(mode: .onRelease, releaseCheckMinutes: 0).releaseCheckMinutes, 2)
        XCTAssertEqual(UpdateCheckSchedule(mode: .onRelease, releaseCheckMinutes: 1).releaseCheckMinutes, 2)
    }

    func testTheShortestIntervalUsesAtMostHalfOfGitHubsHourlyLimit() {
        // Every check counts against GitHub's unauthenticated limit, a 304 included, and other tools on the Mac share
        // it: the shortest interval leaves half of it to them.
        let minutes = AppSettings.releaseCheckMinutesRange.lowerBound
        let shortest = UpdateCheckSchedule(mode: .onRelease, releaseCheckMinutes: minutes)
        let checksAnHour = Int(UpdateChecker.rateLimitWindow / shortest.interval)

        XCTAssertEqual(UpdateChecker.hourlyRateLimit, 60)
        XCTAssertLessThanOrEqual(checksAnHour, 30)
        XCTAssertLessThanOrEqual(checksAnHour, UpdateChecker.hourlyRateLimit / 2)
        XCTAssertEqual(
            UpdateCheckSchedule(mode: .onRelease, releaseCheckMinutes: Int.min).interval,
            shortest.interval,
            "nothing below the range"
        )
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

    // MARK: - After a failed check

    func testARateLimitedCheckWaitsUntilGitHubLiftsTheLimit() {
        var schedule = UpdateCheckSchedule(mode: .onRelease, releaseCheckMinutes: 5)

        schedule.began()
        schedule.finished(rateLimited(until: at(14, 47)), at: at(14, 5))
        XCTAssertEqual(schedule.interval, 42 * 60, "at the reset, not 6 hours later")

        schedule.began()
        schedule.finished(rateLimited(until: at(15, 47)), at: at(14, 47))
        XCTAssertEqual(schedule.interval, 60 * 60, "still limited: the next reset")

        schedule.began()
        schedule.finished(.upToDate(release()), at: at(15, 47))
        XCTAssertEqual(schedule.interval, 5 * 60, "back to the configured interval")
    }

    func testARateLimitLiftedBeforeTheNextCheckKeepsTheUsualInterval() {
        var schedule = UpdateCheckSchedule(mode: .onRelease, releaseCheckMinutes: 5)
        schedule.finished(rateLimited(until: at(14, 6)), at: at(14, 5))
        XCTAssertEqual(schedule.interval, 5 * 60, "never sooner than the configured interval")

        schedule.finished(rateLimited(until: at(14, 0)), at: at(14, 5))
        XCTAssertEqual(schedule.interval, 5 * 60, "a reset already past")

        var manual = UpdateCheckSchedule(mode: .manual, releaseCheckMinutes: 5)
        manual.finished(rateLimited(until: at(14, 47)), at: at(14, 5))
        XCTAssertEqual(manual.interval, sixHours, "the other modes keep checking every 6 hours")
    }

    func testAnUnreachableGitHubRetriesAtTheUsualInterval() {
        var schedule = UpdateCheckSchedule(mode: .onRelease, releaseCheckMinutes: 5)

        schedule.began()
        schedule.finished(unreachable, at: at(14, 5))
        XCTAssertEqual(schedule.interval, 5 * 60, "not 6 hours")

        schedule.finished(.failed("Couldn't check for updates: GitHub answered with HTTP 500"), at: at(14, 10))
        XCTAssertEqual(schedule.interval, 5 * 60, "any failure other than the rate limit")

        var manual = UpdateCheckSchedule(mode: .manual, releaseCheckMinutes: 5)
        manual.finished(unreachable, at: at(14, 5))
        XCTAssertEqual(manual.interval, sixHours)
    }

    func testTheRateLimitWinsOverTheOverride() {
        var schedule = UpdateCheckSchedule(mode: .onRelease, releaseCheckMinutes: 5, override: 30)

        schedule.finished(rateLimited(until: at(14, 47)), at: at(14, 5))
        XCTAssertEqual(schedule.interval, 42 * 60)

        schedule.finished(unreachable, at: at(14, 6))
        XCTAssertEqual(schedule.interval, 30)

        schedule.finished(.available(release(build: 43)), at: at(14, 7))
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

        XCTAssertTrue(schedule.configure(mode: .onRelease, releaseCheckMinutes: 1))
        XCTAssertEqual(schedule.releaseCheckMinutes, 2)
        XCTAssertFalse(schedule.configure(mode: .onRelease, releaseCheckMinutes: 2), "1 was 2 already")

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
        schedule.finished(rateLimited(until: at(14, 47, 12)), at: at(14, 5))

        XCTAssertEqual(
            schedule.settingsLine(now: at(14, 6), calendar: utc),
            "▲ Couldn't check at 14:05: GitHub's rate limit is reached; try again later. Next check at 14:47."
        )

        schedule.finished(unreachable, at: at(14, 50))
        XCTAssertEqual(
            schedule.settingsLine(now: at(14, 51), calendar: utc),
            "▲ Couldn't check at 14:50: couldn't reach GitHub. Next check at 14:55."
        )
    }

    func testTheRateLimitNoteDoesNotCallUnchangedChecksFree() {
        XCTAssertEqual(
            UpdateCheckSchedule.rateLimitNote,
            "Every check counts against GitHub's limit of 60 requests an hour from this Mac, which other apps share. "
                + "After a check hits the limit, the app waits for GitHub to reset it, at most an hour."
        )
    }

    func testTheClampedNote() {
        XCTAssertEqual(
            UpdateCheckSchedule.clampedLine(typed: 0, to: 2),
            "Between 2 and 60 minutes. 0 was changed to 2."
        )
        XCTAssertEqual(
            UpdateCheckSchedule.clampedLine(typed: 120, to: 60),
            "Between 2 and 60 minutes. 120 was changed to 60."
        )
    }

    func testACommittedValueOutOfRangeIsMovedWithTheNote() {
        let low = UpdateCheckSchedule.committed(0, current: 5, note: nil)
        XCTAssertEqual(low.minutes, 2)
        XCTAssertEqual(low.note, "Between 2 and 60 minutes. 0 was changed to 2.")
        let high = UpdateCheckSchedule.committed(120, current: 5, note: nil)
        XCTAssertEqual(high.minutes, 60)
        XCTAssertEqual(high.note, "Between 2 and 60 minutes. 120 was changed to 60.")
    }

    func testTheFieldWritingBackTheMovedValueKeepsTheNote() {
        let note = UpdateCheckSchedule.clampedLine(typed: 1, to: 2)
        let written = UpdateCheckSchedule.committed(2, current: 2, note: note)
        XCTAssertEqual(written.minutes, 2)
        XCTAssertEqual(written.note, note)
    }

    func testANewValueInRangeClearsTheNote() {
        let note = UpdateCheckSchedule.clampedLine(typed: 1, to: 2)
        let typed = UpdateCheckSchedule.committed(10, current: 2, note: note)
        XCTAssertEqual(typed.minutes, 10)
        XCTAssertNil(typed.note)
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

        schedule.finished(rateLimited(until: at(14, 47)), at: at(14, 3))
        XCTAssertNil(schedule.menuLine(now: at(14, 5)))

        schedule.finished(.available(release(build: 43)), at: at(14, 4))
        XCTAssertNil(schedule.menuLine(now: at(14, 5)))
    }
}
