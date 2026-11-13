import SwiftUI
import SymphonyBarCore

// The catalog's Row, its tree and its progress strip (TP-1507) as shared components: every list of the Director draws
// its rows with `Row`, a list of tickets that wait on each other with `TreeList`, and an epic's progress with
// `ProgressStrip`. They draw only from `DesignTokens` (`Row`, `Tree`, `ProgressStrip`), so the design guard reads this
// file like any page's and finds nothing.

// MARK: - Row

/// What a row starts with, in its 18 pt square: a status glyph in its colour, the live status dot of a ticket being
/// worked on, any glyph in a colour, the empty square (so a row without a mark lines up with its neighbours), or
/// nothing.
public enum RowLead: Equatable {
    case none
    case blank
    case status(DesignTokens.Status)
    case dot(DesignTokens.Status, live: Bool)
    case glyph(String, DesignTokens.ColorToken)
}

extension EnvironmentValues {
    /// True inside a row selected in the front window: what it holds draws white on the accent.
    @Entry public var rowOnAccent = false
}

/// A value in a row's trail, such as an age or a count: secondary, with tabular figures, white on a selected row.
public struct RowValue: View {
    let text: String
    @Environment(\.rowOnAccent) private var onAccent

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .textStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Row<EmptyView>.secondaryColor(onAccent: onAccent))
    }
}

/// C49, the catalog's Row (`.row`): one item of a list on one line (34 pt), or two (52 pt) with `line2`. A lead, the
/// identifier, the title cut with an ellipsis, then a trail laid out right to left whose last item, `value`, sits in a
/// column at least `valueWidth` wide so a list's values align. It shows hover, pressed (settling to 99.5 %), selected
/// (the accent fill with white words; the pressed grey with the words in their colours when the window is not in
/// front) and the keyboard focus ring. A click calls `select`, a double click or Return `open`; with either, the row
/// takes keyboard focus unless its list owns it (`focused`). VoiceOver reads it as one element. `state` draws one
/// state still, for a snapshot.
public struct Row<Trail: View>: View {
    let title: String
    let identifier: String?
    let lead: RowLead
    let line2: String?
    let value: String?
    let valueWidth: Double
    let selected: Bool
    let listFocused: Bool?
    let state: DesignTokens.Interaction?
    let windowActive: Bool?
    let select: (() -> Void)?
    let open: (() -> Void)?
    let trail: Trail

    @State private var hovered = false
    @State private var pressed = false
    @FocusState private var focused: Bool
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    public init(
        _ title: String, identifier: String? = nil, lead: RowLead = .none, line2: String? = nil, value: String? = nil,
        valueWidth: Double = DesignTokens.Row.valueWidth, selected: Bool = false, focused: Bool? = nil,
        state: DesignTokens.Interaction? = nil, windowActive: Bool? = nil,
        select: (() -> Void)? = nil, open: (() -> Void)? = nil, @ViewBuilder trail: () -> Trail
    ) {
        self.title = title
        self.identifier = identifier
        self.lead = lead
        self.line2 = line2
        self.value = value
        self.valueWidth = valueWidth
        self.selected = selected
        listFocused = focused
        self.state = state
        self.windowActive = windowActive
        self.select = select
        self.open = open
        self.trail = trail()
    }

    /// Whether it draws two lines.
    public var twoLines: Bool { line2 != nil }

    /// The state it draws: the one given, or the pointer's, the press's, the selection's and the focus's.
    var shown: DesignTokens.Interaction {
        state ?? DesignTokens.Interaction(
            hovered: acts && hovered, pressed: acts && pressed, selected: selected, focused: listFocused ?? focused,
            disabled: !isEnabled
        )
    }

    /// Whether a click, a double click or Return does anything: a row that does nothing shows no hover or press.
    var acts: Bool { select != nil || open != nil }

