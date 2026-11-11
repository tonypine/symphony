import AppKit
import SwiftUI
import SymphonyBarCore

// MARK: - The window model's ticket page, navigation and Stop Run

extension SymphonyWindowModel {
    /// The ticket whose page the window shows, nil on a sidebar view.
    var shownTicket: String? {
        if case let .ticket(identifier) = history.current { return identifier }
        return nil
    }

    /// True on a ticket's or a pull request's page, where no sidebar view is selected.
    var showsPage: Bool { history.current.isPage }

    /// The page of the ticket shown, from the client's last state and what the page read itself.
    var ticketPage: TicketPage? {
        guard let identifier = shownTicket else { return nil }
        var sources = ticketSources
        sources.state = client.stateJSON
        sources.stops = localStops
        sources.inboxDecision = inbox?.items.contains { $0.identifier == identifier && $0.isDecision } ?? false
        return TicketPage(identifier: identifier, sources: sources, now: Date())
    }

    /// Opens the page of ticket `identifier` (D3), from any row that shows it.
    func openTicket(_ identifier: String) {
        guard shownTicket != identifier else { return }
        history.visit(.ticket(identifier))
        showPlace()
    }

    /// ⌘[: the peek's page before, while the Inbox shows one; else the place before.
    func goBack() {
        if peekCanGoBack {
            peek.goBack()
            return
        }
        guard history.goBack() != nil else { return }
        showPlace()
    }

    var canGoBack: Bool { peekCanGoBack || history.canGoBack }

    private var peekCanGoBack: Bool { !showsPage && selection == .inbox && peek.canGoBack }

    /// ⌘].
    func goForward() {
        guard history.goForward() != nil else { return }
        showPlace()
    }

    /// Shows the history's current place: a view takes the sidebar's selection; a page reads its endpoints.
    func showPlace() {
        // A page that opens reads its ticket's feed from the start.
        ticketFeed.follow(identifier: nil, repoKey: nil)
        switch history.current {
        case let .view(view):
            selection = view
        case let .ticket(identifier):
            ticketNote.show(identifier)
            ticketDecisions.show(identifier)
            ticketSources = TicketPage.Sources()
            ticketSlowReadAt = nil
            readTicket(force: true)
            followTicketFeed(afterPoll: false)
        case .pullRequest:
            pullRequestResult = nil
            readPullRequest()
        }
    }

    /// Follows the shown ticket's events feed once its repo is known (the reader reads it all then), and after a state
    /// poll reads what is new while the live channel isn't there to say so.
    func followTicketFeed(afterPoll: Bool) {
        guard let identifier = shownTicket else {
            ticketFeed.follow(identifier: nil, repoKey: nil)
            return
        }
        let started = ticketFeed.follow(identifier: identifier, repoKey: ticketPage?.repoKey)
        if afterPoll, !started { ticketFeed.statePolled() }
    }

    /// The feed's reader read: the page shows what it holds, or today's timeline without it.
    func ticketEventsChanged(_ events: TicketEventsPayload?) {
        guard let identifier = shownTicket, identifier == ticketFeed.identifier else { return }
        ticketSources.events = events
        ticketSources.feedAbsence = ticketFeed.absence
    }

    /// Reads the shown ticket's endpoints: `/api/v1/:issue_identifier` after each state poll, its runs and audit
    /// records every `ticketSlowInterval` or when `force`d.
    func readTicket(force: Bool = false) {
        guard let identifier = shownTicket, !readingTicket, state.countsKnown else { return }
        let slow = force || ticketSlowReadAt.map { Date().timeIntervalSince($0) >= Self.ticketSlowInterval } ?? true
        readingTicket = true
        Task {
            var sources = ticketSources
            if case let .loaded(data) = await client.get(TicketPage.issuePath(identifier)) {
                sources.issue = data
            } else {
                sources.issue = nil
            }
            if slow {
                if case let .loaded(data) = await client.get(TicketPage.runsPath) { sources.runs = data }
                var audit: [Data] = []
                for path in TicketPage.auditPaths(identifier, now: Date()) {
                    if case let .loaded(data) = await client.get(path) { audit.append(data) }
                }
                sources.audit = audit
                ticketSlowReadAt = Date()
            }
            let decisions = await readTicketPath(TicketDecisionsEditor.path(identifier))
            readingTicket = false
            // A page left while its reads were out doesn't take them.
            guard shownTicket == identifier else { return }
            ticketDecisions.apply(decisions, for: identifier)
            // A Check Now answer and the feed's events that came in meanwhile stay.
            sources.check = ticketSources.check
            sources.events = ticketSources.events
            sources.feedAbsence = ticketSources.feedAbsence
            ticketSources = sources
            followTicketFeed(afterPoll: false)
        }
    }

    /// Opens the Stop Run sheet on `identifier`; nothing is sent until its button is pressed.
    func openStopRun(_ identifier: String, origin: StopRunSheet.Origin) {
        guard !stopInFlight else { return }
        let running = overviewState?.running.first { $0.identifier == identifier }
        stopError = nil
        stopSheet = StopRunSheet(identifier: identifier, origin: origin, isRunning: running != nil, state: running?.state)
    }

