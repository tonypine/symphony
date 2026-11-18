import XCTest
@testable import SymphonyBarCore

/// The model behind Factory › Runs: each kind's lines, the edits, the count of changes, Revert and Save.
final class RunsEditorTests: XCTestCase {
    private let yaml = """
        runs:
          default:
            harness: claude
            provider: anthropic
            model: claude-opus-5-5
            effort: medium
            fallbacks:
              - { provider: openrouter, model: acme/chat }
              - { harness: codex, provider: openai, model: gpt-5.5 }
          qa:
            model: claude-sonnet-5-5
          landing:
            effort: low
            fallbacks:
              - { model: claude-haiku-4-5-20251001 }
        repositories:
          - key: web
            runs:
              default:
                effort: high
              qa:
                provider: openrouter
                model: acme/qa

        """

    private let web = RunProfilesScope.repository("web")

    private func editor() throws -> RunsEditor {
        RunsEditor(try RunProfilesConfig.scopedProfiles(in: yaml))
    }

    /// Each line's harness, provider, model and effort, a `*` marking a value the kind sets itself.
    private func describe(_ lines: [RunLine]) -> [String] {
        lines.map { line in
            RunsEditor.lineFields.map { (line[$0].value ?? "-") + (line[$0].isOwn ? "*" : "") }.joined(separator: " ")
        }
    }

    /// The values each line runs with, whoever sets them.
    private func resolved(_ lines: [RunLine]) -> [[String?]] {
        lines.map { line in RunsEditor.lineFields.map { line[$0].value } }
    }

    /// The text Save would write for the editor's changes.
    private func written(_ editor: RunsEditor) throws -> String {
        try RunProfilesConfig.updating(yaml, from: editor.loaded, to: editor.profiles)
    }

    // MARK: Reading

    func testReadsEachKindsFirstChoiceAndFallbacksAndWhoSetsEachValue() throws {
        let editor = try editor()

        XCTAssertEqual(describe(editor.lines(nil)), [
            "claude* anthropic* claude-opus-5-5* medium*",
            "claude openrouter* acme/chat* medium",
            "codex* openai* gpt-5.5* medium",
        ])
        // QA sets its model and takes the rest, and Default's fallbacks, from Default.
        XCTAssertEqual(describe(editor.lines(.qa)), [
            "claude anthropic claude-sonnet-5-5* medium",
            "claude openrouter acme/chat medium",
            "codex openai gpt-5.5 medium",
        ])
        // A fallback that keeps the harness and the provider runs with the kind's effort.
        XCTAssertEqual(describe(editor.lines(.landing)), [
            "claude anthropic claude-opus-5-5 low*",
            "claude anthropic claude-haiku-4-5-20251001* low",
        ])
        XCTAssertEqual(describe(editor.lines(.breakdown)), [
            "claude anthropic claude-opus-5-5 medium",
            "claude openrouter acme/chat medium",
            "codex openai gpt-5.5 medium",
        ])
        for kind in RunKind.allCases { XCTAssertFalse(editor.lines(kind).isEmpty) }
    }

    func testReadsARepositorysOwnValuesOverTheRest() throws {
        let editor = try editor()

        XCTAssertEqual(describe(editor.lines(nil, in: web)), [
            "claude anthropic claude-opus-5-5 high*",
            "claude openrouter acme/chat high",
            "codex openai gpt-5.5 high",
        ])
        XCTAssertEqual(describe(editor.lines(.qa, in: web)), [
            "claude openrouter* acme/qa* high",
            "claude openrouter acme/chat high",
            "codex openai gpt-5.5 high",
        ])
        // The repository's Default effort wins over runs.landing's; runs.landing's fallbacks still apply.
        XCTAssertEqual(describe(editor.lines(.landing, in: web)), [
            "claude anthropic claude-opus-5-5 high",
            "claude anthropic claude-haiku-4-5-20251001 high",
        ])
        XCTAssertEqual(describe(editor.lines(.rework, in: .repository("api"))), describe(editor.lines(.rework)))
    }

