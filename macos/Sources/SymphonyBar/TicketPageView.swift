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
        case .ticket:
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
            readingTicket = false
            // A page left while its reads were out doesn't take them.
            guard shownTicket == identifier else { return }
            // A Check Now answer and the feed's events that came in meanwhile stay.
            sources.check = ticketSources.check
            sources.events = ticketSources.events
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

    /// The ticket's API URL on the clipboard.
    func copyAPIURL(_ page: TicketPage) {
        guard let url = apiURL()?.appendingPathComponent(page.apiPath) else { return }
        copy(url.absoluteString)
    }

    /// Opens Audit filtered to the ticket.
    func showAuditRecords(_ page: TicketPage) {
        showAudit(ticket: page.identifier)
    }

    func revealWorktree(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - D3: the ticket page

/// What the ticket page's buttons do.
struct TicketPageActions {
    var viewTranscript: (_ newWindow: Bool) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }
    var stopRun: () -> Void = {}
    var copyAPIURL: () -> Void = {}
    var showAuditRecords: () -> Void = {}
    var revealWorktree: (String) -> Void = { _ in }
    /// The ⋯ menu's Force… (the Force a Ticket sheet) and Stop Forcing.
    var force: () -> Void = {}
    var stopForcing: () -> Void = {}
    /// A click on a ticket or pull request chip in the page's text.
    var openMention: (Mention) -> Void = { _ in }
    /// The Pull request fact and the done line: the pull request's page (D15), with its link.
    var openPullRequest: (PullRequestPlace, URL?) -> Void = { _, _ in }
    /// The PR and CI card's Check Now, Open in Inbox and Open TP-x.
    var checkNow: () -> Void = {}
    var openInInbox: () -> Void = {}
    var openTicket: (String) -> Void = { _ in }
    /// True while a Check Now is on its way.
    var checking = false

    /// A pull request link of the ticket's repo: its page (D15) when it is one, else the link.
    func open(pullRequest url: URL, repoKey: String?) {
        if let place = PullRequestPlace(repoKey: repoKey, url: url) {
            openPullRequest(place, url)
        } else {
            openURL(url)
        }
    }

    /// Acts on a PR and CI card's button.
    func perform(_ button: PRWatchCard.Button) {
        switch button {
        case .checkNow: checkNow()
        case let .openPR(url), let .openPullRequest(_, url): openURL(url)
        case .openInInbox: openInInbox()
        case let .openTicket(identifier): openTicket(identifier)
        }
    }
}

/// D3 for the window: the page with its Stop Run sheet, or a placeholder while it reads.
struct TicketPageContent: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient

    var body: some View {
        if let page = model.ticketPage {
            TicketPageView(
                page: page,
                brief: model.inbox.flatMap { TicketPage.Brief(identifier: page.identifier, items: $0.items) },
                actions: TicketPageActions(
                    viewTranscript: { newWindow in model.onOpenTranscript(page.identifier, page.repoKey, newWindow) },
                    openURL: model.onOpenURL,
                    stopRun: { model.openStopRun(page.identifier, origin: .ticketPage) },
                    copyAPIURL: { model.copyAPIURL(page) },
                    showAuditRecords: { model.showAuditRecords(page) },
                    revealWorktree: model.revealWorktree,
                    force: { model.openForceSheet(page.identifier) },
                    stopForcing: { model.stopForcing(page.identifier) },
                    openMention: model.openDirectly,
                    openPullRequest: model.openPullRequest,
                    checkNow: { model.checkNow(page.identifier) },
                    openInInbox: { model.openInInbox(page.identifier) },
                    openTicket: model.openTicket,
                    checking: model.checkingNow.contains(page.identifier)
                ),
                images: model.artifactImages
            )
        } else {
            EmptyState(title: "Reading the ticket…", symbol: "doc.text.magnifyingglass", showsSpinner: true)
        }
    }
}

/// The ticket page in a scroll view, laid out for the width it gets.
struct TicketPageView: View {
    let page: TicketPage
    var brief: TicketPage.Brief?
    let actions: TicketPageActions
    /// The timeline's screenshots, read through the window's client.
    var images: ArtifactImages?
    @State private var width: CGFloat = DesignTokens.Layout.windowWidth - DesignTokens.Layout.sidebarWidth
    /// The run groups folded, by run id: they stay folded as the feed is read again.
    @State private var folded = Set<String>()
    /// The screenshot shown full size.
    @State private var fullScreenshot: TicketScreenshot?