    func cancelStop() {
        guard !stopInFlight else { return }
        stopSheet = nil
        stopError = nil
    }

    /// The sheet's button: the stop, then the Backlog move with the note when it is on. A failure keeps the sheet
    /// open and says why; once the run has stopped, pressing again only retries the move.
    func confirmStop(_ sheet: StopRunSheet, alsoBacklog: Bool, note: String) {
        guard !stopInFlight, sheet.canSend(alsoBacklog: alsoBacklog) else { return }
        stopInFlight = true
        stopError = nil
        Task {
            var sheet = sheet
            var failure: String?
            var stop: TicketPage.LocalStop?
            for action in sheet.actions(alsoBacklog: alsoBacklog, note: note) {
                if case let .failed(message) = await onControl(action) {
                    failure = message
                    break
                }
                switch action {
                case .stop:
                    stop = TicketPage.LocalStop(identifier: sheet.identifier, at: Date(), movedToBacklog: false)
                    sheet.isRunning = false
                case let .backlog(_, note):
                    if stop != nil {
                        stop?.movedToBacklog = true
                        stop?.note = note
                    } else if let index = localStops.lastIndex(where: { $0.identifier == sheet.identifier && Date().timeIntervalSince($0.at) < 120 }) {
                        // The move retried after the stop went through.
                        localStops[index].movedToBacklog = true
                        localStops[index].note = note
                    }
                default:
                    break
                }
            }
            if let stop { localStops.append(stop) }
            stopInFlight = false
            if let failure {
                stopError = failure
                stopSheet = sheet
            } else {
                stopSheet = nil
            }
            client.refresh()
            readTicket(force: true)
        }
    }

    /// A Move to… pick (TP-1328): opens the move's sheet; nothing moves until its button is pressed.
    func openMove(_ sheet: MoveSheet) {
        guard !moveInFlight else { return }
        moveError = nil
        moveSheet = sheet
    }

    func cancelMove() {
        guard !moveInFlight else { return }
        moveSheet = nil
        moveError = nil
    }

    /// The sheet's button: the move with the note. On success the sheet closes, the banner offers Undo for 10 s and
    /// the state and the page are read again at once; a failure keeps the sheet open and says why.
    func confirmMove(_ sheet: MoveSheet, note: String) {
        guard !moveInFlight else { return }
        moveInFlight = true
        moveError = nil
        Task {
            let result = await onControl(sheet.action(note: note))
            moveInFlight = false
            switch result {
            case .done, .moved:
                moveSheet = nil
                showMoveBanner(sheet.banner(after: result.moveOutcome ?? sheet.expectedOutcome))
            case let .failed(message):
                moveError = message
            }
            client.refresh()
            readTicket(force: true)
        }
    }

    /// Start now (TP-1330): Symphony starts the ticket's run at once, ahead of the queue. The button is only clickable
    /// when the payload said it may start; on success the state and the page are read again at once, so the running
    /// line shows. A refusal (the state changed between the read and the click) shows Symphony's reason on the banner.
    func startNow(_ identifier: String) {
        guard startInFlight == nil else { return }
        startInFlight = identifier
        Task {
            let result = await onControl(TicketStart.action(identifier))
            if case let .failed(message) = result {
                showMoveBanner(.failed(itemID: identifier, identifier: identifier, message: message))
            }
            client.refresh()
            readTicket(force: true)
            startInFlight = nil
        }
    }

    /// The banner of the last Move to… or refused Start now, while it shows.
    var moveBanner: InboxBanner? {
        guard let banner = inboxBanner, banner.id == moveBannerID else { return nil }
        return banner
    }

    func showMoveBanner(_ banner: InboxBanner) {
        moveBannerID = banner.id
        showBanner(banner)
    }

    /// Undo on a Move to… banner: Symphony takes the move back; the banner says it did, or why it couldn't.
    func undoMove(_ banner: InboxBanner) {
        guard banner.undo else { return }
        dismissBanner()
        Task {
            switch await onControl(.undo(banner.identifier)) {
            case .done, .moved:
                showMoveBanner(.undone(itemID: banner.itemID, identifier: banner.identifier))
            case let .failed(message):
                showMoveBanner(.failed(itemID: banner.itemID, identifier: banner.identifier, message: message))
            }
            client.refresh()
            readTicket(force: true)
        }
    }

    /// Save Note in the facts rail: the note goes on the shown ticket, then the page reads what is new in its feed and
    /// the ticket read again, so the panel shows it at once.
    func submitNote() {
        guard let page = ticketPage else { return }
        Task {
            if await ticketNote.submit(on: page, send: onControl, read: { [ticketFeed] in ticketFeed.read() }) {
                readTicket()
            }
        }
    }

