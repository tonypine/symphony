import AppKit
import Combine
import SwiftUI
import SymphonyBarCore

/// What the Symphony window shows, refreshed by its controller.
@MainActor
final class SymphonyWindowModel: ObservableObject {
    let sidebar = Sidebar()
    let client: LiveAPIClient

    /// The page shown; Repos and Settings never are, as they open their own windows.
    @Published var selection: SymphonyView {
        didSet {
            guard selection != oldValue else { return }
            destinationMemory.remember(selection)
            onSelect(selection)
            readTicketsIfDue()
            readInitiativeStoryIfDue()
            readAggregateIfDue()
            readQualityIfDue()
            readShippedIfDue()
            readAuditIfDue()
            readJournalIfDue()
        }
    }

    /// Whether Symphony answers, or which placeholder every view shows instead (D0).
    @Published var state: WindowState = .stopped {
        didSet {
            guard state != oldValue else { return }
            followConnection()
        }
    }
    /// The live channel: Symphony's notice of each event written to a ticket's history, open while the window is
    /// connected to Symphony. The ticket page reads only what is new when one names its ticket.
    let eventStream: EventStream
    /// Reads the shown ticket's events feed: all of it when the page opens, then what is new when the channel names
    /// the ticket, when it reconnects, or after a state poll while it is down.
    let ticketFeed: TicketEventsReader
    /// The transcripts of the timeline's steps a person unfolds, read through `client` and kept by artifact id.
    let stepTranscripts: StepTranscripts
    /// The facts rail's Note for the next run: what is typed, the note on its way, why the last one wasn't added.
    let ticketNote = TicketNoteComposer()
    /// The facts rail's Decisions panel: the decisions recorded on the shown ticket.
    let ticketDecisions = TicketDecisionsEditor()
    /// The build of the Symphony the window last read, to tell a restart onto another build.
    private var symphonyBuild: DiagnosticsPayload.Build?
    @Published var paused = false
    /// The app's update under way, which the dispatch control and the Overview show (S3a, S3b).
    @Published var updateHold: UpdateHold?
    /// The Overview's reading of the last state payload.
    @Published private(set) var overviewState: OverviewState?
    /// The PR and CI watcher's reading of it: each watched ticket's block, for the Inbox's evidence (S16).
    @Published private(set) var watchState = WatchState()
    /// The last answer to `/api/v1/repos`, for the Overview's repos line.
    @Published private(set) var repos: ReposPoll?
    /// All repos or one: filters every view, and is remembered across relaunches (P6).
    @Published var scope: OverviewScope = .all {
        didSet {
            guard scope != oldValue else { return }
            onScopeChange(scope)
            // Audit and Tickets ask Symphony for the scope's records.
            auditReadAt = nil
            readAuditIfDue()
            ticketsReadAt = nil
            readTicketsIfDue()
            restartJournal()
            // The Insights pages read the scope's slice when their repo control reads the scope.
            insightsSliceChanged()
        }
    }
    /// The control request a view sent and Symphony hasn't answered yet.
    @Published private(set) var controlInFlight: ControlAction?
    /// The last Inbox Symphony served, read again after each state poll.
    @Published private(set) var inbox: InboxPayload? {
        // Whether it holds a decision on the ticket shown is the page's.
        didSet { buildTicketPage() }
    }
    /// What the last Inbox read got when it got no Inbox, nil after one that did.
    @Published private(set) var inboxResult: EndpointResult?
    /// The Inbox item shown, by issue id; nil shows the first.
    @Published var inboxSelection: String?
    /// The Inbox's drawer (TP-1454): the review of `inboxSelection` in the window's inspector, on Home or a ticket page.
    @Published var inboxDrawerShown = false
    /// The Director's picks in each item's decisions, and its write-in, by issue id (C16, N11). Not `@Published`: a
    /// keystroke in the write-in redraws the window only when the text turns blank or stops being blank.
    private(set) var inboxPicks = InboxPicks() {
        willSet { if publishesPicks { objectWillChange.send() } }
    }
    private var publishesPicks = true
    /// The peek (N4): the tickets and pull requests the Director opened from the review, beside it.
    @Published var peek = PeekNavigation()
    /// Each peeked ticket's `/api/v1/:issue_identifier`, by identifier; absent while it answers 404.
    @Published var peekIssues: [String: Data] = [:]
    var peekReads = PeekReads()
    /// The consequence sheet shown (C17); nothing changes Linear until its button is pressed.
    @Published var inboxSheet: ConsequenceSheet?
    /// True while the sheet's move is on its way to Symphony.
    @Published private(set) var inboxMoveInFlight = false
    /// What went wrong with the sheet's move, shown in the sheet.
    @Published private(set) var inboxMoveError: String?
    /// The banner after a move, with Undo for 10 s (C18).
    @Published private(set) var inboxBanner: InboxBanner?
    /// The last Initiatives Symphony served, read again after each state poll.
    @Published private(set) var initiatives: InitiativesPayload?
    /// What the last Initiatives read got when it got none, nil after one that did.
    @Published private(set) var initiativesResult: EndpointResult?
    /// The selected epic's records (`GET /api/v1/tickets?epic=`), by the epic's identifier (TP-1458).
    @Published var initiativeRecords: [String: [TicketsRow]] = [:]
    /// Each sub-ticket's ticket read `connected`, by identifier: its blockers and the epic's progress (TP-1458).
    @Published var initiativeConnected: [String: TicketConnected] = [:]
    var readingInitiativeStory = false
    /// When the selected epic's story was last read, by the epic's identifier.
    var initiativeStoryReadAt: [String: Date] = [:]
    /// The Insights control bar's choice (TP-1463): the period, unit, repo and epic Quality, Usage and Shipped read
    /// together, remembered across relaunches. Changing it reads the three pages' slice again.
    @Published var insightsSlice = InsightsSlice() {
        didSet {
            guard insightsSlice != oldValue else { return }
            onInsightsSliceChange(insightsSlice)
            insightsSliceChanged()
        }
    }
    var onInsightsSliceChange: (InsightsSlice) -> Void = { _ in }
    /// `GET /api/v1/aggregate`'s last answer and last failure, read while an Insights page shows; the three pages
    /// draw what it holds for the slice (`aggregateShown`).
    @Published private(set) var aggregateRead = AggregateRead()
    /// The history's review and the runs of Quality's slice, read while Quality shows, or why they failed.
    @Published private(set) var qualityReview = QualityReviewRead()
    /// Shipped's merged tickets for its period, read while Shipped shows (D9).
    @Published var shipped: ShippedPayload?
    /// What the last Shipped read got when it got none, nil after one that did.
    @Published var shippedResult: EndpointResult?
    /// Every stored learning, read while Shipped shows, for its Learnings tab.
    @Published var learnings: LearningsPayload?
    @Published var learningsResult: EndpointResult?
    /// Shipped's segmented control: Shipped or Learnings.
    @Published var shippedTab: Shipped.Tab = .shipped
    /// The Learnings tab's repo and tag filters and search.
    @Published var learningsFilter = Learnings.Filter()
    /// Set by ⌥⌘F on Shipped to put the focus in the Learnings search field.
    @Published var learningsSearchRequested = false
    /// Audit's records under the filters Symphony applies, read while Audit shows (D10), newest last as served.
    @Published var auditRecords: [AuditRecord]?
    /// The chain verification of the days Audit reads; nil while unknown.
    @Published var auditVerification: AuditVerification?
    /// What the last Audit read got when it got no records, nil after one that did.
    @Published var auditResult: EndpointResult?
    /// Audit's kind, date and ticket filters and search; a change in the first three reads again.
    @Published var auditFilter = Audit.Filter() {
        didSet {
            guard auditFilter.query != oldValue.query else { return }
            auditReadAt = nil
            readAuditIfDue()
        }
    }
    /// The audit record in the inspector, by id.
    @Published var auditSelection: String?
    /// Set by ⌥⌘F on Audit to put the focus in its search field.
    @Published var auditSearchRequested = false
    /// True while Export… reads the records; what went wrong with it, shown under the filters.
    @Published var auditExporting = false
    @Published var auditExportError: String?
    /// The initiative shown, by issue id; nil shows the first. A change reads its story.
    @Published var initiativeSelection: String? {
        didSet { if initiativeSelection != oldValue { readInitiativeStoryIfDue() } }
    }
    /// The views and ticket pages shown, for ⌘[ and ⌘] (P10); its current place is what the window shows.
    @Published var history: NavigationHistory {
        didSet {
            followTicketLook()
            // The drawer belongs to the place it opened on: another view or page opens without it.
            if history.current != oldValue.current { inboxDrawerShown = false }
        }
    }
    /// The ticket page shown and the look it sends when the person leaves it (TP-1451).
    var ticketLook = TicketLook()
    /// What the ticket page shown last read from its own endpoints; the state comes from the client's poll.
    @Published var ticketSources = TicketPage.Sources() {
        didSet { buildTicketPage() }
    }
    /// Builds the page shown off the main actor when its sources changed (TP-1479).
    let ticketPageBuilder = TicketPageBuilder()
    /// The page shown and its Timeline, as last built: reading it builds nothing.
    @Published var ticketPageModel: TicketPageModel?
    /// What the pull request page shown read from its endpoint, nil while it reads (D15).
    @Published var pullRequestResult: PullRequestPageResult?
    var readingPullRequest = false
    /// The link each pull request page was opened from, for Open on GitHub before Symphony answers.
    var pullRequestLinks: [PullRequestPlace: URL] = [:]
    /// How far each Inbox review is scrolled, so ⌘[ from a page finds it where it was. Not `@Published`: a scroll
    /// redraws nothing else.
    var inboxScroll = InboxScrollOffsets()
    /// The Stop Run sheet shown (D12c); nothing stops until its button is pressed.
    @Published var stopSheet: StopRunSheet?
    /// True while the sheet's requests are on their way to Symphony.
    @Published var stopInFlight = false
    /// What went wrong with them, shown in the sheet.
    @Published var stopError: String?
    /// The Move to… sheet shown (TP-1328); nothing moves until its button is pressed.
    @Published var moveSheet: MoveSheet?
    /// True while the sheet's move is on its way to Symphony.
    @Published var moveInFlight = false
    /// What went wrong with it, shown in the sheet.
    @Published var moveError: String?
    /// The banner a Move to… showed, which the ticket page and Tickets show while it stays.
    @Published var moveBannerID: UUID?
    /// The ticket whose Start now (TP-1330) is on its way to Symphony; its button shows progress meanwhile.
    @Published var startInFlight: String?
    /// Stops made from the app, shown on the timeline until their audit record arrives.
    @Published var localStops: [TicketPage.LocalStop] = [] {
        didSet { buildTicketPage() }
    }
    /// The Journal's filters (TP-1459): kept for the session, and each change reads the newest page again.
    @Published var journalQuery = JournalQuery() {
        didSet {
            // Reports only shows less of what is read: it reads nothing again.
            guard !journalQuery.readsAsTheSame(oldValue) else { return }
            restartJournal()
        }
    }
    /// The status reports the Journal pins among its events (TP-1462), newest first.
    @Published var journalReports: [JournalReport] = []
    /// The events the reports cite that the Journal's pages don't hold, read from each report's period.
    @Published var journalCitations = JournalCitations()
    /// The reports whose period was read for their citations, read once each.
    var journalPeriodsRead = Set<String>()
    var readingReports = false
    /// The Journal's pages read under its query and the window's scope, newest first.
    @Published var journalFeed = JournalFeed()
    /// What the last Journal read got when it got no page, nil after one that did.
    @Published var journalResult: EndpointResult?
    /// Show Earlier's read on its way.
    @Published var journalReadingEarlier = false
    var readingJournal = false
    /// When the newest page was last read: a state poll reads it again at most every `ticketSlowInterval`.
    var journalReadAt: Date?
    /// The event a ticket page opens at, from a Journal row (TP-1459): the page selects it and scrolls to it.
    @Published var ticketFocus: TimelineFocus?
    /// Tickets' filter chips, columns and sort (TP-1456): kept for the session, and each change reads the rows again.
    @Published var ticketsQuery = TicketsQuery() {
        didSet {
            guard ticketsQuery != oldValue else { return }
            ticketsReadAt = nil
            readTicketsIfDue()
        }
    }
    /// The rows `GET /api/v1/tickets` served for the query, read while Tickets shows.
    @Published var ticketsPayload: TicketsPayload?
    /// What the last tickets read got when it got no rows, nil after one that did.
    @Published var ticketsResult: EndpointResult?
    /// The ticket entity's columns, as `GET /api/v1/views` names them; the documented catalog until it answers.
    @Published var ticketCatalog = TicketColumn.catalog
    /// The values the filters' menus offer, learned from the rows read this session.
    @Published var ticketFilterValues = TicketFilterValues()
    var ticketCatalogRead = false
    /// The saved views (TP-1457), as the last views read listed them, and the one in force: nil for "All open".
    @Published var ticketViews: [TicketView] = []
    @Published var ticketViewID: String?
    /// Save View… or Rename…'s sheet, Delete…'s confirmation, a view call on its way and what went wrong with it.
    @Published var ticketViewSheet: TicketViewSheet?
    @Published var ticketViewDeleteShown = false
    @Published var ticketViewInFlight = false
    @Published var ticketViewError: String?
    var readingTickets = false
    var ticketsReadAgain = false
    /// When the rows were last read: a state poll reads them again at most every `ticketsInterval`.
    var ticketsReadAt: Date?
    static let ticketsInterval: TimeInterval = 5
    /// Tickets' search, which narrows the rows by identifier and title, and its selected row (D6).
    @Published var ticketSearch = ""
    @Published var ticketSelection: String?
    /// Tickets' inspector (⌥⌘I, Space).
    @Published var inspectorShown = true
    /// Set by ⌥⌘F on Tickets to put the focus in its search field.
    @Published var searchRequested = false
    /// ⌘F's Find a Ticket sheet, from any page (TP-1455).
    @Published var ticketFinderShown = false
    /// Each destination's page shown last this session: Work and Insights open on the tab left last (TP-1455).
    private(set) var destinationMemory = DestinationMemory()
    /// The dispatch control's popover (D12a).
    @Published var dispatchPopoverShown = false
    /// The Pause Dispatch sheet (D12a) and the Force a Ticket sheet (D12b); nothing is sent until their button is pressed.
    @Published var pauseSheetShown = false
    @Published var forceSheet: ForceSheetRequest?
    /// True while the sheets' or the popover's request is on its way to Symphony.
    @Published var dispatchInFlight = false
    /// What went wrong with it, shown in the sheet or the popover.
    @Published var dispatchError: String?
    /// The Setup payload the last fix or Check Again answered with; the page shows it while it is newer than the
    /// state poll's (SU3).
    @Published var setupAnswer: SetupPayload?
    /// The Setup rows in the order shown: they keep their places, new ones join below (P7).
    @Published var setupOrder: [String] = []
    /// The fix's consequence sheet shown (SU7, SU8); nothing changes until its button is pressed.
    @Published var setupSheet: SetupFixSheet?
    /// True while Check Again is on its way: the toolbar's spinner.
    @Published var setupChecking = false
    /// The banner after a fix, with Undo for 10 s after a settings fix (SU10).
    @Published var setupBanner: SetupBanner?
    /// SU12: the welcome line above the Setup page when the first launch opened it, nil otherwise.
    @Published var setupWelcome: String?
    /// The last GitHub updates action's answer: the card shows it until the state poll reports something new.
    @Published var githubUpdatesAnswer: GitHubUpdatesAnswer?
    /// The GitHub updates card's consequence sheet (S11, S12, the relay sheet); nothing changes until its button.
    @Published var githubUpdatesSheet: GitHubUpdatesSheet?
    /// True while Restart Relay is on its way.
    @Published var restartingRelay = false
    /// S2–S6: the guided setup behind Turn On Instant Updates… and Finish Setup…, nil while it is closed.
    @Published var githubUpdatesSetup: GitHubUpdatesSetup?
    var githubUpdatesSetupController: GitHubUpdatesSetupController?
    var setupBannerTask: Task<Void, Never>?
    /// The app's own build, for the build warning (J11).
    var appBuild = AppBuild(build: 0, isDevelopment: true)
    /// The `symphony.yml` path in Settings.
    var configPath: () -> String = { "" }
    /// Check Again with no fix, a Linear fix with one: `POST /api/v1/setup/refresh` or `/fixes`.
    var onSetupRequest: (_ fix: [String: Any]?) async -> SetupAPI.Result = { _ in .failed("") }
    /// `symphony check` on a copy of `symphony.yml`, as the settings writer runs it.
    var onCheckConfig: (String) async -> ConfigCheckResult = { _ in .passed }
    /// `POST /api/v1/setup/github_updates/<action>`, to Symphony or the API fixtures.
    var onGitHubUpdatesRequest: (GitHubUpdatesAPI.Action, [String: String]) async -> GitHubUpdatesAPI.Result = { _, _ in .failed("") }
    /// `GET /api/v1/setup`'s GitHub updates section, which the guided setup reads while a test update is on its way.
    var onGitHubUpdatesRead: () async -> GitHubUpdatesAPI.Result = { .failed("") }
    /// Moves the webhook secret Symphony handed off into the app's secret item, and whether the item holds one.
    var onMoveWebhookSecret: () -> WebhookSecret.Move = { .nothingHandedOff }
    var onWebhookSecretStored: () -> Bool = { false }
    /// Opens Terminal on `gh` with these arguments; the reason when it couldn't.
    var onOpenGitHubTerminal: (_ arguments: [String]) -> String? = { _ in "Terminal isn't available." }
    /// The app's graceful restart of Symphony.
    var onRestartSymphony: () -> Void = {}
    /// The app's version, for the sidebar footer while Symphony doesn't say its own.
    var appVersion = ""
    /// Where the client reads Symphony from, for Diagnostics.
    var apiURL: () -> URL? = { nil }
    var canOpenLogs: () -> Bool = { false }

