import AppKit
import Charts
import SwiftUI
import SymphonyBarCore

/// D7: Quality, from `/api/v1/history` (its `review` part) and `/api/v1/runs`.
struct QualityContent: View {
    @ObservedObject var model: SymphonyWindowModel

    var body: some View {
        if let quality = model.quality {
            QualityView(
                quality: Quality(history: quality.history, runs: quality.runs, period: model.qualityPeriod),
                period: $model.qualityPeriod,
                openTicket: model.openTicket,
                changeReview: model.changeReview
            )
        } else if model.qualityResult == .unsupported {
            EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
        } else {
            EmptyState(title: "Reading Symphony's history…", symbol: SymphonyView.quality.symbol, showsSpinner: true)
        }
    }
}

struct QualityView: View {
    let quality: Quality
    @Binding var period: Quality.Period
    var openTicket: (String) -> Void = { _ in }
    var changeReview: (String) -> Void = { _ in }

    var body: some View {
        ScrollView {
            QualityCards(quality: quality, period: $period, openTicket: openTicket, changeReview: changeReview)
        }
    }
}

/// Quality's cards, outside the scroll view so they also render offscreen.
struct QualityCards: View {
    let quality: Quality
    @Binding var period: Quality.Period
    var openTicket: (String) -> Void = { _ in }
    var changeReview: (String) -> Void = { _ in }
    @State private var showsRuns = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            HStack {
                Picker("Period", selection: $period) {
                    ForEach(Quality.Period.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Spacer()
                Button(Quality.showAllRunsTitle) { showsRuns = true }
            }
            HStack(spacing: DesignTokens.Space.s3) {
                ForEach(quality.tiles) { QualityTile(tile: $0) }
            }
            Card(title: Quality.agreementTitle) {
                AgreementChart(quality: quality, changeReview: changeReview)
            }
            Card(title: Quality.outcomesTitle) {
                OutcomesChart(quality: quality)
            }
            Card(title: Quality.disagreementsTitle) {
                if quality.disagreements.isEmpty {
                    Text("QA and you upheld every Code Review approval in this period.")
                        .font(DesignTokens.TypeStyle.body.font)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                        ForEach(quality.disagreements) { row in
                            DisagreementRowView(row: row).opensTicket(row.identifier, open: openTicket)
                        }
                    }
                }
            }
        }
        .padding(DesignTokens.Space.s6)
        .sheet(isPresented: $showsRuns) {
            AllRunsSheet(quality: quality) { showsRuns = false }
        }
    }
}

