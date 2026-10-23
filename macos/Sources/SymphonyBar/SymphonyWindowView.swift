import AppKit
import Combine
import SwiftUI
import SymphonyBarCore

/// What the Symphony window shows, refreshed by its controller.
@MainActor
final class SymphonyWindowModel: ObservableObject {
    let sidebar = Sidebar()
    let client: LiveAPIClient

    /// The view shown; Repos never is, as it opens its own window.
    @Published var selection: SymphonyView {
        didSet {
            guard selection != oldValue else { return }
            onSelect(selection)
            readHistoryIfDue()
            readQualityIfDue()
            readShippedIfDue()
            readAuditIfDue()
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
    /// The screenshots the ticket page shows, read through `client` and kept by artifact id.
    let artifactImages: ArtifactImages
    /// The note field under the ticket page: what is typed, the note on its way, why the last one wasn't added.
    let ticketNote = TicketNoteComposer()
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
            // Audit asks Symphony for the scope's records.
            auditReadAt = nil
            readAuditIfDue()
        }
    }
    /// The control request a view sent and Symphony hasn't answered yet.
    @Published private(set) var controlInFlight: ControlAction?
    /// The last Inbox Symphony served, read again after each state poll.
    @Published private(set) var inbox: InboxPayload?
    /// What the last Inbox read got when it got no Inbox, nil after one that did.
    @Published private(set) var inboxResult: EndpointResult?
    /// The Inbox item shown, by issue id; nil shows the first.
    @Published var inboxSelection: String?
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
    /// The last history Symphony served, for Usage; read while Usage shows.
    @Published private(set) var usageHistory: HistoryPayload?
    /// What the last history read got when it got none, nil after one that did.
    @Published private(set) var historyResult: EndpointResult?
    /// The history and runs of Quality's period, read while Quality shows.
    @Published private(set) var quality: (history: HistoryPayload, runs: [QualityRun])?
    /// What the last Quality read got when it got none, nil after one that did.
    @Published private(set) var qualityResult: EndpointResult?
    /// Quality's period; changing it reads again.
    @Published var qualityPeriod: Quality.Period = .month {
        didSet {
            guard qualityPeriod != oldValue else { return }
            qualityReadAt = nil
            readQualityIfDue()
        }
    }
    /// Shipped's merged tickets for its period, read while Shipped shows (D9).
    @Published var shipped: ShippedPayload?
    /// What the last Shipped read got when it got none, nil after one that did.
    @Published var shippedResult: EndpointResult?
    /// Every stored learning, read while Shipped shows, for its Learnings tab.
    @Published var learnings: LearningsPayload?
    @Published var learningsResult: EndpointResult?
    /// Shipped's segmented control: Shipped or Learnings.
    @Published var shippedTab: Shipped.Tab = .shipped
    /// Shipped's period; changing it reads again.
    @Published var shippedPeriod: Shipped.Period = .week {
        didSet {
            guard shippedPeriod != oldValue else { return }
            shippedReadAt = nil
            readShippedIfDue()
        }
    }
    /// The Learnings tab's repo and tag filters and search.
    @Published var learningsFilter = Learnings.Filter()
    /// Set by ⌘F on Shipped to put the focus in the Learnings search field.
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
    /// Set by ⌘F on Audit to put the focus in its search field.
    @Published var auditSearchRequested = false
    /// True while Export… reads the records; what went wrong with it, shown under the filters.
    @Published var auditExporting = false
    @Published var auditExportError: String?
    /// The initiative shown, by issue id; nil shows the first.
    @Published var initiativeSelection: String?
    /// The views and ticket pages shown, for ⌘[ and ⌘] (P10); its current place is what the window shows.
    @Published var history: NavigationHistory
    /// What the ticket page shown last read from its own endpoints; the state comes from the client's poll.
    @Published var ticketSources = TicketPage.Sources()
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
    /// Stops made from the app, shown on the timeline until their audit record arrives.
    @Published var localStops: [TicketPage.LocalStop] = []
    /// Tickets' scope bar choice, search and selected row (D6).
    @Published var ticketFilter: TicketList.Filter = .all
    @Published var ticketSearch = ""
    @Published var ticketSelection: String?
    /// Tickets' inspector (⌥⌘I, Space).
    @Published var inspectorShown = true
    /// Set by ⌘F to put the focus in Tickets' search field.
    @Published var searchRequested = false
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
    /// Opens the transcript window of (identifier, repo key); `newWindow` (⌘-click) opens another beside it.
    var onOpenTranscript: (_ identifier: String, _ repoKey: String?, _ newWindow: Bool) -> Void = { _, _, _ in }

