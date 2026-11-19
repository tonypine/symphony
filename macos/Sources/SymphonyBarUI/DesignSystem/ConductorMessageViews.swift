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

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            ForEach(Array(markup.blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case let .paragraph(phrases):
                    paragraph(phrases, role: markup.roles[index])
                case let .list(items):
                    list(items)
                case let .codeBlock(lines):
                    ConductorCodeBlock(lines: lines)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func paragraph(_ phrases: [ConductorMarkup.Phrase], role: ConductorMarkup.Role) -> some View {
        Text(Self.attributed(phrases, style: style, bold: role == .headline))
            .textStyle(style)
            .foregroundStyle(role == .next ? DesignTokens.TextColor.secondary.color : DesignTokens.TextColor.primary.color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
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
            ConductorMarkupText(markup: message.markup, style: .reading)
        }
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
                ConductorMarkupText(markup: message.markup, style: .readingCompact)
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
