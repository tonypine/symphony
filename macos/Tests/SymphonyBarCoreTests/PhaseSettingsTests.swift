import XCTest
@testable import SymphonyBarCore

/// Settings › Phases: the step lists under `phases.<kind>.steps`, read from and written to symphony.yml, checked by
/// the rules Symphony loads them with, and previewed as `symphony workflow preview` prints them.
final class PhaseSettingsTests: XCTestCase {
    /// The files `WorkflowPreviewStepsTest` (Elixir) loads into Symphony and previews: the same text on both sides.
    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/phases/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private var defaults: [PhaseStep] { PhaseDefaults.steps(for: .implementation) }

    /// The default list with the tests step dragged above checks.
    private func reordered() -> PhaseSteps {
        var list = PhaseSteps.defaults(for: .implementation)
        list.move(fromOffsets: IndexSet(integer: 3), toOffset: 2)
        return list
    }

    // MARK: Walkthrough step 1: drag tests above checks, save, and the preview agrees with Symphony's

    func testDraggingTestsAboveChecksSavesTheNewOrderAndPreviewsItAsSymphonyDoes() throws {
        let list = reordered()
        XCTAssertEqual(list.steps.map(\.stepID), ["code", "build", "tests", "checks", "handoff"])
        XCTAssertFalse(list.isDefault)

        var new = PhaseSettings()
        new[.implementation] = list
        let saved = try PhaseSettings.updating("", from: PhaseSettings(), to: new)
        XCTAssertEqual(saved, try fixture("reordered.yml"))

        let read = try PhaseSettings.values(in: saved)
        XCTAssertEqual(read[.implementation], list)
        XCTAssertEqual(PhasePreview.text(kind: .implementation, list: read[.implementation]), try fixture("reordered.preview.txt"))
    }

    func testTheDefaultListPreviewsAsSymphonyDoes() throws {
        let settings = try PhaseSettings.values(in: "agent:\n  max_turns: 3\n")
        XCTAssertEqual(settings[.implementation], .defaults(for: .implementation))
        XCTAssertEqual(PhasePreview.text(kind: .implementation, list: settings[.implementation]), try fixture("default.preview.txt"))
    }

    func testAKindWithNoListPreviewsAsOneAgentSession() {
        XCTAssertEqual(
            PhasePreview.text(kind: .qa, list: .defaults(for: .qa)),
            "## Steps\n\nA qa run follows no step list (the default list): it is one agent session.\n"
        )
        XCTAssertEqual(
            PhasePreview.text(kind: .epicReview, list: PhaseSteps(steps: [], isDefault: false)),
            "## Steps\n\nAn epic_review run follows no step list (symphony.yml): it is one agent session.\n"
        )
    }

    func testThePreviewShowsTitlesTimeoutsPromptsAndReturnsAsSymphonyDoes() {
        let steps = [
            PhaseStep(stepID: "code", mode: .delegated, onFail: nil),
            PhaseStep(stepID: "build", mode: .machine, commands: [StepCommand(run: "mix compile")], timeoutMs: 1_500, onFail: "code"),
            PhaseStep(stepID: "review", mode: .orchestrated, prompt: "Review the diff.\nSay what is missing.\n"),
            PhaseStep(stepID: "lint", mode: .machine, commands: [StepCommand(run: "mix credo")]),
        ]
        XCTAssertEqual(
            PhasePreview.text(kind: .rework, list: PhaseSteps(steps: steps, isDefault: false)),
            """
            ## Steps

            A rework run follows these steps (symphony.yml, `phases.rework.steps`):

            1. `code` code · delegated
            2. `build` build · machine · times out after 1500 ms · on failure returns to `code`
               - `mix compile`
            3. `review` review · orchestrated · on failure ends the run
               - prompt:
                 > Review the diff.
                 > Say what is missing.
                 > \("")
            4. `lint` lint · machine · times out after 10 min · on failure ends the run
               - `mix credo`


            """
        )
    }

    // MARK: Walkthrough step 2: a return-to naming no step in the list is refused on its row

    func testAReturnToNamingNoStepInTheListIsRefusedOnItsRow() {
        var steps = defaults
        steps[3].onFail = "lint"
        let validation = PhaseValidation.check(steps)
        XCTAssertFalse(validation.isValid)
        XCTAssertEqual(validation.reason(for: steps[3]), "Returns to `lint` on failure, but no step in this list has that id.")
        XCTAssertNil(validation.reason(for: steps[1]))
    }

