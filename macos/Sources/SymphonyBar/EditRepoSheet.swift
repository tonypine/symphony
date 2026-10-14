import AppKit
import SwiftUI
import SymphonyBarCore

/// The Edit sheet of one section of a connected repo: its title with the key, which can't change, the section's
/// fields, and a fixed footer with Cancel and Save. Each section's size keeps the footer on a 1024×768 screen.
struct EditRepoSheet: View {
    @ObservedObject var model: AddRepoViewModel
    let cancel: () -> Void

    var body: some View {
        let size = model.section.sheetSize
        VStack(alignment: .leading, spacing: 0) {
            Text(model.title)
                .font(.headline)
                .padding([.top, .horizontal], 16)
                .padding(.bottom, 8)
            Divider()
            Group {
                if let configProblem = model.configProblem {
                    AddRepoWarningBox(message: configProblem)
                        .padding(16)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else if let editing = model.editing {
                    switch model.section {
                    case .source:
                        EditSourceForm(model: model, editing: editing)
                    case .routing:
                        EditRoutingForm(model: model, editing: editing)
                    case .review:
                        EditReviewForm(model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // A late result of symphony check would otherwise write a draft changed meanwhile.
            .disabled(model.isSaving)
            Divider()
            footer
        }
        .frame(width: size.width, height: size.height)
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel, action: cancel)
                .keyboardShortcut(.cancelAction)
            Spacer()
            if model.isSaving {
                ProgressView().controlSize(.small)
                Text(model.savingMessage ?? "Saving…")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button("Save", action: model.save)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
                .help(saveHelp)
        }
        .padding(12)
    }

    private var saveHelp: String {
        if case let .failure(problem) = model.validation { return problem.message }
        return ""
    }
}

/// Why the last Save failed, at the foot of an Edit sheet's form.
private struct EditSaveErrorSection: View {
    let message: String?

    var body: some View {
        if let message {
            Section {
                AddRepoWarningBox(message: message)
            }
        }
    }
}

/// The caption under a field, red for a problem.
private func caption(_ text: String, problem: Bool = false) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(problem ? Color.red : .secondary)
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: Source

/// Where the repo's code comes from, with the same check as Add Repo's Source step, and its base branch.
private struct EditSourceForm: View {
    @ObservedObject var model: AddRepoViewModel
    let editing: RepositoryEntry

    var body: some View {
        Form {
            Section {
                Picker("Source", selection: model.mode) {
                    ForEach(AddRepoDraft.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                switch model.draft.mode {
                case .gitHub:
                    TextField("GitHub repo", text: model.gitHubInput, prompt: Text(verbatim: "https://github.com/owner/repo"))
                case .localFolder:
                    LabeledContent("Folder") {
                        HStack {
                            Text(folderText)
                                .foregroundStyle(folderText == Self.noFolder ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer()
                            if model.isInspectingFolder { ProgressView().controlSize(.small) }
                            Button("Choose…", action: model.chooseFolder)
                        }
                    }
                }
                if let result = model.editSourceResult {
                    AddRepoSourceResultRow(result: result)
                }
                caption(EditRepo.sourceCaption(for: model.draft, editing: editing))
            }
            Section {
                TextField("Base branch", text: model.baseBranch, prompt: Text("origin's default branch"))
            }
            EditSaveErrorSection(message: model.saveError)
        }
        .formStyle(.grouped)
    }

    private static let noFolder = "No folder chosen"

    /// The folder picked, else the repo's own folder while it is a local one.
    private var folderText: String {
        if let picked = model.pickedFolder { return (picked as NSString).abbreviatingWithTildeInPath }
        if editing.workspace.source == nil, let repo = editing.workspace.repo {
            return "\((repo as NSString).abbreviatingWithTildeInPath) (current)"
        }
        return Self.noFolder
    }
}

// MARK: Linear routing

/// Which Linear issues go to the repo: project, labels, the route preview, and whether it is the default repo.
private struct EditRoutingForm: View {
    @ObservedObject var model: AddRepoViewModel
    let editing: RepositoryEntry

    var body: some View {
        Form {
            Section {
                HStack {
                    Picker("Project", selection: model.project) {
                        Text("No project").tag(String?.none)
                        if let unlisted = model.unlistedProject {
                            Text(unlisted).tag(String?.some(unlisted))
                        }
                        ForEach(model.projects) { project in
                            Text(project.name).tag(String?.some(project.name))
                        }
                    }
                    .disabled(model.linear != .loaded)
                    if model.linear == .loading { ProgressView().controlSize(.small) }
                }
                LabeledContent("Labels") {
                    HStack {
                        LabelTokenField(labels: model.pickedLabels, suggestions: model.labelChoices, placeholder: labelsPlaceholder)
                            .disabled(!model.canEditLabels)
                        if model.labelsState == .loading { ProgressView().controlSize(.small) }
                    }
                }
                if case let .failure(problem) = model.validation {
                    Label(problem.message, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(EditRepo.routePreview(for: model.draft, editing: editing), id: \.self) { Text($0) }
                    }
                } icon: {
                    Image(systemName: "arrow.triangle.branch")
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if let warning = linearWarning {
                    AddRepoWarningBox(message: warning) {
                        Button(AddRepoFlow.retryTitle, action: model.loadLinear)
                        Button(AddRepoFlow.openSettingsTitle) { model.openSettings() }
                    }
                }
            }
            if let option = model.defaultOption {
                Section {
                    Toggle(isOn: $model.draft.isDefault) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(EditRepo.defaultTitle)
                            Text(EditRepo.defaultExplanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!option.isEnabled)
                    if let text = option.caption { caption(text) }
                }
            }
            EditSaveErrorSection(message: model.saveError)
        }
        .formStyle(.grouped)
    }

    private var labelsPlaceholder: String {
        switch model.labelsState {
        case .loading: return "Loading labels…"
        case .failed: return "Labels couldn't be listed"
        case .loaded: return model.linear == .loaded ? "Optional: issues must carry all of them" : "Labels couldn't be listed"
        }
    }

    /// What Linear said when the projects or labels didn't load. The pickers keep the repo's route meanwhile.
    private var linearWarning: String? {
        if case let .failed(message) = model.linear { return message }
        if case let .failed(message) = model.labelsState { return message }
        return nil
    }
}

// MARK: Review

/// Whether a verified ticket waits for a person before it merges, and the repo's built-in ticket patterns.
private struct EditReviewForm: View {
    @ObservedObject var model: AddRepoViewModel

    var body: some View {
        Form {
            Section {
                Toggle(ManualReview.checkboxTitle, isOn: manualReview)
                    .toggleStyle(.checkbox)
                caption(model.draft.manualReview.explanation)
            }
            Section {
                BuiltInTicketPatternsPicker(choice: $model.draft.ticketPatternsBuiltIn)
            }
            EditSaveErrorSection(message: model.saveError)
        }
        .formStyle(.grouped)
    }

    private var manualReview: Binding<Bool> {
        Binding(get: { model.draft.manualReview == .on }, set: { model.draft.manualReview = $0 ? .on : .off })
    }
}
