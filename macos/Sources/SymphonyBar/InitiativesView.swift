import SwiftUI
import SymphonyBarCore

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

    /// Reads the selected epic's records and each open sub-ticket's ticket read while Initiatives shows: at once on a new
    /// selection, and at most every `initiativeStoryInterval` after a state poll.
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
            initiativeStoryReadAt[epic] = Date()
            readingInitiativeStory = false
        }
    }
}

struct InitiativeActions {
    /// The issue ids the Inbox lists; Review is offered only on these.
    var inbox: Set<String> = []
    /// Review on a sub-ticket that waits on the Director opens its Inbox item, by issue id.
    var review: (String) -> Void = { _ in }
    /// Any other row opens the ticket's page, by identifier.
    var openTicket: (String) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }
}

/// The list grouped as Active, In review and Done recently beside the selected initiative, like the Inbox (P4).
struct InitiativesView: View {
    let list: InitiativesList
    @Binding var selection: String?
    /// The selected initiative's story; without one, the story the initiative alone tells.
    var story: (Initiative) -> InitiativeStory = { InitiativeStory(initiative: $0) }
    let actions: InitiativeActions
    /// Symphony's clock, so a sub-ticket's situation age reads as on every other page.
    var reference = Date()

    var body: some View {
        if list.isEmpty {
            ContentUnavailableView {
                Label(InitiativesList.emptyTitle, systemImage: SymphonyView.initiatives.symbol)
            } description: {
                Text(InitiativesList.emptyDescription)
            }
        } else {
            HStack(spacing: 0) {
                ScrollView {
                    InitiativesListRows(list: list, selected: list.selection(selection)?.id, select: { selection = $0 })
                }
                .frame(width: DesignTokens.Layout.listColumnWidth)
                .background(DesignTokens.Surface.content.color)
                Divider()
                if let initiative = list.selection(selection) {
                    ScrollView {
                        InitiativeDetail(initiative: initiative, story: story(initiative), actions: actions, reference: reference)
                    }
                    .id(initiative.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

/// The groups and their rows, outside the scroll view so they also render offscreen.
struct InitiativesListRows: View {
    let list: InitiativesList
    let selected: String?
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            ForEach(list.sections) { section in
                Text(section.title)
                    .font(DesignTokens.TypeStyle.label.font)
                    .foregroundStyle(.secondary)
                    .padding(.top, DesignTokens.Space.s3)
                    .padding(.horizontal, DesignTokens.Space.s3)
                    .accessibilityAddTraits(.isHeader)
                ForEach(section.initiatives) { initiative in
                    InitiativeRow(initiative: initiative, selected: initiative.id == selected)
                        .contentShape(Rectangle())
                        .onTapGesture { select(initiative.id) }
                        .accessibilityAction { select(initiative.id) }
                }
            }
        }
        .padding(DesignTokens.Space.s2)
    }
}

/// A list row: identifier and title, "4 of 8 done", and the bar with its legend.
private struct InitiativeRow: View {
    let initiative: Initiative
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            HStack(alignment: .firstTextBaseline) {
                Text(initiative.identifier).font(DesignTokens.TypeStyle.rowTitle.font)
                Spacer(minLength: DesignTokens.Space.s2)
                Text(initiative.progress)
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let title = initiative.title {
                Text(title).font(DesignTokens.TypeStyle.body.font).lineLimit(1)
            }
            ProgressStrip(initiative.stripItems, live: false, label: initiative.progress)
            InitiativeLegend(initiative: initiative)
        }
        .padding(DesignTokens.Space.s3)
        .background(
            selected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(Color.clear),
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(initiative.identifier), \(initiative.title ?? ""), \(initiative.barAccessibilityLabel)")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - C12: the progress strip's legend

/// The strip's legend: each stage's symbol, count and word, so the strip never relies on color alone.
struct InitiativeLegend: View {
    let initiative: Initiative

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Space.s3) { items }
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1 / 2) { items }
        }
        .font(DesignTokens.TypeStyle.caption.font)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var items: some View {
        ForEach(initiative.legend, id: \.stage) { item in
            Label {
                Text("\(item.count) \(item.stage.word)").foregroundStyle(.secondary).monospacedDigit()
            } icon: {
                Image(systemName: item.stage.symbol)
                    .foregroundStyle(item.stage.status.tint.opacity(item.stage.isLight ? 0.6 : 1))
            }
            .labelStyle(.titleAndIcon)
            .fixedSize()
        }
    }
}

// MARK: - The detail

/// The selected initiative as the epic's story (TP-1458): its sentence, the epic read's progress strip and count, its
/// slot line, and its sub-tickets in chain order, numbered, the current one highlighted.
struct InitiativeDetail: View {
    let initiative: Initiative
    let story: InitiativeStory
    let actions: InitiativeActions
    /// The clock the sub-tickets' situation ages are measured against.
    var reference = Date()

    init(initiative: Initiative, story: InitiativeStory? = nil, actions: InitiativeActions, reference: Date = Date()) {
        self.initiative = initiative
        self.story = story ?? InitiativeStory(initiative: initiative, reference: reference)
        self.actions = actions
        self.reference = reference
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                    Button { actions.openTicket(initiative.identifier) } label: {
                        Text(initiative.identifier).font(DesignTokens.TypeStyle.label.font).foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Open the ticket page")
                    if let title = initiative.title {
                        Text(title).font(DesignTokens.TypeStyle.heading.font).accessibilityAddTraits(.isHeader)
                    }
                }
                Spacer()
                if let url = initiative.url {
                    Button("Open in Linear") { actions.openURL(url) }
                }
            }
            Text(initiative.sentence)
                .font(DesignTokens.TypeStyle.sentence.font)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                if let strip = story.strip {
                    ProgressStrip(strip.items, height: DesignTokens.ProgressStrip.headerHeight, label: strip.accessibilityLabel)
                        .frame(maxWidth: DesignTokens.ProgressStrip.headerMaxWidth)
                } else {
                    ProgressStrip(initiative.stripItems, height: DesignTokens.ProgressStrip.headerHeight, label: initiative.progress)
                        .frame(maxWidth: DesignTokens.ProgressStrip.headerMaxWidth)
                    InitiativeLegend(initiative: initiative)
                }
                if let slot = initiative.slot {
                    Label(slot.line, systemImage: "square.stack.3d.up")
                        .font(DesignTokens.TypeStyle.secondary.font)
                        .foregroundStyle(.secondary)
                }
            }
            Card(title: "Sub-tickets") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(story.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        StoryRow(row: row, numberWidth: numberWidth, actions: actions, reference: reference)
                    }
                    if story.rows.isEmpty {
                        Text("No sub-tickets yet.").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Room for the widest number, so the identifiers line up.
    private var numberWidth: CGFloat { story.rows.count >= 10 ? 26 : 16 }
}

/// A sub-ticket of the story: its number, identifier and title, its situation line (C31) or, once done, the day it
/// finished, and the blockers its ticket read names, a resolved one struck through with its date (analysis §2.3). The
/// current one sits on the accent tint; a done one reads quietly; a canceled one is struck. Review when it waits on the
/// Director in the Inbox, else the row opens the ticket page.
private struct StoryRow: View {
    let row: InitiativeStory.Row
    let numberWidth: CGFloat
    let actions: InitiativeActions
    var reference = Date()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            Text(row.number.map(String.init) ?? "")
                .font(DesignTokens.TypeStyle.secondary.font)
                .monospacedDigit()
                .foregroundStyle(row.mark == .current ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .frame(width: numberWidth, alignment: .trailing)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1 / 2) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                    Text(row.identifier).font(DesignTokens.TypeStyle.rowTitle.font).strikethrough(row.mark == .canceled)
                    if let title = row.title { Text(title).lineLimit(1).strikethrough(row.mark == .canceled) }
                }
                .foregroundStyle(quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if let done = row.doneLine {
                    Label(done, systemImage: DesignTokens.SituationKind.done.symbol)
                        .font(DesignTokens.TypeStyle.secondary.font)
                        .foregroundStyle(.tertiary)
                } else {
                    SituationLine(row.line, reference: reference, size: .compact)
                }
                if !row.blockers.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: DesignTokens.Space.s3) { blockerLinks }
                        VStack(alignment: .leading, spacing: DesignTokens.Space.s1 / 2) { blockerLinks }
                    }
                    .font(DesignTokens.TypeStyle.secondary.font)
                }
            }
            Spacer(minLength: DesignTokens.Space.s2)
            if let issueID = reviewIssueID {
                Button("Review") { actions.review(issueID) }
                    .directorButton(.primary, size: .small)
                    .help("Open it in the Inbox")
            } else {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
        }
        .padding(.vertical, DesignTokens.Space.s2)
        .padding(.horizontal, DesignTokens.Space.s2)
        .background(
            row.mark == .current ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(Color.clear),
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture { actions.openTicket(row.identifier) }
        // One button-like element: its default action is the row's own (Review, else the ticket page);
        // Review, the ticket page and each blocker are named actions.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(row.mark == .current ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAction { primaryAction() }
        .accessibilityActions {
            if let issueID = reviewIssueID {
                Button("Review") { actions.review(issueID) }
            }
            Button("Open Ticket") { actions.openTicket(row.identifier) }
            ForEach(row.blockers) { blocker in
                Button("Open \(blocker.identifier)") { actions.openTicket(blocker.identifier) }
            }
        }
    }

    private var quiet: Bool { row.mark == .done || row.mark == .canceled }

    @ViewBuilder private var blockerLinks: some View {
        Text("Blocked by").foregroundStyle(.tertiary).fixedSize()
        ForEach(row.blockers) { blocker in
            BlockerLink(blocker: blocker, open: actions.openTicket).fixedSize()
        }
    }

    private var reviewIssueID: String? { row.ticket?.reviewIssueID(inbox: actions.inbox) }

    private func primaryAction() {
        if let issueID = reviewIssueID { actions.review(issueID) } else { actions.openTicket(row.identifier) }
    }
}