    private func readTicketPath(_ path: String) async -> Data? {
        if case let .loaded(data) = await client.get(path) { return data }
        return nil
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - D3: the ticket page (TP-1448)

/// What the ticket page's controls do.
struct TicketPageActions {
    /// A move on the Action rail, after the page took the ones it shows itself (Answer, Restart…, Write a Note…).
    var move: (TicketActionRail.Request) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }
    /// A click on a ticket or pull request chip in the page's text.
    var openMention: (Mention) -> Void = { _ in }
    /// A blocker's or a held ticket's row in the Connected panel.
    var openTicket: (String) -> Void = { _ in }
    /// The epic's row in the Connected panel: its place in Initiatives.
    var openInitiatives: () -> Void = {}
    /// The Details panel's Copy beside the workspace path.
    var copy: (String) -> Void = DetailsPanel.pasteboardCopy
    /// The Note panel's Save Note.
    var saveNote: () -> Void = {}
}

extension SymphonyWindowModel {
    /// A move the Action rail asks for on `page`: the control call sent, or its sheet opened. Answer, Restart… and
    /// Write a Note… are the page's own and never get here.
    func performMove(_ request: TicketActionRail.Request, on page: TicketPage) {
        switch request {
        case let .send(action):
            if action == TicketStart.action(page.identifier) { startNow(page.identifier) } else { send(action) }
        case .sheet(.stopRun):
            openStopRun(page.identifier, origin: .ticketPage)
        case let .sheet(.moveTo(state)):
            if let sheet = page.moveSheet(to: state) { openMove(sheet) }
        case .sheet(.force):
            openForceSheet(page.identifier)
        case .sheet(.answer), .sheet(.restart), .sheet(.note), .confirm:
            break
        }
    }
}

/// D3 for the window: the page with its sheets, or a placeholder while it reads.
struct TicketPageContent: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient
    @ObservedObject var decisions: TicketDecisionsEditor

    init(model: SymphonyWindowModel, client: LiveAPIClient) {
        self.model = model
        self.client = client
        decisions = model.ticketDecisions
    }

    var body: some View {
        if let page = model.ticketPage {
            let items = model.inbox?.items ?? []
            TicketPageView(
                page: page,
                questions: TicketPage.questions(of: page.identifier, in: items),
                references: items.first { $0.identifier == page.identifier }?.references ?? [:],
                actions: TicketPageActions(
                    move: { model.performMove($0, on: page) },
                    openURL: model.onOpenURL,
                    openMention: model.openDirectly,
                    openTicket: model.openTicket,
                    openInitiatives: { model.show(.initiatives) },
                    copy: model.copy,
                    saveNote: model.submitNote
                ),
                transcripts: model.stepTranscripts,
                note: model.ticketNote,
                decisions: decisions.decisions,
                restart: { model.send(.restart(page.identifier, reason: TicketPageView.restartReason)) },
                banner: model.moveBanner.flatMap { $0.identifier == page.identifier ? $0 : nil },
                undo: model.undoMove,
                closeBanner: model.dismissBanner
            )
        } else {
            EmptyState(title: "Reading the ticket…", symbol: "doc.text.magnifyingglass", showsSpinner: true)
        }
    }
}

/// The ticket page in a scroll view that scrolls as one, laid out for the width it gets, with the decision sheet over
/// it.
struct TicketPageView: View {
    let page: TicketPage
    /// The ticket's open Questions with their options, from the Inbox.
    var questions: [InboxReview.Action] = []
    /// The chips in the page's text, from the ticket's Inbox item.
    var references: [String: Reference] = [:]
    let actions: TicketPageActions
    let transcripts: StepTranscripts
    let note: TicketNoteComposer
    var decisions: [TicketDecision] = []
    /// Restart… once confirmed.
    var restart: () -> Void = {}
    /// A Move to…'s banner, with its Undo for 10 s, under the page.
    var banner: InboxBanner?
    var undo: (InboxBanner) -> Void = { _ in }
    var closeBanner: () -> Void = {}
    @State private var width: CGFloat = TicketPageLayout.laptopPageWidth
    @State private var scroll = TicketPageScroll()
    @State private var sheetOpen = false
    @State private var picks = DecisionPicks()
    @State private var confirmingRestart = false
    /// Bumped by the header's Answer on a desktop: the decisions column takes the keyboard to its first answer again.
    @State private var answerPresses = 0
    @FocusState private var answerFocused: Bool

    static let restartReason = "Restarted from the ticket page"
    static let noteAnchor = "note-panel"

