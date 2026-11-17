import XCTest
@testable import SymphonyBarCore

/// The per-repository `repositories[].runs` profiles, and `execution.harnesses`.
final class ScopedRunProfilesTests: XCTestCase {
    private let config = """
        # Symphony operator config.
        execution:
          # Each harness's command.
          harnesses:
            claude:
              command: claude --verbose  # launcher
              small_model:
                anthropic: claude-haiku-4-5
                # openrouter: deepseek/deepseek-flash
            # codex:
            #   command: codex app-server
          concurrency:
            max_total: 2

        runs:
          default: { harness: claude, provider: anthropic, model: claude-sonnet-5-5 }  # default
          # Plan carefully.
          breakdown: { effort: xhigh }  # big tickets

        repositories:
          # The web app.
          - key: web
            workflow: ./web.md  # web workflow
            route:
              team: ENG
            runs:
              default:
                provider: openrouter  # cheaper
                model: anthropic/claude-sonnet-4.5
              breakdown:
                provider: anthropic
                model: claude-opus-5-5

          - key: api
            workflow: ./api.md
            # api notes

        workspaces:
          root: ~/work

        """

    // MARK: Reading

    func testReadsTheRepositoryKeysAndEachRepositorysProfiles() throws {
        XCTAssertEqual(try RunProfilesConfig.repositoryKeys(in: config), ["web", "api"])

        let profiles = try RunProfilesConfig.scopedProfiles(in: config)
        XCTAssertEqual(profiles.global, RunProfiles(
            defaults: RunProfile(model: "claude-sonnet-5-5", provider: "anthropic", harness: "claude"),
            kinds: [.breakdown: RunProfile(effort: "xhigh")]
        ))
        XCTAssertEqual(profiles.repositories, [
            "web": RunProfiles(
                defaults: RunProfile(model: "anthropic/claude-sonnet-4.5", provider: "openrouter"),
                kinds: [.breakdown: RunProfile(model: "claude-opus-5-5", provider: "anthropic")]
            ),
            "api": RunProfiles(),
        ])
        XCTAssertEqual(profiles[.repository("web")], profiles.repositories["web"])
        XCTAssertEqual(profiles[.repository("missing")], RunProfiles())
        XCTAssertEqual(profiles.harnesses, [
            .claude: HarnessSettings(command: "claude --verbose", smallModels: ["anthropic": "claude-haiku-4-5"]),
        ])
    }

    func testReadsEntriesAtTheSectionsColumnAndAKeyAfterTheFirstLine() throws {
        let yaml = """
            repositories:
            - workflow: ./web.md
              key: "web"
              runs: { landing: { model: x/y } }
            - key: api
              runs:
                default: { effort: high }
            """

        XCTAssertEqual(try RunProfilesConfig.repositoryKeys(in: yaml), ["web", "api"])
        XCTAssertEqual(
            try RunProfilesConfig.profiles(in: yaml, scope: .repository("web")),
            RunProfiles(kinds: [.landing: RunProfile(model: "x/y")])
        )
        XCTAssertEqual(
            try RunProfilesConfig.profiles(in: yaml, scope: .repository("api")),
            RunProfiles(defaults: RunProfile(effort: "high"))
        )
    }

    func testNoRepositoriesMeansNoKeys() throws {
        XCTAssertEqual(try RunProfilesConfig.repositoryKeys(in: "runs:\n  default: { model: x }\n"), [])
        XCTAssertEqual(try RunProfilesConfig.repositoryKeys(in: "repositories:\nruns:\n  default: { model: x }\n"), [])
        XCTAssertEqual(try RunProfilesConfig.scopedProfiles(in: "runs:\n  default: { model: x }\n").repositories, [:])
    }

