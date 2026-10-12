import SwiftUI
import SymphonyBarCore

/// The repo's manual review setting as radio buttons, each with its one-line explanation under it.
struct ManualReviewPicker: View {
    @Binding var choice: ManualReviewChoice

    var body: some View {
        Picker(ManualReview.pickerTitle, selection: $choice) {
            ForEach(ManualReviewChoice.allCases) { option in
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
