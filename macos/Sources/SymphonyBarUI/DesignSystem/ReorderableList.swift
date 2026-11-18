import SwiftUI
import SymphonyBarCore

// The catalog's Reorderable list (`components/reorderable-list`, `.reorder-line`; TP-1531): a short list whose order
// means something and is the Director's to set, such as the first choice and fallbacks of a kind of run on the Runs
// page. The order itself is `ReorderModel`'s.

/// A still state of the list, for a story: the handle under the pointer, the handle with the focus and the line
/// being dragged, each by its place from 1.
public struct ReorderableListDrawn: Equatable {
    public var hover: Int?
    public var focused: Int?
    public var dragging: Int?

    public init(hover: Int? = nil, focused: Int? = nil, dragging: Int? = nil) {
        self.hover = hover
        self.focused = focused
        self.dragging = dragging
    }
}

/// The catalog's grip glyph: six dots, two columns of three.
struct ReorderGrip: Shape {
    func path(in rect: CGRect) -> Path {
        let list = DesignTokens.ReorderableList.self
        let scale = min(rect.width, rect.height) / list.dotGrid
        let radius = list.dotRadius * scale
        var path = Path()
        for x in list.dotColumns {
            for y in list.dotRows {
                let center = CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
                path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            }
        }
        return path
    }
}

/// A line's handle: the grip in the tertiary colour; under the pointer secondary on the pressed surface, with the
/// focus secondary in the focus ring, and in the accent while its line is up.
public struct ReorderHandleFace: View {
    let lifted: Bool
    let hovered: Bool
    let focused: Bool

    public init(lifted: Bool = false, hovered: Bool = false, focused: Bool = false) {
        self.lifted = lifted
        self.hovered = hovered
        self.focused = focused
    }

    public var body: some View {
        let list = DesignTokens.ReorderableList.self
        let shape = RoundedRectangle(cornerRadius: list.handleRadius, style: .continuous)
        ReorderGrip()
            .fill(color)
            .frame(width: list.handleGlyph, height: list.handleGlyph)
            .frame(width: list.handleWidth, height: list.handleHeight)
            .background { if hovered { shape.fill(DesignTokens.StateSurface.pressed.fill) } }
            .contentShape(shape)
            .focusRing(focused, shape, offset: 0)
    }

    private var color: Color {
        if lifted { return DesignTokens.ColorToken.accentText.color }
        return (hovered || focused ? DesignTokens.TextColor.secondary : DesignTokens.TextColor.tertiary).color
    }
}

/// A line's place: the number in a 20 pt disc on the pressed surface.
struct ReorderNumber: View {
    let number: Int

    var body: some View {
        let list = DesignTokens.ReorderableList.self
        Text("\(number)")
            .font(DesignTokens.TypeStyle.font(size: list.numberSize, weight: list.numberWeight))
            .monospacedDigit()
            .foregroundStyle(DesignTokens.TextColor.secondary.color)
            .frame(width: list.number, height: list.number)
            .background(DesignTokens.StateSurface.pressed.fill, in: Circle())
            .accessibilityHidden(true)
    }
}

/// One line: its handle, its place, its own controls and, at its end, the remove button. Lifted, it is the content
/// surface at the third elevation with the accent edge, turned a little.
struct ReorderLine<Handle: View, Content: View>: View {
    let number: Int
    let lifted: Bool
    let remove: Remove?
    let handle: Handle
    let content: Content

    struct Remove {
        let help: String
        let action: () -> Void
    }

    var body: some View {
        let list = DesignTokens.ReorderableList.self
        let shape = RoundedRectangle(cornerRadius: list.radius, style: .continuous)
        HStack(spacing: list.lineGap) {
            handle
            ReorderNumber(number: number)
            content
            Spacer(minLength: 0)
            if let remove {
                IconButton(list.removeSymbol, help: remove.help, size: list.control, action: remove.action)
            }
        }
        .frame(minHeight: list.lineHeight)
        .background {
            if lifted {
                shape.fill(DesignTokens.Surface.content.color)
                    .elevation(list.elevation, in: shape)
                    .overlay { shape.inset(by: -list.liftEdge / 2).stroke(DesignTokens.ColorToken.accent.color, lineWidth: list.liftEdge) }
                    .padding(.vertical, -list.liftVertical)
                    .padding(.horizontal, -list.liftHorizontal)
            }
        }
        .rotationEffect(.degrees(lifted ? list.liftRotation : 0))
    }
}

