import XCTest
@testable import SymphonyBarCore

final class RunProfilesConfigTests: XCTestCase {
    private let config = """
        # Symphony operator config.
        issues:
          provider: linear

        execution:
          harnesses:
            claude:
              command: claude
          concurrency:
            max_total: 2

        runs:
          # Defaults for every kind of run.
          default:
            harness: claude
            model: claude-sonnet-5-5  # cheap default
            effort: medium
          # Plan carefully.
          breakdown: { effort: xhigh }  # big tickets
          landing:
            effort: low
            # model: claude-haiku-4-5-20251001

        workspaces:
          root: ~/work

        """

    // MARK: Reading

    func testReadsDefaultsAndBothStyles() throws {
        let profiles = try RunProfilesConfig.profiles(in: config)

        XCTAssertEqual(profiles.defaults, RunProfile(model: "claude-sonnet-5-5", effort: "medium", harness: "claude"))
        XCTAssertEqual(profiles.kinds, [
            .breakdown: RunProfile(effort: "xhigh"),
            .landing: RunProfile(effort: "low"),
        ])
    }

    func testReadsEveryFieldOfAnEntry() throws {
        let yaml = """
            runs:
              default: { harness: claude, provider: openrouter, model: x/y, effort: low, small_model: x/tiny }
              code_review:
                harness: codex
                provider: openai
                model: gpt-5
                command: "codex app-server"
            """
        let profiles = try RunProfilesConfig.profiles(in: yaml)

        XCTAssertEqual(profiles.defaults, RunProfile(model: "x/y", effort: "low", provider: "openrouter", harness: "claude", smallModel: "x/tiny"))
        XCTAssertEqual(profiles.kinds, [
            .codeReview: RunProfile(model: "gpt-5", provider: "openai", harness: "codex", command: "codex app-server"),
        ])
    }

    func testMissingKeysReadAsUnset() throws {
        XCTAssertEqual(try RunProfilesConfig.profiles(in: "issues:\n  provider: linear\n"), RunProfiles())
        XCTAssertEqual(try RunProfilesConfig.profiles(in: "runs:\n  default:\n    model:\n    effort: null\n"), RunProfiles())
        XCTAssertEqual(try RunProfilesConfig.profiles(in: "runs: {}\n"), RunProfiles())
        XCTAssertEqual(try RunProfilesConfig.profiles(in: "runs:\n"), RunProfiles())
    }

    func testReadsQuotedValuesAndAFlowRunsLine() throws {
        let yaml = """
            runs: {default: {model: "claude-opus-5-5", effort: 'high'}, qa: {model: "claude-haiku-4-5-20251001", effort: low}, ci_fix: {}, typo: {effort: low}}
            """
        let profiles = try RunProfilesConfig.profiles(in: yaml)

        XCTAssertEqual(profiles.defaults, RunProfile(model: "claude-opus-5-5", effort: "high"))
        XCTAssertEqual(profiles.kinds, [.qa: RunProfile(model: "claude-haiku-4-5-20251001", effort: "low")])
    }

    func testRejectsLayoutsItCannotEdit() {
        let cases = [
            "runs: lots\n",
            "runs:\n  breakdown: high\n",
            "runs: { breakdown: high }\n",
            "runs:\n  breakdown: { effort: [high] }\n",
            "runs:\n  default:\n    model: [a, b]\n",
            "runs:\n  default:\n    model:\n      nested: x\n",
            "runs:\n  default:\n    model: \"open\n",
            "runs:\n  default:\n    model: \"a\" b\n",
            "runs:\n  default:\n    model: *alias\n",
            "runs: { breakdown: { effort high } }\n",
            "runs: { breakdown: { effort: high }\n",
            "runs: { qa: [low\n",
        ]
        for yaml in cases {
            XCTAssertThrowsError(try RunProfilesConfig.profiles(in: yaml), yaml) { error in
                guard case .unsupported(let line, _) = error as? RunProfilesConfigError else {
                    return XCTFail("unexpected error \(error) for \(yaml)")
                }
                XCTAssertGreaterThan(line, 0)
            }
        }
    }

