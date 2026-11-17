import AppKit
import SwiftUI
import SymphonyBarCore

// The catalog's Table (`.table`, the Table header and row stories; TP-1510) as a shared component: a 32 pt header whose
// sortable columns are buttons showing their direction, 36 pt rows with hover, every second one faintly banded, the
// picked one on the accent with rounded ends, and the keyboard's row in the focus ring. Columns fit their content or
// share the spare width; with more than fit, the table scrolls sideways and keeps its first column in place. It builds
// only the rows on screen. It draws only from `DesignTokens.Table`, `Row` and the shared colours.

// MARK: - Columns

/// A column of a `DataTable`: its title, how its content sits (text at the leading edge, numbers at the trailing edge
/// in tabular figures), how wide it is (fitted to its content and never squeezed, or a share of the spare width, its
/// cells cut with an ellipsis), and its cell, which is any view. `text` is the cell's words: what a fitted column is
/// measured by, what the column sorts by unless `sortKey` says otherwise, and what VoiceOver reads.
public struct DataTableColumn<Item: Identifiable> {
    public let id: String
    public let title: String
    public let alignment: DesignTokens.Table.Alignment
    public let width: DesignTokens.Table.Width
    public let sortable: Bool
    /// The column's words for its two directions, for VoiceOver: "Age, sorted, oldest first".
    public let ascendingWords: String
    public let descendingWords: String
    /// Whether a first click sorts it ascending: text from A, numbers from the most (the catalog's).
    public let firstAscending: Bool
    /// Room a fitted column's custom cell takes beyond its words (a badge's padding and glyph).
    public let fitExtra: Double
    let text: (Item) -> String
    let sortKey: ((Item) -> String)?
    let cell: ((Item) -> AnyView)?

    /// A column whose cell is its words, in the body style (primary, white on the picked row).
    public init(
        _ title: String, id: String? = nil, alignment: DesignTokens.Table.Alignment = .text,
        width: DesignTokens.Table.Width = .fit, sortable: Bool = true, ascending: String = "ascending",
        descending: String = "descending", firstAscending: Bool? = nil, sortKey: ((Item) -> String)? = nil,
        text: @escaping (Item) -> String
    ) {
        self.id = id ?? title
        self.title = title
        self.alignment = alignment
        self.width = width
        self.sortable = sortable
        ascendingWords = ascending
        descendingWords = descending
        self.firstAscending = firstAscending ?? (alignment == .text)
        fitExtra = 0
        self.text = text
        self.sortKey = sortKey
        cell = nil
    }

    /// A column whose cell is any view; `text` still names its words.
    public init<Cell: View>(
        _ title: String, id: String? = nil, alignment: DesignTokens.Table.Alignment = .text,
        width: DesignTokens.Table.Width = .fit, sortable: Bool = true, ascending: String = "ascending",
        descending: String = "descending", firstAscending: Bool? = nil, fitExtra: Double = 0,
        sortKey: ((Item) -> String)? = nil, text: @escaping (Item) -> String, @ViewBuilder cell: @escaping (Item) -> Cell
    ) {
        self.id = id ?? title
        self.title = title
        self.alignment = alignment
        self.width = width
        self.sortable = sortable
        ascendingWords = ascending
        descendingWords = descending
        self.firstAscending = firstAscending ?? (alignment == .text)
        self.fitExtra = fitExtra
        self.text = text
        self.sortKey = sortKey
        self.cell = { AnyView(cell($0)) }
    }
}

/// What an empty table says: one line, and a Clear Filters link when filters emptied it.
public struct DataTableEmpty {
    public let text: String
    public let clearFilters: (() -> Void)?

    public init(_ text: String, clearFilters: (() -> Void)? = nil) {
        self.text = text
        self.clearFilters = clearFilters
    }
}

