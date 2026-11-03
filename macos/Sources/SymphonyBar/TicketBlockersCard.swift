import SwiftUI
import SymphonyBarCore

/// The ticket page's Blocked by card (TP-1354): one row per blocker (its identifier opens its page, Remove unlinks it),
/// then the add field, its Pick a Ticket menu of the open tickets Symphony tracks, and Add Blocker. Under them, while
/// needed, one line: the change on its way, or why Symphony refused the last one.
struct TicketBlockersCard: View {
    let identifier: String
    @ObservedObject var editor: TicketBlockersEditor
    let add: (String?) -> Void
    let remove: (String) -> Void
    var open: (String) -> Void = { _ in }
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            switch editor.load {
            case .unread:
                note(TicketBlockersEditor.readingReason)
            case .unavailable:
                note(TicketBlockersEditor.unavailableReason)
            case .loaded:
                if editor.blockers.isEmpty {
                    note(TicketBlockersEditor.empty)
                } else {
                    ForEach(editor.blockers) { blocker in row(blocker) }
                }
                addRow
                status
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.TypeStyle.body.font)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ blocker: TicketBlockersEditor.Ticket) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            if offscreenSnapshot {
                // `ImageRenderer` can't draw a link button: its text stands in.
                Text(blocker.identifier).font(DesignTokens.TypeStyle.body.font).foregroundStyle(Color.accentColor)
            } else {
                Button(blocker.identifier) { open(blocker.identifier) }
                    .buttonStyle(.link)
                    .accessibilityLabel(blocker.accessibilityLabel)
            }
            VStack(alignment: .leading, spacing: 0) {
                if let title = blocker.title {
                    Text(title).font(DesignTokens.TypeStyle.body.font).lineLimit(2)
                }
                if let state = blocker.state {
                    Text(state).font(DesignTokens.TypeStyle.callout.font).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
            Button(TicketBlockersEditor.removeTitle) { remove(blocker.identifier) }
                .controlSize(.small)
                .disabled(editor.sending)
                .accessibilityLabel(TicketBlockersEditor.removeLabel(blocker.identifier))
        }
    }

    private var addRow: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            if offscreenSnapshot {
                Text(editor.entry.isEmpty ? TicketBlockersEditor.placeholder : editor.entry)
                    .font(DesignTokens.TypeStyle.body.font)
                    .foregroundStyle(editor.entry.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .padding(.horizontal, DesignTokens.Space.s2)
                    .padding(.vertical, DesignTokens.Space.s1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(DesignTokens.Surface.separator.color))
            } else {
                TextField(TicketBlockersEditor.placeholder, text: $editor.entry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if editor.canAdd { add(nil) } }
                    .accessibilityLabel(TicketBlockersEditor.fieldLabel(identifier))
            }
            if offscreenSnapshot {
                // `ImageRenderer` can't draw a menu: its symbol stands in.
                Image(systemName: "list.bullet").foregroundStyle(.secondary)
            } else {
                pickMenu
            }
            Button(TicketBlockersEditor.addTitle) { add(nil) }
                .disabled(!editor.canAdd)
        }
    }

    private var pickMenu: some View {
        Menu {
            if editor.suggestions.isEmpty {
                Text("No open ticket to pick")
            } else {
                ForEach(editor.suggestions) { ticket in
                    Button([ticket.identifier, ticket.title].compactMap { $0 }.joined(separator: " ")) { add(ticket.identifier) }
                }
            }
        } label: {
            Image(systemName: "list.bullet")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(editor.sending)
        .help(TicketBlockersEditor.pickTitle)
        .accessibilityLabel(TicketBlockersEditor.pickTitle)
    }

    @ViewBuilder private var status: some View {
        if editor.sending {
            Text(TicketBlockersEditor.sendingTitle)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
        } else if let refusal = editor.refusal {
            Label(refusal, systemImage: DesignTokens.Status.problem.symbol)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(DesignTokens.Status.problem.tint)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityLabel(TicketBlockersEditor.refusalLabel(refusal))
        }
    }
}
