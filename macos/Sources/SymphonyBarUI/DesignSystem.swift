import AppKit
import SwiftUI
import SymphonyBarCore

// The design system's tokens (`DesignTokens`, the catalog's `tokens.css` values) in SwiftUI and AppKit, and the
// components the Symphony window shares (`docs/design/design-system.md` §5).

extension DesignTokens.RGBA {
    public var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: CGFloat(alpha))
    }
}

extension DesignTokens.Appearances {
    /// The appearances a token tells apart: light and dark, each also with Increase Contrast on.
    public static let appearanceNames: [NSAppearance.Name] = [
        .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
    ]

    /// The value for an AppKit appearance: light or dark, and the Increase Contrast value under the high-contrast
    /// appearances.
    public func value(for appearance: NSAppearance) -> DesignTokens.RGBA {
        value(matching: appearance.bestMatch(from: Self.appearanceNames) ?? .aqua)
    }

    /// The value for one of `appearanceNames`.
    public func value(matching name: NSAppearance.Name) -> DesignTokens.RGBA {
        let dark = name == .darkAqua || name == .accessibilityHighContrastDarkAqua
        let increased = name == .accessibilityHighContrastAqua || name == .accessibilityHighContrastDarkAqua
        return value(dark: dark, increaseContrast: increased)
    }

    /// A dynamic colour that resolves for the appearance it is drawn in.
    public var nsColor: NSColor {
        NSColor(name: nil) { appearance in value(for: appearance).nsColor }
    }
}

extension DesignTokens.ColorPair {
    /// A dynamic colour: its light or dark value following the appearance.
    public var color: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return value(dark: dark).nsColor
        })
    }
}

extension DesignTokens.ColorToken {
    /// One dynamic colour per token, made once, so a token's colour is the same colour wherever it is read.
    private static let nsColors = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.values.nsColor) })

    /// The token as a dynamic AppKit colour, for text an AppKit view draws.
    public var nsColor: NSColor { Self.nsColors[self] ?? values.nsColor }

    /// The token as a SwiftUI colour: light, dark and their Increase Contrast values follow the appearance.
    public var color: Color { Color(nsColor: nsColor) }
}

extension EnvironmentValues {
    /// True while a view renders offscreen with `ImageRenderer` (the snapshots in `Tests/Snapshots`), which can't
    /// draw an AppKit-backed control: the few that are draw a SwiftUI stand-in of the same size instead.
    @Entry public var offscreenSnapshot = false
}

// The chart palette's validated light and dark pair (§3.3); the catalog's tokens have no chart colours yet.
extension DesignTokens.ChartSeries {
    /// The series color, its light or dark value following the appearance.
    public var color: Color {
        let (light, dark) = hex
        return DesignTokens.ColorPair(.init(hex: light), .init(hex: dark)).color
    }
}

extension DesignTokens.Status {
    /// `--status-*`: the glyph and the mark.
    public var tint: Color { color.color }
    /// `--tint-*`: a badge's background.
    public var badgeFill: Color { tintColor.color }
    /// `--status-*-text`: the word in the status's colour.
    public var text: Color { textColor.color }
}

extension DesignTokens.TypeStyle {
    /// The system's text size over its default: the preferred body font's size over 13 pt. It is 1 unless the
    /// Director changed the text size in System Settings, and every style scales by it.
    public static var textScale: Double { Double(NSFont.preferredFont(forTextStyle: .body).pointSize) / 13 }

    /// The style as an AppKit font, at the catalog's size and weight under the system's text size.
    public var nsFont: NSFont { nsFont(scale: Self.textScale) }

    public func nsFont(scale: Double) -> NSFont {
        let size = CGFloat(scaledSize(by: scale))
        let weight = NSFont.Weight(rawValue: CGFloat(systemWeight))
        return switch family {
        case .mono: .monospacedSystemFont(ofSize: size, weight: weight)
        case .text, .display: .systemFont(ofSize: size, weight: weight)
        }
    }

    /// The style as a SwiftUI font. The line height and tracking are the view's: `textStyle(_:)` sets all three.
    public var font: Font { Font(nsFont as CTFont) }
}

extension View {
    /// Sets a text style whole: its font, its line height and its tracking, at the system's text size.
    public func textStyle(_ style: DesignTokens.TypeStyle) -> some View {
        let scale = DesignTokens.TypeStyle.textScale
        return font(style.font)
            .lineHeight(.exact(points: CGFloat(style.scaledLineHeight(by: scale))))
            .tracking(CGFloat(style.tracking * style.scaledSize(by: scale)))
    }
}

