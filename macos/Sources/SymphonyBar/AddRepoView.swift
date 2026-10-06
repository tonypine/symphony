import AppKit
import SwiftUI
import SymphonyBarCore

/// What the Add Repo sheet edits and shows, also as the Edit Repo sheet of a connected repo. Linear's projects and
/// labels load when it opens, with the stored `LINEAR_API_KEY`; the repos in `symphony.yml` are read once, to check
/// the key and the route against them.
@MainActor
final class AddRepoViewModel: ObservableObject {
    enum LinearState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// What Save wrote.
    enum Saved {
        /// `workflow` is the `WORKFLOW.md` the sheet added for the repo.
        case added(key: String, madeDefault: String?, workflow: PendingWorkflow?)
        case edited(from: RepositoryEntry, to: RepositoryEntry)
    }

    @Published var draft = AddRepoDraft()
    @Published private(set) var projects: [LinearProject] = []
    @Published private(set) var labels: [LinearLabel] = []
    @Published private(set) var linear = LinearState.loading
    /// Why the folder picked is still being checked.
    @Published private(set) var isInspectingFolder = false
    /// Why the last Save failed.
    @Published private(set) var saveError: String?
    /// True while Save waits for `symphony check` on a changed acceptance gate mode.
    @Published private(set) var isSaving = false
    /// Enforce, while its confirmation is open.
    @Published var pendingAcceptanceGate: AcceptanceGateChoice?
    /// Whether the repo picked has a `WORKFLOW.md`; never checked while editing a repo.
    @Published private(set) var workflowCheck = WorkflowCheck.idle
    /// The `WORKFLOW.md` drafted for a repo that has none, as the engineer edited it.
    @Published private(set) var workflowText = ""
    @Published var landing = WorkflowLanding.pullRequest
    /// The `WORKFLOW.md` Save added, kept so a Save that failed on `symphony.yml` doesn't add it twice.
    @Published private(set) var landedWorkflow: PendingWorkflow?
    /// What Save is doing while `isSaving`.
    @Published private(set) var savingMessage: String?

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
    /// True once the base branch was typed, so the source's default branch no longer replaces it.
    private var baseBranchEdited = false
    /// True once the draft was typed in, so it is no longer redrafted.
    private var workflowEdited = false
    /// The stack of the local folder picked, when it has no `WORKFLOW.md`.
    private var folderStack: WorkflowStack?
    private var workflowProbe: Task<Void, Never>?
    private let gitHubCLI: () -> GitHubCLI?
    private let linearClient: (_ apiKey: String) -> LinearClient
    private let onSaved: (Saved) -> Void

    /// With `editing`, the sheet opens on that repo's entry and Save rewrites it.
    init(
        configPath: String,
        secrets: SecretsReader,
        editing key: String? = nil,
        state: StateSnapshot? = nil,
        linearClient: @escaping (_ apiKey: String) -> LinearClient = { LinearClient(apiKey: $0) },
        configCheck: @escaping SettingsConfigCheck = SettingsViewModel.runConfigCheck,
        gitHubCLI: @escaping () -> GitHubCLI? = {
            GitHubCLI.locate(environment: AppStores.current.environment).map(GitHubCLI.process)
        },
        onSaved: @escaping (Saved) -> Void
    ) {
        self.configPath = configPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secrets = secrets
        self.gitHubCLI = gitHubCLI
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
        return AddRepo.entry(for: draft, existing: existing).flatMap { entry in
            switch workflowCheck {
            case .checking:
                return .failure(AddRepoProblem("Checking the repo for a WORKFLOW.md…"))
            case .missing where landing != .skip && landedWorkflow == nil
                && workflowText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                return .failure(AddRepoProblem("The WORKFLOW.md draft is empty. Write one, or pick \"\(WorkflowLanding.skip.rawValue)\"."))
            default:
                return .success(entry)
            }
        }
    }

    /// Whether the sheet shows its WORKFLOW.md step: while it checks the repo, and when the repo has none.
    var showsWorkflowStep: Bool {
        switch workflowCheck {
        case .checking, .missing, .failed:
            return true
        case .idle, .present:
            return false
        }
    }

    /// `owner/repo`, or the local folder, the WORKFLOW.md step talks about.
    var workflowSource: String {
        if draft.mode == .localFolder, case let .success(checkout)? = draft.folder {
            return (checkout.path as NSString).abbreviatingWithTildeInPath
        }
        return draft.gitHub ?? ""
    }

    var canSave: Bool {
        if case .success = validation { return !isInspectingFolder && !isSaving }
        return false
    }

