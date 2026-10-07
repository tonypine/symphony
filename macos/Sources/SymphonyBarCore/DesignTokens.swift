import Foundation

/// The design system's tokens (`docs/design/design-system.md` §3) as named roles. Each maps to a system value, so
/// light, dark, Increase Contrast and later system refinements follow by themselves; the SwiftUI mapping is in the
/// app's `DesignSystem.swift`. No color is hardcoded.
public enum DesignTokens {
    /// A system color a token maps to (§3.1, §3.2).
    public enum SystemColor: String, CaseIterable, Equatable {
        case orange, blue, red, green, gray, purple
        case windowBackground, contentBackground, secondaryBackground, separator
        case primary, secondary, tertiary, accent
    }

    /// The reserved status colors (§3.2). Each always ships with its symbol and its word, never color alone.
    public enum Status: String, CaseIterable, Equatable {
        case you, working, problem, done, idle, forced

        public var color: SystemColor {
            switch self {
            case .you: .orange
            case .working: .blue
            case .problem: .red
            case .done: .green
            case .idle: .gray
            case .forced: .purple
            }
        }

        public var symbol: String {
            switch self {
            case .you: "person.crop.circle.badge.exclamationmark"
            case .working: "circle.dotted.circle"
            case .problem: "exclamationmark.triangle.fill"
            case .done: "checkmark.circle.fill"
            case .idle: "pause.circle"
            case .forced: "bolt.fill"
            }
        }

        public var word: String {
            switch self {
            case .you: "Waiting on you"
            case .working: "Working"
            case .problem: "Needs attention"
            case .done: "Healthy"
            case .idle: "Paused"
            case .forced: "Forced"
            }
        }

        /// The badge background's opacity of the status color: 14% in light, 22% in dark.
        public static func badgeTint(dark: Bool) -> Double { dark ? 0.22 : 0.14 }
    }

    /// Surface and text roles (§3.1).
    public enum Surface {
        public static let window = SystemColor.windowBackground
        public static let content = SystemColor.contentBackground
        public static let raised = SystemColor.secondaryBackground
        public static let separator = SystemColor.separator
    }

    /// Text styles (§3.4), each a macOS text style so the system's text size settings apply.
    public enum TypeStyle: String, CaseIterable, Equatable {
        /// `.title2` semibold: the status sentence that opens a view.
        case sentence
        /// 28 pt semibold: stat tile values.
        case figure
        /// `.title3` semibold: section titles in content.
        case section
        /// `.headline`: a row's title.
        case rowTitle
        /// `.body`: text and table cells.
        case body
        /// `.callout`: secondary lines.
        case callout
        /// `.subheadline` medium: badges, labels, column headers.
        case label
        /// `.caption`: footnotes.
        case caption
        /// `.callout` monospaced: paths, commands, ids.
        case mono
    }

    /// The 4 pt spacing grid (§3.5).
    public enum Space {
        public static let s1: Double = 4
        public static let s2: Double = 8
        public static let s3: Double = 12
        public static let s4: Double = 16
        public static let s5: Double = 20
        public static let s6: Double = 24
        public static let s8: Double = 32
    }

    /// Corner radii (§3.6); inner radii are the outer minus the padding between them.
    public enum Radius {
        public static let card: Double = 14
        public static let row: Double = 10
        public static let mark: Double = 4
    }

    /// Motion (§3.8): `motion.standard` lasts this long; values change with a numeric content transition.
    public enum Motion {
        public static let standardDuration: Double = 0.25
    }

    /// The main window's layout (§3.5).
    public enum Layout {
        public static let windowWidth: Double = 1200
        public static let windowHeight: Double = 760
        public static let minWindowWidth: Double = 960
        public static let minWindowHeight: Double = 600
        public static let sidebarWidth: Double = 200
        public static let minSidebarWidth: Double = 180
        public static let maxSidebarWidth: Double = 260
    }
}