    func testRemovingTheStepOthersReturnToIsRefusedOnTheirRows() {
        var list = PhaseSteps.defaults(for: .implementation)
        list.removeStep(list.steps[0].id)
        let validation = PhaseValidation.check(list.steps)
        XCTAssertEqual(validation.reasons.count, 3)
        XCTAssertEqual(validation.reason(for: list.steps[0]), "Returns to `code` on failure, but no step in this list has that id.")
    }

    func testTheDefaultListIsValid() {
        XCTAssertTrue(PhaseValidation.check(defaults).isValid)
        XCTAssertTrue(PhaseValidation.check([]).isValid)
    }

    func testEachRuleSymphonyLoadsWithHasAReason() {
        func reason(_ step: PhaseStep, among others: [PhaseStep] = []) -> String? {
            let steps = [step] + others
            return PhaseValidation.check(steps).reason(for: step)
        }
        XCTAssertEqual(reason(PhaseStep(stepID: "", mode: .delegated)), "Give the step an id.")
        XCTAssertEqual(
            reason(PhaseStep(stepID: "Build", mode: .delegated)),
            "The id must be lowercase letters, digits and underscores, starting with a letter."
        )
        XCTAssertEqual(
            reason(PhaseStep(stepID: "1st", mode: .delegated)),
            "The id must be lowercase letters, digits and underscores, starting with a letter."
        )
        XCTAssertNil(reason(PhaseStep(stepID: "step_2", mode: .delegated)))
        XCTAssertEqual(
            reason(PhaseStep(stepID: "code", mode: .delegated), among: [PhaseStep(stepID: "code", mode: .delegated)]),
            "Another step has the id `code`."
        )
        XCTAssertEqual(reason(PhaseStep(stepID: "build", mode: .machine)), "A machine step needs a command.")
        XCTAssertEqual(
            reason(PhaseStep(stepID: "build", mode: .machine, commands: [StepCommand(run: "  ")])),
            "Every command needs a shell line to run."
        )
        XCTAssertEqual(reason(PhaseStep(stepID: "ask", mode: .orchestrated, prompt: " ")), "An orchestrated step needs a prompt.")
        XCTAssertEqual(reason(PhaseStep(stepID: "code", mode: .delegated, timeoutMs: 0)), "The timeout must be more than 0.")
        XCTAssertEqual(reason(PhaseStep(stepID: "code", mode: .delegated, noResultLimit: 0)), "The no-result limit must be more than 0.")
    }

    func testALoopWithNoDelegatedStepIsRefusedOnTheStepItStartsAt() {
        let steps = [
            PhaseStep(stepID: "code", mode: .delegated),
            PhaseStep(stepID: "build", mode: .machine, commands: [StepCommand(run: "mix compile")], onFail: "code"),
            PhaseStep(stepID: "tests", mode: .machine, commands: [StepCommand(run: "mix test")], onFail: "build"),
        ]
        let validation = PhaseValidation.check(steps)
        XCTAssertEqual(validation.reasons.count, 1)
        XCTAssertEqual(
            validation.reason(for: steps[1]),
            "Failures can loop through `build` → `tests` → `build` with no delegated step, so the same commands would run again on the same code."
        )
    }

    // MARK: Editing the list

    func testAddingMovingAndRemovingSteps() {
        var list = PhaseSteps.defaults(for: .implementation)
        let added = list.addStep()
        XCTAssertFalse(list.isDefault)
        XCTAssertEqual(list.steps.last?.stepID, "step")
        XCTAssertEqual(list.steps.last?.id, added)
        XCTAssertEqual(PhaseStep.new(in: list.steps).stepID, "step_2")
        XCTAssertEqual(PhaseValidation.check(list.steps).reason(for: list.steps[5]), "Every command needs a shell line to run.")

        list.move(added, by: -1)
        XCTAssertEqual(list.steps.map(\.stepID), ["code", "build", "checks", "tests", "step", "handoff"])
        list.move(list.steps[0].id, by: -1)
        XCTAssertEqual(list.steps[0].stepID, "code")
        list.move(fromOffsets: IndexSet(integer: 0), toOffset: 6)
        XCTAssertEqual(list.steps.map(\.stepID), ["build", "checks", "tests", "step", "handoff", "code"])
        list.removeStep(added)
        XCTAssertEqual(list.steps.map(\.stepID), ["build", "checks", "tests", "handoff", "code"])
    }