    /// The labels an issue in the picked project can carry, and those the edited repo's route has already.
    var labelChoices: [String] {
        let names = LinearLabel.names(labels, for: projects.first { $0.name == draft.project })
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
        Binding(get: { self.draft.mode }, set: { mode in
            self.draft.mode = mode
            if !WorkflowLanding.choices(for: mode).contains(self.landing) { self.landing = .pullRequest }
            self.sourceChanged()
        })
    }

    var gitHubInput: Binding<String> {
        Binding(get: { self.draft.gitHubInput }, set: { input in
            let before = self.draft.gitHub
            self.draft.gitHubInput = input
            if self.draft.gitHub != before { self.sourceChanged() }
        })
    }

    var baseBranch: Binding<String> {
        Binding(get: { self.draft.baseBranch }, set: { branch in
            self.draft.baseBranch = branch
            self.baseBranchEdited = true
            // A GitHub repo is checked on the branch typed; a folder's draft only names it.
            if self.draft.mode == .gitHub { self.checkWorkflow() } else { self.redraftWorkflow() }
        })
    }

    var workflowDraft: Binding<String> {
        Binding(get: { self.workflowText }, set: { self.workflowText = $0; self.workflowEdited = true })
    }

    var key: Binding<String> {
        Binding(get: { self.draft.key }, set: { self.draft.key = $0; self.keyEdited = true })
    }

    var project: Binding<String?> {
        Binding(get: { self.draft.project }, set: { project in
            self.draft.project = project
            // A label the new project's teams don't have would never match.
            let choices = Set(self.labelChoices)
            self.draft.labels.removeAll { !choices.contains($0) }
        })
    }

    func isLabelPicked(_ name: String) -> Binding<Bool> {
        Binding(get: { self.draft.labels.contains(name) }, set: { picked in
            self.draft.labels.removeAll { $0 == name }
            if picked { self.draft.labels.append(name) }
        })
    }

    // MARK: Actions

