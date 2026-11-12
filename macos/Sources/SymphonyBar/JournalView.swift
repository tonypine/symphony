import SwiftUI
import SymphonyBarCore

// MARK: - The window model's Journal (TP-1459)

extension SymphonyWindowModel {
    /// The Journal as it draws, from the pages read under its query.
    var journalModel: JournalModel {
        JournalModel.build(journalFeed, reference: Date(), calendar: .current)
    }

    /// The values the Repo and Epic chips offer: the repos Symphony has tickets in and the epics it lists, with the
    /// one picked.
    var journalFilterValues: JournalFilterValues {
        JournalFilterValues(
            repos: overviewState?.repos ?? [], epics: initiatives?.initiatives.map(\.identifier) ?? [], query: journalQuery
        )
    }

    /// The query or the scope changed: the pages read go, and the newest page is read for them.
    func restartJournal() {
        journalFeed = JournalFeed()
        journalResult = nil
        journalReadAt = nil
        readJournalIfDue()
    }

    /// Reads the newest page while the Journal shows, at most every `ticketSlowInterval` after a state poll; the
    /// earlier pages Show Earlier read stay. Symphony answers from its own store, with no Linear request.
    func readJournalIfDue() {
        guard selection == .journal, !showsPage, !readingJournal, state.countsKnown,
              journalReadAt.map({ Date().timeIntervalSince($0) >= Self.ticketSlowInterval }) ?? true
        else { return }
        readingJournal = true
        let query = journalQuery
        let scope = scope
        Task {
            let result = await client.get(query.path(scope: scope))
            // The filters changed while the read was out: read again for them instead.
            let current = query == journalQuery && scope == self.scope
            if current { takeJournal(result) { $0.takeNewest($1) } }
            journalReadAt = current ? Date() : nil
            readingJournal = false
            if !current { readJournalIfDue() }
        }
    }

    /// Show Earlier: the page before the oldest one read.
    func showEarlierJournal() {
        guard let until = journalFeed.nextUntil, !journalReadingEarlier else { return }
        journalReadingEarlier = true
        let query = journalQuery
        let scope = scope
        Task {
            let result = await client.get(query.path(scope: scope, until: until))
            if query == journalQuery, scope == self.scope, until == journalFeed.nextUntil {
                takeJournal(result) { $0.takeEarlier($1) }
            }
            journalReadingEarlier = false
        }
    }

    /// A row: its ticket's page, at its event.
    func openJournalRow(_ row: JournalRow) {
        guard let focus = row.focus else { return }
        ticketFocus = focus
        openTicket(focus.identifier)
    }

    private func takeJournal(_ result: EndpointResult, into take: (inout JournalFeed, JournalPayload) -> Void) {
        guard case let .loaded(data) = result else {
            journalResult = result
            return
        }
        guard let page = JournalPayload.decode(data) else {
            journalResult = .failed(JournalFilterValues.unreadable)
            return
        }
        take(&journalFeed, page)
        journalResult = nil
    }
}

/// The values the filter bar's Repo and Epic menus offer.
struct JournalFilterValues: Equatable {
    var repos: [String] = []
    var epics: [String] = []

    init(repos: [String] = [], epics: [String] = [], query: JournalQuery = JournalQuery()) {
        self.repos = Self.with(repos, query.repo)
        self.epics = Self.with(epics, query.epic)
    }

    static let unreadable = "Symphony sent events that couldn't be read"

    /// `values` once each, sorted, with `picked` among them.
    private static func with(_ values: [String], _ picked: String?) -> [String] {
        Array(Set(values + [picked].compactMap { $0 })).sorted()
    }
}

/// The Journal destination: the filter bar over the list, or why there is no list.
struct JournalContent: View {
    @ObservedObject var model: SymphonyWindowModel

