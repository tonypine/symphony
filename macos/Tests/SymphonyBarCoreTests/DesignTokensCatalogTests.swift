import XCTest
@testable import SymphonyBarCore

/// The catalog's `docs/design/catalog/tokens.css` against `DesignTokens`: every custom property the CSS defines has its
/// Swift counterpart with the same value, in light and dark and under Increase Contrast, or is listed in
/// `notInSwift` with the reason it has none. A token added to the CSS without either fails here.
final class DesignTokensCatalogTests: XCTestCase {
    /// The CSS tokens with no Swift counterpart, and why.
    static let notInSwift: [String: String] = [
        "--font-text": "A browser's font stack; the app sets the system font by `TypeStyle.family`.",
        "--font-display": "A browser's font stack; the app sets the system font by `TypeStyle.family`.",
        "--font-mono": "A browser's font stack; the app sets the system monospaced font by `TypeStyle.family`.",
        "--accent-fill": "Mixed from `--accent` with color-mix(); the default button's fill is a component, not a token.",
        "--accent-fill-hover": "Mixed from `--accent-hover` with color-mix(); a component's, as `--accent-fill`.",
        "--accent-glow": "Mixed from `--accent` with color-mix(); the default button's glow is a component's.",
        "--radius-capsule": "A CSS stand-in for half the height; SwiftUI draws a capsule with `Capsule()`.",
        "--ease-standard": "A CSS curve; SwiftUI's `.smooth` stands in for it (`Motion.Curve`).",
        "--ease-enter": "A CSS curve; SwiftUI's `.smooth` stands in for it (`Motion.Curve`).",
        "--ease-exit": "A CSS curve; SwiftUI's `.smooth` stands in for it (`Motion.Curve`).",
        "--ease-spring": "A CSS spring sampled with linear(); SwiftUI's `.spring(bounce:)` is the spring itself.",
        "--ease-bounce": "A CSS spring sampled with linear(); SwiftUI's `.spring(bounce:)` is the spring itself.",
        "--enter-offset": "The Enter pattern of menus, toasts and sheets, which the system draws in the app.",
        "--enter-scale": "The Enter pattern of menus, toasts and sheets, which the system draws in the app.",
    ]

    // MARK: - Every token

    func testEveryTokenInTheCatalogHasItsSwiftValue() throws {
        let css = try Self.catalog()
        let base = try Self.declarations(css, after: nil)
        XCTAssertFalse(base.isEmpty)
        let checks = Self.checks()
        for (name, value) in base.sorted(by: { $0.key < $1.key }) where Self.notInSwift[name] == nil {
            guard let check = checks[name] else {
                XCTFail("\(name) is in tokens.css with no Swift counterpart: add it to DesignTokens, or to notInSwift with why")
                continue
            }
            check(value, name)
        }
        // Each Swift token named after the CSS is still there.
        for name in checks.keys.sorted() { XCTAssertNotNil(base[name], "\(name) is no longer in tokens.css") }
        for name in Self.notInSwift.keys.sorted() { XCTAssertNotNil(base[name], "\(name) is listed but not in tokens.css") }
    }

    func testEveryColourHasItsIncreaseContrastValue() throws {
        let css = try Self.catalog()
        let increased = try Self.declarations(css, after: "@media (prefers-contrast: more)")
        for token in DesignTokens.ColorToken.allCases {
            guard let value = increased[token.cssName] else {
                XCTFail("\(token.cssName) has no Increase Contrast value in tokens.css")
                continue
            }
            XCTAssertEqual(try Self.colorPair(value), token.values.increased, token.cssName)
        }
        XCTAssertEqual(increased["--backdrop-glow"], "none")
        XCTAssertEqual(DesignTokens.Backdrop.glows(increaseContrast: true), [])
        let known = Set(DesignTokens.ColorToken.allCases.map(\.cssName) + ["--backdrop-glow"])
        for name in increased.keys.sorted() { XCTAssertTrue(known.contains(name), "\(name) under Increase Contrast has no Swift value") }
    }

    // MARK: - Contrast

