import AppKit
import SwiftUI
import SymphonyBarCore

// The Conductor speaking, on the ticket page. Three shapes: a message between runs (the junction message, 16 pt), a
// steer inside the run it steered (14 pt, with the delivery as a chip), and a quiet line inside a run it watched and
// left alone. The Conductor's mark is a round accent badge with a white baton.

/// The Conductor's mark: 28 pt with an accent-tint ring where it speaks between runs, 18 pt inside a run.
struct ConductorMark: View {
    enum Size {
        case regular, small

        var side: CGFloat {
            switch self {
            case .regular: 28
            case .small: 18
            }
        }

        var glyph: CGFloat {
            switch self {
            case .regular: 14
            case .small: 10
            }
        }

        /// The ring of the accent tint around the regular mark.
        var ring: CGFloat { self == .regular ? 3 : 0 }
    }

    let size: Size

    var body: some View {
        ConductorBaton(lineWidth: size == .regular ? 1.8 : 2)
            .frame(width: size.glyph, height: size.glyph)
            .foregroundStyle(DesignTokens.TextColor.onAccent.color)
            .frame(width: size.side, height: size.side)
            .background(Circle().fill(DesignTokens.ColorToken.accent.color))
            .background(Circle().fill(DesignTokens.ColorToken.accentTint.color).padding(-size.ring))
            .accessibilityHidden(true)
    }
}

/// The Conductor's words, as the markup has them: paragraphs, bullet lists and code blocks, the first paragraph
/// semibold and a last one that starts `Next:` in the secondary colour. `style` is the message's reading style: 16 pt
/// between runs, 14 pt inside a run.
struct ConductorMarkupText: View {
    let markup: ConductorMarkup
    var style: DesignTokens.TypeStyle = .reading
    /// The message's blocks: drawn after its words and before a closing `Next:` paragraph, or at the end without one.
    var blocks: [ConductorBlock] = []

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            ForEach(Array(markup.blocks.enumerated()), id: \.offset) { index, block in
                if markup.roles[index] == .next { blocksView }
                switch block {
                case let .paragraph(phrases):
                    paragraph(phrases, role: markup.roles[index])
                case let .list(items):
                    list(items)
                case let .codeBlock(lines):
                    ConductorCodeBlock(lines: lines)
                }
            }
            if !markup.roles.contains(.next) { blocksView }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var blocksView: some View {
        if !blocks.isEmpty {
            ConductorBlocksView(blocks: blocks)
                .padding(.vertical, DesignTokens.Space.s1)
        }
    }