    var body: some View {
        ScrollView {
            TicketPageBody(
                page: page, brief: brief, actions: actions, width: width, folded: $folded, images: images,
                openScreenshot: { fullScreenshot = $0 }
            )
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .sheet(item: $fullScreenshot) { shot in
            ScreenshotSheet(shot: shot, images: images, close: { fullScreenshot = nil })
        }
    }
}

/// The page's sections, outside the scroll view so they also render offscreen.
struct TicketPageBody: View {
    let page: TicketPage
    /// What the Inbox says about the ticket, when it holds it.
    var brief: TicketPage.Brief?
    let actions: TicketPageActions
    let width: CGFloat
    var folded: Binding<Set<String>> = .constant([])
    var images: ArtifactImages?
    var openScreenshot: (TicketScreenshot) -> Void = { _ in }

    static let sideColumnWidth: CGFloat = 300
    static let mainColumnMinWidth: CGFloat = 460

    private var sideBySide: Bool {
        width - 2 * DesignTokens.Space.s5 >= Self.mainColumnMinWidth + DesignTokens.Space.s4 + Self.sideColumnWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s5) {
            TicketHeader(page: page, summary: brief?.summary, actions: actions)
            let layout = sideBySide
                ? AnyLayout(HStackLayout(alignment: .top, spacing: DesignTokens.Space.s4))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: DesignTokens.Space.s4))
            layout {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
                    if let brief { BriefCards(brief: brief) }
                    if let watch = page.watch {
                        PRWatchCardView(card: watch, checking: actions.checking, perform: actions.perform)
                    }
                    if let now = page.now {
                        Card(title: "Now") { NowGrid(now: now, reveal: actions.revealWorktree) }
                    }
                    Card(title: "Timeline") {
                        if page.timeline.isEmpty {
                            Text("No runs yet.").font(DesignTokens.TypeStyle.body.font).foregroundStyle(.secondary)
                        } else {
                            RunTimeline(steps: page.timeline, folded: folded, images: images, openScreenshot: openScreenshot)
                        }
                    }
                }
                .frame(minWidth: sideBySide ? Self.mainColumnMinWidth : nil, maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
                    Card(title: "Ticket") { FactsGrid(facts: page.facts, open: { actions.open(pullRequest: $0, repoKey: page.repoKey) }) }
                    if let message = page.lastMessage {
                        Card(title: "Last message") { ChipText(text: message) }
                    }
                }
                .frame(maxWidth: sideBySide ? Self.sideColumnWidth : .infinity, alignment: .topLeading)
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // The mentions in the page's text are chips (N1) with popovers (N2, N3), read from its Inbox item.
        .environment(\.mentionReferences, brief?.references ?? [:])
        .environment(\.openMention, OpenMentionAction(handler: actions.openMention))
    }
}

/// The ticket's latest review brief and the decisions answered on it, from its Inbox item.
private struct BriefCards: View {
    let brief: TicketPage.Brief

    var body: some View {
        Card(title: brief.title) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                ForEach(Array(brief.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    ChipText(text: paragraph)
                }
            }
        }
        if !brief.decisions.isEmpty {
            Card(title: "Earlier decisions") {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                    ForEach(Array(brief.decisions.enumerated()), id: \.offset) { _, decision in
                        EarlierDecisionRow(decision: decision)
                    }
                }
            }
        }
    }
}

/// An answered request: when, what it asked, and the answer.
private struct EarlierDecisionRow: View {
    let decision: TicketContext.EarlierDecision

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                if let title = decision.title { ChipText(text: title, font: DesignTokens.TypeStyle.rowTitle.nsFont) }
                Spacer(minLength: DesignTokens.Space.s2)
                if let at = decision.at {
                    Text(at, format: .dateTime.month(.abbreviated).day())
                        .font(DesignTokens.TypeStyle.callout.font)
                        .foregroundStyle(.secondary)
                }
            }
            if let answer = decision.answer {
                ChipText(text: answer, lead: "Your answer:", color: .secondaryLabelColor)
            }
        }
    }
}

