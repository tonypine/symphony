import SwiftUI
import SymphonyBarCore

/// The ticket page's Priority card (TP-1355): the ticket's Linear priority in a menu of Linear's five, a pick setting
/// it. Under it, while needed, one line: the change on its way, or why Symphony refused the last one.
struct TicketPriorityCard: View {
    let identifier: String
    @ObservedObject var editor: TicketPriorityEditor
    let set: (TicketPriority) -> Void
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            switch editor.load {
            case .unread:
                note(TicketPriorityEditor.readingReason)
            case .unavailable:
                note(TicketPriorityEditor.unavailableReason)
            case .loaded:
                menu
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

    @ViewBuilder private var menu: some View {
        if offscreenSnapshot {
            // `ImageRenderer` can't draw a menu: its title and chevron stand in.
            HStack(spacing: DesignTokens.Space.s1) {
                Text(editor.priority?.title ?? "—").font(DesignTokens.TypeStyle.body.font)
                Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
            }
        } else {
            Menu {
                ForEach(TicketPriorityEditor.choices, id: \.self) { priority in
                    Button {
                        set(priority)
                    } label: {
                        if priority == editor.priority {
                            Label(priority.title, systemImage: "checkmark")
                        } else {
                            Text(priority.title)
                        }
                    }
                    .disabled(!editor.canSet(priority))
                }
            } label: {
                Text(editor.priority?.title ?? "—")
            }
            .fixedSize()
            .disabled(editor.sending)
            .accessibilityLabel(TicketPriorityEditor.menuLabel(identifier, editor.priority))
        }
    }

    @ViewBuilder private var status: some View {
        if editor.sending {
            Text(TicketPriorityEditor.sendingTitle)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
        } else if let refusal = editor.refusal {
            Label(refusal, systemImage: DesignTokens.Status.problem.symbol)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(DesignTokens.Status.problem.tint)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityLabel(TicketPriorityEditor.refusalLabel(refusal))
        }
    }
}
