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

    /// What the bar shows, with the sidebar `sidebarShown`; the Inbox's count marked not current while Symphony is
    /// late (TP-1562).
    func windowBarControls(sidebarShown: Bool) -> WindowBarControls {
        WindowBarControls(
            sidebarShown: sidebarShown, canGoBack: canGoBack, canGoForward: history.canGoForward, breadcrumb: breadcrumb,
            inboxCount: inboxBadge, inboxCountCurrent: state.countsCurrent, inboxShown: presentsInboxDrawer && inboxDrawerShown,
            findShortcut: commandF.findTicketShortcut
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
                        .buttonStyle(.plainPointer)
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

extension SymphonyWindowModel {
    /// The shown page's own controls (TP-1497).
    var pageControls: PageControls { showsPage ? .none : PageControls.of(selection, shippedTab: shippedTab) }

    /// Where ⌘F puts the keyboard on the page shown: Find a ticket while Tickets or Audit draw no bar, so no search.
    var commandF: FindCommand {
        FindCommand.commandF(selection, showsPage: showsPage, shippedTab: shippedTab, searchShown: pageSearchShown)
    }

    /// Whether the page shown draws its search: Tickets once its tickets read, Audit once its records read. Shipped's
    /// Learnings bar stays at the top while the learnings read, with its search.
    var pageSearchShown: Bool {
        switch selection {
        case .tickets: ticketsPayload != nil
        case .audit: auditRecords != nil
        default: true
        }
    }

    /// The window's part of the shown page's control bar: the scope when the page reads it.
    var pageBar: PageBar {
        PageBar(
            scope: pageControls.readsScope ? Binding(get: { self.scope }, set: { self.scope = $0 }) : nil,
            repos: overviewState?.repos ?? []
        )
    }
}

/// The window's controls a page's control bar holds: the scope pop-up (nil on a page that doesn't read the scope).
/// The page puts it first, at the left, with what narrows it.
struct PageBar {
    var scope: Binding<OverviewScope>?
    var repos: [String] = []

    /// The scope pop-up, or nothing on a page that doesn't read the scope.
    @ViewBuilder var scopePopUp: some View {
        if let scope {
            ScopePopUp(scope: scope, repos: repos)
        }
    }
}

/// C3: the scope pop-up (C53), all repos or one of the repos Symphony has tickets in, its value always shown: "All
/// repos", or the repo picked even when Symphony no longer lists it.
struct ScopePopUp: View {
    @Binding var scope: OverviewScope
    let repos: [String]

    var body: some View {
        let choices = OverviewScope.choices(repos: repos, current: scope)
        PopUp(
            nil, selection: $scope,
            choices: choices.enumerated().map { PopUpChoice($1, $1.title, separatorBefore: $0 == 1) },
            value: scope.title, size: DesignTokens.ControlBar.control, help: "Show all repos or one",
            accessibilityLabel: scope.accessibilityLabel
        )
    }
}

/// Insights' tabs over its page (Quality, Usage, Shipped), whose one control bar is the page's (TP-1463). Work's tabs
/// are the window bar's switch (TP-1496); no other destination has tabs.
struct InsightsTabs: View {
    @ObservedObject var model: SymphonyWindowModel

    var body: some View {
        if model.destination == .insights, model.destination.pages.count >= DesignTokens.Segmented.fewest {
            SegmentedControl(
                "\(model.destination.title) tabs", selection: Binding(get: { model.selection }, set: { model.show($0) }),
                segments: model.destination.pages.map { Segment($0, $0.title) }, size: .small
            )
            .padding(.top, DesignTokens.ControlBar.pageGap)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Setup's control bar: Check Again at the right (SU3), "Checking…" while Symphony runs its checks, when a press
/// starts nothing more. ⌘R runs it too.
struct SetupControlBar: View {
    let checking: Bool
    let check: () -> Void

    static let checkingTitle = "Checking…"

    var body: some View {
        ControlBar("Setup controls") {
            EmptyView()
        } act: {
            Button(checking ? Self.checkingTitle : SetupPage.checkAgainTitle, action: check)
                .directorButton(.secondary, size: DesignTokens.ControlBar.control, glyph: "arrow.clockwise", selected: checking)
                .help(WindowBarText.checkAgain)
        }
    }
}

/// Initiatives' control bar: the scope.
struct InitiativesControlBar: View {
    let bar: PageBar

    var body: some View {
        ControlBar("Initiatives controls") {
            bar.scopePopUp
        }
    }
}
