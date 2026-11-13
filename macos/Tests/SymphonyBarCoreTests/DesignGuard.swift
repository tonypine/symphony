import Foundation

/// The design guard (TP-1493): finds the places where a view draws with a raw style value instead of a
/// `DesignTokens` value or a shared component, and checks their count per file against a committed baseline that can
/// only go down. `DesignGuardTests` runs it over the app's sources; this file holds no XCTest so the scanner can be
/// built on its own.
enum DesignGuard {
    /// The kinds of bypass the guard counts. `frame` is counted and reported, and fails nothing yet.
    enum Kind: String, CaseIterable, Comparable {
        /// A system text style or a literal size passed to `.font(`.
        case font
        /// A system hierarchical or named colour passed to a colour modifier.
        case color
        /// `NSColor.…`, `Color(nsColor:`, `Color(red:` and the other raw colour initialisers.
        case rawColor
        /// A numeric literal in `.padding(`, `spacing:`, `cornerRadius`, `.shadow(` or `lineWidth:`.
        case number
        /// A `Button(` or `Button {` whose modifiers take neither the shared button style (`.directorButton(`,
        /// `.buttonStyle(DirectorButtonStyle(`) nor stand in for the shared icon button (TP-1505).
        case button
        /// A `.disabled(`: a control turned off without saying why (TP-1505).
        case disabled
        /// A `Circle()` filled or styled with a status colour: a status dot drawn by hand instead of `StatusDot`
        /// (TP-1506).
        case dot
        /// A stock `Picker(`: a choice drawn by the system instead of `SegmentedControl` or `PopUp` (TP-1508).
        case picker
        /// A stock `Menu(` or `Menu {`: a menu drawn by the system instead of `MenuButton` (TP-1508). A context
        /// menu stays the system's; a submenu inside one still counts.
        case menu
        /// A numeric literal in `.frame(`: reported only.
        case frame

        /// The kinds that fail the guard.
        static let guarded: [Kind] = [.font, .color, .rawColor, .number, .button, .disabled, .dot, .picker, .menu]

        static func < (lhs: Kind, rhs: Kind) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    /// One raw value at one place.
    struct Bypass: Equatable {
        var file: String
        var line: Int
        var kind: Kind
        /// The raw value as written, such as `.title3` or `12`.
        var value: String
        /// The token or component to use in its place.
        var use: String

        var message: String { "\(file):\(line): \(kind.rawValue) bypass \(value): use \(use)" }
    }

    /// The source folders the guard reads, under `macos/Sources`.
    static let folders = ["SymphonyBar", "SymphonyBarUI"]

    /// The files that define the design system, relative to `macos/Sources`. Any file under a `DesignSystem` folder is
    /// exempt too. There is no other exemption, and no comment waives a line.
    static let exemptFiles: Set<String> = [
        "SymphonyBarCore/DesignTokens.swift",
        "SymphonyBarUI/DesignSystem.swift",
        "SymphonyBarUI/InteractionStyles.swift",
    ]

    static func isExempt(_ path: String) -> Bool {
        exemptFiles.contains(path) || path.split(separator: "/").dropLast().contains("DesignSystem")
    }

    // MARK: - Scanning