    func testRejectsRepositoryLayoutsItCannotEdit() {
        let cases: [(String, Int)] = [
            ("repositories: []\n", 1),
            ("repositories:\n  key: web\n", 2),
            ("repositories:\n  - key: web\n  other: x\n", 3),
            ("repositories:\n  -\n    key: web\n", 2),
            ("repositories:\n  - workflow: ./web.md\n", 2),
            ("repositories:\n  - key: \"\"\n", 2),
        ]
        for (yaml, line) in cases {
            XCTAssertThrowsError(try RunProfilesConfig.repositoryKeys(in: yaml), yaml) { error in
                guard case .unsupported(let errorLine, _) = error as? RunProfilesConfigError else {
                    return XCTFail("unexpected error \(error) for \(yaml)")
                }
                XCTAssertEqual(errorLine, line, yaml)
            }
        }

        let runsFirst = "repositories:\n  - runs:\n      default: { model: x }\n    key: web\n"
        XCTAssertThrowsError(try RunProfilesConfig.profiles(in: runsFirst, scope: .repository("web"))) { error in
            XCTAssertEqual(
                error as? RunProfilesConfigError,
                .unsupported(line: 2, reason: "put `key:` first, not `runs:`, on the repository's `-` line")
            )
        }
        let scalarRuns = "repositories:\n  - key: web\n    runs: lots\n"
        XCTAssertThrowsError(try RunProfilesConfig.profiles(in: scalarRuns, scope: .repository("web")))
    }

    func testUnknownRepositoryFails() {
        XCTAssertThrowsError(try RunProfilesConfig.profiles(in: config, scope: .repository("ios"))) { error in
            XCTAssertEqual(error as? RunProfilesConfigError, .repositoryNotFound("ios"))
            XCTAssertEqual(error.localizedDescription, "symphony.yml has no repository with key `ios`.")
        }
        XCTAssertThrowsError(try RunProfilesConfig.setting(.model, of: nil, to: "x", in: config, scope: .repository("ios")))
    }

    // MARK: Writing a repository

    func testWritesRepositoryFieldsKeepingCommentsAndOtherEntries() throws {
        let old = try RunProfilesConfig.scopedProfiles(in: config)
        var new = old
        let web = RunProfilesScope.repository("web")
        new[web][nil].effort = "high"
        new[web][nil].harness = "claude"
        new[web][.landing].provider = "openrouter"
        new[web][.landing].model = "openai/gpt-4o"
        new[web][.breakdown].model = "claude-opus-4-1"

        XCTAssertEqual(try RunProfilesConfig.updating(config, from: old, to: new), config.replacingOccurrences(
            of: """
                    runs:
                      default:
                        provider: openrouter  # cheaper
                        model: anthropic/claude-sonnet-4.5
                      breakdown:
                        provider: anthropic
                        model: claude-opus-5-5

                """,
            with: """
                    runs:
                      default:
                        harness: claude
                        provider: openrouter  # cheaper
                        model: anthropic/claude-sonnet-4.5
                        effort: high
                      breakdown:
                        provider: anthropic
                        model: claude-opus-4-1
                      landing:
                        provider: openrouter
                        model: openai/gpt-4o

                """
        ))
    }

    func testAddsARunsBlockToARepositoryWithout() throws {
        let old = try RunProfilesConfig.scopedProfiles(in: config)
        var new = old
        let api = RunProfilesScope.repository("api")
        new[api][.breakdown] = RunProfile(model: "claude-opus-5-5", provider: "anthropic")
        let text = try RunProfilesConfig.updating(config, from: old, to: new)

        XCTAssertTrue(text.contains("""
              - key: api
                workflow: ./api.md
                # api notes
                runs:
                  breakdown:
                    provider: anthropic
                    model: claude-opus-5-5

            workspaces:
            """), text)
        XCTAssertEqual(try RunProfilesConfig.scopedProfiles(in: text), new)
        // The repositories editor still reads the file.
        XCTAssertEqual(try RepositoriesConfig.entries(in: text).map(\.key), ["web", "api"])

        var defaults = old
        defaults[api][nil].provider = "openrouter"
        XCTAssertTrue(try RunProfilesConfig.updating(config, from: old, to: defaults).contains("""
                # api notes
                runs:
                  default:
                    provider: openrouter

            """))
    }

    func testFollowsARepositorysIndentStepAndAFlowRunsLine() throws {
        let yaml = """
            repositories:
            - key: web
              route:
                  team: ENG
            - key: api
              runs: { breakdown: { model: claude-opus-5-5 } }
            """
        var text = try RunProfilesConfig.setting(.effort, of: .landing, to: "low", in: yaml, scope: .repository("web"))
        text = try RunProfilesConfig.setting(.effort, of: .landing, to: "low", in: text, scope: .repository("api"))

        XCTAssertEqual(text, """
            repositories:
            - key: web
              route:
                  team: ENG
              runs:
                  landing:
                      effort: low
            - key: api
              runs: { breakdown: { model: claude-opus-5-5 }, landing: { effort: low } }
            """)
    }

