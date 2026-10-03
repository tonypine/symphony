import XCTest
@testable import SymphonyBarCore

/// `provider` and the per-repository `repositories[].agent` profiles.
final class ScopedRunProfilesTests: XCTestCase {
    private let config = """
        # Symphony operator config.
        agent:
          command: claude
          model: claude-sonnet-5-5  # default
          run_profiles:
            # Plan carefully.
            breakdown: { effort: xhigh }  # big tickets

        repositories:
          # The web app.
          - key: web
            workflow: ./web.md  # web workflow
            route:
              team: ENG
            agent:
              provider: openrouter  # cheaper
              model: anthropic/claude-sonnet-4.5
              run_profiles:
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
            defaults: RunProfile(model: "claude-sonnet-5-5"),
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
    }

    func testReadsProviderInEveryStyle() throws {
        let yaml = """
            agent:
              provider: openrouter
              run_profiles:
                landing: { provider: anthropic, effort: low }
                qa:
                  provider: "openrouter"
            """
        let profiles = try RunProfilesConfig.profiles(in: yaml)

        XCTAssertEqual(profiles.defaults, RunProfile(provider: "openrouter"))
        XCTAssertEqual(profiles.kinds, [
            .landing: RunProfile(effort: "low", provider: "anthropic"),
            .qa: RunProfile(provider: "openrouter"),
        ])
    }

    func testReadsEntriesAtTheSectionsColumnAndAKeyAfterTheFirstLine() throws {
        let yaml = """
            repositories:
            - workflow: ./web.md
              key: "web"
              agent:
                run_profiles: { landing: { model: x/y } }
            - key: api
            """

        XCTAssertEqual(try RunProfilesConfig.repositoryKeys(in: yaml), ["web", "api"])
        XCTAssertEqual(
            try RunProfilesConfig.profiles(in: yaml, scope: .repository("web")),
            RunProfiles(kinds: [.landing: RunProfile(model: "x/y")])
        )
        XCTAssertEqual(try RunProfilesConfig.profiles(in: yaml, scope: .repository("api")), RunProfiles())
    }

    func testNoRepositoriesMeansNoKeys() throws {
        XCTAssertEqual(try RunProfilesConfig.repositoryKeys(in: "agent:\n  model: x\n"), [])
        XCTAssertEqual(try RunProfilesConfig.repositoryKeys(in: "repositories:\nagent:\n  model: x\n"), [])
        XCTAssertEqual(try RunProfilesConfig.scopedProfiles(in: "agent:\n  model: x\n").repositories, [:])
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

        let agentFirst = "repositories:\n  - agent:\n      model: x\n    key: web\n"
        XCTAssertThrowsError(try RunProfilesConfig.profiles(in: agentFirst, scope: .repository("web"))) { error in
            XCTAssertEqual(
                error as? RunProfilesConfigError,
                .unsupported(line: 2, reason: "put `key:` first, not `agent:`, on the repository's `-` line")
            )
        }
        let flowAgent = "repositories:\n  - key: web\n    agent: { model: x }\n"
        XCTAssertThrowsError(try RunProfilesConfig.profiles(in: flowAgent, scope: .repository("web")))
    }

    func testUnknownRepositoryFails() {
        XCTAssertThrowsError(try RunProfilesConfig.profiles(in: config, scope: .repository("ios"))) { error in
            XCTAssertEqual(error as? RunProfilesConfigError, .repositoryNotFound("ios"))
            XCTAssertEqual(error.localizedDescription, "symphony.yml has no repository with key `ios`.")
        }
        XCTAssertThrowsError(try RunProfilesConfig.setting(.model, of: nil, to: "x", in: config, scope: .repository("ios")))
    }

    // MARK: Writing the provider

    func testWritesProviderFirstInEveryStyle() throws {
        let yaml = """
            agent:
              command: claude  # launcher
              effort: low
              run_profiles:
                breakdown: { effort: xhigh }  # big tickets
                landing:
                  effort: low

            """
        var text = try RunProfilesConfig.setting(.provider, of: nil, to: "openrouter", in: yaml)
        text = try RunProfilesConfig.setting(.provider, of: .breakdown, to: "anthropic", in: text)
        text = try RunProfilesConfig.setting(.model, of: .breakdown, to: "claude-opus-5-5", in: text)
        text = try RunProfilesConfig.setting(.provider, of: .landing, to: "openrouter", in: text)
        text = try RunProfilesConfig.setting(.provider, of: .qa, to: "openrouter", in: text)

        XCTAssertEqual(text, """
            agent:
              command: claude  # launcher
              provider: openrouter
              effort: low
              run_profiles:
                breakdown: { provider: anthropic, model: claude-opus-5-5, effort: xhigh }  # big tickets
                landing:
                  provider: openrouter
                  effort: low
                qa: { provider: openrouter }

