import XCTest
@testable import SymphonyBarCore

final class StatusMenuTests: XCTestCase {
    func testQuitItemUsesCommandQ() {
        XCTAssertEqual(StatusMenu.quitKeyEquivalent, "q")
        XCTAssertFalse(StatusMenu.quitTitle.isEmpty)
    }

    func testIconSymbolIsSet() {
        XCTAssertFalse(StatusMenu.iconSymbolName.isEmpty)
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
