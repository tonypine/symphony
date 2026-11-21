import Foundation

/// Why the step lists under `phases` can't be read or changed by editing their block.
public enum PhaseSettingsError: LocalizedError, Equatable {
    /// A key above the steps holds an inline value (for example `phases: {}`) instead of an indented block.
    case notABlock(String)
    /// The steps use YAML the editor doesn't read. `line` counts from 1.
    case unsupported(line: Int, reason: String)

    public var errorDescription: String? {
        switch self {
        case .notABlock(let key):
            return "`\(key):` in symphony.yml is not an indented block. Change the steps by hand."
        case .unsupported(let line, let reason):
            return "symphony.yml line \(line): \(reason). Change the steps by hand."
        }
    }
}

/// A run kind that takes a step list under `phases`, as `symphony.yml` names it: every kind Symphony runs, in
/// `SymphonyElixir.RunKind`'s order.
public enum PhaseKind: String, CaseIterable, Identifiable {
    case implementation
    case breakdown
    case rework
    case landing
    case codeReview = "code_review"
    case epicReview = "epic_review"
    case ciFix = "ci_fix"
    case reviewFeedback = "review_feedback"
    case qa

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .implementation: return "Implementation"
        case .breakdown: return "Breakdown"
        case .rework: return "Rework"
        case .landing: return "Landing"
        case .codeReview: return "Code review"
        case .epicReview: return "Epic review"
        case .ciFix: return "CI fix"
        case .reviewFeedback: return "Review feedback"
        case .qa: return "QA"
        }
    }

    /// The setting's key path, as `SettingsUIManifest` lists it.
    public var keyPath: String { "phases.\(rawValue).steps" }
}

/// A QA playbook kind, as `phases.qa.playbooks` names it: the four Symphony knows, or one of the file's own
/// (lowercase letters, digits and underscores, starting with a letter).
public struct QAPlaybookKind: Hashable, Identifiable, Comparable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static let macosApp = QAPlaybookKind("macos_app")
    public static let cli = QAPlaybookKind("cli")
    public static let web = QAPlaybookKind("web")
    public static let androidApp = QAPlaybookKind("android_app")

    /// The kinds Symphony knows, in the order the picker lists them.
    public static let builtIn: [QAPlaybookKind] = [.macosApp, .cli, .web, .androidApp]

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .macosApp: return "macOS app"
        case .cli: return "CLI"
        case .web: return "Web"
        case .androidApp: return "Android app"
        default: return rawValue
        }
    }

    /// The setting's key path for this kind's list.
    public var keyPath: String { "phases.qa.playbooks.\(rawValue).steps" }

    /// Whether Symphony takes it as a kind's name.
    public var isValid: Bool { PhaseValidation.isValidID(rawValue) }

    public static func < (lhs: QAPlaybookKind, rhs: QAPlaybookKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Whose step list it is, as Symphony checks it (`Config.Schema.Phases.Phase.changeset/3`): a run kind's
/// (`phases.<kind>.steps`) or a QA playbook's (`phases.qa.playbooks.<kind>.steps`), which may run the QA pass's own
/// commands and leave an orchestrated step's prompt to Symphony.
public enum StepListOwner: Hashable {
    case runKind(PhaseKind)
    case qaPlaybook(QAPlaybookKind)

    /// The setting's key path.
    public var keyPath: String {
        switch self {
        case .runKind(let kind): return kind.keyPath
        case .qaPlaybook(let playbook): return playbook.keyPath
        }
    }

    /// The keys from the top of the file to the list's `steps:`.
    var path: [String] {
        switch self {
        case .runKind(let kind): return ["phases", kind.rawValue, "steps"]
        case .qaPlaybook(let playbook): return ["phases", "qa", "playbooks", playbook.rawValue, "steps"]
        }
    }

    /// The QA playbook it is, nil for a run kind.
    public var qaPlaybook: QAPlaybookKind? {
        if case .qaPlaybook(let playbook) = self { return playbook }
        return nil
    }
}

/// An agent step's reasoning effort (`effort`): the efforts a run takes (`runs.<kind>.effort`).
public enum StepEffort: String, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case xhigh
    case max

    public var id: String { rawValue }

    /// As Factory › Runs shows an effort: its name.
    public var title: String { rawValue }
}

/// What an agent step runs once for (`repeat`): `walkthrough`, once per walkthrough step the QA pass walks.
public enum StepRepeat: String, CaseIterable, Identifiable {
    case walkthrough

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .walkthrough: return "Once per walkthrough step"
        }
    }
}

/// How a step runs: a shell command Symphony runs, an agent turn Symphony starts from a prompt, or work the agent
/// does in its session and records itself.
public enum StepMode: String, CaseIterable, Identifiable {
    case machine
    case orchestrated
    case delegated

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .machine: return "Machine"
        case .orchestrated: return "Orchestrated"
        case .delegated: return "Delegated"
        }
    }

    public var explanation: String {
        switch self {
        case .machine: return "Symphony runs a shell command."
        case .orchestrated: return "Symphony starts an agent turn from a prompt."
        case .delegated: return "The agent does the work in its session and records it."
        }
    }
}

/// When a machine step, or one of its commands, runs.
public enum StepCondition: String, CaseIterable, Identifiable {
    case always
    case macosChanged = "macos_changed"
    case elixirChanged = "elixir_changed"
    case elixirSourceChanged = "elixir_source_changed"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .always: return "Always"
        case .macosChanged: return "When macos/ changed"
        case .elixirChanged: return "When Elixir files changed"
        case .elixirSourceChanged: return "When Elixir source files changed"
        }
    }

    /// As `symphony workflow preview` writes it, nil for always.
    var previewText: String? {
        switch self {
        case .always: return nil
        case .macosChanged: return "when macos/ changed"
        case .elixirChanged: return "when Elixir files changed"
        case .elixirSourceChanged: return "when Elixir source files changed"
        }
    }
}

/// One command of a machine step: the shell line it runs and when. `id` only keeps a SwiftUI row stable.
public struct StepCommand: Identifiable, Equatable {
    public let id = UUID()
    public var run: String
    public var when: StepCondition

    public init(run: String, when: StepCondition = .always) {
        self.run = run
        self.when = when
    }

    public static func == (lhs: StepCommand, rhs: StepCommand) -> Bool {
        lhs.run == rhs.run && lhs.when == rhs.when
    }
}

/// The type of one field of an orchestrated step's answer, as `symphony.yml` names it.
public enum AnswerType: String, CaseIterable, Identifiable {
    case string
    case number
    case boolean
    case list
    case object

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .string: return "Text"
        case .number: return "Number"
        case .boolean: return "True or false"
        case .list: return "List"
        case .object: return "Object"
        }
    }
}

/// One field an orchestrated step's JSON answer must hold, with its type. `id` only keeps a SwiftUI row stable.
public struct AnswerField: Identifiable, Equatable {
    public let id = UUID()
    public var name: String
    public var type: AnswerType

    public init(name: String, type: AnswerType = .string) {
        self.name = name
        self.type = type
    }

    public static func == (lhs: AnswerField, rhs: AnswerField) -> Bool {
        lhs.name == rhs.name && lhs.type == rhs.type
    }
}

/// One step of a run's list (`Config.Schema.Phases.Step`). `id` only keeps a SwiftUI row stable; `stepID` is the
/// step's `id` in symphony.yml, the one `onFail` names. A nil field is missing from the file.
public struct PhaseStep: Identifiable, Equatable {
    public let id = UUID()
    public var stepID: String
    public var title: String
    public var mode: StepMode
    public var commands: [StepCommand]
    public var prompt: String
    /// An orchestrated step's answer fields, in the file's order; written only on an orchestrated step.
    public var answer: [AnswerField]
    public var timeoutMs: Int?
    public var onFail: String?
    public var noResultLimit: Int?
    public var when: StepCondition
    /// An agent step's model: a model id, or `small` for the run's small model; nil runs the run's model.
    public var model: String?
    /// An agent step's effort; nil runs the run's effort.
    public var effort: StepEffort?
    /// An agent step's session: steps with the same name continue one agent session, and `fresh` starts one for the
    /// step alone; nil runs in the run's one session.
    public var session: String?
    /// What an agent step runs once for; nil runs it once.
    public var `repeat`: StepRepeat?