    public var body: some View {
        let state = shown
        let active = windowActive ?? appearsActive
        let onAccent = DesignTokens.Row.onAccent(state, windowActive: active)
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
        content(onAccent: onAccent)
            .padding(.horizontal, DesignTokens.Row.sideInset)
            .padding(.vertical, DesignTokens.Row.inset)
            .frame(maxWidth: .infinity, minHeight: DesignTokens.Row.height(twoLines: twoLines), alignment: .leading)
            .background {
                if let fill = DesignTokens.Row.fill(state, windowActive: active) { shape.fill(fill.color) }
            }
            .focusRing(state.showsFocusRing, shape, offset: 0)
            .environment(\.rowOnAccent, onAccent)
            .environment(\.backgroundProminence, onAccent ? .increased : .standard)
            .scaleEffect(DesignTokens.Motion.scale(DesignTokens.Motion.rowPressScale, pressed: state.pressed, reduceMotion: reduceMotion))
            .animation(.motion(.fast, reduceMotion: reduceMotion), value: state)
            .contentShape(shape)
            .onHover { hovered = $0 }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressed = true }
                    .onEnded { _ in pressed = false }
            )
            .focusable(acts && listFocused == nil)
            .focusEffectDisabled()
            .focused($focused)
            // After focus, so Return reaches it from the focused row: key presses go up from the focused view.
            .modifier(RowActions(select: select, open: open))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(state.selected ? .isSelected : [])
    }

    private func content(onAccent: Bool) -> some View {
        HStack(alignment: .center, spacing: DesignTokens.Row.gap) {
            if lead != .none {
                leadView(onAccent: onAccent)
                    .frame(width: DesignTokens.Row.leadSize, height: DesignTokens.Row.leadSize)
                    .alignmentGuide(VerticalAlignment.center) { d in
                        twoLines ? d[.top] + Self.twoLineContentHeight / 2 : d[VerticalAlignment.center]
                    }
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: DesignTokens.Row.lineGap) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Row.itemGap) {
                    if let identifier {
                        Text(identifier)
                            .textStyle(.rowTitle)
                            .monospacedDigit()
                            .fixedSize()
                            .foregroundStyle(Self.secondaryColor(onAccent: onAccent))
                    }
                    Text(title)
                        .font(DesignTokens.TypeStyle.font(size: DesignTokens.TypeStyle.rowTitle.size, weight: DesignTokens.Row.titleWeight))
                        .lineHeight(.exact(points: CGFloat(DesignTokens.TypeStyle.rowTitle.scaledLineHeight(by: DesignTokens.TypeStyle.textScale))))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(onAccent ? DesignTokens.TextColor.onAccent.color : DesignTokens.TextColor.primary.color)
                }
                if let line2 {
                    Text(line2)
                        .textStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(Self.secondaryColor(onAccent: onAccent))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: DesignTokens.Row.itemGap) {
                trail
                if let value {
                    RowValue(value).frame(minWidth: valueWidth, alignment: .trailing)
                }
            }
            .fixedSize()
            // A small button or a chip is taller than a line: it overhangs the trail's line, as the catalog's
            // `.trail .btn { margin: -3px 0 }`, and never makes the row taller.
            .frame(height: DesignTokens.Row.leadSize)
        }
    }

    @ViewBuilder private func leadView(onAccent: Bool) -> some View {
        let font = DesignTokens.TypeStyle.font(size: DesignTokens.Row.leadGlyph, weight: DesignTokens.Row.titleWeight)
        switch lead {
        case .none, .blank:
            Color.clear
        case let .status(status):
            Image(systemName: status.symbol)
                .font(font)
                .foregroundStyle(onAccent ? Self.secondaryColor(onAccent: true) : status.tint)
        case let .dot(status, live):
            StatusDot(status, size: .large, live: live)
        case let .glyph(symbol, colour):
            Image(systemName: symbol)
                .font(font)
                .foregroundStyle(onAccent ? Self.secondaryColor(onAccent: true) : colour.color)
        }
    }

    /// Two lines' text: the first's 18 pt, the gap, the second's 16 pt, under the system's text size.
    static var twoLineContentHeight: Double {
        let scale = DesignTokens.TypeStyle.textScale
        return DesignTokens.TypeStyle.rowTitle.scaledLineHeight(by: scale) + DesignTokens.Row.lineGap
            + DesignTokens.TypeStyle.secondary.scaledLineHeight(by: scale)
    }

    /// The identifier, the second line, the lead and the values: secondary, or white at 85 % on the accent.
    static func secondaryColor(onAccent: Bool) -> Color {
        onAccent
            ? DesignTokens.TextColor.onAccent.color.opacity(DesignTokens.Row.onAccentSecondary)
            : DesignTokens.TextColor.secondary.color
    }
}

