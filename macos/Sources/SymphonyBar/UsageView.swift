import AppKit
import Charts
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

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

// MARK: - C11: meters

struct MeterView: View {
    let meter: Overview.Meter

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.label).font(DesignTokens.TypeStyle.body.font)
                Spacer(minLength: DesignTokens.Space.s2)
                Text(meter.value)
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            if let fraction = meter.fraction {
                MeterBar(fraction: fraction, tint: tint)
            }
            if let note = meter.note {
                Text(note)
                    .font(DesignTokens.TypeStyle.caption.font)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meter.accessibilityLabel + (meter.note.map { ", \($0)" } ?? ""))
    }

    private var tint: Color {
        switch meter.level {
        case .normal: DesignTokens.ColorToken.accent.color
        case .near: DesignTokens.Status.you.tint
        case .atLimit: DesignTokens.Status.problem.tint
        }
    }
}

/// A meter's bar: the fill carries the level, on a track that is a light step of the same hue (design system §3.3).
/// Drawn rather than a `Gauge`, whose AppKit control doesn't render offscreen.
struct MeterBar: View {
    let fraction: Double
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.2))
                Capsule()
                    .fill(tint)
                    .frame(width: max(proxy.size.width * fraction, fraction > 0 ? proxy.size.height : 0))
            }
        }
        .frame(height: 6)
        .animation(reduceMotion ? nil : .standard, value: fraction)
        .accessibilityHidden(true)
    }
}
