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

// MARK: - The sidebar and the status line (TP-1498)

// The catalog's window sidebar and status line (`winSidebar`, `winStatus`, `dispatchControl`): the sidebar expanded and
// folded to its glyphs, in a front window and behind one, with a row under the pointer, pressed and with the keyboard;
// the status line with dispatch on, paused, its menu open, without Home's read and with Symphony stopped. While
// Symphony is late (TP-1562) the sidebar's counts are its last answer's, in idle grey, and the status line says it
// isn't answering, with its last counts in the tertiary colour and Open Logs and Restart Symphony.

/// The sidebar's rows as the window fills them: Home with two that need the Director, Factory with two problems,
/// marked not current while Symphony is late.
@MainActor
func sidebarStoryEntries(waiting: Int = 2, problems: Int = 2, current: Bool = true) -> [SidebarEntry<SidebarItem>] {
    SymphonySidebar.entries(SidebarRows().items) { destination in
        let badge = destination.badge(waitingOnYou: waiting, setup: SetupSummary(errors: problems))
        return current ? badge : badge?.notCurrent
    }
}

/// The sidebar's height: the window buttons' room, then every row.
let sidebarStoryHeight: CGFloat = {
    let tokens = DesignTokens.Sidebar.self
    let rows = Double(SidebarRows().items.count)
    return CGFloat(tokens.topInset + rows * tokens.rowHeight + (rows - 1) * tokens.rowGap + 2 * tokens.inset)
}()

/// A sidebar story: Work current, `drawn` naming a row's state.
@MainActor
func sidebarStory(
    collapsed: Bool = false, windowActive: Bool = true, drawn: [SidebarItem: DesignTokens.Interaction] = [:], waiting: Int = 2,
    problems: Int = 2, countsCurrent: Bool = true
) -> AnyView {
    AnyView(
        Sidebar(
            sidebarStoryEntries(waiting: waiting, problems: problems, current: countsCurrent), current: .destination(.work),
            collapsed: collapsed,
            windowActive: windowActive, drawn: drawn
        ) { _ in }
            .frame(height: sidebarStoryHeight)
            .windowBackdrop()
    )
}

/// The status line's width in a laptop window beside the sidebar.
let statusLineStoryWidth = windowBarStoryWidth

/// A status line story: dispatch on or paused, its control in `face`, with Home's counts unless `counts` is nil.
@MainActor
func statusLineStory(
    window: WindowState = .connected, paused: Bool = false, face: DesignTokens.Interaction? = nil, open: Bool = false,
    counts: HealthLine.Counts? = HealthLine.Counts(inProgress: 7, queued: 18, needYou: 2)
) -> AnyView {
    let now = Date(timeIntervalSince1970: 1_794_000_000)
    let control = DispatchControl(window: window, paused: paused, state: nil, now: now)
    let line = HealthLine(
        window: window, dispatch: control, build: DiagnosticsPayload.Build(version: "0.0.1.926", sha: "a0be0aa5c1d2e3f4"),
        appVersion: "0.0.1.926", lastUpdate: now, counts: window.countsKnown ? counts : nil, timeZone: TimeZone(identifier: "UTC")!
    )
    return AnyView(
        StatusLine(line) { DispatchStatusControl(control, open: open, drawnAs: face) {} }
            .frame(width: statusLineStoryWidth)
            .windowBackdrop()
    )
}

/// Every story of the sidebar and the status line.
@MainActor
let sidebarStatusStories: [ComponentStory] = {
    func side(_ id: String, collapsed: Bool = false, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(
            component: "sidebar", id: id, title: "Sidebar", width: CGFloat(DesignTokens.Sidebar.width(collapsed: collapsed)),
            height: sidebarStoryHeight, draw: draw
        )
    }
    func line(_ id: String, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(
            component: "status-line", id: id, title: "Status line", width: statusLineStoryWidth, height: CGFloat(DesignTokens.StatusLine.height),
            draw: draw
        )
    }
    return [
        side("expanded") { sidebarStory() },
        side("expanded-row-hover") { sidebarStory(drawn: [.destination(.journal): .hover]) },
        side("expanded-row-pressed") { sidebarStory(drawn: [.destination(.journal): .press]) },
        side("expanded-row-keyboard-focus") { sidebarStory(drawn: [.destination(.insights): .focus]) },
        side("expanded-window-not-focused") { sidebarStory(windowActive: false) },
        side("expanded-no-counts") { sidebarStory(waiting: 0, problems: 0) },
        side("collapsed", collapsed: true) { sidebarStory(collapsed: true) },
        side("collapsed-window-not-focused", collapsed: true) { sidebarStory(collapsed: true, windowActive: false) },
        side("expanded-symphony-late") { sidebarStory(countsCurrent: false) },
        side("collapsed-symphony-late", collapsed: true) { sidebarStory(collapsed: true, countsCurrent: false) },
        line("dispatch-on") { statusLineStory() },
        line("dispatch-on-hover") { statusLineStory(face: .hover) },
        line("dispatch-on-menu-open") { statusLineStory(open: true) },
        line("dispatch-on-keyboard-focus") { statusLineStory(face: .focus) },
        line("dispatch-paused") { statusLineStory(paused: true) },
        line("without-home-read") { statusLineStory(counts: nil) },
        line("symphony-stopped") { statusLineStory(window: .stopped) },
        line("symphony-late") { statusLineStory(window: .lagging("\(StatusMachine.notAnsweringTitle) · 25 s")) },
        line("symphony-late-paused") { statusLineStory(window: .lagging("\(StatusMachine.notAnsweringTitle) · 25 s"), paused: true) },
    ]
}()