/// States drawn still, for the gallery's stories: a header under the pointer, a row under the pointer, the keyboard's
/// row, and whether the window is in front.
public struct DataTableShown: Equatable {
    public var headerHover: String?
    public var rowHover: Int?
    public var focusedRow: Int?
    public var windowActive: Bool

    public init(headerHover: String? = nil, rowHover: Int? = nil, focusedRow: Int? = nil, windowActive: Bool = true) {
        self.headerHover = headerHover
        self.rowHover = rowHover
        self.focusedRow = focusedRow
        self.windowActive = windowActive
    }
}

// MARK: - Cell helpers

/// A cell's words in the body style: primary, or secondary (`secondary`), white on the picked row; a number column's in
/// tabular figures. Cut with an ellipsis when its column is narrower.
public struct DataTableText: View {
    let text: String
    let secondary: Bool
    let number: Bool
    @Environment(\.rowOnAccent) private var onAccent

    public init(_ text: String, secondary: Bool = false, number: Bool = false) {
        self.text = text
        self.secondary = secondary
        self.number = number
    }

    public var body: some View {
        Text(text)
            .textStyle(.body)
            .tabularFigures(number)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(
                secondary
                    ? Row<EmptyView>.secondaryColor(onAccent: onAccent)
                    : (onAccent ? DesignTokens.TextColor.onAccent.color : DesignTokens.TextColor.primary.color)
            )
    }
}

extension View {
    /// Marks part of a cell as never cut: in a column that shares the spare width, the rest of the cell shortens
    /// first (the Tickets situation's glyph and word).
    public func dataTableNeverCut() -> some View {
        fixedSize(horizontal: true, vertical: false).layoutPriority(1)
    }

    @ViewBuilder fileprivate func tabularFigures(_ on: Bool) -> some View {
        if on { monospacedDigit() } else { self }
    }
}

// MARK: - Table

/// C59, the catalog's Table: `columns` over `rows`, sorted by `sort` (a click on a sortable header sorts by it, a
/// second reverses), `selection` the picked row. Up and Down move the pick, Return or a double click calls `open`,
/// Space calls `secondary`. With no rows it shows `empty`. VoiceOver reads it as `label`, each header with its sort and
/// each row as its cells after their titles. `drawnAs` draws hover and focus still, for a snapshot.
public struct DataTable<Item: Identifiable>: View {
    let columns: [DataTableColumn<Item>]
    let rows: [Item]
    @Binding var selection: Item.ID?
    @Binding var sort: DesignTokens.Table.Sort?
    let label: String
    let empty: DataTableEmpty
    let surface: DesignTokens.ColorToken
    let drawnAs: DataTableShown?
    let open: ((Item) -> Void)?
    let secondary: ((Item) -> Void)?
    let rowMenu: ((Item) -> AnyView)?

    @State private var cache = DataTableCache<Item>()
    @State private var scroll = DataTableScroll()
    /// Whether the pick last moved by the keys: the focus ring shows then, never after a click.
    @State private var byKeyboard = false
    @FocusState private var focused: Bool
    @Environment(\.offscreenSnapshot) private var offscreen

    public init(
        _ label: String, columns: [DataTableColumn<Item>], rows: [Item], selection: Binding<Item.ID?> = .constant(nil),
        sort: Binding<DesignTokens.Table.Sort?> = .constant(nil), empty: DataTableEmpty = DataTableEmpty("Nothing to show."),
        surface: DesignTokens.ColorToken = DesignTokens.Surface.content, drawnAs: DataTableShown? = nil,
        open: ((Item) -> Void)? = nil, secondary: ((Item) -> Void)? = nil, rowMenu: ((Item) -> AnyView)? = nil
    ) {
        self.label = label
        self.columns = columns
        self.rows = rows
        _selection = selection
        _sort = sort
        self.empty = empty
        self.surface = surface
        self.drawnAs = drawnAs
        self.open = open
        self.secondary = secondary
        self.rowMenu = rowMenu
    }

