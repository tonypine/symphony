import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// D5: Initiatives, from `/api/v1/initiatives`, under the window's scope.
struct InitiativesContent: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient

    var body: some View {
        if let list = model.initiativesList {
            InitiativesView(
                list: list,
                selection: $model.initiativeSelection,
                story: model.initiativeStory,
                runs: model.initiativeRuns,
                actions: InitiativeActions(
                    inbox: Set(model.inbox?.items.filter(\.waitsOnDirector).map(\.id) ?? []),
                    review: { model.showInbox(selecting: $0) },
                    openTicket: model.openTicket,
                    openURL: model.onOpenURL
                ),
                reference: model.overviewState?.generatedAt ?? Date()
            )
        } else if case .unsupported? = model.initiativesResult {
            EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
        } else {
            EmptyState(title: "Reading the initiatives…", symbol: SymphonyView.initiatives.symbol, showsSpinner: true)
        }
    }
}

extension SymphonyWindowModel {
    /// The selected epic's story is read again at most this often: one ticket read per open sub-ticket.
    static let initiativeStoryInterval: TimeInterval = 30

    /// `initiative`'s story from what the window holds: its records, its sub-tickets' ticket reads and the dispatch order.
    func initiativeStory(_ initiative: Initiative) -> InitiativeStory {
        InitiativeStory(
            initiative: initiative, records: initiativeRecords[initiative.identifier] ?? [], connected: initiativeConnected,
            order: overviewState?.order, reference: overviewState?.generatedAt ?? Date()
        )
    }

    /// Reads the selected epic's records, each open sub-ticket's ticket read, and the runs of the ones being worked on
    /// while Initiatives shows: at once on a new selection, and at most every `initiativeStoryInterval` after a state
    /// poll.
    func readInitiativeStoryIfDue() {
        guard selection == .initiatives, !showsPage, state.countsKnown, !readingInitiativeStory,
              let initiative = initiativesList?.selection(initiativeSelection)
        else { return }
        let epic = initiative.identifier
        guard initiativeStoryReadAt[epic].map({ Date().timeIntervalSince($0) >= Self.initiativeStoryInterval }) ?? true else { return }
        readingInitiativeStory = true
        let reads = InitiativeStory.readsNeeded(initiative)
        Task {
            if case let .loaded(data) = await client.get(InitiativeStory.recordsPath(epic)), let payload = TicketsPayload.decode(data) {
                initiativeRecords[epic] = payload.rows
            }
            var connected: [String: TicketConnected] = [:]
            for identifier in reads {
                if case let .loaded(data) = await client.get(TicketPage.issuePath(identifier)),
                   let read = TicketFactsRead.decode(data)?.connected {
                    connected[identifier] = read
                }
            }
            initiativeConnected.merge(connected) { _, new in new }
            await readInitiativeRuns(initiative)
            initiativeStoryReadAt[epic] = Date()
            readingInitiativeStory = false
        }
    }

    /// The run working on each sub-ticket of `initiative` being worked on, for its step bars: each one's events feed,
    /// paged forward from where the last read stopped.
    private func readInitiativeRuns(_ initiative: Initiative) async {
        guard let repoKey = initiative.repoKey else { return }
        let reference = overviewState?.generatedAt ?? Date()
        for row in initiativeStory(initiative).currents {
            var history = initiativeHistories[row.identifier] ?? TicketEventsPayload()
            for _ in 0 ..< TicketEventsReader.maxPages {
                let path = TicketPage.eventsPath(row.identifier, repoKey: repoKey, since: history.nextSince, limit: TicketEventsReader.pageLimit)
                guard case let .loaded(data) = await client.get(path), let page = TicketEventsPayload.decode(data) else { break }
                if history.merge(page) == 0 || page.events.count < TicketEventsReader.pageLimit { break }
            }
            initiativeHistories[row.identifier] = history
            let run = RunGroupModel.groups(history, reference: reference).last { $0.isLive }
            if initiativeRuns[row.identifier] != run { initiativeRuns[row.identifier] = run }
        }
    }
}

struct InitiativeActions {
    /// The issue ids the Inbox lists; Review is offered only on these.
    var inbox: Set<String> = []
    /// Review on a sub-ticket that waits on the Director opens its Inbox item, by issue id.
    var review: (String) -> Void = { _ in }
    /// A row opens the ticket's page, by identifier.
    var openTicket: (String) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }
}

