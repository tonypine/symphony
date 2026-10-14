import XCTest
@testable import SymphonyBarCore

final class UpdateModeTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testModesInPickerOrder() {
        XCTAssertEqual(
            UpdateMode.allCases.map(\.title),
            ["Manual", "Automatically when idle", "Automatically at a set time", "Automatically when released"]
        )
        XCTAssertEqual(UpdateMode.allCases.map(\.rawValue), ["manual", "whenIdle", "atTime", "onRelease"])
        XCTAssertEqual(UpdateMode.atTime.id, "atTime")
    }

    func testEachModeSaysWhatItDoes() {
        XCTAssertTrue(UpdateMode.manual.explanation.contains("Update to vX"))
        XCTAssertTrue(UpdateMode.whenIdle.explanation.contains("as soon as no agent runs are active"))
        XCTAssertTrue(UpdateMode.atTime.explanation.contains("tries again the next day"))
        XCTAssertEqual(
            UpdateMode.onRelease.explanation,
            "When Symphony finds a new release it installs it straight away: it pauses dispatch, waits for agent runs "
                + "to finish, updates, and resumes dispatch. A release you skip is never installed by itself."
        )
        for mode in UpdateMode.allCases {
            XCTAssertFalse(mode.explanation.contains("Not active yet"), mode.rawValue)
        }
        for mode in [UpdateMode.whenIdle, .atTime, .onRelease] {
            XCTAssertTrue(mode.explanation.hasSuffix("A release you skip is never installed by itself."), mode.rawValue)
        }
    }

    func testTheDefaultModeIsOnRelease() {
        XCTAssertEqual(AppSettings.defaultUpdateMode, .onRelease)
        XCTAssertEqual(AppSettings().updateMode, .onRelease)
    }

    func testAnAutomaticModeSaysWhenThisCopyCantUpdateItself() {
        for mode in [UpdateMode.whenIdle, .atTime, .onRelease] {
            XCTAssertTrue(mode.isAutomatic, mode.rawValue)
            XCTAssertEqual(
                mode.blockerLine("Updates are off in Development mode"),
                "▲ This copy can't update itself: updates are off in Development mode.",
                mode.rawValue
            )
            XCTAssertNil(mode.blockerLine(nil), mode.rawValue)
        }
        XCTAssertEqual(
            UpdateMode.onRelease.blockerLine("Updates need a release build of Symphony.app"),
            "▲ This copy can't update itself: updates need a release build of Symphony.app."
        )
        XCTAssertFalse(UpdateMode.manual.isAutomatic)
        XCTAssertNil(UpdateMode.manual.blockerLine("This build has no update signing key"), "Manual says it on the menu")
    }

    func testDefaultUpdateTimeIsThreeInTheMorning() {
        XCTAssertEqual(TimeOfDay.defaultUpdateTime.hour, 3)
        XCTAssertEqual(TimeOfDay.defaultUpdateTime.minute, 0)
        XCTAssertEqual(TimeOfDay.defaultUpdateTime.minutesSinceMidnight, 180)
        XCTAssertEqual(TimeOfDay.defaultUpdateTime.label, "03:00")
    }

    func testMinutesSinceMidnightMustFallInTheDay() {
        XCTAssertEqual(TimeOfDay(minutesSinceMidnight: 0), TimeOfDay(hour: 0, minute: 0))
        XCTAssertEqual(TimeOfDay(minutesSinceMidnight: 1439)?.label, "23:59")
        XCTAssertNil(TimeOfDay(minutesSinceMidnight: -1))
        XCTAssertNil(TimeOfDay(minutesSinceMidnight: 1440))
    }

    func testHourAndMinuteWrapAroundTheDay() {
        XCTAssertEqual(TimeOfDay(hour: 25, minute: 5).label, "01:05")
        XCTAssertEqual(TimeOfDay(hour: 0, minute: -1).label, "23:59")
    }

    func testDateRoundTripForTheTimePicker() {
        let day = Date(timeIntervalSince1970: 1_791_000_000)
        let time = TimeOfDay(hour: 21, minute: 45)

        let date = time.date(on: day, calendar: utc)

        XCTAssertEqual(TimeOfDay(date: date, calendar: utc), time)
        XCTAssertEqual(utc.startOfDay(for: date), utc.startOfDay(for: day), "the picker's date stays on that day")
    }
}
