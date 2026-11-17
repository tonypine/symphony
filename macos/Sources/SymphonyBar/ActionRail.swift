import AppKit
import SwiftUI
import SymphonyBarCore

/// C31, the Action rail (TP-1440, TP-1485): a ticket's moves in one row of medium buttons, in the prototype's order.
/// The expected move first and primary, then Open Pull Request and Force; on a desktop a separator and Stop Run… in red;
/// then More. A move the read refuses stays in its place, faint, with a not-allowed pointer, and shows the read's
/// reason under it without a press. The rail keeps no state of its own: it changes when the read does.
///
/// Pressing a move hands `perform` its request: a control call to send, the consequence sheet to show first, a link to
/// open or text to copy. Cancel Ticket… asks here before its call goes. The rail wraps onto a second line before any
/// button shrinks.
struct ActionRail: View {
    let rail: TicketActionRail
    let perform: (TicketActionRail.Request) -> Void
    /// Snapshots only: More drawn open, as a list under its button (`ImageRenderer` can't draw a menu).
    var moreOpen = false
    @State private var confirming: TicketActionRail.Confirmation?

    /// The glyph before Open Pull Request (the catalog's `pr`).
    static let pullRequestGlyph = "arrow.triangle.pull"

    var body: some View {
        WrappingStack(spacing: DesignTokens.Space.s2) {
            if let primary = rail.primary {
                move(primary, kind: .primary)
            }
            ForEach(rail.secondary) { item in
                move(item, kind: .secondary)
            }
            if rail.stopOnRail, let stop = rail.stop {
                // `.rail-sep`: a 1 pt hairline, 20 pt tall, between the common moves and the destructive one.
                Rectangle()
                    .fill(DesignTokens.ColorToken.strokeSeparator.color)
                    .frame(width: 1, height: 20)
                    .padding(.horizontal, DesignTokens.Space.s1)
                    .frame(height: DesignTokens.Control.medium.height)
                    .accessibilityHidden(true)
                move(stop, kind: .destructive)
            }
            if !rail.moreGroups.isEmpty {
                RailMore(groups: rail.moreGroups, open: moreOpen, press: press)
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
            .directorButton(
                item.allowed || kind == .destructive ? kind : .secondary, glyph: Self.glyph(item.move), disabledReason: item.reason
            )
    }

    /// The catalog's glyph before a move's title: `pr` before Open Pull Request, `forced` before Force.
    static func glyph(_ move: TicketActionRail.Move) -> String? {
        switch move {
        case .openPullRequest: pullRequestGlyph
        case .force, .unforce: DesignTokens.Status.forced.symbol
        default: nil
        }
    }

    private func press(_ move: TicketActionRail.Move, _ state: String?) {
        switch rail.request(move, state: state) {
        case let .confirm(confirmation)?: confirming = confirmation
        case let request?: perform(request)
        case nil: break
        }
    }
}

/// More: a menu button (C54) holding the rarer moves, opening at its trailing edge, in groups under separators: Move
/// to…, Restart… and the other moves not on the rail; Copy Link, Copy Workspace Path and Open in Linear; and on a laptop
/// Stop Run… last, in red. A refused item stays in the menu, off, with the read's reason as its help. Move to… opens the
/// phases beside it. The arrow keys move between its items and Escape closes it, as every menu does.
private struct RailMore: View {
    let groups: [[TicketActionRail.Item]]
    let open: Bool
    let press: (TicketActionRail.Move, String?) -> Void

    var body: some View {
        MenuButton(
            "More", alignment: .trailing, help: "More moves", accessibilityLabel: "More moves", drawnOpen: open
        ) {
            groups.enumerated().flatMap { index, group in (index == 0 ? [] : [MenuItem.separator]) + group.map(entry) }
        }
    }

    private func entry(_ item: TicketActionRail.Item) -> MenuItem {
        if item.move == .moveTo, item.allowed {
            return .submenu(item.title, items: item.states.map { state in MenuItem(state) { press(.moveTo, state) } })
        }
        return MenuItem(item.title, destructive: item.destructive, disabledReason: item.reason) { press(item.move, nil) }
    }
}
