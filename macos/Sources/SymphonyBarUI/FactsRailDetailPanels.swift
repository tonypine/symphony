import AppKit
import SwiftUI
import SymphonyBarCore

// The facts rail's last three panels (`docs/design/director-ticket-page.md` §1 facts 17, 18, 22 to 25, 27, 30 and
// 33): Note for the next run (the note set, by whom and when, which run read it, and the field with Save Note), the
// Decisions (newest first, each folding into its question and answer) and the Details (the catalog's Key-value list:
// repo, priority, labels, workspace with Copy, each run's model folded, links out, then the brief and walkthrough
// above the agent description, which stays folded). Titles sit outside the cards as the rail's first two panels'.

// MARK: - The Note for the next run panel

public struct NotePanel: View {
    let model: NotePanelModel
    @ObservedObject var composer: TicketNoteComposer
    let save: () -> Void

    @Environment(\.offscreenSnapshot) private var offscreenSnapshot
    @FocusState private var focused: Bool

    /// `composer` holds the field's text, whether a note is on its way and why the last one wasn't saved; `save` posts
    /// it (`TicketNoteComposer.submit(identifier:repoKey:send:read:)`).
    public init(model: NotePanelModel, composer: TicketNoteComposer, save: @escaping () -> Void) {
        self.model = model
        self.composer = composer
        self.save = save
    }

    private var saveReason: String? { model.saveReason(composer.text) }

    public var body: some View {
        FactsPanel(title: NotePanelModel.title) {
            if let current = model.current {
                CurrentNote(current: current)
            } else {
                EmptyLine(text: NotePanelModel.emptyLine)
            }
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                field
                Text(NotePanelModel.fieldHint)
                    .font(DesignTokens.TypeStyle.caption.font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
                if let refusal = composer.refusal {
                    Refusal(reason: refusal)
                        .accessibilityLabel(TicketNoteComposer.refusalLabel(refusal))
                }
                HStack(spacing: DesignTokens.Space.s2) {
                    if let reason = saveReason, composer.refusal == nil {
                        Text(reason)
                            .font(DesignTokens.TypeStyle.caption.font)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: DesignTokens.Space.s2)
                    Button(composer.sending ? NotePanelModel.savingTitle : NotePanelModel.saveTitle, action: save)
                        .directorButton(.primary, size: .medium)
                        .disabled(saveReason != nil || composer.sending)
                        .help(saveReason ?? NotePanelModel.saveTitle)
                        .accessibilityHint(saveReason ?? NotePanelModel.fieldHint)
                }
            }
        }
    }

    @ViewBuilder private var field: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
        Group {
            if offscreenSnapshot {
                // `ImageRenderer` draws no text field: its text, or its placeholder, stands in.
                Text(composer.text.isEmpty ? NotePanelModel.placeholder : composer.text)
                    .foregroundStyle(composer.text.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            } else {
                TextField(NotePanelModel.placeholder, text: $composer.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...6)
                    .focused($focused)
                    .disabled(composer.sending)
                    .onSubmit { if saveReason == nil { save() } }
                    .accessibilityLabel(composer.identifier.map(TicketNoteComposer.fieldLabel) ?? NotePanelModel.title)
            }
        }
        .font(DesignTokens.TypeStyle.body.font)
        .padding(DesignTokens.Space.s2)
        .background(DesignTokens.Surface.window.color, in: shape)
        .overlay(shape.strokeBorder(focused ? Color.accentColor : DesignTokens.Surface.separator.color, lineWidth: 1))
    }
}

/// The note set: its text, who set it and when, and which run read it, or that none has yet.
private struct CurrentNote: View {
    let current: NotePanelModel.Current

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            Text(current.text)
                .font(DesignTokens.TypeStyle.body.font)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(current.setLine)
                .font(DesignTokens.TypeStyle.caption.font)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s1) {
                Image(systemName: current.read ? "checkmark.circle.fill" : "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(current.read ? AnyShapeStyle(DesignTokens.Status.done.tint) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
                Text(current.readLine)
                    .font(DesignTokens.TypeStyle.caption.font.weight(.medium))
                    .foregroundStyle(current.read ? AnyShapeStyle(DesignTokens.Status.done.tint) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
            }
            Text(current.confirmation)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignTokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Surface.raised.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(current.accessibilityLabel)
    }
}

// MARK: - The Decisions panel

public struct DecisionsPanel: View {
    let model: DecisionsPanelModel
    @State private var unfolded: Set<String>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `unfolded` names the decisions open at first ("D2"); every one starts folded by default.
    public init(model: DecisionsPanelModel, unfolded: Set<String> = []) {
        self.model = model
        _unfolded = State(initialValue: unfolded)
    }