    var onSelect: (SymphonyView) -> Void = { _ in }
    var onAction: (WindowState.Action) -> Void = { _ in }
    /// Opens the Repos window; with a repo key, on that repo's Review sheet.
    var onOpenRepos: (String?) -> Void = { _ in }
    var onScopeChange: (OverviewScope) -> Void = { _ in }
    /// Sends a control request to Symphony, or to the API fixtures in QA mode, and says how it went.
    var onControl: (ControlAction) async -> ControlResult = { _ in .done }
    /// Check Now on a ticket: Symphony's watcher reads and decides at once, and answers with its new watch block.
    var onCheckNow: (String) async -> WatchCheck.Result = { _ in .failed("") }
    var onOpenURL: (URL) -> Void = { _ in }
    /// Opens the session reader on a run of a ticket; `follow` reads the run again as the page has it now, nil once the
    /// page shows another ticket.
    var onReadSession: (_ identifier: String, _ run: RunGroupModel, _ follow: @escaping () -> RunGroupModel?) -> Void = { _, _, _ in }

    /// The repos are read again at most this often: Symphony reads each checkout's remote to answer.
    static let reposInterval: TimeInterval = 30
    private var reposReadAt: Date?
    private var readingRepos = false
    private var readingInbox = false
    private var readingInitiatives = false
    private var readingAggregate = false
    private var readingQuality = false
    /// The history is read again at most this often.
    static let historyInterval: TimeInterval = 60
    var readingShipped = false
    /// When Shipped and Learnings were last read; the run records they come from change slowly.
    var shippedReadAt: Date?
    var readingAudit = false
    /// When Audit was last read.
    var auditReadAt: Date?
    var readingTicket = false
    /// The tags of the ticket read and the decisions read the page shows (TP-1492): each read after a state poll sends
    /// them, and while nothing changed Symphony answers `304` with no body. A page opened on a ticket starts without.
    var ticketReads = ConditionalReads()
    /// When the ticket page last read its runs and audit records, which change slowly.
    var ticketSlowReadAt: Date?
    /// The runs and audit records are read again at most this often.
    static let ticketSlowInterval: TimeInterval = 10
    private var bannerTask: Task<Void, Never>?
    /// An answer the app holds for the banner's Undo before it sends it (`ConsequenceSheet.holdsForUndo`), with the
    /// banner that offers the Undo and the wait that sends it.
    private var held: (sheet: ConsequenceSheet, action: ControlAction, bannerID: UUID, wait: Task<Void, Never>)? = nil {
        // The ticket page's Send stays off while its answer is held: it redraws when one is held or let go.
        willSet { objectWillChange.send() }
    }
    /// Why Symphony refused a ticket's answer sent after the banner's time, by identifier: the ticket page shows it
    /// under its Send until the Director answers again.
    @Published private(set) var answerFailures: [String: String] = [:]
    /// Whether an answer waits for the banner's Undo, still to send.
    var holdsAnswer: Bool { held != nil }

