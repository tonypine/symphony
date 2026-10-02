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

    func testPauseLine() {
        let sameDay = pausedAt.addingTimeInterval(3600)
        let nextDay = pausedAt.addingTimeInterval(86_400)

        XCTAssertEqual(StatusMenu.pauseLine(.init(reason: " lunch ", since: pausedAt), now: sameDay, timeZone: utc), "Paused since 12:16: lunch")
        XCTAssertEqual(StatusMenu.pauseLine(.init(reason: nil, since: pausedAt), now: nextDay, timeZone: utc), "Paused since Oct 2, 12:16")
        XCTAssertEqual(StatusMenu.pauseLine(.init(reason: "lunch", since: nil), now: sameDay, timeZone: utc), "Paused: lunch")
        XCTAssertEqual(StatusMenu.pauseLine(.init(reason: "  ", since: nil), now: sameDay, timeZone: utc), "Paused")
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
