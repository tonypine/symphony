import XCTest
@testable import SymphonyBarCore

final class DispatchSettingsTests: XCTestCase {
    private let config = """
        # Symphony operator config.
        workspaces:
          root: ~/work

        dispatch:
          source: poll  # until the shadow stays at zero
          shadow_window: 30

        ledger:
          artifact_max_bytes: 10485760

        """

    private let configSettings = DispatchSettings(source: .poll, shadowWindow: 30)

    // MARK: Reading

    func testReadsTheSettings() throws {
        XCTAssertEqual(try DispatchSettings.values(in: config), configSettings)
        XCTAssertEqual(
            try DispatchSettings.values(in: "dispatch:\n  source: record\n  shadow_window: 1_000\n"),
            DispatchSettings(source: .record, shadowWindow: 1_000)
        )
        XCTAssertEqual(try DispatchSettings.values(in: "dispatch:\n  source: \"record\"\n"), DispatchSettings(source: .record))
    }

    func testMissingAndNullKeysReadAsSymphonysDefaults() throws {
        let defaults = DispatchSettings(source: .poll, shadowWindow: 20)
        XCTAssertEqual(DispatchSettings(), defaults)
        XCTAssertEqual(try DispatchSettings.values(in: ""), defaults)
        XCTAssertEqual(try DispatchSettings.values(in: "dispatch:\n"), defaults)
        XCTAssertEqual(try DispatchSettings.values(in: "dispatch:\n  source: ~\n  shadow_window: null\n"), defaults)
    }

    func testRefusesValuesItCannotRead() {
        XCTAssertThrowsError(try DispatchSettings.values(in: "dispatch:\n  source: webhook\n")) { error in
            XCTAssertEqual(error as? DispatchSettingsError, .unknownSource("webhook"))
        }
        XCTAssertThrowsError(try DispatchSettings.values(in: "dispatch:\n  shadow_window: many\n")) { error in
            XCTAssertEqual(error as? DispatchSettingsError, .unreadable(key: "dispatch.shadow_window", value: "many"))
        }
        XCTAssertThrowsError(try DispatchSettings.values(in: "dispatch: {source: record}\n")) { error in
            XCTAssertEqual(error as? DispatchSettingsError, .notABlock("dispatch"))
        }
        XCTAssertEqual(
            DispatchSettingsError.unknownSource("webhook").errorDescription,
            "`dispatch.source: webhook` in symphony.yml is not poll or record. Change it by hand."
        )
        XCTAssertEqual(
            DispatchSettingsError.unreadable(key: "dispatch.shadow_window", value: "many").errorDescription,
            "`dispatch.shadow_window: many` in symphony.yml is not a whole number. Change it by hand."
        )
        XCTAssertEqual(
            DispatchSettingsError.notABlock("dispatch").errorDescription,
            "`dispatch:` in symphony.yml is not an indented block. Change the dispatch settings by hand."
        )
    }

    func testThePickersWords() {
        XCTAssertEqual(DispatchSettings.Source.allCases.map(\.title), ["Linear poll", "Symphony's record"])
    }

    // MARK: Writing

    /// The operator switches the picker to Symphony's record: only `dispatch.source` changes, keeping its comment.
    func testThePickerRewritesOnlyTheSourceLine() throws {
        var record = configSettings
        record.source = .record
        XCTAssertEqual(
            changedLines(config, try DispatchSettings.updating(config, from: configSettings, to: record)),
            ["  source: record  # until the shadow stays at zero"]
        )
        XCTAssertEqual(try DispatchSettings.updating(config, from: configSettings, to: configSettings), config)

        var window = configSettings
        window.shadowWindow = 50
        XCTAssertEqual(changedLines(config, try DispatchSettings.updating(config, from: configSettings, to: window)), ["  shadow_window: 50"])
    }

    func testInsertsTheDispatchSectionWhenMissing() throws {
        XCTAssertEqual(
            try DispatchSettings.updating("issues:\n  provider: linear\n", from: DispatchSettings(), to: DispatchSettings(source: .record)),
            "issues:\n  provider: linear\ndispatch:\n  source: record\n"
        )
        XCTAssertEqual(
            try DispatchSettings.updating(
                "issues:\n  provider: linear\n",
                from: DispatchSettings(),
                to: DispatchSettings(source: .record, shadowWindow: 40)
            ),
            "issues:\n  provider: linear\ndispatch:\n  source: record\n  shadow_window: 40\n"
        )
    }

    /// The window field refuses 0 and negatives: nothing is written.
    func testRefusesAWindowOfZeroOrLess() {
        XCTAssertTrue(DispatchSettings.isValidWindow(1))
        for window in [0, -1, -20] {
            XCTAssertFalse(DispatchSettings.isValidWindow(window))
            XCTAssertThrowsError(
                try DispatchSettings.updating(config, from: configSettings, to: DispatchSettings(source: .poll, shadowWindow: window))
            ) { error in
                XCTAssertEqual(error as? DispatchSettingsError, .windowNotPositive(window))
            }
        }
        XCTAssertEqual(DispatchSettingsError.windowNotPositive(0).errorDescription, DispatchSettings.windowRule)
        XCTAssertEqual(DispatchSettings.windowRule, "The shadow window is a number of poll cycles: 1 or more.")
    }

    func testRefusesToWriteIntoAnInlineSection() {
        XCTAssertThrowsError(
            try DispatchSettings.updating("dispatch: {}\n", from: DispatchSettings(), to: DispatchSettings(source: .record))
        ) { error in
            XCTAssertEqual(error as? DispatchSettingsError, .notABlock("dispatch"))
        }
    }

    // MARK: The file

    /// The operator switches to Symphony's record and saves: symphony.yml shows `dispatch.source: record` and nothing
    /// else changes.
    func testFileWriteRunsTheCheckOnTheNewTextFirst() async throws {
        let url = try writeConfig()
        let file = SymphonyConfigFile(path: url.path)
        let loaded = try file.readDispatchSettings()
        var new = loaded
        new.source = .record
        var checked: String?

        let result = try await file.writeDispatchSettings(new, from: loaded) { path in
            checked = try? String(contentsOfFile: path, encoding: .utf8)
            return .passed
        }

        XCTAssertEqual(result, .passed)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(checked, written)
        XCTAssertEqual(changedLines(config, written), ["  source: record  # until the shadow stays at zero"])
        XCTAssertEqual(try file.readDispatchSettings(), DispatchSettings(source: .record, shadowWindow: 30))
    }

    func testFileWriteLeavesTheFileWhenTheCheckFails() async throws {
        let url = try writeConfig()
        var new = configSettings
        new.shadowWindow = 10

        let result = try await SymphonyConfigFile(path: url.path).writeDispatchSettings(new, from: configSettings) { _ in
            .failed("dispatch.shadow_window is invalid")
        }

        XCTAssertEqual(result, .failed("dispatch.shadow_window is invalid"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), config)
    }

    // MARK: Helpers

    private func writeConfig() throws -> URL {
        let directory = uniqueTemporaryDirectory("dispatch-settings")
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