    func testAnUnchangedListStaysTheDefault() {
        var list = PhaseSteps.defaults(for: .implementation)
        let same = list.steps
        list.steps = same
        XCTAssertTrue(list.isDefault)
        list.move(UUID(), by: 1)
        XCTAssertTrue(list.isDefault)
    }

    // MARK: Reading symphony.yml

    func testReadsFlowStepsAndALiteralPrompt() throws {
        let yaml = """
            phases:
              implementation:
                steps:
                  - {id: code, title: Write the code, mode: delegated}
                  - {id: build, mode: machine, command: mix compile, on_fail: code, timeout_ms: 1500}  # build it
                  - id: review
                    mode: orchestrated
                    prompt: |
                      Review the diff.

                      Say what is missing.
                  # a comment between steps
                  - id: tests
                    mode: machine
                    when: elixir_changed
                    command:
                      - {run: "mix test, then more", when: elixir_changed}
                      - run: 'it''s fine' # quoted
                    no_result_limit: 3
                  - {id: handoff, title: "Hand off: \\"push\\"", mode: delegated}
              qa:
                steps: []
            """
        let settings = try PhaseSettings.values(in: yaml)
        let steps = settings[.implementation].steps
        XCTAssertFalse(settings[.implementation].isDefault)
        XCTAssertEqual(steps.map(\.stepID), ["code", "build", "review", "tests", "handoff"])
        XCTAssertEqual(steps[0].title, "Write the code")
        XCTAssertEqual(steps[1], PhaseStep(stepID: "build", mode: .machine, commands: [StepCommand(run: "mix compile")], timeoutMs: 1_500, onFail: "code"))
        XCTAssertEqual(steps[2].prompt, "Review the diff.\n\nSay what is missing.\n")
        XCTAssertEqual(steps[3].when, .elixirChanged)
        XCTAssertEqual(steps[3].commands, [StepCommand(run: "mix test, then more", when: .elixirChanged), StepCommand(run: "it's fine")])
        XCTAssertEqual(steps[3].noResultLimit, 3)
        XCTAssertEqual(steps[4].title, "Hand off: \"push\"")
        XCTAssertEqual(settings[.qa], PhaseSteps(steps: [], isDefault: false))
        XCTAssertEqual(settings[.rework], .defaults(for: .rework))
    }

    func testTheReworkDefaultReadsTheFindingsFirst() {
        let steps = PhaseDefaults.steps(for: .rework)
        XCTAssertEqual(steps.map(\.stepID), ["findings", "code", "build", "checks", "tests", "handoff"])
        XCTAssertEqual(steps[0], PhaseStep(
            stepID: "findings",
            title: "Read the open findings",
            mode: .machine,
            commands: [StepCommand(run: "symphony:findings")],
            timeoutMs: 60_000,
            onFail: "code"
        ))
        XCTAssertEqual(Array(steps.dropFirst()), defaults)
        XCTAssertEqual(PhaseDefaults.steps(for: .qa), [])
    }

    func testReadsAKeepAndAStripPrompt() throws {
        let yaml = """
            phases:
              rework:
                steps:
                  - id: ask
                    mode: orchestrated
                    prompt: |-
                      One.
                      Two.
                  - id: tell
                    mode: orchestrated
                    prompt: ~
                    on_fail: null
            """
        let steps = try PhaseSettings.values(in: yaml)[.rework].steps
        XCTAssertEqual(steps[0].prompt, "One.\nTwo.")
        XCTAssertEqual(steps[1].prompt, "")
        XCTAssertNil(steps[1].onFail)
    }

