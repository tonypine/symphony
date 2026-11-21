import SwiftUI
import SymphonyBarCore

// The catalog's window sidebar (`.win-side`, `.nav-row`, `winSidebar` and `navRow` in `docs/design/catalog/stories.js`,
// TP-1498): the Director's destinations on the window's backdrop, drawn from `DesignTokens.Sidebar` in place of the
// system's sidebar list.

/// One row of the sidebar: a glyph and a name, a page under its destination (`child`) one step in, and its count, in
/// the Count badge's role colour, absent at zero.
public struct SidebarEntry<ID: Hashable>: Identifiable {
    public var id: ID
    public var title: String
    public var symbol: String
    /// The pointer's help: "Work (⌘3)". Folded, the row's name is its help.
    public var help: String
    public var child: Bool
    public var count: Int
    public var countRole: DesignTokens.Status?
    /// What VoiceOver reads for the count: "4 waiting".
    public var spoken: String?

    public init(
        id: ID, title: String, symbol: String, help: String? = nil, child: Bool = false, count: Int = 0,
        countRole: DesignTokens.Status? = nil, spoken: String? = nil
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.help = help ?? title
        self.child = child
        self.count = count
        self.countRole = countRole
        self.spoken = spoken
    }
}

/// What the sidebar says to VoiceOver.
public enum SidebarText {
    /// The sidebar's landmark name, as the catalog's `aria-label`.
    public static let label = "Destinations"

    /// The sidebar's value: the destination shown.
    public static func value(current: String?) -> String { current.map { "\($0), current" } ?? "" }
}

/// The window's sidebar: 232 pt flush with the window's leading edge, a hairline on its right, its top the room of the
/// window's buttons (which drags the window, as a title bar does). Its rows are 30 pt: the current one carries the
/// accent tint with accent text at 600, or the pressed grey with primary text while the window is not in front; the
/// others show hover, pressed and the keyboard's focus ring. `collapsed`, it is 60 pt of glyphs, each count an 8 pt dot,
/// each name the row's help; the width changes on the fold's spring, at once under Reduce Motion. The arrow keys move
/// the keyboard through the rows, and Space picks the one it is on. VoiceOver reads it as the group "Destinations",
/// whose value is the current destination.
public struct Sidebar<ID: Hashable>: View {
    let entries: [SidebarEntry<ID>]
    let current: ID?
    let collapsed: Bool
    let windowActive: Bool?
    let drawn: [ID: DesignTokens.Interaction]
    let select: (ID) -> Void

    @FocusState private var focus: ID?
    /// Whether the keyboard is the input in use: the ring shows only then (the catalog's `:focus-visible`), never for
    /// the focus the window hands its first row on opening, and a click takes it away.
    @ObservedObject private var modality = InputModality.shared
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    /// A sidebar of `entries` with `current` shown. `windowActive` and `drawn` (a row's state) draw it still, for the
    /// gallery; by default it follows the window and the pointer.
    public init(
        _ entries: [SidebarEntry<ID>], current: ID?, collapsed: Bool = false, windowActive: Bool? = nil,
        drawn: [ID: DesignTokens.Interaction] = [:], select: @escaping (ID) -> Void
    ) {
        self.entries = entries
        self.current = current
        self.collapsed = collapsed
        self.windowActive = windowActive
        self.drawn = drawn
        self.select = select
    }

