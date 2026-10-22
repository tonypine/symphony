import XCTest
@testable import SymphonyBarCore

final class CodeReviewSettingsTests: XCTestCase {
    private let config = """
        # Symphony operator config.
        workspaces:
          root: ~/work

        # Code Review's reviewer.
        code_review:
          enabled: true  # review every PR
          runtime: codex
          command: codex app-server
          # model: claude-opus-5-5

        """

    private let configSettings = CodeReviewSettings(enabled: true, runtime: .codex)

    // MARK: Reading

    func testReadsTheSettings() throws {
        XCTAssertEqual(try CodeReviewSettings.values(in: config), configSettings)
    }

    func testMissingAndNullKeysReadAsSymphonysDefaults() throws {
        let defaults = CodeReviewSettings(enabled: false, runtime: nil)
        XCTAssertEqual(CodeReviewSettings(), defaults)
        XCTAssertEqual(try CodeReviewSettings.values(in: ""), defaults)
        XCTAssertEqual(try CodeReviewSettings.values(in: "code_review:\n"), defaults)
        XCTAssertEqual(try CodeReviewSettings.values(in: "code_review:\n  enabled: null\n  runtime: ~\n"), defaults)
    }

    func testReadsEitherRuntimeQuotedOrNot() throws {
        XCTAssertEqual(try CodeReviewSettings.values(in: "code_review:\n  runtime: claude\n"), CodeReviewSettings(runtime: .claude))
        XCTAssertEqual(try CodeReviewSettings.values(in: "code_review:\n  runtime: \"claude\"\n"), CodeReviewSettings(runtime: .claude))
        XCTAssertEqual(try CodeReviewSettings.values(in: "code_review:\n  runtime: 'codex'\n"), CodeReviewSettings(runtime: .codex))
        XCTAssertEqual(try CodeReviewSettings.values(in: "code_review:\n  enabled: FALSE\n"), CodeReviewSettings())
        XCTAssertEqual(try CodeReviewSettings.values(in: "code_review:\n  enabled: True\n"), CodeReviewSettings(enabled: true))
    }

    func testRefusesValuesItCannotRead() {
        XCTAssertThrowsError(try CodeReviewSettings.values(in: "code_review:\n  enabled: sometimes\n")) { error in
            XCTAssertEqual(error as? CodeReviewSettingsError, .notOnOrOff("sometimes"))
        }
        XCTAssertThrowsError(try CodeReviewSettings.values(in: "code_review:\n  runtime: gemini\n")) { error in
            XCTAssertEqual(error as? CodeReviewSettingsError, .unknownRuntime("gemini"))
        }
        XCTAssertThrowsError(try CodeReviewSettings.values(in: "code_review: {enabled: true}\n")) { error in
            XCTAssertEqual(error as? CodeReviewSettingsError, .notABlock("code_review"))
        }
        XCTAssertEqual(
            CodeReviewSettingsError.notOnOrOff("sometimes").errorDescription,
            "`code_review.enabled: sometimes` in symphony.yml is not true or false. Change it by hand."
        )
        XCTAssertEqual(
            CodeReviewSettingsError.unknownRuntime("gemini").errorDescription,
            "`code_review.runtime: gemini` in symphony.yml is not codex or claude. Change it by hand."
        )
        XCTAssertEqual(
            CodeReviewSettingsError.notABlock("code_review").errorDescription,
            "`code_review:` in symphony.yml is not an indented block. Change Code Review's reviewer by hand."
        )
    }

    // MARK: Writing

    /// The operator turns the reviewer off: only that line changes, keeping its comment, the command and the rest.
    func testRewritesOnlyTheChangedLineKeepingItsComment() throws {
        var off = configSettings
        off.enabled = false
        XCTAssertEqual(
            changedLines(config, try CodeReviewSettings.updating(config, from: configSettings, to: off)),
            ["  enabled: false  # review every PR"]
        )

        var claude = configSettings
        claude.runtime = .claude
        XCTAssertEqual(changedLines(config, try CodeReviewSettings.updating(config, from: configSettings, to: claude)), ["  runtime: claude"])
        XCTAssertEqual(try CodeReviewSettings.updating(config, from: configSettings, to: configSettings), config)
    }

    /// Both keys go in at the top of an existing `code_review:` block, in order, above its `command:` line.
    func testInsertsMissingKeysAboveTheCommand() throws {
        XCTAssertEqual(
            try CodeReviewSettings.updating(
                "code_review:\n  command: claude -p  # read-only\n",
                from: CodeReviewSettings(),
                to: CodeReviewSettings(enabled: true, runtime: .claude)
            ),
            "code_review:\n  enabled: true\n  runtime: claude\n  command: claude -p  # read-only\n"
        )
    }

    func testInsertsTheCodeReviewSectionWhenMissing() throws {
        XCTAssertEqual(
            try CodeReviewSettings.updating(
                "issues:\n  provider: linear\n",
                from: CodeReviewSettings(),
                to: CodeReviewSettings(enabled: true, runtime: .codex)
            ),
            "issues:\n  provider: linear\ncode_review:\n  enabled: true\n  runtime: codex\n"
        )
    }

    func testClearingTheRuntimeWritesNull() throws {
        XCTAssertEqual(
            try CodeReviewSettings.updating("code_review:\n  runtime: codex\n", from: CodeReviewSettings(runtime: .codex), to: CodeReviewSettings()),
            "code_review:\n  runtime: null\n"
        )
    }

    func testRefusesToWriteIntoAnInlineSection() {
        XCTAssertThrowsError(
            try CodeReviewSettings.updating("code_review: {}\n", from: CodeReviewSettings(), to: CodeReviewSettings(enabled: true))
        ) { error in
            XCTAssertEqual(error as? CodeReviewSettingsError, .notABlock("code_review"))
        }
    }

    // MARK: The file

    /// The operator switches the reviewer to Claude: symphony.yml holds the new runtime once the check passes.
    func testFileWriteRunsTheCheckOnTheNewTextFirst() async throws {
        let url = try writeConfig()
        let file = SymphonyConfigFile(path: url.path)
        let loaded = try file.readCodeReviewSettings()
        var new = loaded
        new.runtime = .claude
        var checked: String?

        let result = try await file.writeCodeReviewSettings(new, from: loaded) { path in
            checked = try? String(contentsOfFile: path, encoding: .utf8)
            return .passed
        }

        XCTAssertEqual(result, .passed)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(checked, written)
        XCTAssertEqual(changedLines(config, written), ["  runtime: claude"])
        XCTAssertEqual(try file.readCodeReviewSettings(), CodeReviewSettings(enabled: true, runtime: .claude))
    }

    func testFileWriteLeavesTheFileWhenTheCheckFails() async throws {
        let url = try writeConfig()
        let new = CodeReviewSettings(enabled: true, runtime: nil)

        let result = try await SymphonyConfigFile(path: url.path).writeCodeReviewSettings(new, from: configSettings) { _ in
            .failed("code_review.runtime is required when code_review.enabled is true")
        }

        XCTAssertEqual(result, .failed("code_review.runtime is required when code_review.enabled is true"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), config)
    }

    // MARK: Helpers

    private func writeConfig() throws -> URL {
        let directory = uniqueTemporaryDirectory("code-review-settings")
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