    /// A machine step that sets no timeout gets ten minutes, as Symphony gives it.
    public static let machineTimeoutMs = 600_000
    /// The `session` that starts a new agent session for its step alone.
    public static let freshSession = "fresh"

    public init(
        stepID: String,
        title: String = "",
        mode: StepMode,
        commands: [StepCommand] = [],
        prompt: String = "",
        answer: [AnswerField] = [],
        timeoutMs: Int? = nil,
        onFail: String? = nil,
        noResultLimit: Int? = nil,
        when: StepCondition = .always,
        model: String? = nil,
        effort: StepEffort? = nil,
        session: String? = nil,
        repeat: StepRepeat? = nil
    ) {
        self.stepID = stepID
        self.title = title
        self.mode = mode
        self.commands = commands
        self.prompt = prompt
        self.answer = answer
        self.timeoutMs = timeoutMs
        self.onFail = onFail
        self.noResultLimit = noResultLimit
        self.when = when
        self.model = model
        self.effort = effort
        self.session = session
        self.repeat = `repeat`
    }

    public static func == (lhs: PhaseStep, rhs: PhaseStep) -> Bool {
        lhs.stepID == rhs.stepID && lhs.title == rhs.title && lhs.mode == rhs.mode && lhs.commands == rhs.commands
            && lhs.prompt == rhs.prompt && lhs.answer == rhs.answer && lhs.timeoutMs == rhs.timeoutMs && lhs.onFail == rhs.onFail
            && lhs.noResultLimit == rhs.noResultLimit && lhs.when == rhs.when && lhs.model == rhs.model && lhs.effort == rhs.effort
            && lhs.session == rhs.session && lhs.repeat == rhs.repeat
    }

    /// The keys only an agent step takes that this step sets, in the file's order.
    public var agentKeys: [String] {
        [("model", model != nil), ("effort", effort != nil), ("session", session != nil), ("repeat", self.repeat != nil)]
            .filter(\.1)
            .map(\.0)
    }

    /// The title Symphony shows: the step's id when it has none.
    public var shownTitle: String {
        let title = title.trimmingWhitespace()
        return title.isEmpty ? stepID : title
    }

    /// How long the step may run, with Symphony's default for a machine step; nil gives the agent's turn timeout.
    public var effectiveTimeoutMs: Int? {
        timeoutMs ?? (mode == .machine ? Self.machineTimeoutMs : nil)
    }

    /// The step a failure returns to, nil when it ends the run.
    public var returnsTo: String? {
        guard let onFail = onFail?.trimmingWhitespace(), !onFail.isEmpty else { return nil }
        return onFail
    }

    /// Adds an answer field of type text, named `field` (or `field_2`, ...) so no other field has its name, and
    /// returns its row id.
    @discardableResult
    public mutating func addAnswerField() -> UUID {
        let names = Set(answer.map(\.name))
        let name = (1...).lazy.map { $0 == 1 ? "field" : "field_\($0)" }.first { !names.contains($0) } ?? "field"
        let field = AnswerField(name: name)
        answer.append(field)
        return field.id
    }

    /// Removes the answer field with row `id`.
    public mutating func removeAnswerField(_ id: UUID) {
        answer.removeAll { $0.id == id }
    }

    /// A new step for Add step: a machine step with an id no step in `steps` has.
    public static func new(in steps: [PhaseStep]) -> PhaseStep {
        let ids = Set(steps.map(\.stepID))
        let id = (1...).lazy.map { $0 == 1 ? "step" : "step_\($0)" }.first { !ids.contains($0) } ?? "step"
        return PhaseStep(stepID: id, title: "New step", mode: .machine, commands: [StepCommand(run: "")])
    }
}

/// One kind's step list: the steps, and whether they are the kind's default because symphony.yml doesn't set
/// `phases.<kind>`.
public struct PhaseSteps: Equatable {
    /// Any change makes the list symphony.yml's own: saving writes it.
    public var steps: [PhaseStep] {
        didSet { if steps != oldValue { isDefault = false } }
    }
    public var isDefault: Bool

    public init(steps: [PhaseStep], isDefault: Bool) {
        self.steps = steps
        self.isDefault = isDefault
    }

    /// Moves the steps at `source` to before the step at `destination`, as a drag in the list does.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.filter { steps.indices.contains($0) }.map { steps[$0] }
        var rest = steps
        for index in source.sorted(by: >) where rest.indices.contains(index) { rest.remove(at: index) }
        let insertAt = destination - source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: min(max(insertAt, 0), rest.count))
        steps = rest
    }

    /// Moves the step with row `id` one place up (`by: -1`) or down (`by: 1`); nothing at either end.
    public mutating func move(_ id: UUID, by offset: Int) {
        guard let index = steps.firstIndex(where: { $0.id == id }), steps.indices.contains(index + offset) else { return }
        steps.swapAt(index, index + offset)
    }

    /// Adds a new machine step at the end and returns its row id.
    @discardableResult
    public mutating func addStep() -> UUID {
        let step = PhaseStep.new(in: steps)
        steps.append(step)
        return step.id
    }

    /// Removes the step with row `id`.
    public mutating func removeStep(_ id: UUID) {
        steps.removeAll { $0.id == id }
    }

    /// The default list of `kind`, followed while symphony.yml doesn't set it.
    public static func defaults(for kind: PhaseKind) -> PhaseSteps {
        PhaseSteps(steps: PhaseDefaults.steps(for: kind), isDefault: true)
    }

    /// The default list of `owner`, followed while symphony.yml doesn't set it.
    public static func defaults(for owner: StepListOwner) -> PhaseSteps {
        switch owner {
        case .runKind(let kind): return defaults(for: kind)
        case .qaPlaybook(let playbook): return PhaseSteps(steps: PhaseDefaults.qaSteps(for: playbook), isDefault: true)
        }
    }
}

/// The default step lists, as `Config.Schema.Phases.default_steps/1` gives them (decision 2 of TP-1085):
/// `implementation` writes, builds, checks, tests, runs the window tests in the QA VM and hands off; `rework` reads the
/// open findings first; `ci_fix` fixes the failed check, runs the same checks, then what failed on GitHub (TP-1555);
/// every other kind has none.
public enum PhaseDefaults {
    public static func steps(for kind: PhaseKind) -> [PhaseStep] {
        switch kind {
        case .implementation:
            return implementation
        case .rework:
            let findings = PhaseStep(
                stepID: "findings",
                title: "Read the open findings",
                mode: .machine,
                commands: [StepCommand(run: "symphony:findings")],
                timeoutMs: 60_000,
                onFail: "code"
            )
            return [findings] + implementation
        case .ciFix:
            return ciFix
        default:
            return []
        }
    }

    /// The machine step command Symphony runs itself for the Window tests step: the window tests the change selects, in
    /// the QA VM (`Config.Schema.Phases.window_tests_command/0`).
    public static let windowTestsCommand = "symphony:window_tests"

    /// The machine step command Symphony runs itself for the step that guards the handoff of a ticket with a plan: it
    /// fails while a check of the plan that a test or an attachment proves is open, and passes at once for a ticket with
    /// no plan (`Config.Schema.Phases.checks_command/0`).
    public static let checksCommand = "symphony:checks"

    /// The machine step command Symphony runs itself for a CI Fix run's failed-check step: what failed on GitHub, run
    /// again on the run's commit (`Config.Schema.Phases.failed_check_command/0`).
    public static let failedCheckCommand = "symphony:failed_check"

    /// The checks only CI can prove, which the failed-check step leaves to CI (`Config.Schema.Phases.ci_only_checks/0`):
    /// a check, or one step of it, and why.
    public static let ciOnlyChecks: [CIOnlyCheck] = [
        CIOnlyCheck(check: "dialyzer", why: "its full run of the whole code base takes longer than a run's step allows"),
        CIOnlyCheck(check: "protected paths", why: "it reads the pull request's author and reviews on GitHub"),
        CIOnlyCheck(check: "validate-pr-description", why: "it reads the pull request's description on GitHub"),
        CIOnlyCheck(check: "macos", why: "it only sums up the Mac checks, which the step runs itself"),
        CIOnlyCheck(check: "mac checks", step: "Test the QA signing identity script", why: "it changes the keychain of the machine it runs on"),
        CIOnlyCheck(
            check: "mac checks", step: "Test update, restart and rollback", why: "it signs, installs and launches the app on the machine it runs on"
        ),
    ]

