import SwiftUI
import SymphonyBarCore

/// The Force a Ticket sheet asked for, with what its field starts with.
struct ForceSheetRequest: Identifiable, Equatable {
    let id = UUID()
    var input: String
}

// MARK: - The window model's Tickets and dispatch controls

extension SymphonyWindowModel {
    /// Every tracked ticket under the window's scope, nil until the first state payload.
    var ticketList: TicketList? {
        overviewState.map { TicketList(state: $0, scope: scope, now: Date()) }
    }

    /// Every tracked ticket in every repo, for the Force sheet's lookup.
    var allTickets: TicketList? {
        overviewState.map { TicketList(state: $0, now: Date()) }
    }

    /// C2: the toolbar's dispatch control.
    var dispatchControl: DispatchControl {
        DispatchControl(window: state, paused: paused, state: overviewState, update: updateHold, now: Date())
    }

    /// ⌥⌘F: the search field of the page shown, Audit's, Learnings' on Shipped or Tickets'; ⌘F finds a ticket from any
    /// page (TP-1455).
    func searchPage() {
        if searchesAudit {
            auditSearchRequested = true
        } else if searchesLearnings {
            shippedTab = .learnings
            learningsSearchRequested = true
        } else if hasPageSearch {
            searchRequested = true
        }
    }

    /// Whether the page shown has a search field for ⌥⌘F.
    var hasPageSearch: Bool { !showsPage && [.tickets, .shipped, .audit].contains(selection) }

    /// Whether ⌘F searches Learnings rather than Tickets: on Shipped, whichever tab shows.
    var searchesLearnings: Bool { selection == .shipped && !showsPage }

    /// Whether ⌘F searches Audit's records.
    var searchesAudit: Bool { selection == .audit && !showsPage }

    /// The menu item ⌥⌘F presses: "Search Audit Records", "Search Learnings" or "Search Tickets".
    var searchTitle: String {
        searchesAudit ? "Search Audit Records" : searchesLearnings ? "Search Learnings" : "Search Tickets"
    }

    /// Whether the view shown has an inspector for ⌥⌘I.
    var hasInspector: Bool {
        guard !showsPage else { return false }
        return [.tickets, .audit, .overview].contains(selection)
    }

    /// The inspector's menu item and toolbar button: on Home, the Inbox's drawer (TP-1454).
    var inspectorTitle: String {
        if selection == .overview { return inboxDrawerShown ? HomeInbox.hideDrawerTitle : HomeInbox.showDrawerTitle }
        return inspectorShown ? "Hide Inspector" : "Show Inspector"
    }

    func toggleInspector() {
        if selection == .overview { toggleInboxDrawer() } else { inspectorShown.toggle() }
    }

    /// The control pressed while Symphony is stopped.
    func startSymphony() {
        onAction(.startSymphony)
    }

    /// Pause Dispatch…, from the popover or the menu: opens the sheet; nothing pauses until its button is pressed.
    func openPauseSheet() {
        guard !dispatchInFlight else { return }
        dispatchPopoverShown = false
        dispatchError = nil
        pauseSheetShown = true
    }

    /// Force a Ticket…, from the popover, the toolbar, the inspector, ⇧⌘F or the menu.
    func openForceSheet(_ identifier: String? = nil) {
        guard !dispatchInFlight else { return }
        dispatchPopoverShown = false
        dispatchError = nil
        forceSheet = ForceSheetRequest(input: identifier ?? "")
    }

    func cancelDispatchSheet() {
        guard !dispatchInFlight else { return }
        pauseSheetShown = false
        forceSheet = nil
        dispatchError = nil
    }

    func confirmPause(reason: String) {
        sendDispatch(PauseSheet.action(reason: reason)) { $0.pauseSheetShown = false }
    }

    func confirmForce(input: String) {
        guard let identifier = ForceSheet.identifier(input) else { return }
        sendDispatch(.force(identifier)) { $0.forceSheet = nil }
    }

    /// Resume Dispatch needs no sheet: it changes nothing already running (P5).
    func resumeDispatch() {
        sendDispatch(.resume) { $0.dispatchPopoverShown = false }
    }

    /// Try Now needs no sheet either: Symphony checks the limit with one held run, and lets the rest go only if the
    /// provider allows it.
    func tryUsageLimitNow(_ limit: StateSnapshot.UsageLimit) {
        sendDispatch(.tryNow(condition: limit.condition)) { $0.dispatchPopoverShown = false }
    }

    /// Cancel Update or Update Now Anyway, from the popover: the menu's item does it, so both do the same.
    func performUpdateAction(_ action: WindowState.Action) {
        dispatchPopoverShown = false
        onAction(action)
    }

    /// Stop Forcing, from the inspector, a row's menu, the ticket page or Needs attention.
    func stopForcing(_ identifier: String) {
        send(.stopForcing(identifier))
    }

    /// Sends `action`; on success `done` closes what sent it, on failure the sheet or popover says why.
    private func sendDispatch(_ action: ControlAction, done: @escaping (SymphonyWindowModel) -> Void) {
        guard !dispatchInFlight else { return }
        dispatchInFlight = true
        dispatchError = nil
        Task {
            let result = await onControl(action)
            dispatchInFlight = false
            if case let .failed(message) = result {
                dispatchError = message
            } else {
                done(self)
            }
            client.refresh()
        }
    }
}

// MARK: - D6: Tickets, the table with filters (TP-1456)

/// Save View… or Rename…'s sheet: what it names.
enum TicketViewSheet: Identifiable, Equatable {
    case save
    case rename(TicketView)

    var id: String {
        switch self {
        case .save: "save"
        case let .rename(view): "rename-\(view.id)"
        }
    }
}

// MARK: - Saved views (TP-1457)

extension SymphonyWindowModel {
    /// The saved view in force, nil for "All open" or one the server no longer lists.
    var currentTicketView: TicketView? {
        ticketViewID.flatMap { id in ticketViews.first { $0.id == id } }
    }

    /// The views menu as the bar draws it.
    var ticketViewsMenu: TicketViewsMenu {
        TicketViewsMenu(views: ticketViews, currentID: ticketViewID, query: ticketsQuery)
    }