    func testResetToInheritedRemovesTheRepositoryKeys() throws {
        let old = try RunProfilesConfig.scopedProfiles(in: config)
        let web = RunProfilesScope.repository("web")
        var row = old
        row[web][.breakdown] = RunProfile()

        XCTAssertEqual(try RunProfilesConfig.updating(config, from: old, to: row), config.replacingOccurrences(
            of: "      breakdown:\n        provider: anthropic\n        model: claude-opus-5-5\n",
            with: ""
        ))

        var all = old
        all[web] = RunProfiles()
        let cleared = try RunProfilesConfig.updating(config, from: old, to: all)
        XCTAssertTrue(cleared.contains("""
                route:
                  team: ENG

              - key: api
            """), cleared)
        var expected = old
        expected.repositories = ["web": RunProfiles(), "api": RunProfiles()]
        XCTAssertEqual(try RunProfilesConfig.scopedProfiles(in: cleared), expected)
    }

    func testRemovingAMissingRepositoryFieldChangesNothing() throws {
        XCTAssertEqual(try RunProfilesConfig.setting(.model, of: .qa, to: nil, in: config, scope: .repository("api")), config)
        XCTAssertEqual(try RunProfilesConfig.setting(.effort, of: nil, to: nil, in: config, scope: .repository("web")), config)
    }

    func testAnUntouchedFileRoundTripsByteForByte() throws {
        let profiles = try RunProfilesConfig.scopedProfiles(in: config)
        XCTAssertEqual(try RunProfilesConfig.updating(config, from: profiles, to: profiles), config)

        // Writing a value and then the original back gives the same text.
        var changed = profiles
        changed[.repository("web")][.breakdown].effort = "max"
        changed[.repository("api")][.qa].harness = "codex"
        changed[.codex].command = "codex app-server"
        changed[.claude].smallModels["openrouter"] = "deepseek/deepseek-flash"
        let there = try RunProfilesConfig.updating(config, from: profiles, to: changed)
        XCTAssertNotEqual(there, config)
        XCTAssertEqual(try RunProfilesConfig.scopedProfiles(in: there), changed)
        XCTAssertEqual(try RunProfilesConfig.updating(there, from: changed, to: profiles), config)
    }

    // MARK: Harnesses

    func testWritesAHarnessCommandAndSmallModelsKeepingComments() throws {
        var text = try RunProfilesConfig.settingCommand("claude --dangerously-skip-permissions", of: .claude, in: config)
        text = try RunProfilesConfig.settingSmallModel("deepseek/deepseek-flash", of: .claude, on: "openrouter", in: text)
        text = try RunProfilesConfig.settingSmallModel("claude-haiku-5-5", of: .claude, on: "anthropic", in: text)
        text = try RunProfilesConfig.settingCommand("codex app-server", of: .codex, in: text)
        text = try RunProfilesConfig.settingSmallModel("glm-5.3-flash", of: .opencode, on: "opencode-go", in: text)

        XCTAssertEqual(text, config.replacingOccurrences(
            of: """
                    claude:
                      command: claude --verbose  # launcher
                      small_model:
                        anthropic: claude-haiku-4-5
                        # openrouter: deepseek/deepseek-flash
                    # codex:
                    #   command: codex app-server

                """,
            with: """
                    claude:
                      command: "claude --dangerously-skip-permissions"  # launcher
                      small_model:
                        anthropic: claude-haiku-5-5
                        openrouter: deepseek/deepseek-flash
                        # openrouter: deepseek/deepseek-flash
                    codex:
                      command: "codex app-server"
                    opencode:
                      small_model:
                        opencode-go: glm-5.3-flash
                    # codex:
                    #   command: codex app-server

                """
        ))
        XCTAssertEqual(try RunProfilesConfig.harnesses(in: text), [
            .claude: HarnessSettings(
                command: "claude --dangerously-skip-permissions",
                smallModels: ["anthropic": "claude-haiku-5-5", "openrouter": "deepseek/deepseek-flash"]
            ),
            .codex: HarnessSettings(command: "codex app-server"),
            .opencode: HarnessSettings(smallModels: ["opencode-go": "glm-5.3-flash"]),
        ])
    }

