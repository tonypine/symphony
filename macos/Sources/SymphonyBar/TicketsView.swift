import SwiftUI
import SymphonyBarCore

/// The Force a Ticket sheet asked for, with what its field starts with.
struct ForceSheetRequest: Identifiable, Equatable {
    let id = UUID()
    var input: String
}

// MARK: - The window model's Tickets and dispatch controls

extension SymphonyWindowModel {
    /// Builds `ticketList` and `allTickets` again for a new state or scope, so a render reads them as they are.
    func ticketListsChanged() {
        let now = Date()
        ticketList = overviewState.map { TicketList(state: $0, scope: scope, now: now) }
        allTickets = overviewState.map { TicketList(state: $0, now: now) }
    }

    /// Works out `ticketRows` again for new rows or a new search, so a render reads them as they are.
    func ticketRowsChanged() {
        ticketRows = ticketsPayload?.rows(matching: ticketSearch) ?? []
    }

    /// C2: the toolbar's dispatch control.
    var dispatchControl: DispatchControl {
        DispatchControl(window: state, paused: paused, state: overviewState, update: updateHold, now: Date())
    }

    /// ⌘F (TP-1497): the search of the page shown, Tickets', Audit's, or Learnings' on Shipped (which shows its
    /// Learnings tab); Find a ticket in the window bar on every other page.
    func find() {
        switch commandF {
        case .pageSearch(.audit):
            auditSearchRequested = true
        case .pageSearch(.learnings):
            shippedTab = .learnings
            learningsSearchRequested = true
        case .pageSearch(.tickets):
            searchRequested = true
        case .findTicket:
            findTicket()
        }
    }

    /// Whether the page shown has a search of its own, which ⌘F puts the keyboard in: ⌥⌘F is Find a ticket there.
    var hasPageSearch: Bool { commandF != .findTicket }

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
                    // The same rows again leave the table as it is: nothing re-renders.
                    if payload != ticketsPayload { ticketsPayload = payload }
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

/// A page's search field in its control bar, Tickets', Audit's or Learnings' (TP-1509, TP-1497): the shared search
/// field, small, with the count of what it found and ⌘F, which puts the keyboard in it on its page, while it is empty.
/// ⌘F sets `requested`; the field takes the keyboard through the window and clears it.
struct PageSearchField: View {
    let prompt: String
    @Binding var text: String
    let matches: Int?
    @Binding var requested: Bool

    static let shortcut = FindCommand.commandFShortcut

    var body: some View {
        SearchField(prompt, text: $text, matches: matches, shortcut: Self.shortcut, size: .small, focusRequest: $requested)
            .frame(width: DesignTokens.Field.toolbarSearchWidth)
    }
}

/// D6 for the window: the bar over the table and its details, or a placeholder while it reads.
struct TicketsContent: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient

