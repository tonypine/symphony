import XCTest
@testable import SymphonyBarCore

/// Reading and writing the `fallbacks` lists of `runs` entries in the text of a `symphony.yml`.
final class RunFallbacksConfigTests: XCTestCase {
    private let config = """
        runs:
          default:
            harness: claude
            provider: anthropic
            model: claude-opus-5-5
            fallbacks:
              - { harness: opencode, provider: opencode-go, model: kimi-k3 }  # cheap
              # Then OpenRouter.
              - provider: openrouter
                model: acme/chat
          landing: { model: claude-sonnet-5-5, fallbacks: [{ provider: openrouter, model: acme/flash }] }
          qa:
            model: claude-haiku-4-5
            fallbacks: [{ model: claude-sonnet-5-5 }]  # one more
        repositories:
          - key: web
            runs:
              qa:
                model: claude-haiku-4-5
                fallbacks:
                  - { model: claude-sonnet-5-5 }

        """

    // MARK: Reading

    func testReadsEveryWayAListIsWritten() throws {
        let scoped = try RunProfilesConfig.scopedProfiles(in: config)

        XCTAssertEqual(scoped.global.fallbacks(of: nil), [
            RunFallback(harness: "opencode", provider: "opencode-go", model: "kimi-k3"),
            RunFallback(provider: "openrouter", model: "acme/chat"),
        ])
        XCTAssertEqual(scoped.global.fallbacks(of: .landing), [RunFallback(provider: "openrouter", model: "acme/flash")])
        XCTAssertEqual(scoped.global.fallbacks(of: .qa), [RunFallback(model: "claude-sonnet-5-5")])
        XCTAssertNil(scoped.global.fallbacks(of: .rework))
        XCTAssertEqual(scoped.repositories["web"]?.fallbacks(of: .qa), [RunFallback(model: "claude-sonnet-5-5")])
        XCTAssertEqual(scoped.global.defaults.model, "claude-opus-5-5")
        XCTAssertEqual(scoped.global[.qa].model, "claude-haiku-4-5")
    }

    func testReadsAListAtTheKeysOwnColumnAndEveryField() throws {
        let yaml = """
            runs:
              default:
                model: a
                fallbacks:
                - { model: b, effort: low, small_model: s }
                - harness: codex
                  provider: openai
                  model: c
                effort: high

            """
        let profiles = try RunProfilesConfig.profiles(in: yaml)

        XCTAssertEqual(profiles.fallbacks(of: nil), [
            RunFallback(model: "b", effort: "low", smallModel: "s"),
            RunFallback(harness: "codex", provider: "openai", model: "c"),
        ])
        XCTAssertEqual(profiles.defaults, RunProfile(model: "a", effort: "high"))
    }

    func testAnEmptyOrNullListIsNoneSet() throws {
        for list in ["[]", "", "~", "null"] {
            let profiles = try RunProfilesConfig.profiles(in: "runs:\n  qa:\n    model: a\n    fallbacks: \(list)\n")
            XCTAssertNil(profiles.fallbacks(of: .qa), list)
            XCTAssertTrue(profiles.fallbacks.isEmpty, list)
        }
        let flow = try RunProfilesConfig.profiles(in: "runs: { qa: { model: a, fallbacks: [] } }\n")
        XCTAssertNil(flow.fallbacks(of: .qa))
    }

    func testReadsAListInAFlowRunsBlock() throws {
        let profiles = try RunProfilesConfig.profiles(in: "runs: { default: { model: a, fallbacks: [{ model: b }, {provider: 'x'}] } }\n")
        XCTAssertEqual(profiles.fallbacks(of: nil), [RunFallback(model: "b"), RunFallback(provider: "x")])
    }

