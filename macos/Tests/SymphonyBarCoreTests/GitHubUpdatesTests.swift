import XCTest
@testable import SymphonyBarCore

final class GitHubUpdatesTests: XCTestCase {
    private let config = """
        # Symphony operator config.
        github:
          open_pull_requests_as_draft: true
          webhooks:
            enabled: true
            relay: smee
            fallback_poll_interval_ms: 600000  # 10 minutes
            silence_alert_minutes: 15

        """

    private let configUpdates = GitHubUpdates(fallbackPollMs: 600_000, silenceAlertMinutes: 15)

    // MARK: Reading

    func testReadsTheSettings() throws {
        XCTAssertEqual(try GitHubUpdates.values(in: config), configUpdates)
    }

    func testMissingAndNullKeysReadAsSymphonysDefaults() throws {
        let defaults = GitHubUpdates(fallbackPollMs: 300_000, silenceAlertMinutes: 10)
        XCTAssertEqual(GitHubUpdates(), defaults)
        XCTAssertEqual(try GitHubUpdates.values(in: ""), defaults)
        XCTAssertEqual(try GitHubUpdates.values(in: "github:\n  webhooks:\n    enabled: true\n"), defaults)
        XCTAssertEqual(
            try GitHubUpdates.values(in: "github:\n  webhooks:\n    fallback_poll_interval_ms: null\n    silence_alert_minutes: ~\n"),
            defaults
        )
    }

    func testReadsUnderscoredNumbers() throws {
        XCTAssertEqual(
            try GitHubUpdates.values(in: "github:\n  webhooks:\n    fallback_poll_interval_ms: 120_000\n"),
            GitHubUpdates(fallbackPollMs: 120_000)
        )
    }

    func testRefusesValuesItCannotRead() {
        XCTAssertThrowsError(try GitHubUpdates.values(in: "github:\n  webhooks:\n    silence_alert_minutes: soon\n")) { error in
            XCTAssertEqual(error as? GitHubUpdatesError, .unreadable(key: "github.webhooks.silence_alert_minutes", value: "soon"))
        }
        XCTAssertThrowsError(try GitHubUpdates.values(in: "github:\n  webhooks: {enabled: true}\n")) { error in
            XCTAssertEqual(error as? GitHubUpdatesError, .notABlock("webhooks"))
        }
        XCTAssertEqual(
            GitHubUpdatesError.unreadable(key: "github.webhooks.silence_alert_minutes", value: "soon").errorDescription,
            "`github.webhooks.silence_alert_minutes: soon` in symphony.yml is not a whole number. Change it by hand."
        )
        XCTAssertEqual(
            GitHubUpdatesError.notABlock("webhooks").errorDescription,
            "`webhooks:` in symphony.yml is not an indented block. Change the GitHub update settings by hand."
        )
    }

    // MARK: Writing

    func testRewritesOnlyTheChangedLineKeepingItsComment() throws {
        let updated = try GitHubUpdates.updating(config, from: configUpdates, to: GitHubUpdates(fallbackPollMs: 900_000, silenceAlertMinutes: 15))
        XCTAssertEqual(changedLines(config, updated), ["    fallback_poll_interval_ms: 900000  # 10 minutes"])
        XCTAssertEqual(try GitHubUpdates.updating(config, from: configUpdates, to: configUpdates), config)

        let quieter = try GitHubUpdates.updating(config, from: configUpdates, to: GitHubUpdates(fallbackPollMs: 600_000, silenceAlertMinutes: 30))
        XCTAssertEqual(changedLines(config, quieter), ["    silence_alert_minutes: 30"])
    }