    func testYAMLTheEditorDoesntReadIsReportedWithItsLine() {
        func error(_ steps: String) -> PhaseSettingsError? {
            do {
                _ = try PhaseSettings.values(in: "phases:\n  implementation:\n" + steps)
                return nil
            } catch {
                return error as? PhaseSettingsError
            }
        }
        XCTAssertEqual(error("    steps: [code]\n"), .unsupported(line: 3, reason: "write the steps as an indented list under `steps:`"))
        XCTAssertEqual(error("    steps:\n"), .unsupported(line: 3, reason: "`steps:` is empty; write `steps: []` for no steps"))
        XCTAssertEqual(error("    steps:\n    - id: code\n"), .unsupported(line: 4, reason: "indent the steps under `steps:`"))
        XCTAssertEqual(error("    other: 1\n"), .unsupported(line: 2, reason: "`implementation:` has no `steps:` list"))
        XCTAssertEqual(error("    steps:\n      - id: code\n        mode: delegated\n        color: red\n"), .unsupported(line: 6, reason: "a step has an unknown key `color`"))
        XCTAssertEqual(error("    steps:\n      - id: code\n"), .unsupported(line: 4, reason: "step `code` has no `mode`"))
        XCTAssertEqual(error("    steps:\n      - mode: delegated\n"), .unsupported(line: 4, reason: "a step has no `id`"))
        XCTAssertEqual(error("    steps:\n      - {id: code, mode: robot}\n"), .unsupported(line: 4, reason: "`mode: robot` is not machine, orchestrated or delegated"))
        XCTAssertEqual(
            error("    steps:\n      - {id: code, mode: machine, command: x, when: monday}\n"),
            .unsupported(line: 4, reason: "`when: monday` is not always, macos_changed or elixir_changed")
        )
        XCTAssertEqual(error("    steps:\n      - {id: code, mode: delegated, timeout_ms: soon}\n"), .unsupported(line: 4, reason: "`timeout_ms: soon` is not a whole number"))
        XCTAssertEqual(error("    steps:\n      - {id: code, mode: delegated\n"), .unsupported(line: 4, reason: "a `{...}` step doesn't close on its line"))
        XCTAssertEqual(error("    steps:\n      - {id: code, mode: delegated} x\n"), .unsupported(line: 4, reason: "a `{...}` step has text after its closing brace"))
        XCTAssertEqual(error("    steps:\n      - {id: [code]}\n"), .unsupported(line: 4, reason: "a `{...}` step holds a nested value; write it as an indented list"))
        XCTAssertEqual(error("    steps:\n      - {id}\n"), .unsupported(line: 4, reason: "a `{...}` step has a key with no value"))
        XCTAssertEqual(error("    steps:\n      - {id: code, mode: delegated}\n        title: x\n"), .unsupported(line: 4, reason: "a `{...}` step must stay on one line"))
        XCTAssertEqual(error("    steps:\n      -\n        id: code\n"), .unsupported(line: 4, reason: "write each step's first key after `- `"))
        XCTAssertEqual(error("    steps:\n      - id: code\n       mode: delegated\n"), .unsupported(line: 5, reason: "line up each key of a step under its first key"))
        XCTAssertEqual(error("    steps:\n      - id: code\n        just text\n"), .unsupported(line: 5, reason: "`just text` is not a `key: value` line"))
        XCTAssertEqual(error("    steps:\n      - id: code\n        mode:\n          deep: 1\n"), .unsupported(line: 5, reason: "`mode:` holds a value the editor doesn't read"))
        XCTAssertEqual(error("    steps:\n      - id: &a code\n"), .unsupported(line: 4, reason: "`&a code` is a value the editor doesn't read"))
        XCTAssertEqual(error("    steps:\n      - id: \"code\" x\n"), .unsupported(line: 4, reason: "`\"code\" x` has text after its closing quote"))
        XCTAssertEqual(error("    steps:\n      - id: \"code\n"), .unsupported(line: 4, reason: "a quoted value doesn't end on its line"))
        XCTAssertEqual(error("    steps:\n      - id: 'code\n"), .unsupported(line: 4, reason: "a quoted value doesn't end on its line"))
        XCTAssertEqual(error("    steps:\n      - id: \"\\q\"\n"), .unsupported(line: 4, reason: "`\\q` is an escape the editor doesn't read"))
        XCTAssertEqual(
            error("    steps:\n      - id: a\n        mode: orchestrated\n        prompt: >\n          x\n"),
            .unsupported(line: 6, reason: "`prompt:` holds a value the editor doesn't read")
        )
        XCTAssertEqual(
            error("    steps:\n      - id: a\n        mode: orchestrated\n        prompt: |+\n          x\n"),
            .unsupported(line: 6, reason: "use `|` or `|-` for a block of several lines")
        )
        XCTAssertEqual(
            error("    steps:\n      - id: a\n        mode: machine\n        command:\n          run: x\n"),
            .unsupported(line: 6, reason: "`command:` needs a shell line or a list of commands")
        )
        XCTAssertEqual(
            error("    steps:\n      - id: a\n        mode: machine\n        command:\n          - {run: x, shell: zsh}\n"),
            .unsupported(line: 7, reason: "a command has an unknown key `shell`")
        )
        XCTAssertEqual(
            error("    steps:\n      - id: a\n        mode: machine\n        command:\n          - when: always\n"),
            .unsupported(line: 7, reason: "a command has no `run` line")
        )
        XCTAssertThrowsError(try PhaseSettings.values(in: "phases: {}\n")) { error in
            XCTAssertEqual(error as? PhaseSettingsError, .notABlock("phases"))
        }
    }