/// Work › Initiatives (TP-1500, `docs/design/director-window-and-home.md` § Work: Initiatives) in a scroll view, laid
/// out for the width it gets.
struct InitiativesView: View {
    let list: InitiativesList
    @Binding var selection: String?
    /// The selected initiative's story; without one, the story the initiative alone tells.
    var story: (Initiative) -> InitiativeStory = { InitiativeStory(initiative: $0) }
    /// The run working on each sub-ticket being worked on, by identifier.
    var runs: [String: RunGroupModel] = [:]
    let actions: InitiativeActions
    /// Symphony's clock, so the ages and days read as on every other page.
    var reference = Date()

    var body: some View {
        if list.isEmpty {
            EmptyState(title: InitiativesList.emptyTitle, symbol: SymphonyView.initiatives.symbol)
        } else {
            GeometryReader { proxy in
                ScrollView {
                    InitiativesBody(
                        list: list, selection: $selection, story: story, runs: runs, actions: actions, reference: reference,
                        width: proxy.size.width
                    )
                }
            }
        }
    }
}

/// The page outside its scroll view, so it also renders offscreen: the epics at the left, 340 pt (400 pt from 1600 pt),
/// and the picked epic's story at the right; from 1600 pt the two are centred and the story stops at 1040 pt. Up and
/// Down move through the epics; Tab goes on into the story.
struct InitiativesBody: View {
    let list: InitiativesList
    @Binding var selection: String?
    var story: (Initiative) -> InitiativeStory = { InitiativeStory(initiative: $0) }
    var runs: [String: RunGroupModel] = [:]
    let actions: InitiativeActions
    var reference = Date()
    let width: Double
    /// Whether the story's fold starts open, and whether the window is in front, for a snapshot.
    var unfolded = false
    var windowActive: Bool?

    @FocusState private var listFocused: Bool

    init(
        list: InitiativesList, selection: Binding<String?>, story: @escaping (Initiative) -> InitiativeStory = { InitiativeStory(initiative: $0) },
        runs: [String: RunGroupModel] = [:], actions: InitiativeActions, reference: Date = Date(), width: Double, unfolded: Bool = false,
        windowActive: Bool? = nil
    ) {
        self.list = list
        _selection = selection
        self.story = story
        self.runs = runs
        self.actions = actions
        self.reference = reference
        self.width = width
        self.unfolded = unfolded
        self.windowActive = windowActive
    }

    private var wide: Bool { width >= DesignTokens.Initiatives.wideFrom }

    var body: some View {
        let picked = list.selection(selection)
        HStack(alignment: .top, spacing: DesignTokens.Initiatives.columnGap) {
            epics(picked: picked?.id)
                .frame(width: wide ? DesignTokens.Initiatives.wideListWidth : DesignTokens.Initiatives.listWidth)
            if let picked {
                InitiativeStoryView(
                    initiative: picked, story: story(picked), runs: runs, actions: actions, reference: reference, unfolded: unfolded
                )
                .id(picked.id)
                .frame(maxWidth: wide ? DesignTokens.Initiatives.storyMaxWidth : .infinity, alignment: .topLeading)
            }
        }
        .padding(DesignTokens.Space.s6)
        .frame(maxWidth: .infinity, alignment: wide ? .top : .topLeading)
    }