    func testAFallbackOnAnotherProviderTakesNoModelFromTheFirstChoice() {
        let first = RunsEditor.resolve(RunFallback(), over: RunLine(values: [
            .harness: RunLineValue("claude", isOwn: true), .provider: RunLineValue("anthropic", isOwn: true),
            .model: RunLineValue("claude-opus-5-5", isOwn: true), .smallModel: RunLineValue("claude-haiku-4-5", isOwn: true),
        ]), isOwn: true)
        XCTAssertEqual(first.model, RunLineValue("claude-opus-5-5", isOwn: false))
        XCTAssertEqual(first[.smallModel], RunLineValue("claude-haiku-4-5", isOwn: false))

        let other = RunsEditor.resolve(RunFallback(provider: "openrouter"), over: first, isOwn: true)
        XCTAssertEqual(other.model, RunLineValue(nil, isOwn: false))
        XCTAssertEqual(other[.smallModel], RunLineValue(nil, isOwn: false))
        XCTAssertEqual(other.harness, RunLineValue("claude", isOwn: false))
        XCTAssertEqual(other.provider, RunLineValue("openrouter", isOwn: true))
    }

    // MARK: Setting values

    func testSettingAFirstChoiceValueWritesOnlyThatLine() throws {
        var editor = try editor()
        XCTAssertTrue(editor.set(.model, of: 0, kind: .qa, to: "claude-opus-5-5"))

        XCTAssertEqual(describe(editor.lines(.qa))[0], "claude anthropic claude-opus-5-5* medium")
        XCTAssertEqual(editor.changeCount, 1)
        XCTAssertEqual(try written(editor), yaml.replacingOccurrences(of: "model: claude-sonnet-5-5", with: "model: claude-opus-5-5"))
        XCTAssertFalse(editor.set(.model, of: 0, kind: .qa, to: "claude-opus-5-5"))
    }

    func testSettingAFallbackOfDefaultsListGivesTheKindItsOwnList() throws {
        var editor = try editor()
        XCTAssertTrue(editor.set(.model, of: 1, kind: .qa, to: "acme/flash"))

        XCTAssertEqual(describe(editor.lines(.qa)), [
            "claude anthropic claude-sonnet-5-5* medium",
            "claude openrouter* acme/flash* medium",
            "codex* openai* gpt-5.5* medium",
        ])
        XCTAssertEqual(describe(editor.lines(nil))[1], "claude openrouter* acme/chat* medium")
        XCTAssertEqual(editor.changeCount, 2)
        XCTAssertEqual(try written(editor), yaml.replacingOccurrences(
            of: "    model: claude-sonnet-5-5\n",
            with: "    model: claude-sonnet-5-5\n    fallbacks:\n      - { provider: openrouter, model: acme/flash }\n      - { harness: codex, provider: openai, model: gpt-5.5 }\n"
        ))
    }

    func testClearingAValueTakesItFromDefaultOrTheFirstChoice() throws {
        var editor = try editor()
        XCTAssertTrue(editor.set(.effort, of: 0, kind: .landing, to: nil))
        XCTAssertTrue(editor.set(.model, of: 1, kind: .landing, to: ""))

        XCTAssertEqual(describe(editor.lines(.landing)), [
            "claude anthropic claude-opus-5-5 medium",
            "claude anthropic claude-opus-5-5 medium",
        ])
        XCTAssertEqual(try written(editor), yaml.replacingOccurrences(
            of: "    effort: low\n    fallbacks:\n      - { model: claude-haiku-4-5-20251001 }\n",
            with: "    fallbacks:\n      - {}\n"
        ))
    }

    func testSettingALineThatDoesNotExistChangesNothing() throws {
        var editor = try editor()
        XCTAssertFalse(editor.set(.model, of: 3, kind: .landing, to: "x"))
        XCTAssertFalse(editor.set(.command, of: 1, kind: .landing, to: "claude"))
        XCTAssertFalse(editor.hasChanges)

        XCTAssertTrue(editor.set(.command, of: 0, kind: .landing, to: "claude --fast"))
        XCTAssertEqual(editor.profiles.global[.landing].command, "claude --fast")
    }