    @ViewBuilder private func paragraph(_ phrases: [ConductorMarkup.Phrase], role: ConductorMarkup.Role) -> some View {
        let color = role == .next ? DesignTokens.TextColor.secondary.color : DesignTokens.TextColor.primary.color
        if ConductorMarkup.hasReference(phrases) {
            ConductorReferenceParagraph(phrases: phrases, style: style, bold: role == .headline)
                .foregroundStyle(color)
        } else {
            Text(Self.attributed(phrases, style: style, bold: role == .headline))
                .textStyle(style)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func list(_ items: [[ConductorMarkup.Phrase]]) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1 / 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                    Text(verbatim: "•")
                        .textStyle(style)
                        .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    Text(Self.attributed(item, style: style))
                        .textStyle(style)
                        .foregroundStyle(DesignTokens.TextColor.primary.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.leading, DesignTokens.Space.s1)
    }

    /// The phrases as one attributed string: bold and italic in the style's font, code in the mono font on the hover
    /// surface, a link in the accent text colour underlined, a status phrase semibold in its status's text colour.
    static func attributed(_ phrases: [ConductorMarkup.Phrase], style: DesignTokens.TypeStyle, bold: Bool = false) -> AttributedString {
        var result = AttributedString()
        append(phrases, to: &result, style: style, traits: Traits(bold: bold))
        return result
    }

    private struct Traits {
        var bold = false
        var italic = false
        var color: Color?

        func font(_ style: DesignTokens.TypeStyle) -> Font {
            var font = style.font
            if bold { font = font.weight(.semibold) }
            if italic { font = font.italic() }
            return font
        }
    }

    fileprivate static func appendPhrases(_ phrases: [ConductorMarkup.Phrase], to result: inout AttributedString, style: DesignTokens.TypeStyle, bold: Bool) {
        append(phrases, to: &result, style: style, traits: Traits(bold: bold))
    }

    private static func append(_ phrases: [ConductorMarkup.Phrase], to result: inout AttributedString, style: DesignTokens.TypeStyle, traits: Traits) {
        for phrase in phrases {
            switch phrase {
            case let .plain(text):
                result.append(run(text, traits: traits, style: style))
            case let .bold(inner):
                var inside = traits
                inside.bold = true
                append(inner, to: &result, style: style, traits: inside)
            case let .italic(inner):
                var inside = traits
                inside.italic = true
                append(inner, to: &result, style: style, traits: inside)
            case let .status(status, inner):
                var inside = traits
                inside.bold = true
                inside.color = status.text
                append(inner, to: &result, style: style, traits: inside)
            case let .code(text):
                var code = AttributedString(text)
                code.font = Font(NSFont.monospacedSystemFont(ofSize: style.nsFont.pointSize * Self.codeScale, weight: .regular))
                code.backgroundColor = DesignTokens.StateSurface.hover.color.color
                if let color = traits.color { code.foregroundColor = color }
                result.append(code)
            case let .link(label, destination):
                var link = AttributedString()
                append(label, to: &link, style: style, traits: traits)
                link.link = destination
                link.foregroundColor = DesignTokens.ColorToken.accentText.color
                link.underlineStyle = .single
                result.append(link)
            }
        }
    }

    /// Code in a sentence is a little smaller than the words around it (`0.86em`).
    static let codeScale = 0.86

    private static func run(_ text: String, traits: Traits, style: DesignTokens.TypeStyle) -> AttributedString {
        var run = AttributedString(text)
        run.font = traits.font(style)
        if let color = traits.color { run.foregroundColor = color }
        return run
    }
}

/// A fenced code block: its lines in the mono font on the sunken surface; a line starting `+` in the done text colour
/// and one starting `-` in the problem text colour.
struct ConductorCodeBlock: View {
    let lines: [ConductorMarkup.CodeLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line.text.isEmpty ? " " : line.text)
                    .font(DesignTokens.TypeStyle.mono.font)
                    .foregroundStyle(Self.color(line.change))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, DesignTokens.Space.s2 + 2)
        .padding(.horizontal, DesignTokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Surface.sunken.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row - 2, style: .continuous))
    }

    static func color(_ change: ConductorMarkup.CodeLine.Change) -> Color {
        switch change {
        case .added: DesignTokens.Status.done.text
        case .removed: DesignTokens.Status.problem.text
        case .unchanged: DesignTokens.TextColor.primary.color
        }
    }
}

/// The Conductor's message between runs: its name in the accent text colour, the junction in words after it, and its
/// words under. Its run ("Conductor run 2") is the mechanical detail and sits in the name line's help.
struct ConductorVoice: View {
    let message: ConductorMessage
    /// Newer than the person's last look: the small accent dot before the name, as the other entries carry it.
    var isNew = false

    /// No line of the message runs past 68 characters of its own style.
    static var measure: CGFloat { CGFloat(DesignTokens.Measure.width(for: .reading)) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                if isNew {
                    Circle()
                        .fill(DesignTokens.ColorToken.accent.color)
                        .frame(width: 6, height: 6)
                        .help(TimelineEntry.newHelp)
                }
                Text(ConductorMessage.name)
                    .font(DesignTokens.TypeStyle.rowTitle.font)
                    .foregroundStyle(DesignTokens.ColorToken.accentText.color)
                if let words = message.junctionWords {
                    Text(words)
                        .font(DesignTokens.TypeStyle.secondary.font)
                        .foregroundStyle(DesignTokens.TextColor.tertiary.color)
                }
            }
            .help(message.runTitle ?? "")
            ConductorMarkupText(markup: message.markup, style: .reading, blocks: message.blocks)
        }
    }
}

/// The Conductor's reply to a person's message, drawn directly under that message in its entry: the small mark, then
/// the Conductor speaking, with its blocks.
struct ConductorReply: View {
    let message: ConductorMessage