    var body: some View {
        Group {
            if let payload = model.ticketsPayload {
                TicketsView(
                    payload: payload,
                    rows: model.ticketRows,
                    list: model.ticketList,
                    catalog: model.ticketCatalog,
                    scope: model.scope,
                    query: $model.ticketsQuery,
                    values: model.ticketFilterValues,
                    search: model.ticketSearch,
                    selection: $model.ticketSelection,
                    detailsShown: $model.inspectorShown,
                    reference: model.overviewState?.generatedAt ?? Date(),
                    actions: actions,
                    viewsMenu: model.ticketViewsMenu,
                    viewActions: viewActions,
                    controls: TicketsBarControls(
                        page: model.pageBar, search: $model.ticketSearch, searchRequested: $model.searchRequested,
                        force: { model.openForceSheet() }, canForce: model.dispatchControl.canForce
                    ),
                    situations: model.overviewState?.snapshot.situations ?? [:],
                    pullRequests: client.watchState.watches.compactMapValues(\.facts.prNumber)
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
    /// Why Force… is off: Symphony is stopped. Nil when it can force.
    var forceReason: String? { canForce ? nil : TicketList.stoppedReason }
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

/// Work › Tickets as designed (TP-1501, `docs/design/director-window-and-home.md` § Work: Tickets): the glass bar, then
/// the table in a panel and, while the details are on and a ticket is picked, the details panel at the right, 340 pt;
/// with no ticket picked the table takes the width. Return or a double click opens a ticket, Space turns the details
/// on or off, the arrow keys move the pick.
struct TicketsView: View {
    static let searchPrompt = "Ticket or title"

    let payload: TicketsPayload
    /// The payload's rows the search finds, worked out by the model once per change of either, never in `body`.
    let rows: [TicketsRow]
    /// The state's tickets: the forced marks, the situations' causes and the details' facts.
    var list: TicketList?
    var catalog = TicketColumn.catalog
    var scope = OverviewScope.all
    @Binding var query: TicketsQuery
    var values = TicketFilterValues()
    let search: String
    @Binding var selection: String?
    @Binding var detailsShown: Bool
    var reference = Date()
    let actions: TicketsActions
    /// The views menu at the bar's left, nil before the views were read.
    var viewsMenu: TicketViewsMenu?
    var viewActions = TicketViewActions()
    /// The window's part of the bar: the scope, the search and Force a Ticket….
    var controls = TicketsBarControls()
    /// Each ticket's situation as the state words it, for the tickets the state's lists leave out.
    var situations: [String: Situation] = [:]
    /// Each ticket's pull request number, as the watcher read it, for the details.
    var pullRequests: [String: Int] = [:]
    /// A hover or the keyboard's row drawn still, for a snapshot.
    var drawnAs: DataTableShown?

    var body: some View {
        GeometryReader { proxy in
            let width = Double(proxy.size.width)
            VStack(spacing: 0) {
                TicketsFilterBar(
                    query: $query, catalog: catalog, values: values, count: rows.count, detailsShown: $detailsShown,
                    viewsMenu: viewsMenu, viewActions: viewActions, controls: controls, width: width
                )
                if let error = viewActions.error {
                    TicketViewErrorLine(message: error, dismiss: viewActions.dismissError)
                }
                HStack(alignment: .top, spacing: DesignTokens.Tickets.columnGap) {
                    table(columns: query.drawnColumns(catalog: catalog, scope: scope, width: width))
                    if detailsShown, let details {
                        TicketDetailsPanel(details: details, reference: reference, actions: actions)
                            .frame(width: DesignTokens.Tickets.detailsWidth)
                    }
                }
                .padding(.horizontal, DesignTokens.ControlBar.pageInset)
                .padding(.bottom, DesignTokens.ControlBar.pageInset)
            }
        }
    }

    private func table(columns: [TicketColumn]) -> some View {
        TicketsTable(
            rows: rows, columns: columns, situations: situations, forced: Set(list?.rows.filter(\.forced).map(\.identifier) ?? []),
            reference: reference, sort: $query.sort, selection: $selection,
            empty: DataTableEmpty(
                search.isEmpty && query.chips.isEmpty ? TicketList.emptyTitle : TicketList.noMatchTitle,
                clearFilters: query.chips.isEmpty ? nil : { query.chips = [] }
            ),
            drawnAs: drawnAs, open: actions.open, toggleDetails: { _ in detailsShown.toggle() },
            rowMenu: { AnyView(TicketRowMenu(row: $0, columns: columns, list: list, reference: reference, actions: actions)) }
        )
        .padding(DesignTokens.Tickets.tableInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panelSurface(in: PanelStyle.shape)
    }

    /// The picked ticket as the state and the table have it.
    private var details: TicketDetails? {
        guard let selection else { return nil }
        return TicketDetails(
            identifier: selection, tracked: list?.row(selection), row: rows.first { $0.identifier == selection },
            situation: situations[selection],
            pullRequest: pullRequests[selection], reference: reference
        )
    }
}

/// A row's context menu: Open Ticket, Force… or Stop Forcing, Start Now when it can, and Move to….
struct TicketRowMenu: View {
    let row: TicketsRow
    let columns: [TicketColumn]
    var list: TicketList?
    var reference = Date()
    let actions: TicketsActions

    var body: some View {
        let identifier = row.identifier
        let tracked = list?.row(identifier) ?? TicketList.Row(row, columns: columns, reference: reference)
        Button(TicketList.openTitle) { actions.open(identifier) }
        if tracked.forced {
            Button(TicketList.stopForcingTitle) { actions.stopForcing(identifier) }
        } else {
            Button {
                actions.force(identifier)
            } label: {
                Text(TicketList.forceTitle)
                if let reason = actions.forceReason { Text(reason) }
            }
            .disabled(actions.forceReason != nil)
        }
        if let start = actions.starts[identifier] {
            StartNowMenuItem(identifier: identifier, start: start) { actions.start(identifier) }
        }
        if let menu = actions.moveMenu(tracked) {
            Menu(TicketMoveMenu.title) { MoveToMenuItems(menu: menu, move: actions.move) }
        }
    }
}

/// The window's part of Tickets' control bar (TP-1497): the scope, the search and Force a Ticket….
struct TicketsBarControls {
    var page = PageBar()
    var search: Binding<String> = .constant("")
    /// Set by ⌘F to put the keyboard in the search.
    var searchRequested: Binding<Bool> = .constant(false)
    var force: () -> Void = {}
    var canForce = true
}

/// Tickets' control bar (the catalog's `.tk-bar`, glass at the card's radius): at the left the saved view with its dot
/// while the bar differs from it, a hairline, a chip per filter set with its remove button, Filter, Save View while
/// there are changes to save, then the scope and the search; at the right the count, Columns, Force a Ticket… and the
/// details toggle.
struct TicketsFilterBar: View {
    /// Why the Ticket column can't be hidden.
    static let identifierStays = "Every table shows the ticket."

    @Binding var query: TicketsQuery
    let catalog: [TicketColumn]
    let values: TicketFilterValues
    let count: Int
    @Binding var detailsShown: Bool
    var viewsMenu: TicketViewsMenu?
    var viewActions = TicketViewActions()
    var controls = TicketsBarControls()
    /// The page's width, which decides whether the wide columns show at the default columns.
    var width = DesignTokens.Tickets.wideFrom

    var body: some View {
        ControlBar("Tickets controls") {
            if let viewsMenu {
                TicketViewsMenuButton(menu: viewsMenu, actions: viewActions)
                HairlineDivider(.vertical, length: DesignTokens.Control.small.height)
            }
            // Each chip and Filter wrap on their own with the bar's other controls.
            ForEach(query.chips) { chip in
                FilterChip(chip.field, value: chip.valueWords, removeLabel: chip.removeLabel, help: "Change the \(chip.filter.title) filter") {
                    values.values(chip.filter, query: query).map { value in
                        MenuItem(chip.filter.word(value), checked: chip.values.contains(value)) { query.toggle(chip.filter, value) }
                    }
                } remove: {
                    query.remove(chip.filter)
                }
            }
            MenuButton("Filter", glyph: "plus", size: .small, quiet: true, help: "Add a filter") {
                var items = TicketFilter.allCases.map { filter in
                    MenuItem.submenu(filter.title, items: values.values(filter, query: query).map { value in
                        MenuItem(filter.word(value), checked: query.holds(filter, value)) { query.toggle(filter, value) }
                    })
                }
                if !query.chips.isEmpty {
                    items += [.separator, MenuItem("Clear Filters") { query.chips = [] }]
                }
                return items
            }
            if let move = viewsMenu?.saveChanges {
                Button(TicketViewsMenu.saveChangesTitle) { viewActions.perform(move) }
                    .directorButton(.quiet, size: .small, disabledReason: viewActions.working ? TicketViewActions.workingReason : nil)
                    .help(move == .update ? "Save the filters, columns and sort into \(viewsMenu?.title ?? "")" : "Keep the filters, columns and sort under a name")
            }
            controls.page.scopePopUp
            PageSearchField(prompt: TicketsView.searchPrompt, text: controls.search, matches: count, requested: controls.searchRequested)
        } act: {
            Text(count == 1 ? "1 ticket" : "\(count) tickets")
                .textStyle(.secondary)
                .foregroundStyle(DesignTokens.TextColor.secondary.color)
                .monospacedDigit()
                .frame(height: DesignTokens.Control.small.height)
                .fixedSize()
            MenuButton("Columns", glyph: "tablecells", size: .small, alignment: .trailing, help: "Show or hide columns") {
                catalog.map { column in
                    MenuItem(
                        column.title, checked: query.ticksColumn(column.name, width: width),
                        disabledReason: column.name == "identifier" ? TicketsFilterBar.identifierStays : nil
                    ) {
                        query.pickColumn(column.name, width: width, catalog: catalog)
                    }
                }
            }
            Button(DispatchControl.forceTitle, action: controls.force)
                .directorButton(.secondary, size: .small, glyph: DesignTokens.Status.forced.symbol,
                                disabledReason: controls.canForce ? nil : TicketList.stoppedReason)
                .help("Force a ticket (⇧⌘F)")
            IconButton(
                "sidebar.trailing", help: detailsShown ? "Hide the details (Space)" : "Show the details (Space)", size: .small,
                isOn: $detailsShown
            )
        }
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
    /// Why the menu's moves wait while a view call is on its way.
    static let workingReason = "Wait for the last change to the view to finish."
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

/// The views menu (C54 on the pop-up's face): "View" and the view in force, with the accent dot when the bar differs
/// from it; "All open" and the saved views to pick, the one in force ticked, then Save View…, Update View, Rename… and
/// Delete…, each off with why while it can't act. `drawnOpen` draws it open, still, for a snapshot.
struct TicketViewsMenuButton: View {
    let menu: TicketViewsMenu
    var actions = TicketViewActions()
    var drawnOpen = false

    var body: some View {
        MenuButton(
            popUp: "View", value: menu.title, marked: menu.changed, size: .small, help: menu.help,
            accessibilityLabel: menu.accessibilityLabel, drawnOpen: drawnOpen
        ) {
            menu.items.map { item in
                switch item {
                case let .pick(view, title, current):
                    MenuItem(title, checked: current) { actions.pick(view) }
                case .divider:
                    .separator
                case let .move(move, enabled):
                    MenuItem(move.title, disabledReason: enabled ? (actions.working ? TicketViewActions.workingReason : nil) : menu.disabledReason(move)) {
                        actions.perform(move)
                    }
                }
            }
        }
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
            DirectorTextField("Name", text: $name, placeholder: "Epic 6 needs me", onSubmit: { if canSend { confirm(name) } })
            if let error {
                Label(error, systemImage: DesignTokens.Status.problem.symbol)
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(DesignTokens.Status.problem.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: DesignTokens.Space.s2) {
                if working { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .directorButton(disabledReason: working ? TicketList.waitReason : nil)
                Button(isSave ? "Save" : "Rename") { confirm(name) }
                    .keyboardShortcut(.defaultAction)
                    .directorButton(.primary, disabledReason: sendReason)
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(width: 420)
    }

    private var canSend: Bool { sendReason == nil }

    private var sendReason: String? {
        if working { return TicketList.waitReason }
        return TicketViewDraft.canName(name) ? nil : "Give the view a name first."
    }
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

/// The details panel (`.tk-inspector`): the picked ticket's identifier with its repo and epic chips, its title, its
/// situation, its facts as a two-column list, then Open Ticket and Force… (or Stop Forcing) beside it.
struct TicketDetailsPanel: View {
    let details: TicketDetails
    var reference = Date()
    let actions: TicketsActions

    var body: some View {
        Panel(spacing: DesignTokens.Tickets.detailsGap) {
            HStack(spacing: DesignTokens.Space.s2) {
                Text(details.identifier)
                    .textStyle(.rowTitle)
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                if let repo = details.repo { Chip(repo, kind: .repo) }
                if let epic = details.epic { Chip(epic, kind: .epic) }
            }
            Text(details.title)
                .textStyle(.heading)
                .fixedSize(horizontal: false, vertical: true)
            SituationLine(details.situation, reference: reference, size: .compact, forced: details.forced)
            if !details.facts.isEmpty {
                // The catalog's details list (`.facts`): the shared Key-value list in the secondary style.
                KeyValueList(style: .secondary, rowGap: DesignTokens.KeyValue.compactRowGap) {
                    ForEach(Array(details.facts.enumerated()), id: \.offset) { _, fact in
                        KeyValueRow(fact.label, text: fact.value)
                    }
                }
            }
            HStack(alignment: .top, spacing: DesignTokens.Space.s2) {
                Button(TicketList.openTitle) { actions.open(details.identifier) }
                    .directorButton(.primary)
                // Force… or Stop Forcing, whichever the ticket can take.
                if details.forced {
                    Button(TicketList.stopForcingTitle) { actions.stopForcing(details.identifier) }
                        .directorButton()
                } else {
                    Button(TicketList.forceTitle) { actions.force(details.identifier) }
                        .directorButton(glyph: DesignTokens.Status.forced.symbol, disabledReason: actions.forceReason)
                }
            }
            .padding(.top, DesignTokens.Tickets.movesTopPadding)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Details of \(details.identifier)")
    }
}

// MARK: - C2 and D12a: the dispatch control and its popover

/// The status line's dispatch control (TP-1454, TP-1498): the shared control, pressed while its popover is open.
struct DispatchControlButton: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient

    var body: some View {
        let control = model.dispatchControl
        DispatchStatusControl(control, open: model.dispatchPopoverShown) {
            if control.canStart { model.startSymphony() } else { model.dispatchPopoverShown.toggle() }
        }
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
                StatusDot(control.status, size: .large)
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
            HStack(alignment: .top, spacing: DesignTokens.Space.s2) {
                if working { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                Spacer(minLength: 0)
                Button(DispatchControl.forceTitle, action: actions.force)
                    .directorButton(disabledReason: working ? TicketList.waitReason : control.canForce ? nil : TicketList.stoppedReason)
                // While an update is under way, Pause and Resume Dispatch wait until it ends.
                if control.canResume {
                    Button(DispatchControl.resumeTitle, action: actions.resume)
                        .keyboardShortcut(.defaultAction)
                        .directorButton(.primary, disabledReason: working ? TicketList.waitReason : nil)
                } else if control.update == nil {
                    Button(DispatchControl.pauseTitle, action: actions.pause)
                        .directorButton(disabledReason: working ? TicketList.waitReason : control.canPause ? nil : TicketList.stoppedReason)
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
                      working: working, verb: PauseSheet.buttonTitle, sendReason: nil, cancel: cancel, confirm: { confirm(reason) }) {
            DirectorTextField(PauseSheet.reasonLabel, text: $reason, placeholder: PauseSheet.reasonPrompt, help: PauseSheet.reasonHelp)
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
                      verb: ForceSheet.buttonTitle,
                      sendReason: ForceSheet.canForce(input, in: list) ? nil : "Name a ticket that isn't forced yet, such as SHOP-301.",
                      cancel: cancel, confirm: { confirm(input) }) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                DirectorTextField(ForceSheet.fieldLabel, text: $input, placeholder: ForceSheet.fieldPrompt)
                let matches = ForceSheet.matches(input, in: list)
                if ForceSheet.ticket(input, in: list) == nil, !matches.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(matches) { row in
                            Button { input = row.identifier } label: {
                                Text("\(row.identifier)  \(row.titleText)").lineLimit(1)
                            }
                            .directorButton(.quiet, size: .small)
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
    /// Why the verb is off, nil when it can send.
    let sendReason: String?
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
            HStack(alignment: .top, spacing: DesignTokens.Space.s2) {
                if working { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .directorButton(disabledReason: working ? TicketList.waitReason : nil)
                Button(verb, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .directorButton(.primary, disabledReason: working ? TicketList.waitReason : sendReason)
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
