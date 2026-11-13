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

/// More: a menu button holding the rarer moves; Stop Run… last, under a separator, in red. A refused item stays in
/// the menu, disabled, with the read's reason under its title. The arrow keys move between its items and Escape
/// closes it, as every menu does.
private struct RailMore: View {
    let items: [TicketActionRail.Item]
    let open: Bool
    let press: (TicketActionRail.Move, String?) -> Void
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    private var common: [TicketActionRail.Item] { items.filter { !$0.destructive } }
    private var destructive: [TicketActionRail.Item] { items.filter(\.destructive) }

    var body: some View {
        if offscreenSnapshot {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                Button {} label: { label }
                    .directorButton(selected: open)
                if open { RailMoreList(common: common, destructive: destructive) }
            }
        } else {
            Menu {
                ForEach(common) { item in entry(item) }
                if !destructive.isEmpty {
                    Divider()
                    ForEach(destructive) { item in entry(item) }
                }
            } label: {
                label
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .directorButton()
            .fixedSize()
            .help("More moves")
            .accessibilityLabel("More moves")
        }
    }

    private var label: some View {
        HStack(spacing: DesignTokens.Space.s1) {
            Text("More")
            Image(systemName: "chevron.down").imageScale(.small).accessibilityHidden(true)
        }
    }

    @ViewBuilder private func entry(_ item: TicketActionRail.Item) -> some View {
        if item.move == .moveTo, item.allowed {
            Menu(item.title) {
                ForEach(item.states, id: \.self) { state in
                    Button(state) { press(.moveTo, state) }
                }
            }
        } else {
            Button(role: item.destructive ? .destructive : nil) {
                press(item.move, nil)
            } label: {
                Text(item.title)
                if let reason = item.reason { Text(reason) }
            }
            .disabled(!item.allowed)
            .accessibilityLabel(TicketActionRail.accessibilityLabel(item))
        }
    }
}

/// More drawn open for a snapshot: its items as the menu lists them, a refused one faint with its reason, Stop Run…
/// last under a separator in red.
private struct RailMoreList: View {
    let common: [TicketActionRail.Item]
    let destructive: [TicketActionRail.Item]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(common) { row($0) }
            if !destructive.isEmpty {
                Divider().padding(.vertical, 3)
                ForEach(destructive) { row($0) }
            }
        }
        .padding(DesignTokens.Space.s1)
        .frame(width: 240, alignment: .leading)
        .background(DesignTokens.Surface.raised.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DesignTokens.Surface.separator.color))
    }

    private func row(_ item: TicketActionRail.Item) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: DesignTokens.Space.s1) {
                Text(item.title)
                if item.move == .moveTo, item.allowed {
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").imageScale(.small).accessibilityHidden(true)
                }
            }
            .foregroundStyle(item.allowed ? (item.destructive ? Color.red : Color.primary) : Color.secondary.opacity(0.6))
            if let reason = item.reason {
                Text(reason)
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(DesignTokens.TypeStyle.body.font)
        .padding(.horizontal, DesignTokens.Space.s2)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