    /// Under the message it answers, the junction's words would only repeat where it is.
    private var said: ConductorMessage {
        var said = message
        said.junction = nil
        return said
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Space.s2) {
            ConductorMark(size: .small)
                .padding(.top, 1)
            ConductorVoice(message: said)
        }
        .padding(.vertical, DesignTokens.Space.s1)
        .frame(maxWidth: ConductorVoice.measure, alignment: .leading)
    }
}

/// The Conductor inside a run's group. When it acted on the run (steered or stopped it) the message is drawn whole,
/// under a line that says what it did and when it reaches the run; when it only watched, one quiet line.
struct ConductorRunNote: View {
    let message: ConductorMessage

    var body: some View {
        Group {
            if message.actedOnRun { acted } else { quiet }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message.accessibilityLabel(time: message.at.map(Self.clock)))
    }

    private var acted: some View {
        HStack(alignment: .top, spacing: DesignTokens.Space.s2) {
            ConductorMark(size: .small)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                    Text(ConductorMessage.name)
                        .font(DesignTokens.TypeStyle.rowTitle.font)
                        .foregroundStyle(DesignTokens.ColorToken.accentText.color)
                    if let action = message.watch?.action {
                        Text(action)
                            .font(DesignTokens.TypeStyle.secondary.font)
                            .foregroundStyle(DesignTokens.TextColor.tertiary.color)
                    }
                    if let timing = message.watch?.timing {
                        TimingChip(text: timing)
                    }
                    Spacer(minLength: DesignTokens.Space.s2)
                    time
                }
                .help(message.runTitle ?? "")
                ConductorMarkupText(markup: message.markup, style: .readingCompact, blocks: message.blocks)
            }
        }
        .padding(.vertical, DesignTokens.Space.s1)
    }

    private var quiet: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            ConductorMark(size: .small)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            (Text(ConductorMessage.name).font(DesignTokens.TypeStyle.rowTitle.font).foregroundColor(DesignTokens.ColorToken.accentText.color)
                + Text(verbatim: "  ")
                + Text(message.markup.oneLine).font(DesignTokens.TypeStyle.body.font).foregroundColor(DesignTokens.TextColor.secondary.color))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DesignTokens.Space.s2)
            time
        }
        .padding(.vertical, DesignTokens.Space.s1)
        .help(message.runTitle ?? "")
    }

    @ViewBuilder private var time: some View {
        if let at = message.at {
            Text(Self.clock(at))
                .font(DesignTokens.TypeStyle.secondary.font)
                .foregroundStyle(DesignTokens.TextColor.tertiary.color)
                .monospacedDigit()
        }
    }

    /// "17:48", as the run's other entries tell the time.
    static func clock(_ date: Date) -> String {
        SharedDateFormatter.string(date, format: "HH:mm", timeZone: NSTimeZone.default)
    }
}

/// When the Conductor's guidance reaches the run: "at its next turn", "now".
private struct TimingChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DesignTokens.TypeStyle.label.font)
            .foregroundStyle(DesignTokens.ColorToken.accentText.color)
            .padding(.horizontal, DesignTokens.Space.s2)
            .padding(.vertical, 1)
            .background(Capsule().fill(DesignTokens.ColorToken.accentTint.color))
            .fixedSize()
    }
}

/// A conductor's baton: a stick running from the lower left to the upper right with a small filled dot at its tip, in
/// the colour it is given, drawn on a 16 × 16 grid scaled to its frame.
struct ConductorBaton: View {
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height) / Self.grid
            ZStack {
                BatonStick()
                    .stroke(style: StrokeStyle(lineWidth: lineWidth * scale, lineCap: .round))
                BatonTip()
            }
            .frame(width: Self.grid * scale, height: Self.grid * scale)
        }
        .accessibilityHidden(true)
    }

    static let grid: CGFloat = 16
}

/// The baton's stick, from (3, 13) to (11, 5) on the 16-point grid.
struct BatonStick: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / ConductorBaton.grid
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 3 * unit, y: rect.minY + 13 * unit))
        path.addLine(to: CGPoint(x: rect.minX + 11 * unit, y: rect.minY + 5 * unit))
        return path
    }
}

/// The baton's tip: a dot of 1.4 radius at (12.5, 3.5) on the 16-point grid.
struct BatonTip: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / ConductorBaton.grid
        let radius = 1.4 * unit
        let center = CGPoint(x: rect.minX + 12.5 * unit, y: rect.minY + 3.5 * unit)
        return Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
    }
}

