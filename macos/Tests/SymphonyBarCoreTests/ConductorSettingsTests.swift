import XCTest
@testable import SymphonyBarCore

/// `conductor.enabled`, `conductor.junctions` and `conductor.timeout_ms` as Settings reads and writes them.
final class ConductorSettingsTests: XCTestCase {
    private let config = """
        # Symphony operator config.
        conductor:
          enabled: true  # turns at four junctions
          junctions: [after_coding, before_merge]
          timeout_ms: 120000
        repositories:
          - key: web

        """

    private let configSettings = ConductorSettings(enabled: true, junctions: [.afterCoding, .beforeMerge], timeoutMs: 120_000)

    // MARK: Reading

    func testReadsTheThreeSettings() throws {
        XCTAssertEqual(try ConductorSettings.values(in: config), configSettings)
    }

    func testAMissingOrNullKeyReadsAsSymphonysDefault() throws {
        let defaults = ConductorSettings(enabled: false, junctions: Set(ConductorJunction.allCases), timeoutMs: 180_000)
        XCTAssertEqual(ConductorSettings(), defaults)
        XCTAssertEqual(try ConductorSettings.values(in: ""), defaults)
        XCTAssertEqual(try ConductorSettings.values(in: "conductor:\n"), defaults)
        XCTAssertEqual(try ConductorSettings.values(in: "conductor:\n  enabled: ~\n  junctions: null\n  timeout_ms: ~\n"), defaults)
    }

    func testReadsJunctionsAsABlockListAnEmptyListOrOneBareValue() throws {
        XCTAssertEqual(
            try ConductorSettings.values(in: "conductor:\n  junctions:\n    - after_qa_fail\n    - \"after_rework\"\n").junctions,
            [.afterQAFail, .afterRework]
        )
        XCTAssertEqual(try ConductorSettings.values(in: "conductor:\n  junctions: []\n").junctions, [])
        XCTAssertEqual(try ConductorSettings.values(in: "conductor:\n  junctions: before_merge\n").junctions, [.beforeMerge])
        XCTAssertEqual(try ConductorSettings.values(in: "conductor:\n  timeout_ms: 90_000\n").timeoutMs, 90_000)
    }

    func testRefusesWhatItCantRead() {
        XCTAssertThrowsError(try ConductorSettings.values(in: "conductor:\n  enabled: maybe\n")) { error in
            XCTAssertEqual(error as? ConductorSettingsError, .notOnOrOff(key: "conductor.enabled", value: "maybe"))
        }
        XCTAssertThrowsError(try ConductorSettings.values(in: "conductor:\n  timeout_ms: 3m\n")) { error in
            XCTAssertEqual(error as? ConductorSettingsError, .unreadable(key: "conductor.timeout_ms", value: "3m"))
        }
        XCTAssertThrowsError(try ConductorSettings.values(in: "conductor:\n  junctions: [after_lunch]\n")) { error in
            XCTAssertEqual(error as? ConductorSettingsError, .unknownJunction("after_lunch"))
        }
        XCTAssertThrowsError(try ConductorSettings.values(in: "conductor: {enabled: true}\n")) { error in
            XCTAssertEqual(error as? ConductorSettingsError, .notABlock("conductor"))
        }
        XCTAssertEqual(
            ConductorSettingsError.notABlock("conductor").errorDescription,
            "`conductor:` in symphony.yml is not an indented block. Change the Conductor settings by hand."
        )
        XCTAssertEqual(
            ConductorSettingsError.notOnOrOff(key: "conductor.enabled", value: "maybe").errorDescription,
            "`conductor.enabled: maybe` in symphony.yml is not true or false. Change it by hand."
        )
        XCTAssertEqual(
            ConductorSettingsError.unreadable(key: "conductor.timeout_ms", value: "3m").errorDescription,
            "`conductor.timeout_ms: 3m` in symphony.yml is not a whole number. Change it by hand."
        )
        XCTAssertEqual(
            ConductorSettingsError.unknownJunction("after_lunch").errorDescription,
            "`conductor.junctions` in symphony.yml names `after_lunch`, which is not a junction. Change it by hand."
        )
    }

    // MARK: Writing

    func testRewritesOnlyTheChangedLineKeepingItsComment() throws {
        var off = configSettings
        off.enabled = false
        XCTAssertEqual(changedLines(config, try ConductorSettings.updating(config, from: configSettings, to: off)), ["  enabled: false  # turns at four junctions"])
        XCTAssertEqual(try ConductorSettings.updating(config, from: configSettings, to: configSettings), config)

        let rework = configSettings.setting(.afterRework, on: true).setting(.beforeMerge, on: false)
        XCTAssertEqual(
            changedLines(config, try ConductorSettings.updating(config, from: configSettings, to: rework)),
            ["  junctions: [after_coding, after_rework]"]
        )
        let none = configSettings.setting(.afterCoding, on: false).setting(.beforeMerge, on: false)
        XCTAssertEqual(changedLines(config, try ConductorSettings.updating(config, from: configSettings, to: none)), ["  junctions: []"])

        var slower = configSettings
        slower.timeoutMs = 240_000
        XCTAssertEqual(changedLines(config, try ConductorSettings.updating(config, from: configSettings, to: slower)), ["  timeout_ms: 240000"])
    }

