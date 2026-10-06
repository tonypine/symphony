import AppKit
import SwiftUI
import SymphonyBarCore

/// What the Add Repo sheet edits and shows, also as the Edit Repo sheet of a connected repo. Linear's projects load
/// when it opens, with the stored `LINEAR_API_KEY`, and the picked project's labels each time one is picked; the repos
/// in `symphony.yml` are read once, to check the key and the route against them.
@MainActor
final class AddRepoViewModel: ObservableObject {
    enum LinearState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// What Save wrote.
    enum Saved {
        case added(key: String, madeDefault: String?)
        case edited(from: RepositoryEntry, to: RepositoryEntry)
    }

    @Published var draft = AddRepoDraft()
    @Published private(set) var projects: [LinearProject] = []
    @Published private(set) var labels: [LinearLabel] = []
    @Published private(set) var linear = LinearState.loading
    /// How `labels` loads for the picked project.
    @Published private(set) var labelsState = LinearState.loaded
    /// Why the folder picked is still being checked.
    @Published private(set) var isInspectingFolder = false
    /// Why the last Save failed.
    @Published private(set) var saveError: String? {
        didSet {
            if let saveError, saveError != oldValue { onSaveError(saveError) }
        }
    }
    /// Called with each new reason Save failed.
    var onSaveError: (String) -> Void = { _ in }
    /// True while Save waits for `symphony check` on a changed acceptance gate mode.
    @Published private(set) var isSaving = false
    /// Enforce, while its confirmation is open.
    @Published var pendingAcceptanceGate: AcceptanceGateChoice?

    /// Why the sheet can't add a repo at all: no `symphony.yml` is set, or its repos can't be read.
    let configProblem: String?
    let configPath: String
    /// The repo the sheet edits, as `symphony.yml` has it; nil while adding one.
    let editing: RepositoryEntry?
    /// `auto_review.acceptance_gate.mode`, which the repo's Inherit follows.
    let globalGateMode: AcceptanceGateMode
    /// The edited repo's gate stats, which each state poll refreshes; nil while adding a repo.
    let gateAgreement: AcceptanceGate.RepoAgreement?
    private let configCheck: SettingsConfigCheck
    private let existing: [RepositoryEntry]
    private let secrets: SecretsReader
    /// True once the key was typed, so picking another source no longer replaces it.
    private var keyEdited = false
    private let linearClient: (_ apiKey: String) -> LinearClient
    /// The client the projects loaded with, which then loads the labels.
    private var client: LinearClient?
    private let onSaved: (Saved) -> Void

    /// With `editing`, the sheet opens on that repo's entry and Save rewrites it.
    init(
        configPath: String,
        secrets: SecretsReader,
        editing key: String? = nil,
        state: StateSnapshot? = nil,
        linearClient: @escaping (_ apiKey: String) -> LinearClient = { LinearClient(apiKey: $0) },
        configCheck: @escaping SettingsConfigCheck = SettingsViewModel.runConfigCheck,
        onSaved: @escaping (Saved) -> Void
    ) {
        self.configPath = configPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secrets = secrets
        self.linearClient = linearClient
        self.configCheck = configCheck
        self.onSaved = onSaved
        globalGateMode = (try? SymphonyConfigFile(path: self.configPath).readAcceptanceGateMode()) ?? .off
        var existing: [RepositoryEntry] = []
        var configProblem: String?
        if self.configPath.isEmpty {
            configProblem = "Set the symphony.yml path in Settings first."
        } else {
            do {
                existing = try SymphonyConfigFile(path: self.configPath).readRepositories()
            } catch {
                let shown = (self.configPath as NSString).abbreviatingWithTildeInPath
                configProblem = "Couldn't read the repos in \(shown): \(error.localizedDescription)"
            }
        }
        let editing = key.flatMap { key in existing.first { $0.key == key } }
        if let key, editing == nil, configProblem == nil {
            configProblem = "symphony.yml has no repo `\(key)`."
        }
        self.editing = editing
        gateAgreement = editing.map { AcceptanceGate.RepoAgreement(key: $0.key, state: state) }
        self.existing = existing
        self.configProblem = configProblem
        if let editing {
            draft = EditRepo.draft(for: editing)
            keyEdited = true
        }
        loadLinear()
    }

