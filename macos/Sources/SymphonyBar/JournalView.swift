import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

// MARK: - The window model's Journal (TP-1459)

extension SymphonyWindowModel {
    /// The Journal as it draws, from the pages read under its query, with the reports pinned among them (TP-1462).
    var journalModel: JournalModel {
        JournalModel.build(
            journalFeed, reports: journalReportCards, reportsOnly: journalQuery.reportsOnly, reference: Date(), calendar: .current
        )
    }

    /// The reports' cards, their citations resolved through the Journal's pages and the periods read for them.
    var journalReportCards: [JournalReportCard] {
        var citations = journalCitations
        citations.take(journalFeed.events)
        return journalReports.compactMap { JournalReportCard.build($0, citations: citations, calendar: .current) }
    }

    /// The open Question of a report's card, answered there with the Inbox's own picks and consequence sheet: the Inbox
    /// item that asks it, until the Director answers it.
    func reportQuestion(_ card: JournalReportCard) -> JournalReportQuestion? {
        guard let questionID = card.questionID,
              let item = inbox?.items.first(where: { $0.isDecision && $0.review.action?.questionID == questionID }),
              let action = item.review.action, !answered(item.id)
        else { return nil }
        return JournalReportQuestion(
            itemID: item.id, action: action, picks: picks(for: item.id), answerable: true,
            pick: { [weak self] in self?.pick($0, decision: 0, itemID: item.id) },
            writeIn: { [weak self] in self?.writeIn($0, decision: 0, itemID: item.id) },
            send: { [weak self] in self?.open(.decide, on: item) }
        )
    }

