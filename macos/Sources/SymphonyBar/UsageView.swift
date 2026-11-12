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
                VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                    ForEach(usage.heaviest) { row in
                        HeavyTicketRow(row: row).opensTicket(row.identifier, open: openTicket)
                    }
                }
            }
        }
        .padding(DesignTokens.Space.s6)
    }
}

/// A row of Heaviest tickets: the ticket, its tokens over the slice, and a meter against the cap.
private struct HeavyTicketRow: View {
    let row: Usage.TicketRow

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.identifier).font(DesignTokens.TypeStyle.rowTitle.font)
                Spacer(minLength: DesignTokens.Space.s2)
                Text(row.value)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let fraction = row.fraction {
                MeterBar(fraction: fraction, tint: tint)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.identifier), \(row.value)")
    }

    private var tint: Color {
        switch row.level {
        case .normal: DesignTokens.SystemColor.accent.color
        case .near: DesignTokens.Status.you.tint
        case .atLimit: DesignTokens.Status.problem.tint
        }
    }
}