    public var body: some View {
        let laid = cache.layout(rows: rows, columns: columns, sort: sort)
        GeometryReader { geometry in
            let available = Double(geometry.size.width)
            let widths = DesignTokens.Table.widths(available: available, columns: columns.map(\.width), measured: laid.measured)
            let total = widths.reduce(0, +)
            let pinned = total > available + 0.5
            let fits = Int(((Double(geometry.size.height) - DesignTokens.Table.headerHeight) / DesignTokens.Table.rowHeight).rounded(.up))
            table(laid.rows, widths: widths, width: max(total, available), visible: available, fits: max(fits, 1), pinned: pinned)
        }
        .background(surface.color)
        .focusable(!offscreen)
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.upArrow, .downArrow, .return, .space]) { press in key(press.key, rows: laid.rows) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    @ViewBuilder private func table(
        _ items: [Item], widths: [Double], width: Double, visible: Double, fits: Int, pinned: Bool
    ) -> some View {
        let header = DataTableHeader(
            columns: columns, widths: widths, sort: $sort, surface: surface, shownHover: drawnAs?.headerHover,
            pinned: pinned, scroll: scroll
        )
        if offscreen {
            VStack(alignment: .leading, spacing: 0) {
                header
                // Offscreen there is no scrolling: only the rows its height shows are built.
                rowsOrEmpty(Array(items.prefix(fits)), widths: widths, visible: visible, pinned: pinned)
            }
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView(pinned ? [.horizontal, .vertical] : .vertical) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            rowsOrEmpty(items, widths: widths, visible: visible, pinned: pinned)
                        } header: {
                            header
                        }
                    }
                    .frame(width: width, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onScrollGeometryChange(for: Double.self) { Double($0.contentOffset.x) } action: { _, x in scroll.x = x }
                .onChange(of: selection) { _, picked in
                    guard byKeyboard, let picked else { return }
                    proxy.scrollTo(picked)
                }
            }
        }
    }

    @ViewBuilder private func rowsOrEmpty(_ items: [Item], widths: [Double], visible: Double, pinned: Bool) -> some View {
        if items.isEmpty {
            DataTableEmptyView(empty: empty)
                .frame(width: visible, height: DesignTokens.Table.emptyHeight)
        } else {
            let titles = columns.map(\.title)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let picked = selection == item.id
                DataTableRowView(
                    index: index, cells: columns.map { cell($0, item) }, words: columns.map { $0.text(item) }, titles: titles,
                    widths: widths, alignments: columns.map(\.alignment), selected: picked,
                    focusRing: drawnAs?.focusedRow.map { $0 == index } ?? (picked && focused && byKeyboard),
                    shownHover: drawnAs.map { $0.rowHover == index }, windowActive: drawnAs?.windowActive,
                    surface: surface, pinned: pinned, scroll: scroll,
                    select: {
                        byKeyboard = false
                        focused = true
                        selection = item.id
                    },
                    open: open.map { open in { open(item) } },
                    menu: rowMenu.map { $0(item) }
                )
                .id(item.id)
            }
        }
    }

    private func cell(_ column: DataTableColumn<Item>, _ item: Item) -> AnyView {
        if let cell = column.cell { return cell(item) }
        return AnyView(DataTableText(column.text(item), number: column.alignment == .number))
    }

    private func key(_ key: KeyEquivalent, rows items: [Item]) -> KeyPress.Result {
        let index = items.firstIndex { $0.id == selection }
        switch key {
        case .upArrow, .downArrow:
            guard let next = DesignTokens.Table.moved(index, by: key == .upArrow ? -1 : 1, count: items.count) else { return .ignored }
            byKeyboard = true
            selection = items[next].id
            return .handled
        case .return:
            guard let index, let open else { return .ignored }
            open(items[index])
            return .handled
        default:
            guard let index, let secondary else { return .ignored }
            secondary(items[index])
            return .handled
        }
    }
}

// MARK: - Sorting and measuring, once per change