    func testErrorNamesTheLine() {
        let error = RunProfilesConfigError.unsupported(line: 3, reason: "`runs:` should be an indented block")
        XCTAssertEqual(error.errorDescription, "symphony.yml line 3: `runs:` should be an indented block. Edit models by hand.")
    }

    // MARK: Changing one value

    // MARK: Fallbacks

    private let fallbackConfig = """
        runs:
          default:
            harness: claude
            provider: anthropic
            model: claude-opus-5-5
            fallbacks:
              - { harness: opencode, provider: opencode-go, model: kimi-k3 }
              - provider: openrouter
                model: acme/chat
          landing: { model: claude-sonnet-5-5, fallbacks: [{ provider: openrouter, model: acme/flash }] }
        repositories:
          - key: web
            runs:
              qa:
                model: claude-haiku-4-5
                fallbacks:
                  - { model: claude-sonnet-5-5 }

        """

    func testReadsEntriesThatHaveFallbacks() throws {
        let scoped = try RunProfilesConfig.scopedProfiles(in: fallbackConfig)

        XCTAssertEqual(scoped.global.defaults.model, "claude-opus-5-5")
        XCTAssertEqual(scoped.global.kinds[.landing]?.model, "claude-sonnet-5-5")
        XCTAssertEqual(scoped.repositories["web"]?.kinds[.qa]?.model, "claude-haiku-4-5")
    }

    func testChangingAFieldKeepsTheEntrysFallbacks() throws {
        let old = try RunProfilesConfig.scopedProfiles(in: fallbackConfig)
        var new = old
        new.global.defaults.model = "claude-sonnet-5-5"
        new.global.kinds[.landing]?.effort = "low"
        new.repositories["web"]?.kinds[.qa]?.model = "claude-opus-5-5"

        let updated = try RunProfilesConfig.updating(fallbackConfig, from: old, to: new)

        XCTAssertTrue(updated.contains("- { harness: opencode, provider: opencode-go, model: kimi-k3 }"))
        XCTAssertTrue(updated.contains("- provider: openrouter\n        model: acme/chat"))
        XCTAssertTrue(updated.contains("fallbacks: [{ provider: openrouter, model: acme/flash }]"))
        XCTAssertTrue(updated.contains("- { model: claude-sonnet-5-5 }"))
        XCTAssertTrue(updated.contains("    model: claude-sonnet-5-5\n    fallbacks:"))
        XCTAssertTrue(updated.contains("effort: low"))
        XCTAssertTrue(updated.contains("        model: claude-opus-5-5\n        fallbacks:"))
    }

    func testChangingBreakdownEffortChangesOnlyThatLine() throws {
        let updated = try RunProfilesConfig.setting(.effort, of: .breakdown, to: "high", in: config)

        XCTAssertEqual(changedLines(config, updated), ["  breakdown: { effort: high }  # big tickets"])
        XCTAssertEqual(try RunProfilesConfig.profiles(in: updated)[.breakdown], RunProfile(effort: "high"))
    }

    func testChangingABlockValueKeepsItsComment() throws {
        let updated = try RunProfilesConfig.setting(.model, of: nil, to: "claude-opus-5-5", in: config)

        XCTAssertEqual(changedLines(config, updated), ["    model: claude-opus-5-5  # cheap default"])
        let landing = try RunProfilesConfig.setting(.effort, of: .landing, to: "medium", in: config)
        XCTAssertEqual(changedLines(config, landing), ["    effort: medium"])
    }

    func testSettingTheSameValueLeavesTheTextAlone() throws {
        XCTAssertEqual(try RunProfilesConfig.setting(.effort, of: nil, to: "medium", in: config), config)
        XCTAssertEqual(try RunProfilesConfig.setting(.effort, of: .breakdown, to: "xhigh", in: config), config)
        XCTAssertEqual(try RunProfilesConfig.setting(.model, of: .rework, to: nil, in: config), config)
        XCTAssertEqual(try RunProfilesConfig.setting(.model, of: .breakdown, to: nil, in: config), config)
        XCTAssertEqual(try RunProfilesConfig.setting(.model, of: nil, to: nil, in: "issues:\n"), "issues:\n")
    }