    /// Whether the Director answered the Inbox item `itemID`: held for Undo, on its way, or taken and not read back yet.
    /// A report's Question leaves its card from that moment (TP-1462), and an Undo brings it back.
    func answered(_ itemID: String) -> Bool { answeredItems.contains(itemID) }
    /// The Inbox items the Director answered, by issue id: they leave the Inbox without a banner of their own.
    /// It also keeps the ticket page's Send off from the answer until the read that drops it (`answering`).
    private var answeredItems = Set<String>() {
        willSet { objectWillChange.send() }
    }
    /// The tickets a Check Now is on its way for.
    @Published private(set) var checkingNow = Set<String>()
    /// A sheet to open once the Inbox lists its item: Approve and Merge… chosen on a notification.
    private var pendingSheet: (id: String, move: InboxMove)?
    private var cancellables = Set<AnyCancellable>()

    init(client: LiveAPIClient, eventStream: EventStream, selection: SymphonyView) {
        self.client = client
        self.eventStream = eventStream
        self.selection = selection
        destinationMemory.remember(selection)
        ticketFeed = TicketEventsReader(get: { [client] path in TicketEventsResult(await client.answer(path)) })
        stepTranscripts = StepTranscripts(get: { [client] path in await client.answer(path) })
        history = NavigationHistory(current: .view(selection))
        ticketFeed.listen(to: eventStream)
        ticketFeed.onChange = { [weak self] events in self?.ticketEventsChanged(events) }
        client.$stateJSON
            .sink { [weak self] data in
                guard let self else { return }
                overviewState = data.flatMap(OverviewState.decode)
                watchState = data.map(WatchState.decode) ?? WatchState()
                holdSetupOrder()
                settleGitHubUpdatesAnswer()
                readReposIfDue()
                readInbox()
                readInitiatives()
                readInitiativeStoryIfDue()
                readTicketsIfDue()
                readAggregateIfDue()
                readQualityIfDue()
                readShippedIfDue()
                readAuditIfDue()
                readJournalIfDue()
                readTicket()
                buildTicketPage(state: data)
                followTicketFeed(afterPoll: true)
                readPeek()
            }
            .store(in: &cancellables)
        ticketPageBuilder.$model
            .dropFirst()
            .sink { [weak self] model in self?.ticketPageBuilt(model) }
            .store(in: &cancellables)
        client.$diagnostics
            .map { $0?.build }
            .removeDuplicates()
            .sink { [weak self] build in self?.symphonyBuildChanged(build) }
            .store(in: &cancellables)
    }

