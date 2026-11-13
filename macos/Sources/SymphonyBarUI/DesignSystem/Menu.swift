import AppKit
import SwiftUI
import SymphonyBarCore

// The app's open menu and pop-up list (the catalog's `.menu`, `.menu-item`, `.menu-sep`; TP-1508): the items, what
// the keys do with them (`MenuSession`) and how they are drawn (`MenuList`). `MenuPresenter` shows them on screen.

/// One line of a menu the app draws: a move, a choice that can be ticked, a submenu, or a separator. A move that is
/// off says why: its reason is its help text and what VoiceOver reads after it.
public struct MenuItem {
    public var title: String
    /// An SF Symbol before the title.
    public var glyph: String?
    /// The keyboard hint at the trailing edge, keys with a space between them (`"⌘ L"`).
    public var shortcut: String?
    /// A choice's tick: nil for a move, which has no tick column.
    public var checked: Bool?
    /// A move that stops or throws work away, in the problem colour.
    public var destructive: Bool
    /// Why the item is off; nil when it can be picked.
    public var disabledReason: String?
    /// The items of the submenu it opens.
    public var submenu: [MenuItem]?
    public private(set) var isSeparator = false
    let action: () -> Void

    public init(
        _ title: String, glyph: String? = nil, shortcut: String? = nil, checked: Bool? = nil, destructive: Bool = false,
        disabledReason: String? = nil, action: @escaping () -> Void
    ) {
        self.title = title
        self.glyph = glyph
        self.shortcut = shortcut
        self.checked = checked
        self.destructive = destructive
        self.disabledReason = disabledReason
        self.action = action
    }

    /// An item that opens `items` beside it.
    public static func submenu(_ title: String, glyph: String? = nil, disabledReason: String? = nil, items: [MenuItem]) -> MenuItem {
        var item = MenuItem(title, glyph: glyph, disabledReason: disabledReason) {}
        item.submenu = items
        return item
    }

    /// A hairline between groups of items.
    public static var separator: MenuItem {
        var item = MenuItem("") {}
        item.isSeparator = true
        return item
    }

    /// Whether a click or Return can pick it.
    public var enabled: Bool { !isSeparator && disabledReason == nil && submenu.map { !$0.isEmpty } != false }

    var line: MenuNavigation.Line { isSeparator ? .separator : MenuNavigation.Line(title: title, enabled: enabled) }