    func testInsertsMissingKeysAndSections() throws {
        XCTAssertEqual(
            try GitHubUpdates.updating("issues:\n  provider: linear\n", from: GitHubUpdates(), to: GitHubUpdates(fallbackPollMs: 60_000, silenceAlertMinutes: 5)),
            "issues:\n  provider: linear\ngithub:\n  webhooks:\n    silence_alert_minutes: 5\n    fallback_poll_interval_ms: 60000\n"
        )
        XCTAssertEqual(
            try GitHubUpdates.updating("github:\n  webhooks:\n    enabled: true\n", from: GitHubUpdates(), to: GitHubUpdates(silenceAlertMinutes: 20)),
            "github:\n  webhooks:\n    silence_alert_minutes: 20\n    enabled: true\n"
        )
    }

    func testRefusesToWriteIntoAnInlineSection() {
        XCTAssertThrowsError(
            try GitHubUpdates.updating("github: {enterprise_hosts: []}\n", from: GitHubUpdates(), to: GitHubUpdates(fallbackPollMs: 60_000))
        ) { error in
            XCTAssertEqual(error as? GitHubUpdatesError, .notABlock("github"))
        }
    }

    // MARK: Minutes

    func testMinutesRoundAndStayInTheStepperRange() {
        XCTAssertEqual(GitHubUpdates.minutes(300_000), 5)
        XCTAssertEqual(GitHubUpdates.minutes(90_000), 2)
        XCTAssertEqual(GitHubUpdates.minutes(200), 1)
        XCTAssertEqual(GitHubUpdates.minutes(24 * 3_600_000), 120)
        XCTAssertEqual(GitHubUpdates.stepperMinutes(0), 1)
        XCTAssertEqual(GitHubUpdates.stepperMinutes(15), 15)
        XCTAssertEqual(GitHubUpdates.stepperMinutes(600), 120)
    }

    func testOnlyAMovedStepperChangesTheInterval() {
        let loaded = GitHubUpdates(fallbackPollMs: 45_000, silenceAlertMinutes: 10)
        XCTAssertEqual(loaded.settingMinutes(fallbackPoll: 1, silenceAlert: 10), loaded)
        XCTAssertEqual(loaded.settingMinutes(fallbackPoll: 3, silenceAlert: 10), GitHubUpdates(fallbackPollMs: 180_000, silenceAlertMinutes: 10))
        XCTAssertEqual(loaded.settingMinutes(fallbackPoll: 1, silenceAlert: 25), GitHubUpdates(fallbackPollMs: 45_000, silenceAlertMinutes: 25))

        let long = GitHubUpdates(fallbackPollMs: 300_000, silenceAlertMinutes: 600)
        XCTAssertEqual(long.settingMinutes(fallbackPoll: 5, silenceAlert: 120), long)
        XCTAssertEqual(long.settingMinutes(fallbackPoll: 5, silenceAlert: 119).silenceAlertMinutes, 119)
    }

    // MARK: The file

    func testFileWriteRunsTheCheckOnTheNewTextFirst() async throws {
        let url = try writeConfig()
        let file = SymphonyConfigFile(path: url.path)
        var new = configUpdates
        new.fallbackPollMs = 300_000
        var checked: String?

        let result = try await file.writeGitHubUpdates(new, from: try file.readGitHubUpdates()) { path in
            checked = try? String(contentsOfFile: path, encoding: .utf8)
            return .passed
        }

        XCTAssertEqual(result, .passed)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(checked, written)
        XCTAssertEqual(changedLines(config, written), ["    fallback_poll_interval_ms: 300000  # 10 minutes"])
        XCTAssertEqual(try file.readGitHubUpdates(), new)
    }

    func testFileWriteLeavesTheFileWhenTheCheckFails() async throws {
        let url = try writeConfig()

        let result = try await SymphonyConfigFile(path: url.path).writeGitHubUpdates(
            GitHubUpdates(fallbackPollMs: 600_000, silenceAlertMinutes: 0),
            from: configUpdates
        ) { _ in .failed("github.webhooks.silence_alert_minutes must be greater than 0") }

        XCTAssertEqual(result, .failed("github.webhooks.silence_alert_minutes must be greater than 0"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), config)
    }

    // MARK: Helpers

    private func writeConfig() throws -> URL {
        let directory = uniqueTemporaryDirectory("github-updates")
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