    func testRemovesAHarnessSettingAndTheParentsItEmptied() throws {
        let yaml = "execution:\n  harnesses:\n    claude:\n      small_model:\n        anthropic: x\n  limits:\n    max_turns: 8\n"

        XCTAssertEqual(
            try RunProfilesConfig.settingSmallModel(nil, of: .claude, on: "anthropic", in: yaml),
            "execution:\n  limits:\n    max_turns: 8\n"
        )
        XCTAssertEqual(try RunProfilesConfig.settingSmallModel(nil, of: .claude, on: "openrouter", in: yaml), yaml)
        XCTAssertEqual(try RunProfilesConfig.settingCommand(nil, of: .codex, in: yaml), yaml)
        XCTAssertEqual(try RunProfilesConfig.settingSmallModel("x", of: .claude, on: "anthropic", in: yaml), yaml)
    }

    func testAddsTheExecutionSectionForAHarness() throws {
        XCTAssertEqual(
            try RunProfilesConfig.settingCommand("codex app-server", of: .codex, in: "workspaces:\n  root: ~/work\n"),
            "workspaces:\n  root: ~/work\nexecution:\n  harnesses:\n    codex:\n      command: \"codex app-server\"\n"
        )
        XCTAssertEqual(
            try RunProfilesConfig.settingSmallModel("x/y", of: .claude, on: "openrouter", in: "execution:\n    limits:\n        max_turns: 8\n"),
            "execution:\n    limits:\n        max_turns: 8\n    harnesses:\n        claude:\n            small_model:\n                openrouter: x/y\n"
        )
        XCTAssertEqual(try RunProfilesConfig.settingCommand(nil, of: .codex, in: "workspaces: {}\n"), "workspaces: {}\n")
        XCTAssertEqual(try RunProfilesConfig.harnesses(in: "workspaces: {}\n"), [:])
    }

    func testReadsAndWritesHarnessesInFlowStyle() throws {
        let yaml = "execution:\n  harnesses:\n    claude: { command: claude, small_model: { anthropic: a } }  # one line\n    opencode:\n      small_model: {}\n"
        XCTAssertEqual(try RunProfilesConfig.harnesses(in: yaml), [
            .claude: HarnessSettings(command: "claude", smallModels: ["anthropic": "a"]),
        ])

        var text = try RunProfilesConfig.settingSmallModel("o/r", of: .claude, on: "openrouter", in: yaml)
        text = try RunProfilesConfig.settingSmallModel("glm", of: .opencode, on: "opencode-go", in: text)
        XCTAssertEqual(
            text,
            "execution:\n  harnesses:\n    claude: { command: claude, small_model: { anthropic: a, openrouter: o/r } }  # one line\n"
                + "    opencode:\n      small_model: { opencode-go: glm }\n"
        )
        text = try RunProfilesConfig.settingSmallModel(nil, of: .claude, on: "anthropic", in: text)
        text = try RunProfilesConfig.settingSmallModel(nil, of: .claude, on: "openrouter", in: text)
        text = try RunProfilesConfig.settingCommand(nil, of: .claude, in: text)
        text = try RunProfilesConfig.settingSmallModel(nil, of: .opencode, on: "opencode-go", in: text)
        XCTAssertEqual(text, "")
    }

    func testRejectsHarnessLayoutsItCannotEdit() {
        let cases = [
            "execution:\n  harnesses: many\n",
            "execution:\n  harnesses:\n    claude:\n      command: [claude]\n",
            "execution:\n  harnesses:\n    claude:\n      small_model: haiku\n",
            "execution:\n  harnesses:\n    claude: { small_model: haiku }\n",
            "execution:\n  harnesses:\n    claude: { command: { a: b } }\n",
        ]
        for yaml in cases {
            XCTAssertThrowsError(try RunProfilesConfig.harnesses(in: yaml), yaml) { error in
                guard case .unsupported = error as? RunProfilesConfigError else { return XCTFail("unexpected error \(error) for \(yaml)") }
            }
        }
    }

    func testEmptyHarnessSettingsReadAsMissing() {
        var profiles = ScopedRunProfiles()
        profiles[.codex].command = "codex"
        XCTAssertEqual(profiles.harnesses, [.codex: HarnessSettings(command: "codex")])
        profiles[.codex].command = nil
        XCTAssertEqual(profiles.harnesses, [:])
    }

