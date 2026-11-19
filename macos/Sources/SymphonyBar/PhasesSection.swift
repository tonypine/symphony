import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// Settings › Phases (`phases.<kind>.steps`): the step list a run kind follows, reorderable by drag or by the arrow
/// buttons, each step's title, id, kind, command or prompt (with an orchestrated step's answer fields), what an agent
/// step's turn runs with (model, effort, session, repeat), timeout and the step it returns to on failure; Add step,
/// Remove and Reset to default; a step the rules refuse says why on its row. On QA, the Stepped QA passes switch
/// (`phases.qa.stepped`) and the list to edit: QA's own or a QA playbook's (`phases.qa.playbooks.<kind>.steps`).
/// Under the list, the list as `symphony workflow preview` prints it.
struct PhasesSection: View {
    @ObservedObject var model: SettingsViewModel
    /// The rows open for editing.
    @State private var expanded: Set<UUID> = []

    private var owner: StepListOwner { model.phaseListOwner }
    private var list: PhaseSteps { model.phases[owner] }

    /// The list's name in a sentence: `Implementation`, or `macOS app QA playbook`.
    private var listTitle: String {
        switch owner {
        case .runKind(let kind): return kind.title
        case .qaPlaybook(let playbook): return "\(playbook.title) QA playbook"
        }
    }

    /// What Reset to default removes on Save.
    private var resetKeyPath: String {
        owner.qaPlaybook.map { "phases.qa.playbooks.\($0.rawValue)" } ?? owner.keyPath
    }

    private var emptyListText: String {
        switch owner {
        case .runKind(let kind): return "No steps: a \(kind.title.lowercased()) run is one agent session."
        case .qaPlaybook(let playbook): return "No steps: a \(playbook.title) QA pass is one agent session."
        }
    }

    var body: some View {
        Section {
            Picker("Run kind", selection: $model.phaseKind) {
                ForEach(PhaseKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pointerStyle(.link)
            if model.phaseKind == .qa {
                QAPhaseControls(stepped: $model.phases.qaStepped, playbook: $model.phaseQAPlaybook, kinds: model.phases.qaPlaybookKinds) { kind in
                    if model.phases.qaPlaybooks[kind] == nil { model.phases[.qaPlaybook(kind)] = .defaults(for: .qaPlaybook(kind)) }
                    model.phaseQAPlaybook = kind
                }
            }
            Text(
                list.isDefault
                    ? "Follows its default list: symphony.yml doesn't set \(owner.keyPath)."
                    : "Follows the list in symphony.yml (\(owner.keyPath))."
            )
            .foregroundStyle(.secondary)

            if list.steps.isEmpty {
                Text(emptyListText)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(list.steps.enumerated()), id: \.element.id) { index, step in
                PhaseStepRow(
                    number: index + 1,
                    step: binding(for: step.id),
                    stepIDs: list.steps.map(\.stepID),
                    reason: model.phaseValidation.reason(for: step),
                    playbook: owner.qaPlaybook,
                    isExpanded: expandedBinding(step.id),
                    canMoveUp: index > 0,
                    canMoveDown: index < list.steps.count - 1,
                    move: { offset in model.phases[owner].move(step.id, by: offset) },
                    remove: {
                        expanded.remove(step.id)
                        model.phases[owner].removeStep(step.id)
                    }
                )
            }
            .onMove { source, destination in model.phases[owner].move(fromOffsets: source, toOffset: destination) }

            HStack {
                Button("Add step") {
                    expanded.insert(model.phases[owner].addStep())
                }
                .pointerStyle(.link)
                .accessibilityLabel("Add a step to the \(listTitle) list")
                Spacer()
                Button("Reset to default") {
                    expanded = []
                    model.phases[owner] = .defaults(for: owner)
                }
                .pointerStyle(.link)
                .disabled(list.isDefault)
                .help("Removes \(resetKeyPath) from symphony.yml on Save, so it follows its default list.")
            }

            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                Text("Preview: the list the next run follows").font(.headline)
                ScrollView {
                    Text(PhasePreview.text(owner: owner, list: list))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DesignTokens.Space.s2)
                }
                .frame(minHeight: 80, maxHeight: 260)
                .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.mark).fill(.quaternary.opacity(0.5)))
                .accessibilityLabel("Preview of the \(listTitle) step list")
            }
            if model.phasesError != nil {
                Text("These step lists weren't saved; the reason shows above Save.")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Phases (saved in symphony.yml)")
        } footer: {
            SectionFooter(
                "phases.<kind>.steps. The steps a run of each kind follows, in order: a machine step runs a shell "
                    + "command, an orchestrated step starts an agent turn from its prompt, and a delegated step is work "
                    + "the agent does in its session. A failure returns to the step named, or ends the run. A stepped QA "
                    + "pass (phases.qa.stepped) walks its playbook's list (phases.qa.playbooks.<kind>.steps). The preview "
                    + "is what symphony workflow preview prints. Save checks symphony.yml with symphony check first; the "
                    + "next run follows the saved list."
            )
        }
        .disabled(!model.canEditPhases)
    }

    private func binding(for id: UUID) -> Binding<PhaseStep> {
        let owner = owner
        return Binding(
            get: { model.phases[owner].steps.first { $0.id == id } ?? PhaseStep(stepID: "", mode: .delegated) },
            set: { step in
                guard let index = model.phases[owner].steps.firstIndex(where: { $0.id == id }) else { return }
                model.phases[owner].steps[index] = step
            }
        )
    }

    private func expandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { open in
                if open { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }
}