extension Row where Trail == EmptyView {
    /// A row with nothing in its trail but its value.
    public init(
        _ title: String, identifier: String? = nil, lead: RowLead = .none, line2: String? = nil, value: String? = nil,
        valueWidth: Double = DesignTokens.Row.valueWidth, selected: Bool = false, focused: Bool? = nil,
        state: DesignTokens.Interaction? = nil, windowActive: Bool? = nil,
        select: (() -> Void)? = nil, open: (() -> Void)? = nil
    ) {
        self.init(
            title, identifier: identifier, lead: lead, line2: line2, value: value, valueWidth: valueWidth, selected: selected,
            focused: focused, state: state, windowActive: windowActive, select: select, open: open
        ) { EmptyView() }
    }
}

/// A row's click, double click and Return, and the same as VoiceOver actions; nothing when it has neither.
private struct RowActions: ViewModifier {
    let select: (() -> Void)?
    let open: (() -> Void)?

    func body(content: Content) -> some View {
        if select == nil, open == nil {
            content
        } else {
            content
                .onTapGesture(count: 2) { open?() }
                .simultaneousGesture(TapGesture().onEnded { select?() })
                .onKeyPress(.return) {
                    guard let open else { return .ignored }
                    open()
                    return .handled
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { (open ?? select)?() }
        }
    }
}

// MARK: - Tree list

/// What a tree list tells the row it draws for an item: selected, and whether the list has keyboard focus.
public struct TreeRowState: Equatable {
    public var selected: Bool
    public var focused: Bool
}

/// C50, the catalog's tree (`.t-root`, `.t-kids`): `nodes` as rows, each child one step in under its parent on a rail
/// with a tick to its row. Past `foldDepth` (nil: never) the rest of a chain folds into a pill counting it ("+6"), which
/// a click or the Right arrow opens (`opened` holds the roots whose chains are open) and the Left arrow closes. The up
/// and down arrows walk the lines in order; Return opens the selected row's item (`open`). In a window it makes only
/// the rows on screen (a lazy stack); offscreen, where a snapshot has no scroll view, all of them.
public struct TreeList<ID: Hashable, RowContent: View>: View {
    let nodes: [TreeNode<ID>]
    let foldDepth: Int?
    @Binding var opened: Set<ID>
    @Binding var selection: TreeKey<ID>?
    let open: ((ID) -> Void)?
    let row: (ID, TreeRowState) -> RowContent
    @FocusState private var focused: Bool
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    public init(
        _ nodes: [TreeNode<ID>], foldDepth: Int? = DesignTokens.Tree.foldDepth, opened: Binding<Set<ID>>,
        selection: Binding<TreeKey<ID>?>, open: ((ID) -> Void)? = nil,
        @ViewBuilder row: @escaping (ID, TreeRowState) -> RowContent
    ) {
        self.nodes = nodes
        self.foldDepth = foldDepth
        _opened = opened
        _selection = selection
        self.open = open
        self.row = row
    }