    var title: String {
        editing.map { EditRepo.sheetTitle(key: $0.key) } ?? AddRepo.sheetTitle
    }

    /// The entry Save writes, or what stops it.
    var validation: Result<RepositoryEntry, AddRepoProblem> {
        if let configProblem { return .failure(AddRepoProblem(configProblem)) }
        if let editing { return EditRepo.entry(for: draft, editing: editing, existing: existing) }
        return AddRepo.entry(for: draft, existing: existing)
    }

    var canSave: Bool {
        if case .success = validation { return !isInspectingFolder && !isSaving && labelsState != .loading }
        return false
    }

    /// The labels an issue in the picked project can carry, and those the edited repo's route has already.
    var labelChoices: [String] {
        let names = LinearLabel.names(labels)
        let kept = (editing?.route.labels ?? []).filter { !names.contains($0) }
        return names + kept
    }

    /// The edited repo's project when Linear doesn't list it by that name, so the picker can show it.
    var unlistedProject: String? {
        guard let project = draft.project, !projects.contains(where: { $0.name == project }) else { return nil }
        return project
    }

    // MARK: Bindings

    var mode: Binding<AddRepoDraft.Mode> {
        Binding(get: { self.draft.mode }, set: { self.draft.mode = $0; self.suggestKey() })
    }

    var gitHubInput: Binding<String> {
        Binding(get: { self.draft.gitHubInput }, set: { self.draft.gitHubInput = $0; self.suggestKey() })
    }

    var key: Binding<String> {
        Binding(get: { self.draft.key }, set: { self.draft.key = $0; self.keyEdited = true })
    }

    var project: Binding<String?> {
        Binding(get: { self.draft.project }, set: { project in
            self.draft.project = project
            self.loadLabels()
        })
    }

    func isLabelPicked(_ name: String) -> Binding<Bool> {
        Binding(get: { self.draft.labels.contains(name) }, set: { picked in
            self.draft.labels.removeAll { $0 == name }
            if picked { self.draft.labels.append(name) }
        })
    }

    // MARK: Actions

    /// Loads Linear's projects with the stored key, then the picked project's labels; again after a failure.
    func loadLinear() {
        linear = .loading
        secrets.read { [weak self] result in
            guard let self else { return }
            guard case let .success(secrets) = result else {
                self.linear = .failed("Couldn't read LINEAR_API_KEY from the app's secrets.")
                return
            }
            let client = self.linearClient(secrets.linearAPIKey)
            Task {
                switch await client.projects() {
                case let .success(projects):
                    self.client = client
                    self.projects = projects
                    self.linear = projects.isEmpty ? .failed("Linear lists no projects for this key.") : .loaded
                    self.loadLabels()
                case let .failure(failure):
                    self.linear = .failed(failure.message)
                }
            }
        }
    }

    /// Loads the labels an issue in the picked project can carry, then drops the picked labels it lacks, which would
    /// never match. A new repo needs a project first; the edited repo's route can take any label without one, or with
    /// a project Linear doesn't list.
    func loadLabels() {
        labels = []
        let picked = draft.project
        let projectID = picked.flatMap { name in projects.first { $0.name == name }?.id }
        guard let client, projectID != nil || editing != nil else {
            labelsState = .loaded
            pruneLabels()
            return
        }
        labelsState = .loading
        Task {
            let result = await client.labels(forProject: projectID)
            // Another project was picked meanwhile; its own load fills the labels.
            guard draft.project == picked else { return }
            switch result {
            case let .success(labels):
                self.labels = labels
                labelsState = .loaded
            case let .failure(failure):
                labelsState = .failed(failure.message)
            }
            pruneLabels()
        }
    }

    private func pruneLabels() {
        let choices = Set(labelChoices)
        draft.labels.removeAll { !choices.contains($0) }
    }