    func testAddsAFieldToAnExistingEntryInFieldOrder() throws {
        let flow = try RunProfilesConfig.setting(.model, of: .breakdown, to: "claude-opus-5-5", in: config)
        XCTAssertEqual(changedLines(config, flow), ["  breakdown: { model: claude-opus-5-5, effort: xhigh }  # big tickets"])

        let block = try RunProfilesConfig.setting(.model, of: .landing, to: "claude-haiku-4-5-20251001", in: config)
        XCTAssertEqual(block, config.replacingOccurrences(
            of: "  landing:\n",
            with: "  landing:\n    model: claude-haiku-4-5-20251001\n"
        ))

        let provider = try RunProfilesConfig.setting(.provider, of: nil, to: "anthropic", in: config)
        XCTAssertEqual(provider, config.replacingOccurrences(
            of: "    harness: claude\n",
            with: "    harness: claude\n    provider: anthropic\n"
        ))
    }

    func testWritesEveryFieldOfAFlowEntryInOrder() throws {
        var text = "runs:\n  ci_fix: { model: deepseek/x }\n"
        text = try RunProfilesConfig.setting(.command, of: .ciFix, to: "claude --verbose", in: text)
        text = try RunProfilesConfig.setting(.smallModel, of: .ciFix, to: "deepseek/x", in: text)
        text = try RunProfilesConfig.setting(.effort, of: .ciFix, to: "low", in: text)
        text = try RunProfilesConfig.setting(.provider, of: .ciFix, to: "openrouter", in: text)
        text = try RunProfilesConfig.setting(.harness, of: .ciFix, to: "claude", in: text)

        XCTAssertEqual(
            text,
            "runs:\n  ci_fix: { harness: claude, provider: openrouter, model: deepseek/x, effort: low, small_model: deepseek/x, "
                + "command: \"claude --verbose\" }\n"
        )
        XCTAssertEqual(try RunProfilesConfig.profiles(in: text)[.ciFix], RunProfile(
            model: "deepseek/x", effort: "low", provider: "openrouter", harness: "claude", smallModel: "deepseek/x", command: "claude --verbose"
        ))
    }

    func testKeepsTheBraceSpacingOfAFlowLine() throws {
        let yaml = "runs:\n  qa: {effort: low}\n"
        let updated = try RunProfilesConfig.setting(.model, of: .qa, to: "claude-haiku-4-5-20251001", in: yaml)

        XCTAssertEqual(updated, "runs:\n  qa: {model: claude-haiku-4-5-20251001, effort: low}\n")
    }

    // MARK: Inserting

    func testInsertsAMissingKindInFlowStyleAfterTheLastEntry() throws {
        let updated = try RunProfilesConfig.setting(.effort, of: .rework, to: "high", in: config)
        XCTAssertEqual(updated, config.replacingOccurrences(
            of: "    # model: claude-haiku-4-5-20251001\n",
            with: "    # model: claude-haiku-4-5-20251001\n  rework: { effort: high }\n"
        ))
        XCTAssertEqual(try RunProfilesConfig.setting(.effort, of: .rework, to: nil, in: updated), config)
    }

    func testInsertsAMissingDefaultFirst() throws {
        let yaml = "runs:\n    landing: { effort: low }\nworkspaces:\n    root: ~/work\n"

        XCTAssertEqual(
            try RunProfilesConfig.setting(.model, of: nil, to: "claude-opus-5-5", in: yaml),
            "runs:\n    default: { model: claude-opus-5-5 }\n    landing: { effort: low }\nworkspaces:\n    root: ~/work\n"
        )
    }

    func testAddsARunsSectionWhenTheFileHasNone() throws {
        let yaml = "# config\nissues:\n  provider: linear\n"

        XCTAssertEqual(
            try RunProfilesConfig.setting(.effort, of: .breakdown, to: "high", in: yaml),
            "# config\nissues:\n  provider: linear\nruns:\n  breakdown: { effort: high }\n"
        )
        XCTAssertEqual(
            try RunProfilesConfig.setting(.model, of: nil, to: "claude-opus-5-5", in: yaml),
            "# config\nissues:\n  provider: linear\nruns:\n  default: { model: claude-opus-5-5 }\n"
        )
    }