    func testProvidersInUseFollowHowEachRowResolves() throws {
        XCTAssertEqual(try RunProfilesConfig.scopedProfiles(in: config).providersInUse, [.claude: ["anthropic", "openrouter"]])
        XCTAssertEqual(ScopedRunProfiles().providersInUse, [:])

        let mixed = ScopedRunProfiles(
            global: RunProfiles(
                defaults: RunProfile(provider: "anthropic", harness: "claude"),
                kinds: [.codeReview: RunProfile(provider: "openai", harness: "codex"), .qa: RunProfile(harness: "aider")]
            ),
            repositories: ["web": RunProfiles(kinds: [.landing: RunProfile(provider: "opencode-go", harness: "opencode")])]
        )
        XCTAssertEqual(mixed.providersInUse, [.claude: ["anthropic"], .codex: ["openai"], .opencode: ["opencode-go"]])
    }

    // MARK: Inherited values

    func testInheritedFollowsSymphonysResolutionOrder() {
        let profiles = ScopedRunProfiles(
            global: RunProfiles(
                defaults: RunProfile(model: "claude-sonnet-5-5", provider: "anthropic", harness: "claude", command: "never"),
                kinds: [.landing: RunProfile(model: "claude-haiku-4-5-20251001", effort: "low", command: "claude --fast")]
            ),
            repositories: ["web": RunProfiles(
                defaults: RunProfile(model: "x/y", provider: "openrouter"),
                kinds: [.breakdown: RunProfile(model: "claude-opus-5-5")]
            )]
        )
        let web = RunProfilesScope.repository("web")

        // Nothing is built in.
        XCTAssertEqual(profiles.inherited(nil, in: .global), RunProfile())
        // A command is a run kind's own, never the default entry's.
        XCTAssertEqual(
            profiles.inherited(.landing, in: .global),
            RunProfile(model: "claude-sonnet-5-5", provider: "anthropic", harness: "claude")
        )
        XCTAssertEqual(
            profiles.inherited(nil, in: web),
            RunProfile(model: "claude-sonnet-5-5", provider: "anthropic", harness: "claude")
        )
        // The repository's defaults win over the top-level kind, field by field.
        XCTAssertEqual(
            profiles.inherited(.landing, in: web),
            RunProfile(model: "x/y", effort: "low", provider: "openrouter", harness: "claude", command: "claude --fast")
        )
        XCTAssertEqual(
            profiles.inherited(.breakdown, in: .repository("api")),
            RunProfile(model: "claude-sonnet-5-5", provider: "anthropic", harness: "claude")
        )
    }

    // MARK: File

    func testFileWritesOnlyOnceTheCheckPasses() async throws {
        let directory = uniqueTemporaryDirectory("scoped-run-profiles")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("symphony.yml").path
        try config.write(toFile: path, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let file = SymphonyConfigFile(path: path)

        let old = try file.readScopedRunProfiles()
        var new = old
        new[.repository("web")][.landing].model = "acme/chat-only"
        var checked: [String] = []

        let failed = try await file.writeRunProfiles(new, from: old) { candidate in
            checked.append(candidate)
            XCTAssertEqual(URL(fileURLWithPath: candidate).deletingLastPathComponent().path, directory.path)
            XCTAssertEqual(try? RunProfilesConfig.scopedProfiles(in: String(contentsOfFile: candidate, encoding: .utf8)), new)
            return .failed("Config error in \(candidate): repositories[web].runs.landing.model: no tools")
        }
        // The check ran on a hidden copy, but the message names symphony.yml.
        XCTAssertEqual(failed, .failed("Config error in \(path): repositories[web].runs.landing.model: no tools"))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), config)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["symphony.yml"])

        let passed = try await file.writeRunProfiles(new, from: old) { candidate in
            checked.append(candidate)
            return .passed
        }
        XCTAssertEqual(passed, .passed)
        XCTAssertEqual(try file.readScopedRunProfiles(), new)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["symphony.yml"])
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)

        // Nothing to write: no check, and the file stays byte for byte.
        let written = try String(contentsOfFile: path, encoding: .utf8)
        let unchanged = try await file.writeRunProfiles(new, from: new) { candidate in
            checked.append(candidate)
            return .failed("not run")
        }
        XCTAssertEqual(unchanged, .passed)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), written)
        XCTAssertEqual(checked.count, 2)
    }
}