/// A blocker as its ticket read names it: open with its situation and phase; resolved struck through and secondary,
/// with the day it resolved.
private struct BlockerLink: View {
    let blocker: ConnectedPanelModel.Row
    let open: (String) -> Void

    var body: some View {
        Button { open(blocker.identifier) } label: {
            HStack(spacing: DesignTokens.Space.s1) {
                if blocker.struck {
                    Text(blocker.identifier).strikethrough().foregroundStyle(.secondary)
                } else {
                    Image(systemName: blocker.status.symbol).foregroundStyle(blocker.status.tint).accessibilityHidden(true)
                    Text(blocker.identifier).foregroundStyle(Color.accentColor)
                }
                Text(blocker.detail).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .help("Open \(blocker.identifier)")
    }
}

// MARK: - D1: the Overview's Initiatives card

/// The active initiatives and their progress; a click opens one in Initiatives.
struct InitiativesCard: View {
    let initiatives: [Initiative]
    let open: (String) -> Void
    static let limit = 4

    var body: some View {
        Card(title: SymphonyView.initiatives.title) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                ForEach(initiatives.prefix(Self.limit)) { initiative in
                    Button { open(initiative.id) } label: {
                        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(initiative.identifier).font(DesignTokens.TypeStyle.rowTitle.font)
                                Text(initiative.title ?? "").lineLimit(1).foregroundStyle(.secondary)
                                Spacer(minLength: DesignTokens.Space.s2)
                                Text(initiative.progress).font(DesignTokens.TypeStyle.secondary.font).monospacedDigit()
                            }
                            ProgressStrip(initiative.stripItems, label: initiative.progress)
                            InitiativeLegend(initiative: initiative)
                            if let noLane = initiative.slot?.overviewLine {
                                Text(noLane)
                                    .font(DesignTokens.TypeStyle.secondary.font)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(initiative.identifier) in Initiatives")
                    .accessibilityLabel(
                        [initiative.identifier, initiative.title ?? "", initiative.barAccessibilityLabel, initiative.slot?.overviewLine]
                            .compactMap { $0 }
                            .joined(separator: ", ")
                    )
                }
                if initiatives.count > Self.limit {
                    Text("\(initiatives.count - Self.limit) more in Initiatives")
                        .font(DesignTokens.TypeStyle.secondary.font)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