    private func epics(picked: String?) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Initiatives.cardGap) {
            ForEach(Array(list.sections.enumerated()), id: \.element.id) { index, section in
                ZoneTitle(section.title).padding(.top, gapAbove(section: index))
                ForEach(section.initiatives) { initiative in
                    EpicCard(initiative: initiative, selected: initiative.id == picked, focused: listFocused, windowActive: windowActive) {
                        selection = initiative.id
                        listFocused = true
                    }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        .onKeyPress(.upArrow) { move(by: -1, from: picked) }
        .onKeyPress(.downArrow) { move(by: 1, from: picked) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SymphonyView.initiatives.title)
    }

    /// A second label sits further from the cards above it than the cards from each other.
    private func gapAbove(section index: Int) -> Double {
        index == 0 ? .zero : DesignTokens.Initiatives.groupGap - DesignTokens.Initiatives.cardGap
    }

    /// Up or Down: the epic before or after the picked one.
    private func move(by offset: Int, from picked: String?) -> KeyPress.Result {
        let ordered = list.ordered
        guard let index = ordered.firstIndex(where: { $0.id == picked }) else { return .ignored }
        let next = index + offset
        guard ordered.indices.contains(next) else { return .handled }
        selection = ordered[next].id
        return .handled
    }
}

/// An epic in the list (the catalog's `epicItem`): the selectable card with its identifier and "3 of 26 done", its title
/// on at most two lines, its strip, and what is not done, or, once it landed, when.
struct EpicCard: View {
    let initiative: Initiative
    let selected: Bool
    var focused = false
    var state: DesignTokens.Interaction?
    var windowActive: Bool?
    let select: () -> Void

    var body: some View {
        SelectableCard(selected: selected, focused: selected && focused, state: state, windowActive: windowActive, select: select) {
            VStack(alignment: .leading, spacing: DesignTokens.Initiatives.cardLineGap) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
                    Text(initiative.identifier)
                        .textStyle(.rowTitle)
                        .monospacedDigit()
                        .foregroundStyle(DesignTokens.TextColor.primary.color)
                    Spacer(minLength: DesignTokens.Space.s3)
                    Text(initiative.progress)
                        .textStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                        .foregroundStyle(DesignTokens.TextColor.secondary.color)
                }
                if let title = initiative.title {
                    Text(title)
                        .font(DesignTokens.TypeStyle.font(size: DesignTokens.TypeStyle.rowTitle.size, weight: DesignTokens.Initiatives.cardTitleWeight))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(DesignTokens.TextColor.primary.color)
                }
                if !initiative.subTickets.isEmpty {
                    ProgressStrip(initiative.cardStripItems, live: false, label: initiative.progress)
                }
                legend
            }
        }
        .accessibilityLabel(initiative.cardAccessibilityLabel())
        .help("Show \(initiative.identifier)'s story")
    }

    @ViewBuilder private var legend: some View {
        if let landed = initiative.landedLine() {
            Text(landed).textStyle(.secondary).foregroundStyle(DesignTokens.TextColor.secondary.color)
        } else if !initiative.cardLegend.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignTokens.Space.s3) { legendItems }
                VStack(alignment: .leading, spacing: DesignTokens.Space.s1) { legendItems }
            }
            .textStyle(.secondary)
            .foregroundStyle(DesignTokens.TextColor.secondary.color)
        }
    }
}

extension EpicCard {
    /// Each state not done: its dot, its count and its word, so the strip never relies on colour alone.
    fileprivate var legendItems: some View {
        ForEach(initiative.cardLegend) { item in
            HStack(spacing: DesignTokens.Space.s1) {
                StatusDot(item.status ?? .idle)
                Text(item.text).monospacedDigit()
            }
            .fixedSize()
        }
    }
}

/// The picked epic's story (the catalog's `initiativesPage` main column): its head, then its sub-tickets in landing
/// order, one line each, those past the two after the last one being worked on folded behind one line.
struct InitiativeStoryView: View {
    let initiative: Initiative
    let story: InitiativeStory
    var runs: [String: RunGroupModel] = [:]
    let actions: InitiativeActions
    var reference = Date()
    @State private var unfolded: Bool

    init(
        initiative: Initiative, story: InitiativeStory, runs: [String: RunGroupModel] = [:], actions: InitiativeActions,
        reference: Date = Date(), unfolded: Bool = false
    ) {
        self.initiative = initiative
        self.story = story
        self.runs = runs
        self.actions = actions
        self.reference = reference
        _unfolded = State(initialValue: unfolded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Initiatives.storyGap) {
            head
            if !story.rows.isEmpty {
                VStack(alignment: .leading, spacing: ZoneTitle.gap) {
                    ZoneTitle("Sub-tickets", note: "in landing order")
                    rows
                }
            }
        }
    }

    // MARK: - The head

