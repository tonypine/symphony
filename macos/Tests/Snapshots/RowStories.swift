// The catalog's Row stories (TP-1507), each drawn by the shared `Row` under the id the catalog gives the story
// (`docs/design/catalog/stories.js`), and the tree and the progress strip drawn from the catalog's Home and Initiatives
// data (`PROGRESS`, `QUEUE` and `EPICS` there). The snapshots write `row-<story>-<light|dark>.png`,
// `tree-<name>-<light|dark>.png` and `progress-strip-<name>-<light|dark>.png`; the design sheet's Row page puts each
// Row story beside the catalog's.
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// One of the catalog's `TICKETS`, as its Row stories use it.
struct CatalogTicket {
    let ident: String
    let title: String
    let status: DesignTokens.Status
    let badge: String
    let age: String
    let line2: String
}

let catalogTickets = [
    CatalogTicket(
        ident: "TP-1382", title: "Design system catalog as HTML", status: .you, badge: "Waiting on you", age: "3 h 12 min",
        line2: "Question: review the design catalog"
    ),
    CatalogTicket(
        ident: "TP-1376", title: "A CI-wait pause lifts itself when the commit's CI finishes", status: .working, badge: "Working", age: "14 min",
        line2: "Implementation run 2 · on the tests step"
    ),
    CatalogTicket(
        ident: "TP-1375", title: "A new ticket's first dispatch waits for its relations", status: .problem, badge: "Checks failed", age: "22 min",
        line2: "Two tests failed in the orchestrator"
    ),
]

/// A row story as the catalog's `row()` draws it: the status glyph (or the live dot), the identifier and title, the
/// second line when asked, then the small badge, a fix button (or its reason and the disabled button) and the age.
@MainActor
func rowStory(
    _ ticket: CatalogTicket, state: DesignTokens.Interaction = .rest, twoLines: Bool = false, live: Bool = false,
    windowActive: Bool = true, fix: String? = nil, fixReason: String? = nil
) -> AnyView {
    AnyView(
        Row(
            ticket.title, identifier: ticket.ident, lead: live ? .dot(ticket.status, live: true) : .status(ticket.status),
            line2: twoLines ? ticket.line2 : nil, value: ticket.age, state: state, windowActive: windowActive
        ) {
            Badge(status: ticket.status, word: ticket.badge, size: .small)
            if let fix {
                if let fixReason {
                    RowValue(fixReason)
                    ButtonFace(label: Text(fix), kind: .secondary, size: .small, state: .off, reduceMotion: false).fixedSize()
                } else {
                    ButtonFace(label: Text(fix), kind: .primary, size: .small, state: .rest, reduceMotion: false).fixedSize()
                }
            }
        }
        .frame(width: 640)
    )
}

/// Every Row story, in the catalog's order.
@MainActor
let rowStories: [ComponentStory] = {
    func row(_ id: String, twoLines: Bool = false, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(
            component: "row", id: id, title: "Row", width: 640,
            height: twoLines ? DesignTokens.Row.twoLineHeight : DesignTokens.Row.oneLineHeight, draw: draw
        )
    }
    let working = catalogTickets[1]
    let problem = catalogTickets[2]
    return [
        row("default") { rowStory(working) },
        row("hover") { rowStory(working, state: .hover) },
        row("pressed") { rowStory(working, state: .press) },
        row("selected") { rowStory(working, state: .selection) },
        row("selected-window-not-focused") { rowStory(working, state: .selection, windowActive: false) },
        row("focused") { rowStory(working, state: .focus) },
        row("two-lines", twoLines: true) { rowStory(working, twoLines: true) },
        row("working-live", twoLines: true) { rowStory(working, twoLines: true, live: true) },
        row("with-a-fix", twoLines: true) { rowStory(problem, twoLines: true, fix: "Open Checks") },
        row("fix-disabled-with-reason", twoLines: true) {
            rowStory(problem, twoLines: true, fix: "Run Again", fixReason: "A fix run is already working")
        },
        row("waiting-on-you", twoLines: true) { rowStory(catalogTickets[0], twoLines: true) },
    ]
}()

