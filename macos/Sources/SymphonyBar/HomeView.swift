import SwiftUI
import SymphonyBarCore

/// What Home's rows and its pause notice do.
struct HomeActions {
    var resume: () -> Void = {}
    /// Try Now on the paused usage limit the notice names.
    var tryNow: (StateSnapshot.UsageLimit) -> Void = { _ in }
    /// The control request under way; Resume Dispatch is off until it is answered.
    var controlInFlight: ControlAction?
    /// A click on a row, or Return on the picked one, opens the ticket's page (D3).
    var openTicket: (String) -> Void = { _ in }
}

/// Home in a scroll view, laid out for the width it gets.
struct HomeView: View {
    let board: HomeBoard
    let actions: HomeActions
    /// What waits on the Director, above the board (TP-1454); nil until the Inbox is read.
    var inbox: HomeInbox?
    var inboxActions = HomeInboxActions()
    var now = Date()

    var body: some View {
        ScrollView {
            HomeBody(board: board, actions: actions, inbox: inbox, inboxActions: inboxActions, now: now)
        }
    }
}

/// Home's board (the catalog's Board group): what waits on the Director first, each item answerable in place
/// (TP-1454), the pause notice while dispatch is paused, then one group per situation
/// kind stacked top to bottom in the order the Director acts on them, each a card with its heading (glyph, title, the
/// count of its rows, a hint) and its rows in dispatch order. A group with nothing in it is one quiet heading. Outside
/// the scroll view, so it also renders offscreen.
struct HomeBody: View {
    let board: HomeBoard
    let actions: HomeActions
    /// The Inbox's items above the board; nil or empty draws none.
    var inbox: HomeInbox?
    var inboxActions = HomeInboxActions()
    /// Symphony's clock, for the items' ages.
    var now = Date()
    /// The row picked: it follows the keyboard's focus, and the arrow keys move it across groups.
    @State private var selection: String?
    /// The groups folded by a click on their heading.
    @State private var folded: Set<DesignTokens.SituationKind> = []
    @FocusState private var focus: String?
    /// Set by the first key pressed on the board: a group heading draws its focus ring only for keyboard focus, never
    /// for the focus the window hands it at launch.
    @State private var keyboardFocus = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `selection` is the row drawn picked at first, for a snapshot.
    init(
        board: HomeBoard, actions: HomeActions, inbox: HomeInbox? = nil, inboxActions: HomeInboxActions = HomeInboxActions(),
        now: Date = Date(), selection: String? = nil
    ) {
        self.board = board
        self.actions = actions
        self.inbox = inbox
        self.inboxActions = inboxActions
        self.now = now
        _selection = State(initialValue: selection)
    }

