import SwiftUI
import SymphonyBarCore

/// The ticket page's Decisions card (TP-1357): one row per decision recorded on the ticket (its label and date, what it
/// answered, the answer), then the Record a decision field and its button. Under them, while needed, one line: the ruling
/// on its way, or why Symphony refused the last one.
struct TicketDecisionsCard: View {
    let identifier: String
    @ObservedObject var editor: TicketDecisionsEditor
    let record: () -> Void
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            switch editor.load {
            case .unread:
                note(TicketDecisionsEditor.readingReason)
            case .unavailable:
                note(TicketDecisionsEditor.unavailableReason)
            case .loaded:
                if editor.decisions.isEmpty {
                    note(TicketDecisionsEditor.emptyReason)
                } else {
                    ForEach(editor.decisions) { decision in row(decision) }
                }
                recordRow
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

    private func row(_ decision: TicketDecision) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                Text(decision.id).font(DesignTokens.TypeStyle.rowTitle.font)
                if let title = decision.title {
                    Text(title).font(DesignTokens.TypeStyle.callout.font).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: DesignTokens.Space.s2)
                if let date = decision.date {
                    Text(date).font(DesignTokens.TypeStyle.callout.font).foregroundStyle(.secondary)
                }
            }
            Text(decision.answer)
                .font(DesignTokens.TypeStyle.body.font)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TicketDecisionsEditor.rowLabel(decision))
    }

    private var recordRow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            HStack(alignment: .top, spacing: DesignTokens.Space.s2) {
                if offscreenSnapshot {
                    Text(editor.text.isEmpty ? TicketDecisionsEditor.placeholder : editor.text)
                        .font(DesignTokens.TypeStyle.body.font)
                        .foregroundStyle(editor.text.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .lineLimit(3)
                        .padding(.horizontal, DesignTokens.Space.s2)
                        .padding(.vertical, DesignTokens.Space.s1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(DesignTokens.Surface.separator.color))
                } else {
                    TextField(TicketDecisionsEditor.placeholder, text: $editor.text, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .onSubmit { if editor.canRecord { record() } }
                        .disabled(editor.sending)
                        .accessibilityLabel(TicketDecisionsEditor.fieldLabel(identifier))
                        .accessibilityHint(TicketDecisionsEditor.hint)
                }
                Button(TicketDecisionsEditor.buttonTitle, action: record)
                    .disabled(!editor.canRecord)
                    .accessibilityLabel(TicketDecisionsEditor.buttonLabel(identifier))
            }
            Text(TicketDecisionsEditor.hint)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var status: some View {
        if editor.sending {
            Text(TicketDecisionsEditor.sendingTitle)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
        } else if let refusal = editor.refusal {
            Label(refusal, systemImage: DesignTokens.Status.problem.symbol)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(DesignTokens.Status.problem.tint)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityLabel(TicketDecisionsEditor.refusalLabel(refusal))
        }
    }
}
