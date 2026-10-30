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

        linear:
          reconcile_interval_ms: 120_000  # two minutes
          webhooks:
            enabled: true

        ledger:
          artifact_max_bytes: 10485760

        """

    private let configSettings = DispatchSettings(source: .poll, shadowWindow: 30, reconcileIntervalMs: 120_000)

    // MARK: Reading

    func testReadsTheSettings() throws {
        XCTAssertEqual(try DispatchSettings.values(in: config), configSettings)
        XCTAssertEqual(
            try DispatchSettings.values(in: "dispatch:\n  source: record\n  shadow_window: 1_000\n"),
            DispatchSettings(source: .record, shadowWindow: 1_000)
        )
        XCTAssertEqual(try DispatchSettings.values(in: "dispatch:\n  source: \"record\"\n"), DispatchSettings(source: .record))
        XCTAssertEqual(
            try DispatchSettings.values(in: "linear:\n  reconcile_interval_ms: 90000\n"),
            DispatchSettings(reconcileIntervalMs: 90_000)
        )
    }

    func testMissingAndNullKeysReadAsSymphonysDefaults() throws {
        let defaults = DispatchSettings(source: .poll, shadowWindow: 20, reconcileIntervalMs: 300_000)
        XCTAssertEqual(DispatchSettings(), defaults)
        XCTAssertEqual(try DispatchSettings.values(in: ""), defaults)
        XCTAssertEqual(try DispatchSettings.values(in: "dispatch:\n"), defaults)
        XCTAssertEqual(try DispatchSettings.values(in: "dispatch:\n  source: ~\n  shadow_window: null\n"), defaults)
        XCTAssertEqual(try DispatchSettings.values(in: "linear:\n  reconcile_interval_ms: ~\n"), defaults)
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
        XCTAssertThrowsError(try DispatchSettings.values(in: "linear:\n  reconcile_interval_ms: often\n")) { error in
            XCTAssertEqual(error as? DispatchSettingsError, .unreadable(key: "linear.reconcile_interval_ms", value: "often"))
        }
        XCTAssertThrowsError(try DispatchSettings.values(in: "linear: {reconcile_interval_ms: 60000}\n")) { error in
            XCTAssertEqual(error as? DispatchSettingsError, .notABlock("linear"))
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

    /// The operator sets the reconcile interval to 10 minutes: only `linear.reconcile_interval_ms` changes, written in
    /// milliseconds and keeping its comment.
    func testTheReconcileFieldRewritesOnlyItsLineInMilliseconds() throws {
        let ten = configSettings.setting(source: .poll, shadowWindow: 30, reconcileMinutes: 10)
        XCTAssertEqual(ten.reconcileIntervalMs, 600_000)
        XCTAssertEqual(
            changedLines(config, try DispatchSettings.updating(config, from: configSettings, to: ten)),
            ["  reconcile_interval_ms: 600000  # two minutes"]
        )
        XCTAssertEqual(
            try DispatchSettings.updating("linear:\n  webhooks:\n    enabled: true\n", from: configSettings, to: ten),
            "linear:\n  reconcile_interval_ms: 600000\n  webhooks:\n    enabled: true\n"
        )
    }

    /// The field shows whole minutes; an interval it can't show exactly is kept while the field is untouched.
    func testTheFieldShowsMinutesAndKeepsAnUntouchedInterval() {
        XCTAssertEqual(DispatchSettings.reconcileMinutes(300_000), 5)
        XCTAssertEqual(DispatchSettings.reconcileMinutes(90_000), 2)
        XCTAssertEqual(DispatchSettings.reconcileMinutes(60_000), 1)
        XCTAssertEqual(DispatchSettings.reconcileMinutes(1_000), 1)
        let odd = DispatchSettings(reconcileIntervalMs: 90_000)
        XCTAssertEqual(odd.setting(source: .record, shadowWindow: 20, reconcileMinutes: 2), DispatchSettings(source: .record, reconcileIntervalMs: 90_000))
        XCTAssertEqual(odd.setting(source: .poll, shadowWindow: 20, reconcileMinutes: 3).reconcileIntervalMs, 180_000)
    }

    /// The reconcile field refuses anything under one minute: nothing is written.
    func testRefusesAReconcileIntervalUnderOneMinute() {
        XCTAssertTrue(DispatchSettings.isValidReconcileMinutes(1))
        for minutes in [0, -1] {
            XCTAssertFalse(DispatchSettings.isValidReconcileMinutes(minutes))
            let new = configSettings.setting(source: .poll, shadowWindow: 30, reconcileMinutes: minutes)
            XCTAssertThrowsError(try DispatchSettings.updating(config, from: configSettings, to: new)) { error in
                XCTAssertEqual(error as? DispatchSettingsError, .reconcileUnderOneMinute(minutes * 60_000))
            }
        }
        XCTAssertThrowsError(
            try DispatchSettings.updating(config, from: configSettings, to: DispatchSettings(reconcileIntervalMs: 59_999))
        ) { error in
            XCTAssertEqual(error as? DispatchSettingsError, .reconcileUnderOneMinute(59_999))
        }
        XCTAssertEqual(DispatchSettingsError.reconcileUnderOneMinute(0).errorDescription, DispatchSettings.reconcileRule)
        XCTAssertEqual(DispatchSettings.reconcileRule, "The reconcile interval is a number of minutes: 1 or more.")
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
        XCTAssertEqual(try file.readDispatchSettings(), DispatchSettings(source: .record, shadowWindow: 30, reconcileIntervalMs: 120_000))
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
