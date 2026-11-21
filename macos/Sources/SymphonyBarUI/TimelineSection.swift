import AppKit
import SwiftUI
import SymphonyBarCore

// The catalog's Timeline section and Timeline entry (`docs/design/director-ticket-page.md` §1 facts 12 and 32, §4):
// a ticket's history newest first in one column of at most 780 pt, a separator on each day with its date and how long
// the day's history ran, each entry with its time, its class's glyph, what happened and who did it, and each run as
// its Run group with the run now on top, unfolded. A row is selected with the arrow keys (the accent tint and ring),
// Return and Space fold the selected run, and Escape clears the selection. A click leaves no selection (TP-1572): it
// gives the timeline the keyboard and clears what the arrows selected, and a click on a run's line folds it. A new event drops in from 12 pt
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
    /// Every entry the history holds; `model` is what shows.
    let allModel: TimelineModel
    /// The entries that restate the runs around them show (the toggle at the timeline's head); off by default, for
    /// this ticket's page only.
    @State private var showAllEvents: Bool
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
    @Environment(\.timelineGrowth) private var growth
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    /// The Journal's column at its widest (the catalog's Timeline: one column of at most 780 pt). On the ticket page the
    /// timeline fills its column instead (`.ticket-page .timeline-layout`, TP-1485), so its right edge lines up with the
    /// Lifecycle card's.
    public static let maxWidth: CGFloat = 780
    /// The column of times, and the column of marks after it (the catalog's `.tl-entry`: 48 px, then 26 px).
    static let timeColumn: CGFloat = 48
    static let markColumn: CGFloat = 26

    /// `selection` and `unfoldedRuns` say what is selected and which runs are open to start with; nil opens what
    /// opens by default. The times are `calendar`'s. `idle` is the line shown in the run now's place when no run works.
    public init(
        model: TimelineModel, idle: TimelineIdleLine? = nil, transcripts: StepTranscripts, calendar: Calendar = .current,
        selection: String? = nil, unfoldedRuns: Set<String>? = nil, focus: TimelineFocus? = nil, showAllEvents: Bool = false
    ) {
        allModel = model
        _showAllEvents = State(initialValue: showAllEvents)
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

    /// The timeline as it shows: without the mechanical entries until the person shows all events.
    private var model: TimelineModel { allModel.showing(allEvents: showAllEvents) }

    public var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                if allModel.mechanicalCount > 0 {
                    ShowAllEventsToggle(on: $showAllEvents)
                }
                column(proxy)
                    .onAppear { reveal(proxy) }
                    .onChange(of: focus.flatMap(model.item(holding:))) { _, _ in reveal(proxy) }
            }
        }
    }

    /// Selects the item holding the event the page opened at and scrolls it to the middle, once: the history may come in
    /// after the page drew. The row may not be made yet: the scroll makes it.
    private func reveal(_ proxy: ScrollViewProxy) {
        guard !focusShown, let target = focus.flatMap(model.item(holding:)) else { return }
        focusShown = true
        selection = target
        DispatchQueue.main.async {
            withAnimation(.motion(.standard, reduceMotion: reduceMotion)) { TimelineScrolls.scroll(proxy, to: target, anchor: .center) }
        }
    }

    /// One line of the timeline, in the one list the lazy stack makes rows from (TP-1481): a day's separator, the idle
    /// line, the line where the person last looked, or an item. An item's line has the item's id, so a scroll to an item
    /// finds its row before it is made.
    enum Line: Identifiable, Equatable {
        case day(TimelineDay)
        case idle(TimelineIdleLine)
        case marker(before: String, text: String)
        case item(TimelineItem)

        var id: String {
            switch self {
            case let .day(day): "day-\(day.id)"
            case .idle: "idle"
            case let .marker(before, _): "marker-\(before)"
            case let .item(item): item.id
            }
        }
    }

    /// The timeline's lines top to bottom: each day's separator then its items, the idle line under the first day's
    /// separator (or alone over the empty timeline's words), the marker over the newest item the person saw.
    static func lines(_ model: TimelineModel, idle: TimelineIdleLine?, clock: (Date) -> String) -> [Line] {
        var lines: [Line] = []
        if model.isEmpty, let idle { lines.append(.idle(idle)) }
        for (index, day) in model.days.enumerated() {
            lines.append(.day(day))
            if index == 0, let idle { lines.append(.idle(idle)) }
            for item in day.items {
                if let marker = model.marker, marker.before == item.id {
                    lines.append(.marker(before: item.id, text: TicketMarksRead.markerText(marker.lookedAt, clock: clock)))
                }
                lines.append(.item(item))
            }
        }
        return lines
    }

    /// The entries joined to the line under them by the rule line (the catalog's `.timeline .tl-entry::before`): an
    /// entry whose next line is an entry of the same day. A run, a day's separator or the marker breaks the line.
    static func connected(_ lines: [Line]) -> Set<String> {
        var ids = Set<String>()
        for (line, next) in zip(lines, lines.dropFirst()) {
            if case let .item(.entry(entry)) = line, case .item(.entry) = next { ids.insert(TimelineItem.entry(entry).id) }
        }
        return ids
    }

    /// The timeline in a lazy stack: only the lines near the scroll view's visible part are made, and a folded run makes
    /// no step rows, so a 500-event history costs about what a short one does to open and to scroll (TP-1481). The lines
    /// are one flat list so each item's row is the stack's own child, found by `scrollTo` before it is made.
    private func column(_ proxy: ScrollViewProxy) -> some View {
        let model = model
        let idle = model.runNow == nil ? idle : nil
        let moves = Self.moves(arriving: model.items.count(where: { !seen.contains($0.id) }), seen: seen.count)
        let lines = Self.lines(model, idle: idle, clock: clock)
        let connected = Self.connected(lines)
        return TimelineStack(lazy: !offscreenSnapshot) {
            ForEach(lines) { line in
                switch line {
                case let .day(day):
                    DaySeparator(day: day)
                case let .idle(idle):
                    TimelineIdleRow(line: idle)
                case let .marker(_, text):
                    SinceLookedLine(text: text)
                case let .item(item):
                    row(item, connects: connected.contains(item.id))
                        .modifier(TimelineEntering(entering: moves && !seen.contains(item.id), reduceMotion: reduceMotion) {
                            seen.insert(item.id)
                        })
                }
            }
            if model.isEmpty {
                Text(TimelineModel.empty)
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, DesignTokens.Space.s2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: TimelineKeys.keys, phases: .down) { press in
            guard let action = TimelineKeys.action(press.key, modifiers: press.modifiers) else { return .ignored }
            return handle(action, proxy: proxy)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.title)
        .environment(\.timelineReference, model.reference)
        // A history read whole (the first read of a long ticket's feed) is there at once, and marked seen in one change.
        .onChange(of: model.items.map(\.id)) { _, ids in
            let arriving = ids.count(where: { !seen.contains($0) })
            if arriving > 0, !Self.moves(arriving: arriving, seen: seen.count) { seen.formUnion(ids) }
        }
        // A new event or the run now's newest lines grow the timeline at its top: the page's scroll view keeps what the
        // person reads where it is when that top is above what it shows (TP-1481).
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: { top in
            growth?.top = top
        }
        .onChange(of: model.items.first) { _, _ in growth?.grew() }
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

    private func row(_ item: TimelineItem, connects: Bool) -> TimelineRow {
        Self.makeRow(
            item, selection: selection, connects: connects, clock: clock, transcripts: transcripts, fold: { fold($0) },
            // The live selection, read when the click lands: an equatable row keeps the closure it was first drawn with.
            click: TimelineClick(takeKeyboard: { focused = true }) { next in
                guard selection != next else { return }
                withAnimation(.motion(.standard, reduceMotion: reduceMotion)) { selection = next }
            }
        )
    }

    /// The row `item` draws as, and what a click on it does: `click`, which never selects the row (TP-1572).
    static func makeRow(
        _ item: TimelineItem, selection: String?, connects: Bool, clock: (Date) -> String, transcripts: StepTranscripts,
        fold: (RunGroupModel) -> Binding<Bool>, click: TimelineClick
    ) -> TimelineRow {
        let selected = selection == item.id
        switch item {
        case let .entry(entry):
            return .entry(TimelineEntryRow(entry: entry, time: clock(entry.at), selected: selected, connects: connects, select: click.perform))
        case let .run(run, at):
            return .run(TimelineRunRow(
                run: run, time: clock(at), selected: selected, transcripts: transcripts, fold: fold(run), select: click.perform
            ))
        }
    }

    private func handle(_ action: TimelineKeys.Action, proxy: ScrollViewProxy) -> KeyPress.Result {
        switch action {
        case let .move(steps):
            guard !model.isEmpty else { return .ignored }
            let next = model.moving(selection, by: steps)
            // The page follows the selection: the row comes into view, made first when it wasn't yet (TP-1481).
            withAnimation(.motion(.standard, reduceMotion: reduceMotion)) {
                selection = next
                if let next { TimelineScrolls.scroll(proxy, to: next) }
            }
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

/// The timeline's column: a lazy stack in the window; an eager one offscreen, where `ImageRenderer` has no scroll view
/// to say what shows and a snapshot draws the whole column.
private struct TimelineStack<Content: View>: View {
    let lazy: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: DesignTokens.Space.s1, content: content)
        } else {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1, content: content)
        }
    }
}

