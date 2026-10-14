import AppKit
import SwiftUI
import SymphonyBarCore

/// The Edit Repo sheet of a connected repo: where its code comes from, its base branch, which Linear issues it
/// takes, and its manual review and ticket patterns. Its key stays as it is.
struct EditRepoFormView: View {
    @ObservedObject var model: AddRepoViewModel
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.title)
                .font(.headline)
                .padding([.top, .horizontal], 16)
            Form {
                Section {
                    Picker("Source", selection: model.mode) {
                        ForEach(AddRepoDraft.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    source
                }
                Section {
                    TextField("Repo key", text: model.key)
                        .disabled(true)
                    TextField("Base branch", text: model.baseBranch, prompt: Text("origin's default branch"))
                }
                Section("Linear routing") {
                    linear
                }
                Section(ManualReview.pickerTitle) {
                    ManualReviewPicker(choice: $model.draft.manualReview)
                }
                Section(BuiltInTicketPatterns.pickerTitle) {
                    BuiltInTicketPatternsPicker(choice: $model.draft.ticketPatternsBuiltIn)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack(alignment: .firstTextBaseline) {
                status
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: model.save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
            }
            .padding(12)
        }
        .frame(width: 520, height: 760)
    }

    @ViewBuilder private var source: some View {
        switch model.draft.mode {
        case .gitHub:
            TextField("GitHub repo", text: model.gitHubInput, prompt: Text(verbatim: "https://github.com/owner/repo"))
            Text("Symphony keeps its own clone, made when it starts. Your own checkouts aren't touched.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .localFolder:
            LabeledContent("Folder") {
                HStack {
                    Text(folderText)
                        .foregroundStyle(folderColor)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    if model.isInspectingFolder { ProgressView().controlSize(.small) }
                    Button("Choose…", action: model.chooseFolder)
                }
            }
            Text("Agents work in worktrees of this checkout. It needs a GitHub origin.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var folderText: String {
        switch model.draft.folder {
        case nil:
            if let repo = model.editing?.workspace.repo, model.editing?.workspace.source == nil { return "\(repo) (current)" }
            return "No folder chosen"
        case let .success(checkout)?:
            return "\((checkout.path as NSString).abbreviatingWithTildeInPath) (\(checkout.gitHub))"
        case let .failure(problem)?:
            return problem.message
        }
    }

    private var folderColor: Color {
        switch model.draft.folder {
        case nil:
            return model.editing?.workspace.repo != nil && model.editing?.workspace.source == nil ? .primary : .secondary
        case .success?:
            return .primary
        case .failure?:
            return .red
        }
    }

    @ViewBuilder private var linear: some View {
        switch model.linear {
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading projects from Linear…").foregroundStyle(.secondary)
            }
        case let .failed(message):
            HStack(alignment: .firstTextBaseline) {
                Text(message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Retry", action: model.loadLinear)
            }
        case .loaded:
            Picker("Project", selection: model.project) {
                Text("No project").tag(String?.none)
                if let unlisted = model.unlistedProject {
                    Text(unlisted).tag(String?.some(unlisted))
                }
                ForEach(model.projects) { project in
                    Text(project.name).tag(String?.some(project.name))
                }
            }
            LabeledContent("Labels") {
                if model.labelsState == .loading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading labels…").foregroundStyle(.secondary)
                    }
                } else if case let .failed(message) = model.labelsState {
                    HStack(alignment: .firstTextBaseline) {
                        Text(message)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Retry", action: model.loadLabels)
                    }
                } else if model.labelChoices.isEmpty {
                    Text("No labels")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.labelChoices, id: \.self) { name in
                                Toggle(name, isOn: model.isLabelPicked(name))
                                    .toggleStyle(.checkbox)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 110)
                }
            }
            Text("Issues in the project go to this repo. With labels, only issues that carry all of them do.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var status: some View {
        if let saveError = model.saveError {
            Text(saveError).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        } else if case let .failure(problem) = model.validation {
            Text(problem.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