    // MARK: Use Default's

    func testUseDefaultsClearsWhatTheKindSetsItself() throws {
        var editor = try editor()
        XCTAssertFalse(editor.canUseDefaults(nil))
        XCTAssertFalse(editor.canUseDefaults(.breakdown))
        XCTAssertTrue(editor.canUseDefaults(.landing))
        XCTAssertTrue(editor.canUseDefaults(nil, in: web))
        XCTAssertFalse(editor.useDefaults(.breakdown))

        XCTAssertTrue(editor.useDefaults(.landing))
        XCTAssertEqual(describe(editor.lines(.landing)), [
            "claude anthropic claude-opus-5-5 medium",
            "claude openrouter acme/chat medium",
            "codex openai gpt-5.5 medium",
        ])
        XCTAssertFalse(editor.canUseDefaults(.landing))
        XCTAssertEqual(editor.changeCount, 2)
        XCTAssertEqual(try written(editor), yaml.replacingOccurrences(
            of: "  landing:\n    effort: low\n    fallbacks:\n      - { model: claude-haiku-4-5-20251001 }\n",
            with: ""
        ))
    }

    func testUseDefaultsKeepsTheSmallModelAndCommand() throws {
        var editor = RunsEditor(try RunProfilesConfig.scopedProfiles(in: "runs:\n  qa: { model: a, small_model: s, command: claude --fast }\n"))
        XCTAssertTrue(editor.useDefaults(.qa))
        XCTAssertEqual(editor.profiles.global[.qa], RunProfile(smallModel: "s", command: "claude --fast"))
        XCTAssertFalse(editor.canUseDefaults(.qa))
    }

    // MARK: Adding and removing lines

    func testAddsAFallbackAfterTheLastLine() throws {
        var editor = try editor()
        editor.addFallback(.landing)
        XCTAssertEqual(describe(editor.lines(.landing)).last, "claude anthropic claude-opus-5-5 low")
        XCTAssertEqual(editor.changeCount, 1)
        XCTAssertEqual(try written(editor), yaml.replacingOccurrences(
            of: "      - { model: claude-haiku-4-5-20251001 }\n",
            with: "      - { model: claude-haiku-4-5-20251001 }\n      - {}\n"
        ))

        // A kind taking Default's fallbacks gets a copy of them, then the new one.
        editor.addFallback(.qa)
        XCTAssertEqual(editor.profiles.global.fallbacks(of: .qa), [
            RunFallback(provider: "openrouter", model: "acme/chat"),
            RunFallback(harness: "codex", provider: "openai", model: "gpt-5.5"),
            RunFallback(),
        ])
        XCTAssertTrue(editor.set(.provider, of: 3, kind: .qa, to: "opencode-go"))
        XCTAssertTrue(editor.set(.model, of: 3, kind: .qa, to: "kimi-k3"))
        XCTAssertEqual(describe(editor.lines(.qa))[3], "claude opencode-go* kimi-k3* medium")
        XCTAssertEqual(editor.changeCount, 4)
    }

    func testTheOnlyLineCannotBeRemoved() throws {
        var editor = RunsEditor(try RunProfilesConfig.scopedProfiles(in: "runs:\n  default: { harness: claude, provider: anthropic, model: a }\n"))
        XCTAssertEqual(editor.lines(.qa).count, 1)
        XCTAssertFalse(editor.canRemove(0, of: .qa))
        XCTAssertFalse(editor.remove(0, of: .qa))
        XCTAssertFalse(editor.canRemove(1, of: .qa))
        XCTAssertFalse(editor.hasChanges)

        editor.addFallback(.qa)
        XCTAssertTrue(editor.canRemove(1, of: .qa))
        XCTAssertTrue(editor.remove(1, of: .qa))
        XCTAssertFalse(editor.hasChanges)
    }

