import Foundation

/// Home's top (TP-1454): every Inbox item above the board, newest first, each answerable in place. A Question is
/// answered with its option cards and the Inbox's consequence sheet; a pause or a hold is released, unblocked or
/// restarted with the Inbox's own moves; Review opens the item's full review in the drawer. An item answered from the
/// app leaves at once, before Symphony's next read drops it.
public struct HomeInbox: Equatable {
    /// What a row offers: the Inbox's commands for its item, then Review, which opens the drawer on it.
    public enum Command: Equatable {
        case inbox(InboxCommand)
        case review

        public var title: String {
            switch self {
            case let .inbox(command): command.title
            case .review: HomeInbox.reviewTitle
            }
        }
    }

    /// One item and what its row offers.
    public struct Row: Equatable, Identifiable {
        public var item: InboxItem
        /// The Inbox's toolbar for the item: its buttons, the first the prominent default, and the ⋯ menu.
        public var toolbar: InboxToolbar
        /// The Director's picks in the item's Question, drawn on its option cards: a pick redraws the row.
        public var picks: DecisionPicks
        public var id: String { item.id }

        public init(item: InboxItem, toolbar: InboxToolbar, picks: DecisionPicks = DecisionPicks()) {
            self.item = item
            self.toolbar = toolbar
            self.picks = picks
        }

        /// True for a request with options: the row draws its Question block, answered in place.
        public var asksInPlace: Bool { item.isDecision && item.review.action != nil }

        /// Every command the row offers, buttons and ⋯ menu, then Review: nothing a person could do from the Inbox is
        /// left out.
        public var commands: [Command] {
            toolbar.buttons.map { .inbox($0.command) } + toolbar.overflow.map(Command.inbox) + [.review]
        }
    }

    public static let title = "Needs you"
    public static let reviewTitle = "Review"
    /// The drawer's title and its toolbar toggle's.
    public static let drawerTitle = "Inbox"
    public static let showDrawerTitle = "Show Inbox"
    public static let hideDrawerTitle = "Hide Inbox"
    public static let openInboxTitle = "Open Inbox"

    public var rows: [Row]
    /// "2 more in other repos", nil when the scope hides nothing.
    public var hiddenLine: String?

    /// `answered` holds the issue ids of the items the Director answered from the app, which leave at once; `picks`
    /// is each item's picks, by issue id, for its cards and its toolbar (Send Decision is off while the write-in is blank).
    public init(
        items: [InboxItem],
        scope: OverviewScope = .all,
        answered: Set<String> = [],
        picks: (String) -> DecisionPicks = { _ in DecisionPicks() }
    ) {
        let list = InboxList(items: items, scope: scope)
        hiddenLine = list.hiddenLine
        rows = items.enumerated()
            .filter { scope.includes($0.element.repoKey) && !answered.contains($0.element.id) }
            // Newest first: the shortest wait first; an item whose wait is unknown goes last, in Symphony's order.
            .sorted { ($0.element.waitingSeconds ?? .max, $0.offset) < ($1.element.waitingSeconds ?? .max, $1.offset) }
            .map { entry in
                let itemPicks = picks(entry.element.id)
                return Row(item: entry.element, toolbar: InboxToolbar.toolbar(for: entry.element, picks: itemPicks), picks: itemPicks)
            }
    }

    public var isEmpty: Bool { rows.isEmpty }

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

    /// The section's heading for VoiceOver: "Needs you, 3".
    public var accessibilityLabel: String { "\(Self.title), \(rows.count)" }
}