    /// The machine step commands the QA pass runs itself, with the QA host it holds (`Config.Schema.Phases.qa_commands/0`).
    /// Only a QA playbook's list runs them.
    public static let qaCommands = ["symphony:qa_pre_checks", "symphony:qa_build", "symphony:qa_launch", "symphony:qa_quit", "symphony:qa_attach"]

    /// A QA playbook's default list, as `Config.Schema.Phases.default_qa_steps/1` gives it: only `macos_app` has one.
    /// Its orchestrated steps leave the prompt to Symphony (`priv/qa_steps/macos_app/<id>.md`).
    public static func qaSteps(for playbook: QAPlaybookKind) -> [PhaseStep] {
        guard playbook == .macosApp else { return [] }
        let judged = [
            AnswerField(name: "status"), AnswerField(name: "expected"), AnswerField(name: "actual"), AnswerField(name: "details"),
            AnswerField(name: "evidence", type: .list),
        ]
        return [
            PhaseStep(
                stepID: "pre_checks", title: "Pre-checks", mode: .machine, commands: [StepCommand(run: "symphony:qa_pre_checks")], timeoutMs: 60_000
            ),
            PhaseStep(
                stepID: "build", title: "Build the app", mode: .machine, commands: [StepCommand(run: "symphony:qa_build")],
                timeoutMs: 1_800_000, onFail: "quit"
            ),
            PhaseStep(
                stepID: "plan", title: "Plan the pass", mode: .orchestrated,
                answer: [
                    AnswerField(name: "needs_app", type: .boolean), AnswerField(name: "walk", type: .list),
                    AnswerField(name: "gallery", type: .list), AnswerField(name: "notes"),
                ],
                effort: .high, session: "lead"
            ),
            PhaseStep(
                stepID: "launch", title: "Launch the app", mode: .machine, commands: [StepCommand(run: "symphony:qa_launch")],
                timeoutMs: 300_000, onFail: "quit"
            ),
            PhaseStep(
                stepID: "walk", title: "Walk a step", mode: .orchestrated, answer: judged,
                model: "small", session: PhaseStep.freshSession, repeat: .walkthrough
            ),
            PhaseStep(stepID: "design_check", title: "Design check", mode: .orchestrated, answer: judged, model: "small", session: PhaseStep.freshSession),
            PhaseStep(stepID: "quit", title: "Quit the app", mode: .machine, commands: [StepCommand(run: "symphony:qa_quit")], timeoutMs: 60_000),
            PhaseStep(
                stepID: "attach", title: "Attach the evidence", mode: .machine, commands: [StepCommand(run: "symphony:qa_attach")], timeoutMs: 60_000
            ),
            PhaseStep(stepID: "review", title: "Review and verdict", mode: .orchestrated, effort: .high, session: "lead"),
        ]
    }

    private static var implementation: [PhaseStep] {
        [PhaseStep(stepID: "code", title: "Write the code", mode: .delegated)] + checks(returningTo: "code")
            + [
                windowTests(returningTo: "code"),
                PhaseStep(
                    stepID: "plan_checks",
                    title: "The plan's checks are proved",
                    mode: .machine,
                    commands: [StepCommand(run: checksCommand)],
                    timeoutMs: 60_000,
                    onFail: "code"
                ),
                PhaseStep(stepID: "handoff", title: "Hand off: push and open the pull request", mode: .delegated),
            ]
    }

    private static var ciFix: [PhaseStep] {
        [PhaseStep(stepID: "fix", title: "Fix the failed check", mode: .delegated)] + checks(returningTo: "fix") + [
            PhaseStep(
                stepID: "failed_check",
                title: "The failed check",
                mode: .machine,
                commands: [StepCommand(run: failedCheckCommand)],
                timeoutMs: 3_600_000,
                onFail: "fix"
            ),
            windowTests(returningTo: "fix"),
            PhaseStep(stepID: "handoff", title: "Hand off: push the fix", mode: .delegated),
        ]
    }

    private static func checks(returningTo agentStep: String) -> [PhaseStep] {
        [
            PhaseStep(
                stepID: "build",
                title: "Build",
                mode: .machine,
                commands: [
                    StepCommand(run: "cd macos && make build", when: .macosChanged),
                    StepCommand(run: "mix compile --warnings-as-errors", when: .elixirChanged),
                ],
                timeoutMs: 900_000,
                onFail: agentStep
            ),
            PhaseStep(
                stepID: "checks",
                title: "Format, specs and credo",
                mode: .machine,
                commands: [
                    StepCommand(
                        run: "mix format --check-formatted && mix specs.check && (test -z \"$SYMPHONY_CHANGED_ELIXIR_FILES\" || mix credo --strict $SYMPHONY_CHANGED_ELIXIR_FILES)"
                    ),
                ],
                timeoutMs: 600_000,
                onFail: agentStep,
                when: .elixirSourceChanged
            ),
            PhaseStep(
                stepID: "tests",
                title: "Tests and coverage",
                mode: .machine,
                commands: [
                    StepCommand(run: "(test -z \"$SYMPHONY_CHANGED_TEST_FILES\" || mix test $SYMPHONY_CHANGED_TEST_FILES) && mix cover.changed", when: .elixirSourceChanged),
                    StepCommand(run: "cd macos && swift test --filter \"$SYMPHONY_CHANGED_SWIFT_TEST_FILTER\"", when: .macosChanged),
                ],
                timeoutMs: 1_800_000,
                onFail: agentStep
            ),
        ]
    }

    private static func windowTests(returningTo agentStep: String) -> PhaseStep {
        PhaseStep(
            stepID: "window_tests",
            title: "Window tests",
            mode: .machine,
            commands: [StepCommand(run: windowTestsCommand)],
            timeoutMs: 7_200_000,
            onFail: agentStep
        )
    }
}

/// A check only CI can prove (`Config.Schema.Phases.ci_only_checks/0`): its name as GitHub names the job, the one step
/// of it when only that step is CI's, and why.
public struct CIOnlyCheck: Equatable {
    public let check: String
    public let step: String?
    public let why: String

    public init(check: String, step: String? = nil, why: String) {
        self.check = check
        self.step = step
        self.why = why
    }

    /// `dialyzer`, or `mac checks › Test update, restart and rollback`.
    public var name: String { step.map { "\(check) › \($0)" } ?? check }
}

/// What is wrong with a step list, by the rules Symphony loads it with (`Config.Schema.Phases`): one reason per
/// step at fault, keyed by the step's row `id`. A list with no reason can be saved.
public struct PhaseValidation: Equatable {
    public var reasons: [UUID: String]

    public var isValid: Bool { reasons.isEmpty }

    public func reason(for step: PhaseStep) -> String? { reasons[step.id] }

    /// Lowercase letters, digits and underscores, starting with a letter.
    static func isValidID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// What is wrong with `steps`: a run kind's list, or a QA playbook's (`inQAPlaybook`), which may run the QA pass's
    /// own commands and leave an orchestrated step's prompt to Symphony's prompt file for its id.
    public static func check(_ steps: [PhaseStep], inQAPlaybook: Bool = false) -> PhaseValidation {
        var reasons: [UUID: String] = [:]
        let ids = steps.map(\.stepID)
        for step in steps {
            if let reason = stepReason(step, ids: ids, inQAPlaybook: inQAPlaybook) { reasons[step.id] = reason }
        }
        if reasons.isEmpty, let (step, loop) = loopWithoutDelegated(steps) {
            reasons[step.id] = "Failures can loop through " + loop.map { "`\($0)`" }.joined(separator: " → ")
                + " with no delegated step, so the same commands would run again on the same code."
        }
        return PhaseValidation(reasons: reasons)
    }