    /// §6: text keeps 4.5:1 on the window, content and raised surfaces, in light and dark and under Increase
    /// Contrast. Tertiary text is for placeholders and disabled text, which the rule exempts, except under Increase
    /// Contrast, where it meets it too.
    func testTextKeepsItsContrastOnEverySurface() {
        let surfaces: [DesignTokens.ColorToken] = [.surfaceWindow, .surfaceContent, .surfaceRaised]
        let texts: [DesignTokens.ColorToken] = [.textPrimary, .textSecondary, .accentText]
            + DesignTokens.Status.allCases.map(\.textColor)
        for dark in [false, true] {
            for increased in [false, true] {
                let mode = "\(dark ? "dark" : "light")\(increased ? ", Increase Contrast" : "")"
                for surface in surfaces {
                    let background = surface.values.value(dark: dark, increaseContrast: increased)
                    for text in texts + (increased ? [.textTertiary] : []) {
                        let ratio = text.values.value(dark: dark, increaseContrast: increased).contrast(on: background)
                        XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(text.cssName) on \(surface.cssName), \(mode)")
                    }
                }
                let accent = DesignTokens.ColorToken.accent.values.value(dark: dark, increaseContrast: increased)
                let onAccent = DesignTokens.ColorToken.textOnAccent.values.value(dark: dark, increaseContrast: increased)
                XCTAssertGreaterThanOrEqual(onAccent.contrast(on: accent), 4.5, "text on the accent, \(mode)")
            }
        }
    }

    func testContrastIsWCAGs() {
        let black = DesignTokens.RGBA(hex: 0x000000)
        let white = DesignTokens.RGBA(hex: 0xFFFFFF)
        XCTAssertEqual(black.contrast(on: white), 21, accuracy: 1e-9)
        XCTAssertEqual(white.contrast(on: white), 1, accuracy: 1e-9)
        // A translucent colour is laid over its background first.
        XCTAssertEqual(DesignTokens.RGBA(0, 0, 0, 0.5).over(white), DesignTokens.RGBA(128, 128, 128))
        XCTAssertEqual(DesignTokens.RGBA(0, 0, 0, 0).contrast(on: white), 1, accuracy: 1e-9)
    }

    // MARK: - Type

    func testTheTypeScaleIsTheCatalogs() {
        XCTAssertEqual(DesignTokens.TypeStyle.title.weight, 700)
        XCTAssertEqual(DesignTokens.TypeStyle.title.size, 26)
        XCTAssertEqual(DesignTokens.TypeStyle.title.lineHeight, 32)
        XCTAssertEqual(DesignTokens.TypeStyle.title.tracking, -0.022)
        XCTAssertEqual(DesignTokens.TypeStyle.reading.lineHeight, 16 * 1.4, accuracy: 1e-9)
        XCTAssertEqual(DesignTokens.TypeStyle.reading.tracking, 0.02)
        XCTAssertNil(DesignTokens.TypeStyle.figure.cssName)
        // The system's text size scales size and line height alike.
        XCTAssertEqual(DesignTokens.TypeStyle.body.scaledSize(by: 1.25), 16.25)
        XCTAssertEqual(DesignTokens.TypeStyle.body.scaledLineHeight(by: 2), 38)
    }

    func testWeightsMapOntoAppKitsScale() {
        XCTAssertEqual(DesignTokens.TypeStyle.body.systemWeight, 0)
        XCTAssertEqual(DesignTokens.TypeStyle.heading.systemWeight, 0.3)
        XCTAssertEqual(DesignTokens.TypeStyle.title.systemWeight, 0.4)
        XCTAssertEqual(DesignTokens.TypeStyle.caption.systemWeight, 0.23)
        // The catalog's in-between weights fall between AppKit's named ones.
        XCTAssertEqual(DesignTokens.TypeStyle.sentence.systemWeight, 0.35, accuracy: 1e-9)
        XCTAssertEqual(DesignTokens.TypeStyle.label.systemWeight, 0.265, accuracy: 1e-9)
        XCTAssertEqual(DesignTokens.TypeStyle.mono.systemWeight, 0.115, accuracy: 1e-9)
    }

    // MARK: - Surfaces, glass and the backdrop

