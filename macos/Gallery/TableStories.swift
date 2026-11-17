// The catalog's Table header and row stories (TP-1510), each drawn by the shared `DataTable` under the id the catalog
// gives the story (`docs/design/catalog/stories.js`, `table()`): the five tickets with their stage badge, repo, age and
// tokens, sorted by age, oldest first, unless a story sorts by another column. Each story is a variation of its own
// (`table-header-and-row-default`). The stories are live in the gallery: a header sorts on a click, a row picks, the
// keys move the pick; the hover and focus stories draw that state still. A thousand rows follow, for scrolling.
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// One of the catalog table's tickets.
struct TableTicket: Identifiable {
    let id: String
    let title: String
    let status: DesignTokens.Status
    let word: String
    let repo: String
    /// Minutes since it moved.
    let age: Int
    /// Millions of tokens; none at 0.
    let tokens: Double
}

let tableTickets = [
    TableTicket(id: "TP-1382", title: "Design system catalog as HTML", status: .you, word: "Waiting on you", repo: "symphony", age: 192, tokens: 6.2),
    TableTicket(id: "TP-1376", title: "A CI-wait pause lifts itself", status: .working, word: "Working", repo: "symphony", age: 14, tokens: 1.8),
    TableTicket(id: "TP-1375", title: "First dispatch waits for its relations", status: .problem, word: "Checks failed", repo: "symphony", age: 22, tokens: 3.4),
    TableTicket(id: "SHOP-305", title: "Checkout total rounding", status: .working, word: "Code Review", repo: "web-shop", age: 6, tokens: 0.9),
    TableTicket(id: "TP-1371", title: "Workspace lifecycle docs", status: .idle, word: "Queued", repo: "symphony", age: 120, tokens: 0),
]

/// "3 h 12 min", "2 h", "14 min": the catalog's `fmtAge`.
func tableAge(_ minutes: Int) -> String {
    guard minutes >= 60 else { return "\(minutes) min" }
    return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
}

/// The catalog's columns: Ticket, Title (sharing the spare width), Stage (a small badge), Repo (secondary), Age and
/// Tokens; Title and Stage do not sort.
@MainActor
let tableColumns: [DataTableColumn<TableTicket>] = [
    DataTableColumn(
        "Ticket", id: "ident", ascending: "A to Z", descending: "Z to A", measuredAs: .rowTitle, tabular: true, text: \.id
    ) { ticket in
        Text(ticket.id).textStyle(.rowTitle).monospacedDigit().lineLimit(1)
    },
    DataTableColumn("Title", id: "title", width: .share(1), sortable: false, text: \.title),
    DataTableColumn(
        "Stage", id: "stage", sortable: false, fitExtra: DesignTokens.Badge.Size.small.tableRoom, text: \.word
    ) { ticket in
        Badge(status: ticket.status, word: ticket.word, size: .small)
    },
    DataTableColumn("Repo", id: "repo", text: \.repo) { ticket in DataTableText(ticket.repo, secondary: true) },
    DataTableColumn(
        "Age", id: "age", alignment: .number, ascending: "newest first", descending: "oldest first",
        sortKey: { String($0.age) }, text: { tableAge($0.age) }
    ),
    DataTableColumn(
        "Tokens", id: "tokens", alignment: .number, ascending: "least first", descending: "most first",
        sortKey: { String($0.tokens) }, text: { $0.tokens > 0 ? "\($0.tokens)M" : "none" }
    ) { ticket in
        if ticket.tokens > 0 {
            DataTableText("\(ticket.tokens)M", number: true)
        } else {
            DataTableText("none", secondary: true)
        }
    },
]

/// A live table story: its sort and pick kept while the gallery shows it.
private struct LiveTable: View {
    let rows: [TableTicket]
    @State var sort: DesignTokens.Table.Sort?
    @State var selection: String?
    let drawnAs: DataTableShown?
    let empty: Bool

    var body: some View {
        DataTable(
            "Tickets", columns: tableColumns, rows: empty ? [] : rows, selection: $selection, sort: $sort,
            empty: DataTableEmpty("No tickets match these filters.") {},
            drawnAs: drawnAs
        )
    }
}

/// The catalog's table story: sorted by `sort` (age, oldest first), with `selected` picked and a state drawn still.
@MainActor
func tableStory(
    sort: DesignTokens.Table.Sort = DesignTokens.Table.Sort("age", ascending: false), selected: String? = nil,
    shown: DataTableShown? = nil, empty: Bool = false, rows: [TableTicket] = tableTickets, height: CGFloat = tableStoryHeight
) -> AnyView {
    AnyView(
        LiveTable(rows: rows, sort: sort, selection: selected, drawnAs: shown, empty: empty)
            .frame(width: tableStoryWidth, height: height)
    )
}

/// The catalog's 760 px table, and its height: the header and five rows.
let tableStoryWidth: CGFloat = 760
let tableStoryHeight = CGFloat(DesignTokens.Table.headerHeight + 5 * DesignTokens.Table.rowHeight)

/// A thousand tickets: the catalog's five over and over, for scrolling a long table.
let thousandTableTickets: [TableTicket] = (0 ..< 1000).map { index in
    let ticket = tableTickets[index % tableTickets.count]
    return TableTicket(
        id: "TP-\(2000 + index)", title: ticket.title, status: ticket.status, word: ticket.word, repo: ticket.repo,
        age: ticket.age + index, tokens: ticket.tokens
    )
}

/// Every story of the Table entry, in the catalog's order, then the long table.
@MainActor
let tableStories: [ComponentStory] = {
    func story(_ id: String, height: CGFloat = tableStoryHeight, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "table-header-and-row", id: id, title: "Table header and row", width: tableStoryWidth, height: height, draw: draw)
    }
    let emptyHeight = CGFloat(DesignTokens.Table.headerHeight + DesignTokens.Table.emptyHeight)
    let longHeight = CGFloat(DesignTokens.Table.headerHeight + 12 * DesignTokens.Table.rowHeight)
    return [
        story("default") { tableStory() },
        story("header-hover") { tableStory(shown: DataTableShown(headerHover: "tokens")) },
        story("sorted-by-tokens") { tableStory(sort: DesignTokens.Table.Sort("tokens", ascending: false)) },
        story("row-hover") { tableStory(shown: DataTableShown(rowHover: 1)) },
        // The catalog's third row by age, oldest first.
        story("row-selected") { tableStory(selected: "TP-1375") },
        story("row-focused") { tableStory(shown: DataTableShown(focusedRow: 0)) },
        story("empty", height: emptyHeight) { tableStory(empty: true, height: emptyHeight) },
        story("thousand-rows", height: longHeight) { tableStory(rows: thousandTableTickets, height: longHeight) },
    ]
}()
