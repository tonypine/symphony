import XCTest
@testable import SymphonyBarCore

final class ConfigCheckTests: XCTestCase {
    private func shell(_ script: String) -> ChildLaunch {
        ChildLaunch(
            executable: "/bin/sh",
            arguments: ["-c", script],
            workingDirectory: NSTemporaryDirectory(),
            environment: ["PATH": "/usr/bin:/bin", "CHECK_WORD": "from-env"]
        )
    }

    func testExitStatusZeroPasses() {
        XCTAssertEqual(ConfigCheck.result(status: 0, output: "Config OK: /ops/symphony.yml\n"), .passed)
    }

    func testTheConfigErrorIsPickedOutOfShellNoise() {
        let output = """
            /Users/me/.profile: Operation not permitted
            Config error in /ops/symphony.yml: invalid
              repos[0].workflow is missing

            """

        XCTAssertEqual(
            ConfigCheck.result(status: 1, output: output),
            .failed("Config error in /ops/symphony.yml: invalid repos[0].workflow is missing")
        )
    }

    func testOtherFailuresUseTheLastLineOrTheStatus() {
        XCTAssertEqual(ConfigCheck.result(status: 127, output: "zsh: command not found: mise\n"), .failed("zsh: command not found: mise"))
        XCTAssertEqual(ConfigCheck.result(status: 2, output: " \n"), .failed("symphony check exited with status 2"))
        XCTAssertEqual(ConfigCheck.result(status: -9, output: ""), .failed("symphony check was killed by signal 9"))
    }

    func testLongMessagesAreShortened() {
        let result = ConfigCheck.result(status: 1, output: String(repeating: "x", count: 1000))

        XCTAssertEqual(result, .failed(String(repeating: "x", count: ConfigCheck.maxMessageLength) + "…"))
    }

    func testAConfigErrorReadsWithTheReasonAndKeyBeforeThePath() {
        XCTAssertEqual(
            ConfigCheck.reasonFirst("Config error in /Users/me/ops/symphony.yml: invalid agent.run_profiles.qa.effort: \"huge\""),
            "invalid agent.run_profiles.qa.effort: \"huge\" (in /Users/me/ops/symphony.yml)"
        )
    }

    func testOtherMessagesStayAsTheyAre() {
        let missing = "/opt/symphony/bin/symphony was not found. Build it with `mise exec -- mix build` in the checkout."
        XCTAssertEqual(ConfigCheck.reasonFirst(missing), missing)
        XCTAssertEqual(ConfigCheck.reasonFirst("Config error in /ops/symphony.yml"), "Config error in /ops/symphony.yml")
        XCTAssertEqual(ConfigCheck.reasonFirst("Config error in : bad"), "Config error in : bad")
        XCTAssertEqual(ConfigCheck.reasonFirst("Config error in /ops/symphony.yml:  "), "Config error in /ops/symphony.yml:  ")
    }

    func testRunPassesWithTheLaunchEnvironmentAndFailsWithTheOutput() async {
        let passed = await ConfigCheck.run(shell("test \"$CHECK_WORD\" = from-env"))
        XCTAssertEqual(passed, .passed)

        let failed = await ConfigCheck.run(shell("echo noise; echo 'Config error in /ops/symphony.yml: bad' >&2; exit 1"))
        XCTAssertEqual(failed, .failed("Config error in /ops/symphony.yml: bad"))
    }

    func testRunLogsTheStatusAndOutput() async {
        let entries = LogEntries()
        let result = await ConfigCheck.run(shell("echo 'Symphony 0.0.1 (abc1234)' >&2; echo 'Config OK: /ops/symphony.yml'"), log: entries.append)

        XCTAssertEqual(result, .passed)
        XCTAssertEqual(entries.all, ["symphony check exited with status 0:\n  Symphony 0.0.1 (abc1234)\n  Config OK: /ops/symphony.yml\n"])
    }

    func testTheLogEntryIndentsTheOutputAndSkipsBlankLines() {
        XCTAssertEqual(
            ConfigCheck.logEntry(status: 1, output: "Symphony 0.0.1\n\nConfig error in /ops/symphony.yml: bad\n"),
            "symphony check exited with status 1:\n  Symphony 0.0.1\n  Config error in /ops/symphony.yml: bad\n"
        )
        XCTAssertEqual(ConfigCheck.logEntry(status: -9, output: ""), "symphony check exited with status -9:\n")
    }

    func testOnlyQAModeLogs() {
        XCTAssertNil(ConfigCheck.qaLog(nil))
        XCTAssertNotNil(ConfigCheck.qaLog(QAMode(root: URL(fileURLWithPath: NSTemporaryDirectory()))))
    }

    func testRunGivesUpAfterTheTimeout() async {
        let result = await ConfigCheck.run(shell("sleep 30"), timeout: 2)

        XCTAssertEqual(result, .failed("symphony check took longer than 2 seconds."))
    }

    func testRunReportsAProgramThatCantStart() async {
        let launch = ChildLaunch(executable: "/no/such/symphony", arguments: [], workingDirectory: "/", environment: [:])

        guard case let .failed(message) = await ConfigCheck.run(launch) else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.hasPrefix("Couldn't run symphony check: "), message)
    }
}

/// Collects the entries `ConfigCheck.run` logs, from whichever thread it logs on.
private final class LogEntries: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    var all: [String] { lock.withLock { entries } }

    func append(_ entry: String) {
        lock.withLock { entries.append(entry) }
    }
}