    /// Opens the live channel while Symphony answers and closes it otherwise, so a channel an older Symphony lacked
    /// is tried again each time the window connects.
    private func followConnection() {
        if state == .connected { eventStream.start() } else { eventStream.stop() }
    }

    /// Symphony restarted onto another build between two polls: the channel opens again on the new one.
    private func symphonyBuildChanged(_ build: DiagnosticsPayload.Build?) {
        defer { symphonyBuild = build ?? symphonyBuild }
        guard let build, let symphonyBuild, build != symphonyBuild, state == .connected else { return }
        eventStream.stop()
        eventStream.start()
    }

    /// Home's badge: what waits on the Director in every repo, whatever the scope (P6), from the same
    /// list as the menu and the Overview's tile; 0 hides it, as do unknown counts.
    var inboxBadge: Int {
        guard state.countsKnown, let overviewState else { return 0 }
        return overviewState.snapshot.waitingOnYou.count
    }

    /// Opens the Inbox's drawer on Home, on the item with issue id `id`, or on its first item: the menu bar's Open
    /// Inbox and its rows, a notification, the View menu.
    func showInbox(selecting id: String? = nil) {
        if let id { inboxSelection = id }
        show(.overview)
        inboxDrawerShown = true
        readInbox()
    }

    /// Review on a Home row or a ticket page's decisions line: the drawer on the item with issue id `id`, where the
    /// window is.
    func reviewInDrawer(_ id: String) {
        inboxSelection = id
        peek.close()
        inboxDrawerShown = true
        readInbox()
    }

    /// True where the window draws the drawer: Home, and a ticket's page; not a pull request's page.
    var presentsInboxDrawer: Bool {
        HomeInbox.presentsDrawer(onHome: selection == .overview && !showsPage, onTicketPage: shownTicket != nil)
    }

    /// Hides the drawer, or shows it on the item selected.
    func toggleInboxDrawer() {
        if !inboxDrawerShown { readInbox() }
        inboxDrawerShown.toggle()
    }

    /// Home's top (TP-1454): every Inbox item under the window's scope, newest first, less the ones answered from the
    /// app, which leave at once.
    var homeInbox: HomeInbox? {
        inbox.map { HomeInbox(items: $0.items, scope: scope, answered: answeredItems, picks: picks(for:)) }
    }

    /// Opens Initiatives on the initiative with issue id `id`.
    func showInitiative(_ id: String) {
        initiativeSelection = id
        show(.initiatives)
        readInitiatives()
    }

    /// The Initiatives under the window's scope.
    var initiativesList: InitiativesList? {
        initiatives.map { InitiativesList(initiatives: $0.initiatives, scope: scope, state: overviewState?.snapshot) }
    }

    /// Reads the Initiatives; Symphony serves them from what it cached on its last poll, so this costs no Linear
    /// request.
    private func readInitiatives() {
        guard !readingInitiatives, state.countsKnown else { return }
        readingInitiatives = true
        Task {
            let result = await client.get(InitiativesPayload.path)
            if case let .loaded(data) = result, let payload = InitiativesPayload.decode(data) {
                initiatives = payload
                initiativesResult = nil
            } else {
                initiativesResult = result
            }
            readingInitiatives = false
            readInitiativeStoryIfDue()
        }
    }

    /// The Inbox under the window's scope.
    var inboxList: InboxList? {
        inbox.map { InboxList(items: $0.items, scope: scope) }
    }

    /// Opens the Inbox on the item with issue id `id` and its `move` sheet, once the Inbox lists it.
    func showInbox(selecting id: String, opening move: InboxMove) {
        pendingSheet = (id, move)
        showInbox(selecting: id)
        openPendingSheet()
    }

    private func openPendingSheet() {
        guard let pending = pendingSheet, let item = inbox?.items.first(where: { $0.id == pending.id }) else { return }
        pendingSheet = nil
        open(pending.move, on: item)
    }

    func picks(for itemID: String) -> DecisionPicks { inboxPicks[itemID] }

    /// Picks option `option` in decision `decision` of the item with issue id `itemID`.
    func pick(_ option: Int, decision: Int, itemID: String) {
        inboxPicks.pick(option, decision: decision, itemID: itemID)
    }

    /// Keeps what the Director writes in the write-in (N11) of decision `decision` of the item with issue id `itemID`,
    /// with its picks.
    func writeIn(_ text: String, decision: Int, itemID: String) {
        var picks = inboxPicks
        let blankChanged = picks.writeIn(text, itemID: itemID, decision: decision)
        publishesPicks = blankChanged
        inboxPicks = picks
        publishesPicks = true
    }

    /// Acts on a review's toolbar entry: a move opens its sheet, a link opens.
    func perform(_ command: InboxCommand, on item: InboxItem) {
        switch command {
        case let .move(move): open(move, on: item)
        case let .link(action): perform(action)
        }
    }

    /// Opens the consequence sheet of `move` on `item`. An answer on `item` the app still holds is taken back first:
    /// the Director is answering again, with the picks it left.
    func open(_ move: InboxMove, on item: InboxItem) {
        guard !inboxMoveInFlight else { return }
        if let held, held.sheet.itemID == item.id {
            held.wait.cancel()
            self.held = nil
            answeredItems.remove(item.id)
            if inboxBanner?.id == held.bannerID { dismissBanner() }
        }
        inboxMoveError = nil
        answerFailures[item.identifier] = nil
        inboxSheet = ConsequenceSheet(move: move, item: item, picks: picks(for: item.id))
    }

    /// True from the moment an answer to ticket `identifier` is confirmed until the Inbox read that drops its
    /// Question: held for the banner's Undo, on its way to Symphony, or taken and not read back yet. The ticket page's
    /// Send stays off meanwhile, so nothing is sent twice. A refusal or an Undo turns it on again.
    func answering(_ identifier: String) -> Bool {
        held?.sheet.identifier == identifier
            || (inboxMoveInFlight && inboxSheet?.identifier == identifier)
            || ticketQuestions(identifier).awaitingRead(answeredItems)
    }

    /// Symphony took an answer to ticket `identifier`: the ticket page, when it shows it, reads the ticket and its feed
    /// again at once, so the Question leaves it and the timeline gains the answer.
    private func answerSent(_ identifier: String) {
        answerFailures[identifier] = nil
        guard shownTicket == identifier else { return }
        readTicket(force: true)
        ticketFeed.read()
    }

    /// Cancel on the sheet: nothing is sent.
    func cancelSheet() {
        guard !inboxMoveInFlight else { return }
        inboxSheet = nil
        inboxMoveError = nil
    }

    /// The sheet's button: sends the move; on success the sheet closes, the selection moves to the next item after
    /// a move (the item leaves the list once Symphony's poll sees it moved) and the banner shows; on failure the
    /// sheet says why.
    func confirm(_ sheet: ConsequenceSheet, reason: String) {
        guard !inboxMoveInFlight, let action = sheet.action(reason: reason) else { return }
        if sheet.holdsForUndo { return hold(action, of: sheet) }
        inboxMoveInFlight = true
        inboxMoveError = nil
        Task {
            let result = await onControl(action)
            inboxMoveInFlight = false
            switch result {
            case .done, .moved:
                inboxSheet = nil
                // The picks were sent: Send Decisions turns off again.
                inboxPicks.clear(sheet.itemID)
                answeredItems.insert(sheet.itemID)
                let outcome = result.moveOutcome ?? sheet.expectedOutcome
                if sheet.selectsNext(after: outcome) { inboxSelection = inboxList?.neighbor(of: sheet.itemID)?.id }
                showBanner(sheet.banner(after: outcome))
                answerSent(sheet.identifier)
            case let .failed(message):
                inboxMoveError = message
            }
            client.refresh()
        }
    }