    /// Reads `GET /api/v1/views`: the catalog once, the saved views every time. A view in force the server no longer
    /// lists leaves "All open" in force, with the bar as it is.
    func readTicketViews() async {
        guard case let .loaded(data) = await client.get(TicketsPayload.viewsPath) else { return }
        if !ticketCatalogRead {
            ticketCatalog = TicketColumn.catalog(fromViews: data) ?? ticketCatalog
            ticketCatalogRead = true
        }
        guard let views = TicketView.views(fromViews: data, catalog: ticketCatalog) else { return }
        ticketViews = views
        let inForce = TicketView.inForce(ticketViewID, in: views)
        if inForce != ticketViewID { ticketViewID = inForce }
    }

    /// A pick in the views menu: the view's chips, columns and sort, or "All open"'s.
    func pickTicketView(_ view: TicketView?) {
        ticketViewError = nil
        ticketViewID = view?.id
        if ticketsQuery == (view?.query ?? TicketsQuery()) {
            // The same query: the path still changes, to the view's.
            ticketsReadAt = nil
            readTicketsIfDue()
        } else {
            ticketsQuery = view?.query ?? TicketsQuery()
        }
    }

    func openSaveTicketView() {
        ticketViewError = nil
        ticketViewSheet = .save
    }

    func openRenameTicketView() {
        guard let view = currentTicketView else { return }
        ticketViewError = nil
        ticketViewSheet = .rename(view)
    }

    func openDeleteTicketView() {
        guard currentTicketView != nil else { return }
        ticketViewError = nil
        ticketViewDeleteShown = true
    }

    func cancelTicketViewSheet() {
        guard !ticketViewInFlight else { return }
        ticketViewSheet = nil
        ticketViewError = nil
    }

    /// The sheet's button: Save View… saves the bar under `name` and puts the new view in force; Rename… gives the view
    /// `name` and keeps what it saved.
    func confirmTicketViewName(_ name: String) {
        guard let sheet = ticketViewSheet, TicketViewDraft.canName(name) else { return }
        switch sheet {
        case .save:
            let draft = TicketViewDraft(name: name, query: ticketsQuery)
            sendTicketView(.saveView(draft)) { model in
                model.ticketViewSheet = nil
                if let saved = TicketView.newest(named: draft.name, in: model.ticketViews) { model.ticketViewID = saved.id }
            }
        case let .rename(view):
            let draft = TicketViewDraft(id: view.id, name: name, query: view.query, savedAt: view.updatedAt ?? Date())
            sendTicketView(.saveView(draft)) { $0.ticketViewSheet = nil }
        }
    }

    /// Update View: the bar saved into the view in force.
    func updateTicketView() {
        guard let view = currentTicketView else { return }
        sendTicketView(.saveView(TicketViewDraft(id: view.id, name: view.name, query: ticketsQuery))) { _ in }
    }

    /// Delete…'s confirmation: the view goes for every client, and "All open" is in force.
    func deleteTicketView() {
        guard let view = currentTicketView else { return }
        sendTicketView(.deleteView(id: view.id, name: view.name)) { $0.pickTicketView(nil) }
    }

    /// Sends a view call; on success the views are read again and `done` runs, on failure the sheet or the bar says why.
    private func sendTicketView(_ action: ControlAction, done: @escaping (SymphonyWindowModel) -> Void) {
        guard !ticketViewInFlight else { return }
        ticketViewInFlight = true
        ticketViewError = nil
        Task {
            let result = await onControl(action)
            if case let .failed(message) = result {
                ticketViewError = message
            } else {
                await readTicketViews()
                done(self)
                ticketsReadAt = nil
                readTicketsIfDue()
            }
            ticketViewInFlight = false
        }
    }
}

extension SymphonyWindowModel {
    /// Reads the rows of the query from `GET /api/v1/tickets` while Tickets shows: at once after a change of the query or
    /// the scope, and at most every `ticketsInterval` after a state poll. The views read before it lists the saved views
    /// each time, so one deleted on another client goes; the catalog is read from it once.
    func readTicketsIfDue() {
        guard selection == .tickets, !showsPage, state.countsKnown else { return }
        guard ticketsReadAt.map({ Date().timeIntervalSince($0) >= Self.ticketsInterval }) ?? true else { return }
        guard !readingTickets else {
            ticketsReadAgain = true
            return
        }
        readingTickets = true
        Task {
            await readTicketViews()
            let query = ticketsQuery
            let scope = scope
            let result = await client.get(query.path(view: currentTicketView, scope: scope, catalog: ticketCatalog, now: Date()))
            // An answer to a query changed meanwhile is dropped: the read of the new one follows.
            let current = query == ticketsQuery && scope == self.scope
            if current {
                if case let .loaded(data) = result, let payload = TicketsPayload.decode(data) {
                    ticketsPayload = payload
                    ticketsResult = nil
                    ticketFilterValues.learn(payload.rows, repos: overviewState?.repos ?? [])
                } else {
                    ticketsResult = result
                }
                ticketsReadAt = Date()
            }
            readingTickets = false
            if !current || ticketsReadAgain {
                ticketsReadAgain = false
                readTicketsIfDue()
            }
        }
    }
}