    func testSurfacesAndGlassAreTheirTokens() {
        XCTAssertEqual(DesignTokens.Surface.window, .surfaceWindow)
        XCTAssertEqual(DesignTokens.Surface.content, .surfaceContent)
        XCTAssertEqual(DesignTokens.Surface.raised, .surfaceRaised)
        XCTAssertEqual(DesignTokens.Backdrop.surface, .surfaceWindow)
        XCTAssertEqual(DesignTokens.Backdrop.glows(increaseContrast: false), DesignTokens.Backdrop.glows)
        // Reduce Transparency draws each glass as its solid surface.
        XCTAssertEqual(DesignTokens.Glass.glass.drawn(reduceTransparency: false), .materialGlass)
        XCTAssertEqual(DesignTokens.Glass.glass.drawn(reduceTransparency: true), .surfaceRaised)
        XCTAssertEqual(DesignTokens.Glass.thick.drawn(reduceTransparency: false), .materialGlassThick)
        XCTAssertEqual(DesignTokens.Glass.thick.drawn(reduceTransparency: true), .surfaceContent)
        // A state's surface is its token, translucent over what is under it.
        XCTAssertEqual(DesignTokens.StateSurface.allCases.map(\.color), [.surfaceHover, .surfacePressed, .accentTint])
        XCTAssertEqual(DesignTokens.Motion.enterTint, .accentTint)
    }

    func testAppearancesPickTheirValue() {
        let token = DesignTokens.ColorToken.textSecondary.values
        XCTAssertEqual(token.value(dark: false, increaseContrast: false), DesignTokens.RGBA(hex: 0x5C5C6E))
        XCTAssertEqual(token.value(dark: true, increaseContrast: false), DesignTokens.RGBA(hex: 0xA5A5B4))
        XCTAssertEqual(token.value(dark: false, increaseContrast: true), DesignTokens.RGBA(hex: 0x3C3C4A))
        XCTAssertEqual(token.value(dark: true, increaseContrast: true), DesignTokens.RGBA(hex: 0xCFCFD9))
        XCTAssertEqual(DesignTokens.RGBA(1, 2, 3, 0.5).description, "rgba(1, 2, 3, 0.5)")
    }

    // MARK: - The checks

    typealias Check = (_ value: String, _ name: String) -> Void