    public var body: some View {
        let lines = TreeLines.lines(nodes, foldDepth: foldDepth, opened: opened)
        TreeStack(lazy: !offscreenSnapshot) {
            ForEach(lines) { line in
                lineView(line)
                    .padding(.bottom, DesignTokens.Tree.lineGap)
                    .background(alignment: .topLeading) { TreeRails(line: line) }
                    .id(line.key)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.downArrow) {
            selection = TreeLines.move(from: selection, by: 1, in: lines)
            return .handled
        }
        .onKeyPress(.upArrow) {
            selection = TreeLines.move(from: selection, by: -1, in: lines)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard let next = TreeLines.open(selection, in: lines, opened: opened) else { return .ignored }
            opened = next
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard let foldDepth, let closed = TreeLines.close(selection, in: nodes, foldDepth: foldDepth, opened: opened) else {
                return .ignored
            }
            opened = closed.opened
            selection = closed.selection
            return .handled
        }
        .onKeyPress(.return) {
            guard case let .row(id)? = selection, let open else { return .ignored }
            open(id)
            return .handled
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func lineView(_ line: TreeLine<ID>) -> some View {
        let picked = selection == line.key
        HStack(spacing: 0) {
            Color.clear.frame(width: DesignTokens.Tree.step * Double(line.depth), height: DesignTokens.Tree.railWidth)
            switch line.key {
            case let .row(id):
                row(id, TreeRowState(selected: picked, focused: picked && focused))
                    .simultaneousGesture(TapGesture().onEnded { selection = line.key })
            case .more:
                TreeMore(hidden: line.hidden, focused: picked && focused) {
                    opened.insert(line.root)
                    selection = line.key
                }
            }
        }
    }
}

/// The tree's column: a lazy stack in a window, an eager one offscreen.
private struct TreeStack<Content: View>: View {
    let lazy: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: 0, content: content)
        } else {
            VStack(alignment: .leading, spacing: 0, content: content)
        }
    }
}

/// A line's rails: one per level down to its own, each running on to the next line while its group does, and the tick
/// from its own rail to its row.
private struct TreeRails<ID: Hashable>: View {
    let line: TreeLine<ID>

    var body: some View {
        Canvas { context, size in
            guard line.depth > 0 else { return }
            let shading = GraphicsContext.Shading.color(DesignTokens.Tree.railColor.color)
            let width = DesignTokens.Tree.railWidth
            for level in 1 ... line.depth {
                let height = line.railsContinue[level - 1] ? size.height : size.height - DesignTokens.Tree.lineGap
                context.fill(Path(CGRect(x: DesignTokens.Tree.railX(level: level), y: 0, width: width, height: height)), with: shading)
            }
            let tick = CGRect(
                x: DesignTokens.Tree.railX(level: line.depth) + width, y: DesignTokens.Tree.tickY,
                width: DesignTokens.Tree.tickWidth, height: width
            )
            context.fill(Path(tick), with: shading)
        }
        .accessibilityHidden(true)
    }
}

/// The pill a folded chain shows: "+6" and a chevron; a click opens the chain.
private struct TreeMore: View {
    let hidden: Int
    let focused: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let font = DesignTokens.TypeStyle.font(size: DesignTokens.Tree.More.textSize, weight: DesignTokens.Tree.More.weight)
        HStack(spacing: DesignTokens.Tree.More.gap) {
            Text(DesignTokens.Tree.More.text(hidden)).font(font).monospacedDigit()
            Image(systemName: DesignTokens.Tree.More.symbol)
                .font(DesignTokens.TypeStyle.font(size: DesignTokens.Tree.More.chevron, weight: DesignTokens.Tree.More.weight))
        }
        .foregroundStyle(hovered ? DesignTokens.TextColor.primary.color : DesignTokens.TextColor.secondary.color)
        .padding(.leading, DesignTokens.Tree.More.leadingInset)
        .padding(.trailing, DesignTokens.Tree.More.trailingInset)
        .frame(height: DesignTokens.Tree.More.height)
        .background((hovered ? DesignTokens.Tree.More.hoverFill : DesignTokens.Tree.More.fill).color, in: Capsule())
        .focusRing(focused, Capsule())
        .contentShape(Capsule())
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
        .help(DesignTokens.Tree.More.help(hidden))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DesignTokens.Tree.More.help(hidden))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .padding(.leading, DesignTokens.Tree.More.offset)
        .frame(height: DesignTokens.Row.oneLineHeight)
    }
}

