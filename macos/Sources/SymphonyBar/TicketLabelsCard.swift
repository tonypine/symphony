import SwiftUI
import SymphonyBarCore

/// The ticket page's Labels card (TP-1356): each label a person adds for Symphony to read as a toggle, its one-line
/// effect under its name. Under them, while needed, one line: the change on its way, or why Symphony refused the last one.
struct TicketLabelsCard: View {
    let identifier: String
    @ObservedObject var editor: TicketLabelsEditor
    let set: (String, Bool) -> Void
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            switch editor.load {
            case .unread:
                note(TicketLabelsEditor.readingReason)
            case .unavailable:
                note(TicketLabelsEditor.unavailableReason)
            case .loaded:
                ForEach(editor.toggles) { toggle in row(toggle) }
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

    private func label(_ toggle: TicketLabelToggle) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(toggle.title).font(DesignTokens.TypeStyle.body.font)
            Text(toggle.effect)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func row(_ toggle: TicketLabelToggle) -> some View {
        if offscreenSnapshot {
            // `ImageRenderer` can't draw an AppKit checkbox: a symbol of its state stands in.
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                Image(systemName: toggle.on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(toggle.on ? Color.accentColor : Color.secondary)
                label(toggle)
            }
        } else {
            Toggle(isOn: Binding(get: { toggle.on }, set: { set(toggle.label, $0) })) {
                label(toggle)
            }
            .toggleStyle(.checkbox)
            .disabled(!editor.canToggle(toggle.label))
            .accessibilityLabel(TicketLabelsEditor.toggleLabel(identifier, toggle))
        }
    }

    @ViewBuilder private var status: some View {
        if let label = editor.sending, let toggle = editor.toggles.first(where: { $0.label == label }) {
            Text(TicketLabelsEditor.sendingTitle(toggle))
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
        } else if let refusal = editor.refusal {
            Label(refusal, systemImage: DesignTokens.Status.problem.symbol)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(DesignTokens.Status.problem.tint)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityLabel(TicketLabelsEditor.refusalLabel(refusal))
        }
    }
}
