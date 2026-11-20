import AppKit
import SwiftUI
import SymphonyBarCore

// The brief on top of the ticket page's main column (`docs/design/director-window-and-home.md`, The ticket page; the
// catalog's `briefTitle` and `briefBlock`, `.zone-brief`, `.panel.brief`, `.brief-text`, `.brief-part` and
// `.brief-more`, TP-1504): a zone title naming who wrote it and when, then a panel across the column in the reading
// style. Folded it shows the brief's first three lines and "Read all of it, with the walkthrough"; unfolded the whole
// brief, then under hairlines its Walkthrough and What was asked, and "Show less". "Asked for" has no fold.

public struct BriefPanel: View {
    let model: BriefPanelModel
    @Binding var open: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `open` is the fold, the page's to keep while it is open.
    public init(model: BriefPanelModel, open: Binding<Bool>) {
        self.model = model
        _open = open
    }

    public var body: some View {
        let unfolded = open && model.folds
        TitledPanel(ZoneTitle(model.title, note: model.note), label: model.title, spacing: DesignTokens.Space.s3) {
            ReadingText(model.text)
                .lineLimit(model.folds && !unfolded ? BriefPanelModel.foldedLines : nil)
                .fixedSize(horizontal: false, vertical: true)
            if model.folds {
                FoldBody(expanded: unfolded) {
                    VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                        if let walkthrough = model.walkthrough {
                            BriefPart(title: BriefPanelModel.walkthroughTitle, text: walkthrough, secondary: false).foldRow(0)
                        }
                        if let asked = model.asked {
                            BriefPart(title: BriefPanelModel.askedTitle, text: asked, secondary: true).foldRow(1)
                        }
                    }
                }
                StoryFold(BriefPanelModel.foldTitle(open: unfolded), open: unfolded, leading: -DesignTokens.Space.s2) {
                    withAnimation(FoldMotion.opening(reduceMotion: reduceMotion)) { open.toggle() }
                }
            }
        }
    }
}

/// `.brief-part`: under a hairline, its small upper-case label in the secondary colour, then its text in the reading
/// style; `secondary` sets the text in the secondary colour (What was asked).
struct BriefPart: View {
    let title: String
    let text: String
    let secondary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            HairlineDivider()
                .padding(.bottom, DesignTokens.Space.s2)
            Text(title)
                .textCase(.uppercase)
                .font(DesignTokens.TypeStyle.caption.font)
                .tracking(CGFloat(ZoneTitle.tracking * DesignTokens.TypeStyle.caption.scaledSize(by: DesignTokens.TypeStyle.textScale)))
                .foregroundStyle(DesignTokens.TextColor.secondary.color)
                .accessibilityAddTraits(.isHeader)
            ReadingText(text, color: secondary ? DesignTokens.TextColor.secondary : DesignTokens.TextColor.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Text in the reading style (`--type-reading`: 16 pt, its line height and tracking), with its code and paths in the
/// mono face at 0.85 of that size (`ReadingSpans`). Selectable.
public struct ReadingText: View {
    let text: String
    let color: DesignTokens.ColorToken

    public init(_ text: String, color: DesignTokens.ColorToken = DesignTokens.TextColor.primary) {
        self.text = text
        self.color = color
    }

    /// `text` as one attributed run of prose and code, the code in the mono face.
    public static func attributed(_ text: String) -> AttributedString {
        let size = DesignTokens.TypeStyle.reading.scaledSize(by: DesignTokens.TypeStyle.textScale) * ReadingSpans.codeScale
        let mono = Font(NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular) as CTFont)
        var whole = AttributedString()
        for span in ReadingSpans.split(text) {
            var piece = AttributedString(span.text)
            if span.code { piece.font = mono }
            whole += piece
        }
        return whole
    }

    public var body: some View {
        Text(Self.attributed(text))
            .textStyle(.reading)
            .foregroundStyle(color.color)
            .textSelection(.enabled)
    }
}
