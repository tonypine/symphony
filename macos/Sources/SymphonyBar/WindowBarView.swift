import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

// The window's own bar (TP-1496) as the window model fills it, and the row at the top of a sidebar page that holds the
// controls the system toolbar held for that page alone, until each lives in its page (TP-1497).

// MARK: - The window model's bar

extension SymphonyWindowModel {
    /// Where the window is: the destination, or on a page the destination it was opened from, the ticket's epic and
    /// its identifier.
    var breadcrumb: WindowBreadcrumb {
        WindowBreadcrumb(place: history.current, shownFrom: selection, epic: shownTicket == nil ? nil : ticketEpic)
    }

    /// What the bar shows, with the sidebar `sidebarShown`.
    func windowBarControls(sidebarShown: Bool) -> WindowBarControls {
        WindowBarControls(
            sidebarShown: sidebarShown, canGoBack: canGoBack, canGoForward: history.canGoForward, breadcrumb: breadcrumb,
            inboxCount: inboxBadge, inboxShown: presentsInboxDrawer && inboxDrawerShown, checksSetup: showsSetupCheck,
            refreshing: showsSetupCheck && setupChecking
        )
    }

    /// Work's Initiatives and Tickets switch follows the breadcrumb on Work, while no ticket is open.
    var showsWorkSwitch: Bool { !showsPage && destination == .work }

    /// A breadcrumb link: the page the ticket was opened from, or Initiatives on its epic. Either is a visit, so Back
    /// returns to the ticket.
    func go(_ crumb: Crumb) {
        switch crumb.target {
        case let .view(view):
            show(view)
        case let .initiative(identifier):
            if let epic = initiatives?.initiatives.first(where: { $0.identifier == identifier }) {
                showInitiative(epic.id)
            } else {
                show(.initiatives)
            }
        case nil:
            break
        }
    }

    /// The bar's Inbox: its drawer where the window draws one (Home, a ticket's page), else Home with the drawer.
    func windowBarInbox() {
        if presentsInboxDrawer {
            toggleInboxDrawer()
        } else {
            showInbox()
        }
    }
}

// MARK: - The bar

/// The window's bar as the window model fills it: the same controls on every page, the breadcrumb and Work's switch
/// following the place shown. ⌘F (the View menu's Find a Ticket) puts the keyboard in Find a ticket; what it finds is
/// listed under it while it has the keyboard.
struct DirectorWindowBar: View {
    @ObservedObject var model: SymphonyWindowModel
    let sidebarShown: Bool
    let toggleSidebar: () -> Void
    @FocusState private var findFocused: Bool

    var body: some View {
        WindowBar(
            model.windowBarControls(sidebarShown: sidebarShown),
            actions: WindowBarActions(
                toggleSidebar: toggleSidebar, goBack: model.goBack, goForward: model.goForward, go: model.go,
                find: { model.openFound(model.findQuery) }, inbox: model.windowBarInbox, refresh: model.refresh
            ),
            findText: $model.findQuery, findFocus: $findFocused, findRequest: $model.findRequested,
            workSwitch: model.showsWorkSwitch ? workSwitch : nil
        ) {
            if findFocused {
                FindTicketResults(query: model.findQuery, tickets: model.allTickets, open: model.openFound)
            }
        }
        // The list under Find a ticket is drawn over the page.
        .zIndex(1)
    }

    private var workSwitch: SegmentedControl<SymphonyView> {
        SegmentedControl(
            WindowBarText.workSwitch, selection: Binding(get: { model.selection }, set: { model.show($0) }),
            segments: Destination.work.pages.map { Segment($0, $0.title) }, size: .small
        )
    }
}

/// What Find a ticket found, under it: each match a row that opens its ticket's page, with the catalog's hover; with a
/// query and no match, what it searched. Nothing while the field is empty.
struct FindTicketResults: View {
    let query: String
    let tickets: TicketList?
    let open: (String) -> Void

