import AppKit
import SwiftUI
import SymphonyBarCore

// The design system's tokens (`DesignTokens`) mapped to system values, and the components the Symphony window
// shares (`docs/design/design-system.md` §5). Nothing here hardcodes a color but the chart palette.

extension DesignTokens.SystemColor {
    public var color: Color {
        switch self {
        case .orange: .orange
        case .blue: .blue
        case .red: .red
        case .green: .green
        case .gray: .gray
        case .purple: .purple
        case .windowBackground: Color(nsColor: .windowBackgroundColor)
        case .contentBackground: Color(nsColor: .controlBackgroundColor)
        case .secondaryBackground: Color(nsColor: .quaternarySystemFill)
        case .separator: Color(nsColor: .separatorColor)
        case .primary: .primary
        case .secondary: .secondary
        case .tertiary: Color(nsColor: .tertiaryLabelColor)
        case .accent: .accentColor
        }
    }
}

extension EnvironmentValues {
    /// True while a view renders offscreen with `ImageRenderer` (the snapshots in `Tests/Snapshots`), which can't
    /// draw an AppKit-backed control: the few that are draw a SwiftUI stand-in of the same size instead.
    @Entry public var offscreenSnapshot = false
}

// The one exception to system colors: the chart palette's validated light and dark pair (§3.3).
extension DesignTokens.ChartSeries {
    /// The series color, its light or dark value following the appearance.
    public var color: Color {
        let (light, dark) = hex
        return Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1
            )
        })
    }
}

extension DesignTokens.Status {
    public var tint: Color { color.color }
}

extension DesignTokens.TypeStyle {
    public var font: Font {
        switch self {
        case .sentence: .title2.weight(.semibold)
        case .figure: .system(size: 28, weight: .semibold)
        case .section: .title3.weight(.semibold)
        case .rowTitle: .headline
        case .body: .body
        case .callout: .callout
        case .label: .subheadline.weight(.medium)
        case .caption: .caption
        case .mono: .system(.callout, design: .monospaced)
        }
    }
}

extension DesignTokens.TypeStyle {
    /// The same style as an AppKit font, for text an AppKit view draws (`ChipText`).
    public var nsFont: NSFont {
        func preferred(_ style: NSFont.TextStyle) -> CGFloat { NSFont.preferredFont(forTextStyle: style).pointSize }
        return switch self {
        case .sentence: .systemFont(ofSize: preferred(.title2), weight: .semibold)
        case .figure: .systemFont(ofSize: 28, weight: .semibold)
        case .section: .systemFont(ofSize: preferred(.title3), weight: .semibold)
        case .rowTitle: .preferredFont(forTextStyle: .headline)
        case .body: .preferredFont(forTextStyle: .body)
        case .callout: .preferredFont(forTextStyle: .callout)
        case .label: .systemFont(ofSize: preferred(.subheadline), weight: .medium)
        case .caption: .preferredFont(forTextStyle: .caption1)
        case .mono: .monospacedSystemFont(ofSize: preferred(.callout), weight: .regular)
        }
    }
}

extension DesignTokens.Motion.Curve {
    /// The curve as a SwiftUI animation; under Reduce Motion, a change of 0.01 s.
    public func animation(reduceMotion: Bool) -> Animation {
        switch timing(reduceMotion: reduceMotion) {
        case let .eased(duration): .smooth(duration: duration)
        case let .spring(duration, bounce): .spring(duration: duration, bounce: bounce)
        }
    }
}

extension Animation {
    /// `motion.standard`: sections appearing or leaving, selection, a fold's height. It follows the system's Reduce
    /// Motion setting, as every curve of `motion` does.
    public static var standard: Animation { .motion(.standard) }

