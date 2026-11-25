import SwiftUI
import SymphonyBarCore

// A step's lines as a conversation (`docs/design/prototypes/run-conversation/`, approved 2026-11-24): the agent's notes
// at reading size across the column, what each note did folded into one line under it, a failure in its own row in the
// problem treatment, and the minute above an entry when it changes. 12 pt between entries, 4 pt between a note and its
// fold line. A click on a fold line unfolds its actions as the step's rows (`TranscriptLineRow`), monospace only there.

// MARK: - The conversation

/// A step's conversation, top to bottom, its groups folded or unfolded as `folds` says.
public struct RunConversationView: View {
    let entries: [ConversationEntry]
    @Binding var folds: ConversationFolds
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(entries: [ConversationEntry], folds: Binding<ConversationFolds>) {
        self.entries = entries
        _folds = folds
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Self.entrySpacing) {
            ForEach(entries) { entry in
                ConversationEntryView(entry: entry, open: folds.isOpen(entry.id)) {
                    withAnimation(.motion(.standard, reduceMotion: reduceMotion)) { folds.toggle(entry.id, among: entries.map(\.id)) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilityLabel)
    }

    /// Between two entries.
    public static let entrySpacing: CGFloat = DesignTokens.Space.s3
    /// Between a note and its fold line.
    public static let foldSpacing: CGFloat = DesignTokens.Space.s1
    public static let accessibilityLabel = "What the agent said and did"
}

/// One entry: its minute line when the minute changed, then its note and fold line, its fold line alone, or its failure.
struct ConversationEntryView: View {
    let entry: ConversationEntry
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let minute = entry.minute {
                ConversationMinuteLine(minute: minute)
                    .padding(.bottom, 2)
            }
            switch entry.kind {
            case .note:
                if let note = entry.note { ConversationNote(text: note.text) }
                if entry.hasFold {
                    fold.padding(.top, RunConversationView.foldSpacing)
                }
            case .actions:
                fold
            case .failure:
                if let failure = entry.failure { ConversationFailureRow(action: failure, repeats: entry.repeats) }
                if entry.working { ConversationWorkingMark().padding(.top, RunConversationView.foldSpacing) }
            }
        }
    }

    @ViewBuilder private var fold: some View {
        ConversationFoldLine(gist: entry.gist, open: open, working: entry.working, toggle: toggle)
        if open, !entry.actions.isEmpty {
            ConversationActionRows(actions: entry.actions)
                .padding(.top, DesignTokens.Space.s1)
                .transition(.opacity)
        }
    }
}

// MARK: - Note

/// What the agent wrote: the compact reading style, the full width of the column, its Markdown rendered (bold, italic,
/// inline code, lists, paragraphs and code blocks). Never cut.
public struct ConversationNote: View {
    let markup: ConductorMarkup

    public init(text: String) {
        markup = RunNote.markup(text)
    }

    public var body: some View {
        ConductorMarkupText(markup: markup, style: .readingCompact)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("The agent said: " + markup.plainText)
    }
}

// MARK: - Fold line

/// A group's one line: its chevron, "3 actions" ("2 actions so far" while the run works on it), and its gist, the files
/// written or edited as chips. "Working" follows while the run works on the group. A click unfolds or folds it.
public struct ConversationFoldLine: View {
    let gist: ActionGist
    let open: Bool
    let working: Bool
    let toggle: () -> Void
    @State private var hovered = false

    public init(gist: ActionGist, open: Bool, working: Bool = false, toggle: @escaping () -> Void = {}) {
        self.gist = gist
        self.open = open
        self.working = working
        self.toggle = toggle
    }

    public var body: some View {
        if gist.count == 0 {
            if working { ConversationWorkingMark() }
        } else {
            Button(action: toggle) { line }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(open ? "Expanded" : "Collapsed")
                .accessibilityAddTraits(.isButton)
        }
    }

    private var line: some View {
        FlowLayout(spacing: DesignTokens.Space.s1, lineSpacing: 2) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DesignTokens.TextColor.secondary.color)
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: 12)
            Text(gist.countText(soFar: working))
                .font(DesignTokens.TypeStyle.secondary.font.weight(.semibold))
                .foregroundStyle(hovered ? DesignTokens.TextColor.primary.color : DesignTokens.TextColor.secondary.color)
            if !gist.parts.isEmpty {
                Text(verbatim: "·")
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(DesignTokens.TextColor.tertiary.color)
            }
            ForEach(Array(gist.parts.enumerated()), id: \.offset) { index, part in
                partView(part, last: index == gist.parts.count - 1)
            }
            if working { ConversationWorkingMark() }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private func partView(_ part: ActionGist.Part, last: Bool) -> some View {
        switch part {
        case let .wrote(files):
            word("wrote")
            ForEach(files, id: \.self) { ConversationFileChip(name: $0) }
        case let .edited(files):
            word("edited")
            ForEach(files, id: \.self) { ConversationFileChip(name: $0) }
        case let .words(words):
            word(last ? words : words + ",")
        }
    }

    private func word(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.TypeStyle.secondary.font)
            .foregroundStyle(DesignTokens.TextColor.secondary.color)
    }

    private var accessibilityLabel: String {
        ([gist.countText(soFar: working), gist.text.isEmpty ? nil : gist.text, working ? ConversationWorkingMark.word : nil].compactMap { $0 })
            .joined(separator: ", ")
    }
}

