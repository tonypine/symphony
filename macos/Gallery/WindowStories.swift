// The window's own bar and its breadcrumb (TP-1496), as the catalog's Window section draws them (`winToolbar` in
// `docs/design/catalog/stories.js`): the bar on Home, on Work with either tab, and on a ticket's page, with Find a
// ticket at rest and with the keyboard; the breadcrumb in each of its forms. The gallery draws each in light and dark.
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// The bar's width in a laptop window beside the sidebar.
let windowBarStoryWidth = CGFloat(DesignTokens.Layout.windowWidth - DesignTokens.Layout.sidebarWidth)

/// The catalog's epic: TP-1381, "Phase 3b: the Director redesigned around a ticket's situation".
let windowStoryEpic = EpicChip(identifier: "TP-1381", title: "Phase 3b: the Director redesigned around a ticket's situation")

/// The breadcrumb on Home, on Work's Tickets, on TP-1382's page with and without its epic, and on a pull request's.
let homeCrumbs = WindowBreadcrumb(place: .view(.overview), shownFrom: .overview)
let workCrumbs = WindowBreadcrumb(place: .view(.tickets), shownFrom: .tickets)
let ticketCrumbs = WindowBreadcrumb(place: .ticket("TP-1382"), shownFrom: .tickets, epic: windowStoryEpic)
let ticketNoEpicCrumbs = WindowBreadcrumb(place: .ticket("TP-1382"), shownFrom: .tickets)
let pullRequestCrumbs = WindowBreadcrumb(place: .pullRequest(PullRequestPlace(repoKey: "symphony", number: 448)), shownFrom: .tickets)

/// A bar story: the bar at `breadcrumb`, Work's switch on `workTab` when given, Find a ticket in `find`'s state.
@MainActor
func windowBarStory(
    _ breadcrumb: WindowBreadcrumb, workTab: SymphonyView? = nil, canGoBack: Bool = false, inboxShown: Bool = false,
    sidebarShown: Bool = true, find: DesignTokens.Field.State? = nil
) -> AnyView {
    let controls = WindowBarControls(
        sidebarShown: sidebarShown, canGoBack: canGoBack, breadcrumb: breadcrumb, inboxCount: 2, inboxShown: inboxShown
    )
    let workSwitch = workTab.map { tab in
        SegmentedControl(
            WindowBarText.workSwitch, selection: .constant(tab), segments: Destination.work.pages.map { Segment($0, $0.title) }, size: .small
        )
    }
    return AnyView(
        WindowBar(controls, actions: WindowBarActions(), findText: .constant(""), findDrawnAs: find, workSwitch: workSwitch) { EmptyView() }
            .frame(width: windowBarStoryWidth)
    )
}

/// Every story of the two entries.
@MainActor
let windowStories: [ComponentStory] = {
    func bar(_ id: String, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(
            component: "window-bar", id: id, title: "Window bar", width: windowBarStoryWidth, height: CGFloat(DesignTokens.WindowBar.height),
            draw: draw
        )
    }
    func crumbs(_ id: String, _ breadcrumb: WindowBreadcrumb, hovered: Int? = nil) -> ComponentStory {
        ComponentStory(component: "breadcrumb", id: id, title: "Breadcrumb", width: 320, height: 24) {
            AnyView(Breadcrumb(breadcrumb, hovered: hovered) { _ in }.fixedSize())
        }
    }
    return [
        bar("home") { windowBarStory(homeCrumbs) },
        bar("home-find-focused") { windowBarStory(homeCrumbs, find: .focused) },
        bar("work-initiatives") { windowBarStory(WindowBreadcrumb(place: .view(.initiatives), shownFrom: .initiatives), workTab: .initiatives) },
        bar("work-tickets") { windowBarStory(workCrumbs, workTab: .tickets, canGoBack: true) },
        bar("work-tickets-find-focused") { windowBarStory(workCrumbs, workTab: .tickets, canGoBack: true, find: .focused) },
        bar("ticket-page") { windowBarStory(ticketCrumbs, canGoBack: true) },
        bar("ticket-page-find-focused") { windowBarStory(ticketCrumbs, canGoBack: true, find: .focused) },
        bar("ticket-page-inbox-open") { windowBarStory(ticketCrumbs, canGoBack: true, inboxShown: true) },
        bar("ticket-page-sidebar-hidden") { windowBarStory(ticketCrumbs, canGoBack: true, sidebarShown: false) },
        crumbs("destination", homeCrumbs),
        crumbs("ticket-page", ticketCrumbs),
        crumbs("ticket-page-link-hover", ticketCrumbs, hovered: 0),
        crumbs("ticket-page-no-epic", ticketNoEpicCrumbs),
        crumbs("pull-request", pullRequestCrumbs),
    ]
}()
