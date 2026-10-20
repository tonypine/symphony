import XCTest
@testable import SymphonyBarCore

final class MacAppQAPlaybookTests: XCTestCase {
    private let config = """
        # Symphony operator config.
        auto_review:
          worker_host: qa@qa-vm.local
          playbooks:
            macos_app:
              build: make -C macos app
              app: macos/build/App.app
              dev_server: true  # the hub
              dev_server_port: 8_091
              launch_env:
                HUB_OWNER_TOKEN: abc
                "HUB_URL": "http://127.0.0.1:$SYMPHONY_VERIFICATION_PORT/"  # quoted
                HUB_NOTE: 'it''s fine'
            web:
              enabled: false

        workspaces:
          root: ~/work

        """

    private let configPlaybook = MacAppQAPlaybook(
        devServer: true,
        devServerPort: 8091,
        launchEnv: [
            LaunchVariable(name: "HUB_OWNER_TOKEN", value: "abc"),
            LaunchVariable(name: "HUB_URL", value: "http://127.0.0.1:$SYMPHONY_VERIFICATION_PORT/"),
            LaunchVariable(name: "HUB_NOTE", value: "it's fine"),
        ]
    )

    // MARK: Reading

    func testReadsTheSettings() throws {
        XCTAssertEqual(try MacAppQAPlaybook.values(in: config), configPlaybook)
    }

    func testMissingEmptyAndNullKeysReadAsSymphonysDefaults() throws {
        let defaults = MacAppQAPlaybook(devServer: false, devServerPort: 8090, launchEnv: [])
        XCTAssertEqual(MacAppQAPlaybook(), defaults)
        for yaml in [
            "",
            "auto_review:\n  playbooks: {}\n",
            "auto_review:\n  playbooks:\n    macos_app:\n      build: make\n",
            "auto_review:\n  playbooks:\n    macos_app: ~\n",
            "auto_review:\n  playbooks:\n    macos_app:\n      dev_server: null\n      dev_server_port: ~\n      launch_env: {}\n",
            "auto_review:\n  playbooks:\n    macos_app:\n      launch_env:\n        # none yet\n",
        ] {
            XCTAssertEqual(try MacAppQAPlaybook.values(in: yaml), defaults, yaml)
        }
        XCTAssertFalse(try MacAppQAPlaybook.values(in: "auto_review:\n  playbooks:\n    macos_app:\n      dev_server: false\n").devServer)
    }

    func testRefusesValuesItCannotRead() {
        for (yaml, expected) in [
            ("auto_review:\n  playbooks: {macos_app: {}}\n", MacAppQAPlaybookError.notABlock("playbooks")),
            ("auto_review:\n  playbooks:\n    macos_app:\n      launch_env: {A: b}\n", .notABlock("launch_env")),
            ("auto_review:\n  playbooks:\n    macos_app:\n      dev_server: yes\n", .unreadable(key: "dev_server", value: "yes")),
            ("auto_review:\n  playbooks:\n    macos_app:\n      dev_server_port: soon\n", .unreadable(key: "dev_server_port", value: "soon")),
            ("auto_review:\n  playbooks:\n    macos_app:\n      launch_env:\n        - A\n", .unreadable(key: "launch_env", value: "- A")),
            ("auto_review:\n  playbooks:\n    macos_app:\n      launch_env:\n        A: |\n          long\n", .unreadable(key: "launch_env", value: "long")),
            ("auto_review:\n  playbooks:\n    macos_app:\n      launch_env:\n        A: \"open\n", .unreadable(key: "launch_env.A", value: "\"open")),
            ("auto_review:\n  playbooks:\n    macos_app:\n      launch_env:\n        A: \"\\q\"\n", .unreadable(key: "launch_env.A", value: "\"\\q\"")),
        ] {
            XCTAssertThrowsError(try MacAppQAPlaybook.values(in: yaml), yaml) { error in
                XCTAssertEqual(error as? MacAppQAPlaybookError, expected, yaml)
            }
        }
        XCTAssertEqual(
            MacAppQAPlaybookError.notABlock("playbooks").errorDescription,
            "`playbooks:` in symphony.yml is not an indented block. Change the macOS app QA settings by hand."
        )
        XCTAssertEqual(
            MacAppQAPlaybookError.unreadable(key: "dev_server", value: "yes").errorDescription,
            "`dev_server: yes` in symphony.yml can't be read here. Change it by hand."
        )
    }

    func testReadsEscapedDoubleQuotedValues() throws {
        let yaml = "auto_review:\n  playbooks:\n    macos_app:\n      launch_env:\n        A: \"say \\\"hi\\\"\\\\ \\/ \\n\\t\"\n"
        XCTAssertEqual(try MacAppQAPlaybook.values(in: yaml).launchEnv, [LaunchVariable(name: "A", value: "say \"hi\"\\ / \n\t")])
    }

    // MARK: Writing

    func testChangesOnlyTheSettingsThatDiffer() throws {
        var new = configPlaybook
        new.devServer = false
        new.devServerPort = 9000
        new.launchEnv = [LaunchVariable(name: "HUB_OWNER_TOKEN", value: "xyz"), LaunchVariable(name: "MODE", value: "8090")]
        let updated = try MacAppQAPlaybook.updating(config, from: configPlaybook, to: new)

        XCTAssertEqual(updated, """
            # Symphony operator config.
            auto_review:
              worker_host: qa@qa-vm.local
              playbooks:
                macos_app:
                  build: make -C macos app
                  app: macos/build/App.app
                  dev_server: false  # the hub
                  dev_server_port: 9000
                  launch_env:
                    HUB_OWNER_TOKEN: "xyz"
                    MODE: "8090"
                web:
                  enabled: false

            workspaces:
              root: ~/work

            """)
        XCTAssertEqual(try MacAppQAPlaybook.values(in: updated), new)
        XCTAssertEqual(try MacAppQAPlaybook.updating(config, from: configPlaybook, to: configPlaybook), config)
    }