    /// Asks for a folder, then checks it is a GitHub checkout with a `WORKFLOW.md`.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pickFolder(url.path)
    }

    func pickFolder(_ path: String) {
        isInspectingFolder = true
        Task {
            let result = await Task.detached { LocalCheckout.inspect(path) }.value
            draft.folder = result
            isInspectingFolder = false
            suggestKey()
        }
    }

    func save() {
        guard canSave, case let .success(entry) = validation else { return }
        if let editing, EditRepo.changesAcceptanceGate(from: editing, to: entry) {
            saveChecked(editing, to: entry)
            return
        }
        do {
            let file = SymphonyConfigFile(path: configPath)
            if let editing {
                try file.editRepository(editing, to: entry)
                saveError = nil
                onSaved(.edited(from: editing, to: entry))
            } else {
                let madeDefault = try file.connectRepository(entry)
                saveError = nil
                onSaved(.added(key: entry.key, madeDefault: madeDefault))
            }
        } catch {
            saveError = "Couldn't save symphony.yml: \(error.localizedDescription)"
        }
    }

    /// Writes the edit once `symphony check` passes on the result, as Settings does, since it changes the
    /// acceptance gate's mode. The check runs with the app's settings and stored secrets, like Start.
    private func saveChecked(_ editing: RepositoryEntry, to entry: RepositoryEntry) {
        isSaving = true
        saveError = nil
        let file = SymphonyConfigFile(path: configPath)
        let check = configCheck
        secrets.read { [weak self] result in
            guard let self else { return }
            guard case let .success(secrets) = result else {
                self.isSaving = false
                self.saveError = "Couldn't read the app's secrets to run symphony check."
                return
            }
            let settings = AppStores.current.settingsStore().loadSettings().trimmed()
            Task {
                do {
                    let result = try await file.rewrite(
                        { try EditRepo.updating(editing, to: entry, in: $0) },
                        checkingWith: { await check($0, settings, secrets.trimmed()) }
                    )
                    self.isSaving = false
                    if case let .failed(message) = result {
                        self.saveError = "symphony check rejected this, so nothing was saved: \(message)"
                        return
                    }
                    self.onSaved(.edited(from: editing, to: entry))
                } catch {
                    self.isSaving = false
                    self.saveError = "Couldn't save symphony.yml: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Fills the key from the repo's name until the engineer types one.
    private func suggestKey() {
        guard !keyEdited, let gitHub = draft.gitHub else { return }
        draft.key = AddRepo.suggestedKey(for: GitHubRepoInput.name(gitHub), existing: existing.map(\.key))
    }
}

/// The Add Repo sheet: where the repo's code comes from, its key and base branch, and which Linear issues it takes.
struct AddRepoView: View {
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
                    TextField("Repo key", text: model.key, prompt: Text("Filled in from the repo name"))
                        .disabled(model.editing != nil)
                    TextField(
                        "Base branch",
                        text: $model.draft.baseBranch,
                        prompt: Text(model.editing == nil ? AddRepo.defaultBaseBranch : "origin's default branch")
                    )
                }
                Section("Linear routing") {
                    linear
                }
                if let gateAgreement = model.gateAgreement {
                    Section(AcceptanceGate.pickerTitle) {
                        AcceptanceGatePicker(
                            choice: $model.draft.acceptanceGate,
                            pending: $model.pendingAcceptanceGate,
                            choices: AcceptanceGateChoice.allCases,
                            inherited: model.globalGateMode
                        )
                        GateAgreementLine(agreement: gateAgreement)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack(alignment: .firstTextBaseline) {
                status
                Spacer()
                if model.isSaving {
                    ProgressView().controlSize(.small)
                    Text("Checking symphony.yml…").foregroundStyle(.secondary)
                }
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: model.save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
            }
            .padding(12)
        }
        .frame(width: 520, height: model.editing == nil ? 600 : 760)
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
            Text("Agents work in worktrees of this checkout. It needs a GitHub origin and a WORKFLOW.md.")
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
                Text(model.editing == nil ? "Choose a project…" : "No project").tag(String?.none)
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
                    Text(model.draft.project == nil && model.editing == nil ? "Pick a project to list its labels" : "No labels")
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

/// The edited repo's gate stats, observed on its own so each state poll redraws it while the sheet is open.
private struct GateAgreementLine: View {
    @ObservedObject var agreement: AcceptanceGate.RepoAgreement

    var body: some View {
        Text(agreement.line)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