    /// Loads Linear's projects and labels with the stored key; again after a failure.
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
                async let projects = client.projects()
                async let labels = client.labels()
                switch (await projects, await labels) {
                case let (.success(projects), .success(labels)):
                    self.projects = projects
                    self.labels = labels
                    self.linear = projects.isEmpty ? .failed("Linear lists no projects for this key.") : .loaded
                case let (.failure(failure), _), let (_, .failure(failure)):
                    self.linear = .failed(failure.message)
                }
            }
        }
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
            let (result, stack) = await Task.detached { () -> (Result<LocalCheckout, AddRepoProblem>, WorkflowStack?) in
                let result = LocalCheckout.inspect(path)
                guard case let .success(checkout) = result, !checkout.hasWorkflow else { return (result, nil) }
                return (result, WorkflowTemplate.detect(RepoFiles.checkout(checkout.path)))
            }.value
            draft.folder = result
            folderStack = stack
            if editing == nil, !baseBranchEdited, case let .success(checkout) = result, let branch = checkout.defaultBranch {
                draft.baseBranch = branch
            }
            isInspectingFolder = false
            sourceChanged()
        }
    }

    func save() {
        guard canSave, case let .success(entry) = validation else { return }
        if let editing, EditRepo.changesAcceptanceGate(from: editing, to: entry) {
            saveChecked(editing, to: entry)
            return
        }
        if editing == nil, landedWorkflow == nil, case let .missing(stack, _) = workflowCheck, landing != .skip {
            addWorkflow(stack, then: entry)
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
                onSaved(.added(key: entry.key, madeDefault: madeDefault, workflow: landedWorkflow))
            }
        } catch {
            saveError = "Couldn't save symphony.yml: \(error.localizedDescription)"
        }
    }

    /// Adds the drafted `WORKFLOW.md` the way `landing` says, off the main thread, then saves the entry.
    private func addWorkflow(_ stack: WorkflowStack, then entry: RepositoryEntry) {
        let landing = landing
        let cli = landing == .pullRequest ? gitHubCLI() : nil
        var checkout: LocalCheckout?
        if draft.mode == .localFolder, case let .success(picked)? = draft.folder { checkout = picked }
        let text = workflowText.hasSuffix("\n") ? workflowText : workflowText + "\n"
        let gitHub = draft.gitHub ?? ""
        let baseBranch = entry.baseBranch ?? AddRepo.defaultBaseBranch
        isSaving = true
        saveError = nil
        savingMessage = landing == .pullRequest ? "Opening a pull request…" : "Writing WORKFLOW.md…"
        Task {
            let result = await Task.detached {
                landing.land(text, gitHub: gitHub, baseBranch: baseBranch, summary: stack.summary, checkout: checkout, cli: cli)
            }.value
            isSaving = false
            savingMessage = nil
            switch result {
            case let .success(pending)?:
                landedWorkflow = pending
                save()
            case let .failure(problem)?:
                saveError = problem.message
            case nil:
                break
            }
        }
    }

    /// After another repo is picked: suggests its key and checks it for a `WORKFLOW.md`, forgetting the old draft.
    private func sourceChanged() {
        suggestKey()
        workflowEdited = false
        landedWorkflow = nil
        checkWorkflow()
    }

    /// Checks whether the repo picked has a `WORKFLOW.md`: a folder from its files, a GitHub repo through `gh`, once
    /// the typing pauses. A GitHub repo's default branch becomes the base branch until one is typed.
    private func checkWorkflow() {
        workflowProbe?.cancel()
        guard editing == nil else { return }
        switch draft.mode {
        case .localFolder:
            guard case let .success(checkout)? = draft.folder else {
                workflowCheck = .idle
                return
            }
            workflowCheck = checkout.hasWorkflow ? .present : .missing(folderStack ?? WorkflowStack(), branch: nil)
            redraftWorkflow()
        case .gitHub:
            guard let gitHub = draft.gitHub else {
                workflowCheck = .idle
                return
            }
            guard let cli = gitHubCLI() else {
                workflowCheck = .failed(GitHubCLI.missingMessage)
                return
            }
            workflowCheck = .checking
            let branch = baseBranchEdited ? draft.baseBranch : nil
            workflowProbe = Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                let result = await Task.detached { cli.probe(gitHub, branch: branch) }.value
                guard !Task.isCancelled else { return }
                switch result {
                case let .success(probe):
                    if !baseBranchEdited { draft.baseBranch = probe.defaultBranch }
                    workflowCheck = probe.hasWorkflow ? .present : .missing(probe.stack, branch: probe.branch)
                    redraftWorkflow()
                case let .failure(problem):
                    workflowCheck = .failed(problem.message)
                }
            }
        }
    }

    /// Drafts the `WORKFLOW.md` again for the stack found and the base branch, until the draft is typed in.
    private func redraftWorkflow() {
        guard !workflowEdited, case let .missing(stack, _) = workflowCheck, let gitHub = draft.gitHub else { return }
        workflowText = WorkflowTemplate.render(stack, gitHub: gitHub, baseBranch: draft.baseBranch)
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
                        text: model.baseBranch,
                        prompt: Text(model.editing == nil ? AddRepo.defaultBaseBranch : "origin's default branch")
                    )
                }
                if model.showsWorkflowStep {
                    Section(WorkflowTemplate.fileName) {
                        workflowStep
                    }
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
                    Text(model.savingMessage ?? "Checking symphony.yml…").foregroundStyle(.secondary)
                }
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: model.save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
            }
            .padding(12)
        }
        .frame(
            width: model.showsWorkflowStep ? 640 : 520,
            height: model.editing != nil || model.showsWorkflowStep ? 760 : 600
        )
    }

    @ViewBuilder private var source: some View {
        switch model.draft.mode {
        case .gitHub:
            TextField("GitHub repo", text: model.gitHubInput, prompt: Text(verbatim: "https://github.com/owner/repo"))
            Text("Symphony keeps its own clone, made when it starts. Your own checkouts aren't touched.")
                .font(.caption)
                .foregroundStyle(.secondary)
            workflowFound
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
            workflowFound
        }
    }

    @ViewBuilder private var workflowFound: some View {
        if model.workflowCheck == .present {
            Label("The repo has a WORKFLOW.md.", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Says the repo has no `WORKFLOW.md`, and offers the draft and how to add it.
    @ViewBuilder private var workflowStep: some View {
        switch model.workflowCheck {
        case .checking:
            HStack {
                ProgressView().controlSize(.small)
                Text("Checking the repo for a WORKFLOW.md…").foregroundStyle(.secondary)
            }
        case let .failed(message):
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Save connects the repo as it is; it shows WORKFLOW.md as missing until the repo has one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .missing(stack, _):
            Text(model.workflowCheck.missingMessage(source: model.workflowSource) ?? "")
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Found", value: stack.summary)
            if let landed = model.landedWorkflow {
                Text(landed.savedSentence)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                TextEditor(text: model.workflowDraft)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 240)
                    .disabled(model.isSaving)
                Picker("Add it by", selection: $model.landing) {
                    ForEach(WorkflowLanding.choices(for: model.draft.mode), id: \.self) { Text($0.rawValue).tag($0) }
                }
                .disabled(model.isSaving)
                Text(model.landing.help(baseBranch: model.draft.baseBranch.trimmingCharacters(in: .whitespaces)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .idle, .present:
            EmptyView()
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
                Text("Loading projects and labels from Linear…").foregroundStyle(.secondary)
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
                if model.labelChoices.isEmpty {
                    Text("No labels").foregroundStyle(.secondary)
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