extension DesignTokens.Measure {
    /// `characters` of the "0" of `style`'s font, in points: CSS `ch`.
    public static func width(_ characters: Int = DesignTokens.Measure.characters, for style: DesignTokens.TypeStyle = .body) -> Double {
        let font = style.nsFont
        let zero = ("0" as NSString).size(withAttributes: [.font: font]).width
        return Double(characters) * Double(zero)
    }

    /// `--measure` in body text: reading text never runs past it.
    public static var reading: Double { width() }
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
    public var fill: Color { color.color }
}

/// `--surface-window` with `--backdrop-glow`: what the window draws behind every page. Increase Contrast drops the
/// glow.
public struct WindowBackdrop: View {
    @Environment(\.colorSchemeContrast) private var contrast

    public init() {}

    public var body: some View {
        let glows = DesignTokens.Backdrop.glows(increaseContrast: contrast == .increased)
        DesignTokens.Backdrop.surface.color
            .overlay {
                Canvas { context, size in
                    for glow in glows { Self.draw(glow, in: &context, size: size) }
                }
                .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }

    /// One `radial-gradient(W H at X Y, color, transparent fade)`: a circle gradient squashed to the ellipse.
    static func draw(_ glow: DesignTokens.Backdrop.Glow, in context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: glow.centerX * size.width, y: glow.centerY * size.height)
        let radius = glow.width
        var layer = context
        layer.translateBy(x: center.x, y: center.y)
        layer.scaleBy(x: 1, y: glow.height / glow.width)
        let color = glow.color.color
        let reach = CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)
        layer.fill(
            Path(ellipseIn: reach),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: color, location: 0),
                    .init(color: color.opacity(0), location: glow.fade),
                ]),
                center: .zero, startRadius: 0, endRadius: radius
            )
        )
    }
}

extension View {
    /// The window's backdrop (`WindowBackdrop`) behind this view.
    public func windowBackdrop() -> some View { background { WindowBackdrop() } }

    /// `--elevation-N` around `shape`: the hairline ring, then the near and far shadows.
    public func elevation<S: Shape>(_ level: DesignTokens.Elevation, in shape: S) -> some View {
        modifier(ElevationModifier(level: level, shape: shape))
    }

    /// `--edge-highlight` inside `shape`: a line along its top edge.
    public func edgeHighlight<S: Shape>(_ shape: S) -> some View {
        let shadow = DesignTokens.Elevation.edgeHighlight
        return overlay {
            shape.subtracting(shape.offset(x: shadow.x, y: shadow.y))
                .fill(shadow.color.color)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Glass behind this view in `shape`, or its solid surface while Reduce Transparency is on.
    public func glassBackground<S: Shape>(_ glass: DesignTokens.Glass = .thick, in shape: S) -> some View {
        modifier(GlassModifier(glass: glass, shape: shape))
    }
}

struct ElevationModifier<S: Shape>: ViewModifier {
    let level: DesignTokens.Elevation
    let shape: S

    func body(content: Content) -> some View {
        let shadows = level.shadows
        content
            .background {
                ZStack {
                    // CSS blurs a shadow over its blur radius; SwiftUI's radius is about half of it.
                    ForEach(Array(shadows.dropFirst().enumerated()), id: \.offset) { _, shadow in
                        shape.fill(DesignTokens.Surface.content.color)
                            .shadow(color: shadow.color.color, radius: shadow.blur / 2, x: shadow.x, y: shadow.y)
                    }
                    if let ring = shadows.first {
                        shape.stroke(ring.color.color, lineWidth: ring.spread * 2)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

struct GlassModifier<S: Shape>: ViewModifier {
    let glass: DesignTokens.Glass
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background {
            let fill = glass.drawn(reduceTransparency: reduceTransparency).color
            if reduceTransparency {
                shape.fill(fill)
            } else {
                shape.fill(fill)
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.stroke(DesignTokens.Glass.edge.color, lineWidth: 1))
            }
        }
    }
}

/// C7: a status's symbol and word in a capsule tinted with its color. The word stays in the primary text color, so
/// contrast never depends on the hue.
public struct StatusBadge: View {
    let status: DesignTokens.Status
    var word: String?
    var small = true

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
        .background(status.badgeFill, in: Capsule())
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
                Text(label).font(DesignTokens.TypeStyle.secondary.font).foregroundStyle(.secondary)
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
                    .font(DesignTokens.TypeStyle.heading.font)
                    .accessibilityAddTraits(.isHeader)
                    .layoutPriority(1)
                if let hint {
                    Spacer(minLength: DesignTokens.Space.s2)
                    Text(hint)
                        .font(DesignTokens.TypeStyle.secondary.font)
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