/// D6 for the window: the filter bar over the table and its drawer, or a placeholder while it reads.
struct TicketsContent: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if let payload = model.ticketsPayload {
                TicketsView(
                    payload: payload,
                    list: model.ticketList,
                    catalog: model.ticketCatalog,
                    scope: model.scope,
                    query: $model.ticketsQuery,
                    values: model.ticketFilterValues,
                    search: model.ticketSearch,
                    selection: $model.ticketSelection,
                    drawerShown: $model.inspectorShown,
                    reference: model.overviewState?.generatedAt ?? Date(),
                    actions: actions,
                    viewsMenu: model.ticketViewsMenu,
                    viewActions: viewActions
                )
            } else if model.ticketsResult == .unsupported {
                EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
            } else if case let .failed(message)? = model.ticketsResult {
                EmptyState(title: "Couldn't read the tickets: \(message)", symbol: DesignTokens.Status.problem.symbol)
            } else {
                EmptyState(title: "Reading the tickets…", symbol: SymphonyView.tickets.symbol, showsSpinner: true)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // A row's Move to… banner, with its Undo for 10 s.
            if let banner = model.moveBanner {
                InboxBannerView(banner: banner, undo: { model.undoMove(banner) }, close: model.dismissBanner)
                    .padding(DesignTokens.Space.s4)
            }
        }
        .modifier(TicketViewSheetsPresenter(model: model))
        .searchable(text: $model.ticketSearch, placement: .toolbar, prompt: TicketsView.searchPrompt)
        .searchFocused($searchFocused)
        .onChange(of: model.searchRequested, initial: true) { _, requested in
            guard requested else { return }
            searchFocused = true
            model.searchRequested = false
        }
    }

    private var viewActions: TicketViewActions {
        TicketViewActions(
            pick: model.pickTicketView, save: model.openSaveTicketView, update: model.updateTicketView,
            rename: model.openRenameTicketView, delete: model.openDeleteTicketView, working: model.ticketViewInFlight,
            error: model.ticketViewSheet == nil ? model.ticketViewError : nil, dismissError: { model.ticketViewError = nil }
        )
    }

    private var actions: TicketsActions {
        TicketsActions(
            open: model.openTicket,
            force: { model.openForceSheet($0) },
            stopForcing: model.stopForcing,
            canForce: model.dispatchControl.canForce,
            phases: TicketMoveMenu.phases(inState: client.stateJSON),
            move: model.openMove,
            starts: TicketStart.byIdentifier(inState: client.stateJSON),
            start: model.startNow
        )
    }
}

/// What Tickets' rows and inspector do.
struct TicketsActions {
    var open: (String) -> Void = { _ in }
    var force: (String) -> Void = { _ in }
    var stopForcing: (String) -> Void = { _ in }
    var canForce = true
    /// The state payload's phases, for a row's Move to….
    var phases: [MachinePhase] = []
    /// A Move to… pick: its sheet.
    var move: (MoveSheet) -> Void = { _ in }
    /// Each ticket's Start now as the state payload says, by identifier, for a row's Start Now.
    var starts: [String: TicketStart] = [:]
    /// Start now: the ticket's run starts at once.
    var start: (String) -> Void = { _ in }

    /// A row's Move to… menu, nil when there is none to offer.
    func moveMenu(_ row: TicketList.Row) -> TicketMoveMenu? {
        TicketMoveMenu(identifier: row.identifier, current: row.state, repoKey: row.repoKey, phases: phases)
    }
}

/// The filter bar over the table and the drawer beside it, under the bar: opening the drawer never narrows the bar.
struct TicketsView: View {
    static let searchPrompt = "Ticket or title"

    let payload: TicketsPayload
    /// The state's tickets: the forced and needs-attention marks, the situations' causes and the inspector's facts.
    var list: TicketList?
    var catalog = TicketColumn.catalog
    var scope = OverviewScope.all
    @Binding var query: TicketsQuery
    var values = TicketFilterValues()
    let search: String
    @Binding var selection: String?
    @Binding var drawerShown: Bool
    var reference = Date()
    let actions: TicketsActions
    /// The views menu at the bar's left, nil before the views were read.
    var viewsMenu: TicketViewsMenu?
    var viewActions = TicketViewActions()
    /// The table's own selection, handed to the model after the table's delegate call returns: updating the
    /// window's model inside it re-renders the table reentrantly.
    @State private var tableSelection: String?