    func testTheLastOwnFallbackStaysWhileDefaultHasAList() throws {
        // Symphony reads an empty list as none set, so landing would take Default's two fallbacks again.
        let editor = try editor()
        XCTAssertFalse(editor.canRemove(1, of: .landing))
        XCTAssertFalse(editor.canRemove(0, of: .landing))
        XCTAssertTrue(editor.canRemove(1, of: .qa))
        XCTAssertTrue(editor.canRemove(1, of: nil))
    }

    func testRemovesAFallback() throws {
        var editor = try editor()
        XCTAssertTrue(editor.remove(2, of: nil))

        XCTAssertEqual(describe(editor.lines(nil)), ["claude* anthropic* claude-opus-5-5* medium*", "claude openrouter* acme/chat* medium"])
        XCTAssertEqual(editor.changeCount, 1)
        XCTAssertEqual(try written(editor), yaml.replacingOccurrences(of: "      - { harness: codex, provider: openai, model: gpt-5.5 }\n", with: ""))
    }

    func testRemovingTheFirstChoiceMakesTheFirstFallbackTheFirstChoice() throws {
        var editor = try editor()
        let before = resolved(editor.lines(nil))
        XCTAssertTrue(editor.remove(0, of: nil))

        XCTAssertEqual(resolved(editor.lines(nil)), Array(before.dropFirst()))
        XCTAssertEqual(describe(editor.lines(nil)), ["claude* openrouter* acme/chat* medium*", "codex* openai* gpt-5.5* medium"])
        XCTAssertEqual(try written(editor), yaml.replacingOccurrences(
            of: "    provider: anthropic\n    model: claude-opus-5-5\n    effort: medium\n    fallbacks:\n      - { provider: openrouter, model: acme/chat }\n      - { harness: codex, provider: openai, model: gpt-5.5 }\n",
            with: "    provider: openrouter\n    model: acme/chat\n    effort: medium\n    fallbacks:\n      - { harness: codex, provider: openai, model: gpt-5.5 }\n"
        ))
    }

    // MARK: Moving lines

    func testMovesAFallbackAmongTheFallbacks() throws {
        var editor = try editor()
        XCTAssertTrue(editor.move(2, to: 1, of: nil))

        XCTAssertEqual(describe(editor.lines(nil)), [
            "claude* anthropic* claude-opus-5-5* medium*",
            "codex* openai* gpt-5.5* medium",
            "claude openrouter* acme/chat* medium",
        ])
        XCTAssertEqual(editor.changeCount, 2)
        XCTAssertFalse(editor.move(1, to: 1, of: nil))
        XCTAssertFalse(editor.move(0, to: 3, of: nil))
        XCTAssertFalse(editor.move(-1, to: 0, of: nil))
    }

    func testMovesAFallbackAboveTheFirstChoice() throws {
        var editor = try editor()
        XCTAssertTrue(editor.move(2, to: 0, of: nil))

        XCTAssertEqual(describe(editor.lines(nil)), [
            "codex* openai* gpt-5.5* medium*",
            "claude* anthropic* claude-opus-5-5* medium*",
            "claude* openrouter* acme/chat* medium",
        ])
        XCTAssertEqual(try written(editor), yaml.replacingOccurrences(
            of: "    harness: claude\n    provider: anthropic\n    model: claude-opus-5-5\n    effort: medium\n    fallbacks:\n      - { provider: openrouter, model: acme/chat }\n      - { harness: codex, provider: openai, model: gpt-5.5 }\n",
            with: "    harness: codex\n    provider: openai\n    model: gpt-5.5\n    effort: medium\n    fallbacks:\n      - { harness: claude, provider: anthropic, model: claude-opus-5-5, effort: medium }\n      - { harness: claude, provider: openrouter, model: acme/chat }\n"
        ))
    }

    func testAMoveAboveTheFirstChoiceKeepsWhatAKindTakesFromDefault() throws {
        var editor = try editor()
        // QA sets only its model; its fallbacks are Default's.
        XCTAssertTrue(editor.move(1, to: 0, of: .qa))

        XCTAssertEqual(describe(editor.lines(.qa)), [
            "claude openrouter* acme/chat* medium",
            "claude anthropic* claude-sonnet-5-5* medium",
            "codex* openai* gpt-5.5* medium",
        ])
        XCTAssertEqual(editor.profiles.global[.qa], RunProfile(model: "acme/chat", provider: "openrouter"))
    }

