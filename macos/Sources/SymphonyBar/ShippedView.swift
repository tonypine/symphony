import AppKit
import Charts
import SwiftUI
import SymphonyBarCore

// MARK: - The window model's Shipped and Learnings

extension SymphonyWindowModel {
    /// Opens Shipped on its Shipped tab and reads it at once: the Overview's Shipped today tile and Show Shipped.
    func showShipped() {
        shippedTab = .shipped
        show(.shipped)
        shippedReadAt = nil
        readShippedIfDue()
    }

    /// Reads Shipped's merged tickets for its period and every learning while Shipped shows. Symphony answers both
    /// from its own records, with no Linear request.
    func readShippedIfDue() {
        guard selection == .shipped, !showsPage, !readingShipped, state.countsKnown,
            shippedReadAt.map({ Date().timeIntervalSince($0) >= Self.historyInterval }) ?? true
        else { return }
        readingShipped = true
        let period = shippedPeriod
        Task {
            let result = await client.get(ShippedPayload.path(days: period.rawValue))
            if period == shippedPeriod {
                if case let .loaded(data) = result, let payload = ShippedPayload.decode(data) {
                    shipped = payload
                    shippedResult = nil
                } else {
                    shippedResult = result
                }
            }
            let learningsResult = await client.get(LearningsPayload.path)
            if case let .loaded(data) = learningsResult, let payload = LearningsPayload.decode(data) {
                learnings = payload
                self.learningsResult = nil
            } else {
                self.learningsResult = learningsResult
            }
            shippedReadAt = period == shippedPeriod ? Date() : nil
            readingShipped = false
            if shippedReadAt == nil { readShippedIfDue() }
        }
    }

    /// The way out of Shipped's empty state.
    func perform(_ action: Shipped.Empty.Action) {
        switch action {
        case let .widen(period): shippedPeriod = period
        case .showAllRepos: scope = .all
        }
    }

    /// The way out of the Learnings tab's empty state.
    func perform(_ action: Learnings.Empty.Action) {
        switch action {
        case .clearFilters:
            learningsFilter = Learnings.Filter()
        case .showAllRepos:
            scope = .all
        case .showShipped:
            shippedTab = .shipped
        }
    }
}

/// D9: Shipped, or its Learnings tab, from `/api/v1/shipped` and `/api/v1/learnings`, under the window's scope.
struct ShippedContent: View {
    @ObservedObject var model: SymphonyWindowModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            switch model.shippedTab {
            case .shipped:
                shippedTab
            case .learnings:
                learningsTab
                    .searchable(text: $model.learningsFilter.search, placement: .toolbar, prompt: Learnings.searchPrompt)
                    .searchFocused($searchFocused)
            }
        }
        .onChange(of: model.learningsSearchRequested, initial: true) { _, requested in
            guard requested else { return }
            searchFocused = true
            model.learningsSearchRequested = false
        }
    }

    @ViewBuilder private var shippedTab: some View {
        if let payload = model.shipped {
            ShippedView(
                shipped: Shipped(payload: payload, period: model.shippedPeriod, scope: model.scope),
                period: $model.shippedPeriod,
                openTicket: model.openTicket,
                openURL: model.onOpenURL,
                perform: model.perform
            )
        } else if model.shippedResult == .unsupported {
            EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
        } else {
            EmptyState(title: "Reading what shipped…", symbol: SymphonyView.shipped.symbol, showsSpinner: true)
        }
    }

    @ViewBuilder private var learningsTab: some View {
        if let payload = model.learnings {
            LearningsView(
                learnings: Learnings(payload: payload, filter: model.learningsFilter, scope: model.scope),
                filter: $model.learningsFilter,
                openTicket: model.openTicket,
                openURL: model.onOpenURL,
                perform: model.perform
            )
        } else if model.learningsResult == .unsupported {
            EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
        } else {
            EmptyState(title: "Reading the crew's learnings…", symbol: "lightbulb", showsSpinner: true)
        }
    }
}

struct ShippedView: View {
    let shipped: Shipped
    @Binding var period: Shipped.Period
    var openTicket: (String) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }
    var perform: (Shipped.Empty.Action) -> Void = { _ in }

    var body: some View {
        if let empty = shipped.empty {
            VStack(spacing: 0) {
                PeriodBar(period: $period).padding([.horizontal, .top], DesignTokens.Space.s6)
                EmptyState(
                    title: empty.title,
                    symbol: SymphonyView.shipped.symbol,
                    actions: empty.action.map { action in [(action.title, { perform(action) })] } ?? []
                )
            }
        } else {
            ScrollView {
                ShippedCards(shipped: shipped, period: $period, openTicket: openTicket, openURL: openURL)
            }
        }
    }
}

/// The period pop-up.
private struct PeriodBar: View {
    @Binding var period: Shipped.Period

