import SwiftUI
import SymphonyBarCore

/// The WORKFLOW.md page: that the repo has none, what was found in it, the editable draft and how it lands. Add Repo
/// shows it as a step for a repo without one; it takes only what it shows, so a sheet for a connected repo can show
/// it too.
struct WorkflowSetupPage: View {
    /// "acme/web has no WORKFLOW.md on main. …"
    let message: String
    /// What was found in the repo's files, such as "Elixir · mix test".
    let found: String
    @Binding var draft: String
    @Binding var landing: WorkflowLanding
    let choices: [WorkflowLanding]
    let baseBranch: String
    /// The file once it was added, shown in place of the editor.
    var landed: PendingWorkflow?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Found", value: found)
            if let landed {
                Text(landed.savedSentence)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                PlainTextEditor(text: $draft)
                    .frame(minHeight: 120, maxHeight: .infinity)
                Picker("Add it by", selection: $landing) {
                    ForEach(choices, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                Text(landing.help(baseBranch: baseBranch))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