    private static func stepReason(_ step: PhaseStep, ids: [String], inQAPlaybook: Bool) -> String? {
        let id = step.stepID
        if id.isEmpty { return "Give the step an id." }
        if !isValidID(id) {
            return "The id must be lowercase letters, digits and underscores, starting with a letter."
        }
        if ids.filter({ $0 == id }).count > 1 { return "Another step has the id `\(id)`." }
        switch step.mode {
        case .machine:
            if step.commands.isEmpty { return "A machine step needs a command." }
            if step.commands.contains(where: { $0.run.trimmingWhitespace().isEmpty }) {
                return "Every command needs a shell line to run."
            }
            if !inQAPlaybook, let command = step.commands.first(where: { PhaseDefaults.qaCommands.contains($0.run) }) {
                return "Runs `\(command.run)`, which only a QA playbook's list runs."
            }
            if let key = step.agentKeys.first { return "`\(key)` is only for an agent step; this step is machine." }
        case .orchestrated:
            if !inQAPlaybook, step.prompt.trimmingWhitespace().isEmpty { return "An orchestrated step needs a prompt." }
            if let reason = step.answer.lazy.compactMap({ answerReason(for: $0, in: step.answer) }).first { return reason }
            if let reason = agentReason(step) { return reason }
        case .delegated:
            if let reason = agentReason(step) { return reason }
        }
        if let timeout = step.timeoutMs, timeout <= 0 { return "The timeout must be more than 0." }
        if let limit = step.noResultLimit, limit <= 0 { return "The no-result limit must be more than 0." }
        if let target = step.returnsTo, !ids.contains(target) {
            return "Returns to `\(target)` on failure, but no step in this list has that id."
        }
        return nil
    }

    /// Why Symphony would refuse an agent step's model or session, nil when it takes them.
    private static func agentReason(_ step: PhaseStep) -> String? {
        if let model = step.model, model.trimmingWhitespace().isEmpty {
            return "Name the model, or leave it empty for the run's model."
        }
        if let session = step.session, session != PhaseStep.freshSession, !isValidID(session) {
            return "The session must be `fresh` or a name of lowercase letters, digits and underscores, starting with a letter."
        }
        return nil
    }

    /// Why Symphony would refuse `field` among an orchestrated step's answer `fields`, nil when it takes it.
    public static func answerReason(for field: AnswerField, in fields: [AnswerField]) -> String? {
        let name = field.name
        if name.isEmpty { return "Give each answer field a name." }
        if !isValidID(name) {
            return "The answer field `\(name)` must be lowercase letters, digits and underscores, starting with a letter."
        }
        if fields.filter({ $0.name == name }).count > 1 { return "Two answer fields are named `\(name)`." }
        return nil
    }

    /// The first step that, passing on to the next step or returning to its `onFail`, can come back to itself
    /// through steps none of which is delegated, with the loop; as Symphony checks it at load.
    private static func loopWithoutDelegated(_ steps: [PhaseStep]) -> (PhaseStep, [String])? {
        let undelegated = Set(steps.filter { $0.mode != .delegated }.map(\.stepID))
        var edges: [String: [String]] = [:]
        for (index, step) in steps.enumerated() {
            let next = index + 1 < steps.count ? steps[index + 1].stepID : nil
            edges[step.stepID] = [next, step.returnsTo].compactMap { $0 }.filter { undelegated.contains($0) }
        }
        for step in steps where undelegated.contains(step.stepID) {
            if let loop = walk(edges, start: step.stepID, path: [step.stepID], seen: [step.stepID]) {
                return (step, loop)
            }
        }
        return nil
    }

    private static func walk(_ edges: [String: [String]], start: String, path: [String], seen: Set<String>) -> [String]? {
        for next in edges[path[path.count - 1]] ?? [] {
            if next == start { return path + [start] }
            if !seen.contains(next), let loop = walk(edges, start: start, path: path + [next], seen: seen.union([next])) {
                return loop
            }
        }
        return nil
    }
}

/// The step list as `symphony workflow preview --kind <kind>` prints it above the prompt
/// (`SymphonyElixir.WorkflowPreview.render_steps/1`, without the line that separates it from the prompt).
public enum PhasePreview {
    public static func text(kind: PhaseKind, list: PhaseSteps) -> String {
        let name = kind.rawValue
        let source = list.isDefault ? "the default list" : "symphony.yml"
        let article = "aeiou".contains(name.first ?? "x") ? "An" : "A"
        guard !list.steps.isEmpty else {
            return "## Steps\n\n\(article) \(name) run follows no step list (\(source)): it is one agent session.\n"
        }
        let lines = list.steps.enumerated().map { stepText($1, number: $0 + 1, playbook: nil) }.joined()
        return "## Steps\n\n\(article) \(name) run follows these steps (\(source), `\(kind.keyPath)`):\n\n" + lines + "\n"
    }

    /// A run kind's list as `text(kind:list:)` prints it; a QA playbook's, which `symphony workflow preview` doesn't
    /// print, in the same words, an orchestrated step with no prompt saying Symphony gives it.
    public static func text(owner: StepListOwner, list: PhaseSteps) -> String {
        switch owner {
        case .runKind(let kind): return text(kind: kind, list: list)
        case .qaPlaybook(let playbook): return text(playbook: playbook, list: list)
        }
    }

    private static func text(playbook: QAPlaybookKind, list: PhaseSteps) -> String {
        let source = list.isDefault ? "the default list" : "symphony.yml"
        guard !list.steps.isEmpty else {
            return "## Steps\n\nA stepped \(playbook.rawValue) QA pass follows no step list (\(source)): it is one agent session.\n"
        }
        let lines = list.steps.enumerated().map { stepText($1, number: $0 + 1, playbook: playbook) }.joined()
        return "## Steps\n\nA stepped \(playbook.rawValue) QA pass follows these steps (\(source), `\(playbook.keyPath)`):\n\n" + lines + "\n"
    }

    private static func stepText(_ step: PhaseStep, number: Int, playbook: QAPlaybookKind?) -> String {
        let facts = [step.mode.rawValue, step.mode == .machine ? step.when.previewText : nil, timeout(step), onFail(step)]
            .compactMap { $0 }
            .joined(separator: " · ")
        return "\(number). `\(step.stepID)` \(step.shownTitle) · \(facts)\n" + body(step, playbook: playbook)
    }

    private static func body(_ step: PhaseStep, playbook: QAPlaybookKind?) -> String {
        switch step.mode {
        case .machine:
            let commands = step.commands.map { command in
                "   - " + (command.when.previewText.map { $0 + ": " } ?? "") + "`\(command.run)`\n"
            }.joined()
            guard step.commands.contains(where: { $0.run == PhaseDefaults.failedCheckCommand }) else { return commands }
            return commands + PhaseDefaults.ciOnlyChecks.map { "   - can only be proved by CI: \($0.name) (\($0.why))\n" }.joined()
        case .orchestrated:
            if let playbook, step.prompt.trimmingWhitespace().isEmpty {
                return "   - prompt: Symphony's own (`priv/qa_steps/\(playbook.rawValue)/\(step.stepID).md`)\n" + answer(step)
            }
            return "   - prompt:\n" + step.prompt.components(separatedBy: "\n").map { "     > \($0)\n" }.joined() + answer(step)
        case .delegated:
            return ""
        }
    }

    /// The answer's fields by name, the order Symphony keeps them in; nothing for a step with none.
    private static func answer(_ step: PhaseStep) -> String {
        guard !step.answer.isEmpty else { return "" }
        let fields = step.answer.sorted { $0.name < $1.name }.map { "`\($0.name)` \($0.type.rawValue)" }
        return "   - answer: " + fields.joined(separator: ", ") + "\n"
    }

    private static func timeout(_ step: PhaseStep) -> String? {
        guard let ms = step.effectiveTimeoutMs else { return nil }
        return ms % 60_000 == 0 ? "times out after \(ms / 60_000) min" : "times out after \(ms) ms"
    }

    private static func onFail(_ step: PhaseStep) -> String? {
        if let target = step.returnsTo { return "on failure returns to `\(target)`" }
        return step.mode == .delegated ? nil : "on failure ends the run"
    }
}

