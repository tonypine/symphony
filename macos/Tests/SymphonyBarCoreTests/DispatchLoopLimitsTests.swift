import XCTest
@testable import SymphonyBarCore

final class DispatchLoopLimitsTests: XCTestCase {
    private let config = """
        # Symphony operator config.
        workspaces:
          root: ~/work

        watchdog:
          enabled: true
          dispatch_loop_runs: 3  # tighter than the default
          dispatch_loop_window_ms: 300000
          dispatch_loop_long_runs: 6
          dispatch_loop_long_window_ms: 7200000

        """

    private let configLimits = DispatchLoopLimits(runs: 3, windowMs: 300_000, longRuns: 6, longWindowMs: 7_200_000)

    // MARK: Reading

    func testReadsTheLimits() throws {
        XCTAssertEqual(try DispatchLoopLimits.values(in: config), configLimits)
    }

    func testMissingAndNullKeysReadAsSymphonysDefaults() throws {
        let defaults = DispatchLoopLimits(runs: 4, windowMs: 600_000, longRuns: 8, longWindowMs: 3_600_000)
        XCTAssertEqual(DispatchLoopLimits(), defaults)
        XCTAssertEqual(try DispatchLoopLimits.values(in: ""), defaults)
        XCTAssertEqual(try DispatchLoopLimits.values(in: "watchdog:\n  enabled: true\n"), defaults)
        XCTAssertEqual(
            try DispatchLoopLimits.values(in: "watchdog:\n  dispatch_loop_runs: null\n  dispatch_loop_window_ms: ~\n"),
            defaults
        )
    }

    func testReadsUnderscoredNumbers() throws {
        XCTAssertEqual(
            try DispatchLoopLimits.values(in: "watchdog:\n  dispatch_loop_long_window_ms: 1_800_000\n"),
            DispatchLoopLimits(longWindowMs: 1_800_000)
        )
    }

    func testRefusesValuesItCannotRead() {
        XCTAssertThrowsError(try DispatchLoopLimits.values(in: "watchdog:\n  dispatch_loop_runs: often\n")) { error in
            XCTAssertEqual(error as? DispatchLoopLimitsError, .unreadable(key: "watchdog.dispatch_loop_runs", value: "often"))
        }
        XCTAssertThrowsError(try DispatchLoopLimits.values(in: "watchdog: {dispatch_loop_runs: 5}\n")) { error in
            XCTAssertEqual(error as? DispatchLoopLimitsError, .notABlock("watchdog"))
        }
        XCTAssertEqual(
            DispatchLoopLimitsError.unreadable(key: "watchdog.dispatch_loop_runs", value: "often").errorDescription,
            "`watchdog.dispatch_loop_runs: often` in symphony.yml is not a whole number. Change it by hand."
        )
        XCTAssertEqual(
            DispatchLoopLimitsError.notABlock("watchdog").errorDescription,
            "`watchdog:` in symphony.yml is not an indented block. Change the dispatch-loop limits by hand."
        )
    }

    // MARK: Writing

    func testRewritesOnlyTheChangedLinesKeepingTheirComments() throws {
        var new = configLimits
        new.runs = 5
        new.longWindowMs = 3_600_000
        let updated = try DispatchLoopLimits.updating(config, from: configLimits, to: new)
        XCTAssertEqual(changedLines(config, updated), [
            "  dispatch_loop_runs: 5  # tighter than the default",
            "  dispatch_loop_long_window_ms: 3600000",
        ])
        XCTAssertEqual(try DispatchLoopLimits.updating(config, from: configLimits, to: configLimits), config)
    }

    func testInsertsMissingKeysAndTheSection() throws {
        XCTAssertEqual(
            try DispatchLoopLimits.updating("issues:\n  provider: linear\n", from: DispatchLoopLimits(), to: DispatchLoopLimits(runs: 2, windowMs: 120_000)),
            "issues:\n  provider: linear\nwatchdog:\n  dispatch_loop_runs: 2\n  dispatch_loop_window_ms: 120000\n"
        )
        XCTAssertEqual(
            try DispatchLoopLimits.updating("watchdog:\n  enabled: true\n", from: DispatchLoopLimits(), to: DispatchLoopLimits(longRuns: 10)),
            "watchdog:\n  dispatch_loop_long_runs: 10\n  enabled: true\n"
        )
    }

