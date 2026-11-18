import Foundation

/// The design system's tokens (`docs/design/design-system.md` §3): the catalog's values (`docs/design/catalog/tokens.css`)
/// carried into the app as they are. Each colour has its light and dark value and an Increase Contrast pair; type,
/// surfaces, elevation, radii and the measure are the catalog's numbers. `DesignTokensCatalogTests` parses
/// `tokens.css` and fails when a value here and there differ, so the two never drift. The SwiftUI mapping is in the
/// app's `DesignSystem.swift`.
public enum DesignTokens {
    /// A colour in sRGB: 8-bit channels and an alpha.
    public struct RGBA: Equatable, Hashable, CustomStringConvertible {
        public var red: UInt8
        public var green: UInt8
        public var blue: UInt8
        public var alpha: Double

        public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        /// An opaque colour from `0xRRGGBB`.
        public init(hex: UInt32) {
            self.init(UInt8(hex >> 16 & 0xFF), UInt8(hex >> 8 & 0xFF), UInt8(hex & 0xFF))
        }

        public var description: String { "rgba(\(red), \(green), \(blue), \(alpha))" }

        /// This colour laid over an opaque `background`.
        public func over(_ background: RGBA) -> RGBA {
            func mix(_ top: UInt8, _ bottom: UInt8) -> UInt8 {
                UInt8((Double(top) * alpha + Double(bottom) * (1 - alpha)).rounded())
            }
            return RGBA(mix(red, background.red), mix(green, background.green), mix(blue, background.blue))
        }