    func testErrorDescriptions() {
        XCTAssertEqual(
            PhaseSettingsError.notABlock("phases").errorDescription,
            "`phases:` in symphony.yml is not an indented block. Change the steps by hand."
        )
        XCTAssertEqual(
            PhaseSettingsError.unsupported(line: 4, reason: "a step has no `id`").errorDescription,
            "symphony.yml line 4: a step has no `id`. Change the steps by hand."
        )
    }

    // MARK: Writing symphony.yml

    func testSavingRewritesOnlyTheStepsBlockAndKeepsTheRest() throws {
        let yaml = """
            agent:
              max_turns: 3
            phases:
              implementation:
                steps:  # the list
                  - {id: code, mode: delegated}
                  # trailing note
              qa:
                steps: []
            tickets:
              priorities: [urgent]

            """
        var new = try PhaseSettings.values(in: yaml)
        let old = new
        new[.implementation].steps.append(PhaseStep(stepID: "handoff", title: "yes", mode: .delegated, timeoutMs: 60_000, noResultLimit: 4))
        XCTAssertEqual(
            try PhaseSettings.updating(yaml, from: old, to: new),
            """
            agent:
              max_turns: 3
            phases:
              implementation:
                steps: # the list
                  - id: code
                    mode: delegated
                  - id: handoff
                    title: "yes"
                    mode: delegated
                    timeout_ms: 60000
                    no_result_limit: 4
              qa:
                steps: []
            tickets:
              priorities: [urgent]

            """
        )
        XCTAssertEqual(try PhaseSettings.updating(yaml, from: old, to: old), yaml)
    }

    func testSavingAnEmptyListWritesNoSteps() throws {
        var new = PhaseSettings()
        new[.rework] = PhaseSteps(steps: [], isDefault: false)
        let yaml = try PhaseSettings.updating("agent:\n  max_turns: 3\n", from: PhaseSettings(), to: new)
        XCTAssertEqual(yaml, "agent:\n  max_turns: 3\nphases:\n  rework:\n    steps: []\n")
        XCTAssertEqual(try PhaseSettings.values(in: yaml)[.rework], PhaseSteps(steps: [], isDefault: false))
    }

    func testOnlyTheFieldsOfTheStepsModeAreWritten() throws {
        var step = PhaseStep(
            stepID: "ask",
            title: "  ",
            mode: .orchestrated,
            commands: [StepCommand(run: "mix test")],
            prompt: "Check it.",
            onFail: " ",
            when: .macosChanged
        )
        XCTAssertEqual(StepsWriter.lines([step], indent: 0, step: 2), ["- id: ask", "  mode: orchestrated", "  prompt: Check it."])
        step.mode = .delegated
        XCTAssertEqual(StepsWriter.lines([step], indent: 0, step: 2), ["- id: ask", "  mode: delegated"])
        step.mode = .machine
        XCTAssertEqual(StepsWriter.lines([step], indent: 0, step: 2), ["- id: ask", "  mode: machine", "  when: macos_changed", "  command: mix test"])
    }

    func testValuesRoundTripThroughTheirQuoting() throws {
        let texts = [
            "plain words", "Hand off: push", "yes", "No", "~", "null", "12", "1.5", "-x", "#tag", "a #b", "trailing ",
            " leading", "ends:", "say \"hi\"", "back\\slash", "tab\there", "{brace}", "[list]", "*star", "it's", "", "cr\rhere",
        ]
        let steps = texts.enumerated().map { index, text in
            PhaseStep(stepID: "s\(index)", title: "t", mode: .machine, commands: [StepCommand(run: text, when: .elixirChanged)])
        }
        var new = PhaseSettings()
        new[.landing] = PhaseSteps(steps: steps, isDefault: false)
        let yaml = try PhaseSettings.updating("", from: PhaseSettings(), to: new)
        XCTAssertEqual(try PhaseSettings.values(in: yaml)[.landing].steps.map { $0.commands[0].run }, texts)
        XCTAssertEqual(StepsWriter.scalar("mix test && cd macos"), "mix test && cd macos")
        XCTAssertEqual(StepsWriter.scalar("yes"), "\"yes\"")
    }