    private var desktop: Bool { TicketPageLayout.isDesktop(page: width) }
    private var decisionsWidth: Double? {
        TicketPageLayout.arrangement(page: width, decisions: DecisionsLine(openQuestions: page.openQuestions, questions: questions).waiting)
            .decisionsWidth
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                TicketPageBody(
                    page: page, questions: questions, width: width, transcripts: transcripts, note: note, decisions: decisions,
                    actions: actions, sheetOpen: sheetOpen, answerFocus: $answerFocused,
                    move: { handle($0, proxy: proxy) }, answer: { sheetOpen = true },
                    scroll: scroll, decisionsInRow: false
                )
                .environment(\.mentionReferences, references)
            }
            .onScrollGeometryChange(for: EdgeInsets.self) { $0.contentInsets } action: { _, insets in
                scroll.update(insets: insets)
            }
            .coordinateSpace(name: TicketPageBody.viewportSpace)
            // The desktop's decisions column is pinned over the scroll view, outside the page it scrolls: its height and
            // place follow the page's scroll, and nothing they do can change the page's own layout (TP-1449's QA found a
            // column inside the page, sized from the page's measured row, hanging the app).
            .overlay(alignment: .topLeading) {
                if let decisionsWidth {
                    PinnedDecisions(scroll: scroll, width: decisionsWidth) {
                        TicketDecisionsColumn(
                            page: page, questions: questions, picks: picks,
                            pick: { option, question in picks.picks[question] = option },
                            writeIn: { text, question in picks.writeIns[question] = text },
                            answerPresses: answerPresses
                        )
                    }
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            if width != size.width { width = size.width }
            scroll.update(viewport: size.height)
        }
        .onChange(of: desktop) { _, wide in
            // The desktop's decisions are a column on the page: the laptop's sheet has nothing left to cover.
            if wide { sheetOpen = false }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let banner {
                InboxBannerView(banner: banner, undo: { undo(banner) }, close: closeBanner)
                    .padding(.horizontal, DesignTokens.Space.s5)
                    .padding(.bottom, DesignTokens.Space.s3)
            }
        }
        .decisionSheet(isPresented: desktop ? .constant(false) : $sheetOpen, returnFocus: $answerFocused) {
            DecisionSheet(
                questions: questions, picks: picks, subtitle: page.sheetSubtitle,
                pick: { option, question in picks.picks[question] = option },
                writeIn: { text, question in picks.writeIns[question] = text },
                send: {}, close: { sheetOpen = false }, sendOff: DecisionsLine.sendLaterReason
            )
            .environment(\.mentionReferences, references)
        }
        .confirmationDialog("Restart \(page.identifier)?", isPresented: $confirmingRestart) {
            Button("Restart", role: .destructive, action: restart)
            Button("Keep It", role: .cancel) {}
        } message: {
            Text("Symphony closes \(page.identifier)'s pull request and starts it over from a fresh branch.")
        }
        .onChange(of: page.identifier) { _, _ in
            sheetOpen = false
            picks = DecisionPicks()
        }
    }

    /// A move on the rail: the page shows Answer's sheet (on a desktop, the keyboard goes to the decisions column), asks before Restart… and takes Write a Note… to the Note
    /// panel; the rest go to the window.
    private func handle(_ request: TicketActionRail.Request, proxy: ScrollViewProxy) {
        switch request {
        case .sheet(.answer):
            if desktop { answerPresses += 1 } else { sheetOpen = true }
        case .sheet(.restart): confirmingRestart = true
        case .sheet(.note): withAnimation { proxy.scrollTo(Self.noteAnchor, anchor: .top) }
        default: actions.move(request)
        }
    }
}

/// Where the page's scroll view is, for the sticky columns: only the views that read it draw again as the page
/// scrolls, never the timeline beside them. What it holds only places those columns (an offset, the pinned decisions
/// column over the scroll view), never sizes anything inside the page, so a measure can't feed back into itself. A
/// value set again unchanged publishes nothing.
final class TicketPageScroll: ObservableObject {
    /// The scroll view's height.
    @Published private(set) var viewport: Double
    /// What the window covers at the scroll view's edges: a toolbar on top, a banner at the foot.
    @Published private(set) var insets = EdgeInsets()
    /// The columns' row in the scroll view: it moves up as the page scrolls. In a snapshot, with no scroll view, where
    /// it is in the page.
    @Published private(set) var row: CGRect = .zero

    init(viewport: Double = TicketPageLayout.laptopWindowHeight) {
        self.viewport = viewport
    }

    func update(viewport: Double) {
        if self.viewport != viewport { self.viewport = viewport }
    }

    func update(insets: EdgeInsets) {
        if self.insets != insets { self.insets = insets }
    }

    func update(row: CGRect) {
        if self.row != row { self.row = row }
    }
}

/// The page's zones, outside the scroll view so they also render offscreen: the header across the page; under it,
/// in the main column, the decisions line, the Lifecycle section and the Timeline section; the facts rail beside
/// them, 340 pt wide. Below the width where the main column fits beside the rail, the rail goes under it.
///
/// From 1600 pt on, the desktop's (TP-1449): the moves on the identifier's line; no decisions line, the open
/// Questions instead as a 600 pt column on the far right with their Send; the rail at 440 pt; the main column fluid
/// beside them, up to 1040 pt with the columns centred when nothing waits. The rail and the decisions column are
/// sticky within the page's scroll.
struct TicketPageBody: View {
    let page: TicketPage
    var questions: [InboxReview.Action] = []
    let width: CGFloat
    let transcripts: StepTranscripts
    let note: TicketNoteComposer
    var decisions: [TicketDecision] = []
    var actions = TicketPageActions()
    /// Answer stays pressed while the sheet is open.
    var sheetOpen = false
    var answerFocus: FocusState<Bool>.Binding?
    /// A move on the Action rail.
    var move: (TicketActionRail.Request) -> Void = { _ in }
    /// The decisions line's Answer.
    var answer: () -> Void = {}
    /// Where the page's scroll view is; a snapshot's page hasn't scrolled.
    var scroll = TicketPageScroll()
    /// A snapshot draws the desktop's decisions column in its row, as tall as the window lets it be unscrolled; the
    /// window's page keeps only its room there and pins the column over its scroll view (`PinnedDecisions`).
    var decisionsInRow = true
    var calendar: Calendar = .current
    /// Snapshots only: the Details panel's run models unfolded.
    var detailsUnfolded = false