    @State private var narrow = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            if let inbox, !inbox.isEmpty {
                HomeInboxSection(inbox: inbox, actions: inboxActions, now: now, narrow: narrow)
                    .padding(.bottom, DesignTokens.Space.s3)
            }
            if let sentence = board.pauseSentence {
                PauseNotice(
                    sentence: sentence, lines: board.pauseLines, showsResume: board.showsResume,
                    tryNow: board.showsTryNow ? board.tryNow : nil, actions: actions
                )
                    .padding(.bottom, DesignTokens.Space.s2)
            }
            if !board.hasOrder {
                Text(HomeBoard.olderSymphony)
                    .font(DesignTokens.TypeStyle.body.font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(board.groups) { group in
                BoardGroup(
                    group: group,
                    folded: folded.contains(group.kind),
                    keyboardFocus: keyboardFocus,
                    reference: board.reference,
                    toggle: { toggle(group.kind) }
                ) { row in
                    BoardRow(row: row, reference: board.reference, selected: selection == row.identifier, focused: focus == row.identifier)
                        .focusable()
                        .focusEffectDisabled()
                        .focused($focus, equals: row.identifier)
                        .onTapGesture {
                            selection = row.identifier
                            actions.openTicket(row.identifier)
                        }
                        .onKeyPress(.return) {
                            actions.openTicket(row.identifier)
                            return .handled
                        }
                        .onKeyPress(.downArrow) { move(from: row.identifier, by: 1) }
                        .onKeyPress(.upArrow) { move(from: row.identifier, by: -1) }
                        .accessibilityAction { actions.openTicket(row.identifier) }
                        .accessibilityAction(named: "Open") { actions.openTicket(row.identifier) }
                }
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: Bool.self) { $0.size.width < DesignTokens.Layout.narrowReviewWidth } action: { narrow = $0 }
        .onKeyPress(phases: .down) { _ in
            keyboardFocus = true
            return .ignored
        }
        .onChange(of: focus) { _, id in
            if let id { selection = id }
        }
    }

    private func toggle(_ kind: DesignTokens.SituationKind) {
        withAnimation(reduceMotion ? nil : .standard) {
            if folded.contains(kind) { folded.remove(kind) } else { folded.insert(kind) }
        }
    }

    /// The arrow keys walk the rows of every unfolded group, top to bottom.
    private func move(from id: String, by offset: Int) -> KeyPress.Result {
        var shown = board
        shown.groups = shown.groups.filter { !folded.contains($0.kind) }
        guard let next = shown.row(from: id, offset: offset), next != id else { return .ignored }
        selection = next
        focus = next
        return .handled
    }
}

/// While dispatch is paused or a usage limit holds runs: the sentence, one line per reason, Try Now while a usage
/// limit is paused, and Resume Dispatch unless an update holds it.
private struct PauseNotice: View {
    let sentence: String
    let lines: [String]
    let showsResume: Bool
    let tryNow: StateSnapshot.UsageLimit?
    let actions: HomeActions

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.s3) {
            Image(systemName: DesignTokens.Status.idle.symbol)
                .font(.title2)
                .foregroundStyle(DesignTokens.Status.idle.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                Text(sentence)
                    .font(DesignTokens.TypeStyle.sentence.font)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(DesignTokens.TypeStyle.body.font)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DesignTokens.Space.s4)
            if let tryNow {
                Button(StatusMenu.tryNowTitle) { actions.tryNow(tryNow) }
                    .directorButton(showsResume ? .secondary : .primary)
                    .help(StatusMenu.tryNowHelp)
                    .accessibilityHint(StatusMenu.tryNowHelp)
                    .disabled(actions.controlInFlight != nil)
            }
            if showsResume {
                Button(Overview.resumeTitle, action: actions.resume)
                    .directorButton(.primary)
                    .disabled(actions.controlInFlight != nil)
            }
        }
    }
}

/// A situation group: its heading, then its rows on the content surface. Empty, it is one quiet heading on the window
/// with a hairline and no rows.
private struct BoardGroup<Row: View>: View {
    let group: HomeBoard.Group
    let folded: Bool
    let keyboardFocus: Bool
    let reference: Date
    let toggle: () -> Void
    @ViewBuilder let row: (HomeBoard.Row) -> Row
    @FocusState private var headingFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if group.isEmpty {
                heading.padding(.horizontal, DesignTokens.Space.s4).frame(minHeight: 38)
            } else {
                Button(action: toggle) {
                    heading
                        .padding(.horizontal, DesignTokens.Space.s4)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(GroupHeadingStyle())
                .focusEffectDisabled()
                .focused($headingFocused)
                .accessibilityLabel(group.accessibilityLabel)
                .accessibilityValue(folded ? "Folded" : "Open")
                .accessibilityHint(folded ? "Shows its tickets" : "Hides its tickets")
                if !folded {
                    VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                        ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, item in
                            row(item)
                                .transition(.opacity.animation(reduceMotion ? nil : .standard.delay(Double(index) * 0.035)))
                        }
                    }
                    .padding(.horizontal, DesignTokens.Space.s2)
                    .padding(.bottom, DesignTokens.Space.s2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(shape)
        // A group with rows is a panel; an empty one keeps its hairline on the window.
        .background {
            if !group.isEmpty { Color.clear.panelSurface(in: shape) }
        }
        .overlay {
            if group.isEmpty { shape.strokeBorder(DesignTokens.Surface.separator.color) }
        }
        // The heading spans the card's top edge, so its keyboard focus rings the card, outside its rounded corners.
        .focusRing(headingFocused && keyboardFocus, shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.accessibilityLabel)
    }

    private var heading: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.s2) {
            if !group.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(folded ? 0 : 90))
                    .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.1), value: folded)
                    .accessibilityHidden(true)
            }
            Image(systemName: group.kind.symbol)
                .foregroundStyle(group.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(group.kind.tint))
                .accessibilityHidden(true)
            Text(group.title)
                .font(DesignTokens.TypeStyle.rowTitle.font)
                .foregroundStyle(group.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            if !group.isEmpty { CountPill(count: group.count, kind: group.kind) }
            Spacer(minLength: DesignTokens.Space.s3)
            if let hint = group.isEmpty ? HomeBoard.emptyHint : group.hint {
                Text(hint)
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }
}

/// The heading's hover and pressed surfaces, across the card's full width.
private struct GroupHeadingStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovered = false

        var body: some View {
            let state = DesignTokens.Interaction(hovered: hovered, pressed: configuration.isPressed)
            configuration.label
                .background { state.surface.map { Rectangle().fill($0.fill) } }
                .onHover { hovered = $0 }
        }
    }
}

