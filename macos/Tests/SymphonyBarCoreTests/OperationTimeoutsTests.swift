import XCTest
@testable import SymphonyBarCore

final class OperationTimeoutsTests: XCTestCase {
    private let config = """
        # Symphony operator config.
        agent:
          runtime: claude
          timeouts:
            turn_ms: 3600000
            mcp_tool_ms: 900000  # 15 minutes

        workspaces:
          root: ~/work
          git_network_timeout_ms: 120000

        watchdog:
          pending_tool_report_after_ms: 300000

        """

    private let configTimeouts = OperationTimeouts(gitNetworkMs: 120_000, mcpToolMs: 900_000, pendingToolReportMs: 300_000)

    // MARK: Reading

    func testReadsTheTimeouts() throws {
        XCTAssertEqual(try OperationTimeouts.values(in: config), configTimeouts)
    }

    func testMissingAndNullKeysReadAsSymphonysDefaults() throws {
        let defaults = OperationTimeouts(gitNetworkMs: 300_000, mcpToolMs: 600_000, pendingToolReportMs: 60_000)
        XCTAssertEqual(OperationTimeouts(), defaults)
        XCTAssertEqual(try OperationTimeouts.values(in: ""), defaults)
        XCTAssertEqual(try OperationTimeouts.values(in: "agent:\n  timeouts:\n    turn_ms: 5\nworkspaces:\n  root: ~/w\n"), defaults)
        XCTAssertEqual(
            try OperationTimeouts.values(
                in: "agent:\n  timeouts:\n    mcp_tool_ms: null\nworkspaces:\n  git_network_timeout_ms: ~\n"
                    + "watchdog:\n  pending_tool_report_after_ms: null\n"
            ),
            defaults
        )
    }

    func testReadsUnderscoredNumbers() throws {
        XCTAssertEqual(
            try OperationTimeouts.values(in: "workspaces:\n  git_network_timeout_ms: 60_000\n"),
            OperationTimeouts(gitNetworkMs: 60_000)
        )
    }

    func testRefusesValuesItCannotRead() {
        XCTAssertThrowsError(try OperationTimeouts.values(in: "workspaces:\n  git_network_timeout_ms: soon\n")) { error in
            XCTAssertEqual(error as? OperationTimeoutsError, .unreadable(key: "workspaces.git_network_timeout_ms", value: "soon"))
        }
        XCTAssertThrowsError(try OperationTimeouts.values(in: "agent:\n  timeouts: {mcp_tool_ms: 5}\n")) { error in
            XCTAssertEqual(error as? OperationTimeoutsError, .notABlock("timeouts"))
        }
        XCTAssertEqual(
            OperationTimeoutsError.unreadable(key: "workspaces.git_network_timeout_ms", value: "soon").errorDescription,
            "`workspaces.git_network_timeout_ms: soon` in symphony.yml is not a whole number of milliseconds. Change it by hand."
        )
        XCTAssertEqual(
            OperationTimeoutsError.notABlock("timeouts").errorDescription,
            "`timeouts:` in symphony.yml is not an indented block. Change the timeouts by hand."
        )
    }

    // MARK: Writing

    func testRewritesOnlyTheChangedLineKeepingItsComment() throws {
        let updated = try OperationTimeouts.updating(
            config,
            from: configTimeouts,
            to: OperationTimeouts(gitNetworkMs: 120_000, mcpToolMs: 1_200_000, pendingToolReportMs: 300_000)
        )
        XCTAssertEqual(changedLines(config, updated), ["    mcp_tool_ms: 1200000  # 15 minutes"])
        XCTAssertEqual(try OperationTimeouts.updating(config, from: configTimeouts, to: configTimeouts), config)

        var later = configTimeouts
        later.pendingToolReportMs = 120_000
        let reported = try OperationTimeouts.updating(config, from: configTimeouts, to: later)
        XCTAssertEqual(changedLines(config, reported), ["  pending_tool_report_after_ms: 120000"])
    }