    func testFillsAnEmptyRunsMapOrBlock() throws {
        XCTAssertEqual(
            try RunProfilesConfig.setting(.effort, of: .qa, to: "low", in: "runs: {}  # none yet\n"),
            "runs: # none yet\n  qa: { effort: low }\n"
        )
        XCTAssertEqual(
            try RunProfilesConfig.setting(.effort, of: .qa, to: "low", in: "runs:\nphases: {}\n"),
            "runs:\n  qa: { effort: low }\nphases: {}\n"
        )
        XCTAssertEqual(try RunProfilesConfig.setting(.effort, of: .qa, to: nil, in: "runs: {}\n"), "runs: {}\n")
    }

    func testFillsAnEmptyEntryBlock() throws {
        XCTAssertEqual(
            try RunProfilesConfig.setting(.effort, of: .qa, to: "low", in: "runs:\n  qa:\n"),
            "runs:\n  qa:\n    effort: low\n"
        )
    }

    func testQuotesValuesThatWouldReadAsSomethingElse() throws {
        let updated = try RunProfilesConfig.setting(.model, of: nil, to: "yes", in: "runs:\n  default:\n    model: x\n")

        XCTAssertEqual(updated, "runs:\n  default:\n    model: \"yes\"\n")
        XCTAssertEqual(try RunProfilesConfig.profiles(in: updated).defaults.model, "yes")
    }

    // MARK: Unsetting removes the key

    func testUnsettingRemovesTheKeyAndLeavesTheRestAlone() throws {
        let updated = try RunProfilesConfig.setting(.model, of: nil, to: nil, in: config)

        XCTAssertEqual(updated, config.replacingOccurrences(of: "    model: claude-sonnet-5-5  # cheap default\n", with: ""))
    }

    func testUnsettingRemovesAnEntryItEmptied() throws {
        let flow = try RunProfilesConfig.setting(.effort, of: .breakdown, to: nil, in: config)
        XCTAssertEqual(flow, config.replacingOccurrences(of: "  breakdown: { effort: xhigh }  # big tickets\n", with: ""))

        let block = try RunProfilesConfig.setting(.effort, of: .landing, to: nil, in: config)
        XCTAssertEqual(block, config.replacingOccurrences(of: "  landing:\n    effort: low\n", with: ""))
    }

    func testUnsettingRemovesRunsWhenItEmptied() throws {
        let yaml = "issues:\n  provider: linear\nruns:\n  qa:\n    effort: low\nworkspaces:\n  root: ~/work\n"
        XCTAssertEqual(
            try RunProfilesConfig.setting(.effort, of: .qa, to: nil, in: yaml),
            "issues:\n  provider: linear\nworkspaces:\n  root: ~/work\n"
        )

        let flow = "runs: { qa: { effort: low } }  # one\nissues:\n  provider: linear\n"
        XCTAssertEqual(try RunProfilesConfig.setting(.effort, of: .qa, to: nil, in: flow), "issues:\n  provider: linear\n")
    }

    func testEditsAFlowRunsLine() throws {
        let yaml = "runs: { qa: { effort: low }, landing: { effort: low } }  # cheap\n"

        XCTAssertEqual(
            try RunProfilesConfig.setting(.effort, of: .qa, to: nil, in: yaml),
            "runs: { landing: { effort: low } }  # cheap\n"
        )
        XCTAssertEqual(
            try RunProfilesConfig.setting(.effort, of: .ciFix, to: "low", in: yaml),
            "runs: { qa: { effort: low }, landing: { effort: low }, ci_fix: { effort: low } }  # cheap\n"
        )
        XCTAssertEqual(
            try RunProfilesConfig.setting(.effort, of: .qa, to: "high", in: yaml),
            "runs: { qa: { effort: high }, landing: { effort: low } }  # cheap\n"
        )
        XCTAssertEqual(
            try RunProfilesConfig.setting(.harness, of: nil, to: "codex", in: yaml),
            "runs: { qa: { effort: low }, landing: { effort: low }, default: { harness: codex } }  # cheap\n"
        )
        XCTAssertEqual(try RunProfilesConfig.setting(.effort, of: .rework, to: nil, in: yaml), yaml)
        XCTAssertThrowsError(try RunProfilesConfig.setting(.effort, of: .qa, to: "low", in: "runs: { qa: low }\n"))
    }

