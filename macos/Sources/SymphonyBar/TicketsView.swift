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

    /// Opens Tickets on `filter`, from an Overview tile.
    func showTickets(_ filter: TicketList.Filter) {
        ticketFilter = filter
        ticketSearch = ""
        show(.tickets)
    }

    /// ⌘F: Audit's search on Audit, Learnings' on Shipped, else Tickets' search, from any view.
    func searchTickets() {
        if searchesAudit {
            auditSearchRequested = true
            return
        }
        if searchesLearnings {
            shippedTab = .learnings
            learningsSearchRequested = true
            return
        }
        if showsPage || selection != .tickets { show(.tickets) }
        searchRequested = true
    }

    /// Whether ⌘F searches Learnings rather than Tickets: on Shipped, whichever tab shows.
    var searchesLearnings: Bool { selection == .shipped && !showsPage }

    /// Whether ⌘F searches Audit's records.
    var searchesAudit: Bool { selection == .audit && !showsPage }

    /// The menu item ⌘F presses: "Search Audit Records", "Search Learnings" or "Search Tickets".
    var searchTitle: String {
        searchesAudit ? "Search Audit Records" : searchesLearnings ? "Search Learnings" : "Search Tickets"
    }

    /// Whether the view shown has an inspector for ⌥⌘I.
    var hasInspector: Bool {
        guard !showsPage else { return false }
        return [.tickets, .audit].contains(selection) || selection == .inbox && peek.canToggle
    }

    /// The inspector's menu item and toolbar button: on the Inbox, the peek (N4).
    var inspectorTitle: String {
        (selection == .inbox ? peek.isShown : inspectorShown) ? "Hide Inspector" : "Show Inspector"
    }

    func toggleInspector() {
        if selection == .inbox { togglePeek() } else { inspectorShown.toggle() }
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

// MARK: - D6: Tickets

/// D6 for the window: the table under its scope bar, with the inspector, or a placeholder while it reads.
struct TicketsContent: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if let list = model.ticketList {
                TicketsView(
                    list: list,
                    filter: $model.ticketFilter,
                    search: model.ticketSearch,
                    selection: $model.ticketSelection,
                    inspectorShown: $model.inspectorShown,
                    actions: actions
                )
            } else if client.stateResult == .unsupported {
                EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
            } else {
                EmptyState(title: "Reading Symphony's state…", symbol: SymphonyView.tickets.symbol, showsSpinner: true)
            }
        }
        .searchable(text: $model.ticketSearch, placement: .toolbar, prompt: TicketList.searchPrompt)
        .searchFocused($searchFocused)
        .onChange(of: model.searchRequested, initial: true) { _, requested in
            guard requested else { return }
            searchFocused = true
            model.searchRequested = false
        }
    }

    private var actions: TicketsActions {
        TicketsActions(
            open: model.openTicket,
            force: { model.openForceSheet($0) },
            stopForcing: model.stopForcing,
            canForce: model.dispatchControl.canForce
        )
    }
}

/// What Tickets' rows and inspector do.
struct TicketsActions {
    var open: (String) -> Void = { _ in }
    var force: (String) -> Void = { _ in }
    var stopForcing: (String) -> Void = { _ in }
    var canForce = true
}

/// The scope bar, the table (C19) and the inspector.
struct TicketsView: View {
    let list: TicketList
    @Binding var filter: TicketList.Filter
    let search: String
    @Binding var selection: String?
    @Binding var inspectorShown: Bool
    let actions: TicketsActions
    @State private var sortOrder = TicketList.defaultSort
    /// The table's own selection, handed to the model after the table's delegate call returns: updating the
    /// window's model inside it re-renders the table reentrantly.
    @State private var tableSelection: String?