    /// The repos are read again at most this often: Symphony reads each checkout's remote to answer.
    static let reposInterval: TimeInterval = 30
    private var reposReadAt: Date?
    private var readingRepos = false
    private var readingInbox = false
    private var readingInitiatives = false
    private var readingHistory = false
    /// When the history was last read; the run records it comes from change slowly.
    private var historyReadAt: Date?
    private var readingQuality = false
    private var qualityReadAt: Date?
    /// The history is read again at most this often.
    static let historyInterval: TimeInterval = 60
    var readingShipped = false
    /// When Shipped and Learnings were last read; the run records they come from change slowly.
    var shippedReadAt: Date?
    var readingAudit = false
    /// When Audit was last read.
    var auditReadAt: Date?
    var readingTicket = false
    /// When the ticket page last read its runs and audit records, which change slowly.
    var ticketSlowReadAt: Date?
    /// The runs and audit records are read again at most this often.
    static let ticketSlowInterval: TimeInterval = 10
    private var bannerTask: Task<Void, Never>?
    /// An answer the app holds for the banner's Undo before it sends it (`ConsequenceSheet.holdsForUndo`), with the
    /// banner that offers the Undo and the wait that sends it.
    private var held: (sheet: ConsequenceSheet, action: ControlAction, bannerID: UUID, wait: Task<Void, Never>)?
    /// Whether an answer waits for the banner's Undo, still to send.
    var holdsAnswer: Bool { held != nil }
    /// The Inbox items the Director answered, by issue id: they leave the Inbox without a banner of their own.
    private var answeredItems = Set<String>()
    /// The tickets a Check Now is on its way for.
    @Published private(set) var checkingNow = Set<String>()
    /// A sheet to open once the Inbox lists its item: Approve and Merge… chosen on a notification.
    private var pendingSheet: (id: String, move: InboxMove)?
    private var cancellables = Set<AnyCancellable>()

    init(client: LiveAPIClient, eventStream: EventStream, selection: SymphonyView) {
        self.client = client
        self.eventStream = eventStream
        self.selection = selection
        ticketFeed = TicketEventsReader(get: { [client] path in TicketEventsResult(await client.answer(path)) })
        artifactImages = ArtifactImages(get: { [client] path in await client.answer(path) })
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
                readHistoryIfDue()
                readQualityIfDue()
                readShippedIfDue()
                readAuditIfDue()
                readTicket()
                followTicketFeed(afterPoll: true)
                readPeek()
            }
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

    /// The Overview item's badge: what needs attention in every repo, whatever the scope; 0 hides it, as do
    /// unknown counts.
    var attentionBadge: Int {
        guard state.countsKnown, let overviewState = overviewWithSetup else { return 0 }
        return Overview.badgeCount(overviewState, now: Date())
    }

    /// The Inbox item's badge: what waits on the Director in every repo, whatever the scope (P6), from the same
    /// list as the menu and the Overview's tile; 0 hides it, as do unknown counts.
    var inboxBadge: Int {
        guard state.countsKnown, let overviewState else { return 0 }
        return overviewState.snapshot.waitingOnYou.count
    }

    /// Opens the Inbox on the item with issue id `id`, or on its first item.
    func showInbox(selecting id: String? = nil) {
        if let id { inboxSelection = id }
        show(.inbox)
        readInbox()
    }

    /// Opens Initiatives on the initiative with issue id `id`.
    func showInitiative(_ id: String) {
        initiativeSelection = id
        show(.initiatives)
        readInitiatives()
    }

