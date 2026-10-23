import XCTest
@testable import SymphonyBarCore

final class LedgerSettingsTests: XCTestCase {
    private let config = """
        # Symphony operator config.
        workspaces:
          root: ~/work

        ledger:
          artifact_max_bytes: 10485760  # screenshots stay small
          prompt_brief_enabled: true  # agents get the history summary
          prompt_brief_max_tokens: 40_000

        """

    private let configSettings = LedgerSettings(maxBytes: 10_485_760, briefEnabled: true, briefMaxTokens: 40_000)

    // MARK: Reading

    func testReadsTheSettings() throws {
        XCTAssertEqual(try LedgerSettings.values(in: config), configSettings)
    }

    func testMissingAndNullKeysReadAsSymphonysDefaults() throws {
        let defaults = LedgerSettings(maxBytes: 26_214_400, briefEnabled: true, briefMaxTokens: 50_000)
        XCTAssertEqual(LedgerSettings(), defaults)
        XCTAssertEqual(try LedgerSettings.values(in: ""), defaults)
        XCTAssertEqual(try LedgerSettings.values(in: "ledger:\n"), defaults)
        XCTAssertEqual(try LedgerSettings.values(in: "ledger:\n  artifact_max_bytes: ~\n"), defaults)
        XCTAssertEqual(try LedgerSettings.values(in: "ledger:\n  prompt_brief_enabled: null\n  prompt_brief_max_tokens: ~\n"), defaults)
    }

    func testReadsTheSummaryTurnedOff() throws {
        XCTAssertEqual(try LedgerSettings.values(in: "ledger:\n  prompt_brief_enabled: false\n"), LedgerSettings(briefEnabled: false))
        XCTAssertEqual(try LedgerSettings.values(in: "ledger:\n  prompt_brief_enabled: FALSE\n"), LedgerSettings(briefEnabled: false))
        XCTAssertEqual(try LedgerSettings.values(in: "ledger:\n  prompt_brief_enabled: True\n"), LedgerSettings())
    }

    func testReadsUnderscoredNumbers() throws {
        XCTAssertEqual(try LedgerSettings.values(in: "ledger:\n  artifact_max_bytes: 52_428_800\n"), LedgerSettings(maxBytes: 52_428_800))
    }

    func testRefusesValuesItCannotRead() {
        XCTAssertThrowsError(try LedgerSettings.values(in: "ledger:\n  artifact_max_bytes: huge\n")) { error in
            XCTAssertEqual(error as? LedgerSettingsError, .unreadable(key: "ledger.artifact_max_bytes", value: "huge"))
        }
        XCTAssertThrowsError(try LedgerSettings.values(in: "ledger:\n  prompt_brief_enabled: sometimes\n")) { error in
            XCTAssertEqual(error as? LedgerSettingsError, .notOnOrOff(key: "ledger.prompt_brief_enabled", value: "sometimes"))
        }
        XCTAssertThrowsError(try LedgerSettings.values(in: "ledger:\n  prompt_brief_max_tokens: 50k\n")) { error in
            XCTAssertEqual(error as? LedgerSettingsError, .unreadable(key: "ledger.prompt_brief_max_tokens", value: "50k"))
        }
        XCTAssertEqual(
            LedgerSettingsError.notOnOrOff(key: "ledger.prompt_brief_enabled", value: "sometimes").errorDescription,
            "`ledger.prompt_brief_enabled: sometimes` in symphony.yml is not true or false. Change it by hand."
        )
        XCTAssertThrowsError(try LedgerSettings.values(in: "ledger: {artifact_max_bytes: 5}\n")) { error in
            XCTAssertEqual(error as? LedgerSettingsError, .notABlock("ledger"))
        }
        XCTAssertEqual(
            LedgerSettingsError.unreadable(key: "ledger.artifact_max_bytes", value: "huge").errorDescription,
            "`ledger.artifact_max_bytes: huge` in symphony.yml is not a whole number. Change it by hand."
        )
        XCTAssertEqual(
            LedgerSettingsError.notABlock("ledger").errorDescription,
            "`ledger:` in symphony.yml is not an indented block. Change the ledger settings by hand."
        )
    }

    // MARK: Writing

