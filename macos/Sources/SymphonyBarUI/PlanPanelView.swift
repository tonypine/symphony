import SwiftUI
import SymphonyBarCore

// The plan on top of a groomed ticket's page, in the Brief panel's place and drawn with its parts (`BriefPanel.swift`):
// the zone title "Plan" with how far the checks are, then a panel in the reading style with the plan's summary and one
// line per check. Unfolded it shows, under hairlines, the plan as the runs read it and what was asked, and "Show less".

public struct PlanPanel: View {
    let model: PlanPanelModel
    @Binding var open: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `open` is the fold, the page's to keep while it is open.
    public init(model: PlanPanelModel, open: Binding<Bool>) {
        self.model = model
        _open = open
    }

    public var body: some View {
        let unfolded = open && model.folds
        TitledPanel(ZoneTitle(model.title, note: model.note), label: model.line, spacing: DesignTokens.Space.s3) {
            if let summary = model.summary {
                ReadingText(summary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.checks.isEmpty {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                    ForEach(model.checks) { check in
                        PlanCheckRow(check: check)
                    }
                }
            }
            if model.folds {
                FoldBody(expanded: unfolded) {
                    VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                        if let text = model.text {
                            BriefPart(title: nil, text: text, secondary: false).foldRow(0)
                        }
                        if let asked = model.asked {
                            BriefPart(title: BriefPanelModel.askedTitle, text: asked, secondary: true).foldRow(1)
                        }
                    }
                }
                StoryFold(PlanPanelModel.foldTitle(open: unfolded), open: unfolded, leading: -DesignTokens.Space.s2) {
                    withAnimation(FoldMotion.opening(reduceMotion: reduceMotion)) { open.toggle() }
                }
            }
        }
    }
}

/// One check on one line: its state's mark, its statement, cut with an ellipsis where the line ends, and at the
/// trailing end how it is proved. A waived check says why after its statement, in the secondary style, cut where the
/// line ends. The whole statement, and the test that proved it, are under the pointer.
struct PlanCheckRow: View {
    let check: PlanPanelModel.Check

    private var lead: RowLead {
        .glyph(check.symbol, check.state == .proved ? .statusDone : .textTertiary)
    }

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Row.itemGap) {
            RowLeadMark(lead: lead, glyphSize: DesignTokens.StoryRow.markGlyph)
                .frame(width: DesignTokens.StoryRow.markSize, height: DesignTokens.StoryRow.markSize)
            Text(check.statement)
                .textStyle(.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle((check.state == .waived ? DesignTokens.TextColor.secondary : DesignTokens.TextColor.primary).color)
                .frame(maxWidth: check.reason == nil ? .infinity : nil, alignment: .leading)
                .layoutPriority(1)
            if let reason = check.reason {
                Text(reason)
                    .textStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let proof = check.proof {
                RowValue(proof)
            }
        }
        .help([check.statement, check.help].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(check.accessibilityLabel)
    }
}
