import XCTest
@testable import SymphonyBarCore

final class ProjectServerTests: XCTestCase {
    private let config = """
        # Symphony operator config.
        verification:
          enabled: true
          dev_server:
            build_cmd: scripts/qa-server-build.sh
            start_cmd: "scripts/qa-server-start.sh"  # the hub
            health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/api/v1/state"
            health_timeout_ms: 600_000
            stop_signal: INT
            stop_timeout_ms: 0
            runs: live_qa_pass  # only live passes
        workspaces:
          root: ~/work

        """

    private let configServer = ProjectServerSettings(
        buildCmd: "scripts/qa-server-build.sh",
        startCmd: "scripts/qa-server-start.sh",
        healthCheckURL: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/api/v1/state",
        healthTimeoutMs: 600_000,
        stopSignal: .int,
        stopTimeoutMs: 0,
        runs: .liveQAPass
    )

    // MARK: Reading

    func testReadsTheSettings() throws {
        XCTAssertEqual(try ProjectServerSettings.values(in: config), configServer)
    }

    func testMissingEmptyAndNullKeysReadAsSymphonysDefaults() throws {
        let defaults = ProjectServerSettings()
        XCTAssertNil(defaults.buildCmd)
        XCTAssertEqual(defaults.startCmd, "")
        XCTAssertEqual(defaults.healthCheckURL, "")
        XCTAssertEqual(defaults.healthTimeoutMs, 30_000)
        XCTAssertEqual(defaults.stopSignal, .term)
        XCTAssertEqual(defaults.stopTimeoutMs, 10_000)
        XCTAssertEqual(defaults.runs, .symphonyHost)
        for yaml in [
            "",
            "verification:\n  enabled: true\n",
            "verification: {}\n",
            "verification:\n  dev_server: ~\n",
            "verification:\n  dev_server:\n    build_cmd: null\n    health_timeout_ms: ~\n    stop_signal:\n    runs: null\n",
        ] {
            XCTAssertEqual(try ProjectServerSettings.values(in: yaml), defaults, yaml)
        }
    }

    func testReadsEveryRuleAndSignal() throws {
        for rule in ProjectServerRuns.allCases {
            let yaml = "verification:\n  dev_server:\n    runs: \(rule.rawValue)\n"
            XCTAssertEqual(try ProjectServerSettings.values(in: yaml).runs, rule)
        }
        for signal in ProjectServerStopSignal.allCases {
            let yaml = "verification:\n  dev_server:\n    stop_signal: \"\(signal.rawValue)\"\n"
            XCTAssertEqual(try ProjectServerSettings.values(in: yaml).stopSignal, signal)
        }
        XCTAssertEqual(ProjectServerRuns.allCases.map(\.title), ["On Symphony's host", "Every QA pass", "Live QA passes"])
    }

    func testRefusesValuesItCannotRead() {
        for (yaml, expected) in [
            ("verification:\n  dev_server:\n    runs: sometimes\n", MacAppQAPlaybookError.unreadable(key: "dev_server.runs", value: "sometimes")),
            ("verification:\n  dev_server:\n    runs: Live_QA_Pass\n", .unreadable(key: "dev_server.runs", value: "Live_QA_Pass")),
            ("verification:\n  dev_server:\n    stop_signal: TERMINATE\n", .unreadable(key: "dev_server.stop_signal", value: "TERMINATE")),
            ("verification:\n  dev_server:\n    health_timeout_ms: 0\n", .unreadable(key: "dev_server.health_timeout_ms", value: "0")),
            ("verification:\n  dev_server:\n    stop_timeout_ms: -1\n", .unreadable(key: "dev_server.stop_timeout_ms", value: "-1")),
            ("verification:\n  dev_server: {start_cmd: x}\n", .notABlock("dev_server")),
        ] {
            XCTAssertThrowsError(try ProjectServerSettings.values(in: yaml), yaml) { error in
                XCTAssertEqual(error as? MacAppQAPlaybookError, expected, yaml)
            }
            XCTAssertThrowsError(try MacAppQAPlaybook.values(in: yaml), yaml)
        }
    }

    // MARK: Writing

