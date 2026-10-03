import XCTest
@testable import SymphonyBarCore

final class TerminalDashboardTests: XCTestCase {
    private let stateRoot = URL(fileURLWithPath: "/Users/me/Library/Application Support/symphony/release")
    private let embedded = "/Applications/Symphony.app/Contents/Resources/symphony"

    private func script(_ settings: AppSettings, files: [String]) throws -> String {
        try TerminalDashboard.script(
            settings: settings,
            embeddedSymphonyPath: embedded,
            stateRoot: stateRoot,
            files: StubFileChecker(files: Set(files))
        )
    }

    func testEmbeddedSymphonyRunsTheDashboardAgainstTheWatchedStateDirectory() throws {
        let settings = AppSettings(configPath: "/Users/me/symphony.yml")

        XCTAssertEqual(
            try script(settings, files: [embedded]),
            """
            #!/bin/zsh -l
            export SYMPHONY_STATE_ROOT='/Users/me/Library/Application Support/symphony/release'
            exec /Applications/Symphony.app/Contents/Resources/symphony dashboard

            """
        )
    }

    func testDevelopmentModeRunsTheCheckoutThroughTheCommandPrefix() throws {
        let settings = AppSettings(
            checkoutPath: "/src/my symphony",
            configPath: "/src/my symphony/symphony.yml",
            commandPrefix: "mise exec --",
            developmentMode: true
        )

        let lines = try script(settings, files: ["/src/my symphony/bin/symphony"]).split(separator: "\n")

        XCTAssertEqual(lines[1], "cd '/src/my symphony' || exit 1")
        XCTAssertEqual(lines[3], "exec mise exec -- ./bin/symphony dashboard")
    }

    func testScriptHoldsNoSecretFromTheEnvironment() throws {
        let text = try script(AppSettings(configPath: "/Users/me/symphony.yml"), files: [embedded])

        XCTAssertFalse(text.contains(SecretSettings.linearAPIKeyName))
        // The CLI finds the control URL itself on every poll; a fixed one goes stale when Symphony restarts.
        XCTAssertFalse(text.contains("--url"))
    }

    func testMissingBinariesAndBadSettingsAreLaunchProblems() {
        XCTAssertThrowsError(try script(AppSettings(configPath: "/c.yml"), files: [])) { error in
            XCTAssertEqual(error as? LaunchProblem, .embeddedSymphonyMissing)
        }
        XCTAssertThrowsError(try script(AppSettings(developmentMode: true), files: [])) { error in
            XCTAssertEqual(error as? LaunchProblem, .checkoutPathMissing)
        }
        XCTAssertThrowsError(
            try script(AppSettings(checkoutPath: "/src", commandPrefix: "'open", developmentMode: true), files: [])
        ) { error in
            XCTAssertEqual(error as? LaunchProblem, .commandPrefixInvalid)
        }
        XCTAssertThrowsError(try script(AppSettings(checkoutPath: "/src", developmentMode: true), files: [])) { error in
            XCTAssertEqual(error as? LaunchProblem, .symphonyBinaryMissing("/src/bin/symphony"))
        }
    }
}