/// The rows' order and each column's measured width, worked out again only when the rows' ids or words, the columns
/// or the sort change: the table's body runs on every pick and resize, and a thousand rows' words are not measured each
/// time. The rows it hands back are always the ones just given, in the kept order, so a row whose content changes under
/// the same id is drawn as it is now.
@MainActor
final class DataTableCache<Item: Identifiable> {
    struct Key: Equatable {
        let ids: [Item.ID]
        let columns: [String]
        /// Each row's words, column by column: its text and, when the column has one, its sort words.
        let words: [String]
        let sort: DesignTokens.Table.Sort?
    }

    struct Laid {
        let rows: [Item]
        let measured: [Double]
    }

    private var key: Key?
    /// The given rows' positions in the table's order.
    private var order: [Int] = []
    private var measured: [Double] = []
    /// How many times it measured: a test's count.
    private(set) var measures = 0

    func layout(rows: [Item], columns: [DataTableColumn<Item>], sort: DesignTokens.Table.Sort?) -> Laid {
        let next = Key(ids: rows.map(\.id), columns: columns.map(\.id), words: Self.words(rows, columns: columns), sort: sort)
        if next != key {
            key = next
            measures += 1
            order = Self.order(rows, columns: columns, sort: sort)
            measured = columns.map { Self.measure($0, rows: rows) }
        }
        return Laid(rows: order.map { rows[$0] }, measured: measured)
    }

    static func words(_ rows: [Item], columns: [DataTableColumn<Item>]) -> [String] {
        var words: [String] = []
        words.reserveCapacity(rows.count * columns.count)
        for row in rows {
            for column in columns {
                words.append(column.text(row))
                if let sortKey = column.sortKey { words.append(sortKey(row)) }
            }
        }
        return words
    }

    /// `rows` in `sort`'s order.
    static func sorted(_ rows: [Item], columns: [DataTableColumn<Item>], sort: DesignTokens.Table.Sort?) -> [Item] {
        order(rows, columns: columns, sort: sort).map { rows[$0] }
    }

    /// The positions of `rows` in `sort`'s order by its column's sort words, ties kept in the order given; as given
    /// with no sort.
    static func order(_ rows: [Item], columns: [DataTableColumn<Item>], sort: DesignTokens.Table.Sort?) -> [Int] {
        guard let sort, let column = columns.first(where: { $0.id == sort.column && $0.sortable }) else { return Array(rows.indices) }
        let keys = rows.map(column.sortKey ?? column.text)
        let order = rows.indices.sorted { lhs, rhs in
            if DesignTokens.Table.Sort.ordered(keys[lhs], keys[rhs], ascending: sort.ascending) { return true }
            if DesignTokens.Table.Sort.ordered(keys[rhs], keys[lhs], ascending: sort.ascending) { return false }
            return lhs < rhs
        }
        return order
    }

    /// A fitted column's width: its widest words (or its title with the sort glyph's room) and its padding; nothing
    /// for a column that shares.
    static func measure(_ column: DataTableColumn<Item>, rows: [Item]) -> Double {
        guard column.width.weight == nil else { return 0 }
        let label = DesignTokens.TypeStyle.label
        let title = width(column.title, font: label.nsFont, tracking: label.tracking * label.scaledSize(by: DesignTokens.TypeStyle.textScale))
            + (column.sortable ? DesignTokens.Table.sortGap + DesignTokens.Table.sortGlyph + DesignTokens.Table.headerButtonOutset : 0)
        let font = column.alignment == .number ? numberFont : DesignTokens.TypeStyle.body.nsFont
        let widest = rows.reduce(0.0) { max($0, width(column.text($1), font: font)) } + column.fitExtra
        return (max(title, widest) + 2 * DesignTokens.Table.cellPadding).rounded(.up)
    }

    static func width(_ text: String, font: NSFont, tracking: Double = 0) -> Double {
        let size = (text as NSString).size(withAttributes: [.font: font, .kern: tracking])
        return Double(size.width).rounded(.up)
    }

