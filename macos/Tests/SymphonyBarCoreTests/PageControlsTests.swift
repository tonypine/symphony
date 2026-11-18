import SymphonyBarCore
import XCTest

/// A page's own controls (TP-1497): which page draws a control bar, which holds the window's scope and which its search,
/// and the ⌘F rule: the page's search on Tickets, Shipped and Audit, Find a ticket everywhere else.
final class PageControlsTests: XCTestCase {
    // MARK: - The bar

    func testHomeHasNoControlBarBecauseItHasNoControlsOfItsOwn() {
        XCTAssertEqual(PageControls.of(.overview), .none)
        XCTAssertFalse(PageControls.of(.overview).hasBar)
        XCTAssertEqual(PageControls.of(.inbox), .none, "the Inbox is Home's drawer")
    }

    func testDiagnosticsAndTheWindowsOfTheirOwnHaveNoBar() {
        for view in [SymphonyView.diagnostics, .repos, .settings] {
            XCTAssertEqual(PageControls.of(view), .none, view.rawValue)
        }
    }

    func testTicketsAndAuditHoldTheScopeAndTheirSearch() {
        XCTAssertEqual(PageControls.of(.tickets), PageControls(hasBar: true, readsScope: true, search: .tickets))
        XCTAssertEqual(PageControls.of(.audit), PageControls(hasBar: true, readsScope: true, search: .audit))
    }

    func testJournalAndInitiativesHoldTheScope() {
        for view in [SymphonyView.journal, .initiatives] {
            XCTAssertEqual(PageControls.of(view), PageControls(hasBar: true, readsScope: true), view.rawValue)
        }
    }

    /// Insights' one bar has its own Repo pop-up, which reads the scope (TP-1463): no second scope control.
    func testInsightsKeepsItsOneBarWithNoSecondScope() {
        for view in [SymphonyView.quality, .usage, .shipped] {
            let controls = PageControls.of(view)
            XCTAssertTrue(controls.hasBar, view.rawValue)
            XCTAssertFalse(controls.readsScope, view.rawValue)
        }
        XCTAssertEqual(PageControls.of(.shipped, shippedTab: .learnings), PageControls(hasBar: true, readsScope: true, search: .learnings))
    }

    func testSetupHasABarForCheckAgainAndNoScope() {
        XCTAssertEqual(PageControls.of(.setup), PageControls(hasBar: true))
    }

    /// The scope shows only where the content depends on it: never on Home, Setup or Diagnostics.
    func testTheScopeShowsOnlyOnThePagesThatReadIt() {
        let reading = SymphonyView.allCases.filter { PageControls.of($0).readsScope }
        XCTAssertEqual(reading, [.journal, .initiatives, .tickets, .audit])
    }

    // MARK: - ⌘F

    func testCommandFOnTicketsShippedAndAuditFocusesThePagesSearch() {
        XCTAssertEqual(FindCommand.commandF(.tickets, showsPage: false), .pageSearch(.tickets))
        XCTAssertEqual(FindCommand.commandF(.audit, showsPage: false), .pageSearch(.audit))
        XCTAssertEqual(FindCommand.commandF(.shipped, showsPage: false), .pageSearch(.learnings))
        XCTAssertEqual(FindCommand.commandF(.shipped, showsPage: false, shippedTab: .learnings), .pageSearch(.learnings))
    }

    func testCommandFOnAPageThatDrawsNoSearchYetFocusesFindATicket() {
        // Tickets or Audit reading, or asking for an update of Symphony, draw no bar and so no search.
        XCTAssertEqual(FindCommand.commandF(.tickets, showsPage: false, searchShown: false), .findTicket)
        XCTAssertEqual(FindCommand.commandF(.audit, showsPage: false, searchShown: false), .findTicket)
        XCTAssertEqual(FindCommand.commandF(.audit, showsPage: false, searchShown: false).findTicketShortcut, FindCommand.commandFShortcut)
    }

    func testCommandFElsewhereFocusesFindATicket() {
        for view in SymphonyView.allCases where ![.tickets, .shipped, .audit].contains(view) {
            XCTAssertEqual(FindCommand.commandF(view, showsPage: false), .findTicket, view.rawValue)
        }
    }

    func testCommandFOnATicketsPageFocusesFindATicketWhateverThePageUnder() {
        for view in SymphonyView.allCases {
            XCTAssertEqual(FindCommand.commandF(view, showsPage: true), .findTicket, view.rawValue)
        }
    }

    func testTheMenuItemAndTheFindFieldsHintSayWhatCommandFDoes() {
        XCTAssertEqual(FindCommand.pageSearch(.tickets).menuTitle, "Search Tickets")
        XCTAssertEqual(FindCommand.pageSearch(.learnings).menuTitle, "Search Learnings")
        XCTAssertEqual(FindCommand.pageSearch(.audit).menuTitle, "Search Audit Records")
        XCTAssertEqual(FindCommand.findTicket.menuTitle, TicketFinder.menuTitle)
        XCTAssertEqual(FindCommand.findTicket.findTicketShortcut, "⌘ F")
        XCTAssertEqual(FindCommand.pageSearch(.audit).findTicketShortcut, "⌥ ⌘ F")
    }

    // MARK: - The bar's tokens

    func testTheSummarySitsBesideTheControlsFromADesktopsWidth() {
        XCTAssertFalse(DesignTokens.ControlBar.summaryBeside(width: 1599))
        XCTAssertTrue(DesignTokens.ControlBar.summaryBeside(width: 1600))
        XCTAssertEqual(Insights.summaryBesideWidth, DesignTokens.ControlBar.summaryBesideWidth)
    }
}
