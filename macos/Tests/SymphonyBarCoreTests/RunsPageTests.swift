import XCTest
@testable import SymphonyBarCore

/// Factory › Runs (TP-1538): what the page shows of each kind of run, its edits, For, and Save and Revert.
final class RunsPageTests: XCTestCase {
    private let yaml = """
        # Operator config.
        runs:
          default:
            harness: claude
            provider: anthropic
            model: claude-opus-5-5  # the best
            effort: medium
          # QA reads a lot.
          qa:
            model: claude-sonnet-5-5
            fallbacks:
              - { provider: openrouter, model: deepseek/deepseek-flash }
        repositories:
          - key: web
            runs:
              qa:
                effort: low
          - key: api

        """

    private let web = RunProfilesScope.repository("web")

    private func page() throws -> RunsPage {
        var page = RunsPage()
        page.load(try RunProfilesConfig.scopedProfiles(in: yaml), repositories: try RunProfilesConfig.repositoryKeys(in: yaml))
        return page
    }

    private func row(_ kind: RunKind?, of page: RunsPage) -> RunsPage.Row {
        page.rows.first { $0.kind == kind }!
    }

    /// Each line's four values as shown, a `*` marking one the kind sets itself.
    private func describe(_ row: RunsPage.Row) -> [String] {
        row.lines.map { line in line.fields.map { $0.title + ($0.isOwn ? "*" : "") }.joined(separator: " ") }
    }

    private func file(_ text: String) throws -> (SymphonyConfigFile, URL) {
        let directory = uniqueTemporaryDirectory("runs-page")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("symphony.yml")
        try text.write(to: path, atomically: true, encoding: .utf8)
        return (SymphonyConfigFile(path: path.path), directory)
    }

    // MARK: What the page shows

    func testListsDefaultAndTheNineKindsEachWithItsFirstChoiceThenItsFallbacks() throws {
        let page = try page()
        XCTAssertEqual(page.rows.map(\.title), [
            "Default", "Implementation", "Breakdown", "Rework", "Code Review", "QA", "CI Fix", "Review Feedback", "Landing", "Epic Review",
        ])
        XCTAssertEqual(Set(page.rows.compactMap(\.kind)), Set(RunKind.allCases))
        XCTAssertEqual(describe(row(nil, of: page)), ["Claude* Anthropic* claude-opus-5-5* medium*"])
        XCTAssertEqual(describe(row(.implementation, of: page)), ["Claude Anthropic claude-opus-5-5 medium"], "every value from Default is grey")
        XCTAssertEqual(describe(row(.qa, of: page)), [
            "Claude Anthropic claude-sonnet-5-5* medium",
            "Claude OpenRouter* deepseek/deepseek-flash* medium",
        ])
        XCTAssertEqual(row(.qa, of: page).lines.map(\.id), [0, 1])
        XCTAssertEqual(row(.qa, of: page).lines.first?.fields.map(\.label), ["Harness", "Provider", "Model", "Effort"])
        XCTAssertEqual(row(.qa, of: page).lines.first?.fields.map(\.isSearchable), [false, false, true, false])
        XCTAssertEqual(row(nil, of: page).id, "default")
        XCTAssertTrue(row(nil, of: page).isDefault)
        XCTAssertEqual(row(.qa, of: page).id, "qa")
    }

    func testAKindWithNoFallbackSaysARunWaitsWhenItsProviderCantTakeIt() throws {
        let page = try page()
        XCTAssertEqual(row(.implementation, of: page).waits, "No fallback: a run waits when Anthropic can’t take it")
        XCTAssertNil(row(.qa, of: page).waits)
        XCTAssertEqual(RunsPage.waits(provider: nil), "No fallback: a run waits when its provider can’t take it")
        XCTAssertEqual(RunsPage.waits(provider: "acme"), "No fallback: a run waits when acme can’t take it")
    }