    func testRefusesAListItCannotRead() {
        let cases: [(String, String)] = [
            ("runs:\n  qa:\n    fallbacks:\n      model: x\n", "should be a list"),
            ("runs:\n  qa:\n    fallbacks: { model: x }\n", "should be a list"),
            ("runs:\n  qa: { fallbacks: { model: x } }\n", "should be a list"),
            ("runs:\n  qa:\n    fallbacks: [claude]\n", "each fallback should be a map"),
            ("runs:\n  qa:\n    fallbacks:\n      - claude\n", "each fallback should be a map"),
            ("runs:\n  qa:\n    fallbacks:\n      - { model: x }\n        model: y\n", "each fallback should be a map"),
            ("runs:\n  qa:\n    fallbacks:\n      - model: [a]\n", "should be a single value"),
            ("runs:\n  qa:\n    fallbacks: [{ model: { a: b } }]\n", "should be a single value"),
            ("runs:\n  qa:\n    fallbacks: [{ model: x }\n", "has no closing"),
            ("runs:\n  qa:\n    fallbacks: [{ model: x } x]\n", "has no closing"),
        ]
        for (yaml, reason) in cases {
            XCTAssertThrowsError(try RunProfilesConfig.profiles(in: yaml), yaml) { error in
                guard case .unsupported(_, let message)? = error as? RunProfilesConfigError else {
                    return XCTFail("\(error)")
                }
                XCTAssertTrue(message.contains(reason), "\(yaml): \(message)")
            }
        }
    }

    // MARK: Writing

    func testChangingOneItemRewritesOnlyThatItem() throws {
        let list = [
            RunFallback(harness: "opencode", provider: "opencode-go", model: "kimi-k3"),
            RunFallback(provider: "openrouter", model: "acme/fast"),
        ]
        let updated = try RunProfilesConfig.settingFallbacks(list, of: nil, in: config)

        XCTAssertEqual(updated, config.replacingOccurrences(
            of: "      - provider: openrouter\n        model: acme/chat\n",
            with: "      - { provider: openrouter, model: acme/fast }\n"
        ))
        XCTAssertEqual(try RunProfilesConfig.profiles(in: updated).fallbacks(of: nil), list)
    }

    func testAChangedFlowItemKeepsItsComment() throws {
        let list = [
            RunFallback(harness: "opencode", provider: "opencode-go", model: "glm-5"),
            RunFallback(provider: "openrouter", model: "acme/chat"),
        ]
        let updated = try RunProfilesConfig.settingFallbacks(list, of: nil, in: config)

        XCTAssertEqual(updated, config.replacingOccurrences(
            of: "model: kimi-k3 }  # cheap",
            with: "model: glm-5 }  # cheap"
        ))
    }

    func testAddingAndRemovingItemsKeepsTheCommentsBetweenThem() throws {
        let longer = [
            RunFallback(harness: "opencode", provider: "opencode-go", model: "kimi-k3"),
            RunFallback(provider: "openrouter", model: "acme/chat"),
            RunFallback(model: "claude-sonnet-5-5", effort: "low"),
        ]
        let added = try RunProfilesConfig.settingFallbacks(longer, of: nil, in: config)
        XCTAssertEqual(added, config.replacingOccurrences(
            of: "        model: acme/chat\n",
            with: "        model: acme/chat\n      - { model: claude-sonnet-5-5, effort: low }\n"
        ))

        let shorter = try RunProfilesConfig.settingFallbacks([RunFallback(model: "x")], of: nil, in: config)
        XCTAssertEqual(shorter, config.replacingOccurrences(
            of: "      - { harness: opencode, provider: opencode-go, model: kimi-k3 }  # cheap\n      # Then OpenRouter.\n      - provider: openrouter\n        model: acme/chat\n",
            with: "      - { model: x }  # cheap\n      # Then OpenRouter.\n"
        ))
    }