    func testInsertsMissingKeysAndSections() throws {
        let new = OperationTimeouts(gitNetworkMs: 60_000, mcpToolMs: 120_000)
        XCTAssertEqual(
            try OperationTimeouts.updating("issues:\n  provider: linear\n", from: OperationTimeouts(), to: new),
            "issues:\n  provider: linear\nworkspaces:\n  git_network_timeout_ms: 60000\nagent:\n  timeouts:\n    mcp_tool_ms: 120000\n"
        )
        XCTAssertEqual(
            try OperationTimeouts.updating("issues:\n  provider: linear\n", from: OperationTimeouts(), to: OperationTimeouts(pendingToolReportMs: 180_000)),
            "issues:\n  provider: linear\nwatchdog:\n  pending_tool_report_after_ms: 180000\n"
        )
        XCTAssertEqual(
            try OperationTimeouts.updating("agent:\n    runtime: codex\nworkspaces:\n    root: ~/w\n", from: OperationTimeouts(), to: new),
            "agent:\n    timeouts:\n        mcp_tool_ms: 120000\n    runtime: codex\nworkspaces:\n    git_network_timeout_ms: 60000\n    root: ~/w\n"
        )
        XCTAssertEqual(
            try OperationTimeouts.updating("workspaces:\nagent:\n  timeouts:\n", from: OperationTimeouts(), to: new),
            "workspaces:\n  git_network_timeout_ms: 60000\nagent:\n  timeouts:\n    mcp_tool_ms: 120000\n"
        )
    }

    func testRefusesToWriteIntoAnInlineSection() {
        XCTAssertThrowsError(
            try OperationTimeouts.updating("workspaces: {root: ~/w}\n", from: OperationTimeouts(), to: OperationTimeouts(gitNetworkMs: 1))
        ) { error in
            XCTAssertEqual(error as? OperationTimeoutsError, .notABlock("workspaces"))
        }
    }

    // MARK: Minutes

    func testMinutesRoundAndStayInTheStepperRange() {
        XCTAssertEqual(OperationTimeouts.minutes(300_000), 5)
        XCTAssertEqual(OperationTimeouts.minutes(90_000), 2)
        XCTAssertEqual(OperationTimeouts.minutes(200), 1)
        XCTAssertEqual(OperationTimeouts.minutes(24 * 3_600_000), 120)
    }

    func testOnlyAMovedStepperChangesItsTimeout() {
        let loaded = OperationTimeouts(gitNetworkMs: 200, mcpToolMs: 600_000, pendingToolReportMs: 45_000)
        XCTAssertEqual(loaded.settingMinutes(gitNetwork: 1, mcpTool: 10, pendingToolReport: 1), loaded)
        XCTAssertEqual(
            loaded.settingMinutes(gitNetwork: 3, mcpTool: 10, pendingToolReport: 1),
            OperationTimeouts(gitNetworkMs: 180_000, mcpToolMs: 600_000, pendingToolReportMs: 45_000)
        )
        XCTAssertEqual(
            loaded.settingMinutes(gitNetwork: 1, mcpTool: 30, pendingToolReport: 1),
            OperationTimeouts(gitNetworkMs: 200, mcpToolMs: 1_800_000, pendingToolReportMs: 45_000)
        )
        XCTAssertEqual(
            loaded.settingMinutes(gitNetwork: 1, mcpTool: 10, pendingToolReport: 5),
            OperationTimeouts(gitNetworkMs: 200, mcpToolMs: 600_000, pendingToolReportMs: 300_000)
        )
    }

    // MARK: The file

    func testFileWriteRunsTheCheckOnTheNewTextFirst() async throws {
        let url = try writeConfig()
        let file = SymphonyConfigFile(path: url.path)
        var new = configTimeouts
        new.gitNetworkMs = 600_000
        var checked: String?

        let result = try await file.writeOperationTimeouts(new, from: try file.readOperationTimeouts()) { path in
            checked = try? String(contentsOfFile: path, encoding: .utf8)
            return .passed
        }

        XCTAssertEqual(result, .passed)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(checked, written)
        XCTAssertEqual(changedLines(config, written), ["  git_network_timeout_ms: 600000"])
        XCTAssertEqual(try file.readOperationTimeouts(), new)
    }

    func testFileWriteLeavesTheFileWhenTheCheckFails() async throws {
        let url = try writeConfig()

        let result = try await SymphonyConfigFile(path: url.path).writeOperationTimeouts(
            OperationTimeouts(gitNetworkMs: 0, mcpToolMs: configTimeouts.mcpToolMs, pendingToolReportMs: configTimeouts.pendingToolReportMs),
            from: configTimeouts
        ) { _ in .failed("workspaces.git_network_timeout_ms must be greater than 0") }

        XCTAssertEqual(result, .failed("workspaces.git_network_timeout_ms must be greater than 0"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), config)
    }

    // MARK: Helpers

    private func writeConfig() throws -> URL {
        let directory = uniqueTemporaryDirectory("operation-timeouts")
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