/// The count of a group's rows: tinted for Waiting on you and Retrying, quiet for the others.
private struct CountPill: View {
    let count: Int
    let kind: DesignTokens.SituationKind

    private var tinted: Bool { kind == .you || kind == .retrying }

    var body: some View {
        Text(count, format: .number)
            .font(DesignTokens.TypeStyle.label.font)
            .monospacedDigit()
            .foregroundStyle(tinted ? AnyShapeStyle(kind.tint) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(
                tinted ? AnyShapeStyle(kind.status.badgeFill) : AnyShapeStyle(.quaternary),
                in: Capsule()
            )
            .accessibilityHidden(true)
    }
}

/// A ticket's row, in two lines (the catalog's laptop row): the ticket, then where it stands with its age trailing;
/// for a candidate, why it is or is not next under it. It draws the shared row's hover, pressed, selected and focus
/// states.
private struct BoardRow: View {
    let row: HomeBoard.Row
    let reference: Date
    let selected: Bool
    let focused: Bool
    @State private var hovered = false
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1 / 2) {
            TicketTitle(identifier: row.identifier, title: row.title, repoKey: row.repoKey)
            SituationLine(row.situation, reference: reference, size: .compact, forced: row.forced)
            if let reason = row.reason {
                Label {
                    Text(reason)
                } icon: {
                    Image(systemName: "arrow.turn.down.right")
                }
                .labelStyle(.titleAndIcon)
                .font(DesignTokens.TypeStyle.secondary.font)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
        }
        .padding(.vertical, DesignTokens.Space.s2)
        .padding(.horizontal, DesignTokens.Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(RowFace(
            state: DesignTokens.Interaction(hovered: hovered, pressed: pressed, selected: selected, focused: focused),
            reduceMotion: reduceMotion,
            bleed: EdgeInsets()
        ))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel(reference: reference))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .help("Open \(row.identifier)")
    }
}

/// A ticket is always its identifier and its title together, with its repo after them.
private struct TicketTitle: View {
    let identifier: String
    let title: String?
    let repoKey: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            Text(identifier).font(DesignTokens.TypeStyle.rowTitle.font)
            if let title {
                Text(title).font(DesignTokens.TypeStyle.body.font).lineLimit(1)
            }
            if let repoKey {
                Text(repoKey)
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Shared rows

extension View {
    /// A ticket row: a double-click, or Return once it has focus, opens the ticket's page (D3, P10). It carries the
    /// shared row's states (hover, pressed, the focus ring). VoiceOver reads the row as one element, its label and its
    /// own actions combined, with Open as its default and a named action. Nothing changes for a row that is not about
    /// a ticket.
    @ViewBuilder func opensTicket(_ identifier: String?, open: @escaping (String) -> Void) -> some View {
        if let identifier {
            contentShape(Rectangle())
                .onTapGesture(count: 2) { open(identifier) }
                .rowStyle()
                .onKeyPress(.return) {
                    open(identifier)
                    return .handled
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { open(identifier) }
                .accessibilityAction(named: "Open") { open(identifier) }
        } else {
            self
        }
    }
}

// MARK: - C11: meters

struct MeterView: View {
    let meter: Overview.Meter

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.label).font(DesignTokens.TypeStyle.body.font)
                Spacer(minLength: DesignTokens.Space.s2)
                Text(meter.value)
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            if let fraction = meter.fraction {
                MeterBar(fraction: fraction, tint: tint)
            }
            if let note = meter.note {
                Text(note)
                    .font(DesignTokens.TypeStyle.caption.font)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meter.accessibilityLabel + (meter.note.map { ", \($0)" } ?? ""))
    }

    private var tint: Color {
        switch meter.level {
        case .normal: DesignTokens.ColorToken.accent.color
        case .near: DesignTokens.Status.you.tint
        case .atLimit: DesignTokens.Status.problem.tint
        }
    }
}

/// A meter's bar: the fill carries the level, on a track that is a light step of the same hue (design system §3.3).
/// Drawn rather than a `Gauge`, whose AppKit control doesn't render offscreen.
struct MeterBar: View {
    let fraction: Double
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.2))
                Capsule()
                    .fill(tint)
                    .frame(width: max(proxy.size.width * fraction, fraction > 0 ? proxy.size.height : 0))
            }
        }
        .frame(height: 6)
        .animation(reduceMotion ? nil : .standard, value: fraction)
        .accessibilityHidden(true)
    }
}
