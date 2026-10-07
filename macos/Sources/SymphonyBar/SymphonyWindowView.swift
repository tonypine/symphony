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
        }
    }

    /// Whether Symphony answers, or which placeholder every view shows instead (D0).
    @Published var state: WindowState = .stopped
    @Published var paused = false
    /// The Overview's reading of the last state payload.
    @Published private(set) var overviewState: OverviewState?
    /// The last answer to `/api/v1/repos`, for the Overview's repos line.
    @Published private(set) var repos: ReposPoll?
    /// All repos or one: filters every view, and is remembered across relaunches (P6).
    @Published var scope: OverviewScope = .all {
        didSet {
            guard scope != oldValue else { return }
            onScopeChange(scope)
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
    /// The Director's picks in each plan's decisions, by issue id (C16).
    @Published private(set) var inboxPicks: [String: DecisionPicks] = [:]
    /// The consequence sheet shown (C17); nothing changes Linear until its button is pressed.
    @Published var inboxSheet: ConsequenceSheet?
    /// True while the sheet's move is on its way to Symphony.
    @Published private(set) var inboxMoveInFlight = false
    /// What went wrong with the sheet's move, shown in the sheet.
    @Published private(set) var inboxMoveError: String?
    /// The banner after a move, with Undo for 10 s (C18).
    @Published private(set) var inboxBanner: InboxBanner?
    /// The items moved from the Inbox that Symphony still lists, by issue id: they leave the list at once.
    @Published private(set) var inboxAnswered: Set<String> = []
    /// The app's version, for the sidebar footer while Symphony doesn't say its own.
    var appVersion = ""
    /// Where the client reads Symphony from, for Diagnostics.
    var apiURL: () -> URL? = { nil }
    var canOpenWebDashboard: () -> Bool = { false }
    var canOpenLogs: () -> Bool = { false }

    var onSelect: (SymphonyView) -> Void = { _ in }
    var onAction: (WindowState.Action) -> Void = { _ in }
    var onOpenRepos: () -> Void = {}
    var onOpenWebDashboard: () -> Void = {}
    var onScopeChange: (OverviewScope) -> Void = { _ in }
    /// Sends a control request to Symphony, or to the API fixtures in QA mode, and says how it went.
    var onControl: (ControlAction) async -> ControlResult = { _ in .done }
    var onOpenURL: (URL) -> Void = { _ in }

    /// The repos are read again at most this often: Symphony reads each checkout's remote to answer.
    static let reposInterval: TimeInterval = 30
    private var reposReadAt: Date?
    private var readingRepos = false
    private var readingInbox = false
    private var bannerTask: Task<Void, Never>?
    /// A sheet to open once the Inbox lists its item: Approve and Merge… chosen on a notification.
    private var pendingSheet: (id: String, move: InboxMove)?
    private var cancellables = Set<AnyCancellable>()

    init(client: LiveAPIClient, selection: SymphonyView) {
        self.client = client
        self.selection = selection
        client.$stateJSON
            .sink { [weak self] data in
                guard let self else { return }
                overviewState = data.flatMap(OverviewState.decode)
                readReposIfDue()
                readInbox()
            }
            .store(in: &cancellables)
    }

    /// The Overview item's badge: what needs attention in every repo, whatever the scope; 0 hides it, as do
    /// unknown counts.
    var attentionBadge: Int {
        guard state.countsKnown, let overviewState else { return 0 }
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
        selection = .inbox
        readInbox()
    }

    /// The Inbox under the window's scope, without the items just moved.
    var inboxList: InboxList? {
        inbox.map { InboxList(items: $0.items, scope: scope, answered: inboxAnswered) }
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

    func picks(for itemID: String) -> DecisionPicks { inboxPicks[itemID] ?? DecisionPicks() }

    /// Picks option `option` in decision `decision` of the plan with issue id `itemID`.
    func pick(_ option: Int, decision: Int, itemID: String) {
        var picks = picks(for: itemID)
        picks.picks[decision] = option
        inboxPicks[itemID] = picks
    }

    /// Acts on a review's toolbar entry: a move opens its sheet, a link opens.
    func perform(_ command: InboxCommand, on item: InboxItem) {
        switch command {
        case let .move(move): open(move, on: item)
        case let .link(action): perform(action)
        }
    }

    /// Opens the consequence sheet of `move` on `item`.
    func open(_ move: InboxMove, on item: InboxItem) {
        guard !inboxMoveInFlight else { return }
        inboxMoveError = nil
        inboxSheet = ConsequenceSheet(move: move, item: item, picks: picks(for: item.id))
    }

    /// Cancel on the sheet: nothing is sent.
    func cancelSheet() {
        guard !inboxMoveInFlight else { return }
        inboxSheet = nil
        inboxMoveError = nil
    }

    /// The sheet's button: sends the move; on success the sheet closes, the item leaves the list, the selection
    /// moves to the next item and the banner shows; on failure the sheet says why.
    func confirm(_ sheet: ConsequenceSheet, reason: String) {
        guard !inboxMoveInFlight, let action = sheet.action(reason: reason) else { return }
        inboxMoveInFlight = true
        inboxMoveError = nil
        Task {
            let result = await onControl(action)
            inboxMoveInFlight = false
            switch result {
            case .done:
                let next = inboxList?.neighbor(of: sheet.itemID)
                inboxSheet = nil
                inboxAnswered.insert(sheet.itemID)
                inboxPicks[sheet.itemID] = nil
                inboxSelection = next?.id
                showBanner(sheet.banner)
            case let .failed(message):
                inboxMoveError = message
            }
            client.refresh()
        }
    }

    /// Undo on the banner: takes the move back, and the item comes back to the list, selected.
    func undo(_ banner: InboxBanner) {
        guard banner.undo else { return }
        dismissBanner()
        Task {
            switch await onControl(.undo(banner.identifier)) {
            case .done:
                inboxAnswered.remove(banner.itemID)
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
                inbox = payload
                inboxResult = nil
                // An item moved away leaves the list for good once Symphony stops listing it.
                inboxAnswered = inboxAnswered.filter { id in payload.items.contains { $0.id == id } }
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
        case let .open(url), let .openInLinear(url):
            onOpenURL(url)
        case .openDiagnostics:
            show(.diagnostics)
        case let .stopForcing(identifier):
            send(.stopForcing(identifier))
        }
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
            onOpenRepos()
        } else {
            selection = view
        }
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
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(model.selection.title).font(.headline)
                            Text(model.selection.subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    ToolbarItem(placement: .status) {
                        ConnectionState(state: model.state, lastUpdate: client.lastUpdate)
                    }
                    ToolbarItem(placement: .automatic) {
                        ScopePicker(model: model)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            client.refresh()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .help("Refresh (⌘R)")
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
                            if badge(view) > 0 {
                                SidebarBadge(count: badge(view), tint: view == .inbox ? DesignTokens.Status.you.tint : DesignTokens.Status.problem.tint)
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
            get: { model.selection },
            set: { view in
                guard let view else { return }
                model.show(view)
            }
        )
    }

    private func badge(_ view: SymphonyView) -> Int {
        switch view {
        case .inbox: model.inboxBadge
        case .overview: model.attentionBadge
        default: 0
        }
    }

    /// C1: "Inbox, 4 waiting".
    private func accessibilityValue(_ view: SymphonyView) -> String {
        switch view {
        case .inbox where model.inboxBadge > 0: "\(model.inboxBadge) waiting"
        case .overview where model.attentionBadge > 0: "\(model.attentionBadge) need attention"
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
        } else {
            switch model.selection {
            case .inbox:
                InboxContent(model: model, client: client)
            case .overview:
                OverviewContent(model: model, client: client)
            case .diagnostics:
                DiagnosticsContent(model: model, client: client)
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
        if let state = model.overviewState {
            OverviewView(
                overview: Overview(state: state, scope: model.scope, repos: model.repos, now: Date()),
                actions: OverviewActions(
                    resume: { model.send(.resume) },
                    perform: model.perform,
                    controlInFlight: model.controlInFlight,
                    openInbox: { model.showInbox() }
                )
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
                    openLogs: model.canOpenLogs() ? { model.onAction(.openLogs) } : nil,
                    openWebDashboard: model.canOpenWebDashboard() ? model.onOpenWebDashboard : nil
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
        var openWebDashboard: (() -> Void)?
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
                Button(StatusMenu.openWebDashboardTitle) { actions.openWebDashboard?() }
                    .disabled(actions.openWebDashboard == nil)
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
