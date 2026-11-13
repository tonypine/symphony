import SwiftUI
import SymphonyBarCore

/// Settings › Phases (`phases.<kind>.steps`): the step list a run kind follows, reorderable by drag or by the arrow
/// buttons, each step's title, id, kind, command or prompt (with an orchestrated step's answer fields), timeout and the step it returns to on failure; Add step,
/// Remove and Reset to default; a step the rules refuse says why on its row. Under the list, the list as
/// `symphony workflow preview` prints it.
struct PhasesSection: View {
    @ObservedObject var model: SettingsViewModel
    /// The rows open for editing.
    @State private var expanded: Set<UUID> = []

    private var kind: PhaseKind { model.phaseKind }
    private var list: PhaseSteps { model.phases[kind] }

    var body: some View {
        Section {
            Picker("Run kind", selection: $model.phaseKind) {
                ForEach(PhaseKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pointerStyle(.link)
            Text(
                list.isDefault
                    ? "Follows its default list: symphony.yml doesn't set \(kind.keyPath)."
                    : "Follows the list in symphony.yml (\(kind.keyPath))."
            )
            .foregroundStyle(.secondary)

            if list.steps.isEmpty {
                Text("No steps: a \(kind.title.lowercased()) run is one agent session.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(list.steps.enumerated()), id: \.element.id) { index, step in
                PhaseStepRow(
                    number: index + 1,
                    step: binding(for: step.id),
                    stepIDs: list.steps.map(\.stepID),
                    reason: model.phaseValidation.reason(for: step),
                    isExpanded: expandedBinding(step.id),
                    canMoveUp: index > 0,
                    canMoveDown: index < list.steps.count - 1,
                    move: { offset in model.phases[kind].move(step.id, by: offset) },
                    remove: {
                        expanded.remove(step.id)
                        model.phases[kind].removeStep(step.id)
                    }
                )
            }
            .onMove { source, destination in model.phases[kind].move(fromOffsets: source, toOffset: destination) }

            HStack {
                Button("Add step") {
                    expanded.insert(model.phases[kind].addStep())
                }
                .pointerStyle(.link)
                .accessibilityLabel("Add a step to the \(kind.title) list")
                Spacer()
                Button("Reset to default") {
                    expanded = []
                    model.phases[kind] = .defaults(for: kind)
                }
                .pointerStyle(.link)
                .disabled(list.isDefault)
                .help("Removes \(kind.keyPath) from symphony.yml on Save, so the run follows its default list.")
            }

            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                Text("Preview: the list the next run follows").font(.headline)
                ScrollView {
                    Text(PhasePreview.text(kind: kind, list: list))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DesignTokens.Space.s2)
                }
                .frame(minHeight: 80, maxHeight: 260)
                .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.mark).fill(.quaternary.opacity(0.5)))
                .accessibilityLabel("Preview of the \(kind.title) step list")
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
                    + "the agent does in its session. A failure returns to the step named, or ends the run. The preview "
                    + "is what symphony workflow preview prints. Save checks symphony.yml with symphony check first; the "
                    + "next run follows the saved list."
            )
        }
        .disabled(!model.canEditPhases)
    }

    private func binding(for id: UUID) -> Binding<PhaseStep> {
        let kind = kind
        return Binding(
            get: { model.phases[kind].steps.first { $0.id == id } ?? PhaseStep(stepID: "", mode: .delegated) },
            set: { step in
                guard let index = model.phases[kind].steps.firstIndex(where: { $0.id == id }) else { return }
                model.phases[kind].steps[index] = step
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

/// One step: a summary line (number, id, title, kind, what it returns to) with its reason when the rules refuse it,
/// the move and remove buttons, and, open, the fields its kind takes.
private struct PhaseStepRow: View {
    let number: Int
    @Binding var step: PhaseStep
    let stepIDs: [String]
    let reason: String?
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
                PhaseStepFields(step: $step, stepIDs: stepIDs)
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

    /// The kind and what a failure does, as one line.
    private var summary: String {
        var parts = [step.mode.title]
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

/// The fields of one step, only those its kind takes.
private struct PhaseStepFields: View {
    @Binding var step: PhaseStep
    let stepIDs: [String]

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
                PhaseAnswerFields(step: $step)
            case .delegated:
                EmptyView()
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