    func testEveryMoveKeepsWhatEachLineRunsWithAndSurvivesASave() throws {
        let original = try editor()
        for scope in [RunProfilesScope.global, web] {
            for kind in RunProfilesConfig.scopes {
                let lines = original.lines(kind, in: scope)
                for from in lines.indices {
                    for to in lines.indices where to != from {
                        var editor = original
                        XCTAssertTrue(editor.move(from, to: to, of: kind, in: scope))
                        var expected = resolved(lines)
                        expected.insert(expected.remove(at: from), at: to)
                        let label = "\(scope) \(kind?.rawValue ?? "default") \(from)→\(to)"
                        XCTAssertEqual(resolved(editor.lines(kind, in: scope)), expected, label)
                        XCTAssertEqual(try RunProfilesConfig.scopedProfiles(in: written(editor)), editor.profiles, label)
                    }
                }
            }
        }
    }

    // MARK: Changes

    func testCountsChangesAndReverts() throws {
        var editor = try editor()
        XCTAssertEqual(editor.changeCount, 0)
        XCTAssertFalse(editor.hasChanges)

        editor.set(.effort, of: 0, kind: .qa, to: "high")
        editor.set(.model, of: 0, kind: .landing, in: web, to: "claude-sonnet-5-5")
        editor.setCommand("codex app-server", of: .codex)
        editor.setSmallModel("anthropic/claude-haiku-4.5", of: .claude, on: "openrouter")
        XCTAssertEqual(editor.changeCount, 4)
        XCTAssertTrue(editor.hasChanges)

        editor.revert()
        XCTAssertEqual(editor.profiles, editor.loaded)
        XCTAssertEqual(editor.changeCount, 0)
        XCTAssertFalse(editor.hasChanges)
    }

    func testARepositorysEditIsWrittenUnderThatRepository() throws {
        var editor = try editor()
        editor.set(.model, of: 0, kind: .landing, in: web, to: "claude-sonnet-5-5")
        XCTAssertEqual(describe(editor.lines(.landing, in: web))[0], "claude anthropic claude-sonnet-5-5* high")
        XCTAssertEqual(describe(editor.lines(.landing))[0], "claude anthropic claude-opus-5-5 low*")

        XCTAssertEqual(try written(editor), yaml.replacingOccurrences(
            of: "        model: acme/qa\n",
            with: "        model: acme/qa\n      landing:\n        model: claude-sonnet-5-5\n"
        ))
    }

    // MARK: Harnesses

    func testTheHarnessesBlockShowsTheHarnessesInUseAndTheirProviders() throws {
        var editor = try editor()
        XCTAssertEqual(editor.harnesses, [.claude, .codex])
        XCTAssertEqual(editor.smallModelProviders(of: .claude), [RunProfilesConfig.anthropic, RunProfilesConfig.openRouter])
        XCTAssertEqual(editor.smallModelProviders(of: .codex), [])
        XCTAssertEqual(editor.smallModelProviders(of: .opencode), [])

        XCTAssertTrue(editor.setSmallModel("kimi-k3", of: .opencode, on: RunProfilesConfig.openCodeGo))
        XCTAssertEqual(editor.harnesses, [.claude, .codex, .opencode])
        XCTAssertEqual(editor.smallModelProviders(of: .opencode), [RunProfilesConfig.openCodeGo])
        XCTAssertTrue(editor.setSmallModel("", of: .opencode, on: RunProfilesConfig.openCodeGo))
        XCTAssertFalse(editor.setSmallModel(nil, of: .opencode, on: RunProfilesConfig.openCodeGo))
        XCTAssertEqual(editor.harnesses, [.claude, .codex])
    }

