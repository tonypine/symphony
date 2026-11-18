import XCTest
@testable import SymphonyBarCore

final class HomeInboxTests: XCTestCase {
    /// The drawer at the window's opening size folds the sidebar rather than clip it; a wide window keeps both.
    func testTheDrawerFoldsTheSidebarOnlyWhenTheWindowCantHoldAllThree() {
        XCTAssertTrue(HomeInbox.drawerFoldsSidebar(windowWidth: DesignTokens.Layout.windowWidth, drawerShown: true))
        XCTAssertTrue(HomeInbox.drawerFoldsSidebar(windowWidth: DesignTokens.Layout.minWindowWidth, drawerShown: true))
        XCTAssertFalse(HomeInbox.drawerFoldsSidebar(windowWidth: 1400, drawerShown: true))
        XCTAssertFalse(HomeInbox.drawerFoldsSidebar(windowWidth: DesignTokens.Layout.windowWidth, drawerShown: false))
    }

    /// Home and a ticket's page present the drawer; a pull request's page opened from Home doesn't.
    func testOnlyHomeAndATicketPagePresentTheDrawer() {
        XCTAssertTrue(HomeInbox.presentsDrawer(onHome: true, onTicketPage: false))
        XCTAssertTrue(HomeInbox.presentsDrawer(onHome: false, onTicketPage: true))
        XCTAssertFalse(HomeInbox.presentsDrawer(onHome: false, onTicketPage: false))
    }
}
