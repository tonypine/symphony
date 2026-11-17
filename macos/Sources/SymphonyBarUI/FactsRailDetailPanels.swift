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

    /// The shared text area: two lines tall, growing to six; Return adds a line and ⌘↩ saves, as Save Note does.
    private var field: some View {
        TextArea(
            composer.identifier.map(TicketNoteComposer.fieldLabel) ?? NotePanelModel.title, text: $composer.text,
            placeholder: NotePanelModel.placeholder, hint: NotePanelModel.fieldHint, minLines: 2, maxLines: 6, focused: $focused,
            send: { if saveReason == nil, !composer.sending { save() } }
        )
        .disabled(composer.sending)
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
                .font(DesignTokens.TypeStyle.secondary.font)
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
                        decision(row, unfolded: unfolded.contains(row.id)) {
                            withAnimation(FoldMotion.opening(reduceMotion: reduceMotion)) {
                                if unfolded.contains(row.id) { unfolded.remove(row.id) } else { unfolded.insert(row.id) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// One decision: its label and what was decided, unfolding into the question in its own words and the answer.
    private func decision(_ row: DecisionsPanelModel.Row, unfolded: Bool, toggle: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            CollapsibleHead(
                expanded: unfolded, style: .line, accessibilityLabel: row.accessibilityLabel + (unfolded ? ", expanded" : ", collapsed"),
                toggle: toggle
            ) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                    Text(row.id)
                        .font(DesignTokens.TypeStyle.secondary.font.weight(.semibold))
                        .monospacedDigit()
                        .fixedSize()
                    Text(row.headline)
                        .font(DesignTokens.TypeStyle.secondary.font)
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
            FoldBody(expanded: unfolded) {
                KeyValueList(layout: .stacked, style: .secondary) {
                    KeyValueRow("Question") {
                        Text(row.question ?? DecisionsPanelModel.noQuestionLine)
                            .foregroundStyle(row.question == nil ? DesignTokens.TextColor.secondary.color : DesignTokens.TextColor.primary.color)
                            .textSelection(.enabled)
                    }
                    KeyValueRow("Answer", text: row.answer)
                    KeyValueRow("For the scope", text: row.scope)
                }
                .padding(.leading, FactsFold.bodyIndent)
                .foldRow(0)
            }
        }
    }
}

/// Where a facts panel's fold puts its body: under its title, past the chevron.
enum FactsFold {
    static let bodyIndent: Double = 12 + DesignTokens.Space.s2
}

// MARK: - The Details panel

public struct DetailsPanel: View {
    let model: DetailsPanelModel
    let open: (URL) -> Void
    let copy: (String) -> Void
    @State private var modelsUnfolded: Bool
    @State private var briefUnfolded: Bool
    @State private var descriptionUnfolded: Bool
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
            KeyValueList(style: .secondary) {
                if let repo = model.repo {
                    KeyValueRow("Repo") { Chip(repo, kind: .repo) }
                }
                if let priority = model.priority {
                    KeyValueRow("Priority") { valueText(priority) }
                }
                KeyValueRow("Labels") {
                    if model.labels.isEmpty {
                        valueText(DetailsPanelModel.noLabelsLine, secondary: true)
                    } else {
                        FlowLayout(spacing: DesignTokens.Space.s1, lineSpacing: DesignTokens.Space.s1) {
                            ForEach(model.labels, id: \.self) { Chip($0, kind: .label(.idle)) }
                        }
                    }
                }
                if let workspace = model.workspace {
                    KeyValueRow("Workspace") { workspaceValue(workspace) }
                }
                if let summary = model.modelsSummary {
                    KeyValueRow("Models") { modelsValue(summary) }
                }
                if !model.links.isEmpty {
                    KeyValueRow("Links") {
                        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                            ForEach(model.links) { link in
                                FactRow(url: link.url, open: open) {
                                    HStack(spacing: DesignTokens.Space.s1) {
                                        Text(link.title)
                                            .font(DesignTokens.TypeStyle.secondary.font)
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
            .font(DesignTokens.TypeStyle.secondary.font)
            .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func workspaceValue(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            KeyValuePath(path, copyLabel: "Copy the workspace path", copy: copy)
            if let host = model.workspaceHost {
                Text("On \(host)")
                    .font(DesignTokens.TypeStyle.caption.font)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func modelsValue(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            CollapsibleHead(
                expanded: modelsUnfolded, style: .line, accessibilityLabel: "Each run's model, \(summary)" + (modelsUnfolded ? ", expanded" : ", collapsed"),
                toggle: { withAnimation(FoldMotion.opening(reduceMotion: reduceMotion)) { modelsUnfolded.toggle() } }
            ) {
                valueText(summary)
            }
            FoldBody(expanded: modelsUnfolded) {
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
                .padding(.leading, FactsFold.bodyIndent)
                .foldRow(0)
            }
        }
    }

    /// The brief and its walkthrough, open by default: what the ticket does and why, for a person.
    private var briefFold: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            CollapsibleHead(
                expanded: briefUnfolded, style: .line, accessibilityLabel: DetailsPanelModel.briefTitle + (briefUnfolded ? ", expanded" : ", collapsed"),
                toggle: { withAnimation(FoldMotion.opening(reduceMotion: reduceMotion)) { briefUnfolded.toggle() } }
            ) {
                foldTitle(DetailsPanelModel.briefTitle, detail: model.brief?.written)
            }
            FoldBody(expanded: briefUnfolded) {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                    if let brief = model.brief {
                        prose(brief.text, style: .reading)
                        if let walkthrough = brief.walkthrough {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(DetailsPanelModel.walkthroughTitle)
                                    .font(DesignTokens.TypeStyle.caption.font.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .accessibilityAddTraits(.isHeader)
                                prose(walkthrough, style: .reading)
                            }
                        }
                    } else {
                        EmptyLine(text: DetailsPanelModel.noBriefLine)
                    }
                }
                .padding(.leading, FactsFold.bodyIndent)
                .foldRow(0)
            }
        }
    }

    /// The ticket's description the agent works from, folded by default.
    private var descriptionFold: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            CollapsibleHead(
                expanded: descriptionUnfolded, style: .line,
                accessibilityLabel: DetailsPanelModel.agentDescriptionTitle + (descriptionUnfolded ? ", expanded" : ", collapsed"),
                toggle: { withAnimation(FoldMotion.opening(reduceMotion: reduceMotion)) { descriptionUnfolded.toggle() } }
            ) {
                foldTitle(DetailsPanelModel.agentDescriptionTitle, detail: nil)
            }
            FoldBody(expanded: descriptionUnfolded) {
                Group {
                    if let description = model.agentDescription {
                        prose(description)
                    } else {
                        EmptyLine(text: DetailsPanelModel.noDescriptionLine)
                    }
                }
                .padding(.leading, FactsFold.bodyIndent)
                .foldRow(0)
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

    /// `style` is `.reading` for the brief and its walkthrough (`--type-reading`), the text the Director reads
    /// through.
    private func prose(_ text: String, style: DesignTokens.TypeStyle = .secondary) -> some View {
        Text(text)
            .textStyle(style)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