// MARK: - The tree, from the catalog's Home

/// One ticket of the catalog's Home (`T(…)` in `stories.js`): idle unless it says otherwise.
struct HomeTicket {
    var ident: String
    var title: String
    var status: DesignTokens.Status = .idle
    var live = false
    var badge: String?
    var age: String?
    var fix: String?
    /// The ticket in progress it starts after.
    var after: String?
    var epicName: String?
    /// An epic's parts: each state and how many.
    var parts: [(DesignTokens.Status?, Int)] = []
}

func homeTicket(
    _ ident: String, _ title: String, _ status: DesignTokens.Status = .idle, live: Bool = false, badge: String? = nil,
    age: String? = nil, fix: String? = nil, after: String? = nil, epic: String? = nil, parts: [(DesignTokens.Status?, Int)] = []
) -> HomeTicket {
    HomeTicket(ident: ident, title: title, status: status, live: live, badge: badge, age: age, fix: fix, after: after, epicName: epic, parts: parts)
}

/// The catalog's "In progress": two epics with their tickets under them, then three tickets alone.
let homeProgress: [(HomeTicket, [HomeTicket])] = [
    (homeTicket("SHOP-280", "Checkout that survives a reload", parts: [(.done, 4), (.working, 2), (nil, 3)]), [
        homeTicket("SHOP-305", "Checkout total rounding", .working, live: true, badge: "Coding", age: "14 min"),
        homeTicket("SHOP-301", "Saved carts", .working, badge: "Waiting for CI", age: "6 min"),
    ]),
    (homeTicket("BIL-300", "Annual plans", parts: [(.done, 1), (.you, 1), (.working, 1), (nil, 1)]), [
        homeTicket("BIL-306", "Proration when a plan changes mid-cycle", .you, badge: "Question", age: "3 h 12 min", fix: "Answer"),
        homeTicket("BIL-307", "Invoice PDF shows the plan's period", .working, live: true, badge: "Code Review", age: "4 min"),
    ]),
    (homeTicket("TP-1492", "Symphony tells the Director when a ticket changed", .working, live: true, badge: "QA", age: "9 min"), []),
    (homeTicket("TP-1480", "A poll that changes nothing redraws nothing", .you, badge: "Stopped by you", age: "5 min", fix: "Unblock…"), []),
    (homeTicket("TP-1376", "A CI-wait pause lifts itself when the commit's CI finishes", badge: "Retrying at 16:02", age: "40 min"), []),
]

/// The catalog's queue: who waits on whom.
let homeQueueTickets: [String: HomeTicket] = Dictionary(uniqueKeysWithValues: [
    homeTicket("TP-1481", "A long timeline draws only the rows on screen", after: "TP-1480"),
    homeTicket("TP-1482", "A sheet that puts each native snapshot beside the prototype"),
    homeTicket("TP-1483", "The catalog's type scale, surfaces and elevation in Swift"),
    homeTicket("TP-1493", "Design guard: no raw font, colour or spacing number"),
    homeTicket("TP-1484", "The catalog's panel, zone title and chip as shared components"),
    homeTicket("TP-1485", "Header, moves and window toolbar as designed"),
    homeTicket("TP-1486", "The lifecycle card says where the ticket is in a sentence"),
    homeTicket("TP-1487", "Timeline rows as designed, in a person's words"),
    homeTicket("TP-1488", "The Pull request and Connected cards as designed"),
    homeTicket("SHOP-311", "Gift card balance on the receipt", after: "SHOP-305", epic: "Checkout"),
    homeTicket("SHOP-312", "Gift card as a payment method at checkout", epic: "Checkout"),
    homeTicket("SHOP-314", "Split a payment between a card and a gift card", epic: "Checkout"),
    homeTicket("SHOP-313", "Gift card balance in the account page", epic: "Checkout"),
    homeTicket("BIL-308", "A refund follows the plan's proration", after: "BIL-307", epic: "Annual plans"),
    homeTicket("MOT-93", "Translate Cycle into Brazilian Portuguese, Spanish and German", badge: "Waiting for a slot"),
    homeTicket("MOT-94", "Choose Cycle's language in Settings"),
    homeTicket("MOT-95", "Final verification: Language settings"),
].map { ($0.ident, $0) })

