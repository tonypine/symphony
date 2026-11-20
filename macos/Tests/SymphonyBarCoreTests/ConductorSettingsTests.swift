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
        let defaults = ConductorSettings(enabled: false, junctions: Set(ConductorJunction.settable), timeoutMs: 180_000)
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

    /// A missing `junctions` runs it at every junction, the ones a later release adds too; a list freezes it.
    func testEveryJunctionOnWritesNoListAndOneOffWritesTheList() throws {
        let all = Set(ConductorJunction.settable)
        var everyOn = configSettings
        everyOn.junctions = all
        let withoutKey = try ConductorSettings.updating(config, from: configSettings, to: everyOn)
        XCTAssertEqual(withoutKey, config.replacingOccurrences(of: "  junctions: [after_coding, before_merge]\n", with: ""))
        XCTAssertEqual(try ConductorSettings.values(in: withoutKey), everyOn)

        // A block list goes with its items.
        let block = "conductor:\n  enabled: true\n  junctions:\n    - after_coding\n    # the last one\n  timeout_ms: 120000\n"
        XCTAssertEqual(
            try ConductorSettings.updating(block, from: ConductorSettings.values(in: block), to: everyOn),
            "conductor:\n  enabled: true\n  timeout_ms: 120000\n"
        )

        // No key and one junction off: the list of the rest.
        let oneOff = everyOn.setting(.grooming, on: false)
        XCTAssertEqual(
            changedLines(withoutKey, try ConductorSettings.updating(withoutKey, from: everyOn, to: oneOff)),
            ["  junctions: " + ConductorSettings.inline(oneOff.junctions)]
        )
        // No key and nothing off: nothing to write.
        var slower = everyOn
        slower.timeoutMs = 240_000
        XCTAssertFalse(try ConductorSettings.updating(withoutKey, from: everyOn, to: slower).contains("junctions:"))
    }

    /// A list written before a release added junctions shows them off: the file says so.
    func testAListReadsAsItSaysWithNoNewerJunctionOn() throws {
        let older = "conductor:\n  junctions: [after_coding, after_qa_fail, after_qa_blocked, after_rework, before_merge]\n"
        let read = try ConductorSettings.values(in: older)
        XCTAssertEqual(read.junctions, [.afterCoding, .afterQAFail, .afterQABlocked, .afterRework, .beforeMerge])
        XCTAssertFalse(read.runs(at: .grooming))
        // Turning the rest on drops the list.
        var everyOn = read
        everyOn.junctions = Set(ConductorJunction.settable)
        XCTAssertFalse(try ConductorSettings.updating(older, from: read, to: everyOn).contains("junctions"))
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

    // MARK: Grooming and the final check

    func testReadsAndWritesGroomingsTimeLimitAndTheFinalCheckRounds() throws {
        XCTAssertEqual(ConductorSettings().groomingTimeoutMs, 600_000)
        XCTAssertEqual(ConductorSettings().groomingTimeoutSeconds, 600)
        XCTAssertEqual(ConductorSettings().finalCheckRounds, 3)
        XCTAssertEqual(try ConductorSettings.values(in: config).groomingTimeoutMs, 600_000)

        let read = try ConductorSettings.values(in: "conductor:\n  grooming_timeout_ms: 300_500\n  final_check_rounds: 5\n")
        XCTAssertEqual([read.groomingTimeoutMs, read.finalCheckRounds], [300_500, 5])
        // An untouched field keeps a limit that is no whole number of seconds.
        XCTAssertEqual(read.groomingTimeoutSeconds, 301)
        XCTAssertEqual(read.setting(groomingTimeoutSeconds: 301), read)
        XCTAssertEqual(read.setting(groomingTimeoutSeconds: 900).groomingTimeoutMs, 900_000)
        XCTAssertThrowsError(try ConductorSettings.values(in: "conductor:\n  final_check_rounds: many\n")) { error in
            XCTAssertEqual(error as? ConductorSettingsError, .unreadable(key: "conductor.final_check_rounds", value: "many"))
        }

        var changed = configSettings
        changed.groomingTimeoutMs = 900_000
        changed.finalCheckRounds = 1
        let written = try ConductorSettings.updating(config, from: configSettings, to: changed)
        XCTAssertEqual(try ConductorSettings.values(in: written), changed)
        XCTAssertEqual(
            Set(written.components(separatedBy: "\n")).subtracting(config.components(separatedBy: "\n")),
            ["  grooming_timeout_ms: 900000", "  final_check_rounds: 1"]
        )
    }

    /// Symphony refuses a `grooming_timeout_ms` or a `final_check_rounds` that is not above zero.
    func testGroomingsTimeLimitAndTheFinalCheckRoundsStayAboveZero() {
        let settings = ConductorSettings(groomingTimeoutMs: 300_000, finalCheckRounds: 4)
        for refused in [0, -1] {
            XCTAssertEqual(settings.setting(groomingTimeoutSeconds: refused), settings)
            XCTAssertEqual(settings.setting(finalCheckRounds: refused), settings)
        }
        XCTAssertEqual(settings.setting(groomingTimeoutSeconds: 1).groomingTimeoutMs, 1_000)
        XCTAssertEqual(settings.setting(finalCheckRounds: 1).finalCheckRounds, 1)
    }

    // MARK: Controls

    func testTheJunctionRowsAndTheirTitles() {
        XCTAssertEqual(
            ConductorJunction.settable.map(\.rawValue),
            [
                "grooming", "after_coding", "after_qa_fail", "after_qa_blocked", "after_rework", "before_merge", "message", "sub_ticket_ended",
                "final_check", "child_message",
            ]
        )
        XCTAssertEqual(
            ConductorJunction.settable.map(\.title),
            [
                "Grooming a new ticket", "After coding", "After a QA fail", "After a blocked QA", "After rework", "Before merge",
                "On a message from you", "After a sub-ticket ends", "At the final check", "On a message to a sub-ticket",
            ]
        )
        // While it watches a run the Conductor names `during_run`, which is no setting.
        XCTAssertEqual(ConductorJunction.allCases.filter { !ConductorJunction.settable.contains($0) }, [.duringRun])
        XCTAssertThrowsError(try ConductorSettings.values(in: "conductor:\n  junctions: [during_run]\n")) { error in
            XCTAssertEqual(error as? ConductorSettingsError, .unknownJunction("during_run"))
        }
        XCTAssertEqual(ConductorSettings.inline(Set(ConductorJunction.allCases)).contains("during_run"), false)
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
        on.junctions = Set(ConductorJunction.settable)
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

    // MARK: Filing linked tickets

    func testFilesTicketsTwoPerTicketWhenMissing() throws {
        let read = try ConductorSettings.values(in: "")
        XCTAssertTrue(read.fileTickets)
        XCTAssertEqual(read.maxFiledTickets, 2)
        XCTAssertTrue(SettingsUIManifest.keyPaths.contains("conductor.file_tickets"))
        XCTAssertTrue(SettingsUIManifest.keyPaths.contains("conductor.max_filed_tickets"))
    }

    func testReadsAndWritesTheFilingSettings() throws {
        let yaml = "conductor:\n  enabled: true\n  file_tickets: false\n  max_filed_tickets: 1\n"
        let read = try ConductorSettings.values(in: yaml)
        XCTAssertEqual(read.fileTickets, false)
        XCTAssertEqual(read.maxFiledTickets, 1)

        var changed = read
        changed.fileTickets = true
        changed.maxFiledTickets = 3
        let written = try ConductorSettings.updating(yaml, from: read, to: changed)
        XCTAssertEqual(changedLines(yaml, written), ["  file_tickets: true", "  max_filed_tickets: 3"])
        XCTAssertEqual(try ConductorSettings.values(in: written), changed)

        XCTAssertThrowsError(try ConductorSettings.values(in: "conductor:\n  file_tickets: sometimes\n"))
        XCTAssertThrowsError(try ConductorSettings.values(in: "conductor:\n  max_filed_tickets: two\n"))
    }
}