    func testRemovingAListRemovesItsLinesAndAnEntryItLeftEmpty() throws {
        let block = try RunProfilesConfig.settingFallbacks(nil, of: nil, in: config)
        XCTAssertEqual(block, config.replacingOccurrences(
            of: "    fallbacks:\n      - { harness: opencode, provider: opencode-go, model: kimi-k3 }  # cheap\n      # Then OpenRouter.\n      - provider: openrouter\n        model: acme/chat\n",
            with: ""
        ))
        XCTAssertEqual(try RunProfilesConfig.settingFallbacks([], of: nil, in: config), block)

        let flow = try RunProfilesConfig.settingFallbacks(nil, of: .landing, in: config)
        XCTAssertEqual(flow, config.replacingOccurrences(
            of: "  landing: { model: claude-sonnet-5-5, fallbacks: [{ provider: openrouter, model: acme/flash }] }",
            with: "  landing: { model: claude-sonnet-5-5 }"
        ))

        let inline = try RunProfilesConfig.settingFallbacks(nil, of: .qa, in: config)
        XCTAssertEqual(inline, config.replacingOccurrences(of: "    fallbacks: [{ model: claude-sonnet-5-5 }]  # one more\n", with: ""))

        let only = "runs:\n  qa:\n    fallbacks:\n      - { model: a }\n  rework: { effort: low }\n"
        XCTAssertEqual(try RunProfilesConfig.settingFallbacks(nil, of: .qa, in: only), "runs:\n  rework: { effort: low }\n")
        XCTAssertEqual(try RunProfilesConfig.settingFallbacks(nil, of: .rework, in: only), only)
    }

    func testChangingAnInlineListKeepsItOnItsLine() throws {
        let inline = try RunProfilesConfig.settingFallbacks([RunFallback(model: "a"), RunFallback(model: "b")], of: .qa, in: config)
        XCTAssertEqual(inline, config.replacingOccurrences(
            of: "    fallbacks: [{ model: claude-sonnet-5-5 }]  # one more",
            with: "    fallbacks: [{ model: a }, { model: b }]  # one more"
        ))

        let flow = try RunProfilesConfig.settingFallbacks([RunFallback(model: "a")], of: .landing, in: config)
        XCTAssertEqual(flow, config.replacingOccurrences(
            of: "  landing: { model: claude-sonnet-5-5, fallbacks: [{ provider: openrouter, model: acme/flash }] }",
            with: "  landing: { model: claude-sonnet-5-5, fallbacks: [{ model: a }] }"
        ))
    }

    func testANewListGoesAfterTheEntrysFields() throws {
        let yaml = "runs:\n  default:\n    model: a  # first\n    # effort later\n  qa: { model: b }\n"
        let block = try RunProfilesConfig.settingFallbacks([RunFallback(provider: "openrouter", model: "x/y")], of: nil, in: yaml)
        XCTAssertEqual(
            block,
            "runs:\n  default:\n    model: a  # first\n    fallbacks:\n      - { provider: openrouter, model: x/y }\n    # effort later\n  qa: { model: b }\n"
        )

        let flow = try RunProfilesConfig.settingFallbacks([RunFallback(model: "c")], of: .qa, in: yaml)
        XCTAssertEqual(flow, "runs:\n  default:\n    model: a  # first\n    # effort later\n  qa: { model: b, fallbacks: [{ model: c }] }\n")

        let newEntry = try RunProfilesConfig.settingFallbacks([RunFallback(model: "c")], of: .rework, in: yaml)
        XCTAssertEqual(newEntry, yaml + "  rework: { fallbacks: [{ model: c }] }\n")

        let noRuns = try RunProfilesConfig.settingFallbacks([RunFallback(model: "c")], of: .qa, in: "issues:\n  provider: linear\n")
        XCTAssertEqual(noRuns, "issues:\n  provider: linear\nruns:\n  qa: { fallbacks: [{ model: c }] }\n")

        let emptyRuns = try RunProfilesConfig.settingFallbacks([RunFallback(model: "c")], of: .qa, in: "runs: {}\n")
        XCTAssertEqual(emptyRuns, "runs:\n  qa: { fallbacks: [{ model: c }] }\n")
    }

