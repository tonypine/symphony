import Foundation

/// A view of the Symphony window, in sidebar order (`docs/design/director-app-screens.md` §0).
public enum SymphonyView: String, CaseIterable, Equatable {
    case inbox, overview, initiatives, tickets, quality, usage, repos, diagnostics

    public var title: String {
        switch self {
        case .inbox: "Inbox"
        case .overview: "Overview"
        case .initiatives: "Initiatives"
        case .tickets: "Tickets"
        case .quality: "Quality"
        case .usage: "Usage"
        case .repos: "Repos"
        case .diagnostics: "Diagnostics"
        }
    }

    /// The toolbar's line under the title.
    public var subtitle: String {
        switch self {
        case .inbox: "What waits on you"
        case .overview: "The factory at a glance"
        case .initiatives: "Plans and their sub-tickets"
        case .tickets: "Every ticket Symphony sees"
        case .quality: "How far the gate agrees with you"
        case .usage: "Tokens and limits"
        case .repos: "Repositories Symphony works on"
        case .diagnostics: "Symphony's own health"
        }
    }

    /// The SF Symbol in the sidebar (design system §3.9).
    public var symbol: String {
        switch self {
        case .inbox: "tray.full"
        case .overview: "gauge.with.needle"
        case .initiatives: "flag.pattern.checkered"
        case .tickets: "list.bullet.rectangle"
        case .quality: "checkmark.seal"
        case .usage: "chart.bar.xaxis"
        case .repos: "square.stack.3d.up"
        case .diagnostics: "stethoscope"
        }
    }

    public var section: SidebarSection {
        switch self {
        case .inbox, .overview, .initiatives, .tickets: .main
        case .quality, .usage: .insights
        case .repos, .diagnostics: .factory
        }
    }

    /// Repos opens its own window rather than showing in this one.
    public var opensOwnWindow: Bool { self == .repos }
}

/// A group of the sidebar; the first has no heading.
public enum SidebarSection: String, CaseIterable, Equatable {
    case main, insights, factory

    public var title: String? {
        switch self {
        case .main: nil
        case .insights: "Insights"
        case .factory: "Factory"
        }
    }
}

/// The sidebar: only the views built so far, in the design's order, with ⌘1–⌘8 following that order.
public struct Sidebar: Equatable {
    /// The views this version of the app has. Later views join here, in place.
    public static let builtViews: [SymphonyView] = [.repos, .diagnostics]
    public static let maxShortcuts = 8

    public let views: [SymphonyView]

    public init(built: [SymphonyView] = Sidebar.builtViews) {
        views = SymphonyView.allCases.filter(built.contains)
    }

    /// The sections that hold a view, each with its views.
    public var sections: [(section: SidebarSection, views: [SymphonyView])] {
        SidebarSection.allCases.compactMap { section in
            let views = views.filter { $0.section == section }
            return views.isEmpty ? nil : (section, views)
        }
    }

    /// The number of the view's ⌘-shortcut, nil past ⌘8 or for a view not in the sidebar.
    public func shortcut(for view: SymphonyView) -> Int? {
        guard let index = views.firstIndex(of: view), index < Self.maxShortcuts else { return nil }
        return index + 1
    }

    /// The view on ⌘`number`.
    public func view(forShortcut number: Int) -> SymphonyView? {
        guard number >= 1, number <= min(views.count, Self.maxShortcuts) else { return nil }
        return views[number - 1]
    }

    /// The view the window opens on: the saved one while it is in the sidebar and shows in the window, else the
    /// first such view.
    public func restoredView(saved: String?) -> SymphonyView {
        if let saved = saved.flatMap(SymphonyView.init(rawValue:)), views.contains(saved), !saved.opensOwnWindow {
            return saved
        }
        return views.first { !$0.opensOwnWindow } ?? .diagnostics
    }
}

/// What the window shows while Symphony can't serve its views (D0), or `.connected` once it answers.
public enum WindowState: Equatable {
    case connected
    case stopped
    case starting
    case notAnswering
    /// No `symphony.yml` is set or it doesn't exist.
    case firstLaunch

    /// What a button on a placeholder does.
    public enum Action: Equatable {
        case startSymphony, openLogs, restartSymphony, openSettings

        public var title: String {
            switch self {
            case .startSymphony: StatusMenu.startTitle
            case .openLogs: StatusMenu.openLogsTitle
            case .restartSymphony: StatusMenu.restartTitle
            case .openSettings: "Open Settings…"
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
    /// wins: its views show whatever the settings say.
    public init(status: SymphonyStatus, hasConfig: Bool) {
        switch status {
        case .running, .paused:
            self = .connected
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
        case .connected:
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

    /// Badges and counts show only while Symphony answers; otherwise they are unknown, not zero.
    public var countsKnown: Bool { self == .connected }

    /// The connection state (C4) in the toolbar and the sidebar footer; nil while connected, which stays quiet.
    public var connectionLabel: String? {
        switch self {
        case .connected: nil
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
        case .notAnswering: .problem
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