    func testProviderListsOnlyWhatTheHarnessReachesAndModelOffersTheProvidersModels() throws {
        var page = try page()
        let first = row(.qa, of: page).lines[0].fields
        XCTAssertEqual(first[0].choices.map(\.title), ["Claude", "Codex", "OpenCode"])
        XCTAssertEqual(first[1].choices.map(\.title), ["Anthropic", "OpenRouter", "OpenCode Go"])
        XCTAssertEqual(first[2].choices.map(\.value), ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5-20251001"])
        XCTAssertEqual(first[2].choices.map(\.title), first[2].choices.map(\.value), "models show as their identifiers")
        XCTAssertEqual(first[3].choices.map(\.title), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(row(.qa, of: page).lines[1].fields[2].choices.map(\.title), ["deepseek/deepseek-flash"], "a list not loaded offers the value")

        page.lists.openRouter = .success([
            OpenRouterModel(id: "deepseek/deepseek-v4-pro", name: "DeepSeek V4 Pro", supportsTools: true),
        ])
        XCTAssertEqual(row(.qa, of: page).lines[1].fields[2].choices.map(\.title), ["deepseek/deepseek-v4-pro", "deepseek/deepseek-flash"])

        page.pick(.harness, of: 0, kind: .qa, to: "opencode")
        XCTAssertEqual(row(.qa, of: page).lines[0].fields[1].choices.map(\.title), ["OpenCode Go"])
    }

    func testAValueNoOneSetsShowsNoneAndOffersIt() {
        var page = RunsPage()
        page.load(ScopedRunProfiles(), repositories: [])
        let fields = page.rows[0].lines[0].fields
        XCTAssertEqual(fields.map(\.title), ["None", "None", "None", "None"])
        XCTAssertEqual(fields[0].choices.first, RunsPage.Choice(nil, "None"))
        XCTAssertEqual(fields[1].choices.count, 1 + RunProfilesConfig.providers.count, "no harness: every provider")
        XCTAssertEqual(fields[2].choices, [RunsPage.Choice(nil, "None")])
        XCTAssertEqual(page.rows[0].waits, "No fallback: a run waits when its provider can’t take it")
        XCTAssertEqual(RunsPage.providerTitle("acme"), "acme")
        XCTAssertEqual(RunsPage.harnessTitle("acme"), "acme")
        XCTAssertEqual(RunsPage.harnessTitle("opencode"), "OpenCode")
    }

    func testUseDefaultsShowsOnlyWhereTheKindSetsSomethingAndClearsIt() throws {
        var page = try page()
        XCTAssertFalse(row(nil, of: page).canUseDefaults, "Default of all repositories takes nothing")
        XCTAssertFalse(row(.implementation, of: page).canUseDefaults)
        XCTAssertTrue(row(.qa, of: page).canUseDefaults)

        page.useDefaults(.qa)
        XCTAssertEqual(describe(row(.qa, of: page)), ["Claude Anthropic claude-opus-5-5 medium"])
        XCTAssertEqual(page.changeCount, 2)
        let before = page
        page.useDefaults(nil)
        XCTAssertEqual(page, before, "nothing to clear")
    }

    func testTheOnlyLineHasNoRemoveAndTheRemoveHelpNamesWhatHappens() throws {
        var page = try page()
        XCTAssertEqual(row(.implementation, of: page).lines.map(\.removable), [false])
        XCTAssertEqual(row(.qa, of: page).lines.map(\.removable), [true, true])
        XCTAssertEqual(row(.qa, of: page).lines.map(\.removeHelp), ["Remove; the next one becomes the first choice", "Remove this fallback"])

        page.remove(1, of: .qa)
        XCTAssertEqual(row(.qa, of: page).lines.count, 1)
        XCTAssertEqual(row(.qa, of: page).waits, "No fallback: a run waits when Anthropic can’t take it")
        let before = page
        page.remove(0, of: .qa)
        XCTAssertEqual(page, before, "the only line stays")
    }

    // MARK: Editing

    func testPickingAModelMakesItTheKindsOwnAndCountsOneChange() throws {
        var page = try page()
        page.pick(.model, of: 0, kind: .implementation, to: "claude-sonnet-5-5")
        XCTAssertEqual(describe(row(.implementation, of: page)), ["Claude Anthropic claude-sonnet-5-5* medium"])
        XCTAssertEqual(page.changeCount, 1)
        let before = page
        page.pick(.model, of: 0, kind: .implementation, to: "claude-sonnet-5-5")
        XCTAssertEqual(page, before, "the same value changes nothing")
    }

    func testAHarnessThatDoesntReachTheProviderTakesItsFirstAndAKnownListItsFirstModel() throws {
        var page = try page()
        page.pick(.harness, of: 0, kind: .implementation, to: "codex")
        XCTAssertEqual(describe(row(.implementation, of: page)), ["Codex* OpenAI* gpt-5.5* medium"])

        page.lists.openCodeGo = .success([RunProfileChoice(id: "kimi-k3", title: "kimi-k3")])
        page.pick(.harness, of: 0, kind: .breakdown, to: "opencode")
        XCTAssertEqual(describe(row(.breakdown, of: page)), ["OpenCode* OpenCode Go* kimi-k3* medium"])

        page.pick(.provider, of: 0, kind: .rework, to: "openrouter")
        XCTAssertEqual(describe(row(.rework, of: page)), ["Claude OpenRouter* claude-opus-5-5 medium"], "a list not loaded keeps the model")
        page.pick(.harness, of: 0, kind: .landing, to: "claude")
        XCTAssertEqual(describe(row(.landing, of: page)), ["Claude* Anthropic claude-opus-5-5 medium"], "the provider is reached")
    }

    func testAddingAFallbackPickingItsProviderAndModelAndDraggingItAboveTheOther() throws {
        var page = try page()
        page.lists.openCodeGo = .success(["kimi-k3", "hy4-flash"].map { RunProfileChoice(id: $0, title: $0) })
        page.addFallback(.qa)
        XCTAssertEqual(describe(row(.qa, of: page)).last, "Claude Anthropic claude-sonnet-5-5 medium", "a new fallback runs as the first choice")
        let added = page.changeCount
        XCTAssertGreaterThan(added, 0)

        page.pick(.provider, of: 2, kind: .qa, to: "opencode-go")
        XCTAssertEqual(describe(row(.qa, of: page)).last, "Claude OpenCode Go* kimi-k3* medium")
        page.pick(.model, of: 2, kind: .qa, to: "hy4-flash")
        page.reorder(.qa, to: [0, 2, 1])
        XCTAssertEqual(describe(row(.qa, of: page)), [
            "Claude Anthropic claude-sonnet-5-5* medium",
            "Claude OpenCode Go* hy4-flash* medium",
            "Claude OpenRouter* deepseek/deepseek-flash* medium",
        ])
        XCTAssertGreaterThan(page.changeCount, added)

        let before = page
        page.reorder(.qa, to: [0, 1, 2])
        XCTAssertEqual(page, before, "nothing moved")
    }

    func testALineDraggedAboveTheFirstChoiceBecomesIt() throws {
        var page = try page()
        page.reorder(.qa, to: [1, 0])
        XCTAssertEqual(describe(row(.qa, of: page)), [
            "Claude OpenRouter* deepseek/deepseek-flash* medium",
            "Claude Anthropic* claude-sonnet-5-5* medium",
        ])
    }

    private func moved(_ order: [Int]) -> [Int]? {
        RunsPage.move(in: order).map { [$0.from, $0.to] }
    }

    func testTheMovedLineIsFoundInTheNewOrder() {
        XCTAssertNil(moved([0, 1, 2]))
        XCTAssertNil(moved([1, 0, 3, 2]), "two moves")
        XCTAssertEqual(moved([1, 0]), [1, 0])
        XCTAssertEqual(moved([0, 2, 1]), [2, 1])
        XCTAssertEqual(moved([2, 0, 1]), [2, 0])
        XCTAssertEqual(moved([1, 2, 0]), [0, 2])
    }

    func testRevertPutsEveryValueBackAndTheCountGoes() throws {
        var page = try page()
        page.pick(.effort, of: 0, kind: .qa, to: "max")
        XCTAssertEqual(page.changeCount, 1)
        page.revert()
        XCTAssertEqual(page.changeCount, 0)
        XCTAssertEqual(describe(row(.qa, of: page))[0], "Claude Anthropic claude-sonnet-5-5* medium")
    }

    func testNothingHappensBeforeTheFileIsRead() {
        var page = RunsPage()
        XCTAssertEqual(page.rows, [])
        XCTAssertEqual(page.changeCount, 0)
        page.pick(.model, of: 0, kind: .qa, to: "a")
        page.useDefaults(.qa)
        page.addFallback(.qa)
        page.remove(1, of: .qa)
        page.reorder(.qa, to: [1, 0])
        page.revert()
        XCTAssertNil(page.beginSave())
        XCTAssertEqual(page, RunsPage())
    }

    // MARK: For

    func testForSwitchesToARepositorysOwnValuesWithTheRestGrey() throws {
        var page = try page()
        XCTAssertEqual(page.scopes.map(\.title), ["All repositories", "web", "api"])
        page.show(web)
        XCTAssertEqual(page.scope, web)
        XCTAssertEqual(describe(row(.qa, of: page))[0], "Claude Anthropic claude-sonnet-5-5 low*")
        XCTAssertEqual(describe(row(nil, of: page)), ["Claude Anthropic claude-opus-5-5 medium"])

        page.pick(.model, of: 0, kind: .qa, to: "claude-opus-5-5")
        XCTAssertEqual(page.editor?.profiles[web][.qa].model, "claude-opus-5-5")
        XCTAssertNil(page.editor?.profiles.global[.qa].effort, "the repository's own values change only")

        page.load(try RunProfilesConfig.scopedProfiles(in: yaml), repositories: ["api"])
        XCTAssertEqual(page.scope, .global, "a repository gone from the file sends For back to All repositories")
        XCTAssertEqual(page.changeCount, 1, "a read keeps the changes not saved")
    }

    // MARK: Reading the file

    func testReadsTheFileAndSaysWhyWhenItCant() throws {
        let (file, directory) = try file(yaml)
        defer { try? FileManager.default.removeItem(at: directory) }
        var page = RunsPage()
        page.read(file)
        XCTAssertNil(page.loadError)
        XCTAssertEqual(page.repositories, ["web", "api"])
        XCTAssertEqual(row(.qa, of: page).lines.count, 2)

        var none = RunsPage()
        none.read(nil)
        XCTAssertNil(none.editor)
        XCTAssertEqual(none.loadError, "Choose symphony.yml in Settings to set the runs.")

        var missing = RunsPage()
        missing.read(SymphonyConfigFile(path: directory.appendingPathComponent("gone.yml").path))
        XCTAssertNil(missing.editor)
        XCTAssertNotNil(missing.loadError)

        page.pick(.effort, of: 0, kind: .qa, to: "max")
        page.read(nil)
        XCTAssertEqual(page.changeCount, 1, "a page with changes not saved keeps them")
        XCTAssertNil(page.loadError)
    }

    // MARK: Saving

    func testSaveWritesTheValuesKeepsTheCommentsAndSaysSaved() async throws {
        let (file, directory) = try file(yaml)
        defer { try? FileManager.default.removeItem(at: directory) }
        var page = RunsPage()
        page.read(file)
        XCTAssertFalse(page.canSave, "Save is off with nothing to save")
        XCTAssertNil(page.beginSave())

        page.pick(.model, of: 0, kind: .qa, to: "claude-opus-5-5")
        XCTAssertTrue(page.canSave)
        let editor = try XCTUnwrap(page.beginSave())
        XCTAssertEqual(page.save, .saving)
        XCTAssertFalse(page.canSave, "Save is off while a save is under way")
        XCTAssertNil(page.beginSave())

        var checked = 0
        let outcome = await editor.save(to: file) { _ in
            checked += 1
            return .passed
        }
        page.finishSave(outcome)
        XCTAssertEqual(checked, 1, "Save checks the whole file")
        XCTAssertEqual(page.save, .saved)
        XCTAssertEqual(page.changeCount, 0)
        let text = try String(contentsOfFile: file.path, encoding: .utf8)
        XCTAssertTrue(text.contains("model: claude-opus-5-5  # the best"))
        XCTAssertTrue(text.contains("# QA reads a lot."))
        XCTAssertTrue(text.contains("model: claude-opus-5-5\n    fallbacks:"))

        page.clearSaved()
        XCTAssertEqual(page.save, .editing)
        page.clearSaved()
        XCTAssertEqual(page.save, .editing)
    }

    func testARefusedSaveKeepsEveryChangeAndShowsWhyUntilTheNextEdit() async throws {
        let (file, directory) = try file(yaml)
        defer { try? FileManager.default.removeItem(at: directory) }
        var page = RunsPage()
        page.read(file)
        page.pick(.model, of: 0, kind: .qa, to: "claude-opus-5-5")
        let editor = try XCTUnwrap(page.beginSave())
        page.finishSave(await editor.save(to: file) { _ in .failed("runs.qa resolves no model") })

        guard case .refused(let reason) = page.save else { return XCTFail("saved") }
        XCTAssertTrue(reason.contains("runs.qa resolves no model"))
        XCTAssertEqual(page.changeCount, 1)
        XCTAssertEqual(try String(contentsOfFile: file.path, encoding: .utf8), yaml)
        page.clearSaved()
        XCTAssertEqual(page.save, .refused(reason), "only Saved goes by itself")

        page.pick(.effort, of: 0, kind: .qa, to: "max")
        XCTAssertEqual(page.save, .editing)
        XCTAssertEqual(page.changeCount, 2)
    }
}