    func testRefusesToWriteIntoAnInlineSection() {
        XCTAssertThrowsError(
            try DispatchLoopLimits.updating("watchdog: {enabled: true}\n", from: DispatchLoopLimits(), to: DispatchLoopLimits(runs: 2))
        ) { error in
            XCTAssertEqual(error as? DispatchLoopLimitsError, .notABlock("watchdog"))
        }
    }

    // MARK: Steppers

    func testSteppersStayInTheirRanges() {
        XCTAssertEqual(DispatchLoopLimits.steppedRuns(4), 4)
        XCTAssertEqual(DispatchLoopLimits.steppedRuns(0), 1)
        XCTAssertEqual(DispatchLoopLimits.steppedRuns(500), 50)
        XCTAssertEqual(DispatchLoopLimits.minutes(600_000), 10)
        XCTAssertEqual(DispatchLoopLimits.minutes(90_000), 2)
        XCTAssertEqual(DispatchLoopLimits.minutes(200), 1)
        XCTAssertEqual(DispatchLoopLimits.minutes(48 * 3_600_000), 1_440)
    }

    func testOnlyAMovedStepperChangesItsLimit() {
        let loaded = DispatchLoopLimits(runs: 500, windowMs: 90_000, longRuns: 8, longWindowMs: 3_600_000)
        XCTAssertEqual(loaded.setting(runs: 50, windowMinutes: 2, longRuns: 8, longWindowMinutes: 60), loaded)
        XCTAssertEqual(
            loaded.setting(runs: 6, windowMinutes: 2, longRuns: 8, longWindowMinutes: 60),
            DispatchLoopLimits(runs: 6, windowMs: 90_000, longRuns: 8, longWindowMs: 3_600_000)
        )
        XCTAssertEqual(
            loaded.setting(runs: 50, windowMinutes: 5, longRuns: 12, longWindowMinutes: 120),
            DispatchLoopLimits(runs: 500, windowMs: 300_000, longRuns: 12, longWindowMs: 7_200_000)
        )
    }

    // MARK: The file

    func testFileWriteRunsTheCheckOnTheNewTextFirst() async throws {
        let url = try writeConfig()
        let file = SymphonyConfigFile(path: url.path)
        var new = configLimits
        new.longRuns = 10
        var checked: String?

        let result = try await file.writeDispatchLoopLimits(new, from: try file.readDispatchLoopLimits()) { path in
            checked = try? String(contentsOfFile: path, encoding: .utf8)
            return .passed
        }

        XCTAssertEqual(result, .passed)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(checked, written)
        XCTAssertEqual(changedLines(config, written), ["  dispatch_loop_long_runs: 10"])
        XCTAssertEqual(try file.readDispatchLoopLimits(), new)
    }

    func testFileWriteLeavesTheFileWhenTheCheckFails() async throws {
        let url = try writeConfig()
        var new = configLimits
        new.runs = 0

        let result = try await SymphonyConfigFile(path: url.path).writeDispatchLoopLimits(new, from: configLimits) { _ in
            .failed("watchdog.dispatch_loop_runs must be greater than 0")
        }

        XCTAssertEqual(result, .failed("watchdog.dispatch_loop_runs must be greater than 0"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), config)
    }

    // MARK: Helpers

    private func writeConfig() throws -> URL {
        let directory = uniqueTemporaryDirectory("dispatch-loop-limits")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("symphony.yml")
        try config.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    /// The lines of `after` that differ from `before`, which must have the same number of lines.
    private func changedLines(_ before: String, _ after: String) -> [String] {
        let old = before.components(separatedBy: "\n")
        let new = after.components(separatedBy: "\n")
        XCTAssertEqual(old.count, new.count)
        return zip(old, new).filter { $0 != $1 }.map(\.1)
    }
}
