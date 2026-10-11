import SwiftUI
import SymphonyBarCore

/// The repo's state-machine version as radio buttons, each with its one-line explanation under it.
struct StateMachinePicker: View {
    @Binding var choice: StateMachineChoice

    var body: some View {
        Picker(StateMachine.pickerTitle, selection: $choice) {
            ForEach(StateMachineChoice.allCases) { option in
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                    Text(option.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tag(option)
            }
        }
        .pickerStyle(.radioGroup)
    }
}
