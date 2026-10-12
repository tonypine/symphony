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

    /// The page of the ticket shown, from the client's last state and what the page read itself.
    var ticketPage: TicketPage? {
        guard let identifier = shownTicket else { return nil }
        var sources = ticketSources
        sources.state = client.stateJSON
        sources.stops = localStops
        return TicketPage(identifier: identifier, sources: sources, now: Date())
    }

    /// Opens the page of ticket `identifier` (D3), from any row that shows it.
    func openTicket(_ identifier: String) {
        guard shownTicket != identifier else { return }
        history.visit(.ticket(identifier))
        showPlace()
    }

    /// ⌘[.
    func goBack() {
        guard history.goBack() != nil else { return }
        showPlace()
    }

    /// ⌘].
    func goForward() {
        guard history.goForward() != nil else { return }
        showPlace()
    }

    /// Shows the history's current place: a view takes the sidebar's selection; a ticket page reads its endpoints.
    private func showPlace() {
        switch history.current {
        case let .view(view):
            selection = view
        case .ticket:
            ticketSources = TicketPage.Sources()
            ticketSlowReadAt = nil
            readTicket(force: true)
        }
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
            ticketSources = sources
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

    /// Opens the web dashboard's Audit view filtered to the ticket.
    func showAuditRecords(_ page: TicketPage) {
        guard let base = apiURL(), let url = TicketPage.auditRecordsURL(page.identifier, base: base) else { return }
        onOpenURL(url)
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
}

/// D3 for the window: the page with its Stop Run sheet, or a placeholder while it reads.
struct TicketPageContent: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient

    var body: some View {
        if let page = model.ticketPage {
            TicketPageView(
                page: page,
                actions: TicketPageActions(
                    viewTranscript: { newWindow in model.onOpenTranscript(page.identifier, page.repoKey, newWindow) },
                    openURL: model.onOpenURL,
                    stopRun: { model.openStopRun(page.identifier, origin: .ticketPage) },
                    copyAPIURL: { model.copyAPIURL(page) },
                    showAuditRecords: { model.showAuditRecords(page) },
                    revealWorktree: model.revealWorktree
                )
            )
        } else {
            EmptyState(title: "Reading the ticket…", symbol: "doc.text.magnifyingglass", showsSpinner: true)
        }
    }
}

/// The ticket page in a scroll view, laid out for the width it gets.
struct TicketPageView: View {
    let page: TicketPage
    let actions: TicketPageActions
    @State private var width: CGFloat = DesignTokens.Layout.windowWidth - DesignTokens.Layout.sidebarWidth

    var body: some View {
        ScrollView {
            TicketPageBody(page: page, actions: actions, width: width)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// The page's sections, outside the scroll view so they also render offscreen.
struct TicketPageBody: View {
    let page: TicketPage
    let actions: TicketPageActions
    let width: CGFloat

    static let sideColumnWidth: CGFloat = 300
    static let mainColumnMinWidth: CGFloat = 460

    private var sideBySide: Bool {
        width - 2 * DesignTokens.Space.s5 >= Self.mainColumnMinWidth + DesignTokens.Space.s4 + Self.sideColumnWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s5) {
            TicketHeader(page: page, actions: actions)
            let layout = sideBySide
                ? AnyLayout(HStackLayout(alignment: .top, spacing: DesignTokens.Space.s4))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: DesignTokens.Space.s4))
            layout {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
                    if let now = page.now {
                        Card(title: "Now") { NowGrid(now: now, reveal: actions.revealWorktree) }
                    }
                    Card(title: "Timeline") {
                        if page.timeline.isEmpty {
                            Text("No runs yet.").font(DesignTokens.TypeStyle.body.font).foregroundStyle(.secondary)
                        } else {
                            RunTimeline(steps: page.timeline)
                        }
                    }
                }
                .frame(minWidth: sideBySide ? Self.mainColumnMinWidth : nil, maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
                    Card(title: "Ticket") { FactsGrid(facts: page.facts, openURL: actions.openURL) }
                    if let message = page.lastMessage {
                        Card(title: "Last message") {
                            Text(message)
                                .font(DesignTokens.TypeStyle.body.font)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: sideBySide ? Self.sideColumnWidth : .infinity, alignment: .topLeading)
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The identifier and title, repo, initiative and badges (C7), what it is doing, and the page's actions.
private struct TicketHeader: View {
    let page: TicketPage
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
            if case let .done(pullRequest, _) = page.phase, pullRequest != nil || page.mergedText != nil {
                DoneLine(pullRequest: pullRequest, merged: page.mergedText, openURL: actions.openURL)
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
    let openURL: (URL) -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            Image(systemName: DesignTokens.Status.done.symbol)
                .foregroundStyle(DesignTokens.Status.done.tint)
                .accessibilityHidden(true)
            if let merged {
                Text("Merged \(merged)").font(DesignTokens.TypeStyle.body.font)
            }
            if let pullRequest {
                Button(TicketPage.pullRequestName(pullRequest)) { openURL(pullRequest) }
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
            Menu {
                Button(TicketPage.copyAPIURLTitle, action: actions.copyAPIURL)
                Button(TicketPage.showAuditRecordsTitle, action: actions.showAuditRecords)
                Button(TicketPage.revealWorktreeTitle) { page.workspacePath.map(actions.revealWorktree) }
                    .disabled(page.workspacePath == nil)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
        .fixedSize()
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
    let openURL: (URL) -> Void

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DesignTokens.Space.s4, verticalSpacing: DesignTokens.Space.s2) {
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                GridRow {
                    Text(fact.label)
                        .font(DesignTokens.TypeStyle.body.font)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    if let url = fact.url {
                        Button(fact.value) { openURL(url) }
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

/// Steps down a connecting line: time, symbol, step, result, duration and tokens; the current step live.
struct RunTimeline: View {
    let steps: [TicketPage.Step]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                TimelineRow(step: step, first: index == 0, last: index == steps.count - 1)
            }
        }
    }
}

private struct TimelineRow: View {
    let step: TicketPage.Step
    let first: Bool
    let last: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Space.s3) {
            Text(step.timeText)
                .font(DesignTokens.TypeStyle.callout.font)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .trailing)
                .padding(.top, DesignTokens.Space.s2)
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
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                    Text(step.title).font(DesignTokens.TypeStyle.rowTitle.font)
                    if let word = step.resultWord {
                        Text(word)
                            .font(DesignTokens.TypeStyle.callout.font)
                            .foregroundStyle(step.result == .failed ? AnyShapeStyle(status.tint) : AnyShapeStyle(.secondary))
                    }
                    Spacer(minLength: DesignTokens.Space.s2)
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
            .padding(.vertical, DesignTokens.Space.s2)
        }
        // The line column takes the row's full height, so the line runs unbroken from step to step.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.accessibilityLabel + (step.detail.map { ". \($0)" } ?? ""))
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
            .accessibilityHidden(true)
        if step.result == .current {
            // motion.live: only the current step, and only while drawn; Reduce Motion stops the loop.
            image.symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
        } else {
            image
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