    var body: some View {
        if model.journalFeed.loaded {
            JournalView(
                model: model.journalModel, query: $model.journalQuery, values: model.journalFilterValues,
                readingEarlier: model.journalReadingEarlier, open: model.openJournalRow, showEarlier: model.showEarlierJournal
            )
        } else if model.journalResult == .unsupported {
            EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
        } else if case let .failed(message)? = model.journalResult {
            EmptyState(title: "Couldn't read the Journal: \(message)", symbol: DesignTokens.Status.problem.symbol)
        } else {
            EmptyState(title: "Reading the Journal…", symbol: Destination.journal.symbol, showsSpinner: true)
        }
    }
}

/// The filter bar over the Journal's list, which scrolls under it.
struct JournalView: View {
    let model: JournalModel
    @Binding var query: JournalQuery
    var values = JournalFilterValues()
    var readingEarlier = false
    var open: (JournalRow) -> Void = { _ in }
    var showEarlier: () -> Void = {}
    /// Snapshots draw the list unscrolled, its whole height.
    var scrolls = true
    var calendar: Calendar = .current

    var body: some View {
        VStack(spacing: 0) {
            JournalFilterBar(query: $query, values: values)
            Divider()
            if model.isEmpty {
                EmptyState(title: JournalModel.emptyTitle(query), symbol: Destination.journal.symbol)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if scrolls {
                ScrollView(.vertical) { list }
            } else {
                list
            }
        }
    }

    private var list: some View {
        JournalSection(model: model, calendar: calendar, readingEarlier: readingEarlier, open: open, showEarlier: showEarlier)
            .padding(.horizontal, DesignTokens.Space.s5)
            .padding(.bottom, DesignTokens.Space.s5)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// The filter bar: the Repo, Epic and Class chips, each a menu, and the Everything switch, in one bar that wraps.
struct JournalFilterBar: View {
    @Binding var query: JournalQuery
    let values: JournalFilterValues
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Space.s2) {
            WrappingStack(spacing: DesignTokens.Space.s2) {
                chip(.repo) {
                    Button(OverviewScope.allTitle) { query.repo = nil }
                    Divider()
                    ForEach(values.repos, id: \.self) { repo in
                        Toggle(repo, isOn: Binding(get: { query.repo == repo }, set: { query.repo = $0 ? repo : nil }))
                    }
                }
                chip(.epic) {
                    Button(JournalQuery.allEpics) { query.epic = nil }
                    Divider()
                    ForEach(values.epics, id: \.self) { epic in
                        Toggle(epic, isOn: Binding(get: { query.epic == epic }, set: { query.epic = $0 ? epic : nil }))
                    }
                }
                chip(.classes) {
                    Button(JournalQuery.allClasses) { query.classes = [] }
                    Divider()
                    ForEach(JournalClass.allCases) { value in
                        Toggle(value.title, isOn: Binding(get: { query.classes.contains(value) }, set: { _ in query.toggle(value) }))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            everything
                .font(DesignTokens.TypeStyle.callout.font)
                .fixedSize()
                .frame(height: DesignTokens.Control.small.height)
                .help(Self.everythingHelp)
        }
        .padding(.horizontal, DesignTokens.Space.s4)
        .padding(.vertical, DesignTokens.Space.s2)
    }

    static let everythingHelp = "Show every event, not only the notable ones"

    /// The Everything switch; offscreen, where the AppKit switch can't draw, its face.
    @ViewBuilder private var everything: some View {
        if offscreenSnapshot {
            HStack(spacing: DesignTokens.Space.s2) {
                Text(JournalFilter.everything.title)
                Capsule()
                    .fill(query.everything ? DesignTokens.SystemColor.accent.color : DesignTokens.Surface.separator.color)
                    .frame(width: 26, height: 15)
                    .overlay(alignment: query.everything ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 13, height: 13).padding(1)
                    }
            }
        } else {
            Toggle(JournalFilter.everything.title, isOn: $query.everything)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func chip<Items: View>(_ filter: JournalFilter, @ViewBuilder items: () -> Items) -> some View {
        TicketsBarMenu(
            title: query.chipText(filter) ?? filter.title, help: "Change the \(filter.title) filter",
            kind: query.isSet(filter) ? .secondary : .quiet, items: items
        )
    }
}
