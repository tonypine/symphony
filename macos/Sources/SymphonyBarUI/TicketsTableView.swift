import AppKit
import SwiftUI
import SymphonyBarCore

// Work › Tickets' table (TP-1501, `.tk-table` in `components.css`): the server's rows in the shared `DataTable`, in
// the order the server sorted them. The identifier in the row title's weight; Repo, Epic and Labels as the catalog's
// chips, "None" in the tertiary colour for a ticket without; Title and Situation sharing the width left, two parts to
// three; a title and a situation's cause cut with an ellipsis, the situation's glyph and word never; Urgent at 650.

/// The Tickets table: `columns` over `rows`, sorted by `sort` (the server's), `selection` the picked row; each
/// ticket's situation as the state words it (`situations`). Return or a double click calls `open`, Space
/// `toggleDetails`, and a row's context menu is `rowMenu`'s.
public struct TicketsTable: View {
    let rows: [TicketsRow]
    let columns: [TicketColumn]
    var situations: [String: Situation]
    var reference: Date
    @Binding var sort: TicketSort
    @Binding var selection: String?
    var empty: DataTableEmpty
    var drawnAs: DataTableShown?
    let open: (String) -> Void
    let toggleDetails: (String) -> Void
    let rowMenu: ((TicketsRow) -> AnyView)?

    public init(
        rows: [TicketsRow], columns: [TicketColumn], situations: [String: Situation] = [:], reference: Date = Date(),
        sort: Binding<TicketSort>,
        selection: Binding<String?>, empty: DataTableEmpty = DataTableEmpty(TicketList.noMatchTitle), drawnAs: DataTableShown? = nil,
        open: @escaping (String) -> Void = { _ in }, toggleDetails: @escaping (String) -> Void = { _ in },
        rowMenu: ((TicketsRow) -> AnyView)? = nil
    ) {
        self.rows = rows
        self.columns = columns
        self.situations = situations
        self.reference = reference
        _sort = sort
        _selection = selection
        self.empty = empty
        self.drawnAs = drawnAs
        self.open = open
        self.toggleDetails = toggleDetails
        self.rowMenu = rowMenu
    }

    public var body: some View {
        DataTable(
            "Tickets", columns: TicketsTableColumns.columns(columns, rows: rows, situations: situations, reference: reference),
            rows: rows,
            selection: $selection, sort: tableSort, presorted: true, empty: empty, drawnAs: drawnAs,
            open: { open($0.identifier) }, secondary: { toggleDetails($0.identifier) }, rowMenu: rowMenu
        )
    }

    /// The query's sort as the header shows it, and a click on a header as the query's sort.
    private var tableSort: Binding<DesignTokens.Table.Sort?> {
        Binding(
            get: { DesignTokens.Table.Sort(sort.column, ascending: sort.ascending) },
            set: { picked in
                guard let picked else { return }
                sort = TicketSort(column: picked.column, ascending: picked.ascending)
            }
        )
    }
}

/// The table's columns, built from the catalog's.
public enum TicketsTableColumns {
    /// The word a cell without a value shows.
    public static let none = "None"

    /// Each of `shown` as the table draws it over `rows`, with the state's `situations`, ages against `reference`.
    @MainActor
    public static func columns(
        _ shown: [TicketColumn], rows: [TicketsRow], situations: [String: Situation] = [:], reference: Date
    ) -> [DataTableColumn<TicketsRow>] {
        let state = TicketsTableState(situations: situations, reference: reference)
        return shown.map { column(for: $0, rows: rows, state: state) }
    }

