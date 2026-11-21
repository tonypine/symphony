import AppKit
import Charts
import SwiftUI
import SymphonyBarCore

// MARK: - The page around the control bar

/// An Insights page (TP-1463): the control bar Quality, Usage and Shipped share, over the page drawn from the slice's
/// aggregate read. While the read for the slice shown hasn't answered, the page waits under the bar, which stays at
/// the top of the page in every state (TP-1490).
struct InsightsPage<Content: View>: View {
    @ObservedObject var model: SymphonyWindowModel
    let symbol: String
    /// Shipped's Shipped and Learnings switch, in the bar on Shipped (TP-1497).
    var shippedTab: Binding<Shipped.Tab>?
    @ViewBuilder let content: (AggregatePayload) -> Content

    var body: some View {
        PinnedBarPage {
            InsightsControlBar(
                slice: $model.insightsSlice, values: model.insightsValues, today: model.insightsToday,
                summary: current.map { Insights.summary($0, slice: model.insightsSlice, scope: model.scope) }, scope: model.scope,
                shippedTab: shippedTab
            )
        } content: {
            switch model.aggregateShown {
            case let .loaded(aggregate):
                content(aggregate)
            case .unsupported:
                EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
            case let .failed(message):
                EmptyState(
                    title: "Symphony couldn't read these numbers: \(message)", symbol: "exclamationmark.triangle",
                    actions: [("Try Again", model.readAggregateAgain)]
                )
            case .reading:
                EmptyState(title: "Reading Symphony's numbers…", symbol: symbol, showsSpinner: true)
            }
        }
    }

