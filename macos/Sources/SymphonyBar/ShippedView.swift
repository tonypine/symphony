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

    /// Reads the merged tickets of the Insights slice's days, for their titles and PRs, and every learning while
    /// Shipped shows. Symphony answers both from its own records, with no Linear request.
    func readShippedIfDue() {
        guard selection == .shipped, !showsPage, !readingShipped, state.countsKnown,
            shippedReadAt.map({ Date().timeIntervalSince($0) >= Self.historyInterval }) ?? true
        else { return }
        readingShipped = true
        let days = insightsSlice.daysBack(today: insightsToday)
        Task {
            let result = await client.get(ShippedPayload.path(days: days))
            if days == insightsSlice.daysBack(today: insightsToday) {
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
            shippedReadAt = days == insightsSlice.daysBack(today: insightsToday) ? Date() : nil
            readingShipped = false
            if shippedReadAt == nil { readShippedIfDue() }
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

    private var shippedTab: some View {
        InsightsPage(model: model, symbol: SymphonyView.shipped.symbol) { aggregate in
            ShippedView(
                shipped: Shipped(aggregate: aggregate, slice: model.insightsSlice, details: model.shipped, today: model.insightsToday),
                openTicket: model.openTicket,
                openURL: model.onOpenURL,
                widen: { model.insightsSlice.choose($0, today: model.insightsToday) }
            )
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
    var openTicket: (String) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }
    var widen: (InsightsPeriod) -> Void = { _ in }

    var body: some View {
        if let empty = shipped.empty {
            InsightsEmptyState(empty: empty, symbol: SymphonyView.shipped.symbol, widen: widen)
        } else {
            ScrollView {
                ShippedCards(shipped: shipped, openTicket: openTicket, openURL: openURL)
            }
        }
    }
}

/// Shipped's sentence, chart and buckets, outside the scroll view so they also render offscreen.
struct ShippedCards: View {
    let shipped: Shipped
    var openTicket: (String) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
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
            Card(title: shipped.chart.title) {
                InsightsBarChart(chart: shipped.chart, caption: shipped.caption, height: 180)
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