    var body: some View {
        HStack {
            Picker("Period", selection: $period) {
                ForEach(Shipped.Period.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Spacer()
        }
    }
}

/// Shipped's sentence, chart and days, outside the scroll view so they also render offscreen.
struct ShippedCards: View {
    let shipped: Shipped
    @Binding var period: Shipped.Period
    var openTicket: (String) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            PeriodBar(period: $period)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                Text(shipped.sentence)
                    .font(DesignTokens.TypeStyle.sentence.font)
                    .accessibilityAddTraits(.isHeader)
                if !shipped.context.isEmpty {
                    Text(shipped.context)
                        .font(DesignTokens.TypeStyle.callout.font)
                        .foregroundStyle(.secondary)
                }
            }
            Card(title: Shipped.chartTitle) {
                ShippedChart(shipped: shipped)
            }
            ForEach(shipped.groups) { group in
                Card(title: group.title) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Divider() }
                            ShippedRowView(row: row, openURL: openURL)
                                .padding(.vertical, DesignTokens.Space.s2)
                                .opensTicket(row.identifier, open: openTicket)
                        }
                    }
                }
            }
        }
        .padding(DesignTokens.Space.s6)
    }
}

/// A merged ticket: identifier and title, then its repo, initiative and PR, and its time from Todo to Done.
private struct ShippedRowView: View {
    let row: Shipped.Row
    var openURL: (URL) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1 / 2) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                    Text(row.identifier).font(DesignTokens.TypeStyle.rowTitle.font)
                    Text(row.title).font(DesignTokens.TypeStyle.body.font).lineLimit(1)
                }
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(DesignTokens.TypeStyle.callout.font)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: DesignTokens.Space.s2)
            if let url = row.prURL, let title = row.prTitle {
                LinkButton(title: title) { openURL(url) }
                    .help("Open \(title) on GitHub")
                    .accessibilityLabel("Open \(title) on GitHub")
            }
            if let leadTime = row.leadTime {
                Text(leadTime)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 72, alignment: .trailing)
                    .help("Time from Todo to Done")
            }
        }
        .accessibilityLabel(row.accessibilityLabel)
    }
}

/// A text button in the accent color, drawn by SwiftUI so it also renders offscreen.
private struct LinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(DesignTokens.TypeStyle.callout.font).foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}

/// C12: shipped per day in one hue, with the count on the last bar; hover values, Show Data and a chart
/// description.
private struct ShippedChart: View {
    let shipped: Shipped
    @State private var hovered: Date?
    @State private var showsData = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            HStack {
                Text("Tickets merged each day")
                    .font(DesignTokens.TypeStyle.caption.font)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(Shipped.showDataTitle) { showsData = true }
            }
            Chart {
                ForEach(shipped.bars) { bar in
                    BarMark(
                        x: .value("Day", Self.plotted(bar.date), unit: .day),
                        y: .value("Shipped", bar.shipped),
                        width: .fixed(min(24, 600 / Double(max(shipped.bars.count, 1))))
                    )
                    .foregroundStyle(DesignTokens.ChartSeries.series1.color)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: DesignTokens.Radius.mark, topTrailingRadius: DesignTokens.Radius.mark))
                    .annotation(position: .top) {
                        if bar.id == shipped.bars.last?.id, bar.shipped > 0 {
                            Text("\(bar.shipped)")
                                .font(DesignTokens.TypeStyle.caption.font)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let hovered {
                    RuleMark(x: .value("Day", Self.plotted(hovered), unit: .day))
                        .foregroundStyle(DesignTokens.Surface.separator.color)
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            Text(shipped.hoverLine(on: hovered))
                                .font(DesignTokens.TypeStyle.caption.font)
                                .padding(DesignTokens.Space.s1)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.mark))
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: labelled.map { Self.plotted($0.date) }) { value in
                    AxisValueLabel(centered: true) {
                        if let date = value.as(Date.self) { Text(Usage.dayLabel(Self.day(of: date))) }
                    }
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
                            hovered = proxy.value(atX: location.x, as: Date.self).flatMap { date in
                                shipped.bars.last { Self.plotted($0.date) <= date }?.date
                            }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
            .frame(height: 180)
            .accessibilityChartDescriptor(ShippedChartDescriptor(shipped: shipped))
        }
        .sheet(isPresented: $showsData) {
            DataTable(title: Shipped.chartTitle, rows: shipped.dataTable) { showsData = false }
        }
    }

    /// About seven labelled days, whatever the period.
    private var labelled: [Shipped.DayBar] {
        let step = max(shipped.bars.count / 7, 1)
        return shipped.bars.enumerated().filter { $0.offset % step == 0 }.map(\.element)
    }

    /// The bars' days are UTC midnights; Swift Charts bins by the Mac's own days, so each is plotted at the local
    /// midnight of the same calendar day.
    static func plotted(_ day: Date) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return Calendar.current.date(from: utc.dateComponents([.year, .month, .day], from: day)) ?? day
    }

    /// The UTC midnight of the local day `date` falls on: the inverse of `plotted`.
    static func day(of date: Date) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: Calendar.current.dateComponents([.year, .month, .day], from: date)) ?? date
    }
}