    /// The Initiatives under the window's scope.
    var initiativesList: InitiativesList? {
        initiatives.map { InitiativesList(initiatives: $0.initiatives, scope: scope) }
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
        inboxSheet = ConsequenceSheet(move: move, item: item, picks: picks(for: item.id))
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
            case let .failed(message):
                answeredItems.remove(sheet.itemID)
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

    private func showBanner(_ banner: InboxBanner) {
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
            if case let .loaded(data) = result, let payload = InboxPayload.decode(data) {
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

    /// Open in Inbox on the ticket's PR and CI card: the Inbox, on the ticket's item.
    func openInInbox(_ identifier: String) {
        showInbox(selecting: inbox?.items.first { $0.identifier == identifier }?.id)
    }

    /// S16: a watcher's decision that left the Inbox by itself says why in the banner, once.
    private func showDepartures(from previous: [InboxItem], to current: [InboxItem]) {
        let banners = WatcherDeparture.banners(previous: previous, current: current, answered: answeredItems, watches: watchState.watches)
        answeredItems.subtract(previous.map(\.id).filter { id in !current.contains { $0.id == id } })
        if let banner = banners.first, selection == .inbox, !showsPage { showBanner(banner) }
    }

    /// Opens Usage and reads the history at once.
    func showUsage() {
        show(.usage)
        historyReadAt = nil
        readHistoryIfDue()
    }

    /// Reads the history while Usage shows; Symphony answers from its run records, with no Linear request.
    private func readHistoryIfDue() {
        guard selection == .usage, !showsPage, !readingHistory, state.countsKnown,
            historyReadAt.map({ Date().timeIntervalSince($0) >= Self.historyInterval }) ?? true
        else { return }
        readingHistory = true
        Task {
            let result = await client.get(HistoryPayload.path(days: HistoryPayload.defaultDays))
            if case let .loaded(data) = result, let payload = HistoryPayload.decode(data) {
                usageHistory = payload
                historyResult = nil
            } else {
                historyResult = result
            }
            historyReadAt = Date()
            readingHistory = false
        }
    }

    /// Reads Quality's history and runs while Quality shows, for its period.
    private func readQualityIfDue() {
        guard selection == .quality, !showsPage, !readingQuality, state.countsKnown,
            qualityReadAt.map({ Date().timeIntervalSince($0) >= Self.historyInterval }) ?? true
        else { return }
        readingQuality = true
        let period = qualityPeriod
        Task {
            let result = await client.get(HistoryPayload.path(days: period.rawValue))
            if case let .loaded(data) = result, let history = HistoryPayload.decode(data) {
                let from = history.tokensPerDay.first?.date ?? ""
                let runsResult = await client.get(QualityRun.path(from: from))
                let runs = if case let .loaded(data) = runsResult { QualityRun.decode(data) ?? [] } else { [QualityRun]() }
                if period == qualityPeriod {
                    quality = (history, runs)
                    qualityResult = nil
                }
            } else {
                qualityResult = result
            }
            qualityReadAt = period == qualityPeriod ? Date() : nil
            readingQuality = false
            if qualityReadAt == nil { readQualityIfDue() }
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

    /// Shows `view`: Repos opens its window and the selection stays where it was.
    func show(_ view: SymphonyView) {
        if view.opensOwnWindow {
            onOpenRepos(nil)
        } else {
            selection = view
            history.visit(.view(view))
        }
    }

    /// The toolbar's title: the view's, the ticket's identifier on its page, or "#448 · <title>" on a pull request's.
    var toolbarTitle: String { shownTicket ?? pullRequestScreen?.title ?? selection.title }

    /// The toolbar's line under the title: the view's, the ticket's title on its page, or "<repo> · for <ticket>" on a
    /// pull request's.
    var toolbarSubtitle: String {
        if let screen = pullRequestScreen { return screen.subtitle }
        guard shownTicket != nil else { return selection.subtitle }
        return ticketPage?.title ?? "Ticket"
    }

    /// The sidebar footer's first line: Symphony's state, on its own so the sidebar never cuts it off.
    var footerState: String { state.stateWord(paused: paused) }

    /// The sidebar footer's second line: Symphony and its version.
    var footerVersion: String {
        let version = state == .connected ? client.diagnostics?.build?.version ?? appVersion : appVersion
        return version.isEmpty ? "Symphony" : "Symphony \(version)"
    }

    /// Copies the last state payload to the clipboard.
    func copyStateJSON() {
        guard let text = client.stateJSONText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The Symphony window: a sidebar of views, the selected view, and a toolbar with its title, the connection state
/// and Refresh.
struct SymphonyWindowView: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient

    init(model: SymphonyWindowModel) {
        self.model = model
        client = model.client
    }

    var body: some View {
        NavigationSplitView {
            SymphonySidebar(model: model, client: client)
                .navigationSplitViewColumnWidth(
                    min: DesignTokens.Layout.minSidebarWidth,
                    ideal: DesignTokens.Layout.sidebarWidth,
                    max: DesignTokens.Layout.maxSidebarWidth
                )
        } detail: {
            SymphonyDetail(model: model, client: client)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DesignTokens.Surface.window.color)
                .modifier(StopRunSheetPresenter(model: model))
                .modifier(DispatchSheetsPresenter(model: model))
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
                    ToolbarItem(placement: .status) {
                        ConnectionState(state: model.state, lastUpdate: client.lastUpdate)
                    }
                    ToolbarItem(placement: .automatic) {
                        ScopePicker(model: model)
                    }
                    ToolbarItem(placement: .automatic) {
                        DispatchControlButton(model: model, client: client)
                    }
                    .sharedBackgroundVisibility(.hidden)
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
                    if model.selection == .inbox, !model.showsPage {
                        ToolbarItem(placement: .primaryAction) {
                            // N4: closes the peek, or shows it again.
                            Button { model.togglePeek() } label: {
                                Label(model.inspectorTitle, systemImage: "sidebar.trailing")
                            }
                            .help("\(model.inspectorTitle) (⌥⌘I)")
                            .disabled(!model.peek.canToggle)
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

/// The sidebar: views by section, and Symphony's version and state at the foot.
struct SymphonySidebar: View {
    @ObservedObject var model: SymphonyWindowModel
    /// Observed so the footer shows Symphony's version once its first state payload arrives.
    @ObservedObject var client: LiveAPIClient

    var body: some View {
        List(selection: selection) {
            ForEach(model.sidebar.sections, id: \.section) { group in
                Section {
                    ForEach(group.views, id: \.self) { view in
                        HStack(spacing: DesignTokens.Space.s2) {
                            Label(view.title, systemImage: view.symbol)
                            Spacer(minLength: 0)
                            if let badge = badge(view) {
                                SidebarBadge(count: badge.count, tint: badge.status.tint)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(accessibilityValue(view))
                        .help(shortcutHelp(view))
                        .tag(view)
                    }
                } header: {
                    if let title = group.section.title { Text(title) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: DesignTokens.Space.s2) {
                        Circle()
                            .fill(model.state.connectionStatus.tint)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(model.footerState)
                            .font(DesignTokens.TypeStyle.callout.font)
                    }
                    Text(model.footerVersion)
                        .font(DesignTokens.TypeStyle.caption.font)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8 + DesignTokens.Space.s2)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignTokens.Space.s4)
            .padding(.vertical, DesignTokens.Space.s2)
        }
    }

    /// The list's selection, which opens the Repos window instead of selecting it.
    private var selection: Binding<SymphonyView?> {
        Binding(
            // On a page no view is selected, so choosing the view the page came from goes back to it.
            get: { model.showsPage ? nil : model.selection },
            set: { view in
                guard let view else { return }
                model.show(view)
            }
        )
    }

    /// C1's count and its color: the Inbox's in `status.you`, the Overview's in `status.problem`, Setup's errors in
    /// `status.problem` or else its warnings in `status.you` (SU1); nil hides it.
    private func badge(_ view: SymphonyView) -> (count: Int, status: DesignTokens.Status)? {
        switch view {
        case .inbox: model.inboxBadge > 0 ? (model.inboxBadge, .you) : nil
        case .overview: model.attentionBadge > 0 ? (model.attentionBadge, .problem) : nil
        case .setup: model.setupSummary.badge
        default: nil
        }
    }

    /// C1: "Inbox, 4 waiting".
    private func accessibilityValue(_ view: SymphonyView) -> String {
        switch view {
        case .inbox where model.inboxBadge > 0: "\(model.inboxBadge) waiting"
        case .overview where model.attentionBadge > 0: "\(model.attentionBadge) need attention"
        case .setup: model.setupSummary.accessibilityValue
        default: ""
        }
    }

    private func shortcutHelp(_ view: SymphonyView) -> String {
        model.sidebar.shortcut(for: view).map { "\(view.title) (⌘\($0))" } ?? view.title
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
            switch model.selection {
            case .inbox:
                InboxContent(model: model, client: client)
            case .overview:
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
            default:
                EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
            }
        }
    }
}

/// D1: the Overview, from `/api/v1/state` and `/api/v1/repos`, under the window's scope.
struct OverviewContent: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient

    var body: some View {
        if let state = model.overviewWithSetup {
            OverviewView(
                overview: Overview(state: state, scope: model.scope, repos: model.repos, updating: model.updateHold != nil, now: Date()),
                actions: OverviewActions(
                    resume: { model.send(.resume) },
                    perform: model.perform,
                    controlInFlight: model.controlInFlight,
                    checkingNow: model.checkingNow,
                    openInbox: { model.showInbox() },
                    openTicket: model.openTicket,
                    openTickets: model.showTickets,
                    openInitiative: model.showInitiative,
                    openUsage: model.showUsage,
                    openShipped: { model.showShipped() }
                ),
                initiatives: model.initiativesList?.active ?? []
            )
        } else if client.stateResult == .unsupported {
            EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
        } else {
            EmptyState(title: "Reading Symphony's state…", symbol: SymphonyView.overview.symbol, showsSpinner: true)
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
