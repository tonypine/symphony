import XCTest
@testable import SymphonyBarCore

final class RunProfilesConfigTests: XCTestCase {
    private let config = """
        # Symphony operator config.
        issues:
          provider: linear

        agent:
          runtime: claude
          command: claude
          # Defaults for every kind of run.
          model: claude-sonnet-5-5  # cheap default
          effort: medium
          run_profiles:
            # Plan carefully.
            breakdown: { effort: xhigh }  # big tickets
            landing:
              effort: low
              # model: claude-haiku-4-5-20251001
          concurrency:
            max_total: 2

        workspaces:
          root: ~/work

        """

    // MARK: Reading

    func testReadsDefaultsAndBothStyles() throws {
        let profiles = try RunProfilesConfig.profiles(in: config)

        XCTAssertEqual(profiles.defaults, RunProfile(model: "claude-sonnet-5-5", effort: "medium"))
        XCTAssertEqual(profiles.kinds, [
            .breakdown: RunProfile(effort: "xhigh"),
            .landing: RunProfile(effort: "low"),
        ])
    }

    func testMissingKeysReadAsDefault() throws {
        XCTAssertEqual(try RunProfilesConfig.profiles(in: "issues:\n  provider: linear\n"), RunProfiles())
        XCTAssertEqual(try RunProfilesConfig.profiles(in: "agent:\n  model:\n  effort: null\n  run_profiles: {}\n"), RunProfiles())
    }

    func testReadsQuotedValuesAndAFlowRunProfilesLine() throws {
        let yaml = """
            agent:
              model: "claude-opus-5-5"
              effort: 'high'
              run_profiles: {qa: {model: "claude-haiku-4-5-20251001", effort: low}, ci_fix: {}, typo: {effort: low}}
            """
        let profiles = try RunProfilesConfig.profiles(in: yaml)

        XCTAssertEqual(profiles.defaults, RunProfile(model: "claude-opus-5-5", effort: "high"))
        XCTAssertEqual(profiles.kinds, [.qa: RunProfile(model: "claude-haiku-4-5-20251001", effort: "low")])
    }