    /// Every `.swift` file under the guarded folders, relative to `sources`, skipping exempt ones, sorted.
    static func sourceFiles(in sources: URL) throws -> [String] {
        var paths: [String] = []
        for folder in folders {
            let root = sources.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let relative = folder + url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count)
                if !isExempt(relative) { paths.append(relative) }
            }
        }
        return paths.sorted()
    }

    /// Every bypass in every guarded file under `sources`.
    static func scan(sources: URL) throws -> [Bypass] {
        try sourceFiles(in: sources).flatMap { path in
            try scan(String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8), file: path)
        }
    }

    /// Every bypass in one file's source, in order.
    static func scan(_ source: String, file: String) -> [Bypass] {
        let blanked = blankCommentsAndStrings(source)
        let code = Array(blanked.utf16)
        let text = blanked as NSString
        var found: [Int: (Kind, String, String)] = [:]
        func record(_ offset: Int, _ kind: Kind, _ value: String, _ use: String) {
            if found[offset] == nil { found[offset] = (kind, value, use) }
        }

        for range in arguments(of: [".font("], in: code) {
            for match in matches(fontRegex, in: text, range: range) {
                record(match.offset, .font, match.text, fontReplacement(match.text, in: text.substring(with: NSRange(location: range.lowerBound, length: range.count))))
            }
        }
        for range in arguments(of: colorCalls, in: code) {
            for match in matches(colorRegex, in: text, range: range) {
                record(match.offset, .color, match.text, colorReplacement(match.text))
            }
        }
        // A font or colour kept in a property (`var nameFont: Font { .system(size: 11) }`) counts as well.
        for match in matches(fontAnywhereRegex, in: text, range: 0..<code.count) {
            let rest = text.lineRange(for: NSRange(location: match.offset, length: 0))
            record(match.offset, .font, match.text, fontReplacement(match.text, in: text.substring(with: rest)))
        }
        for match in matches(colorAnywhereRegex, in: text, range: 0..<code.count) {
            record(match.offset, .color, match.text, colorReplacement(match.text))
        }
        for match in matches(rawColorRegex, in: text, range: 0..<code.count) {
            record(match.offset, .rawColor, match.text, "a `DesignTokens.ColorToken` (`.color` in SwiftUI, `.nsColor` in AppKit)")
        }
        for (calls, use) in numberCalls {
            for range in arguments(of: calls, in: code) {
                for match in matches(numberRegex, in: text, range: range) where !isZero(match.text) {
                    record(match.offset, .number, match.text, use(match.text))
                }
            }
        }
        for (label, use) in numberLabels {
            for range in labelledValues(label, in: code) {
                for match in matches(numberRegex, in: text, range: range) where !isZero(match.text) {
                    record(match.offset, .number, match.text, use(match.text))
                }
            }
        }
        for offset in unstyledButtons(in: code, text: text) {
            record(offset, .button, "Button", buttonReplacement)
        }
        for match in matches(disabledRegex, in: text, range: 0..<code.count) {
            record(match.offset, .disabled, ".disabled(", disabledReplacement)
        }
        for offset in statusDots(in: code, text: text) {
            record(offset, .dot, "Circle()", dotReplacement)
        }
        for match in matches(pickerRegex, in: text, range: 0..<code.count) {
            record(match.offset, .picker, "Picker", pickerReplacement)
        }
        for match in matches(menuRegex, in: text, range: 0..<code.count) {
            record(match.offset, .menu, "Menu", menuReplacement)
        }
        for range in arguments(of: [".frame("], in: code) {
            for match in matches(numberRegex, in: text, range: range) where !isZero(match.text) {
                record(match.offset, .frame, match.text, "a `DesignTokens.Layout` or `DesignTokens.Control` measure")
            }
        }

        let lineStarts = lineOffsets(code)
        return found.keys.sorted().map { offset in
            let (kind, value, use) = found[offset]!
            return Bypass(file: file, line: line(of: offset, in: lineStarts), kind: kind, value: value, use: use)
        }
    }

    // MARK: - Patterns

    /// The calls whose argument is a colour or shape style.
    static let colorCalls = [
        ".foregroundStyle(", ".foregroundColor(", ".background(", ".fill(", ".stroke(", ".strokeBorder(", ".tint(",
    ]

    static let systemTextStyles = [
        "largeTitle", "title", "title2", "title3", "headline", "subheadline", "body", "callout", "footnote", "caption",
        "caption2",
    ]
    static let hierarchicalStyles = ["primary", "secondary", "tertiary", "quaternary", "quinary", "separator", "placeholder"]
    static let namedColors = [
        "red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink", "brown", "white",
        "black", "gray", "accentColor",
    ]

    /// A leading-dot member (`.title3`) or one on `Font` (`Font.title3`), not one on a token (`TypeStyle.body`).
    static func memberPattern(_ names: [String], type: String) -> String {
        #"(?:(?<![\w)\]?!])\.|\b"# + type + #"\.)(?:"# + names.joined(separator: "|") + #")\b"#
    }

    static let fontPattern = memberPattern(systemTextStyles + ["system", "custom"], type: "Font")
    static let colorPattern = memberPattern(hierarchicalStyles + namedColors, type: "Color")
    /// A raw font wherever it is written: on `Font`, `.system(size:` and AppKit's system fonts.
    static let fontAnywherePattern = #"\bFont\.(?:"# + (systemTextStyles + ["system", "custom"]).joined(separator: "|")
        + #")\b|(?<![\w)\]?!])\.system\(size:|\.(?:systemFont|boldSystemFont|monospacedSystemFont|monospacedDigitSystemFont)\(ofSize:"#
    /// A system colour on `Color` wherever it is written.
    static let colorAnywherePattern = #"\bColor\.(?:"# + (hierarchicalStyles + namedColors).joined(separator: "|") + #")\b"#
    static let rawColorPattern =
        #"\bNSColor\.\w+|\b(?:Color|SwiftUI\.Color)\(\s*(?:nsColor|red|white|hue|hex|cgColor|\.sRGB\w*|\.displayP3)\b"#
    static let numberPattern = #"(?<![\w.])\d+(?:\.\d+)?(?![\w.])"#
    /// A button's initialiser, not a longer name (`IconButton(`) or a member (`.Button(`).
    static let buttonPattern = #"(?<![\w.])Button\s*[({]"#
    static let disabledPattern = #"\.disabled\("#
    /// A circle's initialiser, not a longer name (`StatusDot(`).
    static let circlePattern = #"(?<![\w.])Circle\(\s*\)"#
    /// A stock picker's initialiser, not a longer name (`DatePicker(`, `ScopePicker(`).
    static let pickerPattern = #"(?<![\w.])Picker\s*\("#
    /// A stock menu's initialiser, not a longer name (`MenuButton(`, `.contextMenu {`).
    static let menuPattern = #"(?<![\w.])Menu\s*[({]"#
    /// A status colour: anything on a status (`row.status.tint`, `DesignTokens.Status.idle`), a `.tint`, or a named
    /// status hue.
    static let statusColourPattern = #"\b[Ss]tatus\b|\.tint\b|\.(?:green|orange|red|blue|gray)\b"#

    static let fontRegex = regex(fontPattern)
    static let colorRegex = regex(colorPattern)
    static let rawColorRegex = regex(rawColorPattern)
    static let fontAnywhereRegex = regex(fontAnywherePattern)
    static let colorAnywhereRegex = regex(colorAnywherePattern)
    static let numberRegex = regex(numberPattern)
    static let buttonRegex = regex(buttonPattern)
    static let disabledRegex = regex(disabledPattern)
    static let circleRegex = regex(circlePattern)
    static let pickerRegex = regex(pickerPattern)
    static let menuRegex = regex(menuPattern)
    static let statusColourRegex = regex(statusColourPattern)

    static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants, checked by the tests.
        try! NSRegularExpression(pattern: pattern)
    }

    static func isZero(_ literal: String) -> Bool { Double(literal) == 0 }

    /// The calls whose numeric literals are spacing, radius or shadow values, with what to use instead.
    static let numberCalls: [([String], (String) -> String)] = [
        ([".padding("], spaceReplacement),
        ([".cornerRadius("], radiusReplacement),
        ([".shadow("], { _ in "`.elevation(_:in:)` with a `DesignTokens.Elevation` level" }),
    ]

    /// The labelled arguments whose value is a spacing, radius or line width.
    static let numberLabels: [(String, (String) -> String)] = [
        ("spacing:", spaceReplacement),
        ("cornerRadius:", radiusReplacement),
        ("lineWidth:", { _ in
            "`DesignTokens.Selection.rowRingWidth`, `.cardRingWidth` or `DesignTokens.FocusRing.width`, or a new width token"
        }),
    ]

    // MARK: - Buttons

    static let buttonReplacement =
        "`.directorButton(_:size:glyph:selected:disabledReason:)` for a labelled button, or `IconButton` for a glyph alone"
    static let disabledReplacement =
        "`.directorButton(…, disabledReason:)`, `IconButton(…, disabledReason:)` or `.disabledReason(_:)`: a control that is off says why"

    /// The modifiers that give a button the shared style.
    static func isSharedStyle(_ modifier: String) -> Bool {
        modifier == "directorButton" || modifier == "buttonStyle(DirectorButtonStyle"
    }

    /// The offset of each button whose chain of modifiers takes no shared style.
    static func unstyledButtons(in code: [UInt16], text: NSString) -> [Int] {
        matches(buttonRegex, in: text, range: 0..<code.count).compactMap { match in
            let open = match.offset + match.text.utf16.count - 1
            return modifiers(after: open, in: code).contains(where: isSharedStyle) ? nil : match.offset
        }
    }

    /// The modifiers chained onto the call whose `(` or `{` is at `open`, past its trailing closures (`{ … }` and
    /// `label: { … }` on the same line): each one's name, and for `.buttonStyle(` the type its argument starts with.
    static func modifiers(after open: Int, in code: [UInt16]) -> [String] {
        modifierCalls(after: open, in: code).map(\.name)
    }

    /// The modifiers chained onto the call whose `(` or `{` is at `open`, each with the range inside its parentheses
    /// (nil for a modifier written without them).
    static func modifierCalls(after open: Int, in code: [UInt16]) -> [(name: String, arguments: Range<Int>?)] {
        guard let close = closing(code, from: open + 1, open: code[open], close: code[open] == 40 ? 41 : 125) else { return [] }
        var index = close + 1
        trailing: while true {
            let probe = skipSpaces(code, from: index, newlines: false)
            if probe < code.count, code[probe] == 123, let end = closing(code, from: probe + 1, open: 123, close: 125) {
                index = end + 1
                continue
            }
            var name = probe
            while name < code.count, isIdentifier(code[name]) { name += 1 }
            if name > probe, name < code.count, code[name] == 58 {
                let brace = skipSpaces(code, from: name + 1, newlines: false)
                if brace < code.count, code[brace] == 123, let end = closing(code, from: brace + 1, open: 123, close: 125) {
                    index = end + 1
                    continue trailing
                }
            }
            break
        }
        var calls: [(name: String, arguments: Range<Int>?)] = []
        while true {
            let dot = skipSpaces(code, from: index, newlines: true)
            guard dot < code.count, code[dot] == 46 else { break }
            var end = dot + 1
            while end < code.count, isIdentifier(code[end]) { end += 1 }
            guard end > dot + 1 else { break }
            var name = String(decoding: code[(dot + 1)..<end], as: UTF16.self)
            var arguments: Range<Int>?
            index = end
            if index < code.count, code[index] == 40, let close = closing(code, from: index + 1, open: 40, close: 41) {
                arguments = (index + 1)..<close
                if name == "buttonStyle" {
                    var type = skipSpaces(code, from: index + 1, newlines: true)
                    let start = type
                    while type < close, isIdentifier(code[type]) { type += 1 }
                    name += "(" + String(decoding: code[start..<type], as: UTF16.self)
                }
                index = close + 1
            }
            let brace = skipSpaces(code, from: index, newlines: false)
            if brace < code.count, code[brace] == 123, let close = closing(code, from: brace + 1, open: 123, close: 125) {
                index = close + 1
            }
            calls.append((name, arguments))
        }
        return calls
    }

    // MARK: - Pickers and menus (TP-1508)

    static let pickerReplacement = "`SegmentedControl` for two to five choices, or `PopUp` for a longer list"
    static let menuReplacement = "`MenuButton`, whose menu the app draws; a context menu stays the system's"

    // MARK: - Status dots

    static let dotReplacement = "`StatusDot(_:size:live:)` beside its word, or a `Badge`"

    /// The modifiers that colour a shape.
    static let colouringModifiers: Set<String> = ["fill", "foregroundStyle", "foregroundColor", "background"]

    /// The offset of each `Circle()` whose chain colours it with a status colour.
    static func statusDots(in code: [UInt16], text: NSString) -> [Int] {
        matches(circleRegex, in: text, range: 0..<code.count).compactMap { match in
            guard let open = firstIndex(of: [40], in: code, from: match.offset) else { return nil }
            let coloured = modifierCalls(after: open, in: code).contains { call in
                guard colouringModifiers.contains(call.name), let arguments = call.arguments else { return false }
                return !matches(statusColourRegex, in: text, range: arguments).isEmpty
            }
            return coloured ? match.offset : nil
        }
    }

    /// The first offset from `start` that is not a space or a tab (nor a line break, with `newlines`).
    static func skipSpaces(_ code: [UInt16], from start: Int, newlines: Bool) -> Int {
        var index = start
        while index < code.count, code[index] == 32 || code[index] == 9 || (newlines && (code[index] == 10 || code[index] == 13)) {
            index += 1
        }
        return index
    }

    // MARK: - Replacements

    static func fontReplacement(_ value: String, in argument: String) -> String {
        let name = value.split(separator: ".").last.map(String.init) ?? value
        if argument.contains("monospaced") { return "`.textStyle(.mono)` (`DesignTokens.TypeStyle.mono`)" }
        let style = switch name {
        case "largeTitle", "title": "title"
        case "title2": "sentence"
        case "title3": "heading"
        case "headline": "rowTitle"
        case "body": "body"
        case "callout": "secondary"
        case "subheadline": "label"
        case "footnote", "caption", "caption2": "caption"
        default: ""
        }
        if style.isEmpty { return "`.textStyle(_:)` with the `DesignTokens.TypeStyle` of that size and weight" }
        return "`.textStyle(.\(style))` (`DesignTokens.TypeStyle.\(style)`)"
    }

    static func colorReplacement(_ value: String) -> String {
        let name = value.split(separator: ".").last.map(String.init) ?? value
        return switch name {
        case "primary": "`DesignTokens.TextColor.primary.color`"
        case "secondary": "`DesignTokens.TextColor.secondary.color`"
        case "tertiary", "quaternary", "quinary", "placeholder": "`DesignTokens.TextColor.tertiary.color`"
        case "separator": "`DesignTokens.Surface.separator.color`"
        case "accentColor", "indigo", "purple": "`DesignTokens.ColorToken.accent.color` (`.accentText` for text)"
        case "red", "pink": "`DesignTokens.Status.problem.tint` (`.text` for text)"
        case "orange", "yellow": "`DesignTokens.Status.you.tint` (`.text` for text)"
        case "green", "mint": "`DesignTokens.Status.done.tint` (`.text` for text)"
        case "blue", "cyan", "teal": "`DesignTokens.Status.working.tint` (`.text` for text)"
        case "gray", "brown": "`DesignTokens.Status.idle.tint` or `DesignTokens.TextColor.tertiary.color`"
        case "white": "`DesignTokens.TextColor.onAccent.color`"
        default: "a `DesignTokens.ColorToken`; shadows are `DesignTokens.Elevation` levels"
        }
    }

    static let spaceSteps: [Double: String] = [4: "s1", 8: "s2", 12: "s3", 16: "s4", 20: "s5", 24: "s6", 32: "s8", 40: "s10"]

    static func spaceReplacement(_ literal: String) -> String {
        if let step = Double(literal).flatMap({ spaceSteps[$0] }) { return "`DesignTokens.Space.\(step)`" }
        return "a `DesignTokens.Space` step (4, 8, 12, 16, 20, 24, 32, 40), or a component that owns the gap"
    }

    static let radii: [Double: String] = [
        22: "DesignTokens.Radius.sheet", 16: "DesignTokens.Radius.card", 10: "DesignTokens.Radius.row",
        4: "DesignTokens.Radius.mark", 7: "DesignTokens.Control.small.radius", 9: "DesignTokens.Control.medium.radius",
        11: "DesignTokens.Control.large.radius", 6: "DesignTokens.Chip.radius",
    ]

    static func radiusReplacement(_ literal: String) -> String {
        if let radius = Double(literal).flatMap({ radii[$0] }) { return "`\(radius)`" }
        return "a `DesignTokens.Radius` or `DesignTokens.Control` radius, or `Capsule()`"
    }

    // MARK: - Baseline

    /// The count per file and kind, the baseline's shape.
    typealias Counts = [String: [Kind: Int]]

    static func counts(_ bypasses: [Bypass], kinds: [Kind] = Kind.guarded) -> Counts {
        var counts: Counts = [:]
        for bypass in bypasses where kinds.contains(bypass.kind) { counts[bypass.file, default: [:]][bypass.kind, default: 0] += 1 }
        return counts
    }

    /// The baseline file: one `<file> <kind> <count>` line per file and kind with any bypass, sorted. `#` starts a
    /// comment line.
    static func parseBaseline(_ text: String) throws -> Counts {
        var counts: Counts = [:]
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 3, let kind = Kind(rawValue: String(fields[1])), Kind.guarded.contains(kind),
                  let count = Int(fields[2]), count > 0, counts[String(fields[0])]?[kind] == nil
            else { throw BaselineError.badLine(index + 1, line) }
            counts[String(fields[0]), default: [:]][kind] = count
        }
        return counts
    }

    enum BaselineError: Error, Equatable { case badLine(Int, String) }

    static let baselineHeader = """
    # The design guard's baseline (TP-1493, docs/design/design-system.md §3.11): how many raw style values each view
    # file still has, per kind, and (TP-1505) how many buttons without the shared style (`button`) and controls turned
    # off without a reason (`disabled`), and (TP-1506) how many status dots drawn by hand (`dot`), and (TP-1508) how
    # many stock pickers (`picker`) and stock menus (`menu`). It must equal what the guard counts: lower a number in the
    # same change that removes a bypass, and delete the line when it reaches zero. A file not listed here may have none.
    """

    static func formatBaseline(_ counts: Counts) -> String {
        var lines = [baselineHeader]
        for file in counts.keys.sorted() {
            for (kind, count) in counts[file]!.sorted(by: { $0.key < $1.key }) where count > 0 {
                lines.append("\(file) \(kind.rawValue) \(count)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Why the counts differ from the baseline, one message per file and kind; empty when they agree.
    static func failures(bypasses: [Bypass], baseline: Counts) -> [String] {
        let actual = counts(bypasses)
        var messages: [String] = []
        for file in Set(actual.keys).union(baseline.keys).sorted() {
            for kind in Kind.guarded {
                let now = actual[file]?[kind] ?? 0
                let allowed = baseline[file]?[kind] ?? 0
                if now > allowed {
                    let list = bypasses.filter { $0.file == file && $0.kind == kind }.map { "  " + $0.message }
                    let head = allowed == 0
                        ? "\(file) draws with \(now) raw \(kind.rawValue) value(s) and is not in the baseline: new code takes every style value from DesignTokens or a shared component"
                        : "\(file) has \(now) \(kind.rawValue) bypass(es), above its baseline of \(allowed): take the new one(s) from DesignTokens or a shared component"
                    messages.append(([head] + list).joined(separator: "\n"))
                } else if now < allowed {
                    messages.append(
                        now == 0
                            ? "\(file) has no \(kind.rawValue) bypass left: delete its `\(kind.rawValue)` line from the baseline"
                            : "\(file) has \(now) \(kind.rawValue) bypass(es), below its baseline of \(allowed): lower the baseline line to `\(file) \(kind.rawValue) \(now)`"
                    )
                }
            }
        }
        return messages
    }

    // MARK: - Lexing

    /// The source with every comment and string literal's text replaced by spaces, keeping lines and offsets, so a
    /// value named in a comment or a string is never counted and a comment never waives one.
    static func blankCommentsAndStrings(_ source: String) -> String {
        var out = Array(source.utf16)
        let quote = UInt16(UInt8(ascii: "\"")), slash = UInt16(UInt8(ascii: "/")), star = UInt16(UInt8(ascii: "*"))
        let newline = UInt16(UInt8(ascii: "\n")), backslash = UInt16(UInt8(ascii: "\\")), hash = UInt16(UInt8(ascii: "#"))
        let space = UInt16(UInt8(ascii: " "))
        var index = 0
        func blank(_ from: Int, _ to: Int) {
            for position in from..<min(to, out.count) where out[position] != newline { out[position] = space }
        }
        func starts(_ text: [UInt16], at position: Int) -> Bool {
            guard position + text.count <= out.count else { return false }
            for offset in text.indices where out[position + offset] != text[offset] { return false }
            return true
        }
        while index < out.count {
            let char = out[index]
            if char == slash, index + 1 < out.count, out[index + 1] == slash {
                var end = index
                while end < out.count, out[end] != newline { end += 1 }
                blank(index, end)
                index = end
            } else if char == slash, index + 1 < out.count, out[index + 1] == star {
                var depth = 1, end = index + 2
                while end < out.count, depth > 0 {
                    if starts([slash, star], at: end) { depth += 1; end += 2 }
                    else if starts([star, slash], at: end) { depth -= 1; end += 2 }
                    else { end += 1 }
                }
                blank(index, end)
                index = end
            } else if char == quote || (char == hash && starts([hash, quote], at: index)) || (char == hash && starts([hash, hash, quote], at: index)) {
                var hashes = 0
                while out[index + hashes] == hash { hashes += 1 }
                let open = index + hashes
                let triple = starts([quote, quote, quote], at: open)
                let delimiter = (triple ? [quote, quote, quote] : [quote]) + Array(repeating: hash, count: hashes)
                var end = open + (triple ? 3 : 1)
                while end < out.count {
                    if hashes == 0, out[end] == backslash { end += 2; continue }
                    if !triple, out[end] == newline { break }
                    if starts(delimiter, at: end) { end += delimiter.count; break }
                    end += 1
                }
                blank(index, end)
                index = end
            } else {
                index += 1
            }
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// The ranges inside the parentheses of each call to one of `calls` (each ends with `(`).
    static func arguments(of calls: [String], in code: [UInt16]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for call in calls {
            let needle = Array(call.utf16)
            var start = 0
            while let found = firstIndex(of: needle, in: code, from: start) {
                let open = found + needle.count
                // A call on a member (`.font(`), not a longer name (`.fontWeight(`): the needle ends in `(`.
                if let close = closing(code, from: open) { ranges.append(open..<close) }
                start = open
            }
        }
        return ranges
    }

    /// The range of each value after `label` (such as `spacing:`), up to the next `,`, closing bracket or `{` at its
    /// depth, or the end of the line.
    static func labelledValues(_ label: String, in code: [UInt16]) -> [Range<Int>] {
        let needle = Array(label.utf16)
        var ranges: [Range<Int>] = []
        var start = 0
        while let found = firstIndex(of: needle, in: code, from: start) {
            let begin = found + needle.count
            start = begin
            if found > 0, isIdentifier(code[found - 1]) { continue }
            var depth = 0, end = begin
            scan: while end < code.count {
                switch code[end] {
                case 10: break scan
                case 123: if depth == 0 { break scan } else { depth += 1 }
                case 40, 91: depth += 1
                case 41, 93, 125: if depth == 0 { break scan } else { depth -= 1 }
                case 44: if depth == 0 { break scan }
                default: break
                }
                end += 1
            }
            ranges.append(begin..<end)
        }
        return ranges
    }

    static func isIdentifier(_ char: UInt16) -> Bool {
        (48...57).contains(char) || (65...90).contains(char) || (97...122).contains(char) || char == 95
    }

    static func firstIndex(of needle: [UInt16], in code: [UInt16], from start: Int) -> Int? {
        guard !needle.isEmpty, code.count >= needle.count, start <= code.count - needle.count else { return nil }
        var index = start
        search: while index <= code.count - needle.count {
            for offset in needle.indices where code[index + offset] != needle[offset] {
                index += 1
                continue search
            }
            return index
        }
        return nil
    }

    /// The offset of the `)` that closes the parenthesis opened just before `open`.
    static func closing(_ code: [UInt16], from open: Int) -> Int? {
        closing(code, from: open, open: 40, close: 41)
    }

    /// The offset of the `close` that closes the `open` just before `start`.
    static func closing(_ code: [UInt16], from start: Int, open: UInt16, close: UInt16) -> Int? {
        var depth = 1, index = start
        while index < code.count {
            if code[index] == open {
                depth += 1
            } else if code[index] == close {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    struct Match { var offset: Int; var text: String }

    static func matches(_ regex: NSRegularExpression, in text: NSString, range: Range<Int>) -> [Match] {
        regex.matches(in: text as String, range: NSRange(location: range.lowerBound, length: range.count)).map {
            Match(offset: $0.range.location, text: text.substring(with: $0.range))
        }
    }

    static func lineOffsets(_ code: [UInt16]) -> [Int] {
        [0] + code.indices.filter { code[$0] == 10 }.map { $0 + 1 }
    }

    /// The 1-based line of `offset`.
    static func line(of offset: Int, in starts: [Int]) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }
}
