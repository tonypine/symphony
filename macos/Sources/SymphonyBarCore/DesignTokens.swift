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
