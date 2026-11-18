import SymphonyBarCore
import XCTest

/// The window's own bar (TP-1496): its breadcrumb says where the window is, never the page's title; each part but the
/// last goes to its place as a visit, so Back returns; its controls' words; a double-click does what one on a title bar
/// does.
final class WindowBarTests: XCTestCase {
    private let epic = EpicChip(identifier: "TP-1381", title: "Phase 3b: the Director redesigned around a ticket's situation")

    // MARK: - The breadcrumb

    func testOnASidebarPageTheBreadcrumbIsTheDestinationsNameAndGoesNowhere() {
        let cases: [(SymphonyView, String)] = [
            (.overview, "Home"), (.journal, "Journal"), (.initiatives, "Work"), (.tickets, "Work"), (.usage, "Insights"),
            (.audit, "Insights"), (.setup, "Setup"), (.diagnostics, "Diagnostics"),
        ]
        for (view, place) in cases {
            let breadcrumb = WindowBreadcrumb(place: .view(view), shownFrom: view)
            XCTAssertEqual(breadcrumb.crumbs, [Crumb(place)], view.rawValue)
            XCTAssertEqual(breadcrumb.here, place)
        }
    }

    func testOnATicketPageItIsWhereItWasOpenedFromTheEpicsShortNameAndTheWholeIdentifier() {
        let breadcrumb = WindowBreadcrumb(place: .ticket("TP-1382"), shownFrom: .tickets, epic: epic)
        XCTAssertEqual(breadcrumb.crumbs.map(\.title), ["Work", "Phase 3b", "TP-1382"])
        XCTAssertEqual(breadcrumb.crumbs.map(\.target), [.view(.tickets), .initiative("TP-1381"), nil])
        XCTAssertEqual(breadcrumb.crumbs[1].symbol, DesignTokens.Breadcrumb.epicSymbol)
        XCTAssertEqual(breadcrumb.crumbs[1].help, "Epic TP-1381: Phase 3b: the Director redesigned around a ticket's situation")
        XCTAssertEqual(breadcrumb.here, "TP-1382")
        XCTAssertEqual(breadcrumb.spoken, "Work, Epic TP-1381: Phase 3b: the Director redesigned around a ticket's situation, TP-1382")
    }

    func testATicketWithoutAnEpicHasNoEpicPartAndHomeIsItsOriginWhenOpenedFromHome() {
        XCTAssertEqual(WindowBreadcrumb(place: .ticket("TP-1382"), shownFrom: .tickets).crumbs.map(\.title), ["Work", "TP-1382"])
        let fromHome = WindowBreadcrumb(place: .ticket("TP-1382"), shownFrom: .overview)
        XCTAssertEqual(fromHome.crumbs, [Crumb("Home", target: .view(.overview)), Crumb("TP-1382")])
    }

    func testOnAPullRequestsPageItIsWhereItWasOpenedFromAndItsNumber() {
        let breadcrumb = WindowBreadcrumb(place: .pullRequest(PullRequestPlace(repoKey: "symphony", number: 448)), shownFrom: .initiatives)
        XCTAssertEqual(breadcrumb.crumbs.map(\.title), ["Work", "#448"])
        XCTAssertEqual(breadcrumb.crumbs.map(\.target), [.view(.initiatives), nil])
        XCTAssertEqual(breadcrumb.spoken, "Work, Pull request symphony#448")
    }

