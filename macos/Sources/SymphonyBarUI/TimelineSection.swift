import SwiftUI
import SymphonyBarCore

// The catalog's Timeline section and Timeline entry (`docs/design/director-ticket-page.md` §1 facts 12 and 32, §4):
// a ticket's history newest first in one column of at most 780 pt, a separator on each day with its date and how long
// the day's history ran, each entry with its time, its class's glyph, what happened and who did it, and each run as
// its Run group with the run now on top, unfolded. A row is selected with a click or the arrow keys (the accent tint
// and ring), Return and Space fold the selected run, and Escape clears the selection. A new event drops in from 12 pt
// above on a spring and its tint fades over 1.2 s; under Reduce Motion it is there at once. The marks (TP-1451): the
// line "Since you last looked, at 16:50" above the newest item the person saw, and a small accent dot on every entry
// and ended run newer than it; the Timeline title (`TimelineTitle`) counts the new events.

/// The timeline's keys (§4 Keyboard): the arrows move the selection, Return and Space fold the selected run, Escape
/// clears the selection.
public enum TimelineKeys {
    public enum Action: Equatable {
        case move(Int)
        case toggle
        case clear
    }

    public static let keys: Set<KeyEquivalent> = [.upArrow, .downArrow, .return, .space, .escape]

    /// What `key` does with no modifier held; nil for any other key or a modifier. The arrows come with the numeric
    /// pad and function flags, the keypad's Enter with the numeric pad's: they aren't modifiers a person holds.
    public static func action(_ key: KeyEquivalent, modifiers: EventModifiers) -> Action? {
        guard modifiers.subtracting([.numericPad, .function]).isEmpty else { return nil }
        switch key {
        case .downArrow: return .move(1)
        case .upArrow: return .move(-1)
        case .return, .space: return .toggle
        case .escape: return .clear
        default: return nil
        }
    }
}

public struct TimelineSection: View {
    let model: TimelineModel
    @ObservedObject var transcripts: StepTranscripts
    let clock: (Date) -> String
    @State private var selection: String?
    /// The runs the person folded or unfolded, over each run's default.
    @State private var runFolds: FoldState
    /// The items on the timeline when it first drew: anything newer enters with the motion.
    @State private var seen: Set<String>
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The column's widest (the catalog's Timeline: one column of at most 780 pt, at both widths).
    public static let maxWidth: CGFloat = 780
    /// The column of times, and the column of marks after it.
    static let timeColumn: CGFloat = 40
    static let markColumn: CGFloat = 18

    /// `selection` and `unfoldedRuns` say what is selected and which runs are open to start with; nil opens what
    /// opens by default. The times are `calendar`'s.
    public init(
        model: TimelineModel, transcripts: StepTranscripts, calendar: Calendar = .current, selection: String? = nil,
        unfoldedRuns: Set<String>? = nil
    ) {
        self.model = model
        self.transcripts = transcripts
        clock = TimelineModel.clock(calendar)
        _selection = State(initialValue: selection)
        let runs = model.items.compactMap(\.run).map(\.id)
        _runFolds = State(initialValue: unfoldedRuns.map { FoldState(ids: runs, unfolded: $0) } ?? FoldState())
        _seen = State(initialValue: Set(model.items.map(\.id)))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            if model.isEmpty {
                Text(TimelineModel.empty)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, DesignTokens.Space.s2)
            }
            ForEach(model.days) { day in
                DaySeparator(day: day)
                ForEach(day.items) { item in
                    if let marker = model.marker, marker.before == item.id {
                        SinceLookedLine(text: TicketMarksRead.markerText(marker.lookedAt, clock: clock))
                    }
                    row(item)
                        .modifier(TimelineEntering(entering: !seen.contains(item.id), reduceMotion: reduceMotion) {
                            seen.insert(item.id)
                        })
                }
            }
        }
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: TimelineKeys.keys, phases: .down) { press in
            guard let action = TimelineKeys.action(press.key, modifiers: press.modifiers) else { return .ignored }
            return handle(action)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.title)
    }

    public static let title = "Timeline"

    @ViewBuilder
    private func row(_ item: TimelineItem) -> some View {
        let selected = selection == item.id
        switch item {
        case let .entry(entry):
            TimelineEntryRow(entry: entry, time: clock(entry.at), selected: selected) { select(item.id) }
        case let .run(run, at):
            TimelineRunRow(run: run, time: clock(at), selected: selected, transcripts: transcripts, fold: fold(run)) {
                select(item.id)
            }
        }
    }

    private func select(_ id: String) {
        focused = true
        withAnimation(.motion(.standard, reduceMotion: reduceMotion)) { selection = id }
    }

    private func handle(_ action: TimelineKeys.Action) -> KeyPress.Result {
        switch action {
        case let .move(steps):
            guard !model.isEmpty else { return .ignored }
            withAnimation(.motion(.standard, reduceMotion: reduceMotion)) { selection = model.moving(selection, by: steps) }
            return .handled
        case .toggle:
            guard let selection, let run = model.items.first(where: { $0.id == selection })?.run else { return .ignored }
            withAnimation(.motion(.standard, reduceMotion: reduceMotion)) { runFolds.toggle(run.id, byDefault: run.opensByDefault) }
            return .handled
        case .clear:
            guard selection != nil else { return .ignored }
            withAnimation(.motion(.standard, reduceMotion: reduceMotion)) { selection = nil }
            return .handled
        }
    }

    /// The run's fold, kept here so Return on the selected run folds it as a click on its line does.
    private func fold(_ run: RunGroupModel) -> Binding<Bool> {
        Binding(
            get: { runFolds.isUnfolded(run.id, byDefault: run.opensByDefault) },
            set: { unfolded in
                if unfolded != runFolds.isUnfolded(run.id, byDefault: run.opensByDefault) {
                    runFolds.toggle(run.id, byDefault: run.opensByDefault)
                }
            }
        )
    }
}