    func testRejectsLayoutsItCannotEdit() {
        let cases = [
            "agent: { model: x }\n",
            "agent:\n  run_profiles: lots\n",
            "agent:\n  run_profiles:\n    breakdown: high\n",
            "agent:\n  run_profiles: { breakdown: high }\n",
            "agent:\n  run_profiles:\n    breakdown: { effort: [high] }\n",
            "agent:\n  model: [a, b]\n",
            "agent:\n  model:\n    nested: x\n",
            "agent:\n  model: \"open\n",
            "agent:\n  model: \"a\" b\n",
            "agent:\n  model: *alias\n",
            "agent:\n  run_profiles: { breakdown: { effort high } }\n",
            "agent:\n  run_profiles: { breakdown: { effort: high }\n",
            "agent:\n  run_profiles: { qa: [low\n",
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
        let error = RunProfilesConfigError.unsupported(line: 3, reason: "`agent:` should be an indented block")
        XCTAssertEqual(error.errorDescription, "symphony.yml line 3: `agent:` should be an indented block. Edit models by hand.")
    }

    // MARK: Changing one value

    func testChangingBreakdownEffortChangesOnlyThatLine() throws {
        let updated = try RunProfilesConfig.setting(.effort, of: .breakdown, to: "high", in: config)

        XCTAssertEqual(changedLines(config, updated), ["    breakdown: { effort: high }  # big tickets"])
        XCTAssertEqual(try RunProfilesConfig.profiles(in: updated)[.breakdown], RunProfile(effort: "high"))
    }

    func testChangingABlockValueKeepsItsComment() throws {
        let updated = try RunProfilesConfig.setting(.model, of: nil, to: "claude-opus-5-5", in: config)

        XCTAssertEqual(changedLines(config, updated), ["  model: claude-opus-5-5  # cheap default"])
        let landing = try RunProfilesConfig.setting(.effort, of: .landing, to: "medium", in: config)
        XCTAssertEqual(changedLines(config, landing), ["      effort: medium"])
    }

    func testSettingTheSameValueLeavesTheTextAlone() throws {
        XCTAssertEqual(try RunProfilesConfig.setting(.effort, of: nil, to: "medium", in: config), config)
        XCTAssertEqual(try RunProfilesConfig.setting(.effort, of: .breakdown, to: "xhigh", in: config), config)
        XCTAssertEqual(try RunProfilesConfig.setting(.model, of: .rework, to: nil, in: config), config)
        XCTAssertEqual(try RunProfilesConfig.setting(.model, of: .breakdown, to: nil, in: config), config)
        XCTAssertEqual(try RunProfilesConfig.setting(.model, of: nil, to: nil, in: "issues:\n"), "issues:\n")
    }

    func testAddsAFieldToAnExistingKind() throws {
        let flow = try RunProfilesConfig.setting(.model, of: .breakdown, to: "claude-opus-5-5", in: config)
        XCTAssertEqual(changedLines(config, flow), ["    breakdown: { model: claude-opus-5-5, effort: xhigh }  # big tickets"])

        let block = try RunProfilesConfig.setting(.model, of: .landing, to: "claude-haiku-4-5-20251001", in: config)
        XCTAssertEqual(block, config.replacingOccurrences(
            of: "    landing:\n",
            with: "    landing:\n      model: claude-haiku-4-5-20251001\n"
        ))
    }

    func testKeepsTheBraceSpacingOfAFlowLine() throws {
        let yaml = "agent:\n  run_profiles:\n    qa: {effort: low}\n"
        let updated = try RunProfilesConfig.setting(.model, of: .qa, to: "claude-haiku-4-5-20251001", in: yaml)

        XCTAssertEqual(updated, "agent:\n  run_profiles:\n    qa: {model: claude-haiku-4-5-20251001, effort: low}\n")
    }

    // MARK: Inserting

    func testInsertsAMissingKindInTheSiblingsStyle() throws {
        let updated = try RunProfilesConfig.setting(.effort, of: .rework, to: "high", in: config)
        XCTAssertEqual(updated, config.replacingOccurrences(
            of: "      # model: claude-haiku-4-5-20251001\n",
            with: "      # model: claude-haiku-4-5-20251001\n    rework: { effort: high }\n"
        ))

        let blocks = "agent:\n  run_profiles:\n    landing:\n      effort: low\n  concurrency:\n    max_total: 2\n"
        XCTAssertEqual(
            try RunProfilesConfig.setting(.model, of: .qa, to: "claude-haiku-4-5-20251001", in: blocks),
            "agent:\n  run_profiles:\n    landing:\n      effort: low\n    qa:\n      model: claude-haiku-4-5-20251001\n  concurrency:\n    max_total: 2\n"
        )
    }

    func testInsertsAMissingRunProfilesBlockAfterTheDefaults() throws {
        let yaml = """
            agent:
              runtime: claude
              command: claude  # flags come from run profiles
              # Model and effort per kind of run.
              # run_profiles:
              #   breakdown: { effort: xhigh }
              concurrency:
                max_total: 2

            """
        let updated = try RunProfilesConfig.setting(.effort, of: .breakdown, to: "high", in: yaml)

        XCTAssertEqual(updated, yaml.replacingOccurrences(
            of: "  command: claude  # flags come from run profiles\n",
            with: "  command: claude  # flags come from run profiles\n  run_profiles:\n    breakdown: { effort: high }\n"
        ))
        XCTAssertEqual(try RunProfilesConfig.setting(.effort, of: .breakdown, to: nil, in: updated), yaml)
    }

    func testInsertsDefaultsInKeyOrder() throws {
        let yaml = "agent:\n    command: claude\n    effort: low\n    concurrency:\n        max_total: 2\n"

        XCTAssertEqual(
            try RunProfilesConfig.setting(.model, of: nil, to: "claude-opus-5-5", in: yaml),
            "agent:\n    command: claude\n    model: claude-opus-5-5\n    effort: low\n    concurrency:\n        max_total: 2\n"
        )
        XCTAssertEqual(
            try RunProfilesConfig.setting(.effort, of: nil, to: "max", in: "agent:\n  concurrency:\n    max_total: 2\n"),
            "agent:\n  effort: max\n  concurrency:\n    max_total: 2\n"
        )
    }

    func testFollowsTheFilesIndentWhenInsertingRunProfiles() throws {
        let yaml = "agent:\n    command: claude\n"

        XCTAssertEqual(
            try RunProfilesConfig.setting(.effort, of: .qa, to: "low", in: yaml),
            "agent:\n    command: claude\n    run_profiles:\n        qa: { effort: low }\n"
        )
    }

    func testAddsAnAgentSectionWhenTheFileHasNone() throws {
        let yaml = "# config\nissues:\n  provider: linear\n"

        XCTAssertEqual(
            try RunProfilesConfig.setting(.effort, of: .breakdown, to: "high", in: yaml),
            "# config\nissues:\n  provider: linear\nagent:\n  run_profiles:\n    breakdown: { effort: high }\n"
        )
        XCTAssertEqual(
            try RunProfilesConfig.setting(.model, of: nil, to: "claude-opus-5-5", in: yaml),
            "# config\nissues:\n  provider: linear\nagent:\n  model: claude-opus-5-5\n"
        )
    }

    func testFillsAnEmptyRunProfilesMapOrBlock() throws {
        XCTAssertEqual(
            try RunProfilesConfig.setting(.effort, of: .qa, to: "low", in: "agent:\n  run_profiles: {}  # none yet\n"),
            "agent:\n  run_profiles: # none yet\n    qa: { effort: low }\n"
        )
        XCTAssertEqual(
            try RunProfilesConfig.setting(.effort, of: .qa, to: "low", in: "agent:\n  run_profiles:\n  limits: {}\n"),
            "agent:\n  run_profiles:\n    qa: { effort: low }\n  limits: {}\n"
        )
        XCTAssertEqual(try RunProfilesConfig.setting(.effort, of: .qa, to: nil, in: "agent:\n  run_profiles: {}\n"), "agent:\n  run_profiles: {}\n")
    }

    func testFillsAnEmptyKindBlock() throws {
        XCTAssertEqual(
            try RunProfilesConfig.setting(.effort, of: .qa, to: "low", in: "agent:\n  run_profiles:\n    qa:\n"),
            "agent:\n  run_profiles:\n    qa:\n      effort: low\n"
        )
    }

    func testQuotesValuesThatWouldReadAsSomethingElse() throws {
        let updated = try RunProfilesConfig.setting(.model, of: nil, to: "yes", in: "agent:\n  model: x\n")

        XCTAssertEqual(updated, "agent:\n  model: \"yes\"\n")
        XCTAssertEqual(try RunProfilesConfig.profiles(in: updated).defaults.model, "yes")
    }

    // MARK: Default removes the key

    func testDefaultRemovesTheKeyAndLeavesTheRestAlone() throws {
        let updated = try RunProfilesConfig.setting(.model, of: nil, to: nil, in: config)

        XCTAssertEqual(updated, config.replacingOccurrences(of: "  model: claude-sonnet-5-5  # cheap default\n", with: ""))
    }

    func testDefaultRemovesAKindItEmptied() throws {
        let flow = try RunProfilesConfig.setting(.effort, of: .breakdown, to: nil, in: config)
        XCTAssertEqual(flow, config.replacingOccurrences(of: "    breakdown: { effort: xhigh }  # big tickets\n", with: ""))

        let block = try RunProfilesConfig.setting(.effort, of: .landing, to: nil, in: config)
        XCTAssertEqual(block, config.replacingOccurrences(of: "    landing:\n      effort: low\n", with: ""))
    }

    func testDefaultRemovesRunProfilesWhenItEmptied() throws {
        let yaml = "agent:\n  command: claude\n  run_profiles:\n    qa:\n      effort: low\n  concurrency:\n    max_total: 2\n"
        XCTAssertEqual(
            try RunProfilesConfig.setting(.effort, of: .qa, to: nil, in: yaml),
            "agent:\n  command: claude\n  concurrency:\n    max_total: 2\n"
        )

        let flow = "agent:\n  run_profiles: { qa: { effort: low } }  # one\n  command: claude\n"
        XCTAssertEqual(try RunProfilesConfig.setting(.effort, of: .qa, to: nil, in: flow), "agent:\n  command: claude\n")
    }

    func testEditsAFlowRunProfilesLine() throws {
        let yaml = "agent:\n  run_profiles: { qa: { effort: low }, landing: { effort: low } }  # cheap\n"

        XCTAssertEqual(
            try RunProfilesConfig.setting(.effort, of: .qa, to: nil, in: yaml),
            "agent:\n  run_profiles: { landing: { effort: low } }  # cheap\n"
        )
        XCTAssertEqual(
            try RunProfilesConfig.setting(.effort, of: .ciFix, to: "low", in: yaml),
            "agent:\n  run_profiles: { qa: { effort: low }, landing: { effort: low }, ci_fix: { effort: low } }  # cheap\n"
        )
        XCTAssertEqual(
            try RunProfilesConfig.setting(.effort, of: .qa, to: "high", in: yaml),
            "agent:\n  run_profiles: { qa: { effort: high }, landing: { effort: low } }  # cheap\n"
        )
        XCTAssertEqual(try RunProfilesConfig.setting(.effort, of: .rework, to: nil, in: yaml), yaml)
        XCTAssertThrowsError(try RunProfilesConfig.setting(.effort, of: .qa, to: "low", in: "agent:\n  run_profiles: { qa: low }\n"))
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
        XCTAssertTrue(text.contains("      # model: claude-haiku-4-5-20251001\n"))

        let stripped = try RunProfilesConfig.updating(text, from: profiles, to: RunProfiles(defaults: profiles.defaults))
        XCTAssertEqual(try RunProfilesConfig.profiles(in: stripped), RunProfiles(defaults: profiles.defaults))
        XCTAssertEqual(stripped, config
            .replacingOccurrences(of: "  run_profiles:\n", with: "")
            .replacingOccurrences(of: "    breakdown: { effort: xhigh }  # big tickets\n", with: "")
            .replacingOccurrences(of: "    landing:\n      effort: low\n", with: ""))
    }

    func testUpdatingWritesOnlyChangedFields() throws {
        let old = try RunProfilesConfig.profiles(in: config)
        var new = old
        new[.breakdown].effort = "high"
        new[.qa].model = "claude-haiku-4-5-20251001"
        new[nil].effort = nil

        let updated = try RunProfilesConfig.updating(config, from: old, to: new)

        XCTAssertEqual(try RunProfilesConfig.profiles(in: updated), new)
        XCTAssertEqual(try RunProfilesConfig.updating(config, from: old, to: old), config)
    }

    func testKeepsCRLFLineEndings() throws {
        let yaml = "agent:\r\n  effort: low\r\n"

        XCTAssertEqual(try RunProfilesConfig.setting(.effort, of: nil, to: "high", in: yaml), "agent:\r\n  effort: high\r\n")
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

    func testChoicesIncludeAValueFromTheFile() {
        XCTAssertEqual(RunProfilesConfig.choices(RunProfilesConfig.models, including: "claude-opus-5-5"), RunProfilesConfig.models)
        XCTAssertEqual(RunProfilesConfig.choices(RunProfilesConfig.models, including: nil), RunProfilesConfig.models)
        XCTAssertEqual(
            RunProfilesConfig.choices(RunProfilesConfig.efforts, including: "huge").last,
            RunProfileChoice(id: "huge", title: "huge")
        )
    }

    func testEveryKindHasATitleAndTheSettingsOrder() {
        XCTAssertEqual(RunProfilesConfig.scopes.count, 11)
        XCTAssertEqual(RunKind.allCases.map(\.title), [
            "Breakdown", "Close-out", "Final verification", "Implementation", "Rework", "CI fix",
            "Review feedback", "Landing", "Pre-push review", "QA",
        ])
        XCTAssertEqual(RunKind.ciFix.id, "ci_fix")
    }

    // MARK: Flags in agent.command

    func testReadsModelAndEffortFlagsFromTheCommand() throws {
        XCTAssertEqual(
            try RunProfilesConfig.commandProfile(in: "agent:\n  command: claude --model claude-opus-5-5 --effort=high --verbose\n"),
            RunProfile(model: "claude-opus-5-5", effort: "high")
        )
        XCTAssertEqual(
            try RunProfilesConfig.commandProfile(in: "agent:\n  command: \"claude --model='claude-haiku-4-5-20251001'\"  # quoted\n"),
            RunProfile(model: "claude-haiku-4-5-20251001")
        )
        XCTAssertEqual(try RunProfilesConfig.commandProfile(in: config), RunProfile())
        XCTAssertEqual(try RunProfilesConfig.commandProfile(in: "agent:\n  command: claude --models x --model-y z\n"), RunProfile())
        XCTAssertEqual(try RunProfilesConfig.commandProfile(in: "issues:\n  provider: linear\n"), RunProfile())
    }

    func testSplitsFlagsOutOfACommand() {
        let split = RunProfilesConfig.splitCommandFlags("--effort low claude --model a --verbose --model=b --effort")
        XCTAssertEqual(split.command, "claude --verbose")
        XCTAssertEqual(split.flags, RunProfile(model: "b", effort: "low"))
    }

    func testSettingAKindMovesCommandFlagsToTheDefaults() throws {
        let yaml = """
            agent:
              runtime: claude
              command: claude --model claude-opus-5-5 --verbose
              concurrency:
                max_total: 2

            """
        let old = try RunProfilesConfig.profiles(in: yaml)
        var new = old
        new[.breakdown].effort = "high"

        XCTAssertEqual(try RunProfilesConfig.updating(yaml, from: old, to: new), """
            agent:
              runtime: claude
              command: claude --verbose
              model: claude-opus-5-5
              run_profiles:
                breakdown: { effort: high }
              concurrency:
                max_total: 2

            """)
    }

    func testMovesTheEqualsFormAndKeepsTheCommandComment() throws {
        let yaml = "agent:\n  command: claude --model=claude-opus-5-5 --effort=xhigh --verbose  # main runs\n"
        var new = RunProfiles()
        new[.landing].model = "claude-haiku-4-5-20251001"

        XCTAssertEqual(
            try RunProfilesConfig.updating(yaml, from: RunProfiles(), to: new),
            """
            agent:
              command: claude --verbose  # main runs
              model: claude-opus-5-5
              effort: xhigh
              run_profiles:
                landing: { model: claude-haiku-4-5-20251001 }

            """.trimmingCharacters(in: .newlines) + "\n"
        )
    }

    func testADefaultSetInTheSameSaveWinsOverTheCommandFlag() throws {
        let yaml = "agent:\n  command: 'claude --model claude-opus-5-5 --effort high'\n"
        var new = RunProfiles()
        new.defaults.model = "claude-sonnet-5-5"

        XCTAssertEqual(
            try RunProfilesConfig.updating(yaml, from: RunProfiles(), to: new),
            "agent:\n  command: 'claude'\n  model: claude-sonnet-5-5\n  effort: high\n"
        )
    }

    func testKeepsDoubleQuotesOnTheCommand() throws {
        let yaml = "agent:\n  command: \"claude --effort low --verbose\"\n"
        var new = RunProfiles()
        new[.qa].effort = "medium"

        XCTAssertEqual(
            try RunProfilesConfig.updating(yaml, from: RunProfiles(), to: new),
            "agent:\n  command: \"claude --verbose\"\n  effort: low\n  run_profiles:\n    qa: { effort: medium }\n"
        )
    }

    func testLeavesCommandFlagsWhenTheSaveSetsNothing() throws {
        let yaml = "agent:\n  command: claude --model claude-opus-5-5\n  run_profiles:\n    qa: { effort: low }\n"
        let old = try RunProfilesConfig.profiles(in: yaml)

        XCTAssertEqual(try RunProfilesConfig.updating(yaml, from: old, to: RunProfiles()), "agent:\n  command: claude --model claude-opus-5-5\n")
        XCTAssertEqual(try RunProfilesConfig.updating(yaml, from: old, to: old), yaml)
    }

    func testWithoutCommandFlagsTheOutputIsUnchanged() throws {
        let old = try RunProfilesConfig.profiles(in: config)
        var new = old
        new[.breakdown].effort = "high"

        XCTAssertEqual(
            try RunProfilesConfig.updating(config, from: old, to: new),
            try RunProfilesConfig.setting(.effort, of: .breakdown, to: "high", in: config)
        )
    }

    func testMovesFlagsOutOfBothCommands() throws {
        let yaml = """
            agent:
              runtime: claude
              command: claude --model claude-opus-5-5 --dangerously-skip-permissions --verbose

            pre_push_review:
              enabled: true
              runtime: claude
              command: claude --model claude-opus-5-5 --effort=high --dangerously-skip-permissions  # reviewer
              max_iterations: 1

            """
        let old = try RunProfilesConfig.profiles(in: yaml)
        var new = old
        new[.breakdown].effort = "high"

        XCTAssertEqual(try RunProfilesConfig.updating(yaml, from: old, to: new), """
            agent:
              runtime: claude
              command: claude --dangerously-skip-permissions --verbose
              model: claude-opus-5-5
              run_profiles:
                breakdown: { effort: high }
                pre_push_review: { model: claude-opus-5-5, effort: high }

            pre_push_review:
              enabled: true
              runtime: claude
              command: claude --dangerously-skip-permissions  # reviewer
              max_iterations: 1

            """)
    }

    func testLeavesThePrePushCommandWhenNothingResolvesForIt() throws {
        let yaml = "agent:\n  command: claude\npre_push_review:\n  command: claude --model claude-opus-5-5\n"
        var new = RunProfiles()
        new[.breakdown].effort = "high"

        XCTAssertEqual(
            try RunProfilesConfig.updating(yaml, from: RunProfiles(), to: new),
            "agent:\n  command: claude\n  run_profiles:\n    breakdown: { effort: high }\npre_push_review:\n  command: claude --model claude-opus-5-5\n"
        )
    }

    func testSettingThePrePushKindMovesTheSectionIntoItsRowAndWinsOverTheSection() throws {
        let yaml = "agent:\n  command: claude\npre_push_review:\n  command: 'claude --model claude-opus-5-5 --effort low'\n  effort: max\n"
        var new = RunProfiles()
        new[.prePushReview].effort = "high"

        XCTAssertEqual(
            try RunProfilesConfig.updating(yaml, from: RunProfiles(), to: new),
            "agent:\n  command: claude\n  run_profiles:\n    pre_push_review: { model: claude-opus-5-5, effort: high }\n"
                + "pre_push_review:\n  command: 'claude'\n"
        )
    }

    func testTheSectionsKeysOutrankItsFlagsWhenTheyMove() throws {
        let yaml = "agent:\n  command: claude\npre_push_review:\n  command: claude --model claude-opus-5-5 --effort low\n  effort: max\n"
        var new = RunProfiles()
        new.defaults.model = "claude-sonnet-5-5"

        XCTAssertEqual(
            try RunProfilesConfig.updating(yaml, from: RunProfiles(), to: new),
            "agent:\n  command: claude\n  model: claude-sonnet-5-5\n  run_profiles:\n"
                + "    pre_push_review: { model: claude-opus-5-5, effort: max }\npre_push_review:\n  command: claude\n"
        )
    }

    func testAnOpenRouterDefaultKeepsTheReviewersClaudeModelOnAnthropic() throws {
        let yaml = """
            agent:
              runtime: claude
              command: claude --model claude-opus-4-7 --dangerously-skip-permissions
            pre_push_review:
              enabled: true
              runtime: claude
              command: claude --model claude-opus-4-7 --dangerously-skip-permissions

            """
        let old = try RunProfilesConfig.profiles(in: yaml)
        var new = old
        new.defaults = RunProfile(model: "openai/gpt-oss-120b", provider: "openrouter")

        XCTAssertEqual(try RunProfilesConfig.updating(yaml, from: old, to: new), """
            agent:
              runtime: claude
              command: claude --dangerously-skip-permissions
              provider: openrouter
              model: openai/gpt-oss-120b
              run_profiles:
                pre_push_review: { provider: anthropic, model: claude-opus-4-7 }
            pre_push_review:
              enabled: true
              runtime: claude
              command: claude --dangerously-skip-permissions

            """)
    }

    func testAnOpenRouterQARowReplacesTheSectionsModel() throws {
        let yaml = "agent:\n  command: claude\nauto_review:\n  enabled: true\n  model: claude-opus-4-7\n  effort: low\n"
        var new = RunProfiles()
        new[.qa] = RunProfile(model: "openai/gpt-oss-120b", provider: "openrouter")

        XCTAssertEqual(
            try RunProfilesConfig.updating(yaml, from: RunProfiles(), to: new),
            "agent:\n  command: claude\n  run_profiles:\n"
                + "    qa: { provider: openrouter, model: openai/gpt-oss-120b, effort: low }\nauto_review:\n  enabled: true\n"
        )
    }

    func testChangingTheRowsProviderDropsTheSectionsModel() throws {
        let yaml = "agent:\n  command: claude\n  model: x/y\npre_push_review:\n  command: claude --model claude-opus-4-7\n"
        let old = try RunProfilesConfig.profiles(in: yaml)
        var new = old
        new[.prePushReview].provider = "openrouter"

        XCTAssertEqual(
            try RunProfilesConfig.updating(yaml, from: old, to: new),
            "agent:\n  command: claude\n  model: x/y\n  run_profiles:\n    pre_push_review: { provider: openrouter }\n"
                + "pre_push_review:\n  command: claude\n"
        )
    }

    func testAMovedModelOverwritesTheRowItOutranked() throws {
        let yaml = "agent:\n  command: claude\n  run_profiles:\n    pre_push_review: { model: claude-haiku-4-5-20251001 }\n"
            + "pre_push_review:\n  model: claude-opus-4-7\n"
        let old = try RunProfilesConfig.profiles(in: yaml)
        var new = old
        new.defaults.effort = "high"

        XCTAssertEqual(
            try RunProfilesConfig.updating(yaml, from: old, to: new),
            "agent:\n  command: claude\n  effort: high\n  run_profiles:\n    pre_push_review: { model: claude-opus-4-7 }\n"
                + "pre_push_review:\n"
        )
    }

    func testAOneLinePrePushSectionFailsOnlyWithFlags() throws {
        var new = RunProfiles()
        new.defaults.effort = "high"
        let plain = "agent:\n  command: claude\npre_push_review: { enabled: true, command: claude, model: x }\n"

        XCTAssertEqual(
            try RunProfilesConfig.updating(plain, from: RunProfiles(), to: new),
            "agent:\n  command: claude\n  effort: high\npre_push_review: { enabled: true, command: claude, model: x }\n"
        )
        let flagged = "agent:\n  command: claude\npre_push_review: { command: claude --model x }\n"
        XCTAssertThrowsError(try RunProfilesConfig.updating(flagged, from: RunProfiles(), to: new)) { error in
            XCTAssertEqual(error as? RunProfilesConfigError, .unsupported(line: 3, reason: "`pre_push_review:` should be an indented block"))
        }
    }

    func testMovesFlagsOutOfTheQACommand() throws {
        let yaml = """
            agent:
              command: claude
            auto_review:
              enabled: true
              state: Auto Review
              command: "claude --effort=low --dangerously-skip-permissions"  # QA
              max_turns: 20

            """
        var new = RunProfiles()
        new[.qa].model = "claude-sonnet-5-5"

        XCTAssertEqual(try RunProfilesConfig.updating(yaml, from: RunProfiles(), to: new), """
            agent:
              command: claude
              run_profiles:
                qa: { model: claude-sonnet-5-5, effort: low }
            auto_review:
              enabled: true
              state: Auto Review
              command: "claude --dangerously-skip-permissions"  # QA
              max_turns: 20

            """)
    }

    func testLeavesTheQACommandWhenNothingResolvesForIt() throws {
        let yaml = "agent:\n  command: claude\nauto_review:\n  command: claude --model claude-opus-5-5\n"
        var new = RunProfiles()
        new[.prePushReview].effort = "high"

        XCTAssertEqual(
            try RunProfilesConfig.updating(yaml, from: RunProfiles(), to: new),
            "agent:\n  command: claude\n  run_profiles:\n    pre_push_review: { effort: high }\nauto_review:\n  command: claude --model claude-opus-5-5\n"
        )
    }

    func testKeepsAKindThatStillHasAProvider() throws {
        let flow = "agent:\n  run_profiles:\n    breakdown: { provider: openrouter, model: x/y }\n"
        let block = "agent:\n  run_profiles:\n    breakdown:\n      provider: openrouter\n      model: x/y\n"
        let old = try RunProfilesConfig.profiles(in: flow)
        XCTAssertEqual(old[.breakdown], RunProfile(model: "x/y", provider: "openrouter"))
        XCTAssertEqual(try RunProfilesConfig.profiles(in: block), old)
        var new = old
        new[.breakdown].model = nil

        XCTAssertEqual(
            try RunProfilesConfig.updating(flow, from: old, to: new),
            "agent:\n  run_profiles:\n    breakdown: { provider: openrouter }\n"
        )
        XCTAssertEqual(
            try RunProfilesConfig.updating(block, from: old, to: new),
            "agent:\n  run_profiles:\n    breakdown:\n      provider: openrouter\n"
        )
    }

    func testDefaultTitleNamesTheCommandValue() {
        XCTAssertEqual(RunProfilesConfig.defaultTitle(RunProfilesConfig.models, inherited: nil), "default")
        XCTAssertEqual(RunProfilesConfig.defaultTitle(RunProfilesConfig.models, inherited: "claude-opus-5-5"), "Opus 5.5, from command")
        XCTAssertEqual(RunProfilesConfig.defaultTitle(RunProfilesConfig.efforts, inherited: "high"), "high, from command")
        XCTAssertEqual(RunProfilesConfig.defaultTitle(RunProfilesConfig.models, inherited: "opus"), "opus, from command")
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
        XCTAssertEqual(changedLines(config, written), ["    breakdown: { effort: high }  # big tickets"])
        XCTAssertEqual(try file.readRunProfiles(), new)
        XCTAssertEqual(try file.readCommandProfile(), RunProfile())
    }

    private func changedLines(_ original: String, _ updated: String) -> [String] {
        let before = original.components(separatedBy: "\n")
        let after = updated.components(separatedBy: "\n")
        XCTAssertEqual(before.count, after.count)
        return zip(before, after).filter { $0 != $1 }.map(\.1)
    }
}