    /// The walkthrough: Work, then a ticket from Tickets; a click on "Work" is back on Work; ⌘[ is on the ticket again.
    func testClickingWorkInTheBreadcrumbIsBackOnWorkAndBackReturnsToTheTicket() throws {
        var history = NavigationHistory(current: .view(.overview))
        history.visit(.view(.tickets))
        history.visit(.ticket("TP-1382"))
        let onTicket = WindowBreadcrumb(place: history.current, shownFrom: .tickets, epic: epic)
        XCTAssertEqual(onTicket.crumbs.map(\.title), ["Work", "Phase 3b", "TP-1382"])

        guard case let .view(view)? = onTicket.crumbs.first?.target else { return XCTFail("Work is not a link") }
        history.visit(.view(view))
        XCTAssertEqual(history.current, .view(.tickets))
        XCTAssertEqual(WindowBreadcrumb(place: history.current, shownFrom: view).crumbs.map(\.title), ["Work"])

        XCTAssertEqual(history.goBack(), .ticket("TP-1382"))
        XCTAssertEqual(WindowBreadcrumb(place: history.current, shownFrom: view, epic: epic).here, "TP-1382")
        XCTAssertTrue(history.canGoForward)
    }

    // MARK: - The bar's words and measures

    func testEachControlSaysWhatItDoesWithItsShortcut() {
        XCTAssertEqual(WindowBarText.sidebar(shown: true), "Hide the sidebar")
        XCTAssertEqual(WindowBarText.sidebar(shown: false), "Show the sidebar")
        XCTAssertEqual(WindowBarText.back, "Back (⌘[)")
        XCTAssertEqual(WindowBarText.forward, "Forward (⌘])")
        XCTAssertEqual(WindowBarText.inbox(needYou: 0), "Inbox (⇧⌘I)")
        XCTAssertEqual(WindowBarText.inbox(needYou: 1), "Inbox: 1 needs you (⇧⌘I)")
        XCTAssertEqual(WindowBarText.inbox(needYou: 2), "Inbox: 2 need you (⇧⌘I)")
        XCTAssertEqual(WindowBarText.refresh, "Refresh (⌘R)")
        XCTAssertEqual(WindowBarText.checkAgain, "Check Again (⌘R)")
        XCTAssertEqual(WindowBarText.findPlaceholder, "Find a ticket")
    }

    func testTheBarIsTheCatalogs() {
        XCTAssertEqual(DesignTokens.WindowBar.height, 44)
        XCTAssertEqual(DesignTokens.WindowBar.searchWidth, 232)
        XCTAssertEqual(DesignTokens.WindowBar.leadingPadding, DesignTokens.Space.s3)
        XCTAssertEqual(DesignTokens.WindowBar.trailingPadding, DesignTokens.Space.s4)
        XCTAssertEqual(DesignTokens.WindowBar.glass, .glass)
        XCTAssertEqual(DesignTokens.Breadcrumb.gap, 6)
        XCTAssertEqual(DesignTokens.Breadcrumb.chevron, 10)
    }

    func testWithTheSidebarFoldedTheBarsFirstControlStartsAfterTheWindowsButtons() {
        XCTAssertEqual(DesignTokens.WindowBar.leading(sidebarShown: true), DesignTokens.Space.s3)
        // Close, minimize and zoom span 8 to 70 pt from the window's edge; beside the 60 pt folded sidebar, the sidebar
        // toggle starts 8 pt past them.
        XCTAssertEqual(DesignTokens.WindowBar.leading(sidebarShown: false), 18)
        XCTAssertGreaterThan(
            DesignTokens.Sidebar.collapsedWidth + DesignTokens.WindowBar.leading(sidebarShown: false), DesignTokens.WindowBar.windowButtonsEnd
        )
    }

    // MARK: - A double-click on the bar

    func testADoubleClickDoesWhatTheSystemSaysOneOnATitleBarDoes() {
        XCTAssertEqual(TitleBarDoubleClick.action(preference: nil), .zoom)
        XCTAssertEqual(TitleBarDoubleClick.action(preference: "Maximize"), .zoom)
        XCTAssertEqual(TitleBarDoubleClick.action(preference: "Fill"), .zoom)
        XCTAssertEqual(TitleBarDoubleClick.action(preference: "Minimize"), .minimize)
        XCTAssertEqual(TitleBarDoubleClick.action(preference: "None"), .nothing)
        XCTAssertEqual(TitleBarDoubleClick.preferenceKey, "AppleActionOnDoubleClick")
    }
}
