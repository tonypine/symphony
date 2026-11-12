import AppKit
import Charts
import SwiftUI
import SymphonyBarCore

// MARK: - The page around the control bar

/// An Insights page (TP-1463): the control bar Quality, Usage and Shipped share, over the page drawn from the slice's
/// aggregate read. While the read for the slice shown hasn't answered, the page waits under the bar.
struct InsightsPage<Content: View>: View {
    @ObservedObject var model: SymphonyWindowModel
    let symbol: String
    @ViewBuilder let content: (AggregatePayload) -> Content

    var body: some View {
        VStack(spacing: 0) {
            InsightsControlBar(
                slice: $model.insightsSlice, values: model.insightsValues, today: model.insightsToday,
                summary: current.map { Insights.summary($0, slice: model.insightsSlice, scope: model.scope) }, scope: model.scope
            )
            Divider()
            if let aggregate = current {
                content(aggregate)
            } else if model.aggregateResult == .unsupported {
                EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
            } else {
                EmptyState(title: "Reading Symphony's numbers…", symbol: symbol, showsSpinner: true)
            }
        }
    }

    /// The aggregate of the slice the bar shows; nil while its read is on its way.
    private var current: AggregatePayload? {
        model.aggregatePath == model.aggregateReadPath ? model.aggregate : nil
    }
}

/// A page's empty slice: what it holds no figure for, and one button that widens the period.
struct InsightsEmptyState: View {
    let empty: InsightsEmpty
    let symbol: String
    var widen: (InsightsPeriod) -> Void = { _ in }

    var body: some View {
        EmptyState(title: empty.title, symbol: symbol, actions: actions)
    }

    private var actions: [(title: String, perform: () -> Void)] {
        guard let title = empty.actionTitle, let period = empty.widen else { return [] }
        return [(title, { widen(period) })]
    }
}

// MARK: - The control bar

/// The Insights control bar (the catalog's Control bar section): the period, the unit, the repo and the epic, small
/// (24 pt) menus on one line, and the one-line summary of what the page shows. On a laptop the summary sits under the
/// controls; when the line has room for both (a desktop), beside them.
struct InsightsControlBar: View {
    @Binding var slice: InsightsSlice
    let values: InsightsControlValues
    let today: String
    /// Nil while the slice's read is on its way.
    let summary: String?
    var scope: OverviewScope = .all
    @State private var showsRange = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Space.s4) {
                controls
                Spacer(minLength: DesignTokens.Space.s4)
                summaryLine
            }
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                controls
                summaryLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DesignTokens.Space.s6)
        .padding(.vertical, DesignTokens.Space.s2)
        .popover(isPresented: $showsRange, arrowEdge: .bottom) {
            InsightsRangeEditor(period: slice.period, today: today) { period in
                slice.choose(period, today: today)
                showsRange = false
            }
        }
    }

    private var controls: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            TicketsBarMenu(title: "Period: \(slice.period.title)", help: "Change the period", kind: .secondary) {
                ForEach(InsightsPreset.allCases) { preset in
                    Toggle(preset.title, isOn: Binding(get: { slice.period == .preset(preset) }, set: { _ in slice.choose(.preset(preset), today: today) }))
                }
                Divider()
                Button(Self.rangeTitle) { showsRange = true }
            }
            TicketsBarMenu(title: "Unit: \(slice.unit.title)", help: "Change how much time each bar holds", kind: .secondary) {
                ForEach(InsightsUnit.allCases) { unit in
                    Toggle(unit.title, isOn: Binding(get: { slice.unit == unit }, set: { _ in slice.unit = unit }))
                        .disabled(!slice.allows(unit, today: today))
                }
            }
            TicketsBarMenu(
                title: "Repo: \(slice.repo ?? scope.stored ?? OverviewScope.allTitle)", help: "Change the repo",
                kind: slice.repo == nil ? .quiet : .secondary
            ) {
                Button(OverviewScope.allTitle) { slice.repo = nil }
                Divider()
                ForEach(values.repos, id: \.self) { repo in
                    Toggle(repo, isOn: Binding(get: { slice.repo == repo }, set: { slice.repo = $0 ? repo : nil }))
                }
            }
            TicketsBarMenu(
                title: "Epic: \(slice.epic ?? InsightsSlice.allEpics)", help: "Change the epic", kind: slice.epic == nil ? .quiet : .secondary
            ) {
                Button(InsightsSlice.allEpics) { slice.epic = nil }
                Divider()
                ForEach(values.epics, id: \.self) { epic in
                    Toggle(epic, isOn: Binding(get: { slice.epic == epic }, set: { slice.epic = $0 ? epic : nil }))
                }
            }
        }
        .fixedSize()
    }

    @ViewBuilder private var summaryLine: some View {
        Text(summary ?? slice.title(scope: scope))
            .font(DesignTokens.TypeStyle.callout.font)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("Showing \(summary ?? slice.title(scope: scope))")
    }

    static let rangeTitle = "Range…"
}

/// The period's range: a first and a last day, in UTC as Symphony counts them, at most a year apart.
private struct InsightsRangeEditor: View {
    let today: String
    var apply: (InsightsPeriod) -> Void
    @State private var from: Date
    @State private var to: Date

    init(period: InsightsPeriod, today: String, apply: @escaping (InsightsPeriod) -> Void) {
        self.today = today
        self.apply = apply
        let days = period.days(today: today)
        _from = State(initialValue: Self.date(days.from))
        _to = State(initialValue: Self.date(days.to))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            DatePicker("From", selection: $from, in: ...to, displayedComponents: .date)
            DatePicker("To", selection: $to, in: from...Self.date(today), displayedComponents: .date)
            HStack {
                Spacer()
                Button("Show Range") { apply(.range(from: Insights.today(from), to: Insights.today(to))) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
        .padding(DesignTokens.Space.s4)
        .frame(width: 280)
    }

    private static func date(_ day: String) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return Date() }
        return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ?? Date()
    }
}

