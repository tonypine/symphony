import SwiftUI
import SymphonyBarCore

// The Home queue's token line (TP-1608, `.tokline` in `docs/design/prototypes/home-queue/page.css`): one dot per stage
// that ran, in the stage's chart colour, with its name and tokens at the left, and the ticket's total against its cap
// at the right ("21.4M of 100M tokens · 21 %"). It has no bar: the ticket page's Lifecycle draws that.

public struct TokenLine: View {
    /// A stage's tokens, in the stage's chart colour.
    public struct Stage: Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        public var tokens: Int
        public var series: DesignTokens.ChartSeries

        public init(name: String, tokens: Int, series: DesignTokens.ChartSeries) {
            self.name = name
            self.tokens = tokens
            self.series = series
        }

        /// "9.6M".
        public var value: String { Overview.tokens(tokens) }
    }

    let stages: [Stage]
    let total: Int
    let cap: Int?

    /// The line for `stages` (in the order they ran), with `total` tokens against the ticket's `cap`.
    public init(stages: [Stage], total: Int, cap: Int?) {
        self.stages = stages
        self.total = total
        self.cap = cap
    }

    /// The stages that ran: those with tokens. A stage not reached yet has no dot.
    public var shown: [Stage] { stages.filter { $0.tokens > 0 } }

    /// "21.4M of 100M tokens · 21 %".
    public var totalText: String { DesignTokens.HomeQueue.tokens(total, cap: cap) }

    /// What VoiceOver reads: each stage with its tokens, then the total.
    public var accessibilityText: String {
        (shown.map { "\($0.name) \($0.value)" } + [totalText]).joined(separator: ", ")
    }

    public var body: some View {
        let queue = DesignTokens.HomeQueue.self
        HStack(spacing: queue.tokenTotalGap) {
            HStack(spacing: queue.tokenStageGap) {
                ForEach(shown) { stage in
                    HStack(spacing: queue.tokenDotGap) {
                        Circle()
                            .fill(stage.series.color)
                            .frame(width: queue.tokenDot, height: queue.tokenDot)
                        Text(stage.name).foregroundStyle(DesignTokens.TextColor.secondary.color)
                        Text(stage.value).foregroundStyle(DesignTokens.TextColor.primary.color)
                    }
                    .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            totalView.fixedSize()
        }
        .textStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// The total in the primary colour and semibold, the rest of the words secondary.
    private var totalView: Text {
        let value = Overview.tokens(total)
        let rest = String(totalText.dropFirst(value.count))
        return Text("\(Text(value).fontWeight(.semibold).foregroundStyle(DesignTokens.TextColor.primary.color))\(Text(rest).foregroundStyle(DesignTokens.TextColor.secondary.color))")
    }
}