    /// Each CSS token's check against its Swift value.
    static func checks() -> [String: Check] {
        var checks: [String: Check] = [:]
        for token in DesignTokens.ColorToken.allCases {
            checks[token.cssName] = { value, name in XCTAssertEqual(try colorPair(value), token.values.standard, name) }
        }
        for style in DesignTokens.TypeStyle.allCases {
            guard let cssName = style.cssName else { continue }
            checks[cssName] = { value, name in
                guard let type = try? typeStyle(value) else { return XCTFail("\(name): can't read \(value)") }
                XCTAssertEqual(type.weight, style.weight, name)
                XCTAssertEqual(type.size, style.size, name)
                XCTAssertEqual(type.lineHeight, style.lineHeight, accuracy: 1e-9, name)
                XCTAssertEqual(type.family, style.family.rawValue, name)
            }
        }
        func length(_ expected: Double) -> Check { { value, name in XCTAssertEqual(try number(value, unit: "px"), expected, name) } }
        func ratio(_ expected: Double, _ unit: String) -> Check { { value, name in XCTAssertEqual(try number(value, unit: unit), expected, name) } }
        func duration(_ expected: Double) -> Check { { value, name in XCTAssertEqual(try seconds(value), expected, name) } }

        checks["--tracking-display"] = ratio(DesignTokens.Tracking.display, "em")
        checks["--tracking-label"] = ratio(DesignTokens.Tracking.label, "em")
        checks["--tracking-reading"] = ratio(DesignTokens.Tracking.reading, "em")
        checks["--measure"] = ratio(Double(DesignTokens.Measure.characters), "ch")
        checks["--measure-narrow"] = ratio(Double(DesignTokens.Measure.narrowCharacters), "ch")
        let space = DesignTokens.Space.self
        for (step, value) in [(1, space.s1), (2, space.s2), (3, space.s3), (4, space.s4), (5, space.s5), (6, space.s6), (8, space.s8), (10, space.s10)] {
            checks["--space-\(step)"] = length(value)
        }
        for (size, suffix) in [(DesignTokens.Control.small, "sm"), (.medium, "md"), (.large, "lg")] {
            checks["--control-\(suffix)"] = length(size.height)
            checks["--radius-control-\(suffix)"] = length(size.radius)
        }
        checks["--radius-control"] = { value, name in XCTAssertEqual(value, "var(--radius-control-md)", name) }
        checks["--radius-sheet"] = length(DesignTokens.Radius.sheet)
        checks["--radius-card"] = length(DesignTokens.Radius.card)
        checks["--radius-row"] = length(DesignTokens.Radius.row)
        checks["--radius-mark"] = length(DesignTokens.Radius.mark)
        checks["--material-blur"] = { value, name in
            XCTAssertEqual(value, "blur(\(format(DesignTokens.Glass.blur))px) saturate(1.8)", name)
        }
        checks["--backdrop-glow"] = { value, name in XCTAssertEqual(try glows(value), DesignTokens.Backdrop.glows, name) }
        for level in DesignTokens.Elevation.allCases {
            checks["--elevation-\(level.rawValue)"] = { value, name in
                if level.shadows.isEmpty { return XCTAssertEqual(value, "none", name) }
                XCTAssertEqual(try shadows(value), level.shadows, name)
            }
        }
        checks["--edge-highlight"] = { value, name in
            XCTAssertTrue(value.hasPrefix("inset "), name)
            XCTAssertEqual(try shadows(String(value.dropFirst("inset ".count))), [DesignTokens.Elevation.edgeHighlight], name)
        }
        let motion = DesignTokens.Motion.self
        checks["--motion-instant"] = duration(motion.instantDuration)
        checks["--motion-fast"] = duration(motion.fastDuration)
        checks["--motion-standard"] = duration(motion.standardDuration)
        checks["--motion-slow"] = duration(motion.slowDuration)
        checks["--motion-spring"] = duration(motion.springDuration)
        checks["--motion-stagger"] = duration(motion.stagger)
        checks["--motion-hover-delay"] = duration(DesignTokens.Chip.hoverDelay)
        checks["--press-scale"] = ratio(motion.pressScale, "")
        checks["--lift"] = length(-motion.lift)
        checks["--focus-ring-width"] = length(DesignTokens.FocusRing.width)
        checks["--focus-ring-offset"] = length(DesignTokens.FocusRing.offset)
        return checks
    }