    func testRemovingEveryVariableLeavesAnEmptyMap() throws {
        var new = configPlaybook
        new.launchEnv = []
        let updated = try MacAppQAPlaybook.updating(config, from: configPlaybook, to: new)
        XCTAssertTrue(updated.contains("      launch_env: {}\n    web:\n"))
        XCTAssertEqual(try MacAppQAPlaybook.values(in: updated), new)
    }

    func testInsertsTheSettingsAndTheSectionsAboveThem() throws {
        let new = MacAppQAPlaybook(devServer: true, devServerPort: 8091, launchEnv: [LaunchVariable(name: "HUB_OWNER_TOKEN", value: "a \"b\"")])
        for yaml in ["workspaces:\n  root: ~/work\n", "auto_review:\n  playbooks: {}\n", "auto_review:\n  playbooks:\n    macos_app: ~\n"] {
            let updated = try MacAppQAPlaybook.updating(yaml, from: MacAppQAPlaybook(), to: new)
            XCTAssertEqual(try MacAppQAPlaybook.values(in: updated), new, updated)
            XCTAssertTrue(updated.contains("HUB_OWNER_TOKEN: \"a \\\"b\\\"\""), updated)
        }
        XCTAssertEqual(
            try MacAppQAPlaybook.updating("", from: MacAppQAPlaybook(), to: new),
            """
            auto_review:
              playbooks:
                macos_app:
                  dev_server: true
                  dev_server_port: 8091
                  launch_env:
                    HUB_OWNER_TOKEN: "a \\"b\\""

            """
        )
        let emptied = MacAppQAPlaybook(launchEnv: [])
        let withVariable = MacAppQAPlaybook(launchEnv: [LaunchVariable(name: "A", value: "b")])
        XCTAssertEqual(
            try MacAppQAPlaybook.updating("", from: withVariable, to: emptied),
            "auto_review:\n  playbooks:\n    macos_app:\n      launch_env: {}\n"
        )
    }

    func testRefusesToWriteUnderAnInlineSection() {
        let new = MacAppQAPlaybook(devServer: true)
        XCTAssertThrowsError(try MacAppQAPlaybook.updating("auto_review: {playbooks: {}}\n", from: MacAppQAPlaybook(), to: new)) { error in
            XCTAssertEqual(error as? MacAppQAPlaybookError, .notABlock("auto_review"))
        }
        let variables = MacAppQAPlaybook(launchEnv: [LaunchVariable(name: "A", value: "b")])
        let inline = "auto_review:\n  playbooks:\n    macos_app:\n      launch_env: {A: c}\n"
        XCTAssertThrowsError(try MacAppQAPlaybook.updating(inline, from: MacAppQAPlaybook(), to: variables)) { error in
            XCTAssertEqual(error as? MacAppQAPlaybookError, .notABlock("launch_env"))
        }
    }

    func testKeepsTheQAHostToolsInTheSamePlaybook() throws {
        let tools = QAHostTools(tools: ["go", "pg_ctl"])
        let withTools = try QAHostTools.updating(config, from: QAHostTools(), to: tools)
        var new = configPlaybook
        new.devServerPort = 8092
        new.launchEnv.append(LaunchVariable(name: "HUB_DEBUG", value: "1"))
        let updated = try MacAppQAPlaybook.updating(withTools, from: configPlaybook, to: new)
        XCTAssertEqual(try MacAppQAPlaybook.values(in: updated), new)
        XCTAssertEqual(try QAHostTools.values(in: updated), tools)

        let retooled = try QAHostTools.updating(updated, from: tools, to: QAHostTools(tools: ["go"]))
        XCTAssertEqual(try MacAppQAPlaybook.values(in: retooled), new)
        XCTAssertEqual(try QAHostTools.values(in: retooled), QAHostTools(tools: ["go"]))
    }

    func testTrimmedDropsBlankRowsAndTrimsNames() {
        let id = UUID()
        let playbook = MacAppQAPlaybook(launchEnv: [
            LaunchVariable(id: id, name: " HUB_OWNER_TOKEN ", value: "abc"),
            LaunchVariable(name: "  ", value: ""),
        ])
        XCTAssertEqual(playbook.trimmed().launchEnv, [LaunchVariable(name: "HUB_OWNER_TOKEN", value: "abc")])
        XCTAssertEqual(playbook.trimmed().launchEnv.first?.id, id)
    }

    // MARK: File

    func testWritesTheFileOnlyWhenTheCheckPasses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("symphony.yml").path
        try config.write(toFile: path, atomically: true, encoding: .utf8)
        let file = SymphonyConfigFile(path: path)

        XCTAssertEqual(try file.readMacAppQAPlaybook(), configPlaybook)
        var new = configPlaybook
        new.devServer = false

        let failed = try await file.writeMacAppQAPlaybook(new, from: configPlaybook) { _ in .failed("nope") }
        XCTAssertEqual(failed, .failed("nope"))
        XCTAssertEqual(try file.readMacAppQAPlaybook(), configPlaybook)

        let passed = try await file.writeMacAppQAPlaybook(new, from: configPlaybook) { _ in .passed }
        XCTAssertEqual(passed, .passed)
        XCTAssertEqual(try file.readMacAppQAPlaybook(), new)
    }
}