    var body: some View {
        let rows = list.rows(filter: filter, search: search).sorted(using: sortOrder)
        VStack(spacing: 0) {
            TicketsScopeBar(list: list, filter: $filter, inspectorShown: inspectorShown)
            Divider()
            if rows.isEmpty {
                EmptyState(title: search.isEmpty ? TicketList.emptyTitle : TicketList.noMatchTitle, symbol: SymphonyView.tickets.symbol)
            } else {
                TicketsTable(rows: rows, selection: $tableSelection, sortOrder: $sortOrder, actions: actions)
                    .onKeyPress(.space) {
                        inspectorShown.toggle()
                        return .handled
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
        .inspector(isPresented: $inspectorShown) {
            TicketInspector(row: selection.flatMap(list.row), actions: actions)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
    }
}

/// The stages to show, with their counts; the last ones fold into More while the inspector is open.
struct TicketsScopeBar: View {
    let list: TicketList
    @Binding var filter: TicketList.Filter
    let inspectorShown: Bool

    var body: some View {
        // Scrolls rather than widening the window when the stages don't fit.
        ScrollView(.horizontal, showsIndicators: false) {
            bar
        }
    }

    private var bar: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            Picker("Stage", selection: barSelection) {
                ForEach(TicketList.Filter.bar(inspectorShown: inspectorShown), id: \.self) { choice in
                    Text(label(choice)).tag(Optional(choice))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Menu {
                ForEach(TicketList.Filter.more(inspectorShown: inspectorShown), id: \.self) { choice in
                    Toggle(label(choice), isOn: Binding(get: { filter == choice }, set: { if $0 { filter = choice } }))
                }
            } label: {
                Text(barSelection.wrappedValue == nil ? "More: \(filter.title)" : "More")
            }
            .menuStyle(.button)
            .fixedSize()
            .help("More stages")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Space.s4)
        .padding(.vertical, DesignTokens.Space.s2)
    }

    /// The bar's choice, nil while the filter is one under More.
    private var barSelection: Binding<TicketList.Filter?> {
        Binding(
            get: { TicketList.Filter.bar(inspectorShown: inspectorShown).contains(filter) ? filter : nil },
            set: { if let choice = $0 { filter = choice } }
        )
    }

    private func label(_ choice: TicketList.Filter) -> String {
        choice == .all ? choice.title : "\(choice.title) \(list.count(choice))"
    }
}

/// C19: ticket, title, repo, stage, what it waits on and since when; Return or a double-click opens the ticket.
struct TicketsTable: View {
    let rows: [TicketList.Row]
    @Binding var selection: String?
    @Binding var sortOrder: [KeyPathComparator<TicketList.Row>]
    let actions: TicketsActions

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Ticket", value: \.identifier) { row in
                HStack(spacing: DesignTokens.Space.s1) {
                    Text(row.identifier).font(DesignTokens.TypeStyle.mono.font)
                    if row.forced {
                        Image(systemName: DesignTokens.Status.forced.symbol)
                            .foregroundStyle(DesignTokens.Status.forced.tint)
                            .accessibilityLabel("Forced")
                    }
                }
            }
            .width(min: 90, ideal: 100)
            TableColumn("Title", value: \.titleText) { row in
                Text(row.titleText).lineLimit(1)
            }
            .width(min: 140, ideal: 240)
            TableColumn("Repo", value: \.repoText)
                .width(min: 60, ideal: 90)
            TableColumn("Stage", value: \.stage) { row in
                HStack(spacing: DesignTokens.Space.s1) {
                    Image(systemName: row.needsAttention ? DesignTokens.Status.problem.symbol : row.stage.status.symbol)
                        .foregroundStyle(row.needsAttention ? DesignTokens.Status.problem.tint : row.stage.status.tint)
                        .accessibilityHidden(true)
                    Text(row.stage.title)
                }
            }
            .width(min: 90, ideal: 120)
            TableColumn("Waits on", value: \.waitsOn) { row in
                Text(row.waitsOn).lineLimit(1)
            }
            .width(min: 80, ideal: 130)
            TableColumn("Since", value: \.sinceSort) { row in
                Text(row.sinceText).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: String.self) { identifiers in
            if let identifier = identifiers.first, let row = rows.first(where: { $0.identifier == identifier }) {
                Button(TicketList.openTitle) { actions.open(identifier) }
                TicketForceButton(row: row, actions: actions)
            }
        } primaryAction: { identifiers in
            identifiers.first.map(actions.open)
        }
        .accessibilityLabel("Tickets")
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

/// The inspector: the selected ticket's facts in short, Open Ticket, and Force or Stop Forcing.
struct TicketInspector: View {
    let row: TicketList.Row?
    let actions: TicketsActions

    var body: some View {
        if let row {
            ScrollView {
                TicketInspectorBody(row: row, actions: actions)
            }
        } else {
            EmptyState(title: "Select a ticket.", symbol: "sidebar.right")
        }
    }
}

/// The inspector's facts and buttons, outside the scroll view so they also render offscreen.
struct TicketInspectorBody: View {
    let row: TicketList.Row
    let actions: TicketsActions

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                Text(row.identifier).font(DesignTokens.TypeStyle.mono.font).foregroundStyle(.secondary)
                Text(row.titleText).font(DesignTokens.TypeStyle.rowTitle.font).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DesignTokens.Space.s1) {
                StatusBadge(status: row.needsAttention ? .problem : row.stage.status, word: row.needsAttention ? DesignTokens.Status.problem.word : row.stage.title)
                if row.forced { StatusBadge(status: .forced) }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DesignTokens.Space.s3, verticalSpacing: DesignTokens.Space.s2) {
                ForEach(Array(row.facts.enumerated()), id: \.offset) { _, fact in
                    GridRow {
                        Text(fact.label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                        Text(fact.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(DesignTokens.TypeStyle.callout.font)
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

/// The toolbar's one custom glass element; with Reduce Transparency it is a solid `surface.raised` capsule.
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
        .buttonStyle(.plain)
        .help(control.canStart ? DispatchControl.startTitle : "Dispatch")
        .accessibilityLabel(control.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $model.dispatchPopoverShown, arrowEdge: .bottom) {
            DispatchPopover(
                control: control,
                working: model.dispatchInFlight,
                error: model.dispatchError,
                actions: DispatchPopover.Actions(
                    pause: model.openPauseSheet,
                    resume: model.resumeDispatch,
                    force: { model.openForceSheet() },
                    cancelUpdate: { model.performUpdateAction(.cancelUpdate) },
                    updateNow: { model.performUpdateAction(.updateNow) }
                )
            )
        }
    }
}

/// The control's face: status dot, word and chevron (or Start Symphony), on glass.
struct DispatchControlLabel: View {
    let control: DispatchControl
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            Circle()
                .fill(control.status.tint)
                .frame(width: 8, height: 8)
            Text(control.word)
                .foregroundStyle(control.mode == .paused ? AnyShapeStyle(control.status.tint) : AnyShapeStyle(.primary))
                .lineLimit(1)
            if control.canStart {
                Text(DispatchControl.startTitle).foregroundStyle(Color.accentColor)
            } else {
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .font(DesignTokens.TypeStyle.callout.font.weight(.medium))
        .padding(.horizontal, DesignTokens.Space.s3)
        .padding(.vertical, DesignTokens.Space.s1 + 2)
        .contentShape(Capsule())
        .modifier(DispatchGlass(reduceTransparency: reduceTransparency))
    }
}

/// `material.glass.control`, or `surface.raised` under Reduce Transparency.
struct DispatchGlass: ViewModifier {
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(DesignTokens.Surface.raised.color, in: Capsule())
        } else {
            content.glassEffect(.regular.interactive(), in: .capsule)
        }
    }
}

/// D12a: dispatch's state with what is working and queued, and its actions.
struct DispatchPopover: View {
    struct Actions {
        var pause: () -> Void = {}
        var resume: () -> Void = {}
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
                .font(DesignTokens.TypeStyle.callout.font)
                Text(control.update == nil ? "No new run starts until you resume, forced tickets included." : "No new run starts until the update ends, forced tickets included.")
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let line = control.update?.waitingLine {
                Text(line).font(DesignTokens.TypeStyle.callout.font)
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
                section("Held by", lines: control.limits, more: 0, empty: "")
            }
            section("Working", lines: control.working, more: control.moreWorking, empty: "Nothing is running.")
            section("Queued", lines: control.queued, more: control.moreQueued, empty: "Nothing is queued.")
            if let error {
                Label(error, systemImage: DesignTokens.Status.problem.symbol)
                    .font(DesignTokens.TypeStyle.callout.font)
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
                Text(empty).font(DesignTokens.TypeStyle.callout.font).foregroundStyle(.tertiary)
            }
            ForEach(lines, id: \.self) { line in
                Text(line).font(DesignTokens.TypeStyle.callout.font).lineLimit(1)
            }
            if more > 0 {
                Text("and \(more) more").font(DesignTokens.TypeStyle.callout.font).foregroundStyle(.secondary)
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
                    .font(DesignTokens.TypeStyle.callout.font)
                }
                if let summary = ForceSheet.summary(input, in: list) {
                    Text(summary)
                        .font(DesignTokens.TypeStyle.callout.font)
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
                    .font(DesignTokens.TypeStyle.callout.font)
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