/// C5: a rate, its label and one line of context; tertiary while there is nothing to count.
private struct QualityTile: View {
    let tile: Quality.Tile

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            Text(tile.title)
                .font(DesignTokens.TypeStyle.label.font)
                .foregroundStyle(tile.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
            Text(tile.value)
                .font(DesignTokens.TypeStyle.figure.font)
                .foregroundStyle(tile.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .monospacedDigit()
            Text(tile.context)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(tile.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .lineLimit(2, reservesSpace: true)
        }
        .padding(DesignTokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                .strokeBorder(DesignTokens.Surface.separator.color)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tile.title), \(tile.value), \(tile.context)")
    }
}

/// C12: each repo's agreement as a bar, with its manual review and Change Review…; hover values, Show Data and a
/// chart description.
private struct AgreementChart: View {
    let quality: Quality
    var changeReview: (String) -> Void
    @State private var hovered: String?
    @State private var showsData = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            HStack {
                Text("Share of Code Review approvals that QA and you upheld")
                    .font(DesignTokens.TypeStyle.caption.font)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(Quality.showDataTitle) { showsData = true }
            }
            if quality.repos.isEmpty {
                Text("No Code Review approval in this period.")
                    .font(DesignTokens.TypeStyle.body.font)
                    .foregroundStyle(.secondary)
            } else {
                Chart(quality.repos) { repo in
                    BarMark(x: .value("Agreement", (repo.rate ?? 0) * 100), y: .value("Repo", repo.repoKey), height: .fixed(18))
                        .foregroundStyle(DesignTokens.ChartSeries.series1.color)
                        .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: DesignTokens.Radius.mark, topTrailingRadius: DesignTokens.Radius.mark))
                        .annotation(position: .trailing) {
                            Text(hovered == repo.repoKey ? "\(Quality.percent(repo.rate)), \(repo.value)" : Quality.percent(repo.rate))
                                .font(DesignTokens.TypeStyle.caption.font)
                                .foregroundStyle(.secondary)
                        }
                }
                // Room past 100% for the trailing value label, so a full bar's label isn't clipped.
                .chartXScale(domain: 0...100, range: .plotDimension(endPadding: 72))
                .chartXAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                    }
                }
                .chartOverlay { proxy in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(location): hovered = proxy.value(atY: location.y, as: String.self)
                            case .ended: hovered = nil
                            }
                        }
                }
                .frame(height: CGFloat(quality.repos.count) * 32 + 24)
                .accessibilityChartDescriptor(AgreementChartDescriptor(quality: quality))
                ForEach(quality.repos) { repo in
                    HStack {
                        Text(repo.repoKey).font(DesignTokens.TypeStyle.rowTitle.font)
                        Text(repo.mode).font(DesignTokens.TypeStyle.callout.font).foregroundStyle(.secondary)
                        Spacer()
                        Button(Quality.changeReviewTitle) { changeReview(repo.repoKey) }
                            .accessibilityLabel("\(Quality.changeReviewTitle) \(repo.repoKey)")
                    }
                }
            }
        }
        .sheet(isPresented: $showsData) {
            DataTable(title: Quality.agreementTitle, rows: quality.agreementTable) { showsData = false }
        }
    }
}

/// C12: runs per day stacked by outcome, in status colors with a legend; hover values, Show Data and a chart
/// description.
private struct OutcomesChart: View {
    let quality: Quality
    @State private var hovered: Date?
    @State private var showsData = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            HStack {
                HStack(spacing: DesignTokens.Space.s3) {
                    ForEach(quality.outcomes, id: \.self) { outcome in
                        HStack(spacing: DesignTokens.Space.s1) {
                            RoundedRectangle(cornerRadius: 2).fill(outcome.status.tint).frame(width: 10, height: 10)
                            Text(outcome.title).font(DesignTokens.TypeStyle.caption.font)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer()
                Button(Quality.showDataTitle) { showsData = true }
            }
            Chart {
                ForEach(quality.segments) { segment in
                    BarMark(
                        x: .value("Day", segment.date, unit: .day),
                        y: .value("Runs", segment.runs),
                        width: .fixed(min(24, 600 / Double(max(quality.dates.count, 1))))
                    )
                    .foregroundStyle(by: .value("Outcome", segment.outcome.title))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: DesignTokens.Radius.mark, topTrailingRadius: DesignTokens.Radius.mark))
                }
                if let hovered {
                    RuleMark(x: .value("Day", hovered, unit: .day))
                        .foregroundStyle(DesignTokens.Surface.separator.color)
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            Text(quality.hoverLine(on: hovered))
                                .font(DesignTokens.TypeStyle.caption.font)
                                .padding(DesignTokens.Space.s1)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.mark))
                        }
                }
            }
            .chartForegroundStyleScale(domain: quality.outcomes.map(\.title), range: quality.outcomes.map(\.status.tint))
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: max(quality.dates.count / 7, 1))) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel()
                }
            }
            .chartOverlay { proxy in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            hovered = proxy.value(atX: location.x, as: Date.self).flatMap { date in quality.dates.last { $0 <= date } }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
            .frame(height: 200)
            .accessibilityChartDescriptor(OutcomesChartDescriptor(quality: quality))
        }
        .sheet(isPresented: $showsData) {
            DataTable(title: Quality.outcomesTitle, rows: quality.outcomesTable) { showsData = false }
        }
    }
}