    func testInsertThenRemoveRoundTripsByteForByte() throws {
        var text = config
        for kind in RunKind.allCases {
            text = try RunProfilesConfig.setting(.effort, of: kind, to: "max", in: text)
            text = try RunProfilesConfig.setting(.model, of: kind, to: "claude-haiku-4-5-20251001", in: text)
        }
        let profiles = try RunProfilesConfig.profiles(in: text)
        XCTAssertEqual(profiles.kinds.count, RunKind.allCases.count)
        XCTAssertTrue(profiles.kinds.values.allSatisfy { $0 == RunProfile(model: "claude-haiku-4-5-20251001", effort: "max") })
        XCTAssertTrue(text.contains("  # Defaults for every kind of run.\n"))
        XCTAssertTrue(text.contains("    # model: claude-haiku-4-5-20251001\n"))

        let stripped = try RunProfilesConfig.updating(text, from: profiles, to: RunProfiles(defaults: profiles.defaults))
        XCTAssertEqual(try RunProfilesConfig.profiles(in: stripped), RunProfiles(defaults: profiles.defaults))
        XCTAssertEqual(stripped, config
            .replacingOccurrences(of: "  breakdown: { effort: xhigh }  # big tickets\n", with: "")
            .replacingOccurrences(of: "  landing:\n    effort: low\n", with: ""))
    }

    func testUpdatingWritesOnlyChangedFields() throws {
        let old = try RunProfilesConfig.profiles(in: config)
        var new = old
        new[.breakdown].effort = "high"
        new[.qa].model = "claude-haiku-4-5-20251001"
        new[nil].effort = nil
        new[nil].provider = "anthropic"

        let updated = try RunProfilesConfig.updating(config, from: old, to: new)

        XCTAssertEqual(try RunProfilesConfig.profiles(in: updated), new)
        XCTAssertEqual(try RunProfilesConfig.updating(config, from: old, to: old), config)
        XCTAssertEqual(
            try RunProfilesConfig.updating(config, from: old, to: {
                var one = old
                one[.breakdown].effort = "high"
                return one
            }()),
            try RunProfilesConfig.setting(.effort, of: .breakdown, to: "high", in: config)
        )
    }

    func testKeepsCRLFLineEndings() throws {
        let yaml = "runs:\r\n  default:\r\n    effort: low\r\n"

        XCTAssertEqual(try RunProfilesConfig.setting(.effort, of: nil, to: "high", in: yaml), "runs:\r\n  default:\r\n    effort: high\r\n")
    }

    func testKeepsAnEntryThatStillHasAField() throws {
        let flow = "runs:\n  breakdown: { provider: openrouter, model: x/y }\n"
        let block = "runs:\n  breakdown:\n    provider: openrouter\n    model: x/y\n"
        let old = try RunProfilesConfig.profiles(in: flow)
        XCTAssertEqual(old[.breakdown], RunProfile(model: "x/y", provider: "openrouter"))
        XCTAssertEqual(try RunProfilesConfig.profiles(in: block), old)
        var new = old
        new[.breakdown].model = nil

        XCTAssertEqual(try RunProfilesConfig.updating(flow, from: old, to: new), "runs:\n  breakdown: { provider: openrouter }\n")
        XCTAssertEqual(try RunProfilesConfig.updating(block, from: old, to: new), "runs:\n  breakdown:\n    provider: openrouter\n")
    }

    // MARK: Model

    func testEmptyProfileReadsAsMissing() {
        var profiles = RunProfiles()
        profiles[.qa].effort = "low"
        XCTAssertEqual(profiles.kinds, [.qa: RunProfile(effort: "low")])
        profiles[.qa].effort = nil
        XCTAssertEqual(profiles.kinds, [:])
        profiles[nil].model = "m"
        XCTAssertEqual(profiles.defaults, RunProfile(model: "m"))
    }