/// The Timeline section's title, with the count of events new since the person last looked ("3 new") beside it.
public struct TimelineTitle: View {
    let marks: TicketMarksRead?

    public init(marks: TicketMarksRead?) {
        self.marks = marks
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            Text(TimelineSection.title)
                .font(DesignTokens.TypeStyle.section.font)
                .accessibilityAddTraits(.isHeader)
            if let new = marks?.newText {
                Text(new)
                    .font(DesignTokens.TypeStyle.callout.font.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.SystemColor.accent.color)
                    .help(TimelineEntry.newHelp)
                    .accessibilityLabel(marks?.newAccessibilityLabel ?? new)
            }
        }
    }
}

/// The line where the person last looked: its words in the accent between two thin accent rules.
private struct SinceLookedLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.s2) {
            rule.frame(width: 12)
            Text(text)
                .font(DesignTokens.TypeStyle.caption.font.weight(.semibold))
                .tracking(0.2)
                .foregroundStyle(DesignTokens.SystemColor.accent.color)
                .fixedSize()
            rule
        }
        .padding(.vertical, DesignTokens.Space.s2)
        .padding(.leading, TimelineSection.timeColumn + DesignTokens.Space.s2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var rule: some View {
        Rectangle()
            .fill(DesignTokens.SystemColor.accent.color.opacity(0.4))
            .frame(height: 1)
    }
}

