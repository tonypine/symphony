// The catalog's Key-value list and Collapsible card stories (TP-1511), each drawn by the shared `KeyValueList` and
// `CollapsibleCard` under the id the catalog gives the story (`docs/design/catalog/stories.js`): the list's ticket and
// work facts at the catalog's 360 px, the card's Earlier runs at its 520 px with three of the catalog's tickets as its
// rows. Each story is a variation of its own (`key-value-list-default`). The card's stories are live: a click, Return
// or Space folds and opens it; the hover and focus stories draw that state still.
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// The catalog's fourth to sixth `TICKETS`: the Collapsible card's rows.
let foldTickets = [
    CatalogTicket(ident: "SHOP-305", title: "Checkout total rounding", status: .working, badge: "Code Review", age: "6 min", line2: "Waiting for CI on PR #812"),
    CatalogTicket(
        ident: "TP-1374", title: "Ask “changes nothing against main” only when the diff is empty", status: .done, badge: "Shipped", age: "1 day",
        line2: "Merged as PR #794"
    ),
    CatalogTicket(ident: "TP-1371", title: "Workspace lifecycle docs", status: .idle, badge: "Queued", age: "2 h", line2: "Waiting for a free slot"),
]

/// The catalog's list width and card width.
let keyValueStoryWidth: CGFloat = 360
let collapsibleStoryWidth: CGFloat = 520

/// The catalog's ticket facts: its stage, repo, pull request and epic. `missing` leaves the epic out, as unknown.
@MainActor
@ViewBuilder
func ticketFactRows(missing: Bool) -> some View {
    KeyValueRow("Stage") { Badge(status: .you, word: "Waiting on you", size: .small) }
    KeyValueRow("Repo") { Chip("symphony", kind: .repo) }
    KeyValueRow("Pull request", text: "PR #812 · checks passing")
    KeyValueRow("Part of", text: missing ? nil : "TP-1381 · Phase 3b")
}

/// The catalog's work facts: its runs, tokens and how long it has waited. `missing` leaves the tokens out.
@MainActor
@ViewBuilder
func workFactRows(missing: Bool) -> some View {
    KeyValueRow("Runs", text: "3 · 1 h 12 min")
    KeyValueRow("Tokens", text: missing ? nil : "6.2M of 8M")
    KeyValueRow("Waiting since", text: "Today 11:15")
}

/// The catalog's Key-value list story: every fact in one list, or in two headed groups.
@MainActor
func keyValueStory(layout: DesignTokens.KeyValue.Layout = .columns, grouped: Bool = false, missing: Bool = false) -> AnyView {
    let list: AnyView =
        if grouped {
            AnyView(
                KeyValueGroups {
                    KeyValueList(layout: layout, heading: "Ticket") { ticketFactRows(missing: missing) }
                    KeyValueList(layout: layout, heading: "Work") { workFactRows(missing: missing) }
                }
            )
        } else {
            AnyView(
                KeyValueList(layout: layout) {
                    ticketFactRows(missing: missing)
                    workFactRows(missing: missing)
                }
            )
        }
    return AnyView(list.frame(width: keyValueStoryWidth, alignment: .leading))
}

/// A live Collapsible card story: its fold kept while the gallery shows it.
private struct LiveCollapsible: View {
    @State var expanded: Bool
    let empty: Bool
    let drawnAs: DesignTokens.Interaction?

    var body: some View {
        CollapsibleCard("Earlier runs", summary: "3 runs · 1 h 12 min", expanded: $expanded, empty: empty, drawnAs: drawnAs) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(foldTickets.enumerated()), id: \.offset) { index, ticket in
                    rowStory(ticket).foldRow(index)
                }
            }
        }
        .frame(width: collapsibleStoryWidth)
    }
}

/// The catalog's Collapsible card story: open or folded, its head in a state drawn still, or empty.
@MainActor
func collapsibleStory(expanded: Bool = true, shown: DesignTokens.Interaction? = nil, empty: Bool = false) -> AnyView {
    AnyView(LiveCollapsible(expanded: expanded, empty: empty, drawnAs: shown))
}

/// Every story of the two entries, in the catalog's order.
@MainActor
let foldStories: [ComponentStory] = {
    func list(_ id: String, height: CGFloat = 220, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "key-value-list", id: id, title: "Key-value list", width: keyValueStoryWidth, height: height, draw: draw)
    }
    func card(_ id: String, height: CGFloat = 200, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "collapsible-card", id: id, title: "Collapsible card", width: collapsibleStoryWidth, height: height, draw: draw)
    }
    let head = CGFloat(DesignTokens.Collapsible.headMinHeight)
    return [
        list("default") { keyValueStory() },
        list("grouped", height: 280) { keyValueStory(grouped: true) },
        list("stacked", height: 360) { keyValueStory(layout: .stacked) },
        list("values-left-out", height: 180) { keyValueStory(missing: true) },
        card("open") { collapsibleStory() },
        card("folded", height: head) { collapsibleStory(expanded: false) },
        card("header-hover", height: head) { collapsibleStory(expanded: false, shown: .hover) },
        card("header-focused", height: head) { collapsibleStory(expanded: false, shown: .focus) },
        card("empty", height: head) { collapsibleStory(empty: true) },
    ]
}()