    func testAFieldReadsAndWritesItsProperty() {
        var profile = RunProfile()
        for field in RunProfileField.allCases {
            profile[field] = field.rawValue
        }
        XCTAssertEqual(profile, RunProfile(
            model: "model", effort: "effort", provider: "provider", harness: "harness", smallModel: "small_model", command: "command"
        ))
        XCTAssertEqual(RunProfileField.allCases.map { profile[$0] }, ["harness", "provider", "model", "effort", "small_model", "command"])
    }

    func testChoicesIncludeAValueFromTheFile() {
        XCTAssertEqual(RunProfilesConfig.choices(RunProfilesConfig.models, including: "claude-opus-5-5"), RunProfilesConfig.models)
        XCTAssertEqual(RunProfilesConfig.choices(RunProfilesConfig.models, including: nil), RunProfilesConfig.models)
        XCTAssertEqual(
            RunProfilesConfig.choices(RunProfilesConfig.efforts, including: "huge").last,
            RunProfileChoice(id: "huge", title: "huge")
        )
    }

    func testEveryKindHasATitleAndTheSettingsOrder() {
        XCTAssertEqual(RunProfilesConfig.scopes.count, 10)
        XCTAssertEqual(RunKind.allCases.map(\.title), [
            "Breakdown", "Implementation", "Rework", "CI fix",
            "Review feedback", "Landing", "Code review", "Epic review", "QA",
        ])
        XCTAssertEqual(RunKind.ciFix.id, "ci_fix")
        // The kinds `SymphonyElixir.RunKind` lists.
        XCTAssertEqual(Set(RunKind.allCases.map(\.rawValue)), [
            "implementation", "breakdown", "rework", "landing", "code_review", "epic_review", "ci_fix", "review_feedback", "qa",
        ])
    }

    func testInheritedTitleNamesTheValueAnUnsetFieldFallsBackTo() {
        XCTAssertEqual(RunProfilesConfig.inheritedTitle(RunProfilesConfig.models, inherited: nil), "none")
        XCTAssertEqual(RunProfilesConfig.inheritedTitle(RunProfilesConfig.models, inherited: "claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(RunProfilesConfig.inheritedTitle(RunProfilesConfig.providers, inherited: "opencode-go"), "OpenCode Go")
        XCTAssertEqual(RunProfilesConfig.inheritedTitle(RunProfilesConfig.models, inherited: "x/y"), "x/y")
    }

    // MARK: Harnesses

    func testEachHarnessOffersTheProvidersItReaches() {
        XCTAssertEqual(RunProfilesConfig.harnesses.map(\.id), ["claude", "codex", "opencode"])
        XCTAssertEqual(RunProfilesConfig.harnesses.map(\.title), ["Claude", "Codex", "OpenCode"])
        XCTAssertEqual(RunProfilesConfig.providers(for: "claude").map(\.title), ["Anthropic", "OpenRouter", "OpenCode Go"])
        XCTAssertEqual(RunProfilesConfig.providers(for: "codex").map(\.title), ["OpenCode Go", "OpenAI"])
        XCTAssertEqual(RunProfilesConfig.providers(for: "opencode").map(\.id), ["opencode-go"])
        XCTAssertEqual(RunProfilesConfig.providers(for: nil), RunProfilesConfig.providers)
        XCTAssertEqual(RunProfilesConfig.providers(for: "aider"), RunProfilesConfig.providers)
        XCTAssertEqual(Harness.allCases.filter(\.callsSmallModel), [.claude, .opencode])
    }

    // MARK: File

    func testFileWritesOnlyChangedFields() throws {
        let directory = uniqueTemporaryDirectory("run-profiles")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("symphony.yml").path
        try config.write(toFile: path, atomically: false, encoding: .utf8)
        let file = SymphonyConfigFile(path: path)

        let old = try file.readRunProfiles()
        var new = old
        new[.breakdown].effort = "high"
        try file.writeRunProfiles(new, from: old)

        let written = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(changedLines(config, written), ["  breakdown: { effort: high }  # big tickets"])
        XCTAssertEqual(try file.readRunProfiles(), new)
    }

    private func changedLines(_ original: String, _ updated: String) -> [String] {
        let before = original.components(separatedBy: "\n")
        let after = updated.components(separatedBy: "\n")
        XCTAssertEqual(before.count, after.count)
        return zip(before, after).filter { $0 != $1 }.map(\.1)
    }
}