/// QA's own settings above its list (`phases.qa`): the Stepped QA passes switch (`stepped`), and the list the editor
/// shows: QA's own (`steps`) or a QA playbook's (`playbooks.<kind>.steps`), with a field to name a kind of the
/// project's own.
struct QAPhaseControls: View {
    @Binding var stepped: Bool
    @Binding var playbook: QAPlaybookKind?
    let kinds: [QAPlaybookKind]
    let addKind: (QAPlaybookKind) -> Void
    @State private var newKind = ""

    private var candidate: QAPlaybookKind { QAPlaybookKind(newKind.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        Toggle("Stepped QA passes", isOn: $stepped)
            .help(
                "phases.qa.stepped. On, a QA pass walks its playbook's step list, one agent turn a step; off, every QA "
                    + "pass is one agent session."
            )
        PopUp(
            "List",
            selection: $playbook,
            choices: [PopUpChoice(QAPlaybookKind?.none, "QA's own list")] + kinds.map { PopUpChoice(Optional($0), "\($0.title) playbook") },
            accessibilityLabel: "The QA step list to edit"
        )
        if playbook != nil, !stepped {
            Text("Stepped QA passes is off, so QA passes don't walk this list yet.")
                .textStyle(.secondary)
        }
        HStack {
            DirectorTextField(
                "Another playbook kind",
                text: $newKind,
                placeholder: "kind_name",
                help: "A QA playbook kind of the project's own: lowercase letters, digits and underscores, starting with a letter.",
                mono: true
            )
            Button("Add") {
                addKind(candidate)
                newKind = ""
            }
            .directorButton(.secondary, disabledReason: addReason)
        }
    }

    /// Why Add is off: a name Symphony would refuse, or a kind already listed.
    private var addReason: String? {
        if !candidate.isValid { return "Name the kind first." }
        if kinds.contains(candidate) { return "That kind is listed already." }
        return nil
    }
}

/// One step: a summary line (number, id, title, kind, what it returns to) with its reason when the rules refuse it,
/// the move and remove buttons, and, open, the fields its kind takes. `playbook` is the QA playbook whose list it is in.
struct PhaseStepRow: View {
    let number: Int
    @Binding var step: PhaseStep
    let stepIDs: [String]
    let reason: String?
    let playbook: QAPlaybookKind?
    @Binding var isExpanded: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            HStack(spacing: DesignTokens.Space.s2) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: DesignTokens.Space.s2) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .frame(width: 12)
                        Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
                        Text(step.stepID.isEmpty ? "(no id)" : step.stepID).font(.system(.body, design: .monospaced))
                        Text(step.shownTitle).lineLimit(1)
                        Text(summary).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .accessibilityLabel("Step \(number), \(step.stepID): \(step.shownTitle)")
                .accessibilityHint(isExpanded ? "Closes the step's fields" : "Opens the step's fields")

