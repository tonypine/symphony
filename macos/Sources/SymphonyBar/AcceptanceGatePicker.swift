import SwiftUI
import SymphonyBarCore

/// The acceptance gate's mode as radio buttons, each with its one-line explanation under it. Picking Enforce asks
/// first; Cancel leaves the mode as it was.
struct AcceptanceGatePicker: View {
    @Binding var choice: AcceptanceGateChoice
    /// The choice waiting for the Enforce confirmation, kept by the owner's model.
    @Binding var pending: AcceptanceGateChoice?
    /// The choices offered: Settings' picker has no Inherit.
    let choices: [AcceptanceGateChoice]
    /// The mode in Settings, which Inherit follows.
    let inherited: AcceptanceGateMode

    var body: some View {
        Picker(AcceptanceGate.pickerTitle, selection: Binding(get: { choice }, set: choose)) {
            ForEach(choices) { option in
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title(inheriting: inherited))
                    Text(option.explanation(inheriting: inherited))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tag(option)
            }
        }
        .pickerStyle(.radioGroup)
        .alert(
            AcceptanceGate.confirmTitle,
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
        ) {
            Button(AcceptanceGate.confirmButton, role: .destructive) {
                if let pending { choice = pending }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(AcceptanceGate.confirmMessage)
        }
    }

    private func choose(_ new: AcceptanceGateChoice) {
        let current = choice.effective(inheriting: inherited)
        if AcceptanceGate.needsConfirmation(from: current, to: new.effective(inheriting: inherited)) {
            pending = new
        } else {
            choice = new
        }
    }
}
