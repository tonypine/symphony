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
    /// Delete: a searchable list's query loses its last letter.
    case deleteBackward
    case text(String)
}

/// An open menu: its items, the one highlighted, the submenu open beside it, and what the keys, the pointer and a pick
/// do. A pick closes the whole menu first, then runs the item's move. A searchable one (`search`, the Searchable
/// pop-up's list) keeps what is typed as its query instead of jumping: its items are the choices the query keeps, the
/// first of them lit, and Delete takes the last letter back.
@MainActor
public final class MenuSession: ObservableObject {
    /// The items shown: every item, or a searchable list's choices its query keeps.
    @Published public private(set) var items: [MenuItem]
    /// What a searchable list searches for; nil for a menu.
    public let search: MenuSearch?
    /// What is typed in a searchable list's field.
    @Published public private(set) var query = ""
    private let allItems: [MenuItem]
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
    /// Tells the presenter a searchable list's items changed, so VoiceOver finds the ones shown.
    var onItems: (() -> Void)?

    public init(items: [MenuItem], highlighted: Int? = nil, search: MenuSearch? = nil) {
        self.items = items
        allItems = items
        self.search = search
        let lines = items.map(\.line)
        self.highlighted = highlighted.flatMap { lines.indices.contains($0) && lines[$0].selectable ? $0 : nil }
    }

