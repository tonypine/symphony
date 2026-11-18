import Foundation

/// The Inbox's drawer, presented beside Home and a ticket's page, and the titles of the controls that show it
/// (TP-1454). Home's own "Needs you" rows are gone (TP-1499): what needs a person is the rows carrying a button.
public enum HomeInbox {
    public static let reviewTitle = "Review"
    /// The drawer's title and its toolbar toggle's.
    public static let drawerTitle = "Inbox"
    public static let showDrawerTitle = "Show Inbox"
    public static let hideDrawerTitle = "Hide Inbox"
    public static let openInboxTitle = "Open Inbox"

    /// The drawer's column: its ideal width, and its widest.
    public static let drawerIdealWidth: Double = 460
    public static let drawerMaxWidth: Double = 640
    /// Under this, the page beside the drawer is too narrow to read: Home's rows and their buttons start to clip.
    public static let minPageWidthBesideDrawer: Double = DesignTokens.Layout.narrowReviewWidth

    /// True when the window, `windowWidth` wide, can't hold the sidebar, a readable page and the drawer at once: the
    /// sidebar folds while the drawer is open, rather than being pushed off the window's edge (1200 pt, the size the
    /// window opens at, folds it; 1400 pt keeps it).
    public static func drawerFoldsSidebar(windowWidth: Double, drawerShown: Bool) -> Bool {
        drawerShown && windowWidth - DesignTokens.Layout.sidebarWidth - drawerIdealWidth < minPageWidthBesideDrawer
    }

    /// True where the window presents the drawer: Home, and a ticket's page. A pull request's page, opened from Home,
    /// has none, so it shows no drawer toggle and never folds the sidebar for a drawer it can't draw.
    public static func presentsDrawer(onHome: Bool, onTicketPage: Bool) -> Bool {
        onHome || onTicketPage
    }
}