    /// Holds an answer that moves nothing for the banner's Undo (DS10): the sheet closes, the selection moves to the
    /// next item after a request's answer and the banner offers Undo; the answer is sent once the banner's time is up. An answer held already
    /// is sent at once, so only the newest waits.
    private func hold(_ action: ControlAction, of sheet: ConsequenceSheet) {
        sendHeldNow()
        inboxSheet = nil
        answeredItems.insert(sheet.itemID)
        if sheet.selectsNext(after: sheet.expectedOutcome) { inboxSelection = inboxList?.neighbor(of: sheet.itemID)?.id }
        let banner = sheet.heldBanner
        showBanner(banner)
        let wait = Task { [weak self] in
            try? await Task.sleep(for: .seconds(InboxBanner.duration))
            guard !Task.isCancelled else { return }
            self?.sendHeldNow()
        }
        held = (sheet, action, banner.id, wait)
    }

    /// Sends the answer the app holds, if any, without waiting for the banner's time: when its time is up, when
    /// another answer is held, and when the window closes or the app quits. Its banner then says how it went, unless
    /// another banner took its place; a failure always shows, and keeps the picks to send again.
    @discardableResult
    func sendHeldNow() -> Task<Void, Never>? {
        guard let held else { return nil }
        self.held = nil
        held.wait.cancel()
        return Task {
            let result = await onControl(held.action)
            let sheet = held.sheet
            switch result {
            case .done, .moved:
                inboxPicks.clear(sheet.itemID)
                if inboxBanner == nil || inboxBanner?.id == held.bannerID {
                    showBanner(sheet.banner(after: result.moveOutcome ?? sheet.expectedOutcome))
                }
                answerSent(sheet.identifier)
            case let .failed(message):
                answeredItems.remove(sheet.itemID)
                answerFailures[sheet.identifier] = message
                showBanner(.failed(itemID: sheet.itemID, identifier: sheet.identifier, message: message))
            }
            client.refresh()
        }
    }

    /// Undo on the banner: takes the move back, and selects the item again. An answer the app still holds is
    /// never sent.
    func undo(_ banner: InboxBanner) {
        guard banner.undo else { return }
        dismissBanner()
        if let held, held.bannerID == banner.id {
            held.wait.cancel()
            self.held = nil
            answeredItems.remove(banner.itemID)
            inboxSelection = banner.itemID
            showBanner(.unsent(itemID: banner.itemID, identifier: banner.identifier))
            return
        }
        Task {
            switch await onControl(.undo(banner.identifier)) {
            case .done, .moved:
                // The answer was taken back: the Question stays, and the page's Send turns on again.
                answeredItems.remove(banner.itemID)
                inboxSelection = banner.itemID
                showBanner(.undone(itemID: banner.itemID, identifier: banner.identifier))
            case let .failed(message):
                showBanner(.failed(itemID: banner.itemID, identifier: banner.identifier, message: message))
            }
            client.refresh()
        }
    }

    func dismissBanner() {
        bannerTask?.cancel()
        inboxBanner = nil
    }