    /// The page's scroll view, where the columns' row is measured as the page scrolls.
    static let viewportSpace = "ticket-page-viewport"

    private var gap: CGFloat { TicketPageLayout.gap }
    private var line: DecisionsLine { DecisionsLine(openQuestions: page.openQuestions, questions: questions) }
    private var arrangement: TicketPageLayout.Arrangement {
        TicketPageLayout.arrangement(page: width, decisions: line.waiting)
    }

    var body: some View {
        let arrangement = arrangement
        VStack(alignment: .leading, spacing: gap) {
            TicketPageHeader(page: page, desktop: arrangement.desktop, move: move)
            if arrangement.railBeside {
                HStack(alignment: .top, spacing: arrangement.columnGap) {
                    mainColumn(desktop: arrangement.desktop).frame(maxWidth: .infinity, alignment: .topLeading)
                    StickyColumn(scroll: scroll) { rail(width: arrangement.railWidth) }
                        .frame(width: arrangement.railWidth)
                    if let decisionsWidth = arrangement.decisionsWidth {
                        if decisionsInRow {
                            UnscrolledDecisions(scroll: scroll) {
                                TicketDecisionsColumn(page: page, questions: questions)
                            }
                            .frame(width: decisionsWidth)
                        } else {
                            Color.clear.frame(width: decisionsWidth, height: 0)
                        }
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.viewportSpace)) } action: { frame in
                    scroll.update(row: frame)
                }
            } else {
                mainColumn(desktop: false)
                rail(width: nil)
            }
        }
        // At most as wide as the columns need, never wider than the scroll view gives: a scroller beside the page
        // narrows the page instead of pushing it sideways.
        .frame(maxWidth: arrangement.desktop ? arrangement.contentWidth : nil, alignment: .topLeading)
        .padding(gap)
        .frame(maxWidth: .infinity, alignment: arrangement.desktop ? .top : .topLeading)
        .environment(\.openMention, OpenMentionAction(handler: actions.openMention))
    }

    private func mainColumn(desktop: Bool) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            // The desktop shows the Questions in their own column: no line, no Answer.
            if !desktop {
                DecisionsLineView(line: line, open: sheetOpen, focus: answerFocus, answer: answer)
            }
            if let lifecycle = page.lifecycleRead?.lifecycle {
                LifecycleSection(model: LifecycleModel.build(lifecycle, phase: page.lifecycleRead?.phasePath?.current))
            }
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                Text(TimelineSection.title)
                    .font(DesignTokens.TypeStyle.section.font)
                    .accessibilityAddTraits(.isHeader)
                TimelineSection(
                    model: TimelineModel.build(
                        page.history ?? TicketEventsPayload(), runNow: page.runNow, reference: page.reference, calendar: calendar
                    ),
                    transcripts: transcripts, calendar: calendar
                )
                .id(page.identifier)
            }
        }
    }

    private func rail(width: CGFloat?) -> some View {
        let runs = page.history?.runs ?? [:]
        return VStack(alignment: .leading, spacing: gap) {
            PullRequestPanel(model: PullRequestPanelModel.build(page.factsRead?.pullRequest), open: actions.openURL)
            ConnectedPanel(
                model: ConnectedPanelModel.build(page.factsRead?.connected, reference: page.reference, calendar: calendar),
                openTicket: actions.openTicket, openInitiatives: actions.openInitiatives
            )
            NotePanel(
                model: NotePanelModel.build(
                    note: page.detailsRead?.note, move: page.detailsRead?.noteMove, runs: runs, reference: page.reference, calendar: calendar
                ),
                composer: note, save: actions.saveNote
            )
            .id(TicketPageView.noteAnchor)
            DecisionsPanel(model: DecisionsPanelModel.build(decisions))
            DetailsPanel(
                model: DetailsPanelModel.build(
                    page.detailsRead, runs: runs, linearURL: page.url, pullRequest: page.factsRead?.pullRequest, description: nil,
                    reference: page.reference, calendar: calendar
                ),
                open: actions.openURL, copy: actions.copy, modelsUnfolded: detailsUnfolded
            )
        }
        .frame(width: width, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Facts")
    }
}

/// A column that stays in view as the page scrolls (§5): shorter than the window, it sticks under the window's top;
/// taller, it scrolls with the page until its foot is in view and stays there. Only this view draws again as the page
/// scrolls, and only its offset changes: never its size, nor the row's.
private struct StickyColumn<Content: View>: View {
    @ObservedObject var scroll: TicketPageScroll
    @ViewBuilder let content: () -> Content
    @State private var height: Double = 0