/// A row of Disagreements: the ticket, the Code Review decision and the one that overturned it.
private struct DisagreementRowView: View {
    let row: Quality.DisagreementRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
            Text(row.identifier).font(DesignTokens.TypeStyle.rowTitle.font)
            if let repo = row.repoKey {
                Text(repo).font(DesignTokens.TypeStyle.callout.font).foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignTokens.Space.s2)
            Text(row.review).font(DesignTokens.TypeStyle.callout.font)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            Text(row.decision).font(DesignTokens.TypeStyle.callout.font)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.identifier), \(row.review), \(row.decision)")
    }
}

/// Show All Runs (C19): the period's runs, filtered by agent, outcome and day.
private struct AllRunsSheet: View {
    let quality: Quality
    var done: () -> Void
    @State private var filter = Quality.RunFilter()

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            Text("All Runs").font(DesignTokens.TypeStyle.section.font)
            HStack {
                Picker("Agent", selection: $filter.agent) {
                    Text("All agents").tag(String?.none)
                    ForEach(quality.agents, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                Picker("Outcome", selection: $filter.outcome) {
                    Text("All outcomes").tag(QualityRun.Outcome?.none)
                    ForEach(QualityRun.Outcome.allCases, id: \.self) { Text($0.title).tag(QualityRun.Outcome?.some($0)) }
                }
                Picker("Day", selection: $filter.date) {
                    Text("All days").tag(String?.none)
                    ForEach(quality.runDates, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            }
            Table(quality.runs(matching: filter)) {
                TableColumn("Ticket") { Text($0.identifier ?? "—") }
                TableColumn("Agent", value: \.agent)
                TableColumn("Outcome") { Text($0.outcome.title) }
                TableColumn("Day", value: \.date)
                TableColumn("Tokens") { Text(Overview.tokens($0.tokens)).monospacedDigit() }
            }
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(minWidth: 640, minHeight: 420)
    }
}

private struct AgreementChartDescriptor: AXChartDescriptorRepresentable {
    let quality: Quality

    func makeChartDescriptor() -> AXChartDescriptor {
        let xAxis = AXCategoricalDataAxisDescriptor(title: "Repo", categoryOrder: quality.repos.map(\.repoKey))
        let yAxis = AXNumericDataAxisDescriptor(title: "Agreement", range: 0...100, gridlinePositions: []) { "\(Int($0))%" }
        let series = AXDataSeriesDescriptor(
            name: "Agreement", isContinuous: false,
            dataPoints: quality.repos.map { AXDataPoint(x: $0.repoKey, y: ($0.rate ?? 0) * 100, label: $0.mode) }
        )
        return AXChartDescriptor(
            title: Quality.agreementTitle, summary: quality.agreementSummary, xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: [series]
        )
    }
}

private struct OutcomesChartDescriptor: AXChartDescriptorRepresentable {
    let quality: Quality

    func makeChartDescriptor() -> AXChartDescriptor {
        let labels = quality.dates.map(Usage.dayLabel)
        let peak = quality.dates.map(quality.total(on:)).max() ?? 0
        let xAxis = AXCategoricalDataAxisDescriptor(title: "Day", categoryOrder: labels)
        let yAxis = AXNumericDataAxisDescriptor(title: "Runs", range: 0...Double(max(peak, 1)), gridlinePositions: []) { "\(Int($0))" }
        let series = quality.outcomes.map { outcome in
            AXDataSeriesDescriptor(
                name: outcome.title, isContinuous: false,
                dataPoints: quality.dates.map { date in
                    AXDataPoint(x: Usage.dayLabel(date), y: Double(quality.segments.first { $0.date == date && $0.outcome == outcome }?.runs ?? 0))
                }
            )
        }
        return AXChartDescriptor(
            title: Quality.outcomesTitle, summary: quality.outcomesSummary, xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: series
        )
    }
}