/// The identifier and title, repo, initiative and badges (C7), what it is doing, and the page's actions.
private struct TicketHeader: View {
    let page: TicketPage
    /// The ticket's Symphony status line, from the Inbox.
    let summary: String?
    let actions: TicketPageActions

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignTokens.Space.s2) {
                    badges
                    Spacer(minLength: DesignTokens.Space.s2)
                    TicketActions(page: page, actions: actions)
                }
                VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                    HStack(spacing: DesignTokens.Space.s2) { badges }
                    TicketActions(page: page, actions: actions)
                }
            }
            Text([page.identifier, page.title].compactMap { $0 }.joined(separator: " "))
                .font(DesignTokens.TypeStyle.sentence.font)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            Text(page.phaseSentence)
                .font(DesignTokens.TypeStyle.body.font)
                .foregroundStyle(.secondary)
            if let summary { ChipText(text: summary, color: .secondaryLabelColor) }
            if case let .done(pullRequest, _) = page.phase, pullRequest != nil || page.mergedText != nil {
                DoneLine(pullRequest: pullRequest, merged: page.mergedText, open: { actions.open(pullRequest: $0, repoKey: page.repoKey) })
            }
        }
    }

    @ViewBuilder private var badges: some View {
        ForEach(Array(page.badges.enumerated()), id: \.offset) { _, badge in
            StatusBadge(status: badge.status, word: badge.word).fixedSize()
        }
        if let repo = page.repoKey {
            Label(repo, systemImage: SymphonyView.repos.symbol)
                .font(DesignTokens.TypeStyle.label.font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        if let initiative = page.initiative {
            Label(initiative, systemImage: SymphonyView.initiatives.symbol)
                .font(DesignTokens.TypeStyle.label.font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Done: the pull request and when it merged.
private struct DoneLine: View {
    let pullRequest: URL?
    let merged: String?
    let open: (URL) -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            Image(systemName: DesignTokens.Status.done.symbol)
                .foregroundStyle(DesignTokens.Status.done.tint)
                .accessibilityHidden(true)
            if let merged {
                Text("Merged \(merged)").font(DesignTokens.TypeStyle.body.font)
            }
            if let pullRequest {
                Button(TicketPage.pullRequestName(pullRequest)) { open(pullRequest) }
                    .buttonStyle(.link)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// View Transcript (the default), Open in Linear, Stop Run…, and the ⋯ menu.
private struct TicketActions: View {
    let page: TicketPage
    let actions: TicketPageActions
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    var body: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            Button(TicketPage.viewTranscriptTitle) {
                // ⌘-click opens another window.
                actions.viewTranscript(NSEvent.modifierFlags.contains(.command))
            }
            .buttonStyle(.borderedProminent)
            .disabled(!page.isTracked)
            .help(page.isTracked ? "Open the run's transcript (⌘-click for another window)" : "Symphony no longer keeps this ticket's transcript")
            if let url = page.url {
                Button(TicketPage.openInLinearTitle) { actions.openURL(url) }
            }
            Button(StopRunSheet.buttonTitle, action: actions.stopRun)
                .disabled(!page.isRunning)
            if offscreenSnapshot {
                // `ImageRenderer` can't draw a menu.
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            } else {
                menu
            }
        }
        .fixedSize()
    }

    private var menu: some View {
        Menu {
            Button(TicketPage.copyAPIURLTitle, action: actions.copyAPIURL)
            Button(TicketPage.showAuditRecordsTitle, action: actions.showAuditRecords)
            Button(TicketPage.revealWorktreeTitle) { page.workspacePath.map(actions.revealWorktree) }
                .disabled(page.workspacePath == nil)
            Divider()
            if page.isForced {
                Button(TicketList.stopForcingTitle, action: actions.stopForcing)
            } else {
                Button(TicketList.forceTitle, action: actions.force)
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }
}

/// Now: the run, its model, time, turn, last activity, workspace and tokens against the cap.
private struct NowGrid: View {
    let now: TicketPage.Now
    let reveal: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DesignTokens.Space.s4, verticalSpacing: DesignTokens.Space.s2) {
                row("Run", now.run)
                if let model = now.model { row("Model", model) }
                if let time = now.runningTime { row("Running for", time) }
                if let turn = now.turn { row("Turn", String(turn)) }
                if let activity = now.lastActivity { row("Last activity", activity) }
                if let pending = now.pendingTool { row("Tool call", pending) }
                if let workspace = now.workspace {
                    GridRow {
                        label("Workspace")
                        HStack(spacing: DesignTokens.Space.s2) {
                            Text(workspace)
                                .font(DesignTokens.TypeStyle.mono.font)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Button("Reveal") { reveal(workspace) }
                                .controlSize(.small)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            MeterView(meter: now.tokens)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            label(title)
            Text(value)
                .font(DesignTokens.TypeStyle.body.font)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.TypeStyle.body.font)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
            .frame(minWidth: 96, alignment: .leading)
    }
}

/// The Ticket card: state, type, initiative, PR, gate verdict, forced.
private struct FactsGrid: View {
    let facts: [TicketPage.Fact]
    /// The PR fact's link: its page (D15).
    let open: (URL) -> Void

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DesignTokens.Space.s4, verticalSpacing: DesignTokens.Space.s2) {
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                GridRow {
                    Text(fact.label)
                        .font(DesignTokens.TypeStyle.body.font)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    if let url = fact.url {
                        Button(fact.value) { open(url) }
                            .buttonStyle(.link)
                            .help(url.absoluteString)
                    } else {
                        Text(fact.value)
                            .font(DesignTokens.TypeStyle.body.font)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - C14: the run timeline

/// Steps down a connecting line: time, symbol, step, result, duration and tokens; the current step live. A run is a
/// group that folds, its events inside it; an event's replies sit under it, and a finding shows its screenshots.
struct RunTimeline: View {
    let steps: [TicketPage.Step]
    var folded: Binding<Set<String>> = .constant([])
    var images: ArtifactImages?
    var openScreenshot: (TicketScreenshot) -> Void = { _ in }
    /// Inside a run or under an event: the time sits at the line's end, so each level doesn't spend a column on it.
    var nested = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                TimelineRow(
                    step: step, first: index == 0, last: index == steps.count - 1, folded: folded, images: images,
                    openScreenshot: openScreenshot, nested: nested
                )
            }
        }
    }
}

private struct TimelineRow: View {
    let step: TicketPage.Step
    let first: Bool
    let last: Bool
    let folded: Binding<Set<String>>
    let images: ArtifactImages?
    let openScreenshot: (TicketScreenshot) -> Void
    let nested: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isFolded: Bool { step.runID.map(folded.wrappedValue.contains) ?? false }

    /// A plain step reads as one element; a group, a step with screenshots or with replies keeps its controls.
    private var isPlain: Bool { !step.isGroup && step.children.isEmpty && step.screenshots.isEmpty }

    var body: some View {
        let row = HStack(alignment: .top, spacing: nested ? DesignTokens.Space.s2 : DesignTokens.Space.s3) {
            if !nested {
                Text(step.timeText)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 88, alignment: .trailing)
                    .padding(.top, DesignTokens.Space.s2)
                    .accessibilityHidden(!isPlain)
            }
            ZStack(alignment: .top) {
                // The connecting line, from the step above to the one below.
                VStack(spacing: 0) {
                    Rectangle().fill(first ? .clear : DesignTokens.Surface.separator.color).frame(width: 2, height: DesignTokens.Space.s2 + 4)
                    Rectangle().fill(last ? .clear : DesignTokens.Surface.separator.color).frame(width: 2)
                }
                symbol
                    .frame(width: 20, height: 20)
                    .background(DesignTokens.Surface.content.color, in: Circle())
                    .padding(.top, DesignTokens.Space.s1 + 2)
            }
            .frame(width: 20)
            .frame(maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1 / 2) {
                if step.isGroup {
                    Button(action: toggle) {
                        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                            Image(systemName: isFolded ? "chevron.right" : "chevron.down")
                                .font(DesignTokens.TypeStyle.callout.font.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                            summary
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isFolded ? "Show what happened in this run" : "Hide what happened in this run")
                    .accessibilityLabel(step.foldAccessibilityLabel(folded: isFolded))
                    .accessibilityValue(step.accessibilityLabel)
                } else if isPlain {
                    summary
                } else {
                    summary
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(spokenLabel)
                }
                if !step.screenshots.isEmpty {
                    ScreenshotThumbnails(shots: step.screenshots, images: images, open: openScreenshot)
                        .padding(.top, DesignTokens.Space.s1)
                }
                if !step.children.isEmpty, !isFolded {
                    RunTimeline(steps: step.children, folded: folded, images: images, openScreenshot: openScreenshot, nested: true)
                        .padding(.top, DesignTokens.Space.s1)
                }
            }
            .padding(.vertical, DesignTokens.Space.s2)
        }
        // The line column takes the row's full height, so the line runs unbroken from step to step.
        .fixedSize(horizontal: false, vertical: true)
        if isPlain {
            row
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenLabel)
        } else {
            row.accessibilityElement(children: .contain)
        }
    }

    private var spokenLabel: String { step.accessibilityLabel + (step.detail.map { ". \($0)" } ?? "") }

    /// The title, its result, duration and tokens, then the detail.
    private var summary: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1 / 2) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                Text(step.title).font(DesignTokens.TypeStyle.rowTitle.font)
                if let word = step.resultWord {
                    Text(word)
                        .font(DesignTokens.TypeStyle.callout.font)
                        .foregroundStyle(step.result == .failed ? AnyShapeStyle(status.tint) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: DesignTokens.Space.s2)
                if nested, !step.timeText.isEmpty {
                    Text(step.timeText)
                        .font(DesignTokens.TypeStyle.callout.font)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                if let duration = step.duration {
                    Text(duration).font(DesignTokens.TypeStyle.callout.font).monospacedDigit()
                }
                if let tokens = step.tokensText {
                    Text(tokens)
                        .font(DesignTokens.TypeStyle.callout.font)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(minWidth: 44, alignment: .trailing)
                }
            }
            if let detail = step.detail {
                Text(detail)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
    }

    private func toggle() {
        guard let runID = step.runID else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
            if folded.wrappedValue.contains(runID) {
                folded.wrappedValue.remove(runID)
            } else {
                folded.wrappedValue.insert(runID)
            }
        }
    }

    private var status: DesignTokens.Status {
        switch step.result {
        case .done: .done
        case .current: .working
        case .failed: .problem
        case .stopped: .idle
        }
    }

    @ViewBuilder private var symbol: some View {
        let image = Image(systemName: step.result == .stopped ? "stop.circle.fill" : status.symbol)
            .foregroundStyle(status.tint)
        if step.result == .current {
            // motion.live: only the current step, and only while drawn; Reduce Motion stops the loop.
            image
                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                .accessibilityLabel(TicketPage.runningTitle)
                .accessibilityHidden(isPlain)
        } else {
            image.accessibilityHidden(true)
        }
    }
}

/// A finding's screenshots, wrapping onto more lines when the column is narrow.
private struct ScreenshotThumbnails: View {
    let shots: [TicketScreenshot]
    let images: ArtifactImages?
    let open: (TicketScreenshot) -> Void

    var body: some View {
        WrappingStack(spacing: DesignTokens.Space.s2) {
            ForEach(shots) { shot in
                if let images {
                    ScreenshotThumbnail(shot: shot, images: images, open: open)
                } else {
                    ScreenshotTile(shot: shot, image: shot.available ? .loading : .unavailable, open: open)
                }
            }
        }
    }
}

/// A thumbnail that reads its image through the window's cache when it shows.
private struct ScreenshotThumbnail: View {
    let shot: TicketScreenshot
    @ObservedObject var images: ArtifactImages
    let open: (TicketScreenshot) -> Void

    var body: some View {
        ScreenshotTile(shot: shot, image: images.image(shot), open: open)
            .onAppear { images.load(shot) }
    }
}

/// The thumbnail itself: the image, opening full size; a quiet tile while it reads; the placeholder when Symphony no
/// longer has it or it isn't an image.
private struct ScreenshotTile: View {
    let shot: TicketScreenshot
    let image: ArtifactImages.Image
    let open: (TicketScreenshot) -> Void
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    static let size = CGSize(width: 128, height: 80)

    var body: some View {
        switch image {
        case let .loaded(data):
            if let picture = NSImage(data: data) {
                Button { open(shot) } label: {
                    Image(nsImage: picture)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: Self.size.width, height: Self.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.mark))
                        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.mark).strokeBorder(DesignTokens.Surface.separator.color))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(shot.label)
                .accessibilityLabel(shot.accessibilityLabel)
            } else {
                unavailable
            }
        case .loading:
            tile {
                if offscreenSnapshot {
                    // `ImageRenderer` can't draw a spinner: its symbol stands in.
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Screenshot \(shot.label), loading")
        case .unavailable, .failed:
            unavailable
        }
    }

    private var unavailable: some View {
        tile {
            VStack(spacing: DesignTokens.Space.s1) {
                Image(systemName: "eye.slash").foregroundStyle(.secondary)
                Text(TicketScreenshot.unavailableTitle)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(DesignTokens.Space.s1)
        }
        .help(shot.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shot.unavailableAccessibilityLabel)
    }

    private func tile(@ViewBuilder _ content: () -> some View) -> some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.mark)
            .fill(DesignTokens.Surface.raised.color)
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.mark).strokeBorder(DesignTokens.Surface.separator.color))
            .overlay(content())
            .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// A screenshot full size, over the window; Close or Esc closes it.
struct ScreenshotSheet: View {
    let shot: TicketScreenshot
    let images: ArtifactImages?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                Text(shot.label)
                    .font(DesignTokens.TypeStyle.sentence.font)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: DesignTokens.Space.s2)
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
            }
            Group {
                if case let .loaded(data)? = images?.image(shot), let picture = NSImage(data: data) {
                    Image(nsImage: picture)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .accessibilityLabel("Screenshot \(shot.label)")
                } else {
                    Label(TicketScreenshot.unavailableTitle, systemImage: "eye.slash")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(DesignTokens.Space.s5)
        .frame(minWidth: 480, idealWidth: 1000, maxWidth: 1800, minHeight: 360, idealHeight: 680, maxHeight: 1300)
        .onExitCommand(perform: close)
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