/// The catalog's Reorderable list: each line has a handle to drag, its place as a number, its own controls (`line`)
/// and a way to remove it. Dragging a line by its handle moves it to any place, including above the first; the
/// others part to show where it lands. From the keyboard, Space on a handle picks its line up, Up and Down move it,
/// Space drops it and Escape puts it back where it was; VoiceOver announces the pick-up, each move and the drop
/// ("Line 2 of 3"). The numbers change at once on the drop, and `onReorder` hears the new order then, once, when it
/// changed. `onRemove` asks the page to remove a line; the only line has no remove button and is never removed.
/// Adding a line is the quiet `addTitle` button under the lines, and `footNote` a line beside it (a kind of run with
/// no fallback says a run waits). `removable` keeps the remove button off the lines the page can't remove. `drawn`
/// draws a still state for a story.
public struct ReorderableList<Item: Identifiable, Line: View>: View {
    let items: [Item]
    let onReorder: ([Item.ID]) -> Void
    let onRemove: ((Item.ID) -> Void)?
    let removable: ((Item.ID) -> Bool)?
    let removeHelp: (Int) -> String
    let addTitle: String?
    let onAdd: (() -> Void)?
    let footNote: ReorderFootNote?
    let drawn: ReorderableListDrawn?
    let line: (Item) -> Line

