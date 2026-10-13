import AppKit
import Charts
import SwiftUI
import SymphonyBarCore

/// D8: Usage, from `/api/v1/history` and `/api/v1/state`.
struct UsageContent: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient

    var body: some View {
        if let history = model.usageHistory {
            UsageView(usage: Usage(history: history, snapshot: model.overviewState?.snapshot), openTicket: model.openTicket)
        } else if model.historyResult == .unsupported {
            EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
        } else {
            EmptyState(title: "Reading Symphony's history…", symbol: SymphonyView.usage.symbol, showsSpinner: true)
        }
    }
}

struct UsageView: View {
    let usage: Usage
    var openTicket: (String) -> Void = { _ in }

    var body: some View {
        ScrollView {
            UsageCards(usage: usage, openTicket: openTicket)
        }
    }
}

/// Usage's cards, outside the scroll view so they also render offscreen.
struct UsageCards: View {
    let usage: Usage
    var openTicket: (String) -> Void = { _ in }

    var body: some View {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
                Card(title: Usage.tokensTitle) {
                    TokensChart(usage: usage)
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
                    if usage.heaviest.isEmpty {
                        Text("No ticket ran in this period.")
                            .font(DesignTokens.TypeStyle.body.font)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                            ForEach(usage.heaviest) { row in
                                HeavyTicketRow(row: row).opensTicket(row.identifier, open: openTicket)
                            }
                        }
                    }
                }
            }
            .padding(DesignTokens.Space.s6)
    }
}

/// C12: tokens per day, stacked by provider, against the daily budget's rule line; hover values, a legend, Show
/// Data and a chart description.
private struct TokensChart: View {
    let usage: Usage
    @State private var hovered: Date?
    @State private var showsData = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            HStack {
                Legend(providers: usage.providers)
                Spacer()
                Button(Usage.showDataTitle) { showsData = true }
            }
            Chart {
                ForEach(usage.segments) { segment in
                    BarMark(
                        x: .value("Day", segment.date, unit: .day),
                        y: .value("Tokens", segment.tokens),
                        width: .fixed(min(24, 600 / Double(max(usage.dates.count, 1))))
                    )
                    .foregroundStyle(by: .value("Provider", segment.provider.name))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: DesignTokens.Radius.mark, topTrailingRadius: DesignTokens.Radius.mark))
                }
                if let budget = usage.dailyBudget {
                    RuleMark(y: .value("Daily budget", budget))
                        .foregroundStyle(DesignTokens.SystemColor.secondary.color)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("Daily budget \(Overview.tokens(budget))")
                                .font(DesignTokens.TypeStyle.caption.font)
                                .foregroundStyle(.secondary)
                        }
                }
                if let hovered {
                    RuleMark(x: .value("Day", hovered, unit: .day))
                        .foregroundStyle(DesignTokens.Surface.separator.color)
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            Text(usage.hoverLine(on: hovered))
                                .font(DesignTokens.TypeStyle.caption.font)
                                .padding(DesignTokens.Space.s1)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.mark))
                        }
                }
            }
            .chartForegroundStyleScale(
                domain: usage.providers.map(\.name),
                range: usage.providers.map(\.series.color)
            )
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: max(usage.dates.count / 7, 1))) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel { Text(Overview.tokens(value.as(Int.self) ?? 0)) }
                }
            }
            .chartOverlay { proxy in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            hovered = proxy.value(atX: location.x, as: Date.self).flatMap(day)
                        case .ended:
                            hovered = nil
                        }
                    }
            }
            .frame(height: 220)
            .accessibilityChartDescriptor(TokensChartDescriptor(usage: usage))
        }
        .sheet(isPresented: $showsData) {
            DataTable(title: Usage.tokensTitle, rows: usage.dataTable) { showsData = false }
        }
    }

    /// The chart's day that `date` falls on.
    private func day(_ date: Date) -> Date? {
        usage.dates.last { $0 <= date }
    }
}

/// The legend: a swatch and the name of each provider, in the series order.
private struct Legend: View {
    let providers: [UsageProvider]

    var body: some View {
        HStack(spacing: DesignTokens.Space.s3) {
            ForEach(providers, id: \.self) { provider in
                HStack(spacing: DesignTokens.Space.s1) {
                    RoundedRectangle(cornerRadius: 2).fill(provider.series.color).frame(width: 10, height: 10)
                    Text(provider.name).font(DesignTokens.TypeStyle.caption.font)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Show Data: the chart's series as a table.
struct DataTable: View {
    let title: String
    let rows: [[String]]
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            Text(title).font(DesignTokens.TypeStyle.section.font)
            ScrollView {
                Grid(alignment: .trailing, horizontalSpacing: DesignTokens.Space.s4, verticalSpacing: DesignTokens.Space.s1) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                                Text(cell)
                                    .font(index == 0 ? DesignTokens.TypeStyle.label.font : DesignTokens.TypeStyle.body.font)
                                    .monospacedDigit()
                                    .gridColumnAlignment(column == 0 ? .leading : .trailing)
                            }
                        }
                        if index == 0 { Divider() }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(minWidth: 420, minHeight: 360)
    }
}

/// A row of Heaviest tickets: the ticket, its tokens and attempts, and a meter against the cap.
private struct HeavyTicketRow: View {
    let row: Usage.TicketRow

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.identifier).font(DesignTokens.TypeStyle.rowTitle.font)
                if let title = row.title {
                    Text(title).font(DesignTokens.TypeStyle.body.font).lineLimit(1)
                }
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
        .accessibilityLabel("\(row.identifier), \(row.title ?? ""), \(row.value)")
    }

    private var tint: Color {
        switch row.level {
        case .normal: DesignTokens.SystemColor.accent.color
        case .near: DesignTokens.Status.you.tint
        case .atLimit: DesignTokens.Status.problem.tint
        }
    }
}

/// The tokens chart for VoiceOver's audio graphs: one series per provider.
private struct TokensChartDescriptor: AXChartDescriptorRepresentable {
    let usage: Usage

    func makeChartDescriptor() -> AXChartDescriptor {
        let labels = usage.dates.map(Usage.dayLabel)
        let peak = usage.dates.map(usage.total(on:)).max() ?? 0
        let xAxis = AXCategoricalDataAxisDescriptor(title: "Day", categoryOrder: labels)
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Tokens", range: 0...Double(max(peak, usage.dailyBudget ?? 0, 1)), gridlinePositions: []
        ) { Overview.tokens(Int($0)) }
        let series = usage.providers.map { provider in
            AXDataSeriesDescriptor(
                name: provider.name, isContinuous: false,
                dataPoints: usage.dates.map { date in
                    AXDataPoint(
                        x: Usage.dayLabel(date),
                        y: Double(usage.segments.first { $0.date == date && $0.provider == provider }?.tokens ?? 0)
                    )
                }
            )
        }
        return AXChartDescriptor(
            title: Usage.tokensTitle, summary: usage.chartSummary, xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: series
        )
    }
}
