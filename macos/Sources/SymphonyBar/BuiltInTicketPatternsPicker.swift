import SwiftUI
import SymphonyBarCore

/// The repo's built-in ticket patterns setting as radio buttons, each with its one-line explanation under it.
struct BuiltInTicketPatternsPicker: View {
    @Binding var choice: BuiltInTicketPatternsChoice

    var body: some View {
        Picker(BuiltInTicketPatterns.pickerTitle, selection: $choice) {
            ForEach(BuiltInTicketPatternsChoice.allCases) { option in
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
