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

    var body: some View {
        Group {
            switch model.shippedTab {
            case .shipped:
                shippedTab
            case .learnings:
                learningsTab
            }
        }
    }

    private var shippedTab: some View {
        InsightsPage(model: model, symbol: SymphonyView.shipped.symbol, shippedTab: $model.shippedTab) { aggregate in
            ShippedView(
                shipped: Shipped(aggregate: aggregate, slice: model.insightsSlice, details: model.shipped, today: model.insightsToday),
                openTicket: model.openTicket,
                openURL: model.onOpenURL,
                widen: { model.insightsSlice.choose($0, today: model.insightsToday) }
            )
        }
    }

    /// The Learnings tab under its control bar, which stays at the top while the learnings read, so the switch back to
    /// Shipped is always there.
    private var learningsTab: some View {
        let learnings = model.learnings.map { Learnings(payload: $0, filter: model.learningsFilter, scope: model.scope) }
        return PinnedBarPage {
            LearningsControlBar(
                learnings: learnings, filter: $model.learningsFilter, tab: $model.shippedTab,
                controls: LearningsBarControls(page: model.pageBar, search: $model.learningsFilter.search, searchRequested: $model.learningsSearchRequested)
            )
        } content: {
            if let learnings {
                LearningsView(learnings: learnings, openTicket: model.openTicket, openURL: model.onOpenURL, perform: model.perform)
            } else if model.learningsResult == .unsupported {
                EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
            } else {
                EmptyState(title: "Reading the crew's learnings…", symbol: "lightbulb", showsSpinner: true)
            }
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
    /// The row a click selected.
    @State var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                Text(shipped.sentence)
                    .font(DesignTokens.TypeStyle.sentence.font)
                    .accessibilityAddTraits(.isHeader)
                if !shipped.context.isEmpty {
                    Text(shipped.context)
                        .font(DesignTokens.TypeStyle.secondary.font)
                        .foregroundStyle(.secondary)
                }
            }
            Card(title: shipped.chart.title) {
                InsightsBarChart(chart: shipped.chart, caption: shipped.caption, height: 180)
            }
            ForEach(shipped.groups) { group in
                Card(title: group.title) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(group.rows) { row in
                            ShippedRowView(
                                row: row, selected: selected == row.id, select: { selected = row.id },
                                open: { openTicket(row.identifier) }, openURL: openURL
                            )
                        }
                    }
                }
            }
        }
        .padding(DesignTokens.Space.s6)
    }
}

/// A merged ticket (C49): its identifier and title, its repo, initiative and PR under them, its PR's button, and its
/// time from Todo to Done in the value column, so the times line up.
private struct ShippedRowView: View {
    let row: Shipped.Row
    let selected: Bool
    let select: () -> Void
    let open: () -> Void
    var openURL: (URL) -> Void

    var body: some View {
        Row(
            row.title, identifier: row.identifier, lead: .status(.done), line2: row.detail.isEmpty ? nil : row.detail,
            value: row.leadTime, valueWidth: DesignTokens.Row.wideValueWidth, selected: selected, select: select, open: open
        ) {
            if let url = row.prURL, let title = row.prTitle {
                Button(title) { openURL(url) }
                    .directorButton(.quiet, size: .small)
                    .help("Open \(title) on GitHub")
                    .accessibilityLabel("Open \(title) on GitHub")
            }
        }
        .accessibilityLabel(row.accessibilityLabel)
    }
}

// MARK: - Learnings

/// The Learnings tab's page under its control bar: the learnings by repo, or why none shows with the way out.
struct LearningsView: View {
    let learnings: Learnings
    var openTicket: (String) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }
    var perform: (Learnings.Empty.Action) -> Void = { _ in }

    var body: some View {
        if let empty = learnings.empty {
            EmptyState(title: empty.title, symbol: "lightbulb", actions: [(empty.action.title, { perform(empty.action) })])
        } else {
            ScrollView {
                LearningsCards(learnings: learnings, openTicket: openTicket, openURL: openURL)
            }
        }
    }
}

/// The window's part of the Learnings tab's control bar (TP-1497): the scope and the search.
struct LearningsBarControls {
    var page = PageBar()
    var search: Binding<String> = .constant("")
    /// Set by ⌘F on Shipped to put the keyboard in the search.
    var searchRequested: Binding<Bool> = .constant(false)
}

/// The Learnings tab's control bar: the Shipped and Learnings switch, the scope, the search and the repo and tag
/// pop-ups at the left; how many learnings show at the right. While the learnings read, only the switch, the scope and
/// the search.
struct LearningsControlBar: View {
    let learnings: Learnings?
    @Binding var filter: Learnings.Filter
    @Binding var tab: Shipped.Tab
    var controls = LearningsBarControls()

    var body: some View {
        ControlBar("Learnings controls") {
            ShippedTabSwitch(tab: $tab)
            controls.page.scopePopUp
            PageSearchField(prompt: Learnings.searchPrompt, text: controls.search, matches: learnings?.count, requested: controls.searchRequested)
            if let learnings {
                PopUp("Repo", selection: $filter.repo, choices: popUpChoices(all: "All repos", learnings.repos), size: .small)
                PopUp("Tag", selection: $filter.tag, choices: popUpChoices(all: "All tags", learnings.tags), size: .small)
            }
        } act: {
            if let learnings {
                Text("\(learnings.count) \(learnings.count == 1 ? "learning" : "learnings")")
                    .textStyle(.secondary)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .monospacedDigit()
            }
        }
    }
}

/// The Learnings tab's repos, outside the scroll view so they also render offscreen.
struct LearningsCards: View {
    let learnings: Learnings
    var openTicket: (String) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }
    /// The row a click selected.
    @State var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            ForEach(learnings.groups) { group in
                Card(title: group.repoKey) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(group.rows) { row in
                            LearningRowView(
                                row: row, selected: selected == row.id, select: { selected = row.id }, openTicket: openTicket,
                                openURL: openURL
                            )
                        }
                    }
                }
            }
        }
        .padding(DesignTokens.Space.s6)
    }
}

/// A learning (C49): its rule on the first line, where it came from and its evidence on the second, its tags and links
/// at the end; the whole rule and evidence are its help text. A double click opens its ticket.
private struct LearningRowView: View {
    let row: Learnings.Row
    let selected: Bool
    let select: () -> Void
    var openTicket: (String) -> Void
    var openURL: (URL) -> Void

    var body: some View {
        let identifier = row.record.issueIdentifier
        Row(
            row.record.rule, lead: .glyph("lightbulb", DesignTokens.TextColor.secondary), line2: line2, selected: selected,
            select: select, open: identifier.map { identifier in { openTicket(identifier) } }
        ) {
            ForEach(row.record.tags, id: \.self) { Chip($0) }
            if let identifier {
                Button("Open \(identifier)") { openTicket(identifier) }
                    .directorButton(.quiet, size: .small)
                    .help("Open the ticket page of \(identifier)")
            }
            if let url = row.record.prURL, let title = row.record.prTitle {
                Button(title) { openURL(url) }
                    .directorButton(.quiet, size: .small)
                    .help("Open \(title) on GitHub")
                    .accessibilityLabel("Open \(title) on GitHub")
            }
        }
        .help(help)
    }

    /// "BIL-204 · today · “The evidence”".
    private var line2: String {
        ([row.context] + [row.record.evidence].compactMap { $0 }.filter { !$0.isEmpty }.map { "“\($0)”" }).joined(separator: " · ")
    }

    /// The rule whole, then its evidence.
    private var help: String {
        [row.record.rule, row.record.evidence].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