// MARK: - Progress strip

/// C51, the catalog's progress strip (`.epic-strip`): one segment per item in the status colour of its state, 3 pt
/// apart, filling the width it is given; past 30 items one segment per state, in proportion. With `live`, the segment of
/// an item being worked on breathes, and is still under Reduce Motion and offscreen. VoiceOver reads one element: the
/// `label` given, then the counts ("4 of 7 sub-tickets done: 4 done, 1 working, 2 waiting").
public struct ProgressStrip: View {
    let items: [DesignTokens.ProgressStrip.Item]
    let height: Double
    let live: Bool
    let label: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    public init(
        _ items: [DesignTokens.ProgressStrip.Item], height: Double = DesignTokens.ProgressStrip.height, live: Bool = true,
        label: String? = nil
    ) {
        self.items = items
        self.height = height
        self.live = live
        self.label = label
    }

    /// What VoiceOver reads: the label, then the counts.
    public static func accessibilityLabel(_ items: [DesignTokens.ProgressStrip.Item], label: String?) -> String {
        [label, DesignTokens.ProgressStrip.spoken(items)].compactMap { $0 }.joined(separator: ": ")
    }

    /// Whether a live segment breathes: live, and neither Reduce Motion nor a snapshot.
    static func breathes(live: Bool, reduceMotion: Bool, offscreen: Bool) -> Bool { live && !reduceMotion && !offscreen }

    /// The breath of a segment whose item is worked on, as the catalog draws it: to `breatheOpacity` and back over
    /// `breathePeriod`, each half on `--ease-standard`.
    static let breath = LayerPulse.Motion.breathe(
        to: DesignTokens.ProgressStrip.breatheOpacity,
        curve: DesignTokens.ProgressStrip.breatheCurve
    )

    public var body: some View {
        let segments = DesignTokens.ProgressStrip.segments(items)
        let weights = Double(max(segments.reduce(0) { $0 + $1.weight }, 1))
        let breathes = Self.breathes(live: live, reduceMotion: reduceMotion, offscreen: offscreenSnapshot)
        GeometryReader { proxy in
            let gaps = DesignTokens.ProgressStrip.gap * Double(max(segments.count - 1, 0))
            let unit = max(Double(proxy.size.width) - gaps, 0) / weights
            HStack(spacing: DesignTokens.ProgressStrip.gap) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    StripSegment(segment: segment, breathes: breathes && segment.live)
                        .frame(width: unit * Double(segment.weight))
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(items, label: label))
    }
}

/// One segment: its state's colour, breathing while its item is worked on. Which of the two it draws follows
/// `breathes`, so a segment whose item starts work while the strip is on screen, or whose Reduce Motion is turned off,
/// begins breathing at once, and one that stops goes back to full colour.
private struct StripSegment: View {
    let segment: DesignTokens.ProgressStrip.Segment
    let breathes: Bool

    /// A breathing segment pulses on Core Animation's render server (`LayerPulse`, TP-1480), as a run's working bar
    /// does. Drawn by SwiftUI on every frame (a `TimelineView`), one working sub-ticket had the hosting view lay the
    /// whole page out each frame: an untouched ticket page kept the main thread about 24 % busy.
    var body: some View {
        let color = DesignTokens.ProgressStrip.color(segment.status).color
        if breathes {
            LayerPulse(shape: .capsule, color: color, motion: ProgressStrip.breath, duration: DesignTokens.ProgressStrip.breathePeriod)
        } else {
            RoundedRectangle(cornerRadius: DesignTokens.ProgressStrip.radius, style: .continuous).fill(color)
        }
    }
}
// A sample change, to time a typical pull request's Mac checks.