    public var body: some View {
        FactsPanel(title: DecisionsPanelModel.title) {
            if model.rows.isEmpty {
                EmptyLine(text: DecisionsPanelModel.emptyLine)
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                    ForEach(model.rows) { row in
                        DecisionRow(row: row, unfolded: unfolded.contains(row.id)) {
                            withAnimation(.motion(.fold, reduceMotion: reduceMotion)) {
                                if unfolded.contains(row.id) { unfolded.remove(row.id) } else { unfolded.insert(row.id) }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One decision: its label and what was decided, unfolding into the question in its own words and the answer.
private struct DecisionRow: View {
    let row: DecisionsPanelModel.Row
    let unfolded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            FoldHeader(
                unfolded: unfolded, accessibilityLabel: row.accessibilityLabel + (unfolded ? ", expanded" : ", collapsed"), toggle: toggle
            ) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                    Text(row.id)
                        .font(DesignTokens.TypeStyle.callout.font.weight(.semibold))
                        .monospacedDigit()
                        .fixedSize()
                    Text(row.headline)
                        .font(DesignTokens.TypeStyle.callout.font)
                        .lineLimit(unfolded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: DesignTokens.Space.s2)
                    if let date = row.date {
                        Text(date)
                            .font(DesignTokens.TypeStyle.caption.font)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
            }
            if unfolded {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                    part("Question", row.question ?? DecisionsPanelModel.noQuestionLine, secondary: row.question == nil)
                    part("Answer", row.answer, secondary: false)
                    if let scope = row.scope { part("For the scope", scope, secondary: false) }
                }
                .padding(.leading, 12 + DesignTokens.Space.s2)
                .transition(.opacity)
            }
        }
    }

    private func part(_ label: String, _ text: String, secondary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DesignTokens.TypeStyle.caption.font.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The Details panel

public struct DetailsPanel: View {
    let model: DetailsPanelModel
    let open: (URL) -> Void
    let copy: (String) -> Void
    @State private var modelsUnfolded: Bool
    @State private var briefUnfolded: Bool
    @State private var descriptionUnfolded: Bool
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `open` opens a link out; `copy` puts the workspace path on the pasteboard (`DetailsPanel.pasteboardCopy` by
    /// default). The brief starts open, the models and the agent description folded; the snapshots open them.
    public init(
        model: DetailsPanelModel, open: @escaping (URL) -> Void, copy: @escaping (String) -> Void = DetailsPanel.pasteboardCopy,
        modelsUnfolded: Bool = false, briefUnfolded: Bool = true, descriptionUnfolded: Bool = false
    ) {
        self.model = model
        self.open = open
        self.copy = copy
        _modelsUnfolded = State(initialValue: modelsUnfolded)
        _briefUnfolded = State(initialValue: briefUnfolded)
        _descriptionUnfolded = State(initialValue: descriptionUnfolded)
    }

    /// Puts `text` on the general pasteboard.
    public static func pasteboardCopy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public var body: some View {
        FactsPanel(title: DetailsPanelModel.title) {
            KeyValueList {
                if let repo = model.repo {
                    KeyValueRow(label: "Repo") { Chip(text: repo, systemImage: "shippingbox") }
                }
                if let priority = model.priority {
                    KeyValueRow(label: "Priority") { valueText(priority) }
                }
                KeyValueRow(label: "Labels") {
                    if model.labels.isEmpty {
                        valueText(DetailsPanelModel.noLabelsLine, secondary: true)
                    } else {
                        FlowLayout(spacing: DesignTokens.Space.s1, lineSpacing: DesignTokens.Space.s1) {
                            ForEach(model.labels, id: \.self) { Chip(text: $0, systemImage: nil) }
                        }
                    }
                }
                if let workspace = model.workspace {
                    KeyValueRow(label: "Workspace") { workspaceValue(workspace) }
                }
                if let summary = model.modelsSummary {
                    KeyValueRow(label: "Models") { modelsValue(summary) }
                }
                if !model.links.isEmpty {
                    KeyValueRow(label: "Links") {
                        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                            ForEach(model.links) { link in
                                FactRow(url: link.url, open: open) {
                                    HStack(spacing: DesignTokens.Space.s1) {
                                        Text(link.title)
                                            .font(DesignTokens.TypeStyle.callout.font)
                                            .foregroundStyle(Color.accentColor)
                                        Image(systemName: "arrow.up.right")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(Color.accentColor)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .accessibilityLabel(link.title)
                                .accessibilityHint("Opens it in the browser")
                            }
                        }
                    }
                }
            }
            Divider()
            briefFold
            descriptionFold
        }
    }

    private func valueText(_ text: String, secondary: Bool = false) -> some View {
        Text(text)
            .font(DesignTokens.TypeStyle.callout.font)
            .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func workspaceValue(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button(copied ? DetailsPanelModel.copiedTitle : DetailsPanelModel.copyTitle) {
                    copy(path)
                    copied = true
                }
                .directorButton(.quiet, size: .small)
                .accessibilityLabel("Copy the workspace path")
            }
            if let host = model.workspaceHost {
                Text("On \(host)")
                    .font(DesignTokens.TypeStyle.caption.font)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func modelsValue(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            FoldHeader(
                unfolded: modelsUnfolded, accessibilityLabel: "Each run's model, \(summary)" + (modelsUnfolded ? ", expanded" : ", collapsed"),
                toggle: { withAnimation(.motion(.fold, reduceMotion: reduceMotion)) { modelsUnfolded.toggle() } }
            ) {
                valueText(summary)
            }
            if modelsUnfolded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.models) { run in
                        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                            Text(run.run)
                                .font(DesignTokens.TypeStyle.caption.font)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                            Text(run.model)
                                .font(DesignTokens.TypeStyle.caption.font)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.leading, 12 + DesignTokens.Space.s2)
                .transition(.opacity)
            }
        }
    }

    /// The brief and its walkthrough, open by default: what the ticket does and why, for a person.
    private var briefFold: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            FoldHeader(
                unfolded: briefUnfolded, accessibilityLabel: DetailsPanelModel.briefTitle + (briefUnfolded ? ", expanded" : ", collapsed"),
                toggle: { withAnimation(.motion(.fold, reduceMotion: reduceMotion)) { briefUnfolded.toggle() } }
            ) {
                foldTitle(DetailsPanelModel.briefTitle, detail: model.brief?.written)
            }
            if briefUnfolded {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                    if let brief = model.brief {
                        prose(brief.text)
                        if let walkthrough = brief.walkthrough {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(DetailsPanelModel.walkthroughTitle)
                                    .font(DesignTokens.TypeStyle.caption.font.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .accessibilityAddTraits(.isHeader)
                                prose(walkthrough)
                            }
                        }
                    } else {
                        EmptyLine(text: DetailsPanelModel.noBriefLine)
                    }
                }
                .padding(.leading, 12 + DesignTokens.Space.s2)
                .transition(.opacity)
            }
        }
    }

    /// The ticket's description the agent works from, folded by default.
    private var descriptionFold: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            FoldHeader(
                unfolded: descriptionUnfolded,
                accessibilityLabel: DetailsPanelModel.agentDescriptionTitle + (descriptionUnfolded ? ", expanded" : ", collapsed"),
                toggle: { withAnimation(.motion(.fold, reduceMotion: reduceMotion)) { descriptionUnfolded.toggle() } }
            ) {
                foldTitle(DetailsPanelModel.agentDescriptionTitle, detail: nil)
            }
            if descriptionUnfolded {
                Group {
                    if let description = model.agentDescription {
                        prose(description)
                    } else {
                        EmptyLine(text: DetailsPanelModel.noDescriptionLine)
                    }
                }
                .padding(.leading, 12 + DesignTokens.Space.s2)
                .transition(.opacity)
            }
        }
    }

    private func foldTitle(_ title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            Text(title)
                .font(DesignTokens.TypeStyle.label.font)
            Spacer(minLength: DesignTokens.Space.s2)
            if let detail {
                Text(detail)
                    .font(DesignTokens.TypeStyle.caption.font)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
    }

    private func prose(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.TypeStyle.callout.font)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

// MARK: - The Key-value list

/// The catalog's Key-value list: labels in secondary on the left, their values beside them; a fact that is unknown is
/// left out, never shown as a dash.
struct KeyValueList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: DesignTokens.Space.s4, verticalSpacing: DesignTokens.Space.s2) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct KeyValueRow<Value: View>: View {
    let label: String
    @ViewBuilder let value: Value

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
                .fixedSize()
                .gridColumnAlignment(.leading)
            value
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// A chip: a repo or a label, on the raised surface.
private struct Chip: View {
    let text: String
    let systemImage: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.row - 2, style: .continuous)
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(shape.fill(DesignTokens.Surface.raised.color))
        .overlay(shape.strokeBorder(DesignTokens.Surface.separator.color))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}
