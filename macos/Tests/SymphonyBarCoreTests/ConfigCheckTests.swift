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

    func testRunPassesWithTheLaunchEnvironmentAndFailsWithTheOutput() async {
        let passed = await ConfigCheck.run(shell("test \"$CHECK_WORD\" = from-env"))
        XCTAssertEqual(passed, .passed)

        let failed = await ConfigCheck.run(shell("echo noise; echo 'Config error in /ops/symphony.yml: bad' >&2; exit 1"))
        XCTAssertEqual(failed, .failed("Config error in /ops/symphony.yml: bad"))
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