    @State private var model: ReorderModel<Item.ID>
    /// A drag under way: the place it started from, the place it is over and where the pointer is.
    @State private var dragFrom: Int?
    @State private var dragTarget: Int?
    @State private var dragOffset: CGSize = .zero
    @State private var lineHeight = DesignTokens.ReorderableList.lineHeight
    @State private var hovered: Item.ID?
    /// Whether the line up was picked up from the keyboard: moving the focus away puts it back.
    @State private var keyboardLift = false
    @FocusState private var focused: Item.ID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        _ items: [Item], onReorder: @escaping ([Item.ID]) -> Void, onRemove: ((Item.ID) -> Void)? = nil,
        removable: ((Item.ID) -> Bool)? = nil, removeHelp: @escaping (Int) -> String = { _ in ReorderSpeech.remove },
        addTitle: String? = nil, onAdd: (() -> Void)? = nil, footNote: ReorderFootNote? = nil,
        drawn: ReorderableListDrawn? = nil, @ViewBuilder line: @escaping (Item) -> Line
    ) {
        self.items = items
        self.onReorder = onReorder
        self.onRemove = onRemove
        self.removable = removable
        self.removeHelp = removeHelp
        self.addTitle = addTitle
        self.onAdd = onAdd
        self.footNote = footNote
        self.drawn = drawn
        self.line = line
        _model = State(initialValue: ReorderModel(items.map(\.id)))
    }

    /// The lines in the order drawn: the model's, or the page's while they differ (a line just added or removed).
    private var shown: [Item] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = model.order.compactMap { byID[$0] }
        return ordered.count == items.count ? ordered : items
    }

    private var pitch: Double { DesignTokens.ReorderableList.pitch(lineHeight) }

    public var body: some View {
        let list = DesignTokens.ReorderableList.self
        VStack(alignment: .leading, spacing: list.gap) {
            let lines = shown
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, item in
                lineView(item, index: index, count: lines.count)
            }
            if let addTitle, let onAdd {
                HStack(spacing: list.footGap) {
                    Button(addTitle, action: onAdd)
                        .buttonStyle(DirectorButtonStyle(kind: .quiet, size: list.control, glyph: list.addSymbol))
                    if let footNote {
                        Text(footNote.text)
                            .textStyle(.secondary)
                            .foregroundStyle((footNote.status?.textColor ?? DesignTokens.TextColor.tertiary).color)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, list.footIndent)
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: items.map(\.id)) { _, ids in model.reset(ids) }
        .onChange(of: focused) { _, now in
            if keyboardLift, let lifted = model.lifted, now != lifted { putBack() }
        }
    }

    @ViewBuilder
    private func lineView(_ item: Item, index: Int, count: Int) -> some View {
        let list = DesignTokens.ReorderableList.self
        let place = index + 1
        let number = drawn == nil ? (model.number(of: item.id) ?? place) : place
        let lifted = drawn.map { $0.dragging == place } ?? (model.lifted == item.id)
        ReorderLine(
            number: number, lifted: lifted, remove: remove(item.id, number: number),
            handle: handle(item.id, number: number, place: place, lifted: lifted), content: line(item)
        )
        .padding(.top, drawn.map { ($0.dragging ?? 0) > 1 && $0.dragging == place + 1 } == true ? list.dropGap : 0)
        .offset(offset(item.id, index: index, lifted: lifted))
        .zIndex(lifted ? 4 : 0)
        .onGeometryChange(for: Double.self) { $0.size.height } action: { lineHeight = $0 }
    }

    private func remove(_ id: Item.ID, number: Int) -> ReorderLine<AnyView, Line>.Remove? {
        guard let onRemove, model.showsRemove, removable?(id) ?? true else { return nil }
        return .init(help: removeHelp(number)) {
            if model.canRemove(id) { onRemove(id) }
        }
    }

    /// Where a line is drawn off its place: the dragged line follows the pointer, the lines it passes step aside.
    private func offset(_ id: Item.ID, index: Int, lifted: Bool) -> CGSize {
        let list = DesignTokens.ReorderableList.self
        if let drawn {
            return drawn.dragging == index + 1 ? CGSize(width: list.drawnLiftX, height: list.drawnLiftY) : .zero
        }
        // The lifted line reads its offset first: at the drop `dragFrom` is already nil, and the line settles from
        // the pointer into its new place as `dragOffset` animates to zero.
        if lifted { return dragOffset }
        guard let from = dragFrom else { return .zero }
        let step = ReorderModel<Item.ID>.shift(index, from: from, to: dragTarget ?? from)
        return CGSize(width: 0, height: Double(step) * pitch)
    }

    private func handle(_ id: Item.ID, number: Int, place: Int, lifted: Bool) -> AnyView {
        if let drawn {
            return AnyView(
                ReorderHandleFace(lifted: lifted, hovered: drawn.hover == place, focused: drawn.focused == place).accessibilityHidden(true)
            )
        }
        return AnyView(
            ReorderHandleFace(lifted: lifted, hovered: hovered == id, focused: focused == id)
                .onHover { inside in
                    if inside {
                        hovered = id
                    } else if hovered == id {
                        hovered = nil
                    }
                }
                .pointerStyle(dragFrom == nil ? .grabIdle : .grabActive)
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { dragChanged(id, translation: $0.translation) }
                        .onEnded { _ in dragEnded() }
                )
                .focusable(interactions: .activate)
                .focusEffectDisabled()
                .focused($focused, equals: id)
                .onKeyPress(.space) { space(id) }
                .onKeyPress(.upArrow) { arrow(id, by: -1) }
                .onKeyPress(.downArrow) { arrow(id, by: 1) }
                .onKeyPress(.escape) { escape() }
                .help(ReorderSpeech.help)
                .accessibilityElement()
                .accessibilityLabel(ReorderSpeech.handle(number))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { _ = space(id) }
                .accessibilityAction(.escape) { _ = escape() }
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: _ = arrow(id, by: 1)
                    case .decrement: _ = arrow(id, by: -1)
                    @unknown default: break
                    }
                }
        )
    }

    // MARK: - The pointer

    private func dragChanged(_ id: Item.ID, translation: CGSize) {
        if dragFrom == nil {
            guard model.lifted == nil || model.lifted == id else { return }
            if model.lifted == nil {
                model.pickUp(id)
                announce(ReorderSpeech.pickedUp)
            }
            keyboardLift = false
            dragFrom = model.order.firstIndex(of: id)
        }
        guard let from = dragFrom else { return }
        dragOffset = translation
        let target = ReorderModel<Item.ID>.target(from: from, translation: translation.height, pitch: pitch, count: model.order.count)
        if target != dragTarget {
            withAnimation(.motion(.fold, reduceMotion: reduceMotion)) { dragTarget = target }
        }
    }

    /// The drop: the line takes the place it is over, at once (the others already stand where they go), and settles
    /// from the pointer into it.
    private func dragEnded() {
        guard let from = dragFrom else { return }
        let to = dragTarget ?? from
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            _ = model.move(to: to)
            dragOffset.height -= Double(to - from) * pitch
            dragFrom = nil
            dragTarget = nil
        }
        withAnimation(.motion(.fold, reduceMotion: reduceMotion)) {
            dragOffset = .zero
            drop()
        }
    }

    // MARK: - The keyboard

    private func space(_ id: Item.ID) -> KeyPress.Result {
        guard dragFrom == nil else { return .handled }
        if model.lifted == id {
            withAnimation(.motion(.fold, reduceMotion: reduceMotion)) { drop() }
        } else if model.lifted == nil {
            withAnimation(.motion(.lift, reduceMotion: reduceMotion)) { _ = model.pickUp(id) }
            keyboardLift = true
            announce(ReorderSpeech.pickedUp)
        }
        return .handled
    }

    private func arrow(_ id: Item.ID, by offset: Int) -> KeyPress.Result {
        guard model.lifted == id, dragFrom == nil else { return .ignored }
        var moved = false
        withAnimation(.motion(.fold, reduceMotion: reduceMotion)) { moved = model.move(by: offset) }
        if moved { announce(ReorderSpeech.moved) }
        return .handled
    }

    private func escape() -> KeyPress.Result {
        guard model.lifted != nil, dragFrom == nil else { return .ignored }
        putBack()
        return .handled
    }

    // MARK: - Ends of a lift

    private func drop() {
        guard let id = model.lifted else { return }
        keyboardLift = false
        let order = model.drop()
        announce(ReorderSpeech.dropped, id: id)
        if let order { onReorder(order) }
    }

    private func putBack() {
        guard let id = model.lifted else { return }
        keyboardLift = false
        withAnimation(.motion(.fold, reduceMotion: reduceMotion)) { model.cancel() }
        announce(ReorderSpeech.putBack, id: id)
    }

    /// Says the lifted line's place now (or `id`'s) with `words`.
    private func announce(_ words: (Int, Int) -> String, id: Item.ID? = nil) {
        guard let id = id ?? model.lifted, let position = model.position(of: id) else { return }
        AccessibilityNotification.Announcement(words(position, model.order.count)).post()
    }
}