    /// The body style in tabular figures.
    static var numberFont: NSFont {
        let body = DesignTokens.TypeStyle.body.nsFont
        return NSFont.monospacedDigitSystemFont(ofSize: body.pointSize, weight: NSFont.Weight(rawValue: CGFloat(DesignTokens.TypeStyle.body.systemWeight)))
    }
}

/// How far the table has scrolled sideways: only the rows on screen and the header read it, to keep the first column
/// in place, so a sideways scroll redraws neither the table nor the rows off screen.
@MainActor
@Observable
final class DataTableScroll {
    var x: Double = 0
}

// MARK: - Header

private struct DataTableHeader<Item: Identifiable>: View {
    let columns: [DataTableColumn<Item>]
    let widths: [Double]
    @Binding var sort: DesignTokens.Table.Sort?
    let surface: DesignTokens.ColorToken
    let shownHover: String?
    let pinned: Bool
    let scroll: DataTableScroll

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                DataTableHeaderCell(column: column, sort: $sort, shownHover: shownHover.map { $0 == column.id })
                    .frame(width: widths[index], height: DesignTokens.Table.headerHeight)
                    .background { if index == 0, pinned { surface.color } }
                    .offset(x: index == 0 && pinned ? DesignTokens.Table.pinnedOffset(scrolled: scroll.x) : 0)
                    .zIndex(index == 0 ? 1 : 0)
            }
        }
        .frame(height: DesignTokens.Table.headerHeight)
        .background(surface.color)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DesignTokens.Surface.separator.color).frame(height: DesignTokens.Table.ruleWidth)
        }
    }
}