    func testRewritesOnlyTheChangedLineKeepingItsComment() throws {
        var cap = configSettings
        cap.maxBytes = 52_428_800
        XCTAssertEqual(
            changedLines(config, try LedgerSettings.updating(config, from: configSettings, to: cap)),
            ["  artifact_max_bytes: 52428800  # screenshots stay small"]
        )
        XCTAssertEqual(try LedgerSettings.updating(config, from: configSettings, to: configSettings), config)

        var off = configSettings
        off.briefEnabled = false
        XCTAssertEqual(
            changedLines(config, try LedgerSettings.updating(config, from: configSettings, to: off)),
            ["  prompt_brief_enabled: false  # agents get the history summary"]
        )

        var limit = configSettings
        limit.briefMaxTokens = 80_000
        XCTAssertEqual(changedLines(config, try LedgerSettings.updating(config, from: configSettings, to: limit)), ["  prompt_brief_max_tokens: 80000"])
    }

    /// The operator turns the summary off and sets its limit: only those two lines are added, in the file's order.
    func testInsertsTheSummarySettingsWithTheOthersUntouched() throws {
        XCTAssertEqual(
            try LedgerSettings.updating(
                "ledger:\n  artifact_max_bytes: 1048576\n",
                from: LedgerSettings(maxBytes: 1_048_576),
                to: LedgerSettings(maxBytes: 1_048_576, briefEnabled: false, briefMaxTokens: 1_000)
            ),
            "ledger:\n  prompt_brief_enabled: false\n  prompt_brief_max_tokens: 1000\n  artifact_max_bytes: 1048576\n"
        )
    }

    func testInsertsTheLedgerSectionWhenMissing() throws {
        XCTAssertEqual(
            try LedgerSettings.updating(
                "issues:\n  provider: linear\n",
                from: LedgerSettings(),
                to: LedgerSettings(maxBytes: 52_428_800)
            ),
            "issues:\n  provider: linear\nledger:\n  artifact_max_bytes: 52428800\n"
        )
    }

    func testRefusesToWriteIntoAnInlineSection() {
        XCTAssertThrowsError(
            try LedgerSettings.updating("ledger: {}\n", from: LedgerSettings(), to: LedgerSettings(maxBytes: 2))
        ) { error in
            XCTAssertEqual(error as? LedgerSettingsError, .notABlock("ledger"))
        }
    }

    // MARK: Steppers

    func testSteppersStayInTheirRanges() {
        XCTAssertEqual(LedgerSettings.megabytes(26_214_400), 25)
        XCTAssertEqual(LedgerSettings.megabytes(1_600_000), 2)
        XCTAssertEqual(LedgerSettings.megabytes(1), 1)
        XCTAssertEqual(LedgerSettings.megabytes(4_000 * 1_048_576), 1_024)
    }

    func testOnlyAMovedStepperChangesItsSetting() {
        let loaded = LedgerSettings(maxBytes: 1_600_000)
        XCTAssertEqual(loaded.setting(maxMegabytes: 2), loaded)
        XCTAssertEqual(loaded.setting(maxMegabytes: 50), LedgerSettings(maxBytes: 52_428_800))

        let summaryOff = LedgerSettings(briefEnabled: false, briefMaxTokens: 9)
        XCTAssertEqual(summaryOff.setting(maxMegabytes: 50), LedgerSettings(maxBytes: 52_428_800, briefEnabled: false, briefMaxTokens: 9))
    }

    // MARK: The file

    /// The operator changes the size cap to 50 MB: symphony.yml holds the new value.
    func testFileWriteRunsTheCheckOnTheNewTextFirst() async throws {
        let url = try writeConfig()
        let file = SymphonyConfigFile(path: url.path)
        let loaded = try file.readLedgerSettings()
        let new = loaded.setting(maxMegabytes: 50)
        var checked: String?

        let result = try await file.writeLedgerSettings(new, from: loaded) { path in
            checked = try? String(contentsOfFile: path, encoding: .utf8)
            return .passed
        }

        XCTAssertEqual(result, .passed)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(checked, written)
        XCTAssertEqual(changedLines(config, written), ["  artifact_max_bytes: 52428800  # screenshots stay small"])
        XCTAssertEqual(try file.readLedgerSettings(), LedgerSettings(maxBytes: 52_428_800, briefMaxTokens: 40_000))
    }

    func testFileWriteLeavesTheFileWhenTheCheckFails() async throws {
        let url = try writeConfig()
        var new = configSettings
        new.maxBytes = 0

        let result = try await SymphonyConfigFile(path: url.path).writeLedgerSettings(new, from: configSettings) { _ in
            .failed("ledger.artifact_max_bytes must be greater than 0")
        }

        XCTAssertEqual(result, .failed("ledger.artifact_max_bytes must be greater than 0"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), config)
    }

    // MARK: Helpers

    private func writeConfig() throws -> URL {
        let directory = uniqueTemporaryDirectory("ledger-settings")
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