    private var head: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Initiatives.headGap) {
            HStack(spacing: DesignTokens.Space.s3) {
                Text(initiative.identifier)
                    .textStyle(.secondary)
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                if let repo = initiative.repoKey { Chip(repo, kind: .repo) }
                Spacer(minLength: DesignTokens.Space.s3)
                if let current = story.current {
                    Button("Open \(current.identifier)") { actions.openTicket(current.identifier) }
                        .directorButton(.secondary, size: .small, glyph: "arrow.right")
                        .help("Open the ticket being worked on")
                }
            }
            .frame(minHeight: DesignTokens.Control.medium.height)
            if let title = initiative.title {
                Text(title)
                    .textStyle(.title)
                    .foregroundStyle(DesignTokens.TextColor.primary.color)
                    .frame(maxWidth: DesignTokens.Initiatives.titleMaxWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            sentence
                .textStyle(.sentence)
                .foregroundStyle(DesignTokens.TextColor.primary.color)
                .fixedSize(horizontal: false, vertical: true)
            if !story.stripItems.isEmpty {
                ProgressStrip(story.stripItems, height: DesignTokens.ProgressStrip.headerHeight, label: story.progress)
                    .frame(maxWidth: DesignTokens.ProgressStrip.headerMaxWidth)
            }
            if let note = InitiativeStory.note(initiative, reference: reference) {
                Text(note)
                    .textStyle(.secondary)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
            }
        }
    }

    /// "3 of 26 done." and, softer, where the chain stands.
    private var sentence: Text {
        let sentence = story.sentence
        guard let rest = sentence.rest else { return Text(sentence.lead) }
        return Text("\(sentence.lead) \(Text(rest).foregroundStyle(DesignTokens.TextColor.secondary.color))")
    }

    // MARK: - The rows

    private var rows: some View {
        let shown = (unfolded ? nil : story.foldIndex).map { story.rows[..<$0] } ?? story.rows[...]
        return VStack(alignment: .leading, spacing: DesignTokens.StoryRow.panelGap) {
            ForEach(shown) { row in
                InitiativeStoryRow(row: row, run: runs[row.identifier], actions: actions, reference: reference)
            }
            if let line = story.foldLine {
                StoryFold(unfolded ? InitiativeStory.unfoldedLine : line, open: unfolded) {
                    withAnimation(.motion(.standard)) { unfolded.toggle() }
                }
            }
        }
        .padding(DesignTokens.StoryRow.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(in: PanelStyle.shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sub-tickets")
    }
}

/// One sub-ticket of the story on the shared story row: its mark for its state, and at the right what matters for it,
/// or, for one being worked on, its situation under its title, its step bars and how long. A row opens the ticket's
/// page; Review on one that waits on the Director opens its Inbox item instead.
struct InitiativeStoryRow: View {
    let row: InitiativeStory.Row
    var run: RunGroupModel?
    let actions: InitiativeActions
    var reference = Date()

    var body: some View {
        StoryRow(
            number: row.number, mark: mark, identifier: row.identifier, title: row.title ?? row.identifier,
            quiet: row.attention == nil && [.done, .open, .next, .canceled].contains(row.mark),
            struck: row.mark == .canceled, current: row.mark == .current, label: row.accessibilityLabel, open: open
        ) {
            if row.mark == .current {
                SituationLine(undated, reference: reference, size: .compact)
            }
        } trail: {
            if let issueID = reviewIssueID {
                Button("Review") { actions.review(issueID) }
                    .directorButton(.primary, size: .small)
                    .help("Open it in the Inbox")
            }
            if row.mark == .current {
                if let steps = run?.steps, !steps.isEmpty {
                    StepBars(steps: steps)
                }
                if let age = SituationText(row.line, reference: reference).age {
                    Text(age)
                }
            } else if let trail = row.trail {
                Text(trail)
            }
        }
        .help("Open \(row.identifier)")
    }

    /// The line under the title without its age, which the trail says.
    private var undated: Situation {
        var line = row.line
        line.since = nil
        return line
    }

    private var mark: RowLead {
        if let attention = row.attention { return .status(attention) }
        return switch row.mark {
        case .done: .status(.done)
        case .current: .dot(.working, live: true)
        case .next: .glyph("clock", DesignTokens.TextColor.secondary)
        case .open: .glyph(row.line.kind.symbol, DesignTokens.TextColor.tertiary)
        case .canceled: .glyph(DesignTokens.SituationKind.cancelled.symbol, DesignTokens.TextColor.tertiary)
        }
    }

    private var reviewIssueID: String? { row.ticket?.reviewIssueID(inbox: actions.inbox) }

    private func open() {
        actions.openTicket(row.identifier)
    }
}