    public var body: some View {
        let tokens = DesignTokens.Sidebar.self
        let active = windowActive ?? appearsActive
        VStack(alignment: .leading, spacing: tokens.rowGap) {
            ForEach(entries) { entry in
                SidebarRow(
                    entry: entry, current: entry.id == current, collapsed: collapsed, windowActive: active,
                    focused: Self.showsRing(focus == entry.id, byKeyboard: modality.keyboard, windowActive: active),
                    drawn: drawn[entry.id]
                ) {
                    select(entry.id)
                }
                    .focused($focus, equals: entry.id)
            }
        }
        .padding(.top, tokens.topInset)
        .padding([.horizontal, .bottom], tokens.inset)
        .frame(width: tokens.width(collapsed: collapsed))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(alignment: .top) {
            if !offscreenSnapshot {
                WindowDragArea().frame(height: tokens.topInset).accessibilityHidden(true)
            }
        }
        .overlay(alignment: .trailing) { HairlineDivider(.vertical) }
        .clipped()
        .animation(.motion(tokens.fold, reduceMotion: reduceMotion), value: collapsed)
        .onMoveCommand(perform: move)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SidebarText.label)
        .accessibilityValue(SidebarText.value(current: entries.first { $0.id == current }?.title))
    }

    /// Whether a row draws the focus ring: it has the focus, the keyboard moved it there, and the window is in front.
    static func showsRing(_ focused: Bool, byKeyboard: Bool, windowActive: Bool) -> Bool {
        focused && byKeyboard && windowActive
    }

    /// The arrow keys: the keyboard to the row above or under the one it is on, from the current row.
    private func move(_ direction: MoveCommandDirection) {
        let ids = entries.map(\.id)
        guard let from = ids.firstIndex(where: { $0 == (focus ?? current) }) else {
            focus = ids.first
            return
        }
        switch direction {
        case .up: focus = ids[max(from - 1, 0)]
        case .down: focus = ids[min(from + 1, ids.count - 1)]
        default: break
        }
    }
}

/// A row of the sidebar (`.nav-row`): a button whose style draws its states.
private struct SidebarRow<ID: Hashable>: View {
    let entry: SidebarEntry<ID>
    let current: Bool
    let collapsed: Bool
    let windowActive: Bool
    let focused: Bool
    let drawn: DesignTokens.Interaction?
    let select: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: select) {
            Text(entry.title)
        }
        .buttonStyle(
            SidebarRowStyle(
                entry: entry, current: current, collapsed: collapsed, windowActive: windowActive, hovered: hovered,
                focused: focused, drawn: drawn
            )
        )
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .help(entry.help)
        .accessibilityLabel(entry.title)
        .accessibilityValue(entry.count > 0 ? entry.spoken ?? CountBadge.spoken(entry.count) : "")
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

/// The row's face in each of its states.
private struct SidebarRowStyle<ID: Hashable>: ButtonStyle {
    let entry: SidebarEntry<ID>
    let current: Bool
    let collapsed: Bool
    let windowActive: Bool
    let hovered: Bool
    let focused: Bool
    let drawn: DesignTokens.Interaction?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let tokens = DesignTokens.Sidebar.self
        let state = drawn ?? DesignTokens.Interaction(hovered: hovered, pressed: configuration.isPressed, focused: focused)
        let shape = RoundedRectangle(cornerRadius: tokens.rowRadius, style: .continuous)
        return HStack(spacing: tokens.rowGapInside) {
            Image(systemName: entry.symbol)
                .resizable()
                .scaledToFit()
                .frame(width: tokens.glyph, height: tokens.glyph)
                .foregroundStyle(tokens.glyphColor(current: current, windowActive: windowActive).color)
                .accessibilityHidden(true)
            if !collapsed {
                Text(entry.title)
                    .font(DesignTokens.TypeStyle.font(size: tokens.textSize, weight: current ? tokens.currentWeight : tokens.weight))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(
                        tokens.text(current: current, child: entry.child, hovered: state.hovered, windowActive: windowActive).color
                    )
                Spacer(minLength: 0)
                CountBadge(entry.count, role: entry.countRole, spoken: entry.spoken)
            }
        }
        .padding(.leading, collapsed ? 0 : tokens.rowInset + (entry.child ? tokens.childIndent : 0))
        .padding(.trailing, collapsed ? 0 : tokens.rowInset)
        .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
        .frame(height: tokens.rowHeight)
        .overlay(alignment: .topTrailing) {
            if collapsed {
                CountBadge(entry.count, role: entry.countRole, form: .dot, spoken: entry.spoken)
                    .padding(.top, tokens.dotTop)
                    .padding(.trailing, tokens.dotTrailing)
            }
        }
        .background {
            if let fill = tokens.fill(state, current: current, windowActive: windowActive) { shape.fill(fill.color) }
        }
        .focusRing(state.showsFocusRing, shape, offset: 0)
        .scaleEffect(DesignTokens.Motion.scale(DesignTokens.Motion.pressScale, pressed: state.pressed, reduceMotion: reduceMotion))
        .contentShape(shape)
        .animation(.motion(.fast, reduceMotion: reduceMotion), value: state)
        .buttonPointer()
    }
}