    @MainActor
    static func column(for column: TicketColumn, rows: [TicketsRow], state: TicketsTableState) -> DataTableColumn<TicketsRow> {
        let reference = state.reference
        let title = column.title
        let id = column.name
        switch column.name {
        case "identifier":
            return DataTableColumn(
                title, id: id, ascending: "A to Z", descending: "Z to A", measuredAs: .rowTitle, tabular: true, text: \.identifier
            ) { row in
                TicketsCellText(row.identifier, style: .rowTitle)
            }
        case "title":
            return DataTableColumn(
                title, id: id, width: .share(DesignTokens.Tickets.titleShare, minimum: DesignTokens.Tickets.titleMinimum),
                ascending: "A to Z", descending: "Z to A", text: \.title
            ) { row in
                TicketsCellText(row.title, weight: DesignTokens.Tickets.titleWeight)
            }
        case "repo", "epic":
            let kind: Chip.Kind = column.name == "epic" ? .epic : .repo
            return DataTableColumn(
                title, id: id, ascending: "A to Z", descending: "Z to A", fitExtra: chipRoom, measuredAs: .label,
                text: { $0.text(id) ?? Self.none }
            ) { row in
                if let value = row.text(id) { Chip(value, kind: kind) } else { TicketsCellText(Self.none, color: .textTertiary) }
            }
        case "labels":
            return DataTableColumn(
                title, id: id, sortable: false, fitExtra: labelsRoom(rows), measuredAs: .label,
                text: { $0.labels.isEmpty ? Self.none : $0.labels.joined() }
            ) { row in
                TicketLabelChips(labels: row.labels)
            }
        case "situation":
            let lead = rows.map { TicketSituationCell.leadWidth(word: state.situation($0).word) }
            return DataTableColumn(
                title, id: id,
                width: .share(DesignTokens.Tickets.situationShare, minimum: situationMinimum(leads: lead)),
                text: { state.situation($0).spoken() }
            ) { row in
                TicketSituationCell(text: state.situation(row))
            }
        case "priority":
            return DataTableColumn(
                title, id: id, firstAscending: true, text: { row in row.cell(column, reference: reference) }
            ) { row in
                TicketsCellText(
                    row.cell(column, reference: reference),
                    weight: row.number("priority") == 1 ? DesignTokens.Tickets.urgentWeight : DesignTokens.TypeStyle.body.weight
                )
            }
        default:
            return DataTableColumn(
                title, id: id, alignment: column.isTime ? .number : .text, ascending: column.isTime ? "newest first" : "ascending",
                descending: column.isTime ? "oldest first" : "descending", text: { row in row.cell(column, reference: reference) }
            )
        }
    }

    /// The room a chip takes beyond its words: its padding, its glyph and the gap after it.
    static var chipRoom: Double { 2 * Chip.inset + Chip.glyph + Chip.gap }

    /// The room the widest row's label chips take beyond their words.
    static func labelsRoom(_ rows: [TicketsRow]) -> Double {
        let most = rows.map(\.labels.count).max() ?? 0
        guard most > 0 else { return 0 }
        let chip = 2 * Chip.labelInset + Chip.swatch + Chip.gap
        return Double(most) * chip + Double(most - 1) * DesignTokens.Space.s1
    }

    /// The Situation column's least width: the widest glyph and word of `leads`, never cut,
    /// and the cell's padding; the table's least share when that is wider.
    public static func situationMinimum(leads: [Double]) -> Double {
        let widest = leads.max() ?? 0
        return max(DesignTokens.Table.minShareWidth, (widest + 2 * DesignTokens.Table.cellPadding).rounded(.up))
    }
}

/// What the table knows of each ticket from the state.
struct TicketsTableState {
    let situations: [String: Situation]
    let reference: Date

    /// A row's situation as the table draws it: the state's own when it holds one of the server's kind, or the
    /// server's kind. A row without either reads as unknown.
    func situation(_ row: TicketsRow) -> SituationText {
        let line = row.situation(tracked: situations[row.identifier]) ?? Situation(kind: .unknown, cause: "")
        return SituationText(line, reference: reference)
    }
}

/// A cell's words in the body style (or `style`) at `weight`, in `color`, on-accent on the picked row; cut with an
/// ellipsis when the column is narrower.
struct TicketsCellText: View {
    let text: String
    var style: DesignTokens.TypeStyle = .body
    var weight: Int?
    var color: DesignTokens.ColorToken = .textPrimary
    @Environment(\.rowOnAccent) private var onAccent