            """)
        XCTAssertEqual(try RunProfilesConfig.profiles(in: text).kinds[.breakdown], RunProfile(
            model: "claude-opus-5-5", effort: "xhigh", provider: "anthropic"
        ))
    }

    func testAProviderAloneDoesNotMoveCommandFlags() throws {
        let yaml = "agent:\n  command: claude --model claude-opus-5-5\n"
        var new = RunProfiles()
        new.defaults.provider = "anthropic"

        XCTAssertEqual(
            try RunProfilesConfig.updating(yaml, from: RunProfiles(), to: new),
            "agent:\n  command: claude --model claude-opus-5-5\n  provider: anthropic\n"
        )
    }

    // MARK: Writing a repository

    func testWritesRepositoryFieldsKeepingCommentsAndOtherEntries() throws {
        let old = try RunProfilesConfig.scopedProfiles(in: config)
        var new = old
        let web = RunProfilesScope.repository("web")
        new[web][nil].effort = "high"
        new[web][.landing].provider = "openrouter"
        new[web][.landing].model = "openai/gpt-4o"
        new[web][.breakdown].model = "claude-opus-4-1"

        XCTAssertEqual(try RunProfilesConfig.updating(config, from: old, to: new), """
            # Symphony operator config.
            agent:
              command: claude
              model: claude-sonnet-5-5  # default
              run_profiles:
                # Plan carefully.
                breakdown: { effort: xhigh }  # big tickets

            repositories:
              # The web app.
              - key: web
                workflow: ./web.md  # web workflow
                route:
                  team: ENG
                agent:
                  provider: openrouter  # cheaper
                  model: anthropic/claude-sonnet-4.5
                  effort: high
                  run_profiles:
                    breakdown:
                      provider: anthropic
                      model: claude-opus-4-1
                    landing:
                      provider: openrouter
                      model: openai/gpt-4o

              - key: api
                workflow: ./api.md
                # api notes

            workspaces:
              root: ~/work

            """)
    }

    func testAddsAnAgentBlockToARepositoryWithout() throws {
        let old = try RunProfilesConfig.scopedProfiles(in: config)
        var new = old
        let api = RunProfilesScope.repository("api")
        new[api][.breakdown] = RunProfile(model: "claude-opus-5-5", provider: "anthropic")
        let text = try RunProfilesConfig.updating(config, from: old, to: new)

        XCTAssertTrue(text.contains("""
              - key: api
                workflow: ./api.md
                # api notes
                agent:
                  run_profiles:
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
                agent:
                  provider: openrouter

            """))
    }

    func testFollowsARepositorysIndentStepAndFlowKinds() throws {
        let yaml = """
            repositories:
            - key: web
              route:
                  team: ENG
            - key: api
              agent:
                  run_profiles: { breakdown: { model: claude-opus-5-5 } }
            """
        var text = try RunProfilesConfig.setting(.effort, of: .landing, to: "low", in: yaml, scope: .repository("web"))
        text = try RunProfilesConfig.setting(.effort, of: .landing, to: "low", in: text, scope: .repository("api"))

        XCTAssertEqual(text, """
            repositories:
            - key: web
              route:
                  team: ENG
              agent:
                  run_profiles:
                      landing:
                          effort: low
            - key: api
              agent:
                  run_profiles: { breakdown: { model: claude-opus-5-5 }, landing: { effort: low } }
            """)
    }

    func testResetToInheritedRemovesTheRepositoryKeys() throws {
        let old = try RunProfilesConfig.scopedProfiles(in: config)
        let web = RunProfilesScope.repository("web")
        var row = old
        row[web][.breakdown] = RunProfile()

        XCTAssertEqual(try RunProfilesConfig.updating(config, from: old, to: row), """
            # Symphony operator config.
            agent:
              command: claude
              model: claude-sonnet-5-5  # default
              run_profiles:
                # Plan carefully.
                breakdown: { effort: xhigh }  # big tickets

            repositories:
              # The web app.
              - key: web
                workflow: ./web.md  # web workflow
                route:
                  team: ENG
                agent:
                  provider: openrouter  # cheaper
                  model: anthropic/claude-sonnet-4.5

              - key: api
                workflow: ./api.md
                # api notes

            workspaces:
              root: ~/work