    /// A curve of `motion`, collapsed to 0.01 s while the system's Reduce Motion is on. A view that reads
    /// `accessibilityReduceMotion` passes it instead.
    public static func motion(_ curve: DesignTokens.Motion.Curve, reduceMotion: Bool? = nil) -> Animation {
        curve.animation(reduceMotion: reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

extension DesignTokens.Control {
    /// The SwiftUI control size whose height is closest to this one, for system controls.
    public var controlSize: ControlSize {
        switch self {
        case .small: .small
        case .medium: .regular
        case .large: .large
        }
    }
}

extension DesignTokens.StateSurface {
    public func fill(dark: Bool) -> Color { color.color.opacity(opacity(dark: dark)) }
}

/// C7: a status's symbol and word in a capsule tinted with its color. The word stays in the primary text color, so
/// contrast never depends on the hue.
public struct StatusBadge: View {
    let status: DesignTokens.Status
    var word: String?
    var small = true
    @Environment(\.colorScheme) private var colorScheme

    public init(status: DesignTokens.Status, word: String? = nil, small: Bool = true) {
        self.status = status
        self.word = word
        self.small = small
    }

    public var body: some View {
        Label {
            Text(word ?? status.word).foregroundStyle(.primary)
        } icon: {
            Image(systemName: status.symbol).foregroundStyle(status.tint)
        }
        .font(small ? DesignTokens.TypeStyle.label.font : DesignTokens.TypeStyle.body.font)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, DesignTokens.Space.s2)
        .padding(.vertical, DesignTokens.Space.s1 / 2)
        .background(
            status.tint.opacity(DesignTokens.Status.badgeTint(dark: colorScheme == .dark)),
            in: Capsule()
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(word ?? status.word)
    }
}

/// C4: the connection state, quiet while connected; the time of the last update is in its help.
public struct ConnectionState: View {
    let state: WindowState
    let lastUpdate: Date?

    public init(state: WindowState, lastUpdate: Date?) {
        self.state = state
        self.lastUpdate = lastUpdate
    }

    public var body: some View {
        HStack(spacing: DesignTokens.Space.s1) {
            Circle()
                .fill(state.connectionStatus.tint)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            if let label = state.connectionLabel {
                Text(label).font(DesignTokens.TypeStyle.callout.font).foregroundStyle(.secondary)
            }
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.connectionLabel.map { "Symphony \($0.lowercased())" } ?? "Symphony connected")
    }

    private var help: String {
        guard let lastUpdate else { return state.connectionLabel ?? "Connected" }
        return "Updated \(lastUpdate.formatted(date: .omitted, time: .standard))"
    }
}

/// C10: a titled section on the solid content surface.
public struct Card<Content: View>: View {
    let title: String
    /// A quiet line at the title's trailing end, such as the keys that work in the card.
    var hint: String?
    @ViewBuilder var content: Content

    public init(title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                Text(title)
                    .font(DesignTokens.TypeStyle.section.font)
                    .accessibilityAddTraits(.isHeader)
                    .layoutPriority(1)
                if let hint {
                    Spacer(minLength: DesignTokens.Space.s2)
                    Text(hint)
                        .font(DesignTokens.TypeStyle.callout.font)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            content
        }
        .padding(DesignTokens.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DesignTokens.Surface.content.color,
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                .strokeBorder(DesignTokens.Surface.separator.color)
        )
    }
}

/// A bar pinned at the top of a page over content that fills the rest (TP-1490): a short state under the bar (an empty
/// or unavailable view, a spinner) sits centred in the space below it, and the bar stays under the tabs instead of
/// floating to the middle of the page with the state.
public struct PinnedBarPage<Bar: View, Content: View>: View {
    let bar: Bar
    let content: Content

    public init(@ViewBuilder bar: () -> Bar, @ViewBuilder content: () -> Content) {
        self.bar = bar()
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            bar
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// C20: a symbol, a sentence and its actions, for an empty or unavailable view.
public struct EmptyState: View {
    let title: String
    let symbol: String
    var actions: [(title: String, perform: () -> Void)] = []
    var showsSpinner = false

    public init(title: String, symbol: String, actions: [(title: String, perform: () -> Void)] = [], showsSpinner: Bool = false) {
        self.title = title
        self.symbol = symbol
        self.actions = actions
        self.showsSpinner = showsSpinner
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if showsSpinner { ProgressView().controlSize(.small) }
        } actions: {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                if index == 0 {
                    Button(action.title, action: action.perform).buttonStyle(.borderedProminent)
                } else {
                    Button(action.title, action: action.perform)
                }
            }
        }
    }
}
