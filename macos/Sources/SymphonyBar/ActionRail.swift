import AppKit
import SwiftUI
import SymphonyBarCore

/// C31, the Action rail (TP-1440): a ticket's moves in one row of medium buttons, drawn from the ticket read's
/// `moves` and nothing else. The expected move first and primary, then the common ones, then More for the rest with
/// Stop Run… last and in red. A move the read refuses stays in its place, faint, with a not-allowed pointer, and shows
/// the read's reason under it. The rail keeps no state of its own: it changes when the read does.
///
/// Pressing a move hands `perform` its request: a control call to send, or the consequence sheet to show first. Cancel
/// Ticket… asks here before its call goes. The rail wraps onto a second line before any button shrinks.
struct ActionRail: View {
    let rail: TicketActionRail
    let perform: (TicketActionRail.Request) -> Void
    /// Snapshots only: More drawn open, as a list under its button (`ImageRenderer` can't draw a menu).
    var moreOpen = false
    @State private var confirming: TicketActionRail.Confirmation?

    var body: some View {
        WrappingStack(spacing: DesignTokens.Space.s2) {
            if let primary = rail.primary {
                move(primary, kind: .primary)
            }
            ForEach(rail.secondary) { item in
                move(item, kind: .secondary)
            }
            if !rail.more.isEmpty {
                RailMore(items: rail.more, open: moreOpen, press: press)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Moves")
        .confirmationDialog(
            confirming?.title ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { confirmation in
            Button(confirmation.button, role: .destructive) { perform(.send(confirmation.action)) }
            Button("Keep It", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    /// A move on the rail: the catalog's medium button, disabled with the read's reason under it.
    private func move(_ item: TicketActionRail.Item, kind: ButtonKind) -> some View {
        Button(item.title) { press(item.move, nil) }
            .accessibilityLabel(TicketActionRail.accessibilityLabel(item))
            .directorButton(item.allowed ? kind : .secondary, disabledReason: item.reason)
    }

    private func press(_ move: TicketActionRail.Move, _ state: String?) {
        switch rail.request(move, state: state) {
        case let .confirm(confirmation)?: confirming = confirmation
        case let request?: perform(request)
        case nil: break
        }
    }
}

/// More: a menu button (C54) holding the rarer moves, opening at its trailing edge; Stop Run… last, under a separator,
/// in red. A refused item stays in the menu, off, with the read's reason as its help. Move to… opens the phases beside
/// it. The arrow keys move between its items and Escape closes it, as every menu does.
private struct RailMore: View {
    let items: [TicketActionRail.Item]
    let open: Bool
    let press: (TicketActionRail.Move, String?) -> Void

    var body: some View {
        MenuButton(
            "More", alignment: .trailing, help: "More moves", accessibilityLabel: "More moves", drawnOpen: open
        ) {
            let common = items.filter { !$0.destructive }.map(entry)
            let destructive = items.filter(\.destructive).map(entry)
            return destructive.isEmpty ? common : common + [.separator] + destructive
        }
    }

    private func entry(_ item: TicketActionRail.Item) -> MenuItem {
        if item.move == .moveTo, item.allowed {
            return .submenu(item.title, items: item.states.map { state in MenuItem(state) { press(.moveTo, state) } })
        }
        return MenuItem(item.title, destructive: item.destructive, disabledReason: item.reason) { press(item.move, nil) }
    }
}
