import Foundation

/// A page of the Symphony window, in sidebar order (`docs/design/director-app-screens.md` §0). Each belongs to one of the
/// five destinations (TP-1455).
public enum SymphonyView: String, CaseIterable, Equatable, Hashable, Identifiable {
    /// `overview` is Home (TP-1453); the raw value stays, so the view the window remembers still opens. The Inbox is
    /// Home's drawer (TP-1454): a window that remembers it opens on Home.
    case inbox, overview, journal, initiatives, tickets, quality, usage, shipped, audit, setup, repos, runs, providers, diagnostics, settings

    public var id: String { rawValue }

    /// The page `name` names, by its name (`overview`) or its title (`Home`), whatever the case; nil for a name the
    /// window lacks. QA mode's `SYMPHONY_BAR_QA_OPEN_VIEW` reads it.
    public static func named(_ name: String) -> SymphonyView? {
        let wanted = name.trimmingWhitespace().lowercased()
        return allCases.first { $0.rawValue == wanted || $0.title.lowercased() == wanted }
    }

    public var title: String {
        switch self {
        case .inbox: "Inbox"
        case .overview: "Home"
        case .journal: "Journal"
        case .initiatives: "Initiatives"
        case .tickets: "Tickets"
        case .quality: "Quality"
        case .usage: "Usage"
        case .shipped: "Shipped"
        case .audit: "Audit"
        case .setup: "Setup"
        case .repos: "Repos"
        case .runs: "Runs"
        case .providers: "Providers"
        case .diagnostics: "Diagnostics"
        case .settings: "Settings"
        }
    }

    /// What the page is for, in a line.
    public var subtitle: String {
        switch self {
        case .inbox: "What waits on you"
        case .overview: "Every open ticket, by where it stands"
        case .journal: Journal.explanation
        case .initiatives: "Plans and their sub-tickets"
        case .tickets: "Every ticket Symphony sees"
        case .quality: "How far to trust the crew"
        case .usage: "Tokens and limits"
        case .shipped: "What shipped and what the crew learned"
        case .audit: "Every move on record, hash-chained"
        case .setup: "What's wrong with the setup, and how to fix it"
        case .repos: "Repositories Symphony works on"
        case .runs: "Each kind of run and its fallbacks"
        case .providers: "Who serves the models, and a pause for each"
        case .diagnostics: "Symphony's own health"
        case .settings: "The app's and Symphony's settings"
        }
    }

    /// The SF Symbol in the sidebar (design system §3.9).
    public var symbol: String {
        switch self {
        case .inbox: "tray.full"
        case .overview: "house"
        case .journal: Destination.journal.symbol
        case .initiatives: "flag.pattern.checkered"
        case .tickets: "list.bullet.rectangle"
        case .quality: "checkmark.seal"
        case .usage: "chart.bar.xaxis"
        case .shipped: "shippingbox"
        case .audit: "checklist"
        case .setup: "wrench.and.screwdriver"
        case .repos: "square.stack.3d.up"
        case .runs: "play.square.stack"
        case .providers: "cloud"
        case .diagnostics: "stethoscope"
        case .settings: "gearshape"
        }
    }

    /// The destination it belongs to.
    public var destination: Destination {
        switch self {
        case .inbox, .overview: .home
        case .journal: .journal
        case .initiatives, .tickets: .work
        case .quality, .usage, .shipped, .audit: .insights
        case .setup, .repos, .runs, .providers, .diagnostics, .settings: .factory
        }
    }

    /// Repos opens its own window rather than showing in this one; Settings is a page of this one (TP-1575).
    public var opensOwnWindow: Bool { self == .repos }

    /// Where the window is, as the window bar's breadcrumb names it (TP-1496): a tabbed destination's name, as its tabs
    /// name the page; else the page's.
    public var toolbarTitle: String { destination.presentation == .tabs ? destination.title : title }
}

/// One of the sidebar's five destinations (analysis §6.4), on ⌘1 to ⌘5.
public enum Destination: String, CaseIterable, Equatable, Hashable, Identifiable {
    case home, journal, work, insights, factory

