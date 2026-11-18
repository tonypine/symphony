import Foundation

// The window's own bar (TP-1496, `docs/design/director-window-and-home.md`, The window, Toolbar): what it says and
// where its parts go, apart from how it is drawn (`WindowBar` and `Breadcrumb` in SymphonyBarUI).

/// Where a part of the breadcrumb goes when it is clicked.
public enum CrumbTarget: Hashable {
    /// A page of the sidebar: the one the ticket page was opened from.
    case view(SymphonyView)
    /// Initiatives, on the epic of this identifier.
    case initiative(String)
}

/// One part of the breadcrumb: its words, its glyph when it has one (the epic's), and where it goes. The last part is
/// where the window is, and goes nowhere.
public struct Crumb: Hashable {
    public var title: String
    public var symbol: String?
    public var target: CrumbTarget?
    /// What VoiceOver and the help read when it differs from the words: the epic's whole title.
    public var help: String?

    public init(_ title: String, symbol: String? = nil, target: CrumbTarget? = nil, help: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.target = target
        self.help = help
    }
}

/// The breadcrumb: where the window is, never the page's title. On a page of the sidebar it is the destination's
/// name ("Home", "Work"; a Factory page's own name, "Setup"). On a ticket's page it is the destination it was opened
/// from, the epic's short name when the ticket has one, and the ticket's identifier: "Work › Phase 3b › TP-1382". On a
/// pull request's page it is the destination and the pull request's number: "Work › #448".
public struct WindowBreadcrumb: Equatable {
    public var crumbs: [Crumb]

    public init(crumbs: [Crumb]) {
        self.crumbs = crumbs
    }

    /// The breadcrumb at `place`, over the sidebar's page `shownFrom` (a page pushed over a view keeps it), with the
    /// ticket's `epic` when its page knows one.
    public init(place: WindowPlace, shownFrom: SymphonyView, epic: EpicChip? = nil) {
        let origin = Crumb(shownFrom.toolbarTitle, target: .view(shownFrom))
        switch place {
        case let .view(view):
            crumbs = [Crumb(view.toolbarTitle)]
        case let .ticket(identifier):
            let epicCrumb = epic.map {
                Crumb($0.shortName, symbol: DesignTokens.Breadcrumb.epicSymbol, target: .initiative($0.identifier), help: $0.fullTitle)
            }
            crumbs = [origin] + [epicCrumb].compactMap { $0 } + [Crumb(identifier)]
        case let .pullRequest(pullRequest):
            crumbs = [origin, Crumb("#\(pullRequest.number)", help: "Pull request \(pullRequest.repoKey)#\(pullRequest.number)")]
        }
    }

    /// Where the window is: the last part's words.
    public var here: String { crumbs.last?.title ?? "" }

    /// What VoiceOver reads for the whole: "Work, Phase 3b, TP-1382".
    public var spoken: String { crumbs.map { $0.help ?? $0.title }.joined(separator: ", ") }

    /// The breadcrumb's name for VoiceOver.
    public static let accessibilityLabel = "Where you are"
}

/// The window bar's words: each control's help, which is also what VoiceOver reads.
public enum WindowBarText {
    public static let toolbarLabel = "Toolbar"
    public static let hideSidebar = "Hide the sidebar"
    public static let showSidebar = "Show the sidebar"
    public static let back = "Back (⌘[)"
    public static let forward = "Forward (⌘])"
    public static let findPlaceholder = "Find a ticket"
    public static let findShortcut = "⌘ F"
    /// The same on every page; on Setup ⌘R also runs Check Again, which is in Setup's own bar (TP-1497).
    public static let refresh = "Refresh (⌘R)"
    /// Check Again's help, in Setup's control bar.
    public static let checkAgain = "Check Again (⌘R)"
    /// Work's switch, for VoiceOver.
    public static let workSwitch = "Work shows"

    /// The sidebar toggle's help: what pressing it does.
    public static func sidebar(shown: Bool) -> String { shown ? hideSidebar : showSidebar }

    /// The Inbox's help: "Inbox: 2 need you (⇧⌘I)", "Inbox (⇧⌘I)" with nothing waiting.
    public static func inbox(needYou count: Int) -> String {
        count > 0 ? "Inbox: \(count) need\(count == 1 ? "s" : "") you (⇧⌘I)" : "Inbox (⇧⌘I)"
    }
}

/// What a double-click on the bar does, as it does on a title bar: the system's choice in Desktop & Dock ("Double-click
/// a window's title bar to"), read from the global `AppleActionOnDoubleClick` default.
public enum TitleBarDoubleClick: Equatable {
    case zoom, minimize, nothing

    /// The global default's key.
    public static let preferenceKey = "AppleActionOnDoubleClick"

    /// The action for the default's value: "Minimize", "None", else zoom (the system's own default, "Maximize" or
    /// "Fill").
    public static func action(preference: String?) -> TitleBarDoubleClick {
        switch preference {
        case "Minimize": .minimize
        case "None": .nothing
        default: .zoom
        }
    }
}