/// A chain: each ticket waits on the one before it.
func chain(_ idents: [String]) -> TreeNode<String> {
    TreeNode(idents[0], children: idents.count > 1 ? [chain(Array(idents.dropFirst()))] : [])
}

let homeQueue: [TreeNode<String>] = [
    chain(["TP-1481", "TP-1482", "TP-1483", "TP-1493", "TP-1484", "TP-1485", "TP-1486", "TP-1487", "TP-1488"]),
    TreeNode("SHOP-311", children: [TreeNode("SHOP-312", children: [TreeNode("SHOP-314")]), TreeNode("SHOP-313")]),
    TreeNode("BIL-308"),
    chain(["MOT-93", "MOT-94", "MOT-95"]),
]

/// The catalog's `homeRow`: the glyph (the live dot, or a clock for one waiting without a badge), the identifier and
/// title, then the ticket it starts after, its epic, its badge, its move and how long, the age in Home's 64 pt column.
@MainActor
func homeRow(_ ticket: HomeTicket, selected: Bool = false, focused: Bool = false) -> some View {
    let lead: RowLead = ticket.live
        ? .dot(.working, live: true)
        : ticket.badge != nil || ticket.status != .idle ? .status(ticket.status) : .glyph("clock", DesignTokens.TextColor.secondary)
    return Row(ticket.title, identifier: ticket.ident, lead: lead, value: ticket.age, valueWidth: 64, selected: selected, focused: focused) {
        if let after = ticket.after {
            HStack(spacing: DesignTokens.Space.s1) {
                Image(systemName: "arrow.right").font(DesignTokens.TypeStyle.caption.font).foregroundStyle(DesignTokens.TextColor.tertiary.color)
                RowValue(after)
            }
            .help("Starts when \(after) lands")
        }
        if let epic = ticket.epicName { Chip(epic, kind: .epic) }
        if let badge = ticket.badge { Badge(status: ticket.status, word: badge, size: .small) }
        if let fix = ticket.fix { ButtonFace(label: Text(fix), kind: .primary, size: .small, state: .rest, reduceMotion: false).fixedSize() }
    }
}

/// The catalog's strip items for an epic's parts.
func stripItems(_ parts: [(DesignTokens.Status?, Int)]) -> [DesignTokens.ProgressStrip.Item] {
    parts.flatMap { part in Array(repeating: DesignTokens.ProgressStrip.Item(part.0, live: part.0 == .working), count: part.1) }
}

/// The catalog's `epicRow`: the epic glyph, its identifier and title, its live strip and "4 of 9".
@MainActor
func homeEpicRow(_ epic: HomeTicket) -> some View {
    let items = stripItems(epic.parts)
    let done = items.filter { $0.status == .done }.count
    return Row(epic.title, identifier: epic.ident, lead: .glyph(SymphonyView.initiatives.symbol, DesignTokens.TextColor.secondary), value: "\(done) of \(items.count)", valueWidth: 64) {
        ProgressStrip(items, label: "\(done) of \(items.count) done").frame(width: DesignTokens.ProgressStrip.compactWidth)
    }
}