    init(_ text: String, style: DesignTokens.TypeStyle = .body, weight: Int? = nil, color: DesignTokens.ColorToken = .textPrimary) {
        self.text = text
        self.style = style
        self.weight = weight
        self.color = color
    }

    var body: some View {
        // The weighted font first: the style's own, set around it, gives way to it and still sets the line height.
        Text(text)
            .font(DesignTokens.TypeStyle.font(size: style.size, weight: weight ?? style.weight))
            .textStyle(style)
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle((onAccent ? DesignTokens.TextColor.onAccent : color).color)
    }
}

/// A row's labels as the catalog's label chips, or "None".
struct TicketLabelChips: View {
    let labels: [String]

    var body: some View {
        if labels.isEmpty {
            TicketsCellText(TicketsTableColumns.none, color: .textTertiary)
        } else {
            HStack(spacing: DesignTokens.Space.s1) {
                ForEach(labels, id: \.self) { Chip($0, kind: .label(.idle)) }
            }
        }
    }
}

/// The compact situation in a table's cell (`td.tk-sit .situation`): the kind's glyph and its word at 650 in its
/// colour, never cut, then the cause, cut with an ellipsis. On the picked row every part is on-accent.
public struct TicketSituationCell: View {
    let text: SituationText
    @Environment(\.rowOnAccent) private var onAccent

    public init(text: SituationText) {
        self.text = text
    }

    /// The word's CSS weight (`.situation .word { font-weight: 650 }`).
    public static let wordWeight = 650

    public var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.s2) {
            TicketSituationLead(text: text)
                .dataTableNeverCut()
            if !text.cause.isEmpty {
                Text(text.cause)
                    .textStyle(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle((onAccent ? DesignTokens.TextColor.onAccent : DesignTokens.TextColor.primary).color)
            }
        }
        .help(text.sentence)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.spoken())
    }

    /// The width the glyph and the word take, as drawn.
    @MainActor
    public static func leadWidth(word: String) -> Double {
        let body = DesignTokens.TypeStyle.body
        let scale = DesignTokens.TypeStyle.textScale
        let wordFont = NSFont.systemFont(
            ofSize: CGFloat(body.size * scale), weight: NSFont.Weight(rawValue: CGFloat(DesignTokens.TypeStyle.systemWeight(css: wordWeight)))
        )
        // Each text is laid out on whole points, as SwiftUI draws it, so each is rounded up on its own.
        let width = glyphWidth + DesignTokens.Space.s2 + DataTableCache<TicketsRow>.width(word, font: wordFont).rounded(.up)
        return width.rounded(.up)
    }

    /// The widest of the kinds' glyphs in the body's size, measured once.
    static let glyphWidth: Double = {
        let size = CGFloat(DesignTokens.TypeStyle.body.size * DesignTokens.TypeStyle.textScale)
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        let widths = DesignTokens.SituationKind.allCases.compactMap { kind in
            NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)?.size.width
        }
        return Double(widths.max() ?? size).rounded(.up)
    }()
}

/// The part of the situation that is never cut.
struct TicketSituationLead: View {
    let text: SituationText
    @Environment(\.rowOnAccent) private var onAccent

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.s2) {
            Image(systemName: text.kind.symbol)
                .font(DesignTokens.TypeStyle.body.font)
                .foregroundStyle(onAccent ? DesignTokens.TextColor.onAccent.color : text.kind.tint)
                .frame(width: TicketSituationCell.glyphWidth)
                .accessibilityHidden(true)
            Text(text.word)
                .font(DesignTokens.TypeStyle.font(size: DesignTokens.TypeStyle.body.size, weight: TicketSituationCell.wordWeight))
                .foregroundStyle(onAccent ? DesignTokens.TextColor.onAccent.color : text.kind.status.text)
                .lineLimit(1)
        }
    }
}