    /// How a destination shows its pages.
    public enum Presentation: Equatable {
        /// One page.
        case single
        /// Its pages as tabs over the page, the first one first.
        case tabs
        /// Its pages listed under it in the sidebar.
        case list
    }

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: "Home"
        case .journal: "Journal"
        case .work: "Work"
        case .insights: "Insights"
        case .factory: "Factory"
        }
    }

    public var symbol: String {
        switch self {
        case .home: SymphonyView.overview.symbol
        case .journal: "book.pages"
        case .work: "square.grid.2x2"
        case .insights: "chart.line.uptrend.xyaxis"
        case .factory: "building.2"
        }
    }

    /// Its pages, in order: the first is where it opens.
    public var pages: [SymphonyView] {
        switch self {
        case .home: [.overview]
        case .journal: [.journal]
        case .work: [.initiatives, .tickets]
        case .insights: [.quality, .usage, .shipped, .audit]
        case .factory: [.setup, .repos, .runs, .providers, .diagnostics, .settings]
        }
    }

    public var presentation: Presentation {
        switch self {
        case .home, .journal: .single
        case .work, .insights: .tabs
        case .factory: .list
        }
    }

    /// The number of its ⌘-shortcut.
    public var shortcut: Int { Self.allCases.firstIndex(of: self)! + 1 }

    /// "Work (⌘3)": the sidebar row's help and the View menu's item.
    public var shortcutHelp: String { "\(title) (⌘\(shortcut))" }

    /// The page it opens on first: its first one that shows in the window.
    public var firstPage: SymphonyView { pages.first { !$0.opensOwnWindow }! }

    /// C1's badge (TP-1455): Home's what waits on the Director in `status.you`, Work's epics waiting on a person
    /// (TP-1458) in `status.you`, Factory's setup problems in `status.problem`; no other destination has one, and a
    /// count of 0 hides it.
    public func badge(waitingOnYou: Int, setup: SetupSummary, epicsWaiting: Int = 0) -> DestinationBadge? {
        switch self {
        case .home where waitingOnYou > 0:
            DestinationBadge(count: waitingOnYou, status: .you, accessibilityValue: "\(waitingOnYou) waiting")
        case .work where epicsWaiting > 0:
            DestinationBadge(
                count: epicsWaiting, status: .you,
                accessibilityValue: "\(epicsWaiting) \(epicsWaiting == 1 ? "epic" : "epics") waiting on you"
            )
        case .factory where setup.errors + setup.warnings > 0:
            DestinationBadge(
                count: setup.errors + setup.warnings, status: .problem,
                accessibilityValue: "Setup: " + SetupSummary.counts(errors: setup.errors, warnings: setup.warnings)
            )
        default:
            nil
        }
    }
}

/// A destination's count in the sidebar, in its status colour.
public struct DestinationBadge: Equatable {
    public var count: Int
    public var status: DesignTokens.Status
    public var accessibilityValue: String

    /// The same count from Symphony's last answer while it is late (TP-1562): idle grey, and read as such.
    public var notCurrent: DestinationBadge {
        DestinationBadge(count: count, status: .idle, accessibilityValue: "\(accessibilityValue), \(HealthLine.notCurrentWords)")
    }
}

/// A row of the sidebar: a destination, or a page Factory lists under it.
public enum SidebarItem: Hashable {
    case destination(Destination)
    case page(SymphonyView)
}

/// The Journal (TP-1459): what it holds, as its subtitle says. One line within the toolbar title's width (design
/// system: at most 260 pt), so it reads whole (TP-1489).
public enum Journal {
    public static let explanation = "What happened while you were away"
}

/// The sidebar: the five destinations in the design's order, Factory with its pages under it (TP-1455).
public struct SidebarRows: Equatable {
    public init() {}

    public var destinations: [Destination] { Destination.allCases }

    /// The View menu's destination items, in order: ⌘1–⌘5 pick them.
    public var menuItems: [DestinationMenuItem] {
        destinations.map { DestinationMenuItem(title: $0.title, keyEquivalent: String($0.shortcut), destination: $0) }
    }

    /// The rows in order: each destination, and under Factory its pages.
    public var items: [SidebarItem] {
        destinations.flatMap { destination in
            [.destination(destination)] + (destination.presentation == .list ? destination.pages.map(SidebarItem.page) : [])
        }
    }

    /// The row selected while `view` shows: Factory's page itself, else its destination.
    public func item(for view: SymphonyView) -> SidebarItem {
        view.destination.presentation == .list ? .page(view) : .destination(view.destination)
    }

    /// The view the window opens on: the saved one while it shows in the window, Home for the Inbox, else Home.
    public func restoredView(saved: String?) -> SymphonyView {
        guard let saved = saved.flatMap(SymphonyView.init(rawValue:)), !saved.opensOwnWindow, saved != .inbox else {
            return .overview
        }
        return saved
    }
}

/// A View menu item that picks a destination on ⌘ and its key.
public struct DestinationMenuItem: Equatable {
    public let title: String
    public let keyEquivalent: String
    public let destination: Destination

    public init(title: String, keyEquivalent: String, destination: Destination) {
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.destination = destination
    }
}

/// Each destination's last page this session, so Work and Insights open on the tab left last (TP-1455).
public struct DestinationMemory: Equatable {
    private var last: [Destination: SymphonyView] = [:]

    public init() {}

    /// The window shows `view`; a page that opens its own window is never left on.
    public mutating func remember(_ view: SymphonyView) {
        guard !view.opensOwnWindow else { return }
        last[view.destination] = view
    }

    /// Where `destination` opens: the page shown last this session, else its first.
    public func page(for destination: Destination) -> SymphonyView {
        last[destination] ?? destination.firstPage
    }
}