/// What the page's scroll view needs to keep its place when the timeline grows above what it shows (TP-1481): a new
/// event, or the run now's newest lines, adds height at the timeline's top, and a page scrolled past that top would
/// see everything it shows slide down. The timeline says where its top is and when it grew; the scroll view, when its
/// content's height changes right after, scrolls by the change. Nothing here is published: it draws nothing.
@MainActor
public final class TimelineGrowth {
    /// Where the timeline's top is in the scroll view: negative once the page scrolled past it.
    var top: CGFloat = 0
    /// When the timeline last grew while its top was above what the scroll view shows.
    private var grewAt: Date?

    /// How soon after the timeline grew the content's height change is its own; a later one is something else (a
    /// row made as the page scrolls, a run unfolded).
    static let window: TimeInterval = 0.5

    public init() {}

    /// The timeline's top item changed: a new event, or the run now read again.
    func grew(now: Date = Date()) {
        grewAt = top < 0 ? now : nil
    }

    /// How far the scroll view scrolls for its content's height change of `delta`: all of it right after the timeline
    /// grew above what it shows, else nothing. A growth is answered once.
    public func compensation(for delta: CGFloat, now: Date = Date()) -> CGFloat {
        guard let grewAt, delta != 0 else { return 0 }
        self.grewAt = nil
        return now.timeIntervalSince(grewAt) <= Self.window ? delta : 0
    }
}