/// A file written or edited, named in a fold line: its name after a document glyph, in a hairline capsule.
public struct ConversationFileChip: View {
    let name: String

    public init(name: String) {
        self.name = name
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "doc")
                .font(.system(size: 9, weight: .medium))
            Text(name)
                .font(DesignTokens.TypeStyle.caption.font)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(DesignTokens.TextColor.secondary.color)
        .padding(.horizontal, DesignTokens.Chip.padding + 1)
        .padding(.vertical, 1)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Chip.radius, style: .continuous)
                .strokeBorder(DesignTokens.Surface.separator.color, lineWidth: 1)
        }
    }
}

/// "Working", after the live dot: the run works on this entry.
public struct ConversationWorkingMark: View {
    public init() {}

    public var body: some View {
        HStack(spacing: DesignTokens.Space.s1) {
            StatusDot(.working, size: .regular, live: true)
            Text(Self.word)
                .font(DesignTokens.TypeStyle.secondary.font.weight(.medium))
                .foregroundStyle(DesignTokens.Status.working.text)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.word)
    }

    public static let word = "Working"
}

// MARK: - Failure

/// A failed command or a red test, never folded: "Failed", the tool and what it was asked, then the first lines of what
/// came back, in the problem treatment. The same failure back to back is one row with its count ("×8").
public struct ConversationFailureRow: View {
    let action: RunAction
    let repeats: Int

    public init(action: RunAction, repeats: Int = 1) {
        self.action = action
        self.repeats = repeats
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                Image(systemName: DesignTokens.Status.problem.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignTokens.Status.problem.tint)
                Text(TranscriptLineRow.failedWord)
                    .font(DesignTokens.TypeStyle.secondary.font.weight(.semibold))
                    .foregroundStyle(DesignTokens.Status.problem.text)
                if let call = action.call {
                    (Text(call.toolName.map { $0 + "  " } ?? "").fontWeight(.semibold) + Text(call.body))
                        .font(DesignTokens.TypeStyle.mono.font)
                        .foregroundStyle(DesignTokens.TextColor.primary.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if repeats > 1 {
                    Text(Self.count(repeats))
                        .font(DesignTokens.TypeStyle.label.font)
                        .foregroundStyle(DesignTokens.Status.problem.text)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            let shown = action.firstLines()
            if !shown.isEmpty {
                Text(shown.joined(separator: "\n"))
                    .font(DesignTokens.TypeStyle.mono.font)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .lineLimit(RunAction.shownLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, DesignTokens.Space.s3)
        .padding(.vertical, DesignTokens.Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                .fill(DesignTokens.Status.problem.tint.opacity(0.12))
            RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                .strokeBorder(DesignTokens.Status.problem.tint.opacity(0.45), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// "×8".
    static func count(_ repeats: Int) -> String { "×\(repeats)" }

    private var accessibilityLabel: String {
        let call = action.call.map { "\($0.text)" }
        let times = repeats > 1 ? "\(repeats) times in a row" : nil
        return ([TranscriptLineRow.failedWord, call, times].compactMap { $0 }.joined(separator: ", ")) + ": " + action.firstLines().joined(separator: " ")
    }
}

// MARK: - Minute line

/// The time above an entry, when the minute changed from the entry before: small, quiet, in no column of its own.
public struct ConversationMinuteLine: View {
    let minute: String

    public init(minute: String) {
        self.minute = minute
    }

    public var body: some View {
        Text(minute)
            .font(DesignTokens.TypeStyle.caption.font)
            .foregroundStyle(DesignTokens.TextColor.tertiary.color)
            .monospacedDigit()
            .accessibilityLabel("At " + minute)
    }
}

// MARK: - Unfolded actions

/// A group's actions unfolded: each call and what came back, as the step's rows (tool, short description, result).
struct ConversationActionRows: View {
    let actions: [RunAction]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            ForEach(Array(actions.flatMap(\.lines).enumerated()), id: \.offset) { _, line in
                TranscriptLineRow(line: line)
            }
        }
        .padding(.leading, DesignTokens.Space.s4)
    }
}