/// What the window shows while Symphony can't serve its views (D0), or `.connected` once it answers.
public enum WindowState: Equatable {
    case connected
    /// Symphony is alive but its last state isn't current (TP-1562): it hasn't answered its state for a while, or
    /// answered one the app couldn't read. The pages stay, drawn from the last answer, and the status line says why.
    case lagging(String)
    case stopped
    case starting
    case notAnswering
    /// No `symphony.yml` is set or it doesn't exist.
    case firstLaunch

    /// What a button on a placeholder does.
    public enum Action: Equatable {
        case startSymphony, openLogs, restartSymphony, openSettings
        /// The app's update check, from Setup's older-service state and its build warning.
        case checkForUpdates
        /// The menu's Cancel Update and Update Now Anyway, from the dispatch control's popover (S3a, S3b).
        case cancelUpdate, updateNow

        public var title: String {
            switch self {
            case .startSymphony: StatusMenu.startTitle
            case .openLogs: StatusMenu.openLogsTitle
            case .restartSymphony: StatusMenu.restartTitle
            case .openSettings: "Open Settings…"
            case .checkForUpdates: UpdateMenu.checkTitle
            case .cancelUpdate: UpdateMenu.cancelUpdateTitle
            case .updateNow: UpdateMenu.updateNowTitle
            }
        }
    }

    /// The one placeholder every view shows in this state.
    public struct Placeholder: Equatable {
        public var title: String
        public var symbol: String
        public var actions: [Action]
        public var showsSpinner: Bool
    }

    /// `hasConfig` is false while no `symphony.yml` is set or the one set doesn't exist. A Symphony that answers
    /// wins: its views show whatever the settings say. `lag` is the status machine's: why the state shown isn't
    /// current, nil while it is.
    public init(status: SymphonyStatus, hasConfig: Bool, lag: String? = nil) {
        switch status {
        case .running, .paused:
            self = lag.map(WindowState.lagging) ?? .connected
        case .starting:
            self = .starting
        case .stopped:
            self = hasConfig ? .stopped : .firstLaunch
        case .error:
            self = hasConfig ? .notAnswering : .firstLaunch
        }
    }

    public var placeholder: Placeholder? {
        switch self {
        case .connected, .lagging:
            return nil
        case .stopped:
            return Placeholder(title: "Symphony is stopped.", symbol: "stop.circle", actions: [.startSymphony], showsSpinner: false)
        case .starting:
            return Placeholder(title: "Symphony is starting…", symbol: "hourglass", actions: [], showsSpinner: true)
        case .notAnswering:
            return Placeholder(
                title: "Symphony isn't answering.",
                symbol: DesignTokens.Status.problem.symbol,
                actions: [.openLogs, .restartSymphony],
                showsSpinner: false
            )
        case .firstLaunch:
            return Placeholder(
                title: "Symphony doesn't know where its config is.",
                symbol: "doc.badge.gearshape",
                actions: [.openSettings],
                showsSpinner: false
            )
        }
    }

    /// True while the window shows Symphony's pages: it answers, or answered and is only late (TP-1562).
    public var servesPages: Bool {
        switch self {
        case .connected, .lagging: true
        case .stopped, .starting, .notAnswering, .firstLaunch: false
        }
    }

    /// Badges and counts show while the pages do, with their last values while Symphony is late; otherwise they are
    /// unknown, not zero.
    public var countsKnown: Bool { servesPages }

    /// False while the badges and counts show Symphony's last answer rather than a current one: they are marked so.
    public var countsCurrent: Bool { self == .connected }

    /// What the status line offers while Symphony is late: the placeholder's actions, there instead of over the pages.
    public var lineActions: [Action] {
        if case .lagging = self { return [.openLogs, .restartSymphony] }
        return []
    }

    /// The connection state (C4) in the status bar's health line; nil while connected.
    public var connectionLabel: String? {
        switch self {
        case .connected: nil
        case let .lagging(reason): reason
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .notAnswering: "Not answering"
        case .firstLaunch: "Not set up"
        }
    }

    /// The status token behind the connection state's dot.
    public var connectionStatus: DesignTokens.Status {
        switch self {
        case .connected: .done
        case .stopped, .firstLaunch: .idle
        case .starting: .working
        case .lagging, .notAnswering: .problem
        }
    }

    /// The sidebar footer's state word.
    public func stateWord(paused: Bool) -> String {
        guard self == .connected else { return connectionLabel ?? "" }
        return paused ? "Paused" : "Running"
    }

    /// Whether `symphony.yml` is set and exists.
    public static func hasConfig(path: String) -> Bool {
        let path = (path.trimmingWhitespace() as NSString).expandingTildeInPath
        return !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }
}

/// What a view shows when Symphony's API can't serve it.
public enum EndpointPlaceholder {
    /// For a view whose endpoint answers 404: the Symphony running predates it.
    public static let updateSymphony = "Update Symphony to see this view."
    public static let updateSymbol = "arrow.down.circle"
}