        /// The WCAG relative luminance of the opaque colour.
        public var luminance: Double {
            func linear(_ channel: UInt8) -> Double {
                let value = Double(channel) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        /// The WCAG contrast ratio of this colour, laid over `background`, against it.
        public func contrast(on background: RGBA) -> Double {
            let (a, b) = (over(background).luminance, background.luminance)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
    }

    /// A light and a dark value (CSS `light-dark()`).
    public struct ColorPair: Equatable {
        public var light: RGBA
        public var dark: RGBA

        public init(_ light: RGBA, _ dark: RGBA) {
            self.light = light
            self.dark = dark
        }

        public func value(dark: Bool) -> RGBA { dark ? self.dark : light }
    }

    /// A colour's values in each appearance: light and dark, and both again with Increase Contrast on
    /// (`tokens.css`'s `@media (prefers-contrast: more)`).
    public struct Appearances: Equatable {
        public var standard: ColorPair
        public var increased: ColorPair

        public init(_ standard: ColorPair, increased: ColorPair) {
            self.standard = standard
            self.increased = increased
        }

        public func value(dark: Bool, increaseContrast: Bool) -> RGBA {
            (increaseContrast ? increased : standard).value(dark: dark)
        }
    }

    /// Every colour of the catalog, named as in `tokens.css` (the raw value, without its `--`). Each has a light and a
    /// dark value, and an Increase Contrast value of each that keeps text at the contrast rule (§6).
    public enum ColorToken: String, CaseIterable, Equatable {
        case surfaceWindow = "surface-window"
        case surfaceContent = "surface-content"
        case surfaceRaised = "surface-raised"
        case surfaceSunken = "surface-sunken"
        case surfaceHover = "surface-hover"
        case surfacePressed = "surface-pressed"
        case surfaceOverlay = "surface-overlay"
        case materialGlass = "material-glass"
        case materialGlassThick = "material-glass-thick"
        case materialEdge = "material-edge"
        case strokeSeparator = "stroke-separator"
        case strokeStrong = "stroke-strong"
        case strokeHighlight = "stroke-highlight"
        case textPrimary = "text-primary"
        case textSecondary = "text-secondary"
        case textTertiary = "text-tertiary"
        case textOnAccent = "text-on-accent"
        case accent
        case accentHover = "accent-hover"
        case accentPressed = "accent-pressed"
        case accentText = "accent-text"
        case accentTint = "accent-tint"
        case accentTintStrong = "accent-tint-strong"
        case statusYou = "status-you"
        case statusWorking = "status-working"
        case statusProblem = "status-problem"
        case statusDone = "status-done"
        case statusIdle = "status-idle"
        case statusForced = "status-forced"
        case statusYouText = "status-you-text"
        case statusWorkingText = "status-working-text"
        case statusProblemText = "status-problem-text"
        case statusDoneText = "status-done-text"
        case statusIdleText = "status-idle-text"
        case statusForcedText = "status-forced-text"
        case tintYou = "tint-you"
        case tintWorking = "tint-working"
        case tintProblem = "tint-problem"
        case tintDone = "tint-done"
        case tintIdle = "tint-idle"
        case tintForced = "tint-forced"
        case shadowRing = "shadow-ring"
        case shadowNear = "shadow-near"
        case shadowFar = "shadow-far"
        case shadowDeep = "shadow-deep"
        case focusRing = "focus-ring-color"

        /// The custom property's name in `tokens.css`.
        public var cssName: String { "--" + rawValue }

        public var values: Appearances {
            func h(_ hex: UInt32) -> RGBA { RGBA(hex: hex) }
            func c(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: Double) -> RGBA { RGBA(r, g, b, a) }
            func v(_ light: RGBA, _ dark: RGBA, _ lightMore: RGBA, _ darkMore: RGBA) -> Appearances {
                Appearances(ColorPair(light, dark), increased: ColorPair(lightMore, darkMore))
            }
            return switch self {
            case .surfaceWindow: v(h(0xF2F2F6), h(0x121216), h(0xECECF2), h(0x0A0A0D))
            case .surfaceContent: v(h(0xFFFFFF), h(0x1B1B21), h(0xFFFFFF), h(0x16161B))
            case .surfaceRaised: v(h(0xF7F7FA), h(0x23232A), h(0xF4F4F8), h(0x202027))
            case .surfaceSunken: v(h(0xE9E9EF), h(0x0C0C10), h(0xDCDCE4), h(0x000000))
            case .surfaceHover: v(c(28, 28, 52, 0.05), c(255, 255, 255, 0.06), c(28, 28, 52, 0.1), c(255, 255, 255, 0.12))
            case .surfacePressed: v(c(28, 28, 52, 0.09), c(255, 255, 255, 0.1), c(28, 28, 52, 0.16), c(255, 255, 255, 0.18))
            case .surfaceOverlay: v(c(18, 18, 30, 0.22), c(0, 0, 0, 0.55), c(18, 18, 30, 0.4), c(0, 0, 0, 0.75))
            case .materialGlass: v(c(255, 255, 255, 0.72), c(38, 38, 46, 0.68), c(255, 255, 255, 0.96), c(30, 30, 38, 0.96))
            case .materialGlassThick: v(c(252, 252, 254, 0.88), c(34, 34, 42, 0.86), c(252, 252, 254, 0.98), c(28, 28, 36, 0.98))
            case .materialEdge: v(c(255, 255, 255, 0.85), c(255, 255, 255, 0.1), c(24, 24, 48, 0.35), c(255, 255, 255, 0.35))
            case .strokeSeparator: v(c(24, 24, 48, 0.08), c(255, 255, 255, 0.08), c(24, 24, 48, 0.45), c(255, 255, 255, 0.45))
            case .strokeStrong: v(c(24, 24, 48, 0.15), c(255, 255, 255, 0.15), c(24, 24, 48, 0.7), c(255, 255, 255, 0.7))
            case .strokeHighlight: v(c(255, 255, 255, 0.95), c(255, 255, 255, 0.07), c(255, 255, 255, 1), c(255, 255, 255, 0.16))
            case .textPrimary: v(h(0x16161D), h(0xF2F2F6), h(0x000000), h(0xFFFFFF))
            case .textSecondary: v(h(0x5C5C6E), h(0xA5A5B4), h(0x3C3C4A), h(0xCFCFD9))
            case .textTertiary: v(h(0x9898A8), h(0x6C6C7C), h(0x5C5C6C), h(0xA0A0AE))
            case .textOnAccent: v(h(0xFFFFFF), h(0xFFFFFF), h(0xFFFFFF), h(0xFFFFFF))
            case .accent: v(h(0x5B4CF5), h(0x6D5FF7), h(0x3A2BC4), h(0x5546E0))
            case .accentHover: v(h(0x4F40EA), h(0x7C70FF), h(0x3123B0), h(0x6457EE))
            case .accentPressed: v(h(0x4234D0), h(0x5E51E6), h(0x281C96), h(0x4A3CD0))
            case .accentText: v(h(0x4A3BE0), h(0xAAA2FF), h(0x3020B8), h(0xC4BEFF))
            case .accentTint: v(c(91, 76, 245, 0.1), c(124, 112, 255, 0.18), c(58, 43, 196, 0.16), c(124, 112, 255, 0.3))
            case .accentTintStrong: v(c(91, 76, 245, 0.17), c(124, 112, 255, 0.28), c(58, 43, 196, 0.26), c(124, 112, 255, 0.42))
            case .statusYou: v(h(0xF08A00), h(0xFFA733), h(0xC46A00), h(0xFFBB5C))
            case .statusWorking: v(h(0x1D8CFF), h(0x3D9FFF), h(0x0A6FD6), h(0x6CB6FF))
            case .statusProblem: v(h(0xEC3A4C), h(0xFF5C68), h(0xD01F33), h(0xFF7F89))
            case .statusDone: v(h(0x18A957), h(0x3BD47C), h(0x0B8A43), h(0x5FE397))
            case .statusIdle: v(h(0x8A8A99), h(0x8F8F9E), h(0x6B6B7A), h(0xB0B0BE))
            case .statusForced: v(h(0xBE3BD6), h(0xD567EE), h(0x9E22B8), h(0xE48CF6))
            case .statusYouText: v(h(0xA35200), h(0xFFBF6E), h(0x7F3F00), h(0xFFD29A))
            case .statusWorkingText: v(h(0x0A63C4), h(0x80BFFF), h(0x054A96), h(0xA8D3FF))
            case .statusProblemText: v(h(0xC0142B), h(0xFF8F96), h(0x980F22), h(0xFFB3B8))
            case .statusDoneText: v(h(0x0F733A), h(0x74E3A3), h(0x0A5A2D), h(0x9CF0C0))
            case .statusIdleText: v(h(0x5B5B6A), h(0xB3B3C0), h(0x45454F), h(0xD0D0DA))
            case .statusForcedText: v(h(0x8C1FA4), h(0xE7A0F6), h(0x6E1683), h(0xF0C2FA))
            case .tintYou: v(c(240, 138, 0, 0.13), c(255, 167, 51, 0.2), c(196, 106, 0, 0.2), c(255, 187, 92, 0.3))
            case .tintWorking: v(c(29, 140, 255, 0.12), c(61, 159, 255, 0.2), c(10, 111, 214, 0.2), c(108, 182, 255, 0.3))
            case .tintProblem: v(c(236, 58, 76, 0.12), c(255, 92, 104, 0.2), c(208, 31, 51, 0.2), c(255, 127, 137, 0.3))
            case .tintDone: v(c(24, 169, 87, 0.12), c(59, 212, 124, 0.18), c(11, 138, 67, 0.2), c(95, 227, 151, 0.28))
            case .tintIdle: v(c(138, 138, 153, 0.13), c(143, 143, 158, 0.2), c(107, 107, 122, 0.2), c(176, 176, 190, 0.3))
            case .tintForced: v(c(190, 59, 214, 0.12), c(213, 103, 238, 0.2), c(158, 34, 184, 0.2), c(228, 140, 246, 0.3))
            case .shadowRing: v(c(24, 24, 48, 0.07), c(255, 255, 255, 0.075), c(24, 24, 48, 0.3), c(255, 255, 255, 0.3))
            case .shadowNear: v(c(24, 24, 48, 0.06), c(0, 0, 0, 0.35), c(24, 24, 48, 0.1), c(0, 0, 0, 0.5))
            case .shadowFar: v(c(24, 24, 60, 0.1), c(0, 0, 0, 0.55), c(24, 24, 60, 0.16), c(0, 0, 0, 0.7))
            case .shadowDeep: v(c(20, 20, 60, 0.18), c(0, 0, 0, 0.7), c(20, 20, 60, 0.26), c(0, 0, 0, 0.85))
            case .focusRing: v(c(91, 76, 245, 0.55), c(140, 128, 255, 0.7), c(58, 43, 196, 0.9), c(170, 160, 255, 0.95))
            }
        }
    }

    /// The reserved status colors (§3.2). Each always ships with its symbol and its word, never color alone.
    public enum Status: String, CaseIterable, Equatable {
        case you, working, problem, done, idle, forced

        /// `--status-*`: the glyph and the mark.
        public var color: ColorToken {
            switch self {
            case .you: .statusYou
            case .working: .statusWorking
            case .problem: .statusProblem
            case .done: .statusDone
            case .idle: .statusIdle
            case .forced: .statusForced
            }
        }

        /// `--status-*-text`: the word when it is drawn in the status's colour, at 4.5:1 on content.
        public var textColor: ColorToken {
            switch self {
            case .you: .statusYouText
            case .working: .statusWorkingText
            case .problem: .statusProblemText
            case .done: .statusDoneText
            case .idle: .statusIdleText
            case .forced: .statusForcedText
            }
        }

        /// `--tint-*`: a badge's background, behind a word kept in `text-primary`.
        public var tintColor: ColorToken {
            switch self {
            case .you: .tintYou
            case .working: .tintWorking
            case .problem: .tintProblem
            case .done: .tintDone
            case .idle: .tintIdle
            case .forced: .tintForced
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

    /// The surfaces (§3.1): the window behind everything, the content of cards and lists on it, a group raised inside
    /// a card, and the track sunk into one.
    public enum Surface {
        public static let window = ColorToken.surfaceWindow
        public static let content = ColorToken.surfaceContent
        public static let raised = ColorToken.surfaceRaised
        public static let sunken = ColorToken.surfaceSunken
        public static let separator = ColorToken.strokeSeparator
        public static let strong = ColorToken.strokeStrong
    }

    /// The text colours (§3.1): primary for content, secondary for metadata, tertiary for placeholders and disabled
    /// text only.
    public enum TextColor {
        public static let primary = ColorToken.textPrimary
        public static let secondary = ColorToken.textSecondary
        public static let tertiary = ColorToken.textTertiary
        public static let onAccent = ColorToken.textOnAccent
    }

    /// Glass (§3.7), the material of what floats over content. With Reduce Transparency on, each is its solid
    /// surface instead.
    public enum Glass: String, CaseIterable, Equatable {
        /// `--material-glass`: bars over scrolling content.
        case glass
        /// `--material-glass-thick`: anything with text to read (menus, toasts, sheets).
        case thick

        public var fill: ColorToken {
            switch self {
            case .glass: .materialGlass
            case .thick: .materialGlassThick
            }
        }

        /// `--material-blur`'s radius in points.
        public static let blur: Double = 28
        /// `--material-edge`: the glass's bright inner edge.
        public static let edge = ColorToken.materialEdge

        /// The solid surface that stands in for the glass under Reduce Transparency.
        public var solid: ColorToken {
            switch self {
            case .glass: .surfaceRaised
            case .thick: .surfaceContent
            }
        }

        /// What is drawn: the glass, or its solid surface while Reduce Transparency is on.
        public func drawn(reduceTransparency: Bool) -> ColorToken { reduceTransparency ? solid : fill }
    }

    /// `--backdrop-glow`: the faint iris and blue glow the window carries at its top, never under text. Increase
    /// Contrast drops it, and the window is its plain surface.
    public enum Backdrop {
        /// One radial glow: an ellipse of `width` × `height` points around a centre given as a fraction of the window
        /// (it may lie outside), its colour fading to clear at `fade` of the way out.
        public struct Glow: Equatable {
            public var width: Double
            public var height: Double
            public var centerX: Double
            public var centerY: Double
            public var color: ColorPair
            public var fade: Double
        }

        public static let surface = ColorToken.surfaceWindow

        public static let glows = [
            Glow(width: 1200, height: 600, centerX: 0.12, centerY: -0.1,
                 color: ColorPair(RGBA(108, 92, 255, 0.1), RGBA(108, 92, 255, 0.16)), fade: 0.6),
            Glow(width: 900, height: 500, centerX: 1, centerY: 0,
                 color: ColorPair(RGBA(36, 150, 255, 0.07), RGBA(36, 150, 255, 0.1)), fade: 0.6),
        ]

        /// The glows drawn: none under Increase Contrast.
        public static func glows(increaseContrast: Bool) -> [Glow] { increaseContrast ? [] : glows }
    }

    /// Depth (§3.7): layered soft shadows, each a hairline ring, a near shadow and a far one. Content sits flat on its
    /// card; only what rises casts more.
    public enum Elevation: Int, CaseIterable, Equatable {
        /// Anything inside a card.
        case level0
        /// A card, a group, a toggle row.
        case level1
        /// A card under the pointer, a tooltip, a preview pane.
        case level2
        /// Menus, pop-up lists, toasts.
        case level3
        /// Sheets.
        case level4

        /// A CSS `box-shadow`: offset, blur and spread in points, and its colour.
        public struct Shadow: Equatable {
            public var x: Double
            public var y: Double
            public var blur: Double
            public var spread: Double
            public var color: ColorToken

            public init(x: Double = 0, y: Double, blur: Double, spread: Double = 0, color: ColorToken) {
                self.x = x
                self.y = y
                self.blur = blur
                self.spread = spread
                self.color = color
            }
        }

        /// `--elevation-N`, outermost first; the first of each is the hairline ring.
        public var shadows: [Shadow] {
            let ring = Shadow(y: 0, blur: 0, spread: 1, color: .shadowRing)
            return switch self {
            case .level0: []
            case .level1: [ring, Shadow(y: 1, blur: 2, color: .shadowNear), Shadow(y: 3, blur: 8, spread: -4, color: .shadowFar)]
            case .level2: [ring, Shadow(y: 2, blur: 4, color: .shadowNear), Shadow(y: 12, blur: 28, spread: -10, color: .shadowFar)]
            case .level3: [ring, Shadow(y: 4, blur: 10, color: .shadowNear), Shadow(y: 22, blur: 48, spread: -14, color: .shadowDeep)]
            case .level4: [ring, Shadow(y: 8, blur: 20, color: .shadowNear), Shadow(y: 40, blur: 90, spread: -24, color: .shadowDeep)]
            }
        }

        /// `--edge-highlight`: an inset line on a card's top edge, one point down.
        public static let edgeHighlight = Shadow(y: 1, blur: 0, color: .strokeHighlight)
    }

    /// The family a text style is set in: SF Pro Text, SF Pro Display, or SF Mono (`--font-*`).
    public enum FontFamily: String, Equatable {
        case text, display, mono
    }

    /// Text styles (§3.4): the catalog's type scale, each a size, a weight, a line height and a tracking. They scale
    /// with the system's text size (`scaledSize(by:)`).
    public enum TypeStyle: String, CaseIterable, Equatable {
        /// 700 26/32, display, tracked −2.2 %: a page's title.
        case title
        /// 650 18/24, display: the status sentence that opens a view, sheet and Question titles.
        case sentence
        /// 600 28/34, display: stat tile values. The app's own; the catalog has none.
        case figure
        /// 600 15/20: a section's or a card's title.
        case heading
        /// 600 13/18: a row's title.
        case rowTitle
        /// 400 13/19: text and table cells.
        case body
        /// 400 12/16: metadata under body text.
        case secondary
        /// 550 11/14, tracked +2 %: badges, labels, column headers.
        case label
        /// 500 10/13: footnotes, timestamps.
        case caption
        /// 450 12/16, SF Mono: paths, commands, ids.
        case mono
        /// 400 16, line height 1.4, tracked +2 %: a text the Director reads through, such as a ticket's brief.
        case reading

        /// The custom property in `tokens.css`; nil for the app's own style.
        public var cssName: String? {
            switch self {
            case .figure: nil
            case .rowTitle: "--type-row-title"
            default: "--type-" + rawValue
            }
        }

        /// The CSS weight, 100–900.
        public var weight: Int {
            switch self {
            case .title: 700
            case .sentence: 650
            case .figure, .heading, .rowTitle: 600
            case .body, .secondary, .reading: 400
            case .label: 550
            case .caption: 500
            case .mono: 450
            }
        }

        /// The size in points at the system's default text size.
        public var size: Double {
            switch self {
            case .title: 26
            case .sentence: 18
            case .figure: 28
            case .heading: 15
            case .rowTitle, .body: 13
            case .secondary, .mono: 12
            case .label: 11
            case .caption: 10
            case .reading: 16
            }
        }

        /// The line height in points at the system's default text size.
        public var lineHeight: Double {
            switch self {
            case .title: 32
            case .sentence: 24
            case .figure: 34
            case .heading: 20
            case .rowTitle: 18
            case .body: 19
            case .secondary, .mono: 16
            case .label: 14
            case .caption: 13
            case .reading: 16 * 1.4
            }
        }

        public var family: FontFamily {
            switch self {
            case .title, .sentence, .figure: .display
            case .mono: .mono
            default: .text
            }
        }

        /// The letter spacing as a fraction of the size (`--tracking-*`).
        public var tracking: Double {
            switch self {
            case .title: Tracking.display
            case .label: Tracking.label
            case .reading: Tracking.reading
            default: 0
            }
        }

        /// The size under the system's text size, `scale` being its body size over the default 13 pt.
        public func scaledSize(by scale: Double) -> Double { size * scale }

        /// The line height under the system's text size.
        public func scaledLineHeight(by scale: Double) -> Double { lineHeight * scale }

        /// The weight on AppKit's scale (`NSFont.Weight`, −1 to 1), between its named weights for the catalog's
        /// in-between ones (550, 650).
        public var systemWeight: Double { Self.systemWeight(css: weight) }

        /// A CSS weight (100–900) on AppKit's scale, between its named weights for the in-between ones.
        public static func systemWeight(css weight: Int) -> Double {
            let named: [(css: Double, system: Double)] = [
                (100, -0.8), (200, -0.6), (300, -0.4), (400, 0), (500, 0.23), (600, 0.3), (700, 0.4), (800, 0.56), (900, 0.62),
            ]
            let css = Double(weight)
            guard let upper = named.firstIndex(where: { $0.css >= css }) else { return named.last!.system }
            if upper == 0 || named[upper].css == css { return named[upper].system }
            let (low, high) = (named[upper - 1], named[upper])
            return low.system + (css - low.css) / (high.css - low.css) * (high.system - low.system)
        }
    }

    /// Letter spacing as a fraction of the size (`--tracking-*`).
    public enum Tracking {
        public static let display = -0.022
        public static let label = 0.02
        public static let reading = 0.02
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
        public static let s10: Double = 40
    }

    /// The reading measure (§3.4, `--measure` and `--measure-narrow`): no line of reading text runs past 68
    /// characters, 52 for help lines. A character is the width of the font's "0" (CSS `ch`); the app's
    /// `Measure.width(_:for:)` turns them into points.
    public enum Measure {
        public static let characters = 68
        public static let narrowCharacters = 52
    }

    /// Corner radii (§3.6), concentric: an inner radius is the outer minus the padding between them.
    public enum Radius {
        public static let sheet: Double = 22
        public static let card: Double = 16
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

    /// The badge (`.badge`, design-system.md C7): a status glyph and word on the status tint, in a capsule.
    public enum Badge {
        /// The catalog's three sizes: `.badge-sm`, `.badge`, `.badge-lg`.
        public enum Size: String, CaseIterable, Equatable {
            case small, regular, large

            /// The capsule's height.
            public var height: Double {
                switch self {
                case .small: 18
                case .regular: 20
                case .large: 24
                }
            }

            /// The room before the glyph (or the word, without one).
            public var leading: Double {
                switch self {
                case .small: 5
                case .regular: 6
                case .large: 8
                }
            }

            /// The room after the word.
            public var trailing: Double {
                switch self {
                case .small: 6
                case .regular: 8
                case .large: 10
                }
            }

            /// The glyph's square.
            public var glyph: Double {
                switch self {
                case .small: 10
                case .regular: 12
                case .large: 14
                }
            }

            /// The word's size at the system's default text size: `--type-label`, 10.5 pt small, 13 pt large.
            public var textSize: Double {
                switch self {
                case .small: 10.5
                case .regular: TypeStyle.label.size
                case .large: 13
                }
            }

            /// The word's CSS weight.
            public var weight: Int {
                switch self {
                case .small, .regular: TypeStyle.label.weight
                case .large: 600
                }
            }
        }

        /// The gap between the glyph and the word.
        public static let gap: Double = 4
        /// On a selected row (`.row[aria-selected="true"] .badge`): white at 20 % behind the word in `text-on-accent`.
        public static let selectedFill: Double = 0.2
    }

    /// The count badge (`.count`): how many things wait in a place. Coloured only for "needs you" and "problem".
    public enum CountBadge {
        public static let height: Double = 18
        public static let minWidth: Double = 18
        /// The room on each side of the number.
        public static let inset: Double = 5
        public static let textSize: Double = 11
        public static let weight = 650
        /// The highest number drawn; above it the badge reads "99+".
        public static let most = 99
        /// Its shadow (`0 1px 2px`): the role's colour at 40 %.
        public static let shadowOpacity: Double = 0.4
        public static let shadowBlur: Double = 2
        public static let shadowY: Double = 1
        /// The dot form for the collapsed sidebar: a filled circle, no number.
        public static let dot: Double = 8

        /// The roles it is coloured for; any other count is quiet.
        public static func isColoured(_ role: Status?) -> Bool { role == .you || role == .problem }

        /// The number as drawn: 1 to 99, then "99+".
        public static func text(_ count: Int) -> String { count > most ? "\(most)+" : "\(count)" }
    }

    /// The status dot (`.dot`): the smallest status mark, always beside a word.
    public enum StatusDot {
        /// `.dot` (8 pt) and `.dot-lg` (10 pt).
        public enum Size: String, CaseIterable, Equatable {
            case regular, large

            public var diameter: Double {
                switch self {
                case .regular: 8
                case .large: 10
                }
            }
        }

        /// The gap between the dot and its word (`.dot-label`).
        public static let labelGap = Space.s2
        /// The live ring (`@keyframes dot-live`): it starts at the dot at 60 % and grows to 2.6 times the dot while
        /// it fades out, over the first 70 % of each 1.8 s period, then waits for the next.
        public static let ringScale: Double = 2.6
        public static let ringOpacity: Double = 0.6
        public static let ringPeriod: Double = 1.8
        public static let ringReach: Double = 0.7
    }

    /// The keyboard hint (`.kbd-hint`): the keys of a shortcut as key caps.
    public enum KeyHint {
        public static let height: Double = 20
        public static let minWidth: Double = 20
        /// The room on each side of a key's symbol; a plain hint's is 1 pt.
        public static let inset: Double = 5
        public static let plainInset: Double = 1
        public static let radius: Double = 6
        public static let textSize: Double = 11
        public static let weight = 550
        /// The gap between two keys.
        public static let gap: Double = 3
        /// The key cap's ring and its 1 pt bottom edge.
        public static let edge: Double = 1

        /// The keys of a shortcut written with a space between them (`"⌘ ⇧ F"`), one per cap.
        public static func keys(_ shortcut: String) -> [String] {
            shortcut.split(whereSeparator: \.isWhitespace).map(String.init)
        }

        /// What VoiceOver reads for the keys: each modifier's name, then the key ("Command Shift F").
        public static func spoken(_ keys: [String]) -> String {
            let names = ["⌘": "Command", "⇧": "Shift", "⌥": "Option", "⌃": "Control", "↩": "Return", "⎋": "Escape", "⌫": "Delete", "⇥": "Tab", "␣": "Space"]
            return keys.map { names[$0] ?? $0 }.joined(separator: " ")
        }
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
        /// What a pressed icon button settles to (the catalog's `.icon-btn:active`).
        public static let iconPressScale: Double = 0.92
        /// What a pressed card or option card settles to.
        public static let cardPressScale: Double = 0.99
        /// What a pressed row settles to.
        public static let rowPressScale: Double = 0.995
        /// How far a hovered clickable card rises, in points.
        public static let lift: Double = 1
        /// How far above its place a new timeline entry drops in from, in points.
        public static let enterOffset: Double = 12
        /// How long a new timeline entry's accent tint takes to fade out.
        public static let enterTintDuration: Double = 1.2
        /// The new entry's tint, at its start: the selection's.
        public static let enterTint = StateSurface.selected.color

        /// How a new timeline entry drops into place: on a spring of `motion.slow`; nil under Reduce Motion, where it
        /// is there at once, without moving or flashing.
        public static func entering(reduceMotion: Bool) -> Timing? {
            reduceMotion ? nil : .spring(duration: slowDuration, bounce: springBounce)
        }

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
            /// A selection sliding to its place: the segmented control's thumb (TP-1508).
            case slide

            /// The curve's timing; under Reduce Motion, an eased change of `reducedDuration`.
            public func timing(reduceMotion: Bool) -> Timing {
                if reduceMotion { return .eased(duration: Motion.reducedDuration) }
                return switch self {
                case .instant: .eased(duration: Motion.instantDuration)
                case .fast: .eased(duration: Motion.fastDuration)
                case .standard: .eased(duration: Motion.standardDuration)
                case .slow: .eased(duration: Motion.slowDuration)
                case .fold, .sheet, .slide: .spring(duration: Motion.springDuration, bounce: Motion.springBounce)
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

        /// A button's leading glyph, in points (the catalog's `--gl`).
        public var glyphSize: Double {
            switch self {
            case .small: 12
            case .medium: 14
            case .large: 16
            }
        }

        /// An icon button's glyph, in points: 2 pt over a button's.
        public var iconGlyphSize: Double { glyphSize + 2 }

        /// The gap between a control's glyph and its label, and between a control and the reason under it.
        public static let glyphGap: Double = 6

        /// A button's hairline edge.
        public static let edgeWidth: Double = 1

        /// How much a filled button brightens under the pointer, and darkens when pressed.
        public static let hoverBrightness: Double = 0.06
        public static let pressedBrightness: Double = -0.08
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
    /// `--surface-pressed`, `--accent-tint`).
    public enum StateSurface: String, CaseIterable, Equatable {
        case hover, pressed, selected

        public var color: ColorToken {
            switch self {
            case .hover: .surfaceHover
            case .pressed: .surfacePressed
            case .selected: .accentTint
            }
        }
    }

    /// A selection's ring: the accent, around a selected row or card.
    public enum Selection {
        public static let color = ColorToken.accent
        public static let rowRingWidth: Double = 1.5
        public static let cardRingWidth: Double = 2
    }

    /// The focus ring (§3.10): the iris at about half strength (`--focus-ring-color`), outside the shape and following
    /// its corners, drawn only for keyboard focus.
    public enum FocusRing {
        public static let color = ColorToken.focusRing
        public static let width: Double = 2
        /// The gap between the shape and the ring; a row's ring sits on its edge.
        public static let offset: Double = 2
    }

    /// The situation a ticket is in (`director-ticket-page.md` §3): exactly one at a time, said with its glyph, its
    /// word and its status color, never color alone. The cases are in the order that picks one when several are true.
    /// `unknown` is what Symphony says when it can tell nothing, and what the app reads a kind it does not know as.
    public enum SituationKind: String, CaseIterable, Equatable {
        case you, retrying, blocked, subTickets, provider, paused, ci, build, slot, working, done, cancelled, unknown

        /// Where it ranks when more than one is true: the lowest wins.
        public var precedence: Int { Self.allCases.firstIndex(of: self) ?? 0 }

        /// The one shown of several that are true; nil when none is.
        public static func shown(_ kinds: some Sequence<SituationKind>) -> SituationKind? {
            kinds.min { $0.precedence < $1.precedence }
        }

        public var status: Status {
            switch self {
            case .working, .ci, .build: .working
            case .slot, .blocked, .subTickets, .provider, .paused, .cancelled, .unknown: .idle
            case .you: .you
            case .retrying: .problem
            case .done: .done
            }
        }

        /// The SF Symbol: a dashed circle for work and CI, a clock for a slot, a box for a build, a person with a
        /// mark, a lock, a stack for sub-tickets, a paused rectangle for a paused provider, a pause, an arrow round, a
        /// filled tick, a slashed circle, a question mark.
        public var symbol: String {
            switch self {
            case .working, .ci: "circle.dotted.circle"
            case .slot: "clock"
            case .subTickets: "square.stack.3d.up"
            case .unknown: "questionmark.circle"
            case .build: "shippingbox"
            case .you: "person.crop.circle.badge.exclamationmark"
            case .blocked: "lock.fill"
            case .provider: "pause.rectangle"
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
            case .subTickets: "Waiting on its sub-tickets"
            case .unknown: "Not known"
            case .provider: "Waiting on a paused provider"
            case .paused: "Paused"
            case .retrying: "Retrying"
            case .done: "Shipped"
            case .cancelled: "Cancelled"
            }
        }
    }

    /// The catalog's Row (`.row`, TP-1507): one line at 34 pt, or two at 52 pt when it has a second line; a lead 18 pt
    /// square, the identifier and the title on the first line, and a trail whose last value sits in a column of
    /// `valueWidth` so a list's trails align. Selected, it fills with the accent and its words turn white; with the
    /// window not in front, the selection is the pressed grey and the words keep their colours.
    public enum Row {
        public static let oneLineHeight: Double = 34
        public static let twoLineHeight: Double = 52
        /// The room above and below the content: one line's 18 pt in 34, two lines' 36 pt in 52.
        public static let inset: Double = 8
        /// The room before the lead and after the trail.
        public static let sideInset = Space.s3
        /// Between the lead, the lines and the trail.
        public static let gap = Space.s3
        /// The lead's square, and its glyph inside it.
        public static let leadSize: Double = 18
        public static let leadGlyph: Double = 14
        /// Between the identifier and the title, and between two items of the trail.
        public static let itemGap = Space.s2
        /// Between the first line and the second.
        public static let lineGap: Double = 2
        /// The title's weight: 13 pt at 500 on the row title's 18 pt line.
        public static let titleWeight = 500
        /// The trail's last value's column: at least this wide, its text at the trailing edge.
        public static let valueWidth: Double = 52
        /// The column for a longer value: a duration ("1 day 4 h") or an amount ("182K of 500K").
        public static let wideValueWidth: Double = 96
        /// Home's column for how long a situation has held (`.home .row .age`).
        public static let homeValueWidth: Double = 64
        /// A selected row's secondary words, lead and values: white at 85 % on the accent.
        public static let onAccentSecondary: Double = 0.85

        /// The row's height for one line or two.
        public static func height(twoLines: Bool) -> Double { twoLines ? twoLineHeight : oneLineHeight }

        /// The row's fill: the accent when selected in the front window (the pressed grey behind it), else pressed,
        /// else hover, else the accent tint on the row that is the page's own item (`current`, the catalog's
        /// `.is-self`); none at rest or disabled.
        public static func fill(_ state: Interaction, windowActive: Bool, current: Bool = false) -> ColorToken? {
            if state.disabled { return nil }
            if state.selected { return windowActive ? .accent : .surfacePressed }
            if state.pressed { return .surfacePressed }
            if state.hovered { return .surfaceHover }
            return current ? .accentTint : nil
        }

        /// Whether the row's words are white on the accent: selected, enabled, in the front window.
        public static func onAccent(_ state: Interaction, windowActive: Bool) -> Bool {
            state.selected && !state.disabled && windowActive
        }
    }

    /// The catalog's tree (`.t-root`, `.t-kids`, `.q-behind`, TP-1507): each ticket's children one step in under it, on a
    /// rail that starts under its lead glyph, with a tick to each child; past `foldDepth` the rest of a chain folds into
    /// a pill that counts it ("+6").
    public enum Tree {
        /// How far a child's row starts in from its parent's.
        public static let step: Double = 32
        /// Where a level's rail runs, from its parent row's leading edge: under the lead glyph's centre.
        public static let railOffset = Space.s3 + 8
        public static let railWidth: Double = 1
        public static let railColor = ColorToken.strokeStrong
        /// The tick from the rail to a child: it starts after the rail and stops 2 pt short of the row.
        public static let tickWidth = Space.s3 - 3
        /// The tick's height down a child's line: the middle of a one-line row.
        public static let tickY = Row.oneLineHeight / 2
        /// Between two lines of the tree.
        public static let lineGap: Double = 2
        /// Rows past this depth (the roots are at 0) fold into the pill until their root is opened.
        public static let foldDepth = 2

        /// Where level `level`'s rail runs (1 for a root's children), from the tree's leading edge.
        public static func railX(level: Int) -> Double { railOffset + step * Double(level - 1) }

        /// The pill a folded chain shows: "+6" and a chevron, on the hover surface in a capsule.
        public enum More {
            public static let height: Double = 20
            public static let leadingInset: Double = 7
            public static let trailingInset: Double = 5
            public static let gap: Double = 3
            /// From its rail's tick.
            public static let offset = Space.s2
            public static let textSize: Double = 11
            public static let weight = 600
            public static let chevron: Double = 8
            public static let symbol = "chevron.right"
            public static let fill = ColorToken.surfaceHover
            public static let hoverFill = ColorToken.surfacePressed

            /// "+6".
            public static func text(_ hidden: Int) -> String { "+\(hidden)" }

            /// "Show the 6 behind it": its help text, and what VoiceOver reads.
            public static func help(_ hidden: Int) -> String { "Show the \(hidden) behind it" }
        }
    }

    /// The catalog's progress strip (`.epic-strip`, TP-1507): one segment per item in the status colour of its state,
    /// 3 pt apart; past `most` items the states share the strip in proportion. The segment of an item being worked on
    /// breathes (its opacity falls to `breatheOpacity` and back every `breathePeriod`), and is still under Reduce
    /// Motion.
    public enum ProgressStrip {
        /// One item: its state's status, nil for one not started; `live` while it is being worked on.
        public struct Item: Equatable {
            public var status: Status?
            public var live: Bool

            public init(_ status: Status?, live: Bool = false) {
                self.status = status
                self.live = live
            }
        }

        /// One segment drawn: its state, whether it breathes, and how many items it stands for.
        public struct Segment: Equatable {
            public var status: Status?
            public var live: Bool
            public var weight: Int
        }

        /// The most segments drawn one per item.
        public static let most = 30
        public static let height: Double = 5
        /// The strip under a page's title, as wide as its column up to `headerMaxWidth`.
        public static let headerHeight: Double = 6
        public static let headerMaxWidth: Double = 720
        public static let gap: Double = 3
        public static let radius: Double = 3
        /// The width of a strip in a row's trail or beside its count.
        public static let compactWidth: Double = 132
        /// A segment not started, or waiting.
        public static let rest = ColorToken.surfacePressed
        public static let breatheOpacity: Double = 0.45
        public static let breathePeriod: Double = 1.8
        /// How each half of the breath moves, down and back up alike: the catalog's `--ease-standard`,
        /// `cubic-bezier(0.2, 0, 0, 1)` (`.epic-strip i.live { animation: ds-breathe 1.8s var(--ease-standard) infinite }`).
        public static let breatheCurve: [Double] = [0.2, 0, 0, 1]

        /// The order the states share a strip past `most`, and VoiceOver reads them in.
        static let order: [Status?] = [.done, .problem, .you, .working, .forced, .idle, nil]

        /// The colour of a segment: its status's, or `rest` for one not started or waiting.
        public static func color(_ status: Status?) -> ColorToken {
            guard let status, status != .idle else { return rest }
            return status.color
        }

        /// The segments of `items`: one each, in order, up to `most`; past it one per state with its count as its
        /// weight, breathing when any of its items is live.
        public static func segments(_ items: [Item]) -> [Segment] {
            if items.count <= most { return items.map { Segment(status: $0.status, live: $0.live, weight: 1) } }
            return order.compactMap { status in
                let these = items.filter { $0.status == status }
                return these.isEmpty ? nil : Segment(status: status, live: these.contains(where: \.live), weight: these.count)
            }
        }

        /// The word VoiceOver reads after a state's count.
        public static func word(_ status: Status?) -> String {
            switch status {
            case .done: "done"
            case .working: "working"
            case .you: "waiting on you"
            case .problem: "needing a fix"
            case .forced: "forced"
            case .idle, nil: "waiting"
            }
        }

        /// What the strip says: "3 done, 1 working, 22 waiting"; "Nothing yet" without items.
        public static func spoken(_ items: [Item]) -> String {
            let waiting = items.filter { $0.status == nil || $0.status == .idle }.count
            let parts = order.dropLast(2).compactMap { status -> String? in
                let count = items.filter { $0.status == status }.count
                return count == 0 ? nil : "\(count) \(word(status))"
            } + (waiting == 0 ? [] : ["\(waiting) \(word(nil))"])
            return parts.isEmpty ? "Nothing yet" : parts.joined(separator: ", ")
        }
    }

    /// The catalog's Segmented control (`.segmented`, TP-1508): two to five equal segments on a sunken capsule track,
    /// and one raised capsule thumb that slides to the selection on the `slide` spring.
    public enum Segmented {
        /// The fewest and the most segments: past five, a pop-up.
        public static let fewest = 2
        public static let most = 5
        /// The track's inset around the thumb.
        public static let inset: Double = 2
        /// The room on each side of a segment's word: 90 % of the control's padding.
        public static let paddingScale: Double = 0.9
        /// The thumb's hairline and the track's.
        public static let hairline: Double = 0.5

        /// The thumb's leading offset from the track's inner edge for segment `index` of `count` in `width` (the
        /// track's inner width): each segment takes an equal share.
        public static func thumbOffset(index: Int, count: Int, width: Double) -> Double {
            guard count > 0 else { return 0 }
            return Double(min(max(index, 0), count - 1)) * width / Double(count)
        }
    }

    /// The catalog's Pop-up and Menu button (`.popup`, `.menu-btn`, TP-1508): a control of a C23 height on the
    /// secondary button's face, its label (and a pop-up's value), and a chevron: up-down for a pop-up, down for a menu
    /// button, which turns over while its menu is open.
    public enum MenuControl {
        /// The room after the label before the trailing edge: 70 % of the control's padding.
        public static let trailingScale: Double = 0.7
        /// The chevron's size, in points.
        public static let chevron: Double = 10
        public static let popUpSymbol = "chevron.up.chevron.down"
        public static let menuSymbol = "chevron.down"
        /// The open control's accent ring, outside its edge (the catalog's `0 0 0 4px var(--accent-tint)`).
        public static let openRingWidth: Double = 3
        /// The dot after a value that differs from what was saved (the catalog's `.unsaved`), and its gap.
        public static let mark: Double = 6
        public static let markGap: Double = 6
    }

    /// The catalog's open menu and pop-up list (`.menu`, `.menu-item`, TP-1508): glass in the menu's radius at the
    /// third elevation, 6 pt under its control; 28 pt items whose hovered one is the accent with white words.
    public enum Menu {
        public static let radius: Double = 12
        public static let padding: Double = 5
        public static let minWidth: Double = 220
        /// The gap between the control and the menu.
        public static let gap: Double = 6
        /// The least room kept between the menu and the screen's edge.
        public static let edgeMargin = Space.s2
        public static let itemHeight: Double = 28
        public static let itemRadius: Double = 7
        public static let itemInset = Space.s2
        public static let itemGap = Space.s2
        /// The tick's box at an item's leading edge, in points.
        public static let check: Double = 12
        public static let checkSymbol = "checkmark"
        /// The room before a keyboard hint.
        public static let hintGap = Space.s4
        /// A separator: a hairline with 5 pt above and below and 8 pt in from each side.
        public static let separatorMargin: Double = 5
        public static let separatorHeight: Double = 1
        public static let elevation = Elevation.level3
        public static let glass = Glass.thick
        /// How long typed letters keep adding to the search before a new one starts over.
        public static let typeAheadTimeout: Double = 1
        /// A submenu's symbol at its item's trailing edge.
        public static let submenuSymbol = "chevron.right"

        /// A separator's height with its margins.
        public static var separatorSpan: Double { separatorHeight + 2 * separatorMargin }
    }

    /// The catalog's Searchable pop-up (`.pick-list`, `.pick-none`, TP-1530): the Pop-up's small face, its value in
    /// the mono face (an identifier) or the tertiary colour when it comes from a default, opening a 280 pt list with
    /// the search field on top and the choices under it, cut to 220 pt and scrolling.
    public enum SearchableList {
        public static let width: Double = 280
        public static let padding: Double = 6
        /// Between the search field and the first choice.
        public static let fieldGap: Double = 4
        /// The tallest the choices are before they scroll.
        public static let listHeight: Double = 220
        /// The line saying nothing matches: 8 pt above and below, 12 pt in.
        public static let noMatchVertical = Space.s2
        public static let noMatchHorizontal = Space.s3
        /// A value from a default: tertiary, at the regular weight.
        public static let inheritedWeight = 400
        public static let control = Control.small

        /// From the list's top to its first choice's: its padding, the field and the gap.
        public static var choicesTop: Double { padding + control.height + fieldGap }
    }

    /// The catalog's Save bar (`.save-bar`, TP-1530): glass over a page edited whole, what is edited on the left and
    /// how much is not saved, Revert and Save on the right.
    /// The catalog's Control bar (`sections/control-bar`, `.control-bar`, `.tk-bar`; TP-1497): the glass bar at the top
    /// of a page that holds the page's own controls, what narrows the page at the left and what acts on it at the right,
    /// with an optional one-line summary under them (beside them on a desktop).
    public enum ControlBar {
        /// `border-radius: var(--radius-card)`.
        public static let radius = Radius.card
        /// `padding: var(--space-2) var(--space-3)`.
        public static let verticalPadding = Space.s2
        public static let horizontalPadding = Space.s3
        /// `gap: var(--space-2)` between the controls of a side (`.tk-bar`).
        public static let gap = Space.s2
        /// `gap: … var(--space-5)` between a labelled group and the next (`.control-bar`).
        public static let groupGap = Space.s5
        /// Between the controls and the summary under them.
        public static let summaryGap = Space.s2
        /// The summary's inset, `padding: 0 var(--space-1)`.
        public static let summaryInset = Space.s1
        /// Room left between what narrows and what acts.
        public static let sidesGap = Space.s3
        /// The bar's distance from the page's sides and from the window bar above it.
        public static let pageInset = Space.s6
        public static let pageGap = Space.s3
        public static let glass = Glass.glass
        public static let elevation = Elevation.level1
        public static let control = Control.small
        /// From this width (a desktop) the summary sits right aligned beside the controls when the line holds both.
        public static let summaryBesideWidth: Double = 1600

        /// Whether a bar `width` wide draws its summary beside its controls.
        public static func summaryBeside(width: Double) -> Bool { width >= summaryBesideWidth }
    }

    /// The window's own bar (`.win-bar`, TP-1496): glass over the page's top, a hairline under it.
    public enum WindowBar {
        /// `height: 44px`.
        public static let height: Double = 44
        /// `padding: 0 var(--space-4) 0 var(--space-3)`.
        public static let leadingPadding = Space.s3
        public static let trailingPadding = Space.s4
        /// The window's close, minimize and zoom buttons end 70 pt from its leading edge. With the sidebar hidden the
        /// bar runs under them, so its first control starts `--space-2` after the zoom button instead.
        public static let windowButtonsEnd: Double = 70

        /// The bar's leading padding: the catalog's `--space-3` beside the sidebar; beside the sidebar folded to its glyphs
        /// (TP-1498), which is narrower than the window's buttons, clear of the zoom button by `--space-2`.
        public static func leading(sidebarShown: Bool) -> Double {
            sidebarShown ? leadingPadding : max(leadingPadding, windowButtonsEnd + Space.s2 - Sidebar.collapsedWidth)
        }
        /// `gap: var(--space-2)` between its controls.
        public static let gap = Space.s2
        /// `.nav-pair { gap: 2px }`: Back and Forward.
        public static let navGap: Double = 2
        /// `.sep`: a hairline 16 pt tall with `--space-1` on each side.
        public static let separatorHeight: Double = 16
        public static let separatorInset = Space.s1
        /// `.win-search { width: 232px }`: Find a ticket.
        public static let searchWidth: Double = 232
        /// `.win-bar .segmented { margin-left: var(--space-2) }`: Work's switch after the breadcrumb.
        public static let switchLeading = Space.s2
        /// `.with-count .count { top: -3px; right: -5px }`: the Inbox's count over its icon's corner.
        public static let countTop: Double = -3
        public static let countTrailing: Double = -5
        public static let glass = Glass.glass
        public static let control = Control.medium
        public static let sidebarSymbol = "sidebar.left"
        public static let backSymbol = "chevron.left"
        public static let forwardSymbol = "chevron.right"
        public static let inboxSymbol = "tray"
        public static let refreshSymbol = "arrow.clockwise"
        /// The gap between Find a ticket and the list of what it found under it (the menu's gap).
        public static let findGap = Menu.gap
    }

    /// The catalog's window sidebar (`.win-side`, `.nav-row`, TP-1498): 232 pt flush with the window and a hairline on
    /// its right, 60 pt of glyphs folded. Its top is the room of the window's buttons, as tall as the window bar.
    /// Rows are 30 pt (`--control-md`) with its corner, 2 pt apart; a row is a 16 pt glyph and its name at 13 pt 500,
    /// and the count. The current destination is the accent tint with accent text at 600; with the window not in
    /// front, the pressed grey with primary text.
    public enum Sidebar {
        public static let width: Double = 232
        public static let collapsedWidth: Double = 60
        /// `.win-lights { height: 44px }`: the room the window's buttons sit in, over the rows.
        public static let topInset = WindowBar.height
        /// `padding: 0 var(--space-2) var(--space-2)`.
        public static let inset = Space.s2
        /// `.win-nav { gap: 2px }`.
        public static let rowGap: Double = 2
        public static let rowHeight = Control.medium.height
        public static let rowRadius = Control.medium.radius
        /// `.nav-row { padding: 0 var(--space-2); gap: var(--space-2) }`.
        public static let rowInset = Space.s2
        public static let rowGapInside = Space.s2
        public static let glyph: Double = 16
        /// `.nav-row.child`: a page under Factory starts where its parent's name does.
        public static let childIndent = Space.s2 + glyph
        public static let textSize: Double = 13
        public static let weight = 500
        public static let currentWeight = 600
        /// `.side-collapsed .nav-row .count { top: 3px; right: 6px }`: the count's dot over the glyph's corner.
        public static let dotTop: Double = 3
        public static let dotTrailing: Double = 6
        /// The width change between the two forms: the fold's spring, instant under Reduce Motion.
        public static let fold = Motion.Curve.fold
        public static let separator = Surface.separator

        /// The width for the form shown.
        public static func width(collapsed: Bool) -> Double { collapsed ? collapsedWidth : width }

        /// The row's fill: pressed, else the current destination's (the accent tint in the front window, the pressed
        /// grey behind), else hover; none at rest.
        public static func fill(_ state: Interaction, current: Bool, windowActive: Bool) -> ColorToken? {
            if state.pressed { return .surfacePressed }
            if current { return windowActive ? .accentTint : .surfacePressed }
            if state.hovered { return .surfaceHover }
            return nil
        }

        /// The name's colour: accent text on the current destination in the front window; secondary for a page under
        /// Factory at rest; primary otherwise.
        public static func text(current: Bool, child: Bool, hovered: Bool, windowActive: Bool) -> ColorToken {
            if current { return windowActive ? .accentText : .textPrimary }
            return child && !hovered ? .textSecondary : .textPrimary
        }

        /// The glyph's colour: accent text on the current destination in the front window, secondary otherwise.
        public static func glyphColor(current: Bool, windowActive: Bool) -> ColorToken {
            current && windowActive ? .accentText : .textSecondary
        }
    }

    /// The catalog's status line (`.win-status`, `.dispatch`, TP-1498): 30 pt of glass under the page with a hairline
    /// over it, `--type-secondary` in secondary text. The dispatch control first, a hairline, the counts, then at the
    /// right the build (tertiary) and the connection with its dot.
    public enum StatusLine {
        public static let height: Double = 30
        /// `padding: 0 var(--space-4) 0 var(--space-2)`.
        public static let leadingPadding = Space.s2
        public static let trailingPadding = Space.s4
        public static let gap = Space.s3
        public static let glass = Glass.glass
        /// `.sep`: a hairline 16 pt tall with `--space-1` on each side.
        public static let separatorHeight = WindowBar.separatorHeight
        public static let separatorInset = Space.s1
        /// The connection's dot and its words.
        public static let dotGap = Space.s1
        public static let build = TextColor.tertiary

        /// `.dispatch`: a quiet control 24 pt tall (`--control-sm`) with its corner, `--space-2` inside and between its
        /// dot, words and chevron; 12 pt at 500 in primary text; the hover surface under the pointer, pressed while
        /// held or while its menu is open.
        public enum Dispatch {
            public static let control = Control.small
            public static let inset = Space.s2
            public static let gap = Space.s2
            public static let textSize: Double = 12
            public static let weight = 500
            public static let chevron: Double = 10
            public static let chevronSymbol = "chevron.down"

            public static func fill(_ state: Interaction, open: Bool) -> ColorToken? {
                if state.pressed || open { return .surfacePressed }
                if state.hovered { return .surfaceHover }
                return nil
            }
        }
    }

    /// The window bar's breadcrumb (`.win-crumbs`, TP-1496): where the window is, links up to the place shown.
    public enum Breadcrumb {
        /// `gap: 6px` between a part and its chevron.
        public static let gap: Double = 6
        /// `.win-crumbs > .glyph`: the chevron between parts, 10 pt, tertiary.
        public static let chevron: Double = 10
        public static let chevronSymbol = "chevron.right"
        /// `.win-crumb .glyph`: a part's own glyph (the epic's), 12 pt, 5 pt before its words.
        public static let glyph: Double = 12
        public static let glyphGap: Double = 5
        /// `.win-crumb`'s focus ring corner, `--radius-mark`.
        public static let radius = Radius.mark
        public static let epicSymbol = "flag.pattern.checkered"
    }

    public enum SaveBar {
        public static let radius = Radius.card
        public static let gap = Space.s2
        public static let verticalPadding = Space.s2
        public static let horizontalPadding = Space.s3
        public static let glass = Glass.glass
        public static let elevation = Elevation.level1
        /// The room after the count before Revert.
        public static let countTrailing = Space.s1
        /// The check before "Saved" and the mark before a refusal, and their gap.
        public static let glyph: Double = 13
        public static let glyphGap: Double = 5
        public static let savedSymbol = "checkmark.circle.fill"
        public static let refusedSymbol = "exclamationmark.triangle.fill"
        public static let shortcut = "⌘ S"
        public static let saving = "Saving…"
        public static let saved = "Saved"
        /// How long "Saved" stays before the page takes it away.
        public static let savedFor: Double = 2

        /// The count: "1 change not saved", "3 changes not saved"; nil with nothing to save.
        public static func unsaved(_ changes: Int) -> String? {
            guard changes > 0 else { return nil }
            return "\(changes) \(changes == 1 ? "change" : "changes") not saved"
        }
    }

    /// Factory › Runs (`.runs-page`, `.run-list`, `.run-row`, TP-1538): the Save bar over one panel of rows, each a
    /// kind of run's name (170 pt) beside its lines, Default's row on the accent tint, a hairline between the others.
    /// The page is 24 pt from the top, 32 pt from the sides and 40 pt from the bottom, at most 1320 pt wide.
    public enum RunsPage {
        public static let maxWidth: Double = 1320
        public static let top = Space.s6
        public static let sides = Space.s8
        public static let bottom = Space.s10
        /// Between the Save bar and the panel.
        public static let gap = Space.s4
        public static let listPadding = Space.s2
        public static let rowPadding = Space.s3
        public static let rowGap = Space.s4
        public static let kindWidth: Double = 170
        /// Between the kind's name and its "Use Default's".
        public static let kindGap: Double = 2
        /// The name's line, as tall as a line of the list.
        public static let kindLineHeight: Double = 28
        /// "Use Default's" sits 8 pt left of the name, so its word lines up with it.
        public static let useDefaultsInset: Double = -8
        public static let defaultFill = ColorToken.accentTint
        public static let defaultRadius = Control.medium.radius
        public static let control = Control.small
        /// The Harnesses block (`.run-harnesses`, `.h-row`, TP-1539): rows 12 pt apart with a hairline between them,
        /// the harness's name in a 90 pt column 5 pt down to sit on the controls' line, then the 300 pt Command field
        /// and the small models wrapping 8 pt apart down, 12 pt across, 20 pt from each other column.
        public static let harnessRowGap = Space.s3
        public static let harnessNameWidth: Double = 90
        public static let harnessNameTop: Double = 5
        public static let harnessColumnGap = Space.s5
        public static let commandWidth: Double = 300
        public static let commandLabelGap = Space.s2
        public static let smallModelGap = Space.s3
        public static let smallModelLineGap = Space.s2
        /// A line whose provider is paused or held (`.reorder-line.is-off`, `.off-note`, TP-1534): its pop-ups ringed
        /// 1 pt inside in the "waiting on you" orange, and after them, 8 pt in, a 6 pt Status dot 6 pt before the
        /// note in that orange's text colour.
        public static let offRing: Double = 1
        public static let offRingColor = ColorToken.statusYou
        public static let offNoteInset = Space.s2
        public static let offNoteGap: Double = 6
        public static let offDot: Double = 6
        public static let offNoteColor = ColorToken.statusYouText
    }

    /// Factory › Providers (`.ini.prov`, `.ini-side`, `.ini-main`, `.story-head`, `.prov-usage`, TP-1534): the list of
    /// List cards in a 340 pt column, 32 pt from the page beside it, which is at most 1040 pt wide; the list's cards
    /// 8 pt apart under each group's zone title, the groups 24 pt apart; the page's blocks 16 pt apart, its head's lines
    /// 8 pt apart with 8 pt more under it; the meters 12 pt apart. The page sits 24 pt from the top, 32 pt from the
    /// sides and 40 pt from the bottom, as Runs.
    public enum ProvidersPage {
        public static let listWidth: Double = 340
        public static let columnGap = Space.s8
        public static let mainMaxWidth: Double = 1040
        public static let top = Space.s6
        public static let sides = Space.s8
        public static let bottom = Space.s10
        public static let cardGap = Space.s2
        public static let groupGap = Space.s6
        public static let blockGap = Space.s4
        public static let headGap = Space.s2
        public static let headBottom = Space.s2
        public static let meterGap = Space.s3
        /// The head's first line, the id and the button: as tall as a medium control.
        public static let idLineHeight = Control.medium.height
        public static let control = Control.medium
        /// The Situation line's glyph, and between its parts.
        public static let glyph: Double = 15
        public static let situationGap = Space.s2
    }

    /// The catalog's List card (`.list-card`, TP-1530): one thing of the list beside a page, its name and one fact on
    /// top and where it stands under them, after a Status dot.
    public enum ListCard {
        public static let radius = Radius.card
        public static let gap: Double = 6
        public static let verticalPadding = Space.s3
        public static let horizontalPadding = Space.s4
        /// Between the name and the fact.
        public static let topGap = Space.s3
        public static let dot: Double = 7
        public static let dotGap: Double = 5
        /// The selection: a 1.5 pt accent edge and its tint 2.5 pt past it; grey while the window is not focused.
        public static let ringWidth: Double = 1.5
        public static let tintWidth: Double = 2.5
    }

    /// The catalog's Reorderable list (`.reorder-line`, `.run-edit`, TP-1531): lines 6 pt apart, each at least 28 pt,
    /// a 16 × 24 pt handle of six dots, the place in a 20 pt disc, the line's own controls and, at its end, the
    /// remove button. The lifted line is the content surface at the third elevation with a 1.5 pt accent edge, 4 pt
    /// above and below and 6 pt to the sides past the line, turned 0.4°.
    public enum ReorderableList {
        public static let gap: Double = 6
        public static let lineHeight: Double = 28
        public static let lineGap = Space.s2
        public static let radius = Control.medium.radius
        public static let handleWidth: Double = 16
        public static let handleHeight: Double = 24
        public static let handleRadius = Radius.mark
        public static let handleGlyph: Double = 14
        /// The six dots, on the catalog's 16 pt grid: columns at 6 and 10, rows at 4, 8 and 12, 1.1 pt across each.
        public static let dotColumns: [Double] = [6, 10]
        public static let dotRows: [Double] = [4, 8, 12]
        public static let dotRadius: Double = 1.1
        public static let dotGrid: Double = 16
        public static let number: Double = 20
        public static let numberSize: Double = 11
        public static let numberWeight = 600
        public static let elevation = Elevation.level3
        public static let liftEdge: Double = 1.5
        public static let liftVertical: Double = 4
        public static let liftHorizontal: Double = 6
        public static let liftRotation: Double = -0.4
        /// Where the catalog's Dragging story draws the lifted line: 14 pt right of and 70 pt above its place, with a
        /// line's room (`dropGap`) opened over the line it is above.
        public static let drawnLiftX: Double = 14
        public static let drawnLiftY: Double = -70
        public static let dropGap: Double = 34
        /// The quiet add button under the lines, in line with their controls.
        public static let footIndent: Double = 38
        public static let footGap = Space.s4
        public static let addSymbol = "plus"
        public static let removeSymbol = "xmark"
        public static let control = Control.small
        /// A line that can't be used now: a 1 pt orange edge inside its controls, and the reason after a 6 pt dot.
        public static let offEdge: Double = 1
        public static let offDot: Double = 6
        public static let offGap: Double = 6
        public static let offIndent = Space.s2

        /// From one line's top to the next's: its height and the gap.
        public static func pitch(_ height: Double) -> Double { max(height, lineHeight) + gap }
    }

    /// The catalog's Progress meter (`.meter`, `.meter-line`, TP-1530): how much of a cap is used. The full form is
    /// 320 pt: its label and value, an 8 pt track and a note; the one-line form is its label, a 6 pt track, the
    /// percent and when it resets, with a stop mark where new work stops.
    public enum ProgressMeter {
        public static let width: Double = 320
        public static let gap: Double = 7
        public static let trackHeight: Double = 8
        /// The track: the fill's colour at 14 % over the sunken surface.
        public static let trackTint: Double = 0.14
        /// The fill's lighter end (70 % of its colour over white) and its glow (45 %, 10 pt).
        public static let fillLight: Double = 0.3
        public static let glowOpacity: Double = 0.45
        public static let glowRadius: Double = 5
        /// The one-line form's columns: label, the track (at least 120 pt), the percent and when it resets.
        public static let lineLabel: Double = 72
        public static let lineTrackMin: Double = 120
        public static let lineValue: Double = 44
        public static let lineResets: Double = 190
        public static let lineGap = Space.s4
        public static let lineTrackHeight: Double = 6
        /// The stop mark: 2 pt wide, 4 pt past the track above and below.
        public static let stopWidth: Double = 2
        public static let stopReach: Double = 4
        /// From this share the fill is orange, and from `atCap` red.
        public static let near = 75
        public static let atCap = 95
    }

    /// The catalog's Text field, Search field and multi-line input (`.field`, `.input`, `.input.search`, `.help`,
    /// `.own-words`, `.tl-compose`; TP-1509): a surface of a control height, its edge and, while focused, a soft halo
    /// outside it; the label above and help, the error or the reason under it, never two of them.
    public enum Field {
        /// What the surface shows: at rest, under the pointer, or with the keyboard.
        public enum State: String, CaseIterable, Equatable {
            case rest, hover, focused
        }

        /// Which input: the text field and the text area (`.input`), or the search field's sunken capsule (`.search`).
        public enum Kind: String, CaseIterable, Equatable {
            case text, search
        }

        /// A colour at an opacity: the hovered edge is the primary text at 28 %.
        public struct Tone: Equatable {
            public var token: ColorToken
            public var opacity: Double

            public init(_ token: ColorToken, opacity: Double = 1) {
                self.token = token
                self.opacity = opacity
            }
        }

        /// What sits under a field: the reason it is off, the error, or its help.
        public enum Footnote: Equatable {
            case reason(String)
            case error(String)
            case help(String)
        }

        /// Between the label, the field and the line under it.
        public static let gap: Double = 6
        /// The room on each side of the text: 70 % of the control's padding (the search field's 75 % before the glyph
        /// and 60 % after the last item).
        public static let paddingScale: Double = 0.7
        public static let searchLeadingScale: Double = 0.75
        public static let searchTrailingScale: Double = 0.6
        /// Between the glyph, the text, the count and the clear button.
        public static let itemGap = Space.s2
        /// The edge, and the halo outside it while focused (the catalog's `0 0 0 4px`, past the 1 pt edge).
        public static let edgeWidth = Control.edgeWidth
        public static let haloWidth: Double = 3
        /// The accented form's edge while focused (the own-words field's `1.5px`), and its halo past it.
        public static let accentedFocusEdge: Double = 1.5
        public static let accentedFocusHalo: Double = 3.5
        /// The hovered text field's edge: the primary text at 28 %.
        public static let hoverEdgeOpacity: Double = 0.28
        /// The hovered search field's surface: the primary text at 3 % over the sunken surface.
        public static let searchHoverOpacity: Double = 0.03
        /// The surface's inner shadow at its top (`inset 0 1px 2px var(--shadow-near)`).
        public static let innerShadowY: Double = 1
        public static let innerShadowBlur: Double = 2
        /// The text's weight: the catalog's 400 at the control's size.
        public static let textWeight = 400
        /// The search glyph and the clear button.
        public static let searchSymbol = "magnifyingglass"
        public static let searchGlyph: Double = 13
        public static let clearSymbol = "xmark"
        public static let clearSize: Double = 16
        public static let clearGlyph: Double = 8
        /// The search field's shortcut, shown while it is empty.
        public static let searchShortcut = "⌘ F"
        /// A search field's width in the window's toolbar.
        public static let toolbarSearchWidth: Double = 220
        /// The error's shake: the field's offsets, in points, at each fraction of `Motion.slowDuration` (the catalog's
        /// `ds-shake`); none under Reduce Motion.
        public static let shakeOffsets: [Double] = [-4, 3, -2, 0]
        public static let shakeTimes: [Double] = [0.2, 0.45, 0.7, 1]
        /// The text area: its radius, its room above and below the text, and its fewest and most lines before it
        /// scrolls (the own-words field starts at three and grows to eight).
        public static let areaRadius = Radius.row
        public static let areaVerticalPadding = Space.s2
        public static let areaMinLines = 3
        public static let areaMaxLines = 8
        /// The keys that send a text area's text.
        public static let sendShortcut = "⌘ ↩"

        /// The surface's colour.
        public static func fill(_ kind: Kind, _ state: State, disabled: Bool) -> ColorToken {
            if disabled { return .surfaceRaised }
            if kind == .search, state != .focused { return .surfaceSunken }
            return .surfaceContent
        }

        /// The edge's colour: the problem colour while invalid, the accent while focused (or `accented`).
        public static func edge(_ kind: Kind, _ state: State, invalid: Bool = false, disabled: Bool = false, accented: Bool = false) -> Tone {
            if disabled { return Tone(.strokeSeparator) }
            if invalid { return Tone(.statusProblem) }
            if state == .focused || accented { return Tone(.accent) }
            switch (kind, state) {
            case (.text, .hover): return Tone(.textPrimary, opacity: hoverEdgeOpacity)
            case (.search, .hover): return Tone(.strokeStrong)
            case (.search, _): return Tone(.strokeSeparator)
            default: return Tone(.strokeStrong)
            }
        }

        /// The halo outside the edge: the accent tint while focused (the problem tint while invalid too), the lighter
        /// accent tint at rest on an `accented` area; none otherwise.
        public static func halo(_ state: State, invalid: Bool = false, disabled: Bool = false, accented: Bool = false) -> ColorToken? {
            if disabled { return nil }
            if state == .focused { return invalid ? .tintProblem : .accentTintStrong }
            if invalid { return nil }
            return accented ? .accentTint : nil
        }

        /// What shows under the field: the reason while it is off, else the error, else the help; one at most.
        public static func footnote(help: String?, error: String?, disabledReason: String?) -> Footnote? {
            if let reason = nonBlank(disabledReason) { return .reason(reason) }
            if let error = nonBlank(error) { return .error(error) }
            if let help = nonBlank(help) { return .help(help) }
            return nil
        }

        private static func nonBlank(_ text: String?) -> String? {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }

        /// The count inside a search field with a query: "3 found", or "None".
        public static func matches(_ count: Int) -> String { count > 0 ? "\(count) found" : "None" }

        /// The line under a search field that found nothing: what it searched.
        public static func noMatch(_ query: String, searched: String) -> String {
            "Nothing matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”. \(searched)"
        }

        /// Whether a search field shows its count, clear button and no-match line: a query that is not only spaces.
        public static func hasQuery(_ query: String) -> Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        /// What Escape does in a search field: clear its query, then give up the keyboard.
        public enum EscapeStep: Equatable { case clear, release }

        public static func escape(query: String) -> EscapeStep { query.isEmpty ? .release : .clear }
    }

    /// The catalog's Table (`.table`, the Table header and row stories; TP-1510): a 32 pt header of short labels whose
    /// sortable ones are small buttons showing their direction, 36 pt rows with the row radius at their ends, every
    /// second one faintly banded; columns that fit their content and columns that share the spare width.
    public enum Table {
        /// The header's height and a row's.
        public static let headerHeight: Double = 32
        public static let rowHeight: Double = 36
        /// The room on each side of a cell's content (`--space-3`).
        public static let cellPadding = Space.s3
        /// A sortable header's button: the small control's height and radius, reaching 8 pt past its cell's padding.
        public static let headerButton = Control.small
        public static let headerButtonOutset = Space.s2
        /// Between a header's label and its sort glyph, and the glyph's size (the catalog's 9 px arrow).
        public static let sortGap = Space.s1
        public static let sortGlyph: Double = 9
        public static let ascendingSymbol = "arrowtriangle.up.fill"
        public static let descendingSymbol = "arrowtriangle.down.fill"
        /// The header's rule under it.
        public static let ruleWidth: Double = 1
        /// The band behind every second row at rest: the catalog's 2.2 % of a dark ink, or of white in dark.
        public static let band = ColorPair(RGBA(24, 24, 48, 0.022), RGBA(255, 255, 255, 0.022))
        /// The fewest points a column that shares the spare width shrinks to before the table scrolls sideways.
        public static let minShareWidth: Double = 80
        /// The empty table's line: its height and its room above the link.
        public static let emptyHeight: Double = 140

        /// How a column's content sits: text at the leading edge, numbers at the trailing edge in tabular figures.
        public enum Alignment: String, CaseIterable, Equatable {
            case text, number
        }

        /// How wide a column is: as wide as its widest content (never squeezed), or a share of the width the fitted
        /// columns leave, down to `minimum`.
        public enum Width: Equatable {
            case fit
            case share(Double, minimum: Double = Table.minShareWidth)

            /// The share's weight; none for a fitted column.
            public var weight: Double? {
                if case let .share(weight, _) = self { return max(weight, 0) }
                return nil
            }
        }

        /// The columns' widths in `available` points: a fitted column gets its `measured` width; the columns that
        /// share split what is left in their weights' proportions, none under its minimum (a share that would be
        /// smaller takes its minimum, and the rest is split again among the others). When even the minimums don't
        /// fit, every sharing column is at its minimum and the total is wider than `available`: the table scrolls.
        public static func widths(available: Double, columns: [Width], measured: [Double]) -> [Double] {
            var widths = columns.indices.map { index -> Double in
                columns[index].weight == nil ? (measured.indices.contains(index) ? max(measured[index], 0) : 0) : 0
            }
            var open = columns.indices.filter { columns[$0].weight != nil }
            var spare = available - widths.reduce(0, +)
            while !open.isEmpty {
                let weights = open.map { columns[$0].weight ?? 0 }
                let total = weights.reduce(0, +)
                let shares = zip(open, weights).map { index, weight in
                    (index, total > 0 ? max(spare, 0) * weight / total : max(spare, 0) / Double(open.count))
                }
                let short = shares.filter { index, share in share < minimum(columns[index]) }
                if short.isEmpty {
                    for (index, share) in shares { widths[index] = share }
                    break
                }
                for (index, _) in short {
                    widths[index] = minimum(columns[index])
                    spare -= widths[index]
                }
                open.removeAll { index in short.contains { $0.0 == index } }
            }
            return widths
        }

        private static func minimum(_ width: Width) -> Double {
            if case let .share(_, minimum) = width { return max(minimum, 0) }
            return 0
        }

        /// The x offset that keeps the first column in place while the table scrolls sideways by `offset`.
        public static func pinnedOffset(scrolled offset: Double) -> Double { max(offset, 0) }

        /// Which column a table is sorted by and which way.
        public struct Sort: Equatable, Hashable {
            public var column: String
            public var ascending: Bool

            public init(_ column: String, ascending: Bool) {
                self.column = column
                self.ascending = ascending
            }

            /// A click on `column`'s header: the same column again reverses; another sorts by it, `firstAscending`
            /// or not (the catalog sorts a new column most first).
            public static func toggled(_ current: Sort?, column: String, firstAscending: Bool = false) -> Sort {
                if let current, current.column == column { return Sort(column, ascending: !current.ascending) }
                return Sort(column, ascending: firstAscending)
            }

            /// The order of two cells' words: numbers by their value (a leading number, its commas, a sign, a
            /// trailing unit or percent left aside), anything else as Finder orders names; `ascending` or reversed.
            public static func ordered(_ lhs: String, _ rhs: String, ascending: Bool) -> Bool {
                let result: ComparisonResult
                if let left = number(lhs), let right = number(rhs) {
                    result = left == right ? .orderedSame : left < right ? .orderedAscending : .orderedDescending
                } else {
                    result = lhs.localizedStandardCompare(rhs)
                }
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }

            /// A cell's number: "1,204", "62%", "3.4M" (a K, M or B scales it), "−12"; nil for words.
            public static func number(_ text: String) -> Double? {
                var body = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
                    .replacingOccurrences(of: "\u{2212}", with: "-")
                var scale = 1.0
                if body.hasSuffix("%") { body.removeLast() }
                if let last = body.last, let factor = ["K": 1e3, "M": 1e6, "B": 1e9][String(last)] {
                    scale = factor
                    body.removeLast()
                }
                return Double(body.trimmingCharacters(in: .whitespaces)).map { $0 * scale }
            }
        }

        /// What VoiceOver reads for a header: its title, then whether it is sorted and which way ("Age, sorted, oldest
        /// first"); `ascending` and `descending` are the column's own words for its directions.
        public static func spokenHeader(_ title: String, sort: Sort?, column: String, ascending: String, descending: String) -> String {
            guard let sort, sort.column == column else { return title }
            return "\(title), sorted, \(sort.ascending ? ascending : descending)"
        }

        /// What VoiceOver reads for a row: each cell after its column's title ("Ticket, TP-1382. Age, 3 h"); an empty
        /// cell is left out.
        public static func spokenRow(titles: [String], cells: [String]) -> String {
            zip(titles, cells).filter { !$0.1.isEmpty }.map { "\($0), \($1)" }.joined(separator: ". ")
        }

        /// The row Up or Down picks from `selected` among `count` rows: the next or the previous, held at the ends;
        /// with nothing picked, Down picks the first and Up the last. Nil when there are no rows.
        public static func moved(_ selected: Int?, by step: Int, count: Int) -> Int? {
            guard count > 0 else { return nil }
            guard let selected, (0 ..< count).contains(selected) else { return step >= 0 ? 0 : count - 1 }
            return min(max(selected + step, 0), count - 1)
        }

        /// Whether row `index` (from 0) is banded: every second one, at rest only (the catalog's even rows).
        public static func banded(_ index: Int, selected: Bool, hovered: Bool) -> Bool {
            index % 2 == 1 && !selected && !hovered
        }

        /// A row's fill: the accent when selected (the pressed grey when the window is not in front), else the hover
        /// overlay, else the band on every second row; none otherwise.
        public enum Fill: Equatable {
            case accent, inactiveSelection, hover, band
        }

        public static func fill(_ index: Int, selected: Bool, hovered: Bool, windowActive: Bool = true) -> Fill? {
            if selected { return windowActive ? .accent : .inactiveSelection }
            if hovered { return .hover }
            return banded(index, selected: selected, hovered: hovered) ? .band : nil
        }
    }

    /// The catalog's Key-value list (`.kv` in `components.css`, TP-1511): labels in a column as wide as the longest,
    /// values beside them; stacked, labels above their values. The Tickets details' list (`.facts`) is the same list
    /// in the secondary style with tighter rows.
    public enum KeyValue {
        /// Between the label column and the values (`gap: … var(--space-4)`).
        public static let columnGap: Double = Space.s4
        /// Between two facts (`gap: 8px …`).
        public static let rowGap: Double = 8
        /// Between two facts of the Tickets details (`.facts`, `gap: 6px …`).
        public static let compactRowGap: Double = 6
        /// Stacked: between a label and its value (`.kv.stacked { gap: 2px }`).
        public static let stackedLabelGap: Double = 2
        /// Stacked: under each value (`.kv.stacked dd { margin-bottom: var(--space-2) }`).
        public static let stackedValueGap: Double = Space.s2
        /// Between the parts of a value that are several things, chips or a path and its button (`dd { gap: … }`).
        public static let valueGap: Double = Space.s2
        /// Between two groups (`.kv-group + .kv-group { margin-top: var(--space-4) }`).
        public static let groupGap: Double = Space.s4
        /// Under a group's heading (`.kv-group h4 { margin: 0 0 var(--space-2) }`).
        public static let groupHeadingGap: Double = Space.s2
        /// A group's heading's letter spacing, as a fraction of its size (`letter-spacing: 0.08em`).
        public static let groupHeadingTracking: Double = 0.08
        /// Narrower than this, a list is stacked ("labels above values, under 300 pt").
        public static let stackedBelow: Double = 300

        /// How a list lays its facts out.
        public enum Layout: String, CaseIterable, Equatable {
            /// Two columns: labels on the left in a column as wide as the longest.
            case columns
            /// Each label above its value, for a narrow place.
            case stacked

            /// Two columns at `width` and wider, stacked under `stackedBelow`.
            public static func fitting(_ width: Double) -> Layout { width < stackedBelow ? .stacked : .columns }
        }
    }

    /// The catalog's Collapsible card (`.collapsible` and `.fold` in `components.css`, TP-1511): a head with the
    /// disclosure chevron, the title and a summary at the trailing end, over a body that folds away.
    public enum Collapsible {
        /// The head's least height (`min-height: 48px`).
        public static let headMinHeight: Double = 48
        /// The head's padding above and below (`padding: var(--space-3) …`).
        public static let headVerticalPadding: Double = Space.s3
        /// The head's padding at the sides (`padding: … var(--space-5)`).
        public static let headHorizontalPadding: Double = Space.s5
        /// Between the chevron, the title and the summary (`gap: var(--space-2)`).
        public static let headGap: Double = Space.s2
        /// The disclosure chevron's size (`.disclose { width: 10px }`).
        public static let chevronSize: Double = 10
        /// The body's padding at the leading side: under the title, past the chevron (`calc(var(--space-3) + 6px)`).
        public static let bodyLeadingPadding: Double = Space.s3 + 6
        /// The body's padding at the trailing side and under it (`padding: 0 var(--space-3) var(--space-3) …`).
        public static let bodyPadding: Double = Space.s3
        /// How far a row of an opening body comes down from (`--enter-offset`).
        public static let rowEnterOffset: Double = 6
        /// What the summary says when the card cannot open: there is nothing in it.
        public static let emptySummary = "None yet"

        /// The summary's opacity: there while folded, faded away while open.
        public static func summaryOpacity(expanded: Bool) -> Double { expanded ? 0 : 1 }

        /// The chevron's turn in degrees: right while folded, down while open.
        public static func chevronDegrees(expanded: Bool) -> Double { expanded ? 90 : 0 }

        /// What VoiceOver reads after the head's title: its state, then the summary ("collapsed, 3 runs"); an empty
        /// card reads "None yet".
        public static func spokenValue(expanded: Bool, summary: String?, empty: Bool) -> String {
            if empty { return emptySummary }
            let state = expanded ? "expanded" : "collapsed"
            guard let summary, !summary.isEmpty, !expanded else { return state }
            return "\(state), \(summary)"
        }
    }

    /// The main window's layout (§3.5).
    public enum Layout {
        public static let windowWidth: Double = 1200
        /// Home's two lists are at most this wide, centred on a wide window (`.home`).
        public static let homeMaxWidth: Double = 1480
        public static let windowHeight: Double = 760
        public static let minWindowWidth: Double = 960
        public static let minWindowHeight: Double = 600
        /// The sidebar's width (`.win { --side-w: 232px }`), and folded to its glyphs.
        public static let sidebarWidth: Double = Sidebar.width
        public static let collapsedSidebarWidth: Double = Sidebar.collapsedWidth
        /// The list column of the Inbox (and later Initiatives).
        public static let listColumnWidth: Double = 340
        public static let minListColumnWidth: Double = 300
        public static let maxListColumnWidth: Double = 420
        /// Under this width the Inbox's review is a narrow pane: an option card's Recommended badge moves under its
        /// label, and the key hints hide.
        public static let narrowReviewWidth: Double = 560
    }
}
