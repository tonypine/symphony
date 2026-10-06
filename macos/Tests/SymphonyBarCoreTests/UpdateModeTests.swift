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
            ["Manual", "Automatically when idle", "Automatically at a set time"]
        )
        XCTAssertEqual(UpdateMode.allCases.map(\.rawValue), ["manual", "whenIdle", "atTime"])
        XCTAssertEqual(UpdateMode.atTime.id, "atTime")
    }

    func testEachModeSaysWhatItDoes() {
        XCTAssertTrue(UpdateMode.manual.explanation.contains("Update to vX"))
        XCTAssertTrue(UpdateMode.whenIdle.explanation.contains("as soon as no agent runs are active"))
        XCTAssertTrue(UpdateMode.atTime.explanation.contains("tries again the next day"))
        for mode in UpdateMode.allCases {
            XCTAssertFalse(mode.explanation.contains("Not active yet"), mode.rawValue)
        }
        for mode in [UpdateMode.whenIdle, .atTime] {
            XCTAssertTrue(mode.explanation.hasSuffix("A release you skip is never installed by itself."), mode.rawValue)
        }
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