/// Home's two lists as trees, 900 pt wide: In progress (epics with their tickets one step in), and the queue folded
/// past two steps unless `opened` names a chain's root, with `selected` picked and the list focused.
@MainActor
func homeTree(opened: Set<String> = [], selected: TreeKey<String>? = nil) -> AnyView {
    let progress = homeProgress.map { TreeNode($0.0.ident, children: $0.1.map { TreeNode($0.ident) }) }
    var progressTickets: [String: HomeTicket] = [:]
    for (epic, tickets) in homeProgress {
        progressTickets[epic.ident] = epic
        for ticket in tickets { progressTickets[ticket.ident] = ticket }
    }
    func title(_ text: String) -> some View {
        Text(text).textStyle(.sentence).padding(.leading, DesignTokens.Space.s3).padding(.bottom, DesignTokens.Space.s3)
    }
    return AnyView(
        VStack(alignment: .leading, spacing: 0) {
            title("In progress")
            TreeList(progress, foldDepth: nil, opened: .constant([]), selection: .constant(nil)) { ident, state in
                let ticket = progressTickets[ident]!
                if ticket.parts.isEmpty { homeRow(ticket, selected: state.selected, focused: state.focused) } else { homeEpicRow(ticket) }
            }
            title("Queue").padding(.top, DesignTokens.Space.s8)
            TreeList(homeQueue, opened: .constant(opened), selection: .constant(selected)) { ident, state in
                homeRow(homeQueueTickets[ident]!, selected: state.selected, focused: state.focused)
            }
        }
        .padding(DesignTokens.Space.s6)
        .frame(width: 900, alignment: .topLeading)
        .background(DesignTokens.Surface.window.color)
    )
}

// MARK: - The progress strip, from the catalog's Initiatives

let catalogEpics: [(ident: String, title: String, parts: [(DesignTokens.Status?, Int)])] = [
    ("TP-1381", "Phase 3b: the Director redesigned around a ticket's situation", [(.done, 3), (.working, 1), (nil, 22)]),
    ("BIL-300", "Annual plans", [(.done, 1), (.you, 1), (nil, 2)]),
    ("SHOP-280", "Checkout that survives a reload", [(.done, 4), (.problem, 1), (.working, 1), (nil, 3)]),
    ("SHOP-500", "Gift cards", [(.done, 3)]),
]

/// The four epics' strips as the Initiatives list draws them (quiet), then Phase 3b's under its title (live, 6 pt),
/// then a 40-ticket epic past 30 segments, its states in proportion.
@MainActor
func progressStrips() -> AnyView {
    let long: [(DesignTokens.Status?, Int)] = [(.done, 18), (.problem, 2), (.you, 1), (.working, 3), (nil, 16)]
    return AnyView(
        VStack(alignment: .leading, spacing: DesignTokens.Space.s5) {
            ForEach(catalogEpics, id: \.ident) { epic in
                let items = stripItems(epic.parts)
                VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                    Text("\(epic.ident) · \(epic.title)").textStyle(.body).foregroundStyle(DesignTokens.TextColor.primary.color)
                    ProgressStrip(items, live: false).frame(width: 300)
                    Text(DesignTokens.ProgressStrip.spoken(items)).textStyle(.secondary).foregroundStyle(DesignTokens.TextColor.secondary.color)
                }
            }
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                Text("Phase 3b, under its title").textStyle(.heading).foregroundStyle(DesignTokens.TextColor.primary.color)
                ProgressStrip(stripItems(catalogEpics[0].parts), height: DesignTokens.ProgressStrip.headerHeight).frame(width: 720)
            }
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                Text("40 sub-tickets: one segment per state, in proportion").textStyle(.heading).foregroundStyle(DesignTokens.TextColor.primary.color)
                ProgressStrip(stripItems(long)).frame(width: 720)
                Text(DesignTokens.ProgressStrip.spoken(stripItems(long))).textStyle(.secondary).foregroundStyle(DesignTokens.TextColor.secondary.color)
            }
        }
        .padding(DesignTokens.Space.s6)
        .frame(width: 800, alignment: .topLeading)
        .background(DesignTokens.Surface.window.color)
    )
}