    /// Sets a searchable list's query: its items become the choices it keeps (no separator), the first that can be
    /// picked lit; an empty query brings every item back with the ticked one lit. Nothing for a menu.
    public func find(_ query: String) {
        guard search != nil, !isClosed else { return }
        self.query = query
        items = query.isEmpty ? allItems : allItems.filter { !$0.isSeparator && MenuSearch.matches($0.title, query: query) }
        let lines = items.map(\.line)
        let ticked = query.isEmpty ? items.firstIndex { $0.checked == true && $0.enabled } : nil
        highlighted = ticked ?? MenuNavigation.end(false, in: lines)
        onItems?()
        onHighlight?(highlighted)
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
        if search != nil {
            switch key {
            case let .text(text):
                find(query + text)
                return true
            case .deleteBackward:
                find(String(query.dropLast()))
                return true
            case .left, .right:
                return true
            default: break
            }
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
        case .deleteBackward: break
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
/// With `search` it is the Searchable pop-up's list: 280 pt, the search field on top holding `query`, the choices
/// under it cut to 220 pt and scrolling, and a line saying nothing matches in their place when none is left.
public struct MenuList: View {
    let items: [MenuItem]
    let highlighted: Int?
    var minWidth: Double
    var search: MenuSearch?
    var query: String
    /// The tallest the list may be: a taller one shows this much and scrolls, keeping the highlighted item in view.
    var maxHeight: Double?
    var hover: ((Int?) -> Void)?
    var pick: ((Int) -> Void)?
    /// How far the list is scrolled from its top, as it scrolls.
    var scrolled: ((Double) -> Void)?
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(
        items: [MenuItem], highlighted: Int? = nil, minWidth: Double = DesignTokens.Menu.minWidth, maxHeight: Double? = nil,
        search: MenuSearch? = nil, query: String = "",
        hover: ((Int?) -> Void)? = nil, pick: ((Int) -> Void)? = nil, scrolled: ((Double) -> Void)? = nil
    ) {
        self.items = items
        self.highlighted = highlighted
        self.minWidth = minWidth
        self.maxHeight = maxHeight
        self.search = search
        self.query = query
        self.hover = hover
        self.pick = pick
        self.scrolled = scrolled
    }

    /// The height the list is cut to, when its items are taller than `maxHeight` (a searchable list's choices, than
    /// its 220 pt).
    var scrollHeight: Double? {
        if search != nil {
            let choices = MenuNavigation.height(of: items.map(\.line)) - 2 * DesignTokens.Menu.padding
            return choices > DesignTokens.SearchableList.listHeight ? DesignTokens.SearchableList.listHeight : nil
        }
        guard let maxHeight, MenuNavigation.height(of: items.map(\.line)) > maxHeight else { return nil }
        return maxHeight
    }

    private var showsChecks: Bool { items.contains { $0.checked != nil } }

    public var body: some View {
        let menu = DesignTokens.Menu.self
        let shape = RoundedRectangle(cornerRadius: menu.radius, style: .continuous)
        Group {
            if let search {
                searching(search)
            } else if let scrollHeight {
                scrolling(height: scrollHeight)
            } else {
                stack.fixedSize()
            }
        }
        .background {
            if offscreenSnapshot || reduceTransparency {
                shape.fill(menu.glass.solid.color)
            } else {
                Color.clear.glassBackground(menu.glass, in: shape)
            }
        }
        .elevation(menu.elevation, in: shape)
    }

    private var stack: some View {
        rows
            .padding(DesignTokens.Menu.padding)
            .frame(minWidth: minWidth, alignment: .leading)
    }

    private var rows: some View {
        let menu = DesignTokens.Menu.self
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if item.isSeparator {
                    HairlineDivider()
                        .padding(.vertical, menu.separatorMargin)
                        .padding(.horizontal, menu.itemInset)
                } else {
                    row(index, item).id(index)
                }
            }
        }
    }

    /// The Searchable pop-up's list: the field holding the query, then the choices (cut and scrolling past 220 pt),
    /// or the line saying nothing matches.
    private func searching(_ search: MenuSearch) -> some View {
        let list = DesignTokens.SearchableList.self
        return VStack(alignment: .leading, spacing: list.fieldGap) {
            SearchQueryFace(placeholder: search.placeholder, query: query)
            if items.isEmpty {
                Text(search.noMatch(query))
                    .textStyle(.secondary)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .lineLimit(1)
                    .padding(.vertical, list.noMatchVertical)
                    .padding(.horizontal, list.noMatchHorizontal)
            } else if let scrollHeight {
                cut(rows.frame(maxWidth: .infinity, alignment: .leading), height: scrollHeight)
            } else {
                rows
            }
        }
        .padding(list.padding)
        .frame(width: list.width, alignment: .leading)
    }

    /// A list taller than `maxHeight`: cut to `height`, scrolling, with the highlighted item kept in view.
    private func scrolling(height: Double) -> some View {
        cut(stack.fixedSize(), height: height).fixedSize(horizontal: true, vertical: false)
    }

    /// `content` cut to `height`, scrolling, with the highlighted item kept in view.
    private func cut(_ content: some View, height: Double) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                content
            }
            .scrollIndicators(.automatic)
            .frame(height: height)
            .onScrollGeometryChange(for: Double.self) { Double($0.contentOffset.y) } action: { _, offset in
                scrolled?(offset)
            }
            .onAppear {
                if let highlighted { proxy.scrollTo(highlighted) }
            }
            .onChange(of: highlighted) { _, index in
                if let index { proxy.scrollTo(index) }
            }
        }
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
            title(item)
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
                    .buttonPointer(enabled: item.disabledReason == nil)
                    .help(item.disabledReason ?? "")
            } else {
                label
            }
        }
    }

    /// An item's title: a searchable list's choices are identifiers, in the mono face.
    @ViewBuilder private func title(_ item: MenuItem) -> some View {
        if search != nil {
            Text(item.title)
                .textStyle(.mono)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text(item.title).textStyle(.body).lineLimit(1).fixedSize()
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
    var maxHeight: Double?
    var scrolled: ((Double) -> Void)?
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MenuList(
            items: session.items, highlighted: session.highlighted, minWidth: minWidth, maxHeight: maxHeight,
            search: session.search, query: session.query,
            hover: { session.hover($0) }, pick: { session.pick($0) }, scrolled: scrolled
        )
        .opacity(shown || reduceMotion ? 1 : 0)
        .offset(y: shown || reduceMotion ? 0 : DesignTokens.Menu.gap)
        .onAppear {
            withAnimation(.motion(.standard, reduceMotion: reduceMotion)) { shown = true }
        }
    }
}