    func testAListAtTheKeysOwnColumnStaysThere() throws {
        let yaml = "runs:\n  default:\n    model: a\n    fallbacks:\n    - { model: b }\n    - model: c\n      effort: low\n    effort: high\n"
        let updated = try RunProfilesConfig.settingFallbacks([RunFallback(model: "b"), RunFallback(model: "d")], of: nil, in: yaml)
        XCTAssertEqual(updated, "runs:\n  default:\n    model: a\n    fallbacks:\n    - { model: b }\n    - { model: d }\n    effort: high\n")
    }

    func testAnEmptyBlockListGetsItsItemsUnderTheKey() throws {
        let yaml = "runs:\n  qa:\n    model: a\n    fallbacks: ~  # none yet\n"
        let updated = try RunProfilesConfig.settingFallbacks([RunFallback(model: "b")], of: .qa, in: yaml)
        XCTAssertEqual(updated, "runs:\n  qa:\n    model: a\n    fallbacks: # none yet\n      - { model: b }\n")

        let bare = "runs:\n  qa:\n    model: a\n    fallbacks:\n  rework: { effort: low }\n"
        let filled = try RunProfilesConfig.settingFallbacks([RunFallback(model: "b")], of: .qa, in: bare)
        XCTAssertEqual(filled, "runs:\n  qa:\n    model: a\n    fallbacks:\n      - { model: b }\n  rework: { effort: low }\n")
    }

    func testARepositorysNewListIsWrittenAsBlocks() throws {
        let list = [RunFallback(provider: "openrouter", model: "x/y"), RunFallback(model: "z")]
        let updated = try RunProfilesConfig.settingFallbacks(list, of: .landing, in: config, scope: .repository("web"))

        XCTAssertEqual(updated, config.replacingOccurrences(
            of: "          - { model: claude-sonnet-5-5 }\n",
            with: "          - { model: claude-sonnet-5-5 }\n      landing:\n        fallbacks:\n          - { provider: openrouter, model: x/y }\n          - { model: z }\n"
        ))
        XCTAssertEqual(try RunProfilesConfig.profiles(in: updated, scope: .repository("web")).fallbacks(of: .landing), list)

        let noRuns = "repositories:\n  - key: api\n    workflow: ./api.md\n"
        XCTAssertEqual(
            try RunProfilesConfig.settingFallbacks([RunFallback(model: "z")], of: nil, in: noRuns, scope: .repository("api")),
            noRuns + "    runs:\n      default:\n        fallbacks:\n          - { model: z }\n"
        )
    }

    func testValuesAreQuotedWhenTheyNeedIt() throws {
        let updated = try RunProfilesConfig.settingFallbacks([RunFallback(model: "a, b")], of: .rework, in: "runs:\n  qa: { model: x }\n")
        XCTAssertEqual(updated, "runs:\n  qa: { model: x }\n  rework: { fallbacks: [{ model: \"a, b\" }] }\n")
        XCTAssertEqual(try RunProfilesConfig.profiles(in: updated).fallbacks(of: .rework), [RunFallback(model: "a, b")])
    }

    func testUpdatingWritesOnlyTheListsThatChanged() throws {
        let old = try RunProfilesConfig.scopedProfiles(in: config)
        var new = old
        new.global.setFallbacks([RunFallback(model: "a")], of: .qa)

        let updated = try RunProfilesConfig.updating(config, from: old, to: new)
        XCTAssertEqual(updated, config.replacingOccurrences(of: "[{ model: claude-sonnet-5-5 }]  # one more", with: "[{ model: a }]  # one more"))
        XCTAssertEqual(try RunProfilesConfig.scopedProfiles(in: updated), new)
    }

    func testAFallbackHasNoCommand() {
        var fallback = RunFallback(model: "a")
        fallback[.command] = "claude"
        XCTAssertNil(fallback[.command])
        XCTAssertEqual(fallback, RunFallback(model: "a"))
        XCTAssertEqual(RunProfilesConfig.renderFallback(RunFallback()), "{}")
    }
}
