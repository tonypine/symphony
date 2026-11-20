import SwiftUI
import SymphonyBarCore

// The facts rail's last panel (`docs/design/director-window-and-home.md`, The ticket page; the catalog's
// `decisionsPanel` and `.decision-list`, TP-1504): the decisions the person recorded on the ticket, newest first, one
// row each. A ticket with none has no Decisions label and no panel: the page draws it only when `isEmpty` is false.

// MARK: - The Decisions panel

public struct DecisionsPanel: View {
    let model: DecisionsPanelModel

    public init(model: DecisionsPanelModel) {
        self.model = model
    }

    public var body: some View {
        TitledPanel(title: DecisionsPanelModel.title) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                ForEach(model.rows) { DecisionRow(row: $0) }
            }
        }
    }
}

/// `.decision-list li`: the answered glyph in the done colour, the decision in the row-title style and, under it, who
/// answered and when in the secondary style. VoiceOver reads it as one element.
public struct DecisionRow: View {
    let row: DecisionsPanelModel.Row

    public init(row: DecisionsPanelModel.Row) {
        self.row = row
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            RowLeadMark(lead: .glyph(TimelineEntry.Kind.questionAnswered.symbol, .statusDone))
                .frame(width: DesignTokens.Row.leadSize)
            VStack(alignment: .leading, spacing: DesignTokens.Row.lineGap) {
                Text(row.title)
                    .textStyle(.rowTitle)
                    .foregroundStyle(DesignTokens.TextColor.primary.color)
                    .fixedSize(horizontal: false, vertical: true)
                Text(row.byline)
                    .textStyle(.secondary)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}

// The facts rail's cards draw again only when their model changed (TP-1480).

extension DecisionsPanel: Equatable {
    nonisolated public static func == (lhs: DecisionsPanel, rhs: DecisionsPanel) -> Bool { lhs.model == rhs.model }
}