public extension EnvironmentValues {
    /// The page's scroll view's `TimelineGrowth`; nil outside the window's page (a snapshot).
    @Entry var timelineGrowth: TimelineGrowth?
}

/// The Timeline section's zone title, with the count of events new since the person last looked ("3 new") as its note.
public struct TimelineTitle: View {
    let marks: TicketMarksRead?

    public init(marks: TicketMarksRead?) {
        self.marks = marks
    }

    public var body: some View {
        ZoneTitle(
            TimelineSection.title, note: marks?.newText, noteColor: .accentText, noteHelp: TimelineEntry.newHelp,
            noteAccessibilityLabel: marks?.newAccessibilityLabel
        )
    }
}

/// The toggle at the timeline's head: "Show all events" brings the entries that restate the runs around them (a phase
/// entered, a workspace synced, an attempt pushed, the branch updated, a short pause); on, it is selected. Drawn only
/// when the timeline holds such entries.
struct ShowAllEventsToggle: View {
    @Binding var on: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button(TimelineModel.showAllEvents) {
                withAnimation(.motion(.standard, reduceMotion: reduceMotion)) { on.toggle() }
            }
            .directorButton(.quiet, size: .small, glyph: on ? "checkmark" : nil, selected: on)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(on ? "On" : "Off")
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
                .foregroundStyle(DesignTokens.ColorToken.accent.color)
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
            .fill(DesignTokens.ColorToken.accent.color.opacity(0.4))
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
            HairlineDivider()
        }
        .padding(.top, DesignTokens.Space.s4)
        .padding(.bottom, DesignTokens.Space.s1)
        .padding(.leading, TimelineSection.timeColumn + DesignTokens.Space.s2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One entry (the catalog's `.tl-entry`): its time, its class's glyph in its tinted round mark joined to the next
/// entry by the rule line, what happened in bold with the rest after it, its detail, the finding card when QA found
/// something, who did it, and a pause's duration at the end. A send-back to Rework is highlighted in the problem tint.
struct TimelineEntryRow: View {
    let entry: TimelineEntry
    let time: String
    let selected: Bool
    /// The ticket the entry is on, as a chip over what happened: the Journal's rows (TP-1459), where the row opens it.
    var ticket: TimelineTicketChip?
    /// The rule line runs from its mark down to the next entry's.
    var connects = false
    /// A click acts on the row (the Journal's rows open their ticket), so the pointer turns into the hand over it. A
    /// ticket page's entry does nothing on a click and keeps the arrow (TP-1572).
    var opens = false
    let select: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.timelineReference) private var reference

    init(
        entry: TimelineEntry, time: String, selected: Bool, ticket: TimelineTicketChip? = nil, connects: Bool = false,
        opens: Bool = false, select: @escaping () -> Void
    ) {
        self.entry = entry
        self.time = time
        self.selected = selected
        self.ticket = ticket
        self.connects = connects
        self.opens = opens
        self.select = select
    }

    var body: some View {
        let _ = TimelineRowBodies.evaluated("entry-\(entry.id)")
        HStack(alignment: .top, spacing: DesignTokens.Space.s2) {
            Text(time)
                .font(DesignTokens.TypeStyle.secondary.font)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: TimelineSection.timeColumn, alignment: .trailing)
                .padding(.top, Self.textTop)
            Group {
                if entry.conductor != nil {
                    ConductorMark(size: .regular)
                } else {
                    TimelineMark(symbol: entry.kind.symbol, tone: entry.kind.tone)
                }
            }
            .frame(width: TimelineSection.markColumn)
            .help(entry.conductor != nil ? ConductorMessage.name : Self.glyphHelp(entry.kind))
            VStack(alignment: .leading, spacing: 2) {
                if let ticket {
                    TimelineTicketChipView(chip: ticket)
                }
                if let message = entry.conductor {
                    ConductorVoice(message: message, isNew: entry.isNew)
                } else {
                    Text("\(newDot)\(Text(entry.lead).fontWeight(.semibold))\(entry.rest.map { " " + $0 } ?? "")")
                        .font(DesignTokens.TypeStyle.body.font)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(entry.isNew ? TimelineEntry.newHelp : "")
                    if let detail = entry.detail {
                        Text(detail)
                            .font(DesignTokens.TypeStyle.secondary.font)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let reply = entry.reply {
                        ConductorReply(message: reply)
                    }
                    if let finding = entry.finding {
                        TimelineFindingCard(finding: finding)
                            .padding(.vertical, DesignTokens.Space.s1)
                    }
                    Text(entry.actor)
                        .font(DesignTokens.TypeStyle.secondary.font)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, Self.textTop)
            .frame(maxWidth: entry.conductor != nil ? ConductorVoice.measure : DesignTokens.Measure.reading, alignment: .leading)
            Spacer(minLength: DesignTokens.Space.s2)
            if let seconds = entry.durationSeconds {
                // An ongoing pause counts on by itself; the timeline isn't built again for it (TP-1479).
                LiveDurationText(seconds: seconds, reference: entry.isOngoing ? reference : nil) { seconds in
                    var entry = entry
                    entry.durationSeconds = seconds
                    return entry.duration ?? ""
                }
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .padding(.top, Self.textTop)
                    .help(Self.durationHelp)
            }
        }
        .padding(.vertical, DesignTokens.Space.s1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            if connects {
                TimelineRuleLine()
                    .padding(.leading, Self.ruleLeading)
                    .padding(.top, entry.conductor != nil ? Self.conductorRuleTop : Self.ruleTop)
                    // Through the gap to the next entry's mark.
                    .padding(.bottom, Self.ruleBottom)
            }
        }
        .background {
            if entry.isHighlighted {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                    .fill(DesignTokens.Status.problem.badgeFill.opacity(Self.highlightOpacity))
                    .padding(Self.highlightInsets)
            }
        }
        .modifier(RowFace(state: DesignTokens.Interaction(hovered: hovered, selected: selected), reduceMotion: reduceMotion))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: select)
        .buttonPointer(enabled: opens)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityHint(ticket?.hint ?? "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
    }

    static let durationHelp = "How long the pause lasted"

    /// What VoiceOver reads: the ticket's chip, the entry, and its finding.
    private var spokenLabel: String {
        // The Conductor's message is one element that starts with its name and reads its words.
        let said = entry.conductor?.accessibilityLabel(time: time).appending(entry.isNew ? ", " + TimelineEntry.newWords : "")
        let parts: [String?] = [ticket?.spoken, said ?? entry.accessibilityLabel(time: time), entry.finding?.accessibilityLabel]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }

    /// The rule line's place: under the mark's middle, from the mark's bottom through the gap to the next entry.
    static let ruleLeading: CGFloat = {
        let markMiddle: CGFloat = TimelineSection.markColumn / 2
        let lineMiddle: CGFloat = TimelineRuleLine.width / 2
        let markStart: CGFloat = TimelineSection.timeColumn + DesignTokens.Space.s2
        return markStart + markMiddle - lineMiddle
    }()
    static let ruleTop: CGFloat = DesignTokens.Space.s1 + TimelineMark.size
    /// The Conductor's mark is a little taller than the others, so its rule line starts lower.
    static let conductorRuleTop: CGFloat = DesignTokens.Space.s1 + ConductorMark.Size.regular.side
    static let ruleBottom: CGFloat = -2 * DesignTokens.Space.s1
    /// The send-back's tint reaches a little past the row.
    static let highlightInsets = EdgeInsets(
        top: -DesignTokens.Space.s1, leading: -DesignTokens.Space.s2, bottom: -DesignTokens.Space.s1, trailing: -DesignTokens.Space.s2
    )
    /// How far the time and the words sit below the mark's top, so their first line meets the mark's middle.
    static let textTop: CGFloat = 4
    /// The send-back's tint behind the row (the problem tint, a little lighter than a badge's).
    static let highlightOpacity = 0.7

    /// The small accent dot before what happened, on an entry newer than the person's last look.
    private var newDot: Text {
        guard entry.isNew else { return Text(verbatim: "") }
        return Text(Image(systemName: "circle.fill"))
            .font(.system(size: 6))
            .baselineOffset(2.5)
            .foregroundStyle(DesignTokens.ColorToken.accent.color) + Text(verbatim: "  ")
    }

    /// What the glyph means, under the pointer: "Phase move".
    static func glyphHelp(_ kind: TimelineEntry.Kind) -> String {
        kind.word.prefix(1).uppercased() + kind.word.dropFirst()
    }

    static func color(_ tone: TimelineEntry.Tone) -> Color {
        switch tone {
        case .accent: DesignTokens.ColorToken.accent.color
        case let .status(status): status.tint
        }
    }

    /// The mark's fill: the tone's tint (`--role-tint`).
    static func fill(_ tone: TimelineEntry.Tone) -> Color {
        switch tone {
        case .accent: DesignTokens.ColorToken.accentTint.color
        case let .status(status): status.badgeFill
        }
    }
}

public extension EnvironmentValues {
    /// The page's screenshots, read through the window's API client; nil where none is given (the thumbnail holds its
    /// place).
    @Entry var artifactImages: ArtifactImages?
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
                .foregroundStyle(chip.opens ? AnyShapeStyle(DesignTokens.ColorToken.accent.color) : AnyShapeStyle(.secondary))
                .fixedSize()
            if let title = chip.title {
                Text(title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(DesignTokens.TypeStyle.secondary.font)
        .padding(.horizontal, DesignTokens.Space.s2)
        .padding(.vertical, 1)
        .background(DesignTokens.Surface.separator.color.opacity(0.5), in: Capsule())
        .help(chip.hint ?? "")
    }
}

/// What a click on a timeline row does (TP-1572): the timeline takes the keyboard, so the arrows move from there, and a
/// selection the arrows left is cleared. It never selects the row: the accent tint and ring are the arrow keys' alone,
/// so a click leaves no outline to dismiss with Escape. A click on a run's line folds it through the run's own header.
struct TimelineClick {
    let takeKeyboard: () -> Void
    let select: (String?) -> Void

    func perform() {
        takeKeyboard()
        select(nil)
    }
}

/// A timeline row, an entry or a run, each drawing again only when what it shows changed (TP-1480).
enum TimelineRow: View {
    case entry(TimelineEntryRow)
    case run(TimelineRunRow)

    /// What a click on the row does.
    var click: () -> Void {
        switch self {
        case let .entry(row): row.select
        case let .run(row): row.select
        }
    }

    var body: some View {
        switch self {
        case let .entry(row): row.equatable()
        case let .run(row): row.equatable()
        }
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
        let _ = TimelineRowBodies.evaluated("run-\(run.id)")
        HStack(alignment: .top, spacing: 0) {
            Text(time)
                .font(DesignTokens.TypeStyle.secondary.font)
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
                    .fill(DesignTokens.StateSurface.selected.fill)
            }
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                    .strokeBorder(DesignTokens.Selection.color.color, lineWidth: DesignTokens.Selection.rowRingWidth)
            }
        }
        .contentShape(Rectangle())
        // A click gives the timeline the keyboard as the run's fold header takes the same click: both read the press as it
        // ends, so neither gesture waits on the other to fail (TP-1480's QA: a tap here took the click from the header's).
        .simultaneousGesture(
            DragGesture(minimumDistance: 0).onEnded { value in
                if CollapsibleHead<EmptyView>.isClick(value.translation) { select() }
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

/// The timeline rows whose bodies SwiftUI evaluated, while a test records them: the test that holds a long timeline to
/// the rows near the screen (TP-1481). Off (nil) in the app, where it costs one check per row drawn.
@MainActor
enum TimelineRowBodies {
    static var recorded: [String]?

    static func evaluated(_ id: String) {
        recorded?.append(id)
    }
}

/// The timeline's scrolls to an item: the jump to the event the page opened at, and the page following the arrow keys'
/// selection. A test records the ids asked for (TP-1481), since a scroll view hosted without a window never scrolls.
/// Off (nil) in the app.
@MainActor
enum TimelineScrolls {
    static var recorded: [String]?

    static func scroll(_ proxy: ScrollViewProxy, to id: String, anchor: UnitPoint? = nil) {
        recorded?.append(id)
        proxy.scrollTo(id, anchor: anchor)
    }
}

/// A new entry dropping in from above on a spring while its accent tint fades; under Reduce Motion it is there at once.
private struct TimelineEntering: ViewModifier {
    let entering: Bool
    let reduceMotion: Bool
    let entered: () -> Void
    @State private var settled: Bool
    @State private var tint: Double

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
                    .fill(DesignTokens.Motion.enterTint.color.opacity(tint))
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
        guard lhs.entry == rhs.entry, lhs.time == rhs.time, lhs.selected == rhs.selected else { return false }
        return lhs.ticket == rhs.ticket && lhs.connects == rhs.connects && lhs.opens == rhs.opens
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
