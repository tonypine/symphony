import AppKit
import Charts
import SwiftUI
import SymphonyBarCore

/// D7: Quality over the Insights slice (TP-1463), from `/api/v1/aggregate`, the `review` part of `/api/v1/history` and
/// `/api/v1/runs`.
struct QualityContent: View {
    @ObservedObject var model: SymphonyWindowModel

    var body: some View {
        InsightsPage(model: model, symbol: SymphonyView.quality.symbol) { aggregate in
            QualityView(
                quality: Quality(
                    aggregate: aggregate, slice: model.insightsSlice, scope: model.scope, review: model.quality?.history.review,
                    runs: model.quality?.runs ?? [], today: model.insightsToday
                ),
                openTicket: model.openTicket,
                changeReview: model.changeReview,
                widen: { model.insightsSlice.choose($0, today: model.insightsToday) }
            )
        }
    }
}

struct QualityView: View {
    let quality: Quality
    var openTicket: (String) -> Void = { _ in }
    var changeReview: (String) -> Void = { _ in }
    var widen: (InsightsPeriod) -> Void = { _ in }

    var body: some View {
        if let empty = quality.empty {
            InsightsEmptyState(empty: empty, symbol: SymphonyView.quality.symbol, widen: widen)
        } else {
            ScrollView {
                QualityCards(quality: quality, openTicket: openTicket, changeReview: changeReview)
            }
        }
    }
}

/// Quality's cards, outside the scroll view so they also render offscreen.
struct QualityCards: View {
    let quality: Quality
    var openTicket: (String) -> Void = { _ in }
    var changeReview: (String) -> Void = { _ in }
    @State private var showsRuns = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            HStack(spacing: DesignTokens.Space.s3) {
                ForEach(quality.tiles) { QualityTile(tile: $0) }
            }
            Card(title: quality.runsChart.title) {
                InsightsBarChart(chart: quality.runsChart)
            }
            Card(title: quality.verdictsChart.title) {
                InsightsBarChart(chart: quality.verdictsChart, height: 160)
            }
            Card(title: Quality.agreementTitle) {
                AgreementChart(quality: quality, changeReview: changeReview)
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
            HStack {
                Spacer()
                Button(Quality.showAllRunsTitle) { showsRuns = true }
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
                Text(quality.agreementNote)
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