    var body: some View {
        if DesignTokens.Field.hasQuery(query) {
            let matches = TicketFinder.matches(query, in: tickets)
            let shape = RoundedRectangle(cornerRadius: DesignTokens.Menu.radius, style: .continuous)
            VStack(alignment: .leading, spacing: 0) {
                if matches.isEmpty {
                    Text(DesignTokens.Field.noMatch(query, searched: TicketFinder.searched))
                        .font(DesignTokens.TypeStyle.secondary.font)
                        .foregroundStyle(DesignTokens.TextColor.secondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(DesignTokens.Menu.itemInset)
                } else {
                    ForEach(matches) { row in
                        Button { open(row.identifier) } label: {
                            Text(TicketFinder.line(row))
                                .font(DesignTokens.TypeStyle.body.font)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, DesignTokens.Space.s1)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .rowStyle()
                        .accessibilityLabel(row.accessibilityLabel(reference: tickets?.reference ?? Date()))
                    }
                }
            }
            .padding(DesignTokens.Menu.padding)
            .background { Color.clear.glassBackground(DesignTokens.Glass.thick, in: shape) }
            .elevation(DesignTokens.Menu.elevation, in: shape)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - A page's own controls

/// The row at the top of a sidebar page: Insights' tabs, then at the right what the system toolbar held for the page
/// alone: Shipped's Shipped and Learnings switch, the page's search (Tickets', Learnings', Audit's), Audit's Export…,
/// Tickets' Force a Ticket, and the scope on the pages that read it. Nothing on a page that has none of them (Setup,
/// Diagnostics). The page's own ticket, TP-1497, moves each into the page.
struct PageControlsRow: View {
    @ObservedObject var model: SymphonyWindowModel

    var body: some View {
        if hasControls {
            VStack(spacing: 0) {
                HStack(spacing: DesignTokens.Space.s2) {
                    if model.destination == .insights {
                        SegmentedControl(
                            "\(model.destination.title) tabs", selection: Binding(get: { model.selection }, set: { model.show($0) }),
                            segments: model.destination.pages.map { Segment($0, $0.title) }, size: .small
                        )
                    }
                    Spacer(minLength: 0)
                    pageControls
                    if Self.readsScope(model.selection) {
                        ScopePicker(model: model)
                    }
                }
                .padding(.horizontal, DesignTokens.Space.s4)
                .padding(.vertical, DesignTokens.Space.s2)
                HairlineDivider()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var hasControls: Bool { model.destination == .insights || Self.readsScope(model.selection) }

    /// The pages whose rows the window's scope narrows; Setup and Diagnostics are Symphony's own.
    static func readsScope(_ view: SymphonyView) -> Bool { ![.setup, .diagnostics, .repos, .settings].contains(view) }

    @ViewBuilder private var pageControls: some View {
        switch model.selection {
        case .tickets:
            PageSearchField(
                prompt: TicketsView.searchPrompt, text: $model.ticketSearch,
                matches: model.ticketsPayload.map { _ in model.ticketRows.count }, requested: $model.searchRequested
            )
            Button(DispatchControl.forceTitle) { model.openForceSheet() }
                .buttonStyle(DirectorButtonStyle(kind: .secondary, size: .small, glyph: DesignTokens.Status.forced.symbol))
                .help("Force a ticket (⇧⌘F)")
                .disabled(!model.dispatchControl.canForce)
        case .shipped:
            SegmentedControl(
                "Shipped or Learnings", selection: $model.shippedTab,
                segments: Shipped.Tab.allCases.map { Segment($0, $0.title) }, size: .small
            )
            if model.shippedTab == .learnings {
                PageSearchField(
                    prompt: Learnings.searchPrompt, text: $model.learningsFilter.search,
                    matches: model.learnings.map { Learnings(payload: $0, filter: model.learningsFilter, scope: model.scope).count },
                    requested: $model.learningsSearchRequested
                )
            }
        case .audit:
            PageSearchField(
                prompt: Audit.searchPrompt, text: $model.auditFilter.search, matches: model.auditView?.rows.count,
                requested: $model.auditSearchRequested
            )
            Button(Audit.exportTitle) { model.exportAudit() }
                .buttonStyle(DirectorButtonStyle(kind: .secondary, size: .small, glyph: "square.and.arrow.up"))
                .help("Export the filtered records as NDJSON")
                .disabled(model.auditExporting || model.auditRecords == nil)
        default:
            EmptyView()
        }
    }
}
