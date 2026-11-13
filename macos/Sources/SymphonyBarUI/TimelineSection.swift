import SwiftUI
import SymphonyBarCore

// The catalog's Timeline section and Timeline entry (`docs/design/director-ticket-page.md` §1 facts 12 and 32, §4):
// a ticket's history newest first in one column of at most 780 pt, a separator on each day with its date and how long
// the day's history ran, each entry with its time, its class's glyph, what happened and who did it, and each run as
// its Run group with the run now on top, unfolded. A row is selected with a click or the arrow keys (the accent tint
// and ring), Return and Space fold the selected run, and Escape clears the selection. A new event drops in from 12 pt
// above on a spring and its tint fades over 1.2 s; under Reduce Motion it is there at once. The marks (TP-1451): the
// line "Since you last looked, at 16:50" above the newest item the person saw, and a small accent dot on every entry
// and ended run newer than it; the Timeline title (`TimelineTitle`) counts the new events. The run in place (TP-1452):
// the run now is the timeline's first line, unfolded and live, its newest lines coming in as the page reads the ticket;
// when no run works on the ticket that place holds one line from the situation saying why, so the page keeps its shape.

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
    /// Why nothing runs, shown in the run now's place while no run works on the ticket.
    let idle: TimelineIdleLine?
    @ObservedObject var transcripts: StepTranscripts
    let clock: (Date) -> String
    @State private var selection: String?
    /// The runs the person folded or unfolded, over each run's default.
    @State private var runFolds: FoldState
    /// The items on the timeline when it first drew: anything newer enters with the motion.
    @State private var seen: Set<String>
    /// The event the page opened at (a Journal row's), and whether the timeline has shown it yet.
    let focus: TimelineFocus?
    @State private var focusShown = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The column's widest (the catalog's Timeline: one column of at most 780 pt, at both widths).
    public static let maxWidth: CGFloat = 780
    /// The column of times, and the column of marks after it.
    static let timeColumn: CGFloat = 40
    static let markColumn: CGFloat = 18

    /// `selection` and `unfoldedRuns` say what is selected and which runs are open to start with; nil opens what
    /// opens by default. The times are `calendar`'s. `idle` is the line shown in the run now's place when no run works.
    public init(
        model: TimelineModel, idle: TimelineIdleLine? = nil, transcripts: StepTranscripts, calendar: Calendar = .current,
        selection: String? = nil, unfoldedRuns: Set<String>? = nil, focus: TimelineFocus? = nil
    ) {
        self.model = model
        self.focus = focus
        self.idle = idle
        self.transcripts = transcripts
        clock = TimelineModel.clock(calendar)
        _selection = State(initialValue: selection)
        let runs = model.items.compactMap(\.run).map(\.id)
        _runFolds = State(initialValue: unfoldedRuns.map { FoldState(ids: runs, unfolded: $0) } ?? FoldState())
        _seen = State(initialValue: Set(model.items.map(\.id)))
        // The event opened at is selected from the first draw that holds it.
        if selection == nil, let target = focus.flatMap(model.item(holding:)) {
            _selection = State(initialValue: target)
        }
    }

    public var body: some View {
        ScrollViewReader { proxy in
            column
                .onAppear { reveal(proxy) }
                .onChange(of: focus.flatMap(model.item(holding:))) { _, _ in reveal(proxy) }
        }
    }

    /// Selects the item holding the event the page opened at and scrolls it to the middle, once: the history may come in
    /// after the page drew.
    private func reveal(_ proxy: ScrollViewProxy) {
        guard !focusShown, let target = focus.flatMap(model.item(holding:)) else { return }
        focusShown = true
        selection = target
        DispatchQueue.main.async {
            withAnimation(.motion(.standard, reduceMotion: reduceMotion)) { proxy.scrollTo(target, anchor: .center) }
        }
    }

    private var column: some View {
        let idle = model.runNow == nil ? idle : nil
        let moves = Self.moves(arriving: model.items.count(where: { !seen.contains($0.id) }), seen: seen.count)
        return VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            if model.isEmpty, let idle {
                TimelineIdleRow(line: idle)
            }
            if model.isEmpty {
                Text(TimelineModel.empty)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, DesignTokens.Space.s2)
            }
            ForEach(model.days) { day in
                DaySeparator(day: day)
                if let idle, day.id == model.days.first?.id {
                    TimelineIdleRow(line: idle)
                }
                ForEach(day.items) { item in
                    if let marker = model.marker, marker.before == item.id {
                        SinceLookedLine(text: TicketMarksRead.markerText(marker.lookedAt, clock: clock))
                    }
                    row(item)
                        .id(item.id)
                        .modifier(TimelineEntering(entering: moves && !seen.contains(item.id), reduceMotion: reduceMotion) {
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
        .environment(\.timelineReference, model.reference)
        // A history read whole (the first read of a long ticket's feed) is there at once, and marked seen in one change.
        .onChange(of: model.items.map(\.id)) { _, ids in
            let arriving = ids.count(where: { !seen.contains($0) })
            if arriving > 0, !Self.moves(arriving: arriving, seen: seen.count) { seen.formUnion(ids) }
        }
    }

    /// The most items that enter with the motion at once: more is a history read whole, not events coming in.
    static let enteringAtMost = 5

    /// Whether `arriving` items new to a timeline that has `seen` items drop in with the motion. Only a few events coming
    /// in onto a timeline that showed some do: the first history, or a long one read whole, is there at once. Each item
    /// that enters marks itself seen and starts two animations, so 500 events entering at once took the main thread for
    /// minutes (TP-1480's QA: a long ticket opened from Find a Ticket, its feed read after the page drew).
    static func moves(arriving: Int, seen: Int) -> Bool {
        seen > 0 && arriving <= enteringAtMost
    }

    public static let title = "Timeline"

    @ViewBuilder
    private func row(_ item: TimelineItem) -> some View {
        let selected = selection == item.id
        switch item {
        // Each row draws again only when what it shows changed: a new event draws its own row (TP-1480).
        case let .entry(entry):
            TimelineEntryRow(entry: entry, time: clock(entry.at), selected: selected) { select(item.id) }
                .equatable()
        case let .run(run, at):
            TimelineRunRow(run: run, time: clock(at), selected: selected, transcripts: transcripts, fold: fold(run)) {
                select(item.id)
            }
            .equatable()
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

/// Why no run works on the ticket, in the run now's place: the situation's glyph in its tint, "No run now", its word
/// and what it waits on, as tall as a folded run's line.
struct TimelineIdleRow: View {
    let line: TimelineIdleLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            Color.clear.frame(width: TimelineSection.timeColumn, height: 1)
            Image(systemName: line.kind.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(line.kind.tint)
                .frame(width: TimelineSection.markColumn)
            Text("\(Text(line.lead).fontWeight(.semibold)) · \(Text(line.word + (line.detail == nil ? "" : ":")).foregroundStyle(line.kind.tint))\(line.detail.map { " " + $0 } ?? "")")
                .font(DesignTokens.TypeStyle.body.font)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: DesignTokens.Measure.reading, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.vertical, DesignTokens.Space.s2)
        .frame(minHeight: Self.height, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.accessibilityLabel)
    }

    /// A folded run's line, so the page keeps its height when the run ends.
    static let height: CGFloat = 36
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
struct DaySeparator: View {
    let title: String
    var span: String?
    let label: String

    init(day: TimelineDay) {
        self.init(title: day.title, span: day.span, label: day.accessibilityLabel)
    }

    init(title: String, span: String? = nil, label: String) {
        self.title = title
        self.span = span
        self.label = label
    }

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.s2) {
            Text(title.uppercased())
                .font(DesignTokens.TypeStyle.caption.font.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .fixedSize()
            if let span {
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
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One entry: its time, its class's glyph in its tone, what happened in bold with the rest after it, its detail and
/// who did it, and a pause's duration at the end.
struct TimelineEntryRow: View {
    let entry: TimelineEntry
    let time: String
    let selected: Bool
    /// The ticket the entry is on, as a chip over what happened: the Journal's rows (TP-1459), where the row opens it.
    var ticket: TimelineTicketChip?
    let select: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.timelineReference) private var reference

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
                if let ticket {
                    TimelineTicketChipView(chip: ticket)
                }
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
            if let seconds = entry.durationSeconds {
                // An ongoing pause counts on by itself; the timeline isn't built again for it (TP-1479).
                LiveDurationText(seconds: seconds, reference: entry.isOngoing ? reference : nil) { seconds in
                    var entry = entry
                    entry.durationSeconds = seconds
                    return entry.duration ?? ""
                }
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
        .accessibilityLabel([ticket?.spoken, entry.accessibilityLabel(time: time)].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(ticket?.hint ?? "")
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

/// The ticket a Journal row is on (TP-1459): its identifier and title, in a chip over what happened.
public struct TimelineTicketChip: Equatable {
    public var identifier: String
    public var title: String?
    /// The row opens the ticket's page at the event; false on Symphony's own stream.
    public var opens: Bool

    public init(identifier: String, title: String? = nil, opens: Bool = true) {
        self.identifier = identifier
        self.title = title
        self.opens = opens
    }

    /// "TP-1401, The situation read model".
    var spoken: String { [identifier, title].compactMap { $0 }.joined(separator: ", ") }
    /// What the row does, for VoiceOver and under the pointer.
    var hint: String? { opens ? "Opens \(identifier) at this event" : nil }
}

/// The chip: the identifier in semibold and the title after it on one line, in a capsule.
struct TimelineTicketChipView: View {
    let chip: TimelineTicketChip

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s1) {
            Text(chip.identifier)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(chip.opens ? AnyShapeStyle(DesignTokens.SystemColor.accent.color) : AnyShapeStyle(.secondary))
                .fixedSize()
            if let title = chip.title {
                Text(title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(DesignTokens.TypeStyle.callout.font)
        .padding(.horizontal, DesignTokens.Space.s2)
        .padding(.vertical, 1)
        .background(DesignTokens.Surface.separator.color.opacity(0.5), in: Capsule())
        .help(chip.hint ?? "")
    }
}

/// A run on the timeline: its start in the column of times, then its Run group; selected, it takes the accent tint
/// and ring around the whole group.
struct TimelineRunRow: View {
    let run: RunGroupModel
    let time: String
    let selected: Bool
    @ObservedObject var transcripts: StepTranscripts
    let fold: Binding<Bool>
    /// Whether the run was unfolded when the row was made. The fold's getter reads the timeline's current state, so
    /// the old row and the new one would always agree on it; the gate compares this value instead (TP-1480).
    let unfolded: Bool
    let select: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    init(
        run: RunGroupModel, time: String, selected: Bool, transcripts: StepTranscripts, fold: Binding<Bool>,
        select: @escaping () -> Void
    ) {
        self.run = run
        self.time = time
        self.selected = selected
        self.transcripts = transcripts
        self.fold = fold
        unfolded = fold.wrappedValue
        self.select = select
    }

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
        // A click selects the run as its fold header takes the same click: both read the press as it ends, so neither
        // gesture waits on the other to fail (TP-1480's QA: a tap here took the click from the header's).
        .simultaneousGesture(
            DragGesture(minimumDistance: 0).onEnded { value in
                if FoldHeader<EmptyView>.isClick(value.translation) { select() }
            }
        )
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

/// A row draws again only when its entry, its time, its selection or its ticket changed; a new `select` for the same
/// row doesn't open the gate (TP-1480).
extension TimelineEntryRow: Equatable {
    nonisolated static func == (lhs: TimelineEntryRow, rhs: TimelineEntryRow) -> Bool {
        lhs.entry == rhs.entry && lhs.time == rhs.time && lhs.selected == rhs.selected && lhs.ticket == rhs.ticket
    }
}

/// A run's row draws again only when its run, its time, its selection or its fold changed; its transcripts draw it
/// again themselves.
extension TimelineRunRow: Equatable {
    nonisolated static func == (lhs: TimelineRunRow, rhs: TimelineRunRow) -> Bool {
        lhs.run == rhs.run && lhs.time == rhs.time && lhs.selected == rhs.selected
            && lhs.unfolded == rhs.unfolded && lhs.transcripts === rhs.transcripts
    }
}