                Button { move(-1) } label: { Image(systemName: "arrow.up") }
                    .disabled(!canMoveUp)
                    .pointerStyle(.link)
                    .help("Move up")
                    .accessibilityLabel("Move \(step.stepID) up")
                Button { move(1) } label: { Image(systemName: "arrow.down") }
                    .disabled(!canMoveDown)
                    .pointerStyle(.link)
                    .help("Move down")
                    .accessibilityLabel("Move \(step.stepID) down")
                Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }
                    .pointerStyle(.link)
                    .help("Remove")
                    .accessibilityLabel("Remove \(step.stepID)")
            }
            .controlSize(.small)

            if let reason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Can't be saved: \(reason)")
            }

            if isExpanded {
                PhaseStepFields(step: $step, stepIDs: stepIDs, playbook: playbook)
                    .padding(.leading, DesignTokens.Space.s5)
            }
        }
        .padding(.vertical, DesignTokens.Space.s1)
        .padding(.horizontal, DesignTokens.Space.s1)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.mark)
                .fill(isExpanded ? Color.accentColor.opacity(0.10) : hovering ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { hovering = $0 }
    }

    /// The kind, what an agent step's turn runs with, and what a failure does, as one line.
    private var summary: String {
        var parts = [step.mode.title]
        if step.mode != .machine {
            if step.repeat != nil { parts.append("once per walkthrough step") }
            if let session = step.session { parts.append("session \(session)") }
            if let model = step.model { parts.append("model \(model)") }
            if let effort = step.effort { parts.append("\(effort.title) effort") }
        }
        if let target = step.returnsTo {
            parts.append("returns to \(target)")
        } else if step.mode != .delegated {
            parts.append("a failure ends the run")
        }
        return "· " + parts.joined(separator: " · ")
    }
}

/// An orchestrated step's answer (`answer`): each field the agent's JSON answer must hold, with its type, which
/// Symphony checks before the step passes. A field Symphony would refuse says why on its line.
private struct PhaseAnswerFields: View {
    @Binding var step: PhaseStep