/// The step list of every kind under `phases` in the configured symphony.yml, with QA's own settings: whether a QA
/// pass walks a step list (`phases.qa.stepped`) and each QA playbook's list (`phases.qa.playbooks.<kind>.steps`).
/// Settings edits them in the Phases group; saving rewrites only the `steps:` block of a list that changed, removes a
/// list reset to its default, and writes `stepped` when it changed.
public struct PhaseSettings: Equatable {
    public var lists: [PhaseKind: PhaseSteps]
    /// `phases.qa.stepped`: on, a QA pass walks its playbook's step list; off, every pass is one agent session.
    public var qaStepped: Bool
    /// The QA playbooks' lists the file sets, and those the editor opened; a kind missing here follows its default.
    public var qaPlaybooks: [QAPlaybookKind: PhaseSteps]

    public init(lists: [PhaseKind: PhaseSteps] = [:], qaStepped: Bool = false, qaPlaybooks: [QAPlaybookKind: PhaseSteps] = [:]) {
        self.lists = Dictionary(uniqueKeysWithValues: PhaseKind.allCases.map { ($0, lists[$0] ?? .defaults(for: $0)) })
        self.qaStepped = qaStepped
        self.qaPlaybooks = qaPlaybooks
    }

    public subscript(kind: PhaseKind) -> PhaseSteps {
        get { lists[kind] ?? .defaults(for: kind) }
        set { lists[kind] = newValue }
    }

    public subscript(owner: StepListOwner) -> PhaseSteps {
        get {
            switch owner {
            case .runKind(let kind): return self[kind]
            case .qaPlaybook(let playbook): return qaPlaybooks[playbook] ?? .defaults(for: owner)
            }
        }
        set {
            switch owner {
            case .runKind(let kind): self[kind] = newValue
            case .qaPlaybook(let playbook): qaPlaybooks[playbook] = newValue
            }
        }
    }

    /// The QA playbook kinds the picker offers: Symphony's four, then the others the file or the editor named, by name.
    public var qaPlaybookKinds: [QAPlaybookKind] {
        QAPlaybookKind.builtIn + Set(qaPlaybooks.keys).subtracting(QAPlaybookKind.builtIn).sorted()
    }

    /// Every list: the run kinds', then the QA playbooks' in the picker's order.
    public var owners: [StepListOwner] {
        PhaseKind.allCases.map { .runKind($0) } + qaPlaybookKinds.map { .qaPlaybook($0) }
    }

    /// Equal when `qaStepped` and every list are: a QA playbook missing from one equals its default in the other.
    public static func == (lhs: PhaseSettings, rhs: PhaseSettings) -> Bool {
        let playbooks = Set(lhs.qaPlaybooks.keys).union(rhs.qaPlaybooks.keys)
        return lhs.lists == rhs.lists && lhs.qaStepped == rhs.qaStepped
            && playbooks.allSatisfy { lhs[.qaPlaybook($0)] == rhs[.qaPlaybook($0)] }
    }

    // MARK: Reading

    /// Each list in `yaml`, its default when the file doesn't set it, and whether QA passes are stepped. `phases.qa`
    /// may hold only `stepped` or `playbooks`, and then QA follows its default list.
    public static func values(in yaml: String) throws -> PhaseSettings {
        let document = Document(yaml)
        var settings = PhaseSettings()
        for kind in PhaseKind.allCases {
            guard let kindKey = try key(at: ["phases", kind.rawValue], in: document) else { continue }
            let range = try notABlockAsPhaseError { try document.block(of: kindKey) }
            var setsQASettings = false
            if kind == .qa {
                let stepped = document.child("stepped", in: range)
                let playbooks = document.child("playbooks", in: range)
                settings.qaStepped = try stepped.map(steppedValue) ?? false
                settings.qaPlaybooks = try playbooks.map { try playbookLists(under: $0, in: document) } ?? [:]
                setsQASettings = stepped != nil || playbooks != nil
            }
            guard let stepsKey = document.child("steps", in: range) else {
                if setsQASettings { continue }
                throw PhaseSettingsError.unsupported(line: kindKey.index + 1, reason: "`\(kind.rawValue):` has no `steps:` list")
            }
            settings[kind] = PhaseSteps(steps: try StepsReader(document: document).steps(under: stepsKey), isDefault: false)
        }
        return settings
    }

    /// `stepped:`'s value: true, or false for false or a null.
    private static func steppedValue(_ key: Document.Key) throws -> Bool {
        let value = ValueLine(key.rest).value
        switch value {
        case "true": return true
        case "false": return false
        case let value where Scalar.nulls.contains(value): return false
        default: throw PhaseSettingsError.unsupported(line: key.index + 1, reason: "`stepped: \(value)` is not true or false")
        }
    }

    /// Whether a key's value is an empty map: `{}`, or a null written out.
    private static func isEmptyMap(_ value: String) -> Bool {
        value == "{}" || (!value.isEmpty && Scalar.nulls.contains(value))
    }