    // MARK: - Reading tokens.css

    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    static func catalog() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let css = try String(contentsOf: root.appendingPathComponent("docs/design/catalog/tokens.css"), encoding: .utf8)
        return css.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
    }

    /// The custom properties of the first `:root` block after `marker` (the file's first without one).
    static func declarations(_ css: String, after marker: String?) throws -> [String: String] {
        var rest = Substring(css)
        if let marker {
            guard let found = rest.range(of: marker) else { throw ParseError(description: "no \(marker)") }
            rest = rest[found.upperBound...]
        }
        guard let open = rest.range(of: ":root {") else { throw ParseError(description: "no :root block") }
        rest = rest[open.upperBound...]
        guard let close = rest.firstIndex(of: "}") else { throw ParseError(description: "an unclosed :root block") }
        var declarations: [String: String] = [:]
        for declaration in rest[..<close].split(separator: ";") {
            let trimmed = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("--"), let colon = trimmed.firstIndex(of: ":") else { continue }
            let value = trimmed[trimmed.index(after: colon)...]
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            declarations[String(trimmed[..<colon])] = value
        }
        return declarations
    }

    /// `value`'s top-level comma-separated parts.
    static func parts(_ value: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        for character in value {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if character == ",", depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts
    }

    /// The inside of `function(…)`.
    static func arguments(_ value: String, of function: String) throws -> String {
        guard value.hasPrefix(function + "("), value.hasSuffix(")") else {
            throw ParseError(description: "\(value) is not \(function)()")
        }
        return String(value.dropFirst(function.count + 1).dropLast())
    }

    static func colorPair(_ value: String) throws -> DesignTokens.ColorPair {
        if value.hasPrefix("light-dark(") {
            let pair = parts(try arguments(value, of: "light-dark"))
            guard pair.count == 2 else { throw ParseError(description: "\(value) is not a pair") }
            return DesignTokens.ColorPair(try color(pair[0]), try color(pair[1]))
        }
        let single = try color(value)
        return DesignTokens.ColorPair(single, single)
    }

    static func color(_ value: String) throws -> DesignTokens.RGBA {
        if value.hasPrefix("#"), value.count == 7, let hex = UInt32(value.dropFirst(), radix: 16) {
            return DesignTokens.RGBA(hex: hex)
        }
        let channels = parts(try arguments(value, of: "rgba"))
        guard channels.count == 4, let red = UInt8(channels[0]), let green = UInt8(channels[1]), let blue = UInt8(channels[2]),
              let alpha = Double(channels[3])
        else { throw ParseError(description: "\(value) is not a colour") }
        return DesignTokens.RGBA(red, green, blue, alpha)
    }

    static func number(_ value: String, unit: String) throws -> Double {
        guard value.hasSuffix(unit), let number = Double(value.dropLast(unit.count)) else {
            if value == "0" { return 0 }
            throw ParseError(description: "\(value) is not a number in \(unit.isEmpty ? "no unit" : unit)")
        }
        return number
    }

    static func seconds(_ value: String) throws -> Double {
        value.hasSuffix("ms") ? try number(value, unit: "ms") / 1000 : try number(value, unit: "s")
    }

    /// `W Spx/LHpx var(--font-family)`, or a unitless line height that multiplies the size.
    static func typeStyle(_ value: String) throws -> (weight: Int, size: Double, lineHeight: Double, family: String) {
        let words = value.split(separator: " ").map(String.init)
        guard words.count == 3, let weight = Int(words[0]) else { throw ParseError(description: "\(value) is not a type style") }
        let metrics = words[1].split(separator: "/").map(String.init)
        guard metrics.count == 2 else { throw ParseError(description: "\(value) has no line height") }
        let size = try number(metrics[0], unit: "px")
        let lineHeight = metrics[1].hasSuffix("px") ? try number(metrics[1], unit: "px") : try number(metrics[1], unit: "") * size
        let family = try arguments(words[2], of: "var")
        guard family.hasPrefix("--font-") else { throw ParseError(description: "\(value) has no font family") }
        return (weight, size, lineHeight, String(family.dropFirst("--font-".count)))
    }

    /// `X Y BLUR [SPREAD] var(--colour)`, comma-separated.
    static func shadows(_ value: String) throws -> [DesignTokens.Elevation.Shadow] {
        try parts(value).map { shadow in
            var words = shadow.split(separator: " ").map(String.init)
            guard let last = words.popLast(), words.count == 3 || words.count == 4 else {
                throw ParseError(description: "\(shadow) is not a shadow")
            }
            let name = try arguments(last, of: "var")
            guard let color = DesignTokens.ColorToken.allCases.first(where: { $0.cssName == name }) else {
                throw ParseError(description: "\(name) is not a colour token")
            }
            let numbers = try words.map { try number($0, unit: "px") }
            return DesignTokens.Elevation.Shadow(
                x: numbers[0], y: numbers[1], blur: numbers[2], spread: numbers.count == 4 ? numbers[3] : 0, color: color
            )
        }
    }

    /// `radial-gradient(Wpx Hpx at X% Y%, colour, transparent F%)`, comma-separated.
    static func glows(_ value: String) throws -> [DesignTokens.Backdrop.Glow] {
        try parts(value).map { gradient in
            let stops = parts(try arguments(gradient, of: "radial-gradient"))
            guard stops.count == 3 else { throw ParseError(description: "\(gradient) is not a glow") }
            let shape = stops[0].split(separator: " ").map(String.init)
            guard shape.count == 5, shape[2] == "at" else { throw ParseError(description: "\(stops[0]) is not a glow's shape") }
            let fade = stops[2].split(separator: " ").map(String.init)
            guard fade.count == 2, fade[0] == "transparent" else { throw ParseError(description: "\(stops[2]) is not a fade") }
            return DesignTokens.Backdrop.Glow(
                width: try number(shape[0], unit: "px"), height: try number(shape[1], unit: "px"),
                centerX: try number(shape[3], unit: "%") / 100, centerY: try number(shape[4], unit: "%") / 100,
                color: try colorPair(stops[1]), fade: try number(fade[1], unit: "%") / 100
            )
        }
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
