import AppKit
import Charts
import SwiftUI
import SymphonyBarCore

/// D8: Usage over the Insights slice (TP-1463), from `/api/v1/aggregate` and `/api/v1/state`.
struct UsageContent: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient

    var body: some View {
        InsightsPage(model: model, symbol: SymphonyView.usage.symbol) { aggregate in
            UsageView(
                usage: Usage(aggregate: aggregate, slice: model.insightsSlice, snapshot: model.overviewState?.snapshot, today: model.insightsToday),
                openTicket: model.openTicket,
                widen: { model.insightsSlice.choose($0, today: model.insightsToday) }
            )
        }
    }
}

struct UsageView: View {
    let usage: Usage
    var openTicket: (String) -> Void = { _ in }
    var widen: (InsightsPeriod) -> Void = { _ in }

    var body: some View {
        if let empty = usage.empty {
            InsightsEmptyState(empty: empty, symbol: SymphonyView.usage.symbol, widen: widen)
        } else {
            ScrollView {
                UsageCards(usage: usage, openTicket: openTicket)
            }
        }
    }
}

/// Usage's cards, outside the scroll view so they also render offscreen.
struct UsageCards: View {
    let usage: Usage
    var openTicket: (String) -> Void = { _ in }
    /// The heavy ticket a click selected.
    @State var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            Card(title: usage.chart.title) {
                InsightsBarChart(chart: usage.chart, height: 220)
            }
            HStack(alignment: .top, spacing: DesignTokens.Space.s4) {
                if !usage.today.isEmpty {
                    Card(title: Usage.todayTitle) {
                        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                            ForEach(usage.today) { MeterView(meter: $0) }
                        }
                    }
                }
                Card(title: Usage.limitsTitle) {
                    if usage.limits.isEmpty {
                        Text("No provider limit reported.")
                            .font(DesignTokens.TypeStyle.body.font)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                            ForEach(usage.limits) { MeterView(meter: $0) }
                        }
                    }
                }
            }
            Card(title: Usage.heaviestTitle) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(usage.heaviest) { row in
                        HeavyTicketRow(row: row, selected: selected == row.id, select: { selected = row.id }, open: { openTicket(row.identifier) })
                    }
                }
            }
        }
        .padding(DesignTokens.Space.s6)
    }
}

/// A row of Heaviest tickets (C49): the ticket, its meter against the cap, and its tokens over the slice in the value
/// column.
private struct HeavyTicketRow: View {
    let row: Usage.TicketRow
    let selected: Bool
    let select: () -> Void
    let open: () -> Void

    var body: some View {
        Row(
            row.identifier, lead: .glyph("gauge.with.needle", DesignTokens.TextColor.secondary), value: row.value,
            valueWidth: DesignTokens.Row.wideValueWidth, selected: selected, select: select, open: open
        ) {
            if let fraction = row.fraction {
                MeterBar(fraction: fraction, tint: tint).frame(width: DesignTokens.ProgressStrip.compactWidth)
            }
        }
        .accessibilityLabel("\(row.identifier), \(row.value)")
    }

    private var tint: Color {
        switch row.level {
        case .normal: DesignTokens.ColorToken.accent.color
        case .near: DesignTokens.Status.you.tint
        case .atLimit: DesignTokens.Status.problem.tint
        }
    }
}