    func showBanner(_ banner: InboxBanner) {
        bannerTask?.cancel()
        inboxBanner = banner
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: banner.announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(InboxBanner.duration))
            guard !Task.isCancelled, let self, inboxBanner?.id == banner.id else { return }
            inboxBanner = nil
        }
    }

    /// Acts on a review's button.
    func perform(_ action: InboxAction) {
        switch action {
        case let .openInLinear(url), let .openPR(url), let .editInLinear(url):
            onOpenURL(url)
        case let .copySteps(text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// Reads the Inbox; Symphony serves it from what it cached on its last poll, so this costs no Linear request.
    private func readInbox() {
        guard !readingInbox, state.countsKnown else { return }
        readingInbox = true
        Task {
            let result = await client.get(InboxPayload.path)
            if case let .loaded(data) = result, let payload = InboxPayload.decode(data)?.withPauses(fromState: client.stateJSON) {
                showDepartures(from: inbox?.items ?? [], to: payload.items)
                inbox = payload
                inboxResult = nil
                openPendingSheet()
            } else {
                inboxResult = result
            }
            readingInbox = false
        }
    }

    /// Sends `action`, then reads Symphony's state again so the view follows.
    func send(_ action: ControlAction) {
        guard controlInFlight == nil else { return }
        controlInFlight = action
        Task {
            let result = await onControl(action)
            controlInFlight = nil
            if case let .failed(message) = result { SymphonyRunner.showAlert(title: message, body: "") }
            client.refresh()
        }
    }

    /// Acts on a Needs attention row's button.
    func perform(_ fix: Overview.Fix) {
        switch fix {
        case let .open(identifier):
            openTicket(identifier)
        case let .openInLinear(url):
            onOpenURL(url)
        case let .stopRun(identifier):
            openStopRun(identifier, origin: .needsAttention)
        case .openDiagnostics:
            show(.diagnostics)
        case .openUsage:
            showUsage()
        case let .stopForcing(identifier):
            stopForcing(identifier)
        case let .checkNow(identifier):
            checkNow(identifier)
        case let .openTicket(identifier):
            openTicket(identifier)
        case .openSetup:
            show(.setup)
        case .restartRelay:
            restartRelay()
        }
    }

    /// Check Now (S15, S17): the ticket's watcher reads and decides at once; its answer shows on the ticket's page
    /// straight away, and the state and the page are read again.
    func checkNow(_ identifier: String) {
        guard !checkingNow.contains(identifier) else { return }
        checkingNow.insert(identifier)
        Task {
            let result = await onCheckNow(identifier)
            checkingNow.remove(identifier)
            switch result {
            case let .checked(data):
                if shownTicket == identifier { ticketSources.check = data }
            case let .failed(message):
                SymphonyRunner.showAlert(title: message, body: "")
            }
            client.refresh()
            readTicket()
        }
    }

    /// Open in Inbox on the ticket's PR and CI card: the drawer on the ticket's item, over the page.
    func openInInbox(_ identifier: String) {
        guard let id = inbox?.items.first(where: { $0.identifier == identifier })?.id else { return showInbox() }
        reviewInDrawer(id)
    }

    /// S16: a watcher's decision that left the Inbox by itself says why in the banner, once.
    private func showDepartures(from previous: [InboxItem], to current: [InboxItem]) {
        let banners = WatcherDeparture.banners(previous: previous, current: current, answered: answeredItems, watches: watchState.watches)
        answeredItems.subtract(previous.map(\.id).filter { id in !current.contains { $0.id == id } })
        if let banner = banners.first, selection == .overview && !showsPage || inboxDrawerShown { showBanner(banner) }
    }

    /// Opens Usage and reads its slice at once.
    func showUsage() {
        show(.usage)
        aggregateRead.expire()
        readAggregateIfDue()
    }

    /// Symphony's UTC day, which the Insights presets end on: its state's clock, else the Mac's.
    var insightsToday: String { Insights.today(overviewState?.generatedAt ?? Date()) }

    /// The read of the slice under the window's scope.
    var aggregateReadPath: String { insightsSlice.path(today: insightsToday, scope: scope) }

    /// What the Insights pages show for the slice: its answer, its failure, or that it is reading.
    var aggregateShown: AggregateRead.Shown { aggregateRead.shown(aggregateReadPath) }

    /// Try Again on a failed read: reads the slice again at once.
    func readAggregateAgain() {
        aggregateRead.expire()
        readAggregateIfDue()
    }

    /// Whether an Insights page shows.
    private var showsInsights: Bool { [.quality, .usage, .shipped].contains(selection) && !showsPage }

    /// The slice or the scope changed: the three pages read it again.
    private func insightsSliceChanged() {
        aggregateRead.expire()
        readAggregateIfDue()
        qualityReview.expire()
        readQualityIfDue()
        shippedReadAt = nil
        readShippedIfDue()
    }

    /// The control bar's repos and epics: the repos Symphony has tickets in and the epics it lists, with those picked.
    var insightsValues: InsightsControlValues {
        InsightsControlValues(
            repos: overviewState?.repos ?? [], epics: initiatives?.initiatives.map(\.identifier) ?? [], slice: insightsSlice
        )
    }

    /// Reads the slice while an Insights page shows: one read for Quality, Usage and Shipped, so a page switch reads
    /// nothing. Symphony answers from its run records and events, with no Linear request.
    /// The run records and events it comes from change slowly, so a slice is read again at most once per
    /// `historyInterval`, a failing one too.
    private func readAggregateIfDue() {
        let path = aggregateReadPath
        guard showsInsights, !readingAggregate, state.countsKnown,
            aggregateRead.isDue(path, now: Date(), interval: Self.historyInterval)
        else { return }
        readingAggregate = true
        Task {
            let result = await client.get(path)
            aggregateRead.record(path, result, now: Date())
            readingAggregate = false
            if path != aggregateReadPath { readAggregateIfDue() }
        }
    }

    /// The reads of Quality's review for the slice shown.
    private var qualityReviewReads: (history: String, runs: String) { QualityReviewRead.key(insightsSlice, today: insightsToday) }

    /// What Quality's review cards show for the slice: its review, its failure, or that it is reading.
    var qualityReviewShown: QualityReview { qualityReview.shown(QualityReviewRead.key(qualityReviewReads)) }

    /// Try Again on a failed review read: reads it again at once.
    func readQualityAgain() {
        qualityReview.expire()
        readQualityIfDue()
    }

    /// Reads Quality's review history and runs while Quality shows, for the slice's days. A slice is read again at
    /// most once per `historyInterval`, a failing one too.
    private func readQualityIfDue() {
        let reads = qualityReviewReads
        let key = QualityReviewRead.key(reads)
        guard selection == .quality, !showsPage, !readingQuality, state.countsKnown,
            qualityReview.isDue(key, now: Date(), interval: Self.historyInterval)
        else { return }
        readingQuality = true
        Task {
            let history = await client.get(reads.history)
            var runs: EndpointResult?
            if case .loaded = history { runs = await client.get(reads.runs) }
            qualityReview.record(key, history: history, runs: runs, now: Date())
            readingQuality = false
            if key != QualityReviewRead.key(qualityReviewReads) { readQualityIfDue() }
        }
    }

    /// Change Review…: the Repos window on `repoKey`'s Review sheet, where its manual review is.
    func changeReview(_ repoKey: String) {
        onOpenRepos(repoKey)
    }

    private func readReposIfDue() {
        guard !readingRepos, reposReadAt.map({ Date().timeIntervalSince($0) >= Self.reposInterval }) ?? true else { return }
        readingRepos = true
        Task {
            let result = await client.get(ReposAPI.path)
            repos = ReposAPI.poll(result)
            reposReadAt = Date()
            readingRepos = false
        }
    }

    /// Shows `view`: Repos and Settings open their windows and the selection stays where it was.
    func show(_ view: SymphonyView) {
        switch view {
        case .repos:
            onOpenRepos(nil)
        case .settings:
            onAction(.openSettings)
        default:
            selection = view
            history.visit(.view(view))
        }
    }

    /// ⌘1 to ⌘5 and the sidebar's rows: the destination on the page it showed last this session, else its first.
    func show(_ destination: Destination) {
        show(destinationMemory.page(for: destination))
    }

    /// The destination shown, which the sidebar selects; a page pushed over it keeps it.
    var destination: Destination { selection.destination }

    /// C1's badge on `destination` (TP-1455): Home's what waits on you, Work's epics waiting on a person (TP-1458),
    /// Factory's setup problems; unknown counts hide it.
    func badge(_ destination: Destination) -> DestinationBadge? {
        let epicsWaiting = state.countsKnown ? InitiativesList.waitingOnPerson(initiatives?.initiatives ?? []) : 0
        return destination.badge(waitingOnYou: inboxBadge, setup: setupSummary, epicsWaiting: epicsWaiting)
    }

    /// ⌘F: the Find a Ticket sheet, from any page.
    func findTicket() {
        ticketFinderShown = true
    }

    /// Return in Find a Ticket: the best match's page, pushed over the page the sheet opened on, so Back returns to it.
    func openFound(_ query: String) {
        guard let identifier = TicketFinder.target(query, in: allTickets) else { return }
        ticketFinderShown = false
        openTicket(identifier)
    }

    /// The toolbar's title: the destination's or the page's, the ticket's identifier on its page, or "#448 · <title>"
    /// on a pull request's.
    var toolbarTitle: String { shownTicket ?? pullRequestScreen?.title ?? selection.toolbarTitle }

    /// The toolbar's line under the title: the view's, the ticket's title on its page, or "<repo> · for <ticket>" on a
    /// pull request's.
    var toolbarSubtitle: String {
        if let screen = pullRequestScreen { return screen.subtitle }
        guard shownTicket != nil else { return selection.subtitle }
        return ticketPage?.title ?? "Ticket"
    }

    /// The status bar's health line (TP-1454): the build that answers and whether Symphony does.
    var healthLine: HealthLine {
        HealthLine(
            window: state, dispatch: dispatchControl, build: client.diagnostics?.build, appVersion: appVersion,
            lastUpdate: client.lastUpdate
        )
    }

    /// Copies the last state payload to the clipboard.
    func copyStateJSON() {
        guard let text = client.stateJSONText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The Symphony window: a sidebar of views, the selected view, a toolbar with its title and Refresh, and the status
/// bar with the dispatch control and the factory's health (TP-1454).
struct SymphonyWindowView: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient

    init(model: SymphonyWindowModel) {
        self.model = model
        client = model.client
    }

    /// The sidebar, shown unless the Inbox's drawer needs its room (TP-1454).
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// True while the sidebar is folded for the drawer, so closing the drawer, or widening the window, brings it back;
    /// a sidebar the Director folded stays folded.
    @State private var sidebarFoldedForDrawer = false
    @State private var windowWidth: Double = DesignTokens.Layout.windowWidth

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SymphonySidebar(model: model, client: client)
                .navigationSplitViewColumnWidth(
                    min: DesignTokens.Layout.minSidebarWidth,
                    ideal: DesignTokens.Layout.sidebarWidth,
                    max: DesignTokens.Layout.maxSidebarWidth
                )
        } detail: {
            // The status bar under the page, in the layout rather than an inset, so nothing on the page (the decision
            // banner, the drawer) is drawn under it: one line of the factory's health, and the dispatch control
            // (TP-1454).
            VStack(spacing: 0) {
                SymphonyDetail(model: model, client: client)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DesignTokens.Surface.window.color)
                WindowStatusBar(model: model, client: client)
            }
                .modifier(StopRunSheetPresenter(model: model))
                .modifier(MoveSheetPresenter(model: model))
                .modifier(DispatchSheetsPresenter(model: model))
                .sheet(isPresented: $model.ticketFinderShown) {
                    TicketFinderSheet(model: model)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        // P10: ⌘[ and ⌘] between the views and the ticket pages shown.
                        ControlGroup {
                            Button(action: model.goBack) { Label(NavigationHistory.backTitle, systemImage: "chevron.left") }
                                .disabled(!model.canGoBack)
                                .help("Back (⌘[)")
                            Button(action: model.goForward) { Label(NavigationHistory.forwardTitle, systemImage: "chevron.right") }
                                .disabled(!model.history.canGoForward)
                                .help("Forward (⌘])")
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(model.toolbarTitle).font(.headline).lineLimit(1)
                            HStack(spacing: DesignTokens.Space.s1) {
                                Text(model.toolbarSubtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                // D15 reading: the spinner in the subtitle, over its placeholder cards.
                                if model.pullRequestScreen?.isLoading == true {
                                    ProgressView().controlSize(.mini).accessibilityLabel(PullRequestScreen.readingTitle)
                                }
                            }
                        }
                        // A pull request's long title is cut short here, so the window's items stay out of the
                        // toolbar's overflow; its page's header shows it whole.
                        .frame(maxWidth: DesignTokens.Layout.toolbarTitleMaxWidth, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                    ToolbarItem(placement: .automatic) {
                        ScopePicker(model: model)
                    }
                    ToolbarItem(placement: .automatic) {
                        // ⌘F from any page (TP-1455).
                        Button { model.findTicket() } label: {
                            Label(TicketFinder.title, systemImage: "magnifyingglass")
                        }
                        .help("\(TicketFinder.title) (⌘F)")
                    }
                    if model.selection == .shipped, !model.showsPage {
                        ToolbarItem(placement: .principal) {
                            Picker("Shipped or Learnings", selection: $model.shippedTab) {
                                ForEach(Shipped.Tab.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                    }
                    if model.selection == .audit, !model.showsPage {
                        ToolbarItem(placement: .automatic) {
                            Button { model.exportAudit() } label: {
                                Label(Audit.exportTitle, systemImage: "square.and.arrow.up")
                            }
                            .help("Export the filtered records as NDJSON")
                            .disabled(model.auditExporting || model.auditRecords == nil)
                        }
                    }
                    if model.selection == .tickets, !model.showsPage {
                        ToolbarItem(placement: .automatic) {
                            Button { model.openForceSheet() } label: {
                                Label(DispatchControl.forceTitle, systemImage: DesignTokens.Status.forced.symbol)
                            }
                            .help("Force a ticket (⇧⌘F)")
                            .disabled(!model.dispatchControl.canForce)
                        }
                    }
                    if model.presentsInboxDrawer, model.state == .connected {
                        ToolbarItem(placement: .primaryAction) {
                            // The Inbox's drawer, on Home and on a ticket page (TP-1454).
                            Button { model.toggleInboxDrawer() } label: {
                                Label(model.inboxDrawerShown ? HomeInbox.hideDrawerTitle : HomeInbox.showDrawerTitle, systemImage: "sidebar.trailing")
                            }
                            .help(model.selection == .overview && !model.showsPage
                                ? "\(model.inspectorTitle) (⌥⌘I)"
                                : model.inboxDrawerShown ? HomeInbox.hideDrawerTitle : HomeInbox.showDrawerTitle)
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        // On Setup, ⌘R is Check Again, with a spinner while it runs (SU3).
                        if model.showsSetupCheck {
                            Button { model.refresh() } label: {
                                if model.setupChecking {
                                    ProgressView().controlSize(.small).accessibilityLabel("Checking")
                                } else {
                                    Label(SetupPage.checkAgainTitle, systemImage: "arrow.clockwise")
                                }
                            }
                            .help("\(SetupPage.checkAgainTitle) (⌘R)")
                            .disabled(model.setupChecking)
                        } else {
                            Button {
                                model.refresh()
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .help("Refresh (⌘R)")
                        }
                    }
                }
        }
        .onGeometryChange(for: Double.self) { $0.size.width } action: { width in
            windowWidth = width
            fitDrawer()
        }
        .onChange(of: model.inboxDrawerShown) { fitDrawer() }
        .onChange(of: model.presentsInboxDrawer) { fitDrawer() }
    }

    /// Folds the sidebar while the drawer is open in a window too narrow for the sidebar, the page and the drawer, so
    /// neither the sidebar nor the drawer's Close is pushed off the window's edge; unfolds it once there is room.
    private func fitDrawer() {
        if HomeInbox.drawerFoldsSidebar(
            windowWidth: windowWidth, drawerShown: model.inboxDrawerShown && model.presentsInboxDrawer
        ) {
            guard columnVisibility != .detailOnly else { return }
            columnVisibility = .detailOnly
            sidebarFoldedForDrawer = true
        } else if sidebarFoldedForDrawer {
            columnVisibility = .all
            sidebarFoldedForDrawer = false
        }
    }
}

/// C3: the scope pop-up, all repos or one of the repos Symphony has tickets in.
struct ScopePicker: View {
    @ObservedObject var model: SymphonyWindowModel

    var body: some View {
        Picker(selection: $model.scope) {
            ForEach(OverviewScope.choices(repos: model.overviewState?.repos ?? [], current: model.scope), id: \.self) { scope in
                Text(scope.title).tag(scope)
            }
        } label: {
            Label("Scope", systemImage: SymphonyView.repos.symbol)
        }
        .pickerStyle(.menu)
        .help("Show all repos or one")
        .accessibilityLabel(model.scope.accessibilityLabel)
    }
}

/// The sidebar: the five destinations, Factory with its pages under it (TP-1455). Symphony's version and state are in
/// the status bar (TP-1454).
struct SymphonySidebar: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient

    var body: some View {
        List(selection: selection) {
            ForEach(model.sidebar.items, id: \.self) { item in
                switch item {
                case let .destination(destination):
                    SidebarRowContent(title: destination.title, symbol: destination.symbol, badge: model.badge(destination))
                        .help(destination.shortcutHelp)
                        .tag(item)
                case let .page(page):
                    SidebarRowContent(title: page.title, symbol: page.symbol, badge: nil, indented: true)
                        .help(page.opensOwnWindow ? "Opens the \(page.title) window" : page.title)
                        .tag(item)
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// The list's selection: a destination opens on its last page, Repos and Settings open their windows instead of
    /// being selected.
    private var selection: Binding<SidebarItem?> {
        Binding(
            // On a page no row is selected, so choosing the destination the page came from goes back to it.
            get: { model.showsPage ? nil : model.sidebar.item(for: model.selection) },
            set: { item in
                switch item {
                case let .destination(destination): model.show(destination)
                case let .page(page): model.show(page)
                case nil: break
                }
            }
        )
    }
}

/// A row of the sidebar: its label, and C1's count when it has one. One VoiceOver element: "Home, 4 waiting".
struct SidebarRowContent: View {
    let title: String
    let symbol: String
    let badge: DestinationBadge?
    var indented = false

    var body: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            Label(title, systemImage: symbol)
            Spacer(minLength: 0)
            if let badge {
                SidebarBadge(count: badge.count, tint: badge.status.tint)
            }
        }
        .padding(.leading, indented ? DesignTokens.Space.s4 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityValue(badge?.accessibilityValue ?? "")
    }
}

/// C1's count: a filled capsule in the view's status colour (`.badge` ignores the tint in a sidebar).
struct SidebarBadge: View {
    let count: Int
    let tint: Color

    var body: some View {
        Text("\(count)")
            .font(DesignTokens.TypeStyle.callout.font.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 16)
            .background(tint, in: Capsule())
            .accessibilityHidden(true)
    }
}

/// The selected view, or the one placeholder every view shows while Symphony can't serve it (D0).
struct SymphonyDetail: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient

    var body: some View {
        if let placeholder = model.state.placeholder {
            EmptyState(
                title: placeholder.title,
                symbol: placeholder.symbol,
                actions: placeholder.actions.map { action in (action.title, { model.onAction(action) }) },
                showsSpinner: placeholder.showsSpinner
            )
        } else if model.shownTicket != nil {
            TicketPageContent(model: model, client: client)
        } else if model.shownPullRequest != nil {
            PullRequestPageContent(model: model)
        } else {
            VStack(spacing: 0) {
                if model.destination.presentation == .tabs {
                    DestinationTabs(model: model)
                }
                // The page takes the rest of the height, so the tabs stay at the top over a page that isn't full
                // (an empty state centres in the space under them).
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder private var page: some View {
        switch model.selection {
        case .inbox, .overview:
            // The Inbox is Home's drawer (TP-1454).
            OverviewContent(model: model, client: client)
        case .initiatives:
            InitiativesContent(model: model, client: client)
        case .tickets:
            TicketsContent(model: model, client: client)
        case .diagnostics:
            DiagnosticsContent(model: model, client: client)
        case .usage:
            UsageContent(model: model, client: client)
        case .quality:
            QualityContent(model: model)
        case .shipped:
            ShippedContent(model: model)
        case .audit:
            AuditContent(model: model)
        case .setup:
            SetupContent(model: model)
        case .journal:
            JournalContent(model: model)
        default:
            EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
        }
    }
}

/// Work's and Insights' tabs over the page (TP-1455): a tab shows its page as it was, and the destination remembers it.
struct DestinationTabs: View {
    @ObservedObject var model: SymphonyWindowModel

    var body: some View {
        VStack(spacing: 0) {
            Picker(model.destination.title, selection: Binding(get: { model.selection }, set: { model.show($0) })) {
                ForEach(model.destination.pages) { page in
                    Text(page.title).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, DesignTokens.Space.s2)
            .accessibilityLabel("\(model.destination.title) tabs")
            Divider()
        }
        .frame(maxWidth: .infinity)
    }
}

/// D1: Home, what waits on the Director on top (TP-1454), then the board of every open ticket Symphony works, from
/// `/api/v1/state`'s dispatch order under the window's scope. The Inbox's review is its drawer, its moves ask with
/// the Inbox's consequence sheets, and the banner after one sits under the page.
struct OverviewContent: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient

    var body: some View {
        if let state = model.overviewWithSetup {
            VStack(spacing: 0) {
                HomeView(
                    board: HomeBoard(state: state, scope: model.scope, updating: model.updateHold != nil, now: Date()),
                    actions: HomeActions(
                        resume: { model.send(.resume) },
                        tryNow: { model.send(.tryNow(condition: $0.condition)) },
                        controlInFlight: model.controlInFlight,
                        openTicket: model.openTicket
                    ),
                    inbox: model.homeInbox,
                    inboxActions: model.homeInboxActions,
                    now: model.overviewState?.generatedAt ?? Date()
                )
                if let banner = model.inboxBanner {
                    InboxBannerView(banner: banner, undo: { model.undo(banner) }, close: model.dismissBanner)
                        .padding(DesignTokens.Space.s3)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.default, value: model.inboxBanner)
            .modifier(InboxDrawerPresenter(model: model))
            .modifier(InboxSheetPresenter(model: model))
        } else if client.stateResult == .unsupported {
            EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
        } else {
            EmptyState(title: HomeBoard.readingOrder, symbol: SymphonyView.overview.symbol, showsSpinner: true)
        }
    }
}

/// D11: Symphony's own health, from `/api/v1/state`.
struct DiagnosticsContent: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient

    var body: some View {
        if let payload = client.diagnostics {
            DiagnosticsView(
                report: DiagnosticsReport(payload: payload, apiURL: model.apiURL(), lastUpdate: client.lastUpdate),
                actions: DiagnosticsView.Actions(
                    copyStateJSON: model.copyStateJSON,
                    openLogs: model.canOpenLogs() ? { model.onAction(.openLogs) } : nil
                )
            )
        } else if client.stateResult == .unsupported {
            EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
        } else {
            EmptyState(title: "Reading Symphony's state…", symbol: "stethoscope", showsSpinner: true)
        }
    }
}

/// Diagnostics' groups as cards of label and value rows, under its actions.
struct DiagnosticsView: View {
    struct Actions {
        var copyStateJSON: () -> Void
        /// Nil while the action can't be taken, which disables its button.
        var openLogs: (() -> Void)?
    }

    let report: DiagnosticsReport
    let actions: Actions

    var body: some View {
        ScrollView {
            DiagnosticsCards(report: report, actions: actions)
        }
    }
}

/// Diagnostics' actions and cards, outside the scroll view so they also render offscreen.
struct DiagnosticsCards: View {
    let report: DiagnosticsReport
    let actions: DiagnosticsView.Actions

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            HStack(spacing: DesignTokens.Space.s2) {
                Spacer()
                Button("Copy State JSON", action: actions.copyStateJSON)
                Button(StatusMenu.openLogsTitle) { actions.openLogs?() }
                    .disabled(actions.openLogs == nil)
            }
            ForEach(report.groups, id: \.title) { group in
                Card(title: group.title) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DesignTokens.Space.s4,
                         verticalSpacing: DesignTokens.Space.s2) {
                        ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                            DiagnosticsRow(row: row)
                        }
                    }
                }
            }
        }
        .padding(DesignTokens.Space.s5)
    }
}

private struct DiagnosticsRow: View {
    let row: DiagnosticsReport.Row

    var body: some View {
        GridRow {
            Text(row.label)
                .font(row.monospacedLabel ? DesignTokens.TypeStyle.mono.font : DesignTokens.TypeStyle.body.font)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
                .frame(minWidth: 140, alignment: .leading)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1 / 2) {
                HStack(spacing: DesignTokens.Space.s2) {
                    if let status = row.status {
                        Image(systemName: status.symbol)
                            .foregroundStyle(status.tint)
                            .accessibilityLabel(status.word)
                    }
                    Text(row.value)
                        .font(row.monospacedValue ? DesignTokens.TypeStyle.mono.font : DesignTokens.TypeStyle.body.font)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .textSelection(.enabled)
                }
                if let detail = row.detail {
                    Text(detail)
                        .font(DesignTokens.TypeStyle.mono.font)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// ⌘F's Find a Ticket (TP-1455): a field that finds a tracked ticket by its identifier or title as it is typed; Return
/// opens the best match's page, or the page of the identifier typed, and Escape closes it.
struct TicketFinderSheet: View {
    @ObservedObject var model: SymphonyWindowModel
    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let matches = TicketFinder.matches(query, in: model.allTickets)
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            Text(TicketFinder.title).font(.headline)
            TextField(TicketFinder.title, text: $query, prompt: Text(TicketFinder.prompt))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .focused($fieldFocused)
                .onSubmit { model.openFound(query) }
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { row in
                        // Every row is a link to its ticket's page, with the catalog's hover (TP-1438).
                        Button { model.openFound(row.identifier) } label: {
                            Text(TicketFinder.line(row))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, DesignTokens.Space.s1)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .rowStyle()
                        .accessibilityLabel(row.accessibilityLabel(reference: model.allTickets?.reference ?? Date()))
                    }
                }
            } else if !query.trimmingCharacters(in: .whitespaces).isEmpty, TicketFinder.target(query, in: model.allTickets) == nil {
                Text(TicketFinder.noMatch).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.ticketFinderShown = false }
                    .keyboardShortcut(.cancelAction)
                Button(TicketFinder.openTitle) { model.openFound(query) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(TicketFinder.target(query, in: model.allTickets) == nil)
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(width: 420)
        .onAppear { fieldFocused = true }
    }
}