    /// What VoiceOver reads: the title, ticked or not, and why it is off.
    var accessibilityText: String {
        [title, checked == true ? "checked" : nil, disabledReason].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The keys an open menu answers.
public enum MenuKey: Equatable {
    case up, down, home, end, left, right, pick, escape
    case text(String)
}

/// An open menu: its items, the one highlighted, the submenu open beside it, and what the keys, the pointer and a pick
/// do. A pick closes the whole menu first, then runs the item's move.
@MainActor
public final class MenuSession: ObservableObject {
    public let items: [MenuItem]
    @Published public private(set) var highlighted: Int?
    @Published public private(set) var child: MenuSession?
    public private(set) var childIndex: Int?
    public private(set) var isClosed = false
    public private(set) weak var parent: MenuSession?
    private var typeAhead = MenuNavigation.TypeAhead()

    /// Called once when the menu closes, after a pick or not.
    var onClose: (() -> Void)?
    /// Shows the submenu `child` beside item `index`, or, given nil, takes the one shown away.
    var onSubmenu: ((MenuSession?, Int) -> Void)?
    /// Tells the presenter the highlight moved, so VoiceOver follows it.
    var onHighlight: ((Int?) -> Void)?

    public init(items: [MenuItem], highlighted: Int? = nil) {
        self.items = items
        let lines = items.map(\.line)
        self.highlighted = highlighted.flatMap { lines.indices.contains($0) && lines[$0].selectable ? $0 : nil }
    }

    var lines: [MenuNavigation.Line] { items.map(\.line) }

    /// The outermost menu: the one a pick or Escape closes.
    var root: MenuSession { parent?.root ?? self }

    /// The pointer over item `index` (nil: off the items): it lights, and a submenu under it opens.
    public func hover(_ index: Int?) {
        guard !isClosed else { return }
        guard let index, items.indices.contains(index), lines[index].selectable else {
            if child == nil { setHighlight(nil) }
            return
        }
        setHighlight(index)
        if items[index].submenu != nil {
            if childIndex != index { openSubmenu(index, highlightFirst: false) }
        } else {
            closeChild()
        }
    }

    /// A key while the menu is open; true when the menu used it. A submenu answers first, and gives Left and Escape
    /// back to the menu it opened from, which closes it.
    @discardableResult
    public func handle(_ key: MenuKey, at time: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard !isClosed else { return false }
        if let child, child.handle(key, at: time) { return true }
        if child != nil, key == .left || key == .escape {
            closeChild()
            return true
        }
        switch key {
        case .up: setHighlight(MenuNavigation.move(from: highlighted, step: -1, in: lines))
        case .down: setHighlight(MenuNavigation.move(from: highlighted, step: 1, in: lines))
        case .home: setHighlight(MenuNavigation.end(false, in: lines))
        case .end: setHighlight(MenuNavigation.end(true, in: lines))
        case .right:
            if let highlighted, items[highlighted].submenu != nil, lines[highlighted].selectable {
                openSubmenu(highlighted, highlightFirst: true)
            }
        case .left, .escape:
            if parent != nil { return false }
            if key == .escape { close() }
        case .pick:
            if let highlighted { pick(highlighted) }
        case let .text(text):
            if let found = typeAhead.type(text, at: time, current: highlighted, in: lines) { setHighlight(found) }
        }
        return true
    }

    /// A click or Return on item `index`: a submenu opens; a move or a choice closes the menu, then runs.
    public func pick(_ index: Int) {
        guard !isClosed, items.indices.contains(index), lines[index].selectable else { return }
        let item = items[index]
        if item.submenu != nil {
            setHighlight(index)
            openSubmenu(index, highlightFirst: true)
            return
        }
        root.close()
        item.action()
    }

    /// Closes the whole menu, its submenus with it.
    public func close() {
        let root = root
        guard !root.isClosed else { return }
        root.closeAll()
        root.onClose?()
    }

    private func closeAll() {
        child?.closeAll()
        isClosed = true
    }

    private func setHighlight(_ index: Int?) {
        guard highlighted != index else { return }
        highlighted = index
        onHighlight?(index)
    }

    private func openSubmenu(_ index: Int, highlightFirst: Bool) {
        closeChild()
        let items = items[index].submenu ?? []
        let sub = MenuSession(items: items, highlighted: highlightFirst ? MenuNavigation.end(false, in: items.map(\.line)) : nil)
        sub.parent = self
        child = sub
        childIndex = index
        onSubmenu?(sub, index)
    }

    private func closeChild() {
        guard let child, let index = childIndex else { return }
        child.closeAll()
        self.child = nil
        childIndex = nil
        onSubmenu?(nil, index)
    }
}

// MARK: - Drawing

/// An open menu as the catalog draws it: glass in the menu's 12 pt radius at the third elevation, 28 pt items with a
/// tick column when any item is a choice, a keyboard hint or a submenu's chevron at the trailing edge, hairline
/// separators, the highlighted item on the accent fill with white words, a destructive item in the problem colour and
/// an item that is off in the tertiary colour with its reason as help. Without `hover` and `pick`, a still picture.
public struct MenuList: View {
    let items: [MenuItem]
    let highlighted: Int?
    var minWidth: Double
    var hover: ((Int?) -> Void)?
    var pick: ((Int) -> Void)?
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(
        items: [MenuItem], highlighted: Int? = nil, minWidth: Double = DesignTokens.Menu.minWidth,
        hover: ((Int?) -> Void)? = nil, pick: ((Int) -> Void)? = nil
    ) {
        self.items = items
        self.highlighted = highlighted
        self.minWidth = minWidth
        self.hover = hover
        self.pick = pick
    }

    private var showsChecks: Bool { items.contains { $0.checked != nil } }

    public var body: some View {
        let menu = DesignTokens.Menu.self
        let shape = RoundedRectangle(cornerRadius: menu.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if item.isSeparator {
                    Rectangle()
                        .fill(DesignTokens.Surface.separator.color)
                        .frame(height: menu.separatorHeight)
                        .padding(.vertical, menu.separatorMargin)
                        .padding(.horizontal, menu.itemInset)
                        .accessibilityHidden(true)
                } else {
                    row(index, item)
                }
            }
        }
        .padding(menu.padding)
        .frame(minWidth: minWidth, alignment: .leading)
        .fixedSize()
        .background {
            if offscreenSnapshot || reduceTransparency {
                shape.fill(menu.glass.solid.color)
            } else {
                Color.clear.glassBackground(menu.glass, in: shape)
            }
        }
        .elevation(menu.elevation, in: shape)
    }

    private func row(_ index: Int, _ item: MenuItem) -> some View {
        let menu = DesignTokens.Menu.self
        let lit = index == highlighted && item.enabled
        let label = HStack(spacing: menu.itemGap) {
            if showsChecks {
                Image(systemName: menu.checkSymbol)
                    .font(DesignTokens.Control.small.glyphFont())
                    .foregroundStyle(lit ? DesignTokens.TextColor.onAccent.color : DesignTokens.ColorToken.accentText.color)
                    .frame(width: menu.check)
                    .opacity(item.checked == true ? 1 : 0)
                    .accessibilityHidden(true)
            }
            if let glyph = item.glyph {
                Image(systemName: glyph).font(DesignTokens.Control.small.glyphFont()).accessibilityHidden(true)
            }
            Text(item.title).textStyle(.body).lineLimit(1).fixedSize()
            Spacer(minLength: menu.hintGap)
            if let shortcut = item.shortcut {
                KeyboardHint(shortcut, plain: true, highlighted: lit)
            }
            if item.submenu != nil {
                Image(systemName: menu.submenuSymbol).font(DesignTokens.Control.small.glyphFont()).accessibilityHidden(true)
            }
        }
        .foregroundStyle(foreground(item, lit: lit))
        .padding(.horizontal, menu.itemInset)
        .frame(height: menu.itemHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if lit {
                RoundedRectangle(cornerRadius: menu.itemRadius, style: .continuous).fill(DesignTokens.ColorToken.accent.color)
            }
        }
        .contentShape(Rectangle())
        return Group {
            if let hover, let pick {
                label
                    .onHover { inside in hover(inside ? index : nil) }
                    .onTapGesture { pick(index) }
                    .help(item.disabledReason ?? "")
            } else {
                label
            }
        }
    }

    private func foreground(_ item: MenuItem, lit: Bool) -> Color {
        if !item.enabled { return DesignTokens.TextColor.tertiary.color }
        if lit { return DesignTokens.TextColor.onAccent.color }
        return item.destructive ? DesignTokens.Status.problem.text : DesignTokens.TextColor.primary.color
    }
}

/// An open session's list, live: it follows the session's highlight, and rises 6 pt and fades in as it opens.
struct MenuSessionList: View {
    @ObservedObject var session: MenuSession
    let minWidth: Double
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MenuList(
            items: session.items, highlighted: session.highlighted, minWidth: minWidth,
            hover: { session.hover($0) }, pick: { session.pick($0) }
        )
        .opacity(shown || reduceMotion ? 1 : 0)
        .offset(y: shown || reduceMotion ? 0 : DesignTokens.Menu.gap)
        .onAppear {
            withAnimation(.motion(.standard, reduceMotion: reduceMotion)) { shown = true }
        }
    }
}
