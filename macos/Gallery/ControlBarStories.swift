// The catalog's Control bar (TP-1497, `sections/control-bar` in `docs/design/catalog/stories.js`): the one bar a page
// holds its own controls in, as each page fills it. The catalog's own stories (Laptop, Desktop, Filtered) are Insights'
// bar; then Shipped's with its Shipped and Learnings switch, Learnings', Tickets' (and filtered), Audit's, the
// Journal's, Initiatives' and Setup's (and checking). Home and Diagnostics have none. The gallery draws each in light
// and dark.
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// A page's width in a laptop and in a desktop window beside the sidebar.
let controlBarLaptopWidth = CGFloat(DesignTokens.Layout.windowWidth - DesignTokens.Layout.sidebarWidth)
let controlBarDesktopWidth: CGFloat = 2560 - CGFloat(DesignTokens.Layout.sidebarWidth)

/// The fixtures the bars are drawn from, under the gallery's root.
private let controlBarFixtures = galleryRoot.appendingPathComponent("macos/Tests/Fixtures/director-app")

/// The repos the scope pop-up lists.
private let controlBarRepos = ["symphony", "web-shop"]

/// The scope pop-up as the window gives it to a page, on all repos.
@MainActor
private var controlBarPage: PageBar { PageBar(scope: Binding.constant(OverviewScope.all), repos: controlBarRepos) }

/// Insights' bar: `slice`, and on Shipped its switch.
@MainActor
private func insightsBar(_ slice: InsightsSlice = InsightsSlice(), shipped: Bool = false) -> AnyView {
    let values = InsightsControlValues(repos: controlBarRepos, epics: ["TP-1381", "TP-1450"], slice: slice)
    let summary = "\(slice.title(scope: .all)): 14 shipped, 31M tokens, 52 runs"
    return AnyView(
        InsightsControlBar(
            slice: .constant(slice), values: values, today: "2026-11-12", summary: summary, shippedTab: shipped ? Binding.constant(Shipped.Tab.shipped) : nil
        )
    )
}

/// The Learnings tab's bar over the `shipped` fixture's learnings.
@MainActor
private func learningsBar() -> AnyView {
    let file = controlBarFixtures.appendingPathComponent("shipped/api/v1/learnings.json")
    guard let payload = LearningsPayload.decode(try! Data(contentsOf: file)) else { fatalError("The shipped fixture's learnings don't read") }
    let learnings = Learnings(payload: payload, filter: Learnings.Filter(), scope: .all)
    return AnyView(
        LearningsControlBar(
            learnings: learnings, filter: .constant(Learnings.Filter()), tab: .constant(.learnings), controls: LearningsBarControls(page: controlBarPage)
        )
    )
}

/// Tickets' bar, with `query`'s chips.
@MainActor
private func ticketsBar(_ query: TicketsQuery = TicketsQuery()) -> AnyView {
    AnyView(
        TicketsFilterBar(
            query: .constant(query), catalog: TicketColumn.catalog, values: TicketFilterValues(), count: query.chips.isEmpty ? 9 : 2,
            drawerShown: .constant(false), viewsMenu: TicketViewsMenu(views: [], currentID: nil, query: query),
            controls: TicketsBarControls(page: controlBarPage)
        )
    )
}

/// Audit's bar over the `audit` fixture's records.
@MainActor
private func auditBar() -> AnyView {
    let records = AuditRecord.records(try! Data(contentsOf: controlBarFixtures.appendingPathComponent("audit/api/v1/audit.json")))
    let today = "2026-10-07"
    let audit = Audit(records: records, verification: nil, filter: Audit.Filter(), scope: .all, today: today)
    return AnyView(AuditControlBar(audit: audit, filter: .constant(Audit.Filter()), today: today, controls: AuditBarControls(page: controlBarPage)))
}

/// Every story of the entry.
@MainActor
let controlBarStories: [ComponentStory] = {
    func story(_ id: String, width: CGFloat = controlBarLaptopWidth, height: CGFloat = 64, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "control-bar", id: id, title: "Control bar", width: width, height: height) {
            AnyView(draw().frame(width: width))
        }
    }
    var filtered = InsightsSlice(epic: "TP-1381")
    filtered.repo = "symphony"
    var ticketsFiltered = TicketsQuery()
    ticketsFiltered.toggle(.epic, "TP-1381")
    return [
        story("laptop", height: 96) { insightsBar() },
        story("desktop", width: controlBarDesktopWidth) { insightsBar() },
        story("filtered", height: 128) { insightsBar(filtered) },
        story("shipped", height: 128) { insightsBar(shipped: true) },
        story("learnings") { learningsBar() },
        story("tickets", height: 96) { ticketsBar() },
        story("tickets-filtered", height: 128) { ticketsBar(ticketsFiltered) },
        story("audit") { auditBar() },
        story("journal") {
            AnyView(JournalFilterBar(query: .constant(JournalQuery()), values: JournalFilterValues(repos: controlBarRepos), page: controlBarPage))
        },
        story("initiatives") { AnyView(InitiativesControlBar(bar: controlBarPage)) },
        story("setup") { AnyView(SetupControlBar(checking: false, check: {})) },
        story("setup-checking") { AnyView(SetupControlBar(checking: true, check: {})) },
    ]
}()