    var body: some View {
        // The row's place in what the window shows of the scroll view: where it starts there, as the page has scrolled.
        let visible = scroll.viewport - scroll.insets.top - scroll.insets.bottom
        content()
            .onGeometryChange(for: Double.self) { $0.size.height } action: { if height != $0 { height = $0 } }
            .offset(
                y: TicketPageLayout.stickyOffset(
                    scroll: 0, viewport: visible, top: scroll.row.minY - scroll.insets.top, height: height, room: scroll.row.height
                )
            )
    }
}

/// The desktop's decisions column pinned over the page's scroll view: its top with the columns' row until the row
/// scrolls under the window's top, its foot above the window's bottom, so its header and Send are always in view. It
/// sits over the row's room for it, at the row's right edge.
private struct PinnedDecisions<Content: View>: View {
    @ObservedObject var scroll: TicketPageScroll
    let width: Double
    @ViewBuilder let content: () -> Content

    var body: some View {
        let pinned = TicketPageLayout.pinnedDecisions(
            rowTop: scroll.row.minY, viewport: scroll.viewport, insetTop: scroll.insets.top, insetBottom: scroll.insets.bottom
        )
        content()
            .frame(width: width, height: pinned.height)
            .offset(x: scroll.row.maxX - width, y: pinned.top)
            // Until the row is measured there is nowhere to put it.
            .opacity(scroll.row == .zero ? 0 : 1)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Decisions")
    }
}

/// A snapshot's decisions column in its row: from the row's top to the window's bottom margin, the page unscrolled.
private struct UnscrolledDecisions<Content: View>: View {
    @ObservedObject var scroll: TicketPageScroll
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(height: TicketPageLayout.decisionsColumnRoom(viewport: scroll.viewport, top: scroll.row.minY))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Decisions")
    }
}

/// The desktop's decisions column: the decision sheet's content without its sheet chrome (no close button, no
/// shadow), its header on top and its Send at the foot, the Questions scrolling between them.
struct TicketDecisionsColumn: View {
    let page: TicketPage
    let questions: [InboxReview.Action]
    /// The answers picked so far, and what picking one does.
    var picks = DecisionPicks()
    var pick: (Int, Int) -> Void = { _, _ in }
    var writeIn: (String, Int) -> Void = { _, _ in }
    /// The header's Answer on a desktop, counted: each press takes the keyboard to the column's first answer.
    var answerPresses = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        Group {
            if questions.isEmpty {
                // Symphony names a Question the Inbox doesn't hold yet: its options come with the Inbox's next read.
                VStack(spacing: DesignTokens.Space.s3) {
                    ProgressView().controlSize(.small)
                    Text(DecisionsLine(openQuestions: page.openQuestions, questions: questions).title)
                        .font(DesignTokens.TypeStyle.rowTitle.font)
                    Text(DecisionsLine.readingReason)
                        .font(DesignTokens.TypeStyle.callout.font)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DesignTokens.Surface.window.color)
                .accessibilityElement(children: .combine)
            } else {
                DecisionSheet(
                    questions: questions, picks: picks, subtitle: page.sheetSubtitle, pick: pick, writeIn: writeIn,
                    send: {}, close: nil, sendOff: DecisionsLine.sendLaterReason
                )
                .id(answerPresses)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(DesignTokens.Surface.separator.color))
    }
}

/// The header across the page: the identifier with its repo and epic chips, the title, where the ticket stands and
/// why (the Situation line), and the moves on their own row under them. On a desktop (TP-1449) the moves sit on the
/// identifier's line, at its right, so the title has the whole width under them.
struct TicketPageHeader: View {
    let page: TicketPage
    var desktop = false
    var move: (TicketActionRail.Request) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                if desktop, let moves = page.moves {
                    HStack(alignment: .top, spacing: DesignTokens.Space.s8) {
                        identifierLine
                            .frame(minHeight: DesignTokens.Control.medium.height)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ActionRail(rail: TicketActionRail(identifier: page.identifier, moves: moves), perform: move)
                            .layoutPriority(1)
                    }
                } else {
                    identifierLine
                }
                Text(page.headerTitle ?? page.identifier)
                    .font(DesignTokens.TypeStyle.sentence.font)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
            }
            if let situation = page.situation {
                SituationLine(situation, reference: page.reference, forced: page.isForced)
            } else {
                Text(page.phaseSentence)
                    .font(DesignTokens.TypeStyle.body.font)
                    .foregroundStyle(.secondary)
            }
            if let note = page.repositoryPausedNote {
                Label(note, systemImage: "pause.circle")
                    .font(DesignTokens.TypeStyle.body.font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !desktop, let moves = page.moves {
                ActionRail(rail: TicketActionRail(identifier: page.identifier, moves: moves), perform: move)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var identifierLine: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            Text(page.identifier)
                .font(DesignTokens.TypeStyle.label.font)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let repo = page.repoKey { HeaderChip(text: repo, systemImage: SymphonyView.repos.symbol) }
            if let epic = page.epicChip { HeaderChip(text: epic, systemImage: SymphonyView.initiatives.symbol) }
        }
    }
}