    /// The open Questions of the reports' cards, by report.
    var journalReportQuestions: [String: JournalReportQuestion] {
        Dictionary(journalReportCards.compactMap { card in reportQuestion(card).map { (card.id, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    /// A citation: its ticket's page, at the event it names.
    func openCitation(_ focus: TimelineFocus) {
        ticketFocus = focus
        openTicket(focus.identifier)
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
            let current = query.readsAsTheSame(journalQuery) && scope == self.scope
            if current { takeJournal(result) { $0.takeNewest($1) } }
            journalReadAt = current ? Date() : nil
            readingJournal = false
            if !current { readJournalIfDue() }
            readJournalReports()
        }
    }

    /// Reads the reports published since the oldest event the pages hold (every one once the oldest page is in), then
    /// the period of each report whose citations the pages don't hold, once per report. Symphony answers from its own
    /// store.
    func readJournalReports() {
        guard !readingReports else { return }
        readingReports = true
        let since = journalFeed.canShowEarlier ? journalFeed.events.last?.event.at : nil
        Task {
            if case let .loaded(data) = await client.get(JournalReportsPayload.path(since: since)),
               let payload = JournalReportsPayload.decode(data) {
                journalReports = payload.reports
            }
            var citations = journalCitations
            citations.take(journalFeed.events)
            for report in journalReports where !journalPeriodsRead.contains(report.id) && !citations.resolves(report) {
                guard let path = report.periodEventsPath else { continue }
                journalPeriodsRead.insert(report.id)
                if case let .loaded(data) = await client.get(path), let page = JournalPayload.decode(data) {
                    journalCitations.take(page.events)
                }
            }
            readingReports = false
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
            if query.readsAsTheSame(journalQuery), scope == self.scope, until == journalFeed.nextUntil {
                takeJournal(result) { $0.takeEarlier($1) }
            }
            journalReadingEarlier = false
            // The reports of the earlier page's time.
            readJournalReports()
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
            VStack(spacing: 0) {
                JournalView(
                    model: model.journalModel, query: $model.journalQuery, values: model.journalFilterValues,
                    readingEarlier: model.journalReadingEarlier, questions: model.journalReportQuestions,
                    sending: model.holdsAnswer || model.inboxMoveInFlight, open: model.openJournalRow,
                    showEarlier: model.showEarlierJournal, openCitation: model.openCitation, openMention: model.openMentionDirectly
                )
                // The banner of an answer sent from a report's card, with its Undo.
                if let banner = model.inboxBanner {
                    InboxBannerView(banner: banner, undo: { model.undo(banner) }, close: model.dismissBanner)
                        .padding(DesignTokens.Space.s3)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.default, value: model.inboxBanner)
            // C17: Send on a report's Question asks first, with the Inbox's own consequence sheet.
            .modifier(InboxSheetPresenter(model: model))
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
    /// The reports' open Questions, by report.
    var questions: [String: JournalReportQuestion] = [:]
    /// An answer is held for Undo or on its way: Send waits.
    var sending = false
    var open: (JournalRow) -> Void = { _ in }
    var showEarlier: () -> Void = {}
    var openCitation: (TimelineFocus) -> Void = { _ in }
    var openMention: (Mention) -> Void = { _ in }
    /// Snapshots draw the list unscrolled, its whole height.
    var scrolls = true
    var calendar: Calendar = .current
    /// The events the citation under the pointer names: their rows are lit.
    @State private var highlighted: Set<String> = []
    /// The row a citation with no ticket page showed: lit for `revealedFor`, after the list scrolled to it.
    @State private var revealed: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long the row a citation showed stays lit.
    static let revealedFor: Duration = .seconds(2)

    var body: some View {
        VStack(spacing: 0) {
            JournalFilterBar(query: $query, values: values)
            Divider()
            if model.isEmpty {
                EmptyState(title: JournalModel.emptyTitle(query), symbol: Destination.journal.symbol)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if scrolls {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        list { id in
                            withAnimation(reduceMotion ? nil : .standard) { proxy.scrollTo(JournalSection<EmptyView>.rowID(id), anchor: .center) }
                        }
                    }
                }
            } else {
                list { _ in }
            }
        }
    }

    /// The list; `scrollTo` brings an event's row into view.
    private func list(scrollTo: @escaping (String) -> Void) -> some View {
        JournalSection(
            model: model, calendar: calendar, readingEarlier: readingEarlier, highlighted: highlighted.union(revealed.map { [$0] } ?? []),
            open: open, showEarlier: showEarlier
        ) { card in
            JournalReportCardView(
                card: card, question: questions[card.id], sending: sending, clock: TimelineModel.clock(calendar), open: openCitation,
                show: { id in reveal(id, scrollTo: scrollTo) }, hover: { highlighted = $0 }, openMention: openMention
            )
        }
        .padding(.horizontal, DesignTokens.Space.s5)
        .padding(.bottom, DesignTokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// A citation with no ticket page (an event on Symphony's own stream): the list scrolls to the event's row, which
    /// stays lit for a moment, whether or not the pointer is still on the citation.
    private func reveal(_ id: String, scrollTo: (String) -> Void) {
        revealed = id
        scrollTo(id)
        Task { @MainActor in
            try? await Task.sleep(for: Self.revealedFor)
            if revealed == id { revealed = nil }
        }
    }
}

/// The filter bar: the Repo, Epic and Class chips, each a menu, and the Reports only and Everything switches, in one bar
/// that wraps.
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
            filterSwitch(JournalQuery.reportsOnlyTitle, isOn: $query.reportsOnly)
                .font(DesignTokens.TypeStyle.secondary.font)
                .fixedSize()
                .frame(height: DesignTokens.Control.small.height)
                .help(JournalQuery.reportsOnlyHelp)
            filterSwitch(JournalFilter.everything.title, isOn: $query.everything)
                .font(DesignTokens.TypeStyle.secondary.font)
                .fixedSize()
                .frame(height: DesignTokens.Control.small.height)
                .help(Self.everythingHelp)
        }
        .padding(.horizontal, DesignTokens.Space.s4)
        .padding(.vertical, DesignTokens.Space.s2)
    }

    static let everythingHelp = "Show every event, not only the notable ones"

    /// A switch of the bar (Reports only, Everything); offscreen, where the AppKit switch can't draw, its face.
    @ViewBuilder private func filterSwitch(_ title: String, isOn: Binding<Bool>) -> some View {
        if offscreenSnapshot {
            HStack(spacing: DesignTokens.Space.s2) {
                Text(title)
                Capsule()
                    .fill(isOn.wrappedValue ? DesignTokens.ColorToken.accent.color : DesignTokens.Surface.separator.color)
                    .frame(width: 26, height: 15)
                    .overlay(alignment: isOn.wrappedValue ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 13, height: 13).padding(1)
                    }
            }
        } else {
            Toggle(title, isOn: isOn)
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

// MARK: - A report's card (TP-1462)

/// A report's open Question as its card asks it: the Inbox item's request, answered with the Inbox's picks, and Send,
/// which opens the Inbox's consequence sheet and sends through the same `decide`.
struct JournalReportQuestion {
    /// The Inbox item that asks it.
    var itemID: String
    var action: InboxReview.Action
    var picks = DecisionPicks()
    var answerable = true
    var pick: (Int) -> Void = { _ in }
    var writeIn: (String) -> Void = { _ in }
    var send: () -> Void = {}
}

/// A report in the Journal: its time in the column of times, then a card with the period, the model that wrote it, the
/// report's sentences as one paragraph whose cited sentences are links, the tickets it rests on, and its Question while
/// it is open. A link opens the ticket page at the event its sentence cites; the pointer on it, or on a ticket's chip,
/// lights the rows of the events it names.
struct JournalReportCardView: View {
    let card: JournalReportCard
    var question: JournalReportQuestion?
    /// An answer is held for Undo or on its way: Send waits.
    var sending = false
    let clock: (Date) -> String
    var open: (TimelineFocus) -> Void = { _ in }
    /// Shows an event's row in the Journal: a citation of an event no ticket page holds.
    var show: (String) -> Void = { _ in }
    var hover: (Set<String>) -> Void = { _ in }
    var openMention: (Mention) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let symbol = "doc.text"
    static let restsOn = "Rests on"

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous) }

    /// Each cited sentence that resolves, as a link of the paragraph named by its index.
    private var links: [ChipTextLink] {
        card.sentences.filter(\.linked).map { ChipTextLink(range: $0.range, id: String($0.index)) }
    }

    /// A cited sentence's link: its ticket's page at the event, or the event's row in the Journal.
    private func follow(_ sentence: JournalReportCard.Sentence) {
        if let focus = sentence.focus {
            open(focus)
        } else if let row = sentence.row {
            show(row)
        }
    }

    private func sentence(_ link: ChipTextLink?) -> JournalReportCard.Sentence? {
        link.flatMap { link in card.sentences.first { String($0.index) == link.id } }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            Text(clock(card.at))
                .font(DesignTokens.TypeStyle.secondary.font)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: JournalSection<EmptyView>.timeColumn, alignment: .trailing)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                header
                ChipText(text: card.text, links: links)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.mentionReferences, card.references)
                    .environment(\.openMention, OpenMentionAction(handler: openMention))
                    .environment(\.openMentionDirectly, OpenMentionAction(handler: openMention))
                    .environment(\.openTextLink, TextLinkAction { link in
                        if let sentence = sentence(link) { follow(sentence) }
                    })
                    .environment(\.hoverTextLink, TextLinkHoverAction { link in hover(Set(sentence(link)?.events ?? [])) })
                if !card.tickets.isEmpty {
                    tickets
                }
                if let question {
                    QuestionBlock(
                        action: question.action, picks: question.picks, pick: question.pick, writeIn: question.writeIn,
                        answerable: question.answerable && !sending, showsKeys: false, send: question.send
                    )
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .leading))
                    ))
                }
            }
            .padding(DesignTokens.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.Surface.content.color, in: shape)
            .overlay(shape.strokeBorder(DesignTokens.Surface.separator.color))
            // The Question leaves with the Inbox's motion once it is answered.
            .animation(reduceMotion ? nil : .standard, value: question?.itemID)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.accessibilityLabel)
        .accessibilityActions {
            ForEach(card.sentences.filter(\.linked)) { sentence in
                if let label = sentence.linkLabel {
                    Button(label) { follow(sentence) }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            Image(systemName: Self.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DesignTokens.ColorToken.accent.color)
                .accessibilityHidden(true)
            Text(JournalReportCard.kicker)
                .font(DesignTokens.TypeStyle.rowTitle.font)
            Text(card.period)
                .font(DesignTokens.TypeStyle.secondary.font)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: DesignTokens.Space.s2)
            if let model = card.modelLine {
                Text(model)
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("The model that wrote this report")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The tickets the report rests on, each a chip that opens its page at the first event it cites there.
    private var tickets: some View {
        WrappingStack(spacing: DesignTokens.Space.s2) {
            Text(Self.restsOn)
                .font(DesignTokens.TypeStyle.secondary.font)
                .foregroundStyle(.secondary)
            ForEach(card.tickets, id: \.identifier) { focus in
                Button { open(focus) } label: {
                    Text(focus.identifier)
                        .font(DesignTokens.TypeStyle.secondary.font)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(DesignTokens.ColorToken.accent.color)
                        .padding(.horizontal, DesignTokens.Space.s2)
                        .padding(.vertical, 1)
                        .background(DesignTokens.Surface.separator.color.opacity(0.5), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Open \(focus.identifier) at the event this report cites")
                .accessibilityLabel("Open \(focus.identifier) at the event this report cites")
                .onHover { inside in hover(inside ? Set(card.events(of: focus.identifier)) : []) }
            }
        }
    }
}
