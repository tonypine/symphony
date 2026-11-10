import Foundation

/// The design system's tokens (`docs/design/design-system.md` §3) as named roles. Each maps to a system value, so
/// light, dark, Increase Contrast and later system refinements follow by themselves; the SwiftUI mapping is in the
/// app's `DesignSystem.swift`. No color is hardcoded but the chart palette, which the design validates as a pair.
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

    /// The categorical chart palette (§3.3), in its fixed order: a series keeps its color whatever else a chart
    /// shows, and never takes a status color. Light and dark values are the design's validated pair.
    public enum ChartSeries: Int, CaseIterable, Equatable {
        case series1 = 1, series2, series3, series4

        /// The light and dark values as `0xRRGGBB`.
        public var hex: (light: UInt32, dark: UInt32) {
            switch self {
            case .series1: (0x007AFF, 0x3D86F5)
            case .series2: (0xE07800, 0xCC780A)
            case .series3: (0xAF52DE, 0xAE5ADF)
            case .series4: (0x1A9BB0, 0x2A9FB4)
            }
        }
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

    /// The reading measure (§3.4, `--measure`): reading text never runs past 68 characters, about 480 pt of body
    /// text. A situation's cause wraps there.
    public enum Measure {
        public static let characters = 68
        public static let reading: Double = 480
    }

    /// Corner radii (§3.6); inner radii are the outer minus the padding between them.
    public enum Radius {
        public static let card: Double = 14
        public static let row: Double = 10
        public static let mark: Double = 4
    }

    /// N1, a ticket or pull request chip inside text: `accent` behind the mention's characters.
    public enum Chip {
        public static let tint: Double = 0.14
        public static let hoverTint: Double = 0.26
        public static let radius: Double = 6
        /// The tint's room on each side of the characters.
        public static let padding: Double = 4
        /// How long the pointer rests on a chip before its popover opens.
        public static let hoverDelay: Double = 0.5
    }

    /// Motion (§3.8 and `director-ticket-page.md` §4): the durations, the curves built from them, and the press and
    /// lift patterns. With Reduce Motion on, every curve lasts `reducedDuration`, presses don't scale and nothing
    /// lifts.
    public enum Motion {
        /// `motion.instant`: a press settling.
        public static let instantDuration: Double = 0.1
        /// `motion.fast`: a surface changing under the pointer.
        public static let fastDuration: Double = 0.16
        /// `motion.standard`: sections appearing or leaving, selection, a fold's height.
        public static let standardDuration: Double = 0.28
        /// `motion.slow`: an entry dropping into the timeline, a Question leaving.
        public static let slowDuration: Double = 0.45
        /// `motion.spring`: the fold's chevron, the decision sheet, a lift.
        public static let springDuration: Double = 0.5
        /// The spring's overshoot (about 2 %).
        public static let springBounce: Double = 0.1
        /// `motion.stagger`: between the rows that fade into an opened fold.
        public static let stagger: Double = 0.035
        /// Every duration under Reduce Motion.
        public static let reducedDuration: Double = 0.01
        /// What a pressed button settles to.
        public static let pressScale: Double = 0.97
        /// What a pressed card or option card settles to.
        public static let cardPressScale: Double = 0.99
        /// What a pressed row settles to.
        public static let rowPressScale: Double = 0.995
        /// How far a hovered clickable card rises, in points.
        public static let lift: Double = 1

        /// How a curve moves: an eased change of a duration, or a spring of a duration and a bounce.
        public enum Timing: Equatable {
            case eased(duration: Double)
            case spring(duration: Double, bounce: Double)
        }

        /// The curves every animation of the Director is one of.
        public enum Curve: String, CaseIterable, Equatable {
            /// `motion.instant`, eased: a press.
            case instant
            /// `motion.fast`, eased: hover and pressed surfaces.
            case fast
            /// `motion.standard`, eased: a section appearing, a selection, a fold's height.
            case standard
            /// `motion.slow`, eased.
            case slow
            /// The fold's spring: the chevron turning.
            case fold
            /// The decision sheet sliding in and out.
            case sheet
            /// A clickable card or option card lifting.
            case lift

            /// The curve's timing; under Reduce Motion, an eased change of `reducedDuration`.
            public func timing(reduceMotion: Bool) -> Timing {
                if reduceMotion { return .eased(duration: Motion.reducedDuration) }
                return switch self {
                case .instant: .eased(duration: Motion.instantDuration)
                case .fast: .eased(duration: Motion.fastDuration)
                case .standard: .eased(duration: Motion.standardDuration)
                case .slow: .eased(duration: Motion.slowDuration)
                case .fold, .sheet: .spring(duration: Motion.springDuration, bounce: Motion.springBounce)
                case .lift: .spring(duration: Motion.standardDuration, bounce: Motion.springBounce)
                }
            }
        }

        /// The delay of the `index`th row fading into an opened fold; none under Reduce Motion.
        public static func staggerDelay(_ index: Int, reduceMotion: Bool) -> Double {
            reduceMotion ? 0 : Double(max(index, 0)) * stagger
        }

        /// The scale `pressed` gives a control that settles to `scale`; under Reduce Motion, none.
        public static func scale(_ scale: Double, pressed: Bool, reduceMotion: Bool) -> Double {
            pressed && !reduceMotion ? scale : 1
        }

        /// How far a hovered clickable card rises; under Reduce Motion, nothing lifts.
        public static func lift(hovered: Bool, reduceMotion: Bool) -> Double {
            hovered && !reduceMotion ? lift : 0
        }
    }

    /// The three control heights (catalog `--control-*`): every button, pop-up and field is one of them, its corner
    /// radius concentric with the card around it.
    public enum Control: String, CaseIterable, Equatable {
        case small, medium, large

        public var height: Double {
            switch self {
            case .small: 24
            case .medium: 30
            case .large: 36
            }
        }

        public var radius: Double {
            switch self {
            case .small: 7
            case .medium: 9
            case .large: 11
            }
        }

        /// The room on each side of the label.
        public var padding: Double {
            switch self {
            case .small: 10
            case .medium: 14
            case .large: 18
            }
        }

        /// The label's size in points.
        public var fontSize: Double {
            switch self {
            case .small: 12
            case .medium: 13
            case .large: 14
            }
        }
    }

    /// What a control, row or card shows: under the pointer, pressed, selected, focused from the keyboard, or
    /// disabled. More than one can be true at once.
    public struct Interaction: Equatable {
        public var hovered: Bool
        public var pressed: Bool
        public var selected: Bool
        public var focused: Bool
        public var disabled: Bool

        public init(hovered: Bool = false, pressed: Bool = false, selected: Bool = false, focused: Bool = false, disabled: Bool = false) {
            self.hovered = hovered
            self.pressed = pressed
            self.selected = selected
            self.focused = focused
            self.disabled = disabled
        }

        public static let rest = Interaction()
        public static let hover = Interaction(hovered: true)
        public static let press = Interaction(hovered: true, pressed: true)
        public static let selection = Interaction(selected: true)
        public static let focus = Interaction(focused: true)
        public static let off = Interaction(disabled: true)

        /// The surface the state lays over whatever is under it: a disabled control takes none, pressed wins over
        /// selected, and selected over hover.
        public var surface: StateSurface? {
            if disabled { return nil }
            if pressed { return .pressed }
            if selected { return .selected }
            if hovered { return .hover }
            return nil
        }

        /// Whether the selection's accent ring is drawn.
        public var showsSelectionRing: Bool { selected && !disabled }

        /// Whether the focus ring is drawn: keyboard focus, on anything that isn't disabled.
        public var showsFocusRing: Bool { focused && !disabled }
    }

    /// The translucent surfaces a state lays over the surface under it (catalog `--surface-hover`,
    /// `--surface-pressed`, `--accent-tint`): the primary text color, or the accent for a selection, at a low opacity.
    public enum StateSurface: String, CaseIterable, Equatable {
        case hover, pressed, selected

        public var color: SystemColor {
            switch self {
            case .hover, .pressed: .primary
            case .selected: .accent
            }
        }

        public func opacity(dark: Bool) -> Double {
            switch self {
            case .hover: dark ? 0.06 : 0.05
            case .pressed: dark ? 0.1 : 0.09
            case .selected: dark ? 0.18 : 0.1
            }
        }
    }

    /// A selection's ring: the accent, around a selected row or card.
    public enum Selection {
        public static let color = SystemColor.accent
        public static let rowRingWidth: Double = 1.5
        public static let cardRingWidth: Double = 2
    }

    /// The focus ring (§3.10): the accent at about half strength, outside the shape and following its corners, drawn
    /// only for keyboard focus.
    public enum FocusRing {
        public static let color = SystemColor.accent
        public static let width: Double = 2
        /// The gap between the shape and the ring; a row's ring sits on its edge.
        public static let offset: Double = 2
        public static func opacity(dark: Bool) -> Double { dark ? 0.7 : 0.55 }
    }

    /// The situation a ticket is in (`director-ticket-page.md` §3): exactly one at a time, said with its glyph, its
    /// word and its status color, never color alone. The cases are in the order that picks one when several are true.
    public enum SituationKind: String, CaseIterable, Equatable {
        case you, retrying, blocked, paused, ci, build, slot, working, done, cancelled

        /// Where it ranks when more than one is true: the lowest wins.
        public var precedence: Int { Self.allCases.firstIndex(of: self) ?? 0 }

        /// The one shown of several that are true; nil when none is.
        public static func shown(_ kinds: some Sequence<SituationKind>) -> SituationKind? {
            kinds.min { $0.precedence < $1.precedence }
        }

        public var status: Status {
            switch self {
            case .working, .ci, .build: .working
            case .slot, .blocked, .paused, .cancelled: .idle
            case .you: .you
            case .retrying: .problem
            case .done: .done
            }
        }

        /// The SF Symbol: a dashed circle for work and CI, a clock for a slot, a box for a build, a person with a
        /// mark, a lock, a pause, an arrow round, a filled tick, a slashed circle.
        public var symbol: String {
            switch self {
            case .working, .ci: "circle.dotted.circle"
            case .slot: "clock"
            case .build: "shippingbox"
            case .you: "person.crop.circle.badge.exclamationmark"
            case .blocked: "lock.fill"
            case .paused: "pause.circle"
            case .retrying: "arrow.clockwise"
            case .done: "checkmark.circle.fill"
            case .cancelled: "circle.slash"
            }
        }

        /// The word when the line has nothing more specific (the step's name, the blocking ticket).
        public var word: String {
            switch self {
            case .working: "Working"
            case .slot: "Waiting for a slot"
            case .ci: "Waiting for CI"
            case .build: "Waiting for a build"
            case .you: "Waiting on you"
            case .blocked: "Blocked"
            case .paused: "Paused"
            case .retrying: "Retrying"
            case .done: "Shipped"
            case .cancelled: "Cancelled"
            }
        }
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
        /// The toolbar's title and subtitle at most, each on one line cut at the end. The widest view's (Setup's) is
        /// about 240 pt; a pull request's title (D15) runs past 400, which would push the window's own toolbar items
        /// into its overflow menu. The page's header shows the title whole.
        public static let toolbarTitleMaxWidth: Double = 260
        /// The list column of the Inbox (and later Initiatives).
        public static let listColumnWidth: Double = 340
        public static let minListColumnWidth: Double = 300
        public static let maxListColumnWidth: Double = 420
        /// Under this width the Inbox's review is a narrow pane: an option card's Recommended badge moves under its
        /// label, and the key hints hide.
        public static let narrowReviewWidth: Double = 560
    }
}