/// A chip beside the identifier: the repo, the epic.
private struct HeaderChip: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(DesignTokens.TypeStyle.caption.font)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, DesignTokens.Space.s2)
            .padding(.vertical, 2)
            .background(DesignTokens.Surface.separator.color.opacity(0.5), in: Capsule())
    }
}

/// The decisions line (§2, question 1): "A question waits on you" in the Waiting on you tint with Answer, which opens
/// the decision sheet and stays pressed while it is open; or "Nothing needs you" in the same place and height.
struct DecisionsLineView: View {
    let line: DecisionsLine
    var open = false
    var focus: FocusState<Bool>.Binding?
    let answer: () -> Void

    /// The line's height either way, so the page never jumps when a Question comes or goes.
    static let height: CGFloat = 56

    private var tint: Color { DesignTokens.Status.you.tint }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        HStack(spacing: DesignTokens.Space.s3) {
            mark
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title)
                    .font(line.waiting ? DesignTokens.TypeStyle.rowTitle.font : DesignTokens.TypeStyle.body.font)
                    .foregroundStyle(line.waiting ? .primary : .secondary)
                Text(line.detail)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: DesignTokens.Measure.reading, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line.accessibilityLabel)
            if line.waiting { answerButton }
        }
        .padding(.leading, DesignTokens.Space.s4)
        .padding(.trailing, DesignTokens.Space.s3)
        .frame(minHeight: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line.waiting ? AnyShapeStyle(tint.opacity(0.12)) : AnyShapeStyle(DesignTokens.Surface.content.color), in: shape)
        .overlay(shape.strokeBorder(line.waiting ? tint.opacity(0.25) : DesignTokens.Surface.separator.color))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Decisions")
    }

    @ViewBuilder private var mark: some View {
        if line.waiting {
            Image(systemName: "questionmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 17))
                .foregroundStyle(.tertiary)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var answerButton: some View {
        let button = Button(DecisionsLine.answerTitle, action: answer)
            .directorButton(.primary, size: .medium, selected: open)
            .disabledReason(line.answerReason)
            .help(line.answerReason ?? "Open the question to answer it")
            .accessibilityHint(line.answerReason ?? "Opens the decision sheet")
        if let focus {
            button.focused(focus)
        } else {
            button
        }
    }
}

/// Lays its views out in lines, left to right, starting a new line when the next one doesn't fit.
struct WrappingStack: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let places = arrange(width: bounds.width, subviews: subviews).places
        for (subview, place) in zip(subviews, places) {
            subview.place(at: CGPoint(x: bounds.minX + place.x, y: bounds.minY + place.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> (places: [CGPoint], size: CGSize) {
        let maxWidth = width ?? .infinity
        var places: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            places.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (places, CGSize(width: widest, height: y + lineHeight))
    }
}

// MARK: - TP-1330: Start now

/// Start Now: disabled, its tooltip Symphony's reason, whenever the payload says the start would be refused; a spinner
/// and "Starting…" while the call is on its way.
struct StartNowButton: View {
    let identifier: String
    let start: TicketStart
    var starting = false
    let action: () -> Void
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    var body: some View {
        Button(action: action) {
            if starting {
                HStack(spacing: DesignTokens.Space.s1) {
                    if offscreenSnapshot {
                        // `ImageRenderer` can't draw a spinner: a still one stands in.
                        Image(systemName: "progress.indicator").accessibilityHidden(true)
                    } else {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                    }
                    Text(TicketStart.startingTitle)
                }
            } else {
                Text(TicketStart.title)
            }
        }
        .disabled(!start.allowed || starting)
        .help(start.help(identifier))
        .accessibilityLabel(starting ? "Starting \(identifier)" : start.accessibilityLabel(identifier))
    }
}

/// A Tickets row's Start Now entry: disabled with Symphony's reason under its title when the start would be refused.
struct StartNowMenuItem: View {
    let identifier: String
    let start: TicketStart
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(TicketStart.title)
            if !start.allowed { Text(start.help(identifier)) }
        }
        .disabled(!start.allowed)
        .help(start.help(identifier))
        .accessibilityLabel(start.accessibilityLabel(identifier))
    }
}

// MARK: - TP-1328: Move to…

/// Move to…'s entries, in a Tickets row's context menu.
struct MoveToMenuItems: View {
    let menu: TicketMoveMenu
    let move: (MoveSheet) -> Void

    var body: some View {
        ForEach(menu.entries) { entry in
            if entry.isCurrent {
                // A checked item, off: the phase the ticket is in.
                Toggle(entry.name, isOn: .constant(true))
                    .disabled(true)
                    .accessibilityLabel(TicketMoveMenu.accessibilityLabel(entry))
            } else {
                Button(entry.name) { menu.sheet(for: entry).map(move) }
                    .accessibilityLabel(TicketMoveMenu.accessibilityLabel(entry))
            }
        }
    }
}

/// The move's sheet: the question, what happens and what stays, the optional note, then Cancel and the move.
struct MoveSheetView: View {
    let sheet: MoveSheet
    let working: Bool
    let error: String?
    let cancel: () -> Void
    let confirm: (_ note: String) -> Void
    @State private var note: String
    @FocusState private var noteFocused: Bool
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    init(sheet: MoveSheet, working: Bool, error: String?, note: String = "", cancel: @escaping () -> Void,
         confirm: @escaping (String) -> Void) {
        self.sheet = sheet
        self.working = working
        self.error = error
        self.cancel = cancel
        self.confirm = confirm
        _note = State(initialValue: note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            Text(sheet.title)
                .font(DesignTokens.TypeStyle.sentence.font)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(sheet.happens)
                .font(DesignTokens.TypeStyle.body.font)
                .fixedSize(horizontal: false, vertical: true)
            Text(sheet.stays)
                .font(DesignTokens.TypeStyle.body.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if offscreenSnapshot {
                // `ImageRenderer` can't draw a text field: its text stands in.
                Text(note.isEmpty ? MoveSheet.notePlaceholder : note)
                    .font(DesignTokens.TypeStyle.body.font)
                    .foregroundStyle(note.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .padding(.horizontal, DesignTokens.Space.s2)
                    .padding(.vertical, DesignTokens.Space.s1)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                    .background(DesignTokens.Surface.content.color, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(DesignTokens.Surface.separator.color))
            } else {
                TextField(MoveSheet.notePlaceholder, text: $note, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                    .focused($noteFocused)
                    .accessibilityLabel(MoveSheet.notePrompt)
            }
            if let error {
                Label(error, systemImage: DesignTokens.Status.problem.symbol)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(DesignTokens.Status.problem.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DesignTokens.Space.s2) {
                if working {
                    ProgressView().controlSize(.small).accessibilityLabel("Working")
                }
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button(sheet.verb) { confirm(note) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(width: 460)
        .onAppear { noteFocused = true }
    }
}

/// Presents the window model's Move to… sheet on any view that offers Move to….
struct MoveSheetPresenter: ViewModifier {
    @ObservedObject var model: SymphonyWindowModel

    func body(content: Content) -> some View {
        content.sheet(item: $model.moveSheet) { sheet in
            MoveSheetView(
                sheet: sheet,
                working: model.moveInFlight,
                error: model.moveError,
                cancel: model.cancelMove,
                confirm: { note in model.confirmMove(sheet, note: note) }
            )
        }
    }
}

// MARK: - D12c: the Stop Run sheet

/// C17: the Stop Run sheet. The title is the question; then what happens, what stays the same, Also move to Backlog
/// with its note, and Cancel with Stop Run in the destructive style.
struct StopRunSheetView: View {
    let sheet: StopRunSheet
    let working: Bool
    let error: String?
    let cancel: () -> Void
    let confirm: (_ alsoBacklog: Bool, _ note: String) -> Void
    @State private var alsoBacklog: Bool
    @State private var note: String

    init(sheet: StopRunSheet, working: Bool, error: String?, note: String = "", cancel: @escaping () -> Void,
         confirm: @escaping (Bool, String) -> Void) {
        self.sheet = sheet
        self.working = working
        self.error = error
        self.cancel = cancel
        self.confirm = confirm
        _alsoBacklog = State(initialValue: sheet.alsoBacklogByDefault)
        _note = State(initialValue: note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            Text(sheet.title)
                .font(DesignTokens.TypeStyle.sentence.font)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(sheet.happens(alsoBacklog: alsoBacklog))
                .font(DesignTokens.TypeStyle.body.font)
                .foregroundStyle(sheet.isRunning ? AnyShapeStyle(DesignTokens.Status.problem.tint) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
            Text(sheet.stays(alsoBacklog: alsoBacklog))
                .font(DesignTokens.TypeStyle.body.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                Toggle(StopRunSheet.alsoBacklogTitle, isOn: $alsoBacklog)
                    .toggleStyle(.checkbox)
                if alsoBacklog {
                    TextField(StopRunSheet.notePlaceholder, text: $note, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(StopRunSheet.notePrompt)
                }
            }
            if let error {
                Label(error, systemImage: DesignTokens.Status.problem.symbol)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(DesignTokens.Status.problem.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DesignTokens.Space.s2) {
                if working {
                    ProgressView().controlSize(.small).accessibilityLabel("Working")
                }
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button(sheet.verb, role: sheet.isRunning ? .destructive : nil) { confirm(alsoBacklog, note) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(sheet.isRunning ? DesignTokens.Status.problem.tint : nil)
                    .disabled(working || !sheet.canSend(alsoBacklog: alsoBacklog))
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(width: 460)
    }
}

/// Presents the window model's Stop Run sheet on any view that offers Stop Run….
struct StopRunSheetPresenter: ViewModifier {
    @ObservedObject var model: SymphonyWindowModel

    func body(content: Content) -> some View {
        content.sheet(item: $model.stopSheet) { sheet in
            StopRunSheetView(
                sheet: sheet,
                working: model.stopInFlight,
                error: model.stopError,
                cancel: model.cancelStop,
                confirm: { alsoBacklog, note in model.confirmStop(sheet, alsoBacklog: alsoBacklog, note: note) }
            )
        }
    }
}