    var body: some View {
        let rows = payload.rows(matching: search)
        let columns = query.shownColumns(catalog: catalog, scope: scope)
        VStack(spacing: 0) {
            TicketsFilterBar(query: $query, catalog: catalog, values: values, count: rows.count, drawerShown: $drawerShown,
                             viewsMenu: viewsMenu, viewActions: viewActions)
            if let error = viewActions.error {
                TicketViewErrorLine(message: error, dismiss: viewActions.dismissError)
            }
            Divider()
            HStack(spacing: 0) {
                Group {
                    if rows.isEmpty {
                        EmptyState(title: search.isEmpty && query.chips.isEmpty ? TicketList.emptyTitle : TicketList.noMatchTitle,
                                   symbol: SymphonyView.tickets.symbol)
                    } else {
                        TicketsTable(rows: rows, columns: columns, list: list, reference: reference, sort: $query.sort,
                                     selection: $tableSelection, actions: actions)
                            .onKeyPress(.space) {
                                drawerShown.toggle()
                                return .handled
                            }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                if drawerShown {
                    Divider()
                    TicketsDrawer(row: drawerRow(rows), reference: reference, actions: actions, close: { drawerShown = false })
                        .frame(width: TicketsDrawer.width)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .onAppear { tableSelection = selection }
        .onChange(of: tableSelection) { _, chosen in
            guard chosen != selection else { return }
            Task { @MainActor in selection = chosen }
        }
        .onChange(of: selection) { _, chosen in
            if chosen != tableSelection { tableSelection = chosen }
        }
    }

    /// The selected ticket as the state has it, or as the server's columns read when the state doesn't list it.
    private func drawerRow(_ rows: [TicketsRow]) -> TicketList.Row? {
        guard let selection else { return nil }
        if let tracked = list?.row(selection) { return tracked }
        return rows.first { $0.identifier == selection }.map { TicketList.Row($0, columns: payload.columns, reference: reference) }
    }
}

/// The filter bar: a chip per filter set, + Filter, the row count and Columns, in one bar that wraps on a laptop.
struct TicketsFilterBar: View {
    @Binding var query: TicketsQuery
    let catalog: [TicketColumn]
    let values: TicketFilterValues
    let count: Int
    @Binding var drawerShown: Bool
    var viewsMenu: TicketViewsMenu?
    var viewActions = TicketViewActions()

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Space.s2) {
            if let viewsMenu {
                TicketViewsMenuButton(menu: viewsMenu, actions: viewActions)
                Divider().frame(height: DesignTokens.Control.small.height)
            }
            WrappingStack(spacing: DesignTokens.Space.s2) {
                ForEach(query.chips) { chip in
                    TicketFilterChipView(chip: chip, values: values.values(chip.filter, query: query),
                                         toggle: { query.toggle(chip.filter, $0) }, remove: { query.remove(chip.filter) })
                }
                TicketsBarMenu(title: "Filter", symbol: "plus", help: "Add a filter") {
                    ForEach(TicketFilter.allCases) { filter in
                        Menu(filter.title) {
                            ForEach(values.values(filter, query: query), id: \.self) { value in
                                Toggle(filter.word(value), isOn: Binding(
                                    get: { query.holds(filter, value) },
                                    set: { _ in query.toggle(filter, value) }
                                ))
                            }
                        }
                    }
                    if !query.chips.isEmpty {
                        Divider()
                        Button("Clear Filters") { query.chips = [] }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(count == 1 ? "1 ticket" : "\(count) tickets")
                .font(DesignTokens.TypeStyle.secondary.font)
                .foregroundStyle(.secondary)
                .frame(height: DesignTokens.Control.small.height)
                .fixedSize()
            TicketsBarMenu(title: "Columns", symbol: "tablecells", help: "Show or hide columns") {
                ForEach(catalog) { column in
                    Toggle(column.title, isOn: Binding(
                        get: { query.columns.contains(column.name) },
                        set: { query.setColumn(column.name, shown: $0, catalog: catalog) }
                    ))
                    .disabled(column.name == "identifier")
                }
            }
            Button { drawerShown.toggle() } label: {
                Label(drawerShown ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
            }
            .labelStyle(.iconOnly)
            .directorButton(.quiet, size: .small, selected: drawerShown)
            .help(drawerShown ? "Hide Inspector (Space)" : "Show Inspector (Space)")
        }
        .padding(.horizontal, DesignTokens.Space.s4)
        .padding(.vertical, DesignTokens.Space.s2)
    }
}

/// What the views menu does: pick a view, and the moves on the one in force.
struct TicketViewActions {
    var pick: (TicketView?) -> Void = { _ in }
    var save: () -> Void = {}
    var update: () -> Void = {}
    var rename: () -> Void = {}
    var delete: () -> Void = {}
    /// A view call on its way: the menu's moves wait for it.
    var working = false
    /// What went wrong with Update View or Delete…, shown under the bar.
    var error: String?
    var dismissError: () -> Void = {}

    /// Runs the move `move` of the menu.
    func perform(_ move: TicketViewsMenu.Move) {
        switch move {
        case .save: save()
        case .update: update()
        case .rename: rename()
        case .delete: delete()
        }
    }
}

/// The views menu: the view in force on its face, with a dot when the bar differs from it; "All open" and the saved
/// views to pick, then Save View…, Update View, Rename… and Delete…. Offscreen, where a menu draws nothing, its face.
struct TicketViewsMenuButton: View {
    let menu: TicketViewsMenu
    var actions = TicketViewActions()
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    var body: some View {
        if offscreenSnapshot {
            ButtonFace(label: TicketViewsMenuLabel(menu: menu), kind: .secondary, size: .small, state: .rest, reduceMotion: true)
        } else {
            Menu {
                ForEach(menu.items) { item in
                    switch item {
                    case let .pick(view, title, current):
                        Toggle(title, isOn: Binding(get: { current }, set: { _ in actions.pick(view) }))
                    case .divider:
                        Divider()
                    case let .move(move, enabled):
                        Button(move.title) { actions.perform(move) }
                            .disabled(!enabled || actions.working)
                            .help(enabled ? "" : menu.disabledReason(move))
                    }
                }
            } label: {
                TicketViewsMenuLabel(menu: menu)
            }
            .menuStyle(.button)
            .directorButton(.secondary, size: .small)
            .fixedSize()
            .help(menu.help)
            .accessibilityLabel(menu.accessibilityLabel)
        }
    }
}

/// The menu button's face: a stack symbol, the view's name and, when the bar differs from it, a dot.
struct TicketViewsMenuLabel: View {
    let menu: TicketViewsMenu

    var body: some View {
        HStack(spacing: DesignTokens.Space.s1) {
            Image(systemName: "rectangle.stack")
            Text(menu.title).lineLimit(1)
            if menu.changed {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The views menu drawn open, as the menu lists it: for the snapshots, where a menu draws nothing offscreen.
struct TicketViewsMenuPanel: View {
    let menu: TicketViewsMenu

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            TicketViewsMenuButton(menu: menu)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(menu.items) { item in
                    switch item {
                    case let .pick(_, title, current):
                        row(title, checked: current, enabled: true)
                    case .divider:
                        Divider().padding(.vertical, DesignTokens.Space.s1)
                    case let .move(move, enabled):
                        row(move.title, checked: false, enabled: enabled)
                    }
                }
            }
            .padding(DesignTokens.Space.s1)
            .frame(width: 240, alignment: .leading)
            .background(DesignTokens.Surface.raised.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.row).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
    }

    private func row(_ title: String, checked: Bool, enabled: Bool) -> some View {
        HStack(spacing: DesignTokens.Space.s1) {
            Image(systemName: "checkmark").opacity(checked ? 1 : 0).frame(width: 14)
            Text(title)
            Spacer(minLength: 0)
        }
        .font(DesignTokens.TypeStyle.body.font)
        .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .padding(.horizontal, DesignTokens.Space.s2)
        .padding(.vertical, 3)
    }
}

/// What went wrong with a view call made without a sheet, under the bar, with × to dismiss it.
struct TicketViewErrorLine: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            Label(message, systemImage: DesignTokens.Status.problem.symbol)
                .font(DesignTokens.TypeStyle.secondary.font)
                .foregroundStyle(DesignTokens.Status.problem.tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Label("Dismiss", systemImage: "xmark") }
                .labelStyle(.iconOnly)
                .directorButton(.quiet, size: .small)
                .help("Dismiss")
        }
        .padding(.horizontal, DesignTokens.Space.s4)
        .padding(.bottom, DesignTokens.Space.s2)
    }
}

/// Save View… and Rename…: one field for the name, Cancel and Save or Rename.
struct TicketViewNameSheetView: View {
    let sheet: TicketViewSheet
    let working: Bool
    let error: String?
    let cancel: () -> Void
    let confirm: (_ name: String) -> Void
    @State private var name: String
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    init(sheet: TicketViewSheet, name: String = "", working: Bool, error: String?, cancel: @escaping () -> Void,
         confirm: @escaping (String) -> Void) {
        self.sheet = sheet
        self.working = working
        self.error = error
        self.cancel = cancel
        self.confirm = confirm
        if case let .rename(view) = sheet, name.isEmpty {
            _name = State(initialValue: view.name)
        } else {
            _name = State(initialValue: name)
        }
    }

    private var isSave: Bool { sheet == .save }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            Text(isSave ? "Save View" : "Rename View")
                .font(DesignTokens.TypeStyle.sentence.font)
                .accessibilityAddTraits(.isHeader)
            Text(isSave ? "Keeps the filters, columns and sort you have set under a name. Every Director lists it."
                        : "Gives the view a new name. What it filters, shows and sorts stays as saved.")
                .font(DesignTokens.TypeStyle.body.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if offscreenSnapshot {
                // A text field draws nothing offscreen: its face with the name in it stands in for it.
                Text(name.isEmpty ? "Epic 6 needs me" : name)
                    .foregroundStyle(name.isEmpty ? .tertiary : .primary)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .background(DesignTokens.Surface.content.color, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
            } else {
                TextField("Name", text: $name, prompt: Text("Epic 6 needs me"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Name")
                    .onSubmit { if canSend { confirm(name) } }
            }
            if let error {
                Label(error, systemImage: DesignTokens.Status.problem.symbol)
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(DesignTokens.Status.problem.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DesignTokens.Space.s2) {
                if working { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button(isSave ? "Save" : "Rename") { confirm(name) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(width: 420)
    }

    private var canSend: Bool { !working && TicketViewDraft.canName(name) }
}

/// Presents Save View… and Rename…'s sheet and Delete…'s confirmation.
struct TicketViewSheetsPresenter: ViewModifier {
    @ObservedObject var model: SymphonyWindowModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $model.ticketViewSheet) { sheet in
                TicketViewNameSheetView(sheet: sheet, working: model.ticketViewInFlight, error: model.ticketViewError,
                                        cancel: model.cancelTicketViewSheet, confirm: model.confirmTicketViewName)
            }
            .confirmationDialog(
                TicketViewsMenu.deleteQuestion(model.currentTicketView?.name ?? ""),
                isPresented: $model.ticketViewDeleteShown, titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive, action: model.deleteTicketView)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(TicketViewsMenu.deleteMessage)
            }
    }
}

/// A filter's chip: what it reads, its values to add or take out, and × to remove it.
struct TicketFilterChipView: View {
    let chip: TicketFilterChip
    let values: [String]
    let toggle: (String) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            TicketsBarMenu(title: chip.text, help: "Change the \(chip.filter.title) filter", kind: .secondary) {
                ForEach(values, id: \.self) { value in
                    Toggle(chip.filter.word(value), isOn: Binding(get: { chip.values.contains(value) }, set: { _ in toggle(value) }))
                }
            }
            Button(action: remove) { Label(chip.removeLabel, systemImage: "xmark") }
                .labelStyle(.iconOnly)
                .directorButton(.quiet, size: .small)
                .help(chip.removeLabel)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(chip.text)
    }
}

/// A small menu button of the bar; offscreen, where a menu draws nothing, its face.
struct TicketsBarMenu<Items: View>: View {
    let title: String
    var symbol: String?
    let help: String
    var kind: ButtonKind = .quiet
    @ViewBuilder var items: Items
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    var body: some View {
        if offscreenSnapshot {
            ButtonFace(label: label, kind: kind, size: .small, state: .rest, reduceMotion: true)
        } else {
            Menu { items } label: { label }
                .menuStyle(.button)
                .directorButton(kind, size: .small)
                .fixedSize()
                .help(help)
                .accessibilityLabel(title)
        }
    }

    @ViewBuilder private var label: some View {
        if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
    }
}

/// The sort of a column as the table's header sets it: the server sorts, so it compares nothing itself.
struct TicketColumnSort: SortComparator, Hashable {
    var column: String
    var order: SortOrder = .forward

    func compare(_ lhs: TicketsRow, _ rhs: TicketsRow) -> ComparisonResult { .orderedSame }
}

/// C19 over the server's rows: the columns shown, each sortable by a click on its header (a second click reverses
/// it), which reads the rows again in that order; Return or a double-click opens the ticket.
struct TicketsTable: View {
    let rows: [TicketsRow]
    let columns: [TicketColumn]
    var list: TicketList?
    var reference = Date()
    @Binding var sort: TicketSort
    @Binding var selection: String?
    let actions: TicketsActions
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    var body: some View {
        if offscreenSnapshot {
            // `Table` draws nothing offscreen: the same header and cells in a grid stand in for it.
            TicketsGrid(rows: rows, columns: columns, list: list, reference: reference, sort: sort, selection: selection)
        } else {
            table
        }
    }

    private var sortOrder: Binding<[TicketColumnSort]> {
        Binding(
            get: { [TicketColumnSort(column: sort.column, order: sort.ascending ? .forward : .reverse)] },
            set: { order in
                guard let first = order.first else { return }
                sort = TicketSort(column: first.column, ascending: first.order == .forward)
            }
        )
    }

    private var table: some View {
        Table(of: TicketsRow.self, selection: $selection, sortOrder: sortOrder) {
            TableColumnForEach(columns) { column in
                TableColumn(column.title, sortUsing: TicketColumnSort(column: column.name)) { row in
                    TicketCell(row: row, column: column, tracked: list?.row(row.identifier), reference: reference)
                }
                .width(min: TicketCell.minWidth(column), ideal: TicketCell.idealWidth(column))
            }
        } rows: {
            ForEach(rows) { row in TableRow(row) }
        }
        .contextMenu(forSelectionType: String.self) { identifiers in
            if let identifier = identifiers.first, let row = rows.first(where: { $0.identifier == identifier }) {
                let tracked = list?.row(identifier) ?? TicketList.Row(row, columns: columns, reference: reference)
                Button(TicketList.openTitle) { actions.open(identifier) }
                TicketForceButton(row: tracked, actions: actions)
                if let start = actions.starts[identifier] {
                    StartNowMenuItem(identifier: identifier, start: start) { actions.start(identifier) }
                }
                if let menu = actions.moveMenu(tracked) {
                    Menu(TicketMoveMenu.title) { MoveToMenuItems(menu: menu, move: actions.move) }
                }
            }
        } primaryAction: { identifiers in
            identifiers.first.map(actions.open)
        }
        .accessibilityLabel("Tickets")
    }
}

/// The table's offscreen stand-in: the header, the sorted column's arrow, and the rows with the selected one drawn
/// as the table draws it.
struct TicketsGrid: View {
    let rows: [TicketsRow]
    let columns: [TicketColumn]
    var list: TicketList?
    var reference = Date()
    var sort = TicketSort.default
    var selection: String?

    var body: some View {
        // An overlay, so a grid wider than the table's space is cut at its right edge instead of widening the page.
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) { grid.fixedSize(horizontal: true, vertical: false) }
            .clipped()
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignTokens.Space.s3) {
                ForEach(columns) { column in
                    HStack(spacing: DesignTokens.Space.s1) {
                        Text(column.title)
                        if column.name == sort.column {
                            Image(systemName: sort.ascending ? "chevron.up" : "chevron.down").font(.caption2.weight(.semibold))
                        }
                    }
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(.secondary)
                    .frame(width: TicketCell.idealWidth(column), alignment: .leading)
                }
            }
            .padding(.vertical, DesignTokens.Space.s1)
            Divider()
            ForEach(rows) { row in
                let selected = row.identifier == selection
                HStack(spacing: DesignTokens.Space.s3) {
                    ForEach(columns) { column in
                        TicketCell(row: row, column: column, tracked: list?.row(row.identifier), reference: reference)
                            .frame(width: TicketCell.idealWidth(column), alignment: .leading)
                    }
                }
                .padding(.vertical, 3)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(selected ? Color.accentColor : Color.clear)
                .environment(\.backgroundProminence, selected ? .increased : .standard)
            }
        }
        .padding(.horizontal, DesignTokens.Space.s4)
    }
}

/// A cell: the identifier with the forced and needs-attention marks, the compact Situation line, chips for the epic,
/// the repo and the labels, and the rest as text (a time as an age).
struct TicketCell: View {
    let row: TicketsRow
    let column: TicketColumn
    var tracked: TicketList.Row?
    var reference = Date()

    var body: some View {
        // Always a view, so an empty cell keeps its column's width.
        HStack(spacing: 0) {
            content
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var content: some View {
        switch column.name {
        case "identifier":
            HStack(spacing: DesignTokens.Space.s1) {
                Text(row.identifier).font(DesignTokens.TypeStyle.mono.font)
                if tracked?.forced == true {
                    Image(systemName: DesignTokens.Status.forced.symbol)
                        .foregroundStyle(DesignTokens.Status.forced.tint)
                        .accessibilityLabel("Forced")
                }
                if tracked?.needsAttention == true {
                    Image(systemName: DesignTokens.Status.problem.symbol)
                        .foregroundStyle(DesignTokens.Status.problem.tint)
                        .accessibilityLabel("Needs attention")
                        .help("Needs attention")
                }
            }
        case "situation":
            if let line = row.situation(tracked: tracked?.situation) {
                SituationLine(line, reference: reference, size: .compact, forced: tracked?.forced ?? false)
                    .lineLimit(1)
            }
        case "epic", "repo":
            if let value = row.text(column.name) {
                TicketValueChip(text: value, systemImage: column.name == "epic" ? SymphonyView.initiatives.symbol : SymphonyView.repos.symbol)
            }
        case "labels":
            HStack(spacing: DesignTokens.Space.s1) {
                ForEach(row.labels.prefix(3), id: \.self) { TicketValueChip(text: $0) }
                if row.labels.count > 3 {
                    Text("+\(row.labels.count - 3)").font(DesignTokens.TypeStyle.caption.font).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.labels.joined(separator: ", "))
        default:
            Text(row.cell(column, reference: reference))
                .lineLimit(1)
                .monospacedDigit()
        }
    }

    static func minWidth(_ column: TicketColumn) -> CGFloat {
        switch column.name {
        case "identifier": 90
        case "title": 140
        case "situation": 200
        case "labels": 100
        default: 60
        }
    }

    static func idealWidth(_ column: TicketColumn) -> CGFloat {
        switch column.name {
        case "identifier": 110
        case "title": 260
        case "situation": 340
        case "labels": 180
        case "epic", "repo", "phase", "assignee": 100
        case "url": 200
        default: 80
        }
    }
}

/// A small capsule for a value: an epic, a repo, a label.
struct TicketValueChip: View {
    let text: String
    var systemImage: String?

    var body: some View {
        Group {
            if let systemImage { Label(text, systemImage: systemImage) } else { Text(text) }
        }
        .font(DesignTokens.TypeStyle.caption.font)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, DesignTokens.Space.s2)
        .padding(.vertical, 1)
        .background(DesignTokens.Surface.separator.color.opacity(0.5), in: Capsule())
    }
}

/// Force… or Stop Forcing, whichever the row can take.
private struct TicketForceButton: View {
    let row: TicketList.Row
    let actions: TicketsActions

    var body: some View {
        if row.forced {
            Button(TicketList.stopForcingTitle) { actions.stopForcing(row.identifier) }
        } else {
            Button(TicketList.forceTitle) { actions.force(row.identifier) }
                .disabled(!actions.canForce)
        }
    }
}

/// The inspector as a drawer beside the table: the selected ticket's facts in short, Open Ticket, Force or Stop
/// Forcing, and Close.
struct TicketsDrawer: View {
    static let width: CGFloat = 320

    let row: TicketList.Row?
    var reference = Date()
    let actions: TicketsActions
    let close: () -> Void
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    var body: some View {
        VStack(spacing: 0) {
            InboxDrawerHeader(title: "Ticket", close: close)
            Divider()
            if let row, offscreenSnapshot {
                // A scroll view draws nothing offscreen.
                TicketInspectorBody(row: row, reference: reference, actions: actions)
                Spacer(minLength: 0)
            } else if let row {
                ScrollView {
                    TicketInspectorBody(row: row, reference: reference, actions: actions)
                }
            } else {
                EmptyState(title: "Select a ticket.", symbol: "sidebar.right")
            }
        }
        .background(DesignTokens.Surface.content.color)
    }
}

/// The inspector's facts and buttons, outside the scroll view so they also render offscreen.
struct TicketInspectorBody: View {
    let row: TicketList.Row
    var reference = Date()
    let actions: TicketsActions

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                Text(row.identifier).font(DesignTokens.TypeStyle.mono.font).foregroundStyle(.secondary)
                Text(row.titleText).font(DesignTokens.TypeStyle.rowTitle.font).fixedSize(horizontal: false, vertical: true)
            }
            SituationLine(row.line, reference: reference, size: .compact, forced: row.forced)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DesignTokens.Space.s3, verticalSpacing: DesignTokens.Space.s2) {
                ForEach(Array(row.facts.enumerated()), id: \.offset) { _, fact in
                    GridRow {
                        Text(fact.label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                        Text(fact.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(DesignTokens.TypeStyle.secondary.font)
            HStack(spacing: DesignTokens.Space.s2) {
                Button(TicketList.openTitle) { actions.open(row.identifier) }
                    .buttonStyle(.borderedProminent)
                TicketForceButton(row: row, actions: actions)
            }
        }
        .padding(DesignTokens.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - C2 and D12a: the dispatch control and its popover

/// The status bar's dispatch control (TP-1454): a quiet button with the catalog's hover and pressed faces, pressed
/// while its popover is open.
struct DispatchControlButton: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient

    var body: some View {
        let control = model.dispatchControl
        Button {
            if control.canStart { model.startSymphony() } else { model.dispatchPopoverShown.toggle() }
        } label: {
            DispatchControlLabel(control: control)
        }
        .directorButton(.quiet, size: .small, selected: model.dispatchPopoverShown)
        .help(control.canStart ? DispatchControl.startTitle : "Dispatch")
        .accessibilityLabel(control.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $model.dispatchPopoverShown, arrowEdge: .top) {
            DispatchPopover(
                control: control,
                working: model.dispatchInFlight,
                error: model.dispatchError,
                actions: DispatchPopover.Actions(
                    pause: model.openPauseSheet,
                    resume: model.resumeDispatch,
                    tryNow: model.tryUsageLimitNow,
                    force: { model.openForceSheet() },
                    cancelUpdate: { model.performUpdateAction(.cancelUpdate) },
                    updateNow: { model.performUpdateAction(.updateNow) }
                )
            )
        }
    }
}

/// The control's face: status dot, word and chevron (or Start Symphony); the button's style draws its surface.
struct DispatchControlLabel: View {
    let control: DispatchControl

    var body: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            Circle()
                .fill(control.status.tint)
                .frame(width: 8, height: 8)
            Text(control.word)
                // Plain colors: the quiet button's own foreground is the accent, which a hierarchical style would take.
                .foregroundStyle(control.mode == .paused ? control.status.tint : Color.primary)
                .lineLimit(1)
            if control.canStart {
                Text(DispatchControl.startTitle).foregroundStyle(Color.accentColor)
            } else {
                Image(systemName: "chevron.up").font(.caption2.weight(.semibold)).foregroundStyle(Color.secondary)
            }
        }
    }
}

/// D12a: dispatch's state with what is working and queued, and its actions.
struct DispatchPopover: View {
    struct Actions {
        var pause: () -> Void = {}
        var resume: () -> Void = {}
        var tryNow: (StateSnapshot.UsageLimit) -> Void = { _ in }
        var force: () -> Void = {}
        var cancelUpdate: () -> Void = {}
        var updateNow: () -> Void = {}
    }

    let control: DispatchControl
    let working: Bool
    let error: String?
    let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            HStack(spacing: DesignTokens.Space.s2) {
                Circle().fill(control.status.tint).frame(width: 10, height: 10).accessibilityHidden(true)
                Text(control.word).font(DesignTokens.TypeStyle.rowTitle.font)
            }
            if !control.pauseFacts.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DesignTokens.Space.s3, verticalSpacing: DesignTokens.Space.s1) {
                    ForEach(Array(control.pauseFacts.enumerated()), id: \.offset) { _, fact in
                        GridRow {
                            Text(fact.label).foregroundStyle(.secondary)
                            Text(fact.value)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .font(DesignTokens.TypeStyle.secondary.font)
                Text(control.update == nil ? "No new run starts until you resume, forced tickets included." : "No new run starts until the update ends, forced tickets included.")
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let line = control.update?.waitingLine {
                Text(line).font(DesignTokens.TypeStyle.secondary.font)
            }
            // The menu's update actions, in place of Resume Dispatch (S3a, S3b).
            if control.canCancelUpdate {
                HStack(spacing: DesignTokens.Space.s2) {
                    Spacer(minLength: 0)
                    if control.canUpdateNow {
                        Button(DispatchControl.updateNowTitle, action: actions.updateNow)
                    }
                    Button(DispatchControl.cancelUpdateTitle, action: actions.cancelUpdate)
                }
            }
            if !control.limits.isEmpty {
                HStack(alignment: .top, spacing: DesignTokens.Space.s2) {
                    section("Held by", lines: control.limits, more: 0, empty: "")
                    Spacer(minLength: 0)
                    if control.canTryNow, let limit = control.tryNow {
                        Button(DispatchControl.tryNowTitle) { actions.tryNow(limit) }
                            .help(StatusMenu.tryNowHelp)
                            .accessibilityHint(StatusMenu.tryNowHelp)
                            .disabled(working)
                    }
                }
            }
            section("Working", lines: control.working, more: control.moreWorking, empty: "Nothing is running.")
            section("Queued", lines: control.queued, more: control.moreQueued, empty: "Nothing is queued.")
            if let error {
                Label(error, systemImage: DesignTokens.Status.problem.symbol)
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(DesignTokens.Status.problem.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(spacing: DesignTokens.Space.s2) {
                if working { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                Spacer(minLength: 0)
                Button(DispatchControl.forceTitle, action: actions.force)
                    .disabled(!control.canForce || working)
                // While an update is under way, Pause and Resume Dispatch wait until it ends.
                if control.canResume {
                    Button(DispatchControl.resumeTitle, action: actions.resume)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(working)
                } else if control.update == nil {
                    Button(DispatchControl.pauseTitle, action: actions.pause)
                        .disabled(!control.canPause || working)
                }
            }
        }
        .padding(DesignTokens.Space.s4)
        .frame(width: 340, alignment: .leading)
    }

    @ViewBuilder private func section(_ title: String, lines: [String], more: Int, empty: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            Text(title).font(DesignTokens.TypeStyle.label.font).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            if lines.isEmpty {
                Text(empty).font(DesignTokens.TypeStyle.secondary.font).foregroundStyle(.tertiary)
            }
            ForEach(lines, id: \.self) { line in
                Text(line).font(DesignTokens.TypeStyle.secondary.font).lineLimit(1)
            }
            if more > 0 {
                Text("and \(more) more").font(DesignTokens.TypeStyle.secondary.font).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - D12a and D12b: the sheets

/// C17: Pause Dispatch. What happens, what stays, an optional reason, Cancel and Pause Dispatch.
struct PauseSheetView: View {
    let working: Bool
    let error: String?
    let cancel: () -> Void
    let confirm: (_ reason: String) -> Void
    @State private var reason: String

    init(working: Bool, error: String?, reason: String = "", cancel: @escaping () -> Void, confirm: @escaping (String) -> Void) {
        self.working = working
        self.error = error
        self.cancel = cancel
        self.confirm = confirm
        _reason = State(initialValue: reason)
    }

    var body: some View {
        DispatchSheet(title: PauseSheet.title, happens: PauseSheet.happens, stays: PauseSheet.stays, error: error,
                      working: working, verb: PauseSheet.buttonTitle, canSend: true, cancel: cancel, confirm: { confirm(reason) }) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                TextField(PauseSheet.reasonLabel, text: $reason, prompt: Text(PauseSheet.reasonPrompt))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(PauseSheet.reasonLabel)
                Text(PauseSheet.reasonHelp).font(DesignTokens.TypeStyle.caption.font).foregroundStyle(.secondary)
            }
        }
    }
}

/// C17: Force a Ticket. A field that finds the ticket as it is typed, its title and state, what forcing skips and
/// what it doesn't, Cancel and Force.
struct ForceSheetView: View {
    let list: TicketList?
    let working: Bool
    let error: String?
    let cancel: () -> Void
    let confirm: (_ input: String) -> Void
    @State private var input: String

    init(list: TicketList?, input: String, working: Bool, error: String?, cancel: @escaping () -> Void, confirm: @escaping (String) -> Void) {
        self.list = list
        self.working = working
        self.error = error
        self.cancel = cancel
        self.confirm = confirm
        _input = State(initialValue: input)
    }

    var body: some View {
        DispatchSheet(title: ForceSheet.title, happens: ForceSheet.skips, stays: ForceSheet.keeps, error: error, working: working,
                      verb: ForceSheet.buttonTitle, canSend: ForceSheet.canForce(input, in: list), cancel: cancel, confirm: { confirm(input) }) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                TextField(ForceSheet.fieldLabel, text: $input, prompt: Text(ForceSheet.fieldPrompt))
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.TypeStyle.mono.font)
                    .accessibilityLabel(ForceSheet.fieldLabel)
                let matches = ForceSheet.matches(input, in: list)
                if ForceSheet.ticket(input, in: list) == nil, !matches.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(matches) { row in
                            Button { input = row.identifier } label: {
                                Text("\(row.identifier)  \(row.titleText)").lineLimit(1)
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .font(DesignTokens.TypeStyle.secondary.font)
                }
                if let summary = ForceSheet.summary(input, in: list) {
                    Text(summary)
                        .font(DesignTokens.TypeStyle.secondary.font)
                        .padding(DesignTokens.Space.s2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DesignTokens.Surface.raised.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(summary.replacingOccurrences(of: "\n", with: ", "))
                }
            }
        }
    }
}

/// P5's layout, shared by both sheets.
private struct DispatchSheet<Options: View>: View {
    let title: String
    let happens: String
    let stays: String
    let error: String?
    let working: Bool
    let verb: String
    let canSend: Bool
    let cancel: () -> Void
    let confirm: () -> Void
    @ViewBuilder var options: Options

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            Text(title)
                .font(DesignTokens.TypeStyle.sentence.font)
                .accessibilityAddTraits(.isHeader)
            Text(happens).font(DesignTokens.TypeStyle.body.font).fixedSize(horizontal: false, vertical: true)
            Text(stays).font(DesignTokens.TypeStyle.body.font).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            options
            if let error {
                Label(error, systemImage: DesignTokens.Status.problem.symbol)
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(DesignTokens.Status.problem.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DesignTokens.Space.s2) {
                if working { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button(verb, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working || !canSend)
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(width: 460)
    }
}

/// Presents the window model's Pause Dispatch and Force a Ticket sheets.
struct DispatchSheetsPresenter: ViewModifier {
    @ObservedObject var model: SymphonyWindowModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.pauseSheetShown) {
                PauseSheetView(working: model.dispatchInFlight, error: model.dispatchError, cancel: model.cancelDispatchSheet,
                               confirm: { model.confirmPause(reason: $0) })
            }
            .sheet(item: $model.forceSheet) { request in
                ForceSheetView(list: model.allTickets, input: request.input, working: model.dispatchInFlight,
                               error: model.dispatchError, cancel: model.cancelDispatchSheet, confirm: { model.confirmForce(input: $0) })
            }
    }
}