    func testPromptsRoundTripAsLiteralBlocksOrQuoted() throws {
        let prompts = ["One line.", "Two\nlines.\n", "Two\nlines, no end", "Ends\n\n", "  indented\nfirst", "tab\tin\nlines", "space \nend", "a\n\nb\n"]
        let steps = prompts.enumerated().map { PhaseStep(stepID: "p\($0)", mode: .orchestrated, prompt: $1) }
        let lines = StepsWriter.lines(steps, indent: 0, step: 2)
        XCTAssertTrue(lines.contains("  prompt: |"))
        XCTAssertTrue(lines.contains("  prompt: |-"))
        XCTAssertTrue(lines.contains("  prompt: \"Ends\\n\\n\""))
        var new = PhaseSettings()
        new[.qa] = PhaseSteps(steps: steps, isDefault: false)
        let yaml = try PhaseSettings.updating("", from: PhaseSettings(), to: new)
        XCTAssertEqual(try PhaseSettings.values(in: yaml)[.qa].steps.map(\.prompt), prompts)
    }

    func testResettingRemovesTheKindAndAnEmptiedPhasesKey() throws {
        let yaml = "agent:\n  max_turns: 3\nphases:\n  implementation:\n    steps: []\n    # under it\n  qa:\n    steps: []\nnext: 1\n"
        let old = try PhaseSettings.values(in: yaml)
        var new = old
        new[.implementation] = .defaults(for: .implementation)
        let once = try PhaseSettings.updating(yaml, from: old, to: new)
        XCTAssertEqual(once, "agent:\n  max_turns: 3\nphases:\n  qa:\n    steps: []\nnext: 1\n")
        new[.qa] = .defaults(for: .qa)
        XCTAssertEqual(try PhaseSettings.updating(yaml, from: old, to: new), "agent:\n  max_turns: 3\nnext: 1\n")
        XCTAssertEqual(try PhaseSettings.resetting("agent: {}\n", kind: .qa), "agent: {}\n")
    }

    func testAnInlinePhasesKeyIsReportedWhenSaving() {
        var new = PhaseSettings()
        new[.qa] = PhaseSteps(steps: [], isDefault: false)
        XCTAssertThrowsError(try PhaseSettings.updating("phases: {}\n", from: PhaseSettings(), to: new)) { error in
            XCTAssertEqual(error as? PhaseSettingsError, .notABlock("phases"))
        }
    }

    func testEveryKindModeAndConditionHasWords() {
        XCTAssertEqual(PhaseKind.allCases.map(\.keyPath).filter { !SettingsUIManifest.keyPaths.contains($0) }, [])
        for kind in PhaseKind.allCases { XCTAssertFalse(kind.title.isEmpty); XCTAssertEqual(kind.id, kind.rawValue) }
        for mode in StepMode.allCases { XCTAssertFalse(mode.title.isEmpty); XCTAssertFalse(mode.explanation.isEmpty); XCTAssertEqual(mode.id, mode.rawValue) }
        for condition in StepCondition.allCases { XCTAssertFalse(condition.title.isEmpty); XCTAssertEqual(condition.id, condition.rawValue) }
        XCTAssertEqual(PhaseStep(stepID: "x", title: " ", mode: .delegated).shownTitle, "x")
    }

    func testTheFileIsWrittenOnlyWhenTheCheckPasses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("symphony.yml").path
        try "agent:\n  max_turns: 3\n".write(toFile: path, atomically: true, encoding: .utf8)
        let file = SymphonyConfigFile(path: path)
        var new = PhaseSettings()
        new[.implementation] = reordered()

        let rejected = try await file.writePhaseSettings(new, from: PhaseSettings()) { _ in .failed("nope") }
        XCTAssertEqual(rejected, .failed("nope"))
        XCTAssertEqual(try file.readPhaseSettings(), PhaseSettings())