    func testWritesAChangedRuleInPlace() throws {
        var new = configServer
        new.runs = .everyQAPass
        let updated = try ProjectServerSettings.updating(config, from: configServer, to: new)
        XCTAssertEqual(updated, config.replacingOccurrences(of: "runs: live_qa_pass  #", with: "runs: every_qa_pass  #"))
        XCTAssertEqual(try ProjectServerSettings.values(in: updated), new)
        XCTAssertEqual(try ProjectServerSettings.updating(config, from: configServer, to: configServer), config)
    }

    func testChangesOnlyTheSettingsThatDiffer() throws {
        var new = configServer
        new.buildCmd = nil
        new.startCmd = "make serve"
        new.stopSignal = .kill
        let updated = try ProjectServerSettings.updating(config, from: configServer, to: new)
        XCTAssertEqual(updated, """
            # Symphony operator config.
            verification:
              enabled: true
              dev_server:
                build_cmd: null
                start_cmd: "make serve"  # the hub
                health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/api/v1/state"
                health_timeout_ms: 600_000
                stop_signal: KILL
                stop_timeout_ms: 0
                runs: live_qa_pass  # only live passes
            workspaces:
              root: ~/work

            """)
        XCTAssertEqual(try ProjectServerSettings.values(in: updated), new)
    }

    func testInsertsTheSettingsInOrderAndTheSectionsAboveThem() throws {
        let new = ProjectServerSettings(
            buildCmd: "make", startCmd: "make serve", healthCheckURL: "http://127.0.0.1:8090/", healthTimeoutMs: 1_000,
            stopSignal: .hup, stopTimeoutMs: 500, runs: .everyQAPass
        )
        XCTAssertEqual(
            try ProjectServerSettings.updating("", from: ProjectServerSettings(), to: new),
            """
            verification:
              dev_server:
                build_cmd: "make"
                start_cmd: "make serve"
                health_check_url: "http://127.0.0.1:8090/"
                health_timeout_ms: 1000
                stop_signal: HUP
                stop_timeout_ms: 500
                runs: every_qa_pass

            """
        )
        for yaml in ["workspaces:\n  root: ~/work\n", "verification: {}\n", "verification:\n  enabled: true\n  dev_server: ~\n"] {
            let updated = try ProjectServerSettings.updating(yaml, from: ProjectServerSettings(), to: new)
            XCTAssertEqual(try ProjectServerSettings.values(in: updated), new, updated)
        }
        XCTAssertThrowsError(try ProjectServerSettings.updating("verification: {enabled: true}\n", from: ProjectServerSettings(), to: new)) { error in
            XCTAssertEqual(error as? MacAppQAPlaybookError, .notABlock("verification"))
        }
    }

    func testTrimmedTrimsTheTextAndTakesABlankBuildAsNone() {
        let server = ProjectServerSettings(buildCmd: "  ", startCmd: " make serve ", healthCheckURL: " http://x/ ")
        XCTAssertEqual(server.trimmed(), ProjectServerSettings(buildCmd: nil, startCmd: "make serve", healthCheckURL: "http://x/"))
    }

    // MARK: Through the macOS app QA settings

    func testTheMacOSAppQASettingsReadAndWriteTheProjectServer() throws {
        XCTAssertEqual(try MacAppQAPlaybook.values(in: config).projectServer, configServer)
        let old = try MacAppQAPlaybook.values(in: config)
        var new = old
        new.projectServer.runs = .symphonyHost
        new.devServerPort = 8091
        let updated = try MacAppQAPlaybook.updating(config, from: old, to: new)
        XCTAssertTrue(updated.contains("    runs: symphony_host  # only live passes\n"), updated)
        XCTAssertTrue(updated.contains("macos_app:\n      dev_server_port: 8091\n"), updated)
        XCTAssertEqual(try MacAppQAPlaybook.values(in: updated), new)
    }

    /// The Settings page's QA fixture holds the project's server in the new shape, run only for live QA passes.
    func testTheSettingsQAFixtureHoldsTheProjectServer() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/settings-project-server/config/symphony.yml")
        let playbook = try MacAppQAPlaybook.values(in: String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(playbook.projectServer, ProjectServerSettings(
            buildCmd: "scripts/qa-server-build.sh",
            startCmd: "scripts/qa-server-start.sh",
            healthCheckURL: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/api/v1/state",
            healthTimeoutMs: 600_000,
            runs: .liveQAPass
        ))
        XCTAssertEqual(playbook.devServerPort, 8090)
    }
}