    var body: some View {
        LabeledContent("Answer") {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                if step.answer.isEmpty {
                    Text("No fields: Symphony doesn't check the agent's answer.")
                        .foregroundStyle(.secondary)
                }
                ForEach($step.answer) { $field in
                    VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                        HStack {
                            TextField("Field name", text: $field.name, prompt: Text("lowercase_name"))
                                .labelsHidden()
                                .font(.system(.body, design: .monospaced))
                                .accessibilityLabel("Answer field name")
                            Picker("Type", selection: $field.type) {
                                ForEach(AnswerType.allCases) { type in
                                    Text(type.title).tag(type)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .pointerStyle(.link)
                            .accessibilityLabel("Type of the answer field \(field.name)")
                            IconButton("minus.circle", help: "Remove the answer field \(field.name)", size: .small) {
                                step.removeAnswerField(field.id)
                            }
                        }
                        if let reason = PhaseValidation.answerReason(for: field, in: step.answer) {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Button("Add field") { step.addAnswerField() }
                    .pointerStyle(.link)
                    .accessibilityLabel("Add an answer field to \(step.stepID)")
            }
        }
    }
}

/// What an agent step's turn runs with and where: its model, effort, session and repeat, each empty for the run's
/// own. A machine step shows them only while it still sets one, so the refused value can be cleared.
private struct PhaseStepAgentFields: View {
    @Binding var step: PhaseStep

    var body: some View {
        DirectorTextField(
            "Model",
            text: optionalText($step.model),
            placeholder: "Run's model",
            help: "A model id, or small for the run's small model. Empty runs the run's model.",
            mono: true
        )
        PopUp(
            "Effort",
            selection: $step.effort,
            choices: [PopUpChoice(StepEffort?.none, "Run's effort")] + StepEffort.allCases.map { PopUpChoice(Optional($0), $0.title) }
        )
        DirectorTextField(
            "Session",
            text: optionalText($step.session),
            placeholder: "Run's session",
            help: "Steps with the same session name continue one agent session; fresh starts a new session for this step alone. "
                + "Empty runs in the run's one session.",
            mono: true
        )
        PopUp(
            "Repeat",
            selection: $step.repeat,
            choices: [PopUpChoice(StepRepeat?.none, "Once")] + StepRepeat.allCases.map { PopUpChoice(Optional($0), $0.title) }
        )
    }

    /// An optional text as a field's text: empty is missing, so the run's own applies.
    private func optionalText(_ value: Binding<String?>) -> Binding<String> {
        Binding(
            get: { value.wrappedValue ?? "" },
            set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}

/// The fields of one step, only those its kind takes. `playbook` is the QA playbook whose list it is in, where an
/// orchestrated step may leave its prompt to Symphony.
private struct PhaseStepFields: View {
    @Binding var step: PhaseStep
    let stepIDs: [String]
    let playbook: QAPlaybookKind?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            TextField("Title", text: $step.title, prompt: Text(step.stepID))
            TextField("Id", text: $step.stepID, prompt: Text("lowercase_with_underscores"))
            LabeledContent("Kind") {
                SegmentedControl("Kind", selection: $step.mode, segments: StepMode.allCases.map { Segment($0, $0.title) })
            }
            Text(step.mode.explanation).foregroundStyle(.secondary)

            switch step.mode {
            case .machine:
                Picker("Runs", selection: $step.when) {
                    ForEach(StepCondition.allCases) { condition in
                        Text(condition.title).tag(condition)
                    }
                }
                .pointerStyle(.link)
                ForEach($step.commands) { $command in
                    HStack {
                        TextField("Command", text: $command.run, prompt: Text("mix test"))
                            .font(.system(.body, design: .monospaced))
                        Picker("When", selection: $command.when) {
                            ForEach(StepCondition.allCases) { condition in
                                Text(condition.title).tag(condition)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .pointerStyle(.link)
                        IconButton("minus.circle", help: "Remove this command", size: .small) {
                            step.commands.removeAll { $0.id == command.id }
                        }
                    }
                }
                Button("Add command") { step.commands.append(StepCommand(run: "")) }
                    .pointerStyle(.link)
            case .orchestrated:
                LabeledContent("Prompt") {
                    TextEditor(text: $step.prompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 60, maxHeight: 160)
                        .accessibilityLabel("Prompt")
                }
                if let playbook, step.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Empty: Symphony uses its own prompt for this step, priv/qa_steps/\(playbook.rawValue)/\(step.stepID).md.")
                        .textStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PhaseAnswerFields(step: $step)
            case .delegated:
                EmptyView()
            }

            if step.mode != .machine || !step.agentKeys.isEmpty {
                PhaseStepAgentFields(step: $step)
            }

            LabeledContent("Timeout") {
                HStack {
                    TextField("Timeout", text: number($step.timeoutMs), prompt: Text(timeoutPrompt))
                        .labelsHidden()
                        .frame(width: 110)
                    Text("ms").foregroundStyle(.secondary)
                }
            }
            LabeledContent("On failure, returns to") {
                HStack {
                    TextField("Returns to", text: returnsTo, prompt: Text("none: a failure ends the run"))
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                    Menu("Pick") {
                        Button("None: end the run") { step.onFail = nil }
                        ForEach(stepIDs.filter { $0 != step.stepID }, id: \.self) { id in
                            Button(id) { step.onFail = id }
                        }
                    }
                    .fixedSize()
                    .pointerStyle(.link)
                    .accessibilityLabel("Pick the step a failure returns to")
                }
            }
            LabeledContent("No-result limit") {
                TextField("No-result limit", text: number($step.noResultLimit), prompt: Text("2"))
                    .labelsHidden()
                    .frame(width: 110)
                    .help("How many times in a row the step may end with no result before the run pauses on a question.")
            }
        }
    }

    private var timeoutPrompt: String {
        step.mode == .machine ? "\(PhaseStep.machineTimeoutMs)" : "the agent's turn timeout"
    }

    private var returnsTo: Binding<String> {
        Binding(
            get: { step.onFail ?? "" },
            set: { step.onFail = $0.isEmpty ? nil : $0 }
        )
    }

    /// An optional whole number as text: empty is missing, so Symphony's default applies; other text that isn't a
    /// whole number is kept out.
    private func number(_ value: Binding<Int?>) -> Binding<String> {
        Binding(
            get: { value.wrappedValue.map(String.init) ?? "" },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    value.wrappedValue = nil
                } else if let parsed = Int(trimmed) {
                    value.wrappedValue = parsed
                }
            }
        )
    }
}