    /// The aggregate of the slice the bar shows; nil while its read is on its way or failed.
    private var current: AggregatePayload? {
        if case let .loaded(aggregate) = model.aggregateShown { aggregate } else { nil }
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

/// The Insights control bar (the catalog's Control bar section, drawn by the shared `ControlBar`): on Shipped its
/// Shipped and Learnings switch first, then the period as a small (24 pt) segmented control and Range… for other days,
/// the unit, the repo and the epic as small pop-ups, Clear when a repo or an epic is picked, wrapping onto a second line
/// when the bar can't hold them on one, and the one-line summary of what the page shows: on its own line under the
/// controls on a laptop, right aligned beside them from 1600 pt (a desktop).
struct InsightsControlBar: View {
    @Binding var slice: InsightsSlice
    let values: InsightsControlValues
    let today: String
    /// Nil while the slice's read is on its way.
    let summary: String?
    var scope: OverviewScope = .all
    /// Shipped's switch to its Learnings tab; nil on Quality and Usage.
    var shippedTab: Binding<Shipped.Tab>?
    @State private var showsRange = false

    var body: some View {
        ControlBar("What the page shows", summary: summary ?? slice.title(scope: scope)) {
            controls
        }
        .popover(isPresented: $showsRange, arrowEdge: .bottom) {
            InsightsRangeEditor(period: slice.period, today: today) { period in
                slice.choose(period, today: today)
                showsRange = false
            }
            .pointerButtons()
        }
    }

    /// The groups on one line when the bar holds them, else wrapped onto the next (a laptop's window as it opens holds
    /// Shipped's switch and the four groups on two lines); a group never splits.
    private var controls: some View {
        WrappingStack(spacing: DesignTokens.ControlBar.groupGap, lineSpacing: DesignTokens.ControlBar.gap) {
            if let shippedTab {
                ShippedTabSwitch(tab: shippedTab)
            }
            group("Period") {
                SegmentedControl(
                    "Period",
                    selection: Binding(get: { slice.period }, set: { slice.choose($0, today: today) }),
                    segments: InsightsPreset.allCases.map { Segment(InsightsPeriod.preset($0), $0.segment) },
                    size: .small
                )
                Button(Self.rangeTitle) { showsRange = true }
                    .directorButton(.quiet, size: .small, selected: isRange)
                    .help(isRange ? "The days shown: \(slice.period.title). Pick other days" : "Pick the first and the last day")
            }
            group("Unit") {
                PopUp(
                    nil, selection: $slice.unit,
                    choices: InsightsUnit.allCases.map { unit in
                        PopUpChoice(unit, unit.title, disabledReason: slice.allows(unit, today: today) ? nil : InsightsSlice.tooManyBars)
                    },
                    size: .small, help: "Change how much time each bar holds", accessibilityLabel: "Unit"
                )
            }
            PopUp(
                "Repo", selection: $slice.repo,
                choices: popUpChoices(all: OverviewScope.allTitle, values.repos),
                value: slice.repo ?? scope.stored ?? OverviewScope.allTitle, size: .small, help: "Change the repo"
            )
            PopUp(
                "Epic", selection: $slice.epic,
                choices: popUpChoices(all: InsightsSlice.allEpics, values.epics),
                size: .small, help: "Change the epic"
            )
            if slice.isFiltered {
                Button(Self.clearTitle) { slice.clear() }
                    .directorButton(.quiet, size: .small)
                    .help("Show every repo and every epic")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Whether the period is a range of days rather than one of the segments.
    private var isRange: Bool {
        if case .range = slice.period { true } else { false }
    }

    /// A control under its label, side by side: "Period [Last 7 days ⌃⌄]".
    private func group(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: DesignTokens.ControlBar.gap) {
            Text(label)
                .textStyle(.label)
                .foregroundStyle(DesignTokens.TextColor.secondary.color)
                .accessibilityHidden(true)
            control()
        }
    }

    static let rangeTitle = "Range…"
    static let clearTitle = "Clear"
}

/// Shipped's Shipped and Learnings switch (a small segmented control), first in the page's control bar on either tab.
struct ShippedTabSwitch: View {
    @Binding var tab: Shipped.Tab

    var body: some View {
        SegmentedControl("Shipped or Learnings", selection: $tab, segments: Shipped.Tab.allCases.map { Segment($0, $0.title) }, size: .small)
    }
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
                        .foregroundStyle(DesignTokens.TextColor.secondary.color)
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
                                .glassBackground(.thick, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.mark))
                        }
                }
            }
            .chartXScale(domain: chart.bars.map(\.id))
            .chartForegroundStyleScale(domain: chart.keys.map(\.name), range: chart.keys.map(\.tint.color))
            .chartLegend(.hidden)
            .chartXAxis {
                // A categorical axis marks every bar: only about seven carry their label, drawn at its full width over
                // the empty bars beside it, so none is cut short.
                AxisMarks { value in
                    AxisValueLabel(centered: true, collisionResolution: .disabled) {
                        Text(axisLabel(value.as(String.self))).fixedSize()
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
            ShowDataSheet(title: chart.title, rows: chart.dataTable) { showsData = false }
            .pointerButtons()
        }
    }

    /// The axis label of a bar: its day, or its time inside a day, for the labelled ones; none for the bars between.
    private func axisLabel(_ id: String?) -> String {
        guard let id, labelled.contains(id) else { return "" }
        return chart.axisLabel(id)
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

/// Show Data: a chart's series as the shared table (C59): its first row the column titles, the first column the words
/// that share the width, a column whose every cell is a number at the trailing edge in tabular figures.
struct ShowDataSheet: View {
    let title: String
    let rows: [[String]]
    var done: () -> Void
    @State private var selection: Int?
    @State private var sort: DesignTokens.Table.Sort?

    /// One row of the series: its place in the chart's order and its cells.
    struct Line: Identifiable {
        let id: Int
        let cells: [String]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            Text(title).textStyle(.heading)
            DataTable(title, columns: Self.columns(rows), rows: Self.lines(rows), selection: $selection, sort: $sort)
            HStack {
                Spacer()
                Button("Done", action: done).directorButton(.primary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(minWidth: 420, minHeight: 360)
    }

    static func lines(_ rows: [[String]]) -> [Line] {
        rows.dropFirst().enumerated().map { Line(id: $0.offset, cells: $0.element) }
    }

    static func columns(_ rows: [[String]]) -> [DataTableColumn<Line>] {
        let titles = rows.first ?? []
        let body = rows.dropFirst()
        return titles.indices.map { index in
            let numbers = !body.isEmpty && body.allSatisfy { row in
                index < row.count && DesignTokens.Table.Sort.number(row[index]) != nil
            }
            return DataTableColumn<Line>(
                titles[index], id: "\(index)", alignment: numbers && index > 0 ? .number : .text,
                width: index == 0 ? .share(1) : .fit
            ) { line in index < line.cells.count ? line.cells[index] : "" }
        }
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