        let passed = try await file.writePhaseSettings(new, from: PhaseSettings()) { _ in .passed }
        XCTAssertEqual(passed, .passed)
        XCTAssertEqual(try file.readPhaseSettings()[.implementation].steps.map(\.stepID), ["code", "build", "tests", "checks", "handoff"])
    }

    // MARK: An orchestrated step's answer fields

    private func orchestrated(answer: [AnswerField] = []) -> PhaseStep {
        PhaseStep(stepID: "ask", mode: .orchestrated, prompt: "Pick a layout.", answer: answer)
    }

    // Walkthrough steps 1 and 2: a new orchestrated step has no fields; two added, saved and read back.
    func testAnsweringFieldsAreAddedSavedAndReadBack() throws {
        var step = orchestrated()
        XCTAssertEqual(step.answer, [])
        let first = step.addAnswerField()
        step.addAnswerField()
        XCTAssertEqual(step.answer.map(\.name), ["field", "field_2"])
        XCTAssertEqual(step.answer.map(\.type), [.string, .string])
        XCTAssertEqual(step.answer[0].id, first)
        step.answer[0].name = "layout"
        step.answer[1].name = "columns"
        step.answer[1].type = .number

        var new = PhaseSettings()
        new[.qa] = PhaseSteps(steps: [step], isDefault: false)
        XCTAssertTrue(PhaseValidation.check(new[.qa].steps).isValid)
        let yaml = try PhaseSettings.updating("", from: PhaseSettings(), to: new)
        XCTAssertEqual(
            yaml,
            "phases:\n  qa:\n    steps:\n      - id: ask\n        mode: orchestrated\n        prompt: Pick a layout.\n"
                + "        answer: {layout: string, columns: number}\n"
        )
        let read = try PhaseSettings.values(in: yaml)
        XCTAssertEqual(read[.qa], new[.qa])
        XCTAssertEqual(
            PhasePreview.text(kind: .qa, list: read[.qa]),
            "## Steps\n\nA qa run follows these steps (symphony.yml, `phases.qa.steps`):\n\n"
                + "1. `ask` ask · orchestrated · on failure ends the run\n   - prompt:\n     > Pick a layout.\n"
                + "   - answer: `columns` number, `layout` string\n\n"
        )
    }

    func testRemovingAndRetypingAnAnswerField() {
        var step = orchestrated(answer: [AnswerField(name: "layout"), AnswerField(name: "columns", type: .number)])
        let before = step
        step.answer[0].type = .object
        XCTAssertNotEqual(step, before)
        step.removeAnswerField(step.answer[1].id)
        XCTAssertEqual(step.answer, [AnswerField(name: "layout", type: .object)])
        for type in AnswerType.allCases { XCTAssertFalse(type.title.isEmpty); XCTAssertEqual(type.id, type.rawValue) }
        XCTAssertEqual(AnswerType.string.title, "Text")
    }

    // Walkthrough step 3: a name Symphony would refuse says why on its row, and the list can't be saved.
    func testAnAnswerFieldSymphonyWouldRefuseSaysWhyOnItsRow() {
        func reason(_ fields: [AnswerField]) -> String? {
            let step = orchestrated(answer: fields)
            return PhaseValidation.check([step]).reason(for: step)
        }
        XCTAssertEqual(
            reason([AnswerField(name: "Layout")]),
            "The answer field `Layout` must be lowercase letters, digits and underscores, starting with a letter."
        )
        XCTAssertEqual(
            reason([AnswerField(name: "2nd")]),
            "The answer field `2nd` must be lowercase letters, digits and underscores, starting with a letter."
        )
        XCTAssertEqual(reason([AnswerField(name: "")]), "Give each answer field a name.")
        XCTAssertEqual(reason([AnswerField(name: "layout"), AnswerField(name: "layout", type: .list)]), "Two answer fields are named `layout`.")
        XCTAssertNil(reason([AnswerField(name: "layout_2"), AnswerField(name: "columns", type: .number)]))

        let fields = [AnswerField(name: "ok"), AnswerField(name: "Bad")]
        XCTAssertNil(PhaseValidation.answerReason(for: fields[0], in: fields))
        XCTAssertNotNil(PhaseValidation.answerReason(for: fields[1], in: fields))

        // Only an orchestrated step takes an answer, so another kind's leftover fields are neither checked nor written.
        let machine = PhaseStep(stepID: "build", mode: .machine, commands: [StepCommand(run: "make")], answer: [AnswerField(name: "Bad")])
        XCTAssertTrue(PhaseValidation.check([machine]).isValid)
        XCTAssertEqual(StepsWriter.lines([machine], indent: 0, step: 2), ["- id: build", "  mode: machine", "  command: make"])
        var delegated = machine
        delegated.mode = .delegated
        XCTAssertEqual(StepsWriter.lines([delegated], indent: 0, step: 2), ["- id: build", "  mode: delegated"])
    }

    func testAnswerNamesYAMLWouldMisreadAreQuoted() throws {
        let step = orchestrated(answer: [AnswerField(name: "yes", type: .boolean), AnswerField(name: "null", type: .list)])
        let lines = StepsWriter.lines([step], indent: 0, step: 2)
        XCTAssertEqual(lines.last, "  answer: {\"yes\": boolean, \"null\": list}")
        var new = PhaseSettings()
        new[.qa] = PhaseSteps(steps: [step], isDefault: false)
        let yaml = try PhaseSettings.updating("", from: PhaseSettings(), to: new)
        XCTAssertEqual(try PhaseSettings.values(in: yaml)[.qa].steps[0].answer, step.answer)
    }

    func testReadsAnAnswerAsAFlowMappingOrAnIndentedBlock() throws {
        let yaml = """
            phases:
              qa:
                steps:
                  - id: flow
                    mode: orchestrated
                    prompt: p
                    answer: {layout: 'string', "columns": number}  # the fields
                  - id: block
                    mode: orchestrated
                    prompt: p
                    answer:
                      # what the agent says
                      ok: boolean
                      items: list  # each one

                      details: object
                  - id: none
                    mode: orchestrated
                    prompt: p
                    answer: {}
                  - id: nothing
                    mode: orchestrated
                    prompt: p
                    answer:
                  - id: other
                    mode: delegated
                    answer: {left: string}

            """
        let steps = try PhaseSettings.values(in: yaml)[.qa].steps
        XCTAssertEqual(steps[0].answer, [AnswerField(name: "layout"), AnswerField(name: "columns", type: .number)])
        XCTAssertEqual(
            steps[1].answer,
            [AnswerField(name: "ok", type: .boolean), AnswerField(name: "items", type: .list), AnswerField(name: "details", type: .object)]
        )
        XCTAssertEqual(steps[2].answer, [])
        XCTAssertEqual(steps[3].answer, [])
        XCTAssertEqual(steps[4].answer, [AnswerField(name: "left")])
    }

    func testAListReadWithAnAnswerAndSavedUnchangedKeepsItByteForByte() throws {
        let yaml = """
            phases:
              qa:
                steps:
                  - id: ask
                    mode: orchestrated
                    prompt: Pick a layout.
                    answer:
                      layout: string   # odd spacing kept
                      columns: number
              implementation:
                steps:
                  - {id: code, mode: delegated}

            """
        let old = try PhaseSettings.values(in: yaml)
        XCTAssertEqual(try PhaseSettings.updating(yaml, from: old, to: old), yaml)

        // Another kind's change leaves the qa block as it is.
        var new = old
        new[.implementation].steps.append(PhaseStep(stepID: "handoff", mode: .delegated))
        let saved = try PhaseSettings.updating(yaml, from: old, to: new)
        XCTAssertTrue(saved.hasPrefix(yaml.components(separatedBy: "  implementation:")[0]))
        XCTAssertEqual(try PhaseSettings.values(in: saved)[.qa], old[.qa])
    }

    func testAnAnswerTheEditorDoesntReadIsReportedWithItsLine() {
        func error(_ answer: String) -> PhaseSettingsError? {
            do {
                _ = try PhaseSettings.values(in: "phases:\n  qa:\n    steps:\n      - id: ask\n        mode: orchestrated\n" + answer)
                return nil
            } catch {
                return error as? PhaseSettingsError
            }
        }
        XCTAssertEqual(
            error("        answer: {layout: text}\n"),
            .unsupported(line: 6, reason: "the answer field `layout` has the type `text`, not string, number, boolean, list or object")
        )
        XCTAssertEqual(
            error("        answer:\n          layout:\n"),
            .unsupported(line: 7, reason: "the answer field `layout` has the type ``, not string, number, boolean, list or object")
        )
        XCTAssertEqual(error("        answer: layout\n"), .unsupported(line: 6, reason: "`answer:` needs a field name and type on each line under it"))
        XCTAssertEqual(
            error("        answer: x\n          layout: string\n"),
            .unsupported(line: 6, reason: "`answer:` needs a field name and type on each line under it")
        )
        XCTAssertEqual(
            error("        answer: {layout: string}\n          more: number\n"),
            .unsupported(line: 6, reason: "an `answer: {...}` must stay on one line")
        )
        XCTAssertEqual(
            error("        answer:\n          layout: string\n            columns: number\n"),
            .unsupported(line: 8, reason: "line up the answer's fields")
        )
        XCTAssertEqual(error("        answer:\n          layout\n"), .unsupported(line: 7, reason: "`layout` is not a `name: type` line"))
    }
}