/// A day's separator: its date (and "Today" or "Yesterday"), how long its history ran, and a rule across.
private struct DaySeparator: View {
    let day: TimelineDay

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.s2) {
            Text(day.title.uppercased())
                .font(DesignTokens.TypeStyle.caption.font.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .fixedSize()
            if let span = day.span {
                Text(span)
                    .font(DesignTokens.TypeStyle.caption.font)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            Rectangle()
                .fill(DesignTokens.Surface.separator.color)
                .frame(height: 1)
        }
        .padding(.top, DesignTokens.Space.s4)
        .padding(.bottom, DesignTokens.Space.s1)
        .padding(.leading, TimelineSection.timeColumn + DesignTokens.Space.s2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.accessibilityLabel)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One entry: its time, its class's glyph in its tone, what happened in bold with the rest after it, its detail and
/// who did it, and a pause's duration at the end.
struct TimelineEntryRow: View {
    let entry: TimelineEntry
    let time: String
    let selected: Bool
    let select: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            Text(time)
                .font(DesignTokens.TypeStyle.callout.font)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: TimelineSection.timeColumn, alignment: .trailing)
            Image(systemName: entry.kind.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Self.color(entry.kind.tone))
                .frame(width: TimelineSection.markColumn)
                .help(Self.glyphHelp(entry.kind))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(newDot)\(Text(entry.lead).fontWeight(.semibold))\(entry.rest.map { " " + $0 } ?? "")")
                    .font(DesignTokens.TypeStyle.body.font)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(entry.isNew ? TimelineEntry.newHelp : "")
                if let detail = entry.detail {
                    Text(detail)
                        .font(DesignTokens.TypeStyle.callout.font)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(entry.actor)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: DesignTokens.Measure.reading, alignment: .leading)
            Spacer(minLength: DesignTokens.Space.s2)
            if let duration = entry.duration {
                Text(duration)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help(Self.durationHelp)
            }
        }
        .padding(.vertical, DesignTokens.Space.s1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(RowFace(state: DesignTokens.Interaction(hovered: hovered, selected: selected), reduceMotion: reduceMotion))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: select)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.accessibilityLabel(time: time))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
    }

    static let durationHelp = "How long the pause lasted"

    /// The small accent dot before what happened, on an entry newer than the person's last look.
    private var newDot: Text {
        guard entry.isNew else { return Text(verbatim: "") }
        return Text(Image(systemName: "circle.fill"))
            .font(.system(size: 6))
            .baselineOffset(2.5)
            .foregroundStyle(DesignTokens.SystemColor.accent.color) + Text(verbatim: "  ")
    }

    /// What the glyph means, under the pointer: "Phase move".
    static func glyphHelp(_ kind: TimelineEntry.Kind) -> String {
        kind.word.prefix(1).uppercased() + kind.word.dropFirst()
    }

    static func color(_ tone: TimelineEntry.Tone) -> Color {
        switch tone {
        case .accent: DesignTokens.SystemColor.accent.color
        case let .status(status): status.tint
        }
    }
}

/// A run on the timeline: its start in the column of times, then its Run group; selected, it takes the accent tint
/// and ring around the whole group.
private struct TimelineRunRow: View {
    let run: RunGroupModel
    let time: String
    let selected: Bool
    @ObservedObject var transcripts: StepTranscripts
    let fold: Binding<Bool>
    let select: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(time)
                .font(DesignTokens.TypeStyle.callout.font)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: TimelineSection.timeColumn, alignment: .trailing)
                .padding(.top, DesignTokens.Space.s2)
                .accessibilityHidden(true)
            RunGroup(run: run, transcripts: transcripts, fold: fold)
        }
        .background {
            if selected {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                    .fill(DesignTokens.StateSurface.selected.fill(dark: colorScheme == .dark))
            }
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                    .strokeBorder(DesignTokens.Selection.color.color, lineWidth: DesignTokens.Selection.rowRingWidth)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { select() })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilityLabel(run, time: time))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The group for VoiceOver: "Started at 09:02 by Implementation run 1".
    static func accessibilityLabel(_ run: RunGroupModel, time: String) -> String {
        "Started at \(time) by \(run.title)"
    }
}

/// A new entry dropping in from above on a spring while its accent tint fades; under Reduce Motion it is there at once.
private struct TimelineEntering: ViewModifier {
    let entering: Bool
    let reduceMotion: Bool
    let entered: () -> Void
    @State private var settled: Bool
    @State private var tint: Double
    @Environment(\.colorScheme) private var colorScheme

    init(entering: Bool, reduceMotion: Bool, entered: @escaping () -> Void) {
        self.entering = entering
        self.reduceMotion = reduceMotion
        self.entered = entered
        let moves = entering && DesignTokens.Motion.entering(reduceMotion: reduceMotion) != nil
        _settled = State(initialValue: !moves)
        _tint = State(initialValue: moves ? 1 : 0)
    }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                    .fill(DesignTokens.SystemColor.accent.color.opacity(DesignTokens.Motion.enterTint(dark: colorScheme == .dark) * tint))
            }
            .offset(y: settled ? 0 : -DesignTokens.Motion.enterOffset)
            .opacity(settled ? 1 : 0)
            .onAppear {
                guard entering else { return }
                entered()
                guard !settled, case let .spring(duration, bounce)? = DesignTokens.Motion.entering(reduceMotion: reduceMotion) else { return }
                withAnimation(.spring(duration: duration, bounce: bounce)) { settled = true }
                withAnimation(.easeOut(duration: DesignTokens.Motion.enterTintDuration)) { tint = 0 }
            }
    }
}