    func testInsertsTheConductorSectionWhenMissing() throws {
        XCTAssertEqual(
            try ConductorSettings.updating(
                "issues:\n  provider: linear\n",
                from: ConductorSettings(),
                to: ConductorSettings(enabled: true, junctions: [.afterQAFail], timeoutMs: 60_000)
            ),
            "issues:\n  provider: linear\nconductor:\n  enabled: true\n  junctions: [after_qa_fail]\n  timeout_ms: 60000\n"
        )
    }

    func testRefusesToWriteIntoAnInlineSection() {
        XCTAssertThrowsError(try ConductorSettings.updating("conductor: {}\n", from: ConductorSettings(), to: ConductorSettings(enabled: true))) { error in
            XCTAssertEqual(error as? ConductorSettingsError, .notABlock("conductor"))
        }
    }

    // MARK: Controls

    func testTheJunctionRowsAndTheirTitles() {
        XCTAssertEqual(ConductorJunction.allCases.map(\.rawValue), ["after_coding", "after_qa_fail", "after_qa_blocked", "after_rework", "before_merge"])
        XCTAssertEqual(ConductorJunction.allCases.map(\.title), ["After coding", "After a QA fail", "After a blocked QA", "After rework", "Before merge"])
        XCTAssertTrue(configSettings.runs(at: .afterCoding))
        XCTAssertFalse(configSettings.runs(at: .afterRework))
        XCTAssertEqual(configSettings.setting(.afterCoding, on: true), configSettings)
    }

    func testOnlyAChangedTimeLimitFieldChangesTheSetting() {
        let odd = ConductorSettings(timeoutMs: 90_500)
        XCTAssertEqual(odd.timeoutSeconds, 91)
        XCTAssertEqual(odd.setting(timeoutSeconds: 91), odd)
        XCTAssertEqual(odd.setting(timeoutSeconds: 120).timeoutMs, 120_000)
        XCTAssertEqual(ConductorSettings().timeoutSeconds, 180)
    }

    // MARK: The file

    func testReadsAndWritesTheFileOnceTheCheckPasses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("conductor-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("symphony.yml")
        try config.write(to: url, atomically: true, encoding: .utf8)
        let file = SymphonyConfigFile(path: url.path)

        XCTAssertEqual(try file.readConductorSettings(), configSettings)
        var on = configSettings
        on.junctions = Set(ConductorJunction.allCases)
        let refused = try await file.writeConductorSettings(on, from: configSettings) { _ in .failed("conductor.junctions: no") }
        XCTAssertEqual(refused, .failed("conductor.junctions: no"))
        XCTAssertEqual(try file.readConductorSettings(), configSettings)
        let passed = try await file.writeConductorSettings(on, from: configSettings) { _ in .passed }
        XCTAssertEqual(passed, .passed)
        XCTAssertEqual(try file.readConductorSettings(), on)
    }

    private func changedLines(_ before: String, _ after: String) -> [String] {
        let old = before.components(separatedBy: "\n")
        return after.components(separatedBy: "\n").filter { !old.contains($0) }
    }

    // MARK: The watch

    func testTheWatchIsOffWithItsLimitsWhenMissing() throws {
        XCTAssertEqual(try ConductorSettings.values(in: "").watch, ConductorWatchSettings())
        XCTAssertEqual(
            ConductorWatchSettings(),
            ConductorWatchSettings(enabled: false, runMinutes: 30, runTokens: 30_000_000, minIntervalMinutes: 10, maxTurnsPerRun: 3, allowStop: false)
        )
        XCTAssertEqual(ConductorWatchSettings.keyPaths.count, 6)
        XCTAssertTrue(ConductorWatchSettings.keyPaths.allSatisfy(SettingsUIManifest.keyPaths.contains))
    }

    func testReadsAndWritesTheWatchUnderConductor() throws {
        let yaml = "conductor:\n  enabled: true\n  watch:\n    enabled: true\n    run_minutes: 45\n    allow_stop: true\n"
        let read = try ConductorSettings.values(in: yaml)
        XCTAssertEqual(read.watch, ConductorWatchSettings(enabled: true, runMinutes: 45, allowStop: true))

        var changed = read
        changed.watch.maxTurnsPerRun = 1
        changed.watch.runTokens = 5_000_000
        let written = try ConductorSettings.updating(yaml, from: read, to: changed)
        XCTAssertEqual(try ConductorSettings.values(in: written), changed)
        XCTAssertTrue(written.contains("    max_turns_per_run: 1"), written)

        var on = ConductorSettings()
        on.watch.enabled = true
        let inserted = try ConductorSettings.updating("issues:\n  provider: memory\n", from: ConductorSettings(), to: on)
        XCTAssertEqual(try ConductorSettings.values(in: inserted).watch.enabled, true, inserted)
    }

    func testRefusesAWatchLimitItCantRead() {
        XCTAssertThrowsError(try ConductorSettings.values(in: "conductor:\n  watch:\n    run_minutes: soon\n"))
        XCTAssertThrowsError(try ConductorSettings.values(in: "conductor:\n  watch:\n    allow_stop: maybe\n"))
    }
}