private struct ShippedChartDescriptor: AXChartDescriptorRepresentable {
    let shipped: Shipped

    func makeChartDescriptor() -> AXChartDescriptor {
        let labels = shipped.bars.map { Usage.dayLabel($0.date) }
        let peak = shipped.bars.map(\.shipped).max() ?? 0
        let xAxis = AXCategoricalDataAxisDescriptor(title: "Day", categoryOrder: labels)
        let yAxis = AXNumericDataAxisDescriptor(title: "Tickets", range: 0...Double(max(peak, 1)), gridlinePositions: []) { "\(Int($0))" }
        let series = AXDataSeriesDescriptor(
            name: Shipped.chartTitle, isContinuous: false,
            dataPoints: shipped.bars.map { AXDataPoint(x: Usage.dayLabel($0.date), y: Double($0.shipped)) }
        )
        return AXChartDescriptor(
            title: Shipped.chartTitle, summary: shipped.chartSummary, xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: [series]
        )
    }
}

// MARK: - Learnings

struct LearningsView: View {
    let learnings: Learnings
    @Binding var filter: Learnings.Filter
    var openTicket: (String) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }
    var perform: (Learnings.Empty.Action) -> Void = { _ in }

    var body: some View {
        if let empty = learnings.empty {
            VStack(spacing: 0) {
                LearningsFilterBar(learnings: learnings, filter: $filter).padding([.horizontal, .top], DesignTokens.Space.s6)
                EmptyState(title: empty.title, symbol: "lightbulb", actions: [(empty.action.title, { perform(empty.action) })])
            }
        } else {
            ScrollView {
                LearningsCards(learnings: learnings, filter: $filter, openTicket: openTicket, openURL: openURL)
            }
        }
    }
}

/// The repo and tag pop-ups, and how many records show.
private struct LearningsFilterBar: View {
    let learnings: Learnings
    @Binding var filter: Learnings.Filter

    var body: some View {
        HStack(spacing: DesignTokens.Space.s3) {
            Picker("Repo", selection: $filter.repo) {
                Text("All repos").tag(String?.none)
                ForEach(learnings.repos, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Picker("Tag", selection: $filter.tag) {
                Text("All tags").tag(String?.none)
                ForEach(learnings.tags, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Spacer()
            Text("\(learnings.count) \(learnings.count == 1 ? "learning" : "learnings")")
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// The Learnings tab's filters and repos, outside the scroll view so they also render offscreen.
struct LearningsCards: View {
    let learnings: Learnings
    @Binding var filter: Learnings.Filter
    var openTicket: (String) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            LearningsFilterBar(learnings: learnings, filter: $filter)
            ForEach(learnings.groups) { group in
                Card(title: group.repoKey) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Divider() }
                            LearningRowView(row: row, openTicket: openTicket, openURL: openURL)
                                .padding(.vertical, DesignTokens.Space.s2)
                        }
                    }
                }
            }
        }
        .padding(DesignTokens.Space.s6)
    }
}

/// A learning: its rule, its evidence and tags, and links to its ticket and PR.
private struct LearningRowView: View {
    let row: Learnings.Row
    var openTicket: (String) -> Void
    var openURL: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                Text(row.context)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                Spacer(minLength: DesignTokens.Space.s2)
                if let identifier = row.record.issueIdentifier {
                    LinkButton(title: "Open \(identifier)") { openTicket(identifier) }
                        .help("Open the ticket page of \(identifier)")
                }
                if let url = row.record.prURL, let title = row.record.prTitle {
                    LinkButton(title: title) { openURL(url) }
                        .help("Open \(title) on GitHub")
                        .accessibilityLabel("Open \(title) on GitHub")
                }
            }
            Text(row.record.rule)
                .font(DesignTokens.TypeStyle.body.font)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let evidence = row.record.evidence, !evidence.isEmpty {
                Text("“\(evidence)”")
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !row.record.tags.isEmpty {
                HStack(spacing: DesignTokens.Space.s1) {
                    ForEach(row.record.tags, id: \.self) { tag in
                        Text(tag)
                            .font(DesignTokens.TypeStyle.caption.font)
                            .padding(.horizontal, DesignTokens.Space.s2)
                            .padding(.vertical, 2)
                            .background(DesignTokens.Surface.separator.color.opacity(0.5), in: Capsule())
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Tags: \(row.record.tags.joined(separator: ", "))")
            }
        }
    }
}