/// The line beside the add button under the lines (`.run-waits`): in the tertiary colour, or in a status's text colour
/// (`.run-waits.only`, "waiting on you" orange, when it warns).
public struct ReorderFootNote: Equatable {
    public var text: String
    public var status: DesignTokens.Status?

    public init(_ text: String, status: DesignTokens.Status? = nil) {
        self.text = text
        self.status = status
    }
}

extension View {
    /// A line's control that can't be used now: the 1 pt orange edge inside it (`.reorder-line.is-off .popup`).
    public func reorderLineOff(_ off: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.ReorderableList.control.radius, style: .continuous)
        return overlay {
            if off {
                shape.strokeBorder(DesignTokens.Status.you.color.color, lineWidth: DesignTokens.ReorderableList.offEdge).allowsHitTesting(false)
            }
        }
    }
}

/// Why a line can't be used now, after its controls (`.off-note`): a 6 pt dot and the reason, in the "waiting on you"
/// orange, in one line.
public struct ReorderLineNote: View {
    let text: String
    let status: DesignTokens.Status

    public init(_ text: String, status: DesignTokens.Status = .you) {
        self.text = text
        self.status = status
    }

    public var body: some View {
        let list = DesignTokens.ReorderableList.self
        HStack(spacing: list.offGap) {
            Circle().fill(status.color.color).frame(width: list.offDot, height: list.offDot)
            Text(text).textStyle(.secondary).lineLimit(1).fixedSize()
        }
        .foregroundStyle(status.textColor.color)
        .padding(.leading, list.offIndent)
    }
}