    /// The lists under `playbooks:` by kind, each kind an indented block holding its `steps:`; none for `{}` or a null.
    private static func playbookLists(under key: Document.Key, in document: Document) throws -> [QAPlaybookKind: PhaseSteps] {
        let value = ValueLine(key.rest).value
        if isEmptyMap(value) { return [:] }
        guard value.isEmpty else {
            throw PhaseSettingsError.unsupported(line: key.index + 1, reason: "write the playbooks as an indented block under `playbooks:`")
        }
        let children = document.children(of: key)
        guard let indent = document.childIndent(in: children) else { return [:] }
        var lists: [QAPlaybookKind: PhaseSteps] = [:]
        for index in children {
            guard let lineIndent = document.indent(at: index), lineIndent <= indent else { continue }
            let content = document.lines[index].dropFirst(indent)
            let name = String(content.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
            let rest = content.dropFirst(name.count)
            guard lineIndent == indent, !name.isEmpty, rest.hasPrefix(":") else {
                throw PhaseSettingsError.unsupported(line: index + 1, reason: "`\(String(content).trimmingWhitespace())` is not a playbook kind's `name:` line")
            }
            let kindKey = Document.Key(name: name, index: index, indent: indent, rest: String(rest.dropFirst()))
            let block = try notABlockAsPhaseError { try document.block(of: kindKey) }
            guard let stepsKey = document.child("steps", in: block) else {
                throw PhaseSettingsError.unsupported(line: index + 1, reason: "`\(name):` has no `steps:` list")
            }
            lists[QAPlaybookKind(name)] = PhaseSteps(steps: try StepsReader(document: document).steps(under: stepsKey), isDefault: false)
        }
        return lists
    }

    // MARK: Writing

    static let steppedPath = ["phases", "qa", "stepped"]

    /// The same text with the lists that differ between `old` and `new` written (the `steps:` block of a set list, or
    /// the list removed when it was reset to its default), then `phases.qa.stepped`: `true`, or removed when off.
    public static func updating(_ yaml: String, from old: PhaseSettings, to new: PhaseSettings) throws -> String {
        var yaml = yaml
        var seen = Set<StepListOwner>()
        for owner in old.owners + new.owners where seen.insert(owner).inserted && old[owner] != new[owner] {
            yaml = new[owner].isDefault ? try resetting(yaml, owner: owner) : try setting(yaml, owner: owner, to: new[owner].steps)
        }
        if old.qaStepped != new.qaStepped {
            yaml = new.qaStepped
                ? try notABlockAsPhaseError { try ConfigSetting.setting(at: steppedPath, to: "true", in: yaml) }
                : try removing(steppedPath, in: yaml)
        }
        return yaml
    }

    /// The same text with `owner`'s `steps:` holding `steps`, inserting the keys when missing. Only that block is
    /// rewritten.
    static func setting(_ yaml: String, owner: StepListOwner, to steps: [PhaseStep]) throws -> String {
        let path = owner.path
        let opened = owner.qaPlaybook == nil ? yaml : try openingPlaybooks(in: yaml)
        let text = try notABlockAsPhaseError { try ConfigSetting.setting(at: path, to: "[]", in: opened) }
        var document = Document(text)
        guard let stepsKey = try key(at: path, in: document),
              let kindKey = try key(at: Array(path.dropLast()), in: document) else { return text }

        let children = document.children(of: stepsKey)
        if let last = document.lastStructural(in: children) {
            document.lines.removeSubrange((stepsKey.index + 1)...document.blockEnd(last, deeperThan: stepsKey.indent))
        }
        guard !steps.isEmpty else { return document.text }

        let comment = ValueLine(stepsKey.rest).tail.trimmingWhitespace()
        document.lines[stepsKey.index] = String(repeating: " ", count: stepsKey.indent) + "steps:"
            + (comment.isEmpty ? "" : " " + comment)
        let step = max(stepsKey.indent - kindKey.indent, 1)
        document.insert(StepsWriter.lines(steps, indent: stepsKey.indent + step, step: step), after: stepsKey.index)
        return document.text
    }

    /// The text with a `playbooks: {}` or null turned into an empty block, so a kind can go under it.
    private static func openingPlaybooks(in yaml: String) throws -> String {
        var document = Document(yaml)
        guard let key = try key(at: ["phases", "qa", "playbooks"], in: document), isEmptyMap(ValueLine(key.rest).value) else {
            return yaml
        }
        let comment = ValueLine(key.rest).tail.trimmingWhitespace()
        document.lines[key.index] = String(repeating: " ", count: key.indent) + "playbooks:" + (comment.isEmpty ? "" : " " + comment)
        return document.text
    }

    /// The same text without `phases.<kind>`, so the kind follows its default list; without `phases:` too when
    /// nothing else is under it. For `qa`, only its `steps:` goes, so `stepped` and `playbooks` stay.
    static func resetting(_ yaml: String, kind: PhaseKind) throws -> String {
        try resetting(yaml, owner: .runKind(kind))
    }

    /// The same text without `owner`'s list, so it follows its default: a run kind's `phases.<kind>` (only
    /// `phases.qa.steps` for `qa`) or a playbook's `phases.qa.playbooks.<kind>`, and without each key above it the
    /// removal leaves empty.
    static func resetting(_ yaml: String, owner: StepListOwner) throws -> String {
        switch owner {
        case .runKind(let kind) where kind != .qa: return try removing(["phases", kind.rawValue], in: yaml)
        case .runKind, .qaPlaybook: return try removing(owner.path, in: yaml)
        }
    }

    /// The same text without the key at `path` and its block, and without each key above it the removal leaves with
    /// nothing under it.
    static func removing(_ path: [String], in yaml: String) throws -> String {
        var document = Document(yaml)
        guard let target = try key(at: path, in: document) else { return yaml }
        document.lines.removeSubrange(target.index...end(of: target, in: document))
        for depth in stride(from: path.count - 1, through: 1, by: -1) {
            guard let parent = try key(at: Array(path.prefix(depth)), in: document),
                  document.lastStructural(in: document.children(of: parent)) == nil else { break }
            document.lines.removeSubrange(parent.index...end(of: parent, in: document))
        }
        return document.text
    }

    /// The last line of `key`'s block, with the comments right after it that are indented under it.
    private static func end(of key: Document.Key, in document: Document) -> Int {
        let last = document.lastStructural(in: document.children(of: key)) ?? key.index
        return document.blockEnd(last, deeperThan: key.indent)
    }

    /// The `key:` line at `path`, nil when it or a key above it is missing.
    static func key(at path: [String], in document: Document) throws -> Document.Key? {
        var range = document.all
        var found: Document.Key?
        for name in path {
            if let parent = found { range = try notABlockAsPhaseError { try document.block(of: parent) } }
            guard let key = document.child(name, in: range) else { return nil }
            found = key
        }
        return found
    }

    private static func notABlockAsPhaseError<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch MaxConcurrentAgentsError.notABlock(let key) {
            throw PhaseSettingsError.notABlock(key)
        }
    }
}

/// Writes a step list as block-style YAML lines, each value quoted only when it has to be.
enum StepsWriter {
    static func lines(_ steps: [PhaseStep], indent: Int, step: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        return steps.flatMap { item -> [String] in
            let fields = fields(of: item, step: step)
            return fields.enumerated().map { index, field in (index == 0 ? pad + "- " : pad + "  ") + field }
        }
    }

    /// The step's `key: value` lines, relative to the item's column: only the fields its mode takes. An orchestrated
    /// step with no prompt has no `prompt:`, so a QA playbook's step takes Symphony's own.
    private static func fields(of item: PhaseStep, step: Int) -> [String] {
        var fields = ["id: " + scalar(item.stepID)]
        let title = item.title.trimmingWhitespace()
        if !title.isEmpty { fields.append("title: " + scalar(title)) }
        fields.append("mode: " + item.mode.rawValue)
        if item.mode != .machine {
            if let repeats = item.repeat { fields.append("repeat: " + repeats.rawValue) }
            if let session = item.session { fields.append("session: " + scalar(session)) }
            if let model = item.model { fields.append("model: " + scalar(model)) }
            if let effort = item.effort { fields.append("effort: " + effort.rawValue) }
        }
        switch item.mode {
        case .machine:
            if item.when != .always { fields.append("when: " + item.when.rawValue) }
            if item.commands.count == 1, item.commands[0].when == .always {
                fields.append("command: " + scalar(item.commands[0].run))
            } else {
                let pad = String(repeating: " ", count: step)
                fields.append("command:")
                for command in item.commands {
                    fields.append(pad + "- run: " + scalar(command.run))
                    if command.when != .always { fields.append(pad + "  when: " + command.when.rawValue) }
                }
            }
        case .orchestrated:
            if !item.prompt.trimmingWhitespace().isEmpty { fields.append(contentsOf: prompt(item.prompt, step: step)) }
            if !item.answer.isEmpty {
                fields.append("answer: {" + item.answer.map { scalar($0.name) + ": " + $0.type.rawValue }.joined(separator: ", ") + "}")
            }
        case .delegated:
            break
        }
        if let timeout = item.timeoutMs { fields.append("timeout_ms: \(timeout)") }
        if let target = item.returnsTo { fields.append("on_fail: " + scalar(target)) }
        if let limit = item.noResultLimit { fields.append("no_result_limit: \(limit)") }
        return fields
    }

    /// A one-line prompt as a scalar; one of several lines as a literal block (`|`, or `|-` when it doesn't end in
    /// a newline), unless its lines can't be written that way.
    private static func prompt(_ text: String, step: Int) -> [String] {
        guard text.contains("\n") else { return ["prompt: " + scalar(text)] }
        var body = text
        let indicator: String
        if body.hasSuffix("\n") {
            body.removeLast()
            indicator = "|"
        } else {
            indicator = "|-"
        }
        let lines = body.components(separatedBy: "\n")
        let first = lines.first { !$0.isEmpty } ?? ""
        guard !body.hasSuffix("\n"), !first.hasPrefix(" "), !lines.contains(where: { $0.contains("\t") || $0.hasSuffix(" ") })
        else { return ["prompt: " + quoted(text)] }
        let pad = String(repeating: " ", count: step)
        return ["prompt: " + indicator] + lines.map { $0.isEmpty ? "" : pad + $0 }
    }

    static let plainUnsafeStarts = Set("-?:,[]{}#&*!|>'\"%@` \t")
    static let plainUnsafeWords: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "~", "y", "n"]

    /// `text` as a YAML scalar: plain when YAML reads it back as the same string, double-quoted otherwise.
    static func scalar(_ text: String) -> String {
        guard let first = text.first, let last = text.last,
              !plainUnsafeStarts.contains(first), last != " ", last != ":",
              !text.contains(": "), !text.contains(" #"), !text.contains("\n"), !text.contains("\t"),
              !plainUnsafeWords.contains(text.lowercased()), Double(text) == nil
        else { return quoted(text) }
        return text
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for character in text {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.append(character)
            }
        }
        return out + "\""
    }
}

/// Reads a `steps:` block: a list of steps, each an indented mapping or a `{...}` flow mapping, with plain or
/// quoted scalars and literal-block prompts. Anything else is reported with its line, for a change by hand.
struct StepsReader {
    let document: Document

    /// A line of a mapping: its index in the file, its column and its text from that column.
    private struct Line {
        let index: Int
        let column: Int
        let content: String
    }

    static let stepKeys: Set<String> = [
        "id", "title", "mode", "command", "prompt", "answer", "timeout_ms", "on_fail", "no_result_limit", "when", "model", "effort", "session",
        "repeat",
    ]