    func testHarnessSettingsAreSavedTheSameWay() throws {
        var editor = try editor()
        XCTAssertTrue(editor.setCommand("codex app-server", of: .codex))
        XCTAssertFalse(editor.setCommand("codex app-server", of: .codex))
        XCTAssertEqual(editor.changeCount, 1)
        XCTAssertEqual(try written(editor), yaml + "execution:\n  harnesses:\n    codex:\n      command: codex app-server\n")

        XCTAssertTrue(editor.setCommand(" ", of: .codex))
        XCTAssertFalse(editor.hasChanges)
    }

    // MARK: Saving

    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/run-profiles", isDirectory: true)
    }

    private func copyOfFixture() throws -> (SymphonyConfigFile, URL) {
        let directory = uniqueTemporaryDirectory("runs-editor")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("symphony.yml")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("symphony.yml"), to: path)
        return (SymphonyConfigFile(path: path.path), directory)
    }

    func testSaveWritesOnlyTheChangedLinesAndKeepsEveryComment() async throws {
        let (file, directory) = try copyOfFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var editor = RunsEditor(try file.readScopedRunProfiles())

        editor.set(.model, of: 0, kind: .qa, to: "claude-opus-5-5")
        editor.addFallback(.qa)
        editor.set(.provider, of: 2, kind: .qa, to: "opencode-go")
        editor.set(.model, of: 2, kind: .qa, to: "kimi-k3")
        XCTAssertTrue(editor.move(1, to: 0, of: .landing, in: web))
        editor.set(.model, of: 1, kind: nil, to: "acme/flash")
        editor.setSmallModel("anthropic/claude-haiku-4.5", of: .claude, on: "openrouter")
        XCTAssertEqual(editor.changeCount, 8)

        var checked: [String] = []
        let outcome = await editor.save(to: file) { candidate in
            checked.append((try? String(contentsOfFile: candidate, encoding: .utf8)) ?? "")
            return .passed
        }
        let golden = try String(contentsOf: fixtures.appendingPathComponent("symphony.saved.yml"), encoding: .utf8)
        XCTAssertEqual(try String(contentsOfFile: file.path, encoding: .utf8), golden)
        XCTAssertEqual(checked, [golden])
        XCTAssertEqual(outcome, .saved(try RunProfilesConfig.scopedProfiles(in: golden)))

        editor.apply(outcome)
        XCTAssertEqual(editor.changeCount, 0)
        XCTAssertEqual(editor.loaded, try file.readScopedRunProfiles())
    }

    func testARefusedSaveKeepsEveryChangeAndTheFile() async throws {
        let (file, directory) = try copyOfFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try String(contentsOfFile: file.path, encoding: .utf8)
        var editor = RunsEditor(try file.readScopedRunProfiles())
        editor.addFallback(.qa)
        editor.set(.harness, of: 2, kind: .qa, to: "codex")
        let edited = editor

        let outcome = await editor.save(to: file) { candidate in
            .failed("Config error in \(candidate): runs.qa.fallbacks[1] changes the harness or the provider, so it must set `model`")
        }
        XCTAssertEqual(outcome, .refused(
            "runs.qa.fallbacks[1] changes the harness or the provider, so it must set `model` (in \(file.url.path))"
        ))
        editor.apply(outcome)
        XCTAssertEqual(editor, edited)
        XCTAssertEqual(editor.changeCount, 2)
        XCTAssertEqual(try String(contentsOfFile: file.path, encoding: .utf8), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["symphony.yml"])
    }

    func testASaveThatCannotReadTheFileReturnsWhy() async throws {
        let directory = uniqueTemporaryDirectory("runs-editor-missing")
        let file = SymphonyConfigFile(path: directory.appendingPathComponent("symphony.yml").path)
        var editor = RunsEditor(ScopedRunProfiles())
        editor.set(.model, of: 0, kind: .qa, to: "a")

        guard case .refused(let reason) = await editor.save(to: file, checkingWith: { _ in .passed }) else {
            return XCTFail("saved a missing file")
        }
        XCTAssertFalse(reason.isEmpty)
    }
}