private struct DataTableHeaderCell<Item: Identifiable>: View {
    let column: DataTableColumn<Item>
    @Binding var sort: DesignTokens.Table.Sort?
    let shownHover: Bool?
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let sorted = sort?.column == column.id ? sort : nil
        let lit = sorted != nil || (shownHover ?? hovered)
        Group {
            if column.sortable {
                Button {
                    withAnimation(.motion(.standard, reduceMotion: reduceMotion)) {
                        sort = DesignTokens.Table.Sort.toggled(sort, column: column.id, firstAscending: column.firstAscending)
                    }
                } label: {
                    label(sorted: sorted, lit: lit)
                        .padding(.horizontal, DesignTokens.Table.headerButtonOutset)
                        .frame(height: DesignTokens.Table.headerButton.height)
                        .background {
                            if shownHover ?? hovered {
                                RoundedRectangle(cornerRadius: DesignTokens.Table.headerButton.radius, style: .continuous)
                                    .fill(DesignTokens.ColorToken.surfaceHover.color)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .animation(.motion(.fast, reduceMotion: reduceMotion), value: hovered)
                .padding(.horizontal, DesignTokens.Table.cellPadding - DesignTokens.Table.headerButtonOutset)
            } else {
                label(sorted: nil, lit: false).padding(.horizontal, DesignTokens.Table.cellPadding)
            }
        }
        .frame(maxWidth: .infinity, alignment: column.alignment == .number ? .trailing : .leading)
        .accessibilityLabel(
            DesignTokens.Table.spokenHeader(
                column.title, sort: sort, column: column.id, ascending: column.ascendingWords, descending: column.descendingWords
            )
        )
        .accessibilityAddTraits(.isHeader)
    }

    private func label(sorted: DesignTokens.Table.Sort?, lit: Bool) -> some View {
        HStack(spacing: DesignTokens.Table.sortGap) {
            Text(column.title)
                .textStyle(.label)
                .lineLimit(1)
            if let sorted {
                Image(systemName: sorted.ascending ? DesignTokens.Table.ascendingSymbol : DesignTokens.Table.descendingSymbol)
                    .font(DesignTokens.TypeStyle.font(size: DesignTokens.Table.sortGlyph, weight: DesignTokens.TypeStyle.label.weight))
                    .transition(.scale.combined(with: .opacity))
                    .id(sorted.ascending)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(lit ? DesignTokens.TextColor.primary.color : DesignTokens.TextColor.secondary.color)
    }
}

// MARK: - Rows

private struct DataTableRowView: View {
    let index: Int
    let cells: [AnyView]
    let words: [String]
    let titles: [String]
    let widths: [Double]
    let alignments: [DesignTokens.Table.Alignment]
    let selected: Bool
    let focusRing: Bool
    let shownHover: Bool?
    let windowActive: Bool?
    let surface: DesignTokens.ColorToken
    let pinned: Bool
    let scroll: DataTableScroll
    let select: () -> Void
    let open: (() -> Void)?
    let menu: AnyView?

    @State private var hovered = false
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let active = windowActive ?? appearsActive
        let fill = DesignTokens.Table.fill(index, selected: selected, hovered: shownHover ?? hovered, windowActive: active)
        let onAccent = selected && active
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
        HStack(spacing: 0) {
            ForEach(cells.indices, id: \.self) { column in
                cells[column]
                    .padding(.horizontal, DesignTokens.Table.cellPadding)
                    .frame(
                        width: widths[column], height: DesignTokens.Table.rowHeight,
                        alignment: alignments[column] == .number ? .trailing : .leading
                    )
                    .background { if column == 0, pinned { pinnedBackground(fill) } }
                    .offset(x: column == 0 && pinned ? DesignTokens.Table.pinnedOffset(scrolled: scroll.x) : 0)
                    .zIndex(column == 0 ? 1 : 0)
            }
        }
        .frame(height: DesignTokens.Table.rowHeight)
        .background { if let fill { shape.fill(Self.color(fill)) } }
        .focusRing(focusRing, shape, offset: 0)
        .environment(\.rowOnAccent, onAccent)
        .environment(\.backgroundProminence, onAccent ? .increased : .standard)
        .animation(.motion(.fast, reduceMotion: reduceMotion), value: fill)
        .contentShape(shape)
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { open?() }
        .simultaneousGesture(TapGesture().onEnded { select() })
        .contextMenu { if let menu { menu } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DesignTokens.Table.spokenRow(titles: titles, cells: words))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { select() }
        .accessibilityAction(named: "Open") { open?() }
    }

    /// The first cell's own ground while it stays in place: the table's surface under the row's fill, the row's
    /// rounded end on its leading side.
    private func pinnedBackground(_ fill: DesignTokens.Table.Fill?) -> some View {
        let radius = DesignTokens.Radius.row
        let shape = UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, style: .continuous)
        return ZStack {
            Rectangle().fill(surface.color)
            if let fill { shape.fill(Self.color(fill)) }
        }
    }

    static func color(_ fill: DesignTokens.Table.Fill) -> Color {
        switch fill {
        case .accent: DesignTokens.ColorToken.accent.color
        case .inactiveSelection: DesignTokens.ColorToken.surfacePressed.color
        case .hover: DesignTokens.ColorToken.surfaceHover.color
        case .band: DesignTokens.Table.band.color
        }
    }
}

// MARK: - Empty

private struct DataTableEmptyView: View {
    let empty: DataTableEmpty

    var body: some View {
        HStack(spacing: DesignTokens.Space.s1) {
            Text(empty.text)
                .textStyle(.body)
                .foregroundStyle(DesignTokens.TextColor.secondary.color)
            if let clear = empty.clearFilters {
                Button("Clear Filters", action: clear)
                    .buttonStyle(.plain)
                    .textStyle(.body)
                    .foregroundStyle(DesignTokens.ColorToken.accentText.color)
                    .pointerStyle(.link)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension DesignTokens.Badge.Size {
    /// What a badge of this size takes beyond its word: its padding, its glyph and the gap after it. A fitted column of
    /// badges passes it as its `fitExtra`.
    public var tableRoom: Double { leading + trailing + glyph + DesignTokens.Badge.gap }
}