    func steps(under key: Document.Key) throws -> [PhaseStep] {
        let value = ValueLine(key.rest).value
        if value == "[]" { return [] }
        guard value.isEmpty else { throw unsupported(key.index, "write the steps as an indented list under `steps:`") }
        let range = document.children(of: key)
        let structural = range.filter { document.indent(at: $0) != nil }
        guard let firstIndex = structural.first, let itemIndent = document.indent(at: firstIndex) else {
            if range.upperBound < document.lines.count, document.lines[range.upperBound].dropFirst(key.indent).hasPrefix("-") {
                throw unsupported(range.upperBound, "indent the steps under `steps:`")
            }
            throw unsupported(key.index, "`steps:` is empty; write `steps: []` for no steps")
        }
        let starts = structural.filter { document.indent(at: $0) == itemIndent }
        return try starts.enumerated().map { number, start in
            let end = number + 1 < starts.count ? starts[number + 1] : range.upperBound
            return try step(from: start, to: end, indent: itemIndent)
        }
    }

    private func step(from start: Int, to end: Int, indent: Int) throws -> PhaseStep {
        let entries = try mapping(itemAt: start, to: end, indent: indent)
        var fields: [String: (Line, [Int])] = [:]
        for (line, children) in entries {
            let (name, _) = try split(line)
            guard Self.stepKeys.contains(name) else { throw unsupported(line.index, "a step has an unknown key `\(name)`") }
            fields[name] = (line, children)
        }
        func text(_ name: String) throws -> String? {
            guard let (line, children) = fields[name] else { return nil }
            return try scalarValue(line, children: children)
        }
        func number(_ name: String) throws -> Int? {
            guard let value = try text(name) else { return nil }
            guard let number = Int(value) else { throw unsupported(fields[name]!.0.index, "`\(name): \(value)` is not a whole number") }
            return number
        }
        guard let idLine = fields["id"] else { throw unsupported(start, "a step has no `id`") }
        guard let modeText = try text("mode") else { throw unsupported(start, "step `\(try text("id") ?? "")` has no `mode`") }
        guard let mode = StepMode(rawValue: modeText) else {
            throw unsupported(fields["mode"]!.0.index, "`mode: \(modeText)` is not machine, orchestrated or delegated")
        }
        return PhaseStep(
            stepID: try scalarValue(idLine.0, children: idLine.1) ?? "",
            title: try text("title") ?? "",
            mode: mode,
            commands: try fields["command"].map { try commands($0.0, children: $0.1) } ?? [],
            prompt: try text("prompt") ?? "",
            answer: try fields["answer"].map { try answer($0.0, children: $0.1) } ?? [],
            timeoutMs: try number("timeout_ms"),
            onFail: try text("on_fail"),
            noResultLimit: try number("no_result_limit"),
            when: try condition(try text("when"), line: fields["when"]?.0.index ?? start),
            model: try text("model"),
            effort: try choice("effort", from: try text("effort"), line: fields["effort"]?.0.index ?? start),
            session: try text("session"),
            repeat: try choice("repeat", from: try text("repeat"), line: fields["repeat"]?.0.index ?? start)
        )
    }

    /// The value of the `key:` whose values are `Choice`'s cases, nil when missing or null.
    private func choice<Choice: RawRepresentable & CaseIterable>(_ key: String, from value: String?, line: Int) throws -> Choice?
    where Choice.RawValue == String {
        guard let value else { return nil }
        guard let choice = Choice(rawValue: value) else {
            let names = Choice.allCases.map(\.rawValue)
            let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " or " + names[names.count - 1]
            throw unsupported(line, "`\(key): \(value)` is not \(list)")
        }
        return choice
    }

    /// The entries of the list item starting at `start`: its `key: value` lines with the lines nested under each.
    /// A `{...}` item gives one entry per key, each on the item's line.
    private func mapping(itemAt start: Int, to end: Int, indent: Int) throws -> [(Line, [Int])] {
        let line = document.lines[start]
        let afterDash = line.dropFirst(indent + 1)
        let spaces = afterDash.prefix { $0 == " " }.count
        let content = String(afterDash.dropFirst(spaces))
        guard spaces > 0 || content.isEmpty, !content.isEmpty else { throw unsupported(start, "write each step's first key after `- `") }
        let column = indent + 1 + spaces
        if content.hasPrefix("{") {
            guard (start + 1..<end).allSatisfy({ document.indent(at: $0) == nil }) else {
                throw unsupported(start, "a `{...}` step must stay on one line")
            }
            return try FlowMapping.parse(content, line: start).map { (Line(index: start, column: column, content: "\($0.key): \($0.value)"), []) }
        }
        var entries: [(Line, [Int])] = [(Line(index: start, column: column, content: content), [])]
        for index in (start + 1)..<end {
            guard let lineIndent = rawIndent(index) else {
                entries[entries.count - 1].1.append(index)
                continue
            }
            // A comment out at the keys' column or left of it belongs to no value, not even a literal block.
            if document.indent(at: index) == nil, lineIndent <= column { continue }
            if lineIndent == column {
                entries.append((Line(index: index, column: column, content: String(document.lines[index].dropFirst(column))), []))
            } else if lineIndent > column {
                entries[entries.count - 1].1.append(index)
            } else {
                throw unsupported(index, "line up each key of a step under its first key")
            }
        }
        return entries
    }

    /// Leading spaces of a line, nil for a blank one.
    private func rawIndent(_ index: Int) -> Int? {
        let line = document.lines[index]
        guard !line.allSatisfy(\.isWhitespace) else { return nil }
        return line.prefix { $0 == " " }.count
    }

    private func split(_ line: Line) throws -> (String, String) {
        let content = line.content
        let name = content.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        let rest = content.dropFirst(name.count)
        guard !name.isEmpty, rest.hasPrefix(":"), rest.dropFirst().first.map({ $0 == " " || $0 == "\t" }) ?? true else {
            throw unsupported(line.index, "`\(content.trimmingWhitespace())` is not a `key: value` line")
        }
        return (String(name), String(rest.dropFirst()).trimmingWhitespace())
    }

    /// The scalar after `key:`, or the literal block nested under it; nil for a null.
    private func scalarValue(_ line: Line, children: [Int]) throws -> String? {
        let (name, rest) = try split(line)
        let value = rest.trimmingWhitespace()
        if value.hasPrefix("|") { return try literalBlock(value, children: children, line: line) }
        guard children.allSatisfy({ document.indent(at: $0) == nil }) else {
            throw unsupported(line.index, "`\(name):` holds a value the editor doesn't read")
        }
        return try Scalar.parse(value, line: line.index)
    }

    private func literalBlock(_ indicator: String, children: [Int], line: Line) throws -> String {
        let chomp = String(indicator.dropFirst()).trimmingWhitespace()
        guard chomp == "" || chomp == "-" else { throw unsupported(line.index, "use `|` or `|-` for a block of several lines") }
        let lines = children.map { document.lines[$0] }
        let indent = lines.compactMap { line -> Int? in line.allSatisfy(\.isWhitespace) ? nil : line.prefix { $0 == " " }.count }.min() ?? 0
        var body = lines.map { $0.allSatisfy(\.isWhitespace) ? "" : String($0.dropFirst(indent)) }
        while body.last == "" { body.removeLast() }
        return body.joined(separator: "\n") + (chomp == "-" || body.isEmpty ? "" : "\n")
    }

    /// A `command:` value: one shell line, or a list of `run`/`when` entries, indented or `{...}`.
    private func commands(_ line: Line, children: [Int]) throws -> [StepCommand] {
        let (_, rest) = try split(line)
        if !rest.trimmingWhitespace().isEmpty {
            return try scalarValue(line, children: children).map { [StepCommand(run: $0)] } ?? []
        }
        let structural = children.filter { document.indent(at: $0) != nil }
        guard let first = structural.first, let indent = document.indent(at: first),
              document.lines[first].dropFirst(indent).hasPrefix("-") else {
            throw unsupported(line.index, "`command:` needs a shell line or a list of commands")
        }
        let starts = structural.filter { document.indent(at: $0) == indent }
        let end = (children.last ?? line.index) + 1
        return try starts.enumerated().map { number, start in
            let stop = number + 1 < starts.count ? starts[number + 1] : end
            var run: String?
            var when: String?
            for (entry, nested) in try mapping(itemAt: start, to: stop, indent: indent) {
                let (name, _) = try split(entry)
                switch name {
                case "run": run = try scalarValue(entry, children: nested)
                case "when": when = try scalarValue(entry, children: nested)
                default: throw unsupported(entry.index, "a command has an unknown key `\(name)`")
                }
            }
            guard let run else { throw unsupported(start, "a command has no `run` line") }
            return StepCommand(run: run, when: try condition(when, line: start))
        }
    }