// MARK: - A chart

/// C12 for an Insights series: one bar per bucket, at most 24 pt wide, stacked by key, one reference line, the value on
/// the last bar; a legend, hover values, Show Data and a chart description.
struct InsightsBarChart: View {
    let chart: InsightsChart
    var caption: String?
    var height: CGFloat = 200
    @State private var hovered: String?
    @State private var showsData = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            HStack {
                if let caption {
                    Text(caption).font(DesignTokens.TypeStyle.caption.font).foregroundStyle(.secondary)
                } else {
                    InsightsLegend(keys: chart.keys)
                }
                Spacer()
                Button(Usage.showDataTitle) { showsData = true }
            }
            Chart {
                ForEach(chart.segments) { segment in
                    BarMark(
                        x: .value(Insights.bucketColumn, segment.bar),
                        y: .value(chart.measure, segment.value),
                        width: .fixed(min(24, 600 / Double(max(chart.bars.count, 1))))
                    )
                    .foregroundStyle(by: .value("Key", segment.key.name))
                    .clipShape(Self.shape(segment))
                    .annotation(position: .top) {
                        if segment.isTop, let last = chart.lastValue, last.id == segment.bar {
                            Text(last.text).font(DesignTokens.TypeStyle.caption.font).foregroundStyle(.secondary)
                        }
                    }
                }
                if let reference = chart.reference {
                    RuleMark(y: .value(reference.title, reference.value))
                        .foregroundStyle(DesignTokens.SystemColor.secondary.color)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("\(reference.title) \(chart.value(reference.value))")
                                .font(DesignTokens.TypeStyle.caption.font)
                                .foregroundStyle(.secondary)
                        }
                }
                if let hovered {
                    RuleMark(x: .value(Insights.bucketColumn, hovered))
                        .foregroundStyle(DesignTokens.Surface.separator.color)
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            Text(chart.hoverLine(hovered))
                                .font(DesignTokens.TypeStyle.caption.font)
                                .padding(DesignTokens.Space.s1)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.mark))
                        }
                }
            }
            .chartXScale(domain: chart.bars.map(\.id))
            .chartForegroundStyleScale(domain: chart.keys.map(\.name), range: chart.keys.map(\.tint.color))
            .chartLegend(.hidden)
            .chartXAxis {
                // A categorical axis labels every bar: only about seven carry their label.
                AxisMarks { value in
                    AxisValueLabel(centered: true) {
                        Text(axisLabel(value.as(String.self)))
                    }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel { Text(chart.value(value.as(Int.self) ?? 0)) }
                }
            }
            .chartOverlay { proxy in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location): hovered = proxy.value(atX: location.x, as: String.self)
                        case .ended: hovered = nil
                        }
                    }
            }
            .frame(height: height)
            .accessibilityChartDescriptor(InsightsChartDescriptor(chart: chart))
        }
        .sheet(isPresented: $showsData) {
            DataTable(title: chart.title, rows: chart.dataTable) { showsData = false }
        }
    }

    /// The axis label of a bar: its own for the labelled ones, none for the bars between.
    private func axisLabel(_ id: String?) -> String {
        guard let id, labelled.contains(id) else { return "" }
        return chart.label(id)
    }

    private var labelled: Set<String> { Set(chart.labelled) }

    /// The top mark of a bar is rounded on its top corners.
    static func shape(_ segment: InsightsChart.Segment) -> UnevenRoundedRectangle {
        let radius = segment.isTop ? DesignTokens.Radius.mark : 0
        return UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius)
    }
}

/// The legend: a swatch and the name of each key, in the stacking order.
struct InsightsLegend: View {
    let keys: [InsightsChart.Key]

    var body: some View {
        HStack(spacing: DesignTokens.Space.s3) {
            ForEach(keys) { key in
                HStack(spacing: DesignTokens.Space.s1) {
                    RoundedRectangle(cornerRadius: 2).fill(key.tint.color).frame(width: 10, height: 10)
                    Text(key.name).font(DesignTokens.TypeStyle.caption.font)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension InsightsChart.Tint {
    var color: Color {
        switch self {
        case let .series(series): series.color
        case let .status(status): status.tint
        }
    }
}

/// Show Data: a chart's series as a table.
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

/// An Insights chart for VoiceOver's audio graphs: one series per key.
private struct InsightsChartDescriptor: AXChartDescriptorRepresentable {
    let chart: InsightsChart

    func makeChartDescriptor() -> AXChartDescriptor {
        let peak = chart.bars.map(\.total).max() ?? 0
        let xAxis = AXCategoricalDataAxisDescriptor(title: Insights.bucketColumn, categoryOrder: chart.bars.map(\.label))
        let yAxis = AXNumericDataAxisDescriptor(
            title: chart.measure, range: 0...Double(max(peak, chart.reference?.value ?? 0, 1)), gridlinePositions: []
        ) { chart.value(Int($0)) }
        let series = chart.keys.map { key in
            AXDataSeriesDescriptor(
                name: key.name, isContinuous: false,
                dataPoints: chart.bars.map { AXDataPoint(x: $0.label, y: Double($0.values[key.key] ?? 0)) }
            )
        }
        return AXChartDescriptor(title: chart.title, summary: chart.summary, xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: series)
    }
}
