import Foundation

// A page's own controls (TP-1497, `docs/design/director-window-and-home.md`, The window: "A page's other controls live
// in the page"): which sidebar page draws a control bar at its top, whether the window's scope is in it, which search
// it holds, and where ⌘F puts the keyboard. How the bar is drawn is `ControlBar` in SymphonyBarUI.

/// A page's search field, in its control bar.
public enum PageSearch: Equatable, CaseIterable {
    /// Tickets' search of the tickets' identifiers and titles.
    case tickets
    /// Shipped's search, on its Learnings tab: ⌘F on Shipped shows the tab.
    case learnings
    /// Audit's search of the records.
    case audit

    /// The View menu's item that puts the keyboard in it.
    public var menuTitle: String {
        switch self {
        case .tickets: "Search Tickets"
        case .learnings: "Search Learnings"
        case .audit: "Search Audit Records"
        }
    }
}

/// What a sidebar page's control bar holds of the window's: the scope pop-up and the page's search. A page with no
/// control of its own (Home, Diagnostics) draws no bar.
public struct PageControls: Equatable {
    /// The page draws a control bar at its top.
    public var hasBar: Bool
    /// The bar holds the scope pop-up (all repos or one): the page's content depends on it, and the page has no repo
    /// control of its own that reads it (Insights' Repo pop-up does, TP-1463).
    public var readsScope: Bool
    /// The page's search in the bar, nil without one.
    public var search: PageSearch?

    public init(hasBar: Bool = false, readsScope: Bool = false, search: PageSearch? = nil) {
        self.hasBar = hasBar
        self.readsScope = readsScope
        self.search = search
    }

    /// No bar: the page has no controls of its own.
    public static let none = PageControls()

    /// The controls of `view`, with Shipped on `shippedTab`.
    ///
    /// - Home has none: it shows every repo, whatever the scope, as two lists and nothing else.
    /// - Journal and Initiatives: the scope; on Journal it is the bar's one repo chooser, before its Epic and Class chips.
    /// - Tickets and Audit: the scope and their search, then Export… at the right on Audit.
    /// - Quality, Usage and Shipped: Insights' one bar, whose Repo pop-up reads the scope (TP-1463); on Shipped it
    ///   holds the Shipped and Learnings switch. Learnings: the switch, the scope as its one repo chooser, and its
    ///   search.
    /// - Setup: Check Again at the right; Setup is Symphony's own, so no scope.
    /// - Diagnostics, Runs (its Save bar holds its own For chooser, TP-1538), Providers (Symphony's own, TP-1534), and
    ///   Settings (its own section list and Save, TP-1575) and Repos (its own window): none.
    public static func of(_ view: SymphonyView, shippedTab: Shipped.Tab = .shipped) -> PageControls {
        switch view {
        case .inbox, .overview, .diagnostics, .repos, .runs, .providers, .settings:
            .none
        case .journal, .initiatives:
            PageControls(hasBar: true, readsScope: true)
        case .tickets:
            PageControls(hasBar: true, readsScope: true, search: .tickets)
        case .audit:
            PageControls(hasBar: true, readsScope: true, search: .audit)
        case .quality, .usage:
            PageControls(hasBar: true)
        case .shipped:
            shippedTab == .learnings
                ? PageControls(hasBar: true, readsScope: true, search: .learnings) : PageControls(hasBar: true, search: .learnings)
        case .setup:
            PageControls(hasBar: true)
        }
    }
}

/// Where ⌘F puts the keyboard: the search of the page shown when it has one (Tickets, Shipped, Audit), else Find a
/// ticket in the window bar, which ⌥⌘F reaches from every page.
public enum FindCommand: Equatable {
    case pageSearch(PageSearch)
    case findTicket

    /// ⌘F on `view`; a ticket's or a pull request's page shown over it (`showsPage`) has no search of its own, and
    /// neither has a page that draws no bar yet (`searchShown` false: Tickets or Audit reading, or asking for an update
    /// of Symphony), so ⌘F there is Find a ticket.
    public static func commandF(
        _ view: SymphonyView, showsPage: Bool, shippedTab: Shipped.Tab = .shipped, searchShown: Bool = true
    ) -> FindCommand {
        guard !showsPage, searchShown, let search = PageControls.of(view, shippedTab: shippedTab).search else { return .findTicket }
        return .pageSearch(search)
    }

    /// The View menu's ⌘F item: "Search Tickets", "Search Learnings", "Search Audit Records" or "Find a Ticket…".
    public var menuTitle: String {
        switch self {
        case let .pageSearch(search): search.menuTitle
        case .findTicket: TicketFinder.menuTitle
        }
    }

    /// The hint Find a ticket shows while it is empty: ⌘F where it is what ⌘F does, ⌥⌘F beside a page's search.
    public var findTicketShortcut: String {
        self == .findTicket ? Self.commandFShortcut : Self.optionCommandFShortcut
    }

    public static let commandFShortcut = "⌘ F"
    public static let optionCommandFShortcut = "⌥ ⌘ F"
}