    /// An `answer:` value: a `{name: type, ...}` mapping on its line, or one `name: type` line per field indented
    /// under it; nothing for a null or `{}`.
    private func answer(_ line: Line, children: [Int]) throws -> [AnswerField] {
        let (_, rest) = try split(line)
        let value = rest.trimmingWhitespace()
        let structural = children.filter { document.indent(at: $0) != nil }
        let entries: [(key: String, value: String, line: Int)]
        if value.hasPrefix("{") {
            guard structural.isEmpty else { throw unsupported(line.index, "an `answer: {...}` must stay on one line") }
            entries = try FlowMapping.parse(value, line: line.index).map { ($0.key, $0.value, line.index) }
        } else if structural.isEmpty {
            guard try Scalar.parse(value, line: line.index) == nil else {
                throw unsupported(line.index, "`answer:` needs a field name and type on each line under it")
            }
            return []
        } else {
            guard value.isEmpty || value.hasPrefix("#") else {
                throw unsupported(line.index, "`answer:` needs a field name and type on each line under it")
            }
            let indent = document.indent(at: structural[0])
            entries = try structural.map { index in
                guard document.indent(at: index) == indent else { throw unsupported(index, "line up the answer's fields") }
                let content = document.lines[index].trimmingWhitespace()
                guard let colon = content.range(of: ":") else { throw unsupported(index, "`\(content)` is not a `name: type` line") }
                return (String(content[..<colon.lowerBound]), String(content[colon.upperBound...]), index)
            }
        }
        return try entries.map { entry in
            let name = try Scalar.parse(entry.key, line: entry.line) ?? ""
            let typeText = try Scalar.parse(entry.value, line: entry.line) ?? ""
            guard let type = AnswerType(rawValue: typeText) else {
                throw unsupported(entry.line, "the answer field `\(name)` has the type `\(typeText)`, not string, number, boolean, list or object")
            }
            return AnswerField(name: name, type: type)
        }
    }

    private func condition(_ value: String?, line: Int) throws -> StepCondition {
        guard let value else { return .always }
        guard let condition = StepCondition(rawValue: value) else {
            throw unsupported(line, "`when: \(value)` is not always, macos_changed, elixir_changed or elixir_source_changed")
        }
        return condition
    }

    private func unsupported(_ index: Int, _ reason: String) -> PhaseSettingsError {
        .unsupported(line: index + 1, reason: reason)
    }
}

/// One YAML scalar on a line: plain, single-quoted or double-quoted, with an optional trailing comment.
enum Scalar {
    static let nulls: Set<String> = ["", "~", "null", "Null", "NULL"]

    /// The string `text` holds; nil for a null.
    static func parse(_ text: String, line: Int) throws -> String? {
        let text = text.trimmingWhitespace()
        guard let first = text.first else { return nil }
        let rest: Substring
        let value: String
        switch first {
        case "\"":
            (value, rest) = try doubleQuoted(text.dropFirst(), line: line)
        case "'":
            (value, rest) = try singleQuoted(text.dropFirst(), line: line)
        case "[", "{", "&", "*", "!", ">", "|", "%", "@", "`":
            throw PhaseSettingsError.unsupported(line: line + 1, reason: "`\(text)` is a value the editor doesn't read")
        default:
            let plain = text.range(of: " #").map { String(text[..<$0.lowerBound]) } ?? text
            let trimmed = plain.trimmingWhitespace()
            return nulls.contains(trimmed) ? nil : trimmed
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        guard tail.isEmpty || tail.hasPrefix("#") else {
            throw PhaseSettingsError.unsupported(line: line + 1, reason: "`\(text)` has text after its closing quote")
        }
        return value
    }

    /// The value of a double-quoted scalar whose opening quote is already read, and what follows its closing quote.
    static func doubleQuoted(_ text: Substring, line: Int) throws -> (String, Substring) {
        var value = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" { return (value, text[text.index(after: index)...]) }
            if character == "\\" {
                index = text.index(after: index)
                guard index < text.endIndex else { break }
                switch text[index] {
                case "n": value += "\n"
                case "t": value += "\t"
                case "r": value += "\r"
                case "0": value += "\0"
                case "\\", "\"", "/", " ": value.append(text[index])
                default:
                    throw PhaseSettingsError.unsupported(line: line + 1, reason: "`\\\(text[index])` is an escape the editor doesn't read")
                }
            } else {
                value.append(character)
            }
            index = text.index(after: index)
        }
        throw PhaseSettingsError.unsupported(line: line + 1, reason: "a quoted value doesn't end on its line")
    }

    /// The value of a single-quoted scalar whose opening quote is already read, and what follows its closing quote.
    static func singleQuoted(_ text: Substring, line: Int) throws -> (String, Substring) {
        var value = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "'" {
                let next = text.index(after: index)
                guard next < text.endIndex, text[next] == "'" else { return (value, text[next...]) }
                value += "'"
                index = text.index(after: next)
                continue
            }
            value.append(text[index])
            index = text.index(after: index)
        }
        throw PhaseSettingsError.unsupported(line: line + 1, reason: "a quoted value doesn't end on its line")
    }
}

/// A one-line `{key: value, ...}` flow mapping, its values plain or quoted scalars.
enum FlowMapping {
    /// The entries in order, each value as the scalar text the line gives it (re-read by `Scalar.parse`).
    static func parse(_ text: String, line: Int) throws -> [(key: String, value: String)] {
        func fail(_ reason: String) -> PhaseSettingsError { .unsupported(line: line + 1, reason: reason) }
        var rest = text.dropFirst()
        var entries: [(key: String, value: String)] = []
        while true {
            rest = rest.drop { $0 == " " }
            if rest.first == "}" && entries.isEmpty {
                rest = rest.dropFirst()
                break
            }
            guard let colon = rest.firstIndex(of: ":") else { throw fail("a `{...}` step has a key with no value") }
            let key = rest[..<colon].trimmingCharacters(in: .whitespaces)
            rest = rest[rest.index(after: colon)...].drop { $0 == " " }
            let value: String
            switch rest.first {
            case "\"", "'":
                let quote = rest.first!
                let (_, after) = quote == "\"" ? try Scalar.doubleQuoted(rest.dropFirst(), line: line) : try Scalar.singleQuoted(rest.dropFirst(), line: line)
                value = String(rest[..<after.startIndex])
                rest = after
            case "[", "{":
                throw fail("a `{...}` step holds a nested value; write it as an indented list")
            default:
                let stop = rest.firstIndex { $0 == "," || $0 == "}" } ?? rest.endIndex
                value = rest[..<stop].trimmingCharacters(in: .whitespaces)
                rest = rest[stop...]
            }
            entries.append((key: key, value: value))
            rest = rest.drop { $0 == " " }
            if rest.first == "," {
                rest = rest.dropFirst()
                continue
            }
            guard rest.first == "}" else { throw fail("a `{...}` step doesn't close on its line") }
            rest = rest.dropFirst()
            break
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        guard tail.isEmpty || tail.hasPrefix("#") else { throw fail("a `{...}` step has text after its closing brace") }
        return entries
    }
}

extension SymphonyConfigFile {
    public func readPhaseSettings() throws -> PhaseSettings {
        try PhaseSettings.values(in: read())
    }

    /// Writes the step lists that differ between `old` and `new`, once `check` passes on the result.
    public func writePhaseSettings(
        _ new: PhaseSettings,
        from old: PhaseSettings,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await rewrite({ try PhaseSettings.updating($0, from: old, to: new) }, checkingWith: check)
    }
}