            """)

        var all = old
        all[web] = RunProfiles()
        let cleared = try RunProfilesConfig.updating(config, from: old, to: all)
        XCTAssertTrue(cleared.contains("""
                route:
                  team: ENG

              - key: api
            """), cleared)
        XCTAssertEqual(try RunProfilesConfig.scopedProfiles(in: cleared), ScopedRunProfiles(
            global: old.global,
            repositories: ["web": RunProfiles(), "api": RunProfiles()]
        ))
    }

    func testRemovingAMissingRepositoryFieldChangesNothing() throws {
        XCTAssertEqual(try RunProfilesConfig.setting(.model, of: .qa, to: nil, in: config, scope: .repository("api")), config)
        XCTAssertEqual(try RunProfilesConfig.setting(.effort, of: nil, to: nil, in: config, scope: .repository("web")), config)
    }

    func testARepositoryProfileMovesTheCommandFlags() throws {
        let yaml = """
            agent:
              command: claude --model claude-opus-5-5
            pre_push_review:
              command: claude --effort high
            repositories:
              - key: web
            """
        var new = ScopedRunProfiles(repositories: ["web": RunProfiles()])
        new[.repository("web")][.landing].effort = "low"

        XCTAssertEqual(try RunProfilesConfig.updating(yaml, from: ScopedRunProfiles(repositories: ["web": RunProfiles()]), to: new), """
            agent:
              command: claude
              model: claude-opus-5-5
            pre_push_review:
              command: claude
              effort: high
            repositories:
              - key: web
                agent:
                  run_profiles:
                    landing:
                      effort: low
            """)
    }

    func testAnUntouchedFileRoundTripsByteForByte() throws {
        let profiles = try RunProfilesConfig.scopedProfiles(in: config)
        XCTAssertEqual(try RunProfilesConfig.updating(config, from: profiles, to: profiles), config)

        // Writing a value and then the original back gives the same text.
        var changed = profiles
        changed[.repository("web")][.breakdown].effort = "max"
        let there = try RunProfilesConfig.updating(config, from: profiles, to: changed)
        XCTAssertNotEqual(there, config)
        XCTAssertEqual(try RunProfilesConfig.updating(there, from: changed, to: profiles), config)
    }

    // MARK: Inherited values

    func testInheritedFollowsSymphonysResolutionOrder() {
        let profiles = ScopedRunProfiles(
            global: RunProfiles(
                defaults: RunProfile(model: "claude-sonnet-5-5"),
                kinds: [.landing: RunProfile(model: "claude-haiku-4-5-20251001", effort: "low")]
            ),
            repositories: ["web": RunProfiles(
                defaults: RunProfile(model: "x/y", provider: "openrouter"),
                kinds: [.breakdown: RunProfile(model: "claude-opus-5-5")]
            )]
        )
        let command = RunProfile(model: "opus", effort: "high")
        let web = RunProfilesScope.repository("web")

        XCTAssertEqual(profiles.inherited(nil, in: .global, command: command), RunProfile(model: "opus", effort: "high", provider: "anthropic"))
        XCTAssertEqual(
            profiles.inherited(.landing, in: .global, command: command),
            RunProfile(model: "claude-sonnet-5-5", effort: "high", provider: "anthropic")
        )
        XCTAssertEqual(
            profiles.inherited(nil, in: web, command: RunProfile()),
            RunProfile(model: "claude-sonnet-5-5", provider: "anthropic")
        )
        // The repository's defaults win over the top-level kind, field by field.
        XCTAssertEqual(
            profiles.inherited(.landing, in: web, command: RunProfile()),
            RunProfile(model: "x/y", effort: "low", provider: "openrouter")
        )
        XCTAssertEqual(
            profiles.inherited(.breakdown, in: .repository("api"), command: RunProfile()),
            RunProfile(model: "claude-sonnet-5-5", provider: "anthropic")
        )
    }

    func testDefaultTitleNamesWhereTheValueComesFrom() {
        XCTAssertEqual(
            RunProfilesConfig.defaultTitle(RunProfilesConfig.providers, inherited: "anthropic", source: "inherited"),
            "Anthropic, inherited"
        )
        XCTAssertEqual(RunProfilesConfig.defaultTitle(RunProfilesConfig.models, inherited: "x/y", source: "inherited"), "x/y, inherited")
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
            return .failed("Config error: repositories[web].agent.run_profiles.landing.model: no tools")
        }
        XCTAssertEqual(failed, .failed("Config error: repositories[web].agent.run_profiles.landing.model: no tools"))
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