/// A paragraph that holds ticket or pull request references: the words flow and wrap as a `Text` would, and each
/// reference is the reference chip (`ChipText`), with the live state of the ticket or pull request when the app has it
/// and as plain text when it does not.
struct ConductorReferenceParagraph: View {
    let phrases: [ConductorMarkup.Phrase]
    let style: DesignTokens.TypeStyle
    var bold = false

    enum Fragment: Equatable {
        case words(AttributedString)
        case reference(String)
    }

    var body: some View {
        ConductorFlowLayout(lineHeight: CGFloat(style.scaledLineHeight(by: DesignTokens.TypeStyle.textScale))) {
            ForEach(Array(Self.fragments(phrases, style: style, bold: bold).enumerated()), id: \.offset) { _, fragment in
                switch fragment {
                case let .words(words):
                    Text(words).textStyle(style).fixedSize()
                case let .reference(key):
                    ChipText(text: key, font: style.nsFont).fixedSize()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ConductorMarkup.plainText(of: phrases))
    }

    /// The paragraph cut into words, each with its own styling, and its references.
    static func fragments(_ phrases: [ConductorMarkup.Phrase], style: DesignTokens.TypeStyle, bold: Bool) -> [Fragment] {
        var fragments: [Fragment] = []
        var pending: [ConductorMarkup.Phrase] = []

        func flush() {
            guard !pending.isEmpty else { return }
            var text = AttributedString()
            ConductorMarkupText.appendPhrases(pending, to: &text, style: style, bold: bold)
            fragments += words(of: text).map(Fragment.words)
            pending = []
        }
        func walk(_ phrases: [ConductorMarkup.Phrase], wrap: (([ConductorMarkup.Phrase]) -> ConductorMarkup.Phrase)?) {
            for phrase in phrases {
                switch phrase {
                case let .code(text) where ConductorMarkup.isReference(text):
                    flush()
                    fragments.append(.reference(text))
                case let .bold(inner): walk(inner, wrap: { wrap?([.bold($0)]) ?? .bold($0) })
                case let .italic(inner): walk(inner, wrap: { wrap?([.italic($0)]) ?? .italic($0) })
                case let .status(status, inner): walk(inner, wrap: { wrap?([.status(status, $0)]) ?? .status(status, $0) })
                case let .link(label, destination): walk(label, wrap: { wrap?([.link(label: $0, destination: destination)]) ?? .link(label: $0, destination: destination) })
                default: pending.append(wrap?([phrase]) ?? phrase)
                }
            }
        }
        walk(phrases, wrap: nil)
        flush()
        return fragments
    }

    /// `text` cut after each space, so a line breaks between words.
    static func words(of text: AttributedString) -> [AttributedString] {
        var words: [AttributedString] = []
        var start = text.startIndex
        var index = start
        while index < text.endIndex {
            let next = text.characters.index(after: index)
            if text.characters[index] == " " {
                words.append(AttributedString(text[start..<next]))
                start = next
            }
            index = next
        }
        if start < text.endIndex { words.append(AttributedString(text[start...])) }
        return words
    }
}

/// Lays its children out left to right and wraps to a new line when the next does not fit; a line is as tall as its
/// tallest child or `lineHeight`, whichever is more, and the children sit in the middle of it.
struct ConductorFlowLayout: Layout {
    let lineHeight: CGFloat

    private struct Line {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines = [Line()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if lines[lines.count - 1].width + size.width > width, !lines[lines.count - 1].items.isEmpty { lines.append(Line()) }
            lines[lines.count - 1].items.append((index, size))
            lines[lines.count - 1].width += size.width
            lines[lines.count - 1].height = max(lines[lines.count - 1].height, size.height, lineHeight)
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = lines(subviews, width: width)
        return CGSize(width: min(width, lines.map(\.width).max() ?? 0), height: lines.map(\.height).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, width: bounds.width) {
            var x = bounds.minX
            for (index, size) in line.items {
                subviews[index].place(at: CGPoint(x: x, y: y + line.height / 2), anchor: .leading, proposal: ProposedViewSize(size))
                x += size.width
            }
            y += line.height
        }
    }
}
