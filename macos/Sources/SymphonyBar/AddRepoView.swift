import AppKit
import SwiftUI
import SymphonyBarCore

/// What the Add Repo sheet edits and shows, step by step, also as the Edit sheet of one section of a connected repo.
/// Linear's projects load when the Add Repo or Linear routing sheet opens, with the stored `LINEAR_API_KEY`, and the
/// picked project's labels each time one is picked; the repos in `symphony.yml` are read once, to check the key and
/// the route against them.
@MainActor
final class AddRepoViewModel: ObservableObject {
    typealias LinearState = LinearLoad

    /// What Save wrote.
    enum Saved {
        /// `workflow` is the `WORKFLOW.md` the sheet added for the repo.
        case added(key: String, madeDefault: String?, workflow: PendingWorkflow?)
        /// `previousDefault` is the repo that lost `default: true` to this one.
        case edited(from: RepositoryEntry, to: RepositoryEntry, previousDefault: String?)
    }

    @Published var draft = AddRepoDraft()
    /// The Add Repo page shown.
    @Published private(set) var step = AddRepoStep.source
    @Published private(set) var projects: [LinearProject] = []
    @Published private(set) var labels: [LinearLabel] = []
    @Published private(set) var linear = LinearState.loading
    /// How `labels` loads for the picked project.
    @Published private(set) var labelsState = LinearState.loaded
    /// True while the folder picked is still being checked.
    @Published private(set) var isInspectingFolder = false
    /// The folder picked last, as it was picked, nil before one is.
    @Published private(set) var pickedFolder: String?
    /// The default branch of the repo picked, as GitHub or the checkout's `origin/HEAD` says.
    @Published private(set) var defaultBranch: String?
    /// Why the last Save failed.
    @Published private(set) var saveError: String? {
        didSet {
            if let saveError, saveError != oldValue { onSaveError(saveError) }
        }
    }
    /// Called with each new reason Save failed.
    var onSaveError: (String) -> Void = { _ in }
    /// Opens the app's Settings, where `LINEAR_API_KEY` is.
    var openSettings: () -> Void = {}
    /// How a repo added now would reach Symphony, from its status now.
    var apply: () -> AddRepoApply = { .onNextStart }
    /// Runs `symphony check` on a copy of `symphony.yml` at the path given, before the Review sheet saves.
    var configCheck: (_ path: String) async -> ConfigCheckResult = { _ in .passed }
    /// True while Save adds the drafted `WORKFLOW.md`.
    @Published private(set) var isSaving = false
    /// Whether the repo picked has a `WORKFLOW.md`; of the Edit sheets, only Source checks it.
    @Published private(set) var workflowCheck = WorkflowCheck.idle
    /// The `WORKFLOW.md` drafted for a repo that has none, as the engineer edited it.
    @Published private(set) var workflowText = ""
    @Published var landing = WorkflowLanding.pullRequest
    /// The `WORKFLOW.md` Save added, kept so a Save that failed on `symphony.yml` doesn't add it twice.
    @Published private(set) var landedWorkflow: PendingWorkflow?
    /// What Save is doing while `isSaving`.
    @Published private(set) var savingMessage: String?
    /// SU11: the Check setup step, once Connect saved the repo.
    @Published private(set) var setupCheck: AddRepoSetupCheck?
    /// The open fix sheet of a problem the step lists, nil while none is.
    @Published private(set) var fixSheet: SetupFixSheet?
    /// What the last fix did.
    @Published private(set) var fixMessage: String?
    /// Checks the setup of the repo saved, once Symphony has read it (`SetupAPI.checkRepo`).
    var checkRepo: (_ key: String) async -> SetupAPI.Result = { _ in .failed("") }
    /// Sends a Linear fix to Symphony (`POST /api/v1/setup/fixes`).
    var setupRequest: (_ fix: [String: Any]) async -> SetupAPI.Result = { _ in .failed("") }
    /// Instant GitHub updates: `GET /api/v1/setup`'s section, and an action (`POST /api/v1/setup/github_updates/…`).
    var readGitHubUpdates: () async -> GitHubUpdatesAPI.Result = { .failed("") }
    var gitHubUpdatesRequest: (GitHubUpdatesAPI.Action, [String: String]) async -> GitHubUpdatesAPI.Result = { _, _ in .failed("") }
    /// True while instant GitHub updates are on, so the sheet ends by connecting the repo to them (S13).
    @Published private(set) var instantUpdatesOn = false
    /// S13: the Instant updates step, once Check setup is done.
    @Published private(set) var instantUpdates: AddRepoInstantUpdates?
    /// Why Skip couldn't take the repo back to polling.
    @Published private(set) var instantSkipError: String?
    /// Done on Instant updates: the section as the step left it, so Setup's card lists the repo at once.
    var onGitHubUpdates: (GitHubUpdatesSection) -> Void = { _ in }
    private var instantController: AddRepoInstantUpdatesController?
    /// Starts Symphony, and whether it can now.
    var startSymphony: () -> Void = {}
    var canStartSymphony: () -> Bool = { false }
    /// Goes where an `open` fix sends the operator.
    var openDestination: (SetupDestination) -> Void = { _ in }
    /// Closes the sheet.
    var close: () -> Void = {}
    private var checkTask: Task<Void, Never>?

    /// Why the sheet can't add a repo at all: no `symphony.yml` is set, or its repos can't be read.
    let configProblem: String?
    let configPath: String
    /// The repo the sheet edits, as `symphony.yml` has it; nil while adding one.
    let editing: RepositoryEntry?
    /// The section of `editing` the sheet edits.
    let section: EditRepo.Section
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
    /// The client the projects loaded with, which then loads the labels.
    private var client: LinearClient?
    private let onSaved: (Saved) -> Void

    /// With `editing`, the sheet opens on that repo's `section` and Save rewrites its entry.
    init(
        configPath: String,
        secrets: SecretsReader,
        editing key: String? = nil,
        section: EditRepo.Section = .routing,
        linearClient: @escaping (_ apiKey: String) -> LinearClient = {
            LinearClient(apiKey: $0, endpoint: AppStores.current.linearEndpoint)
        },
        gitHubCLI: @escaping () -> GitHubCLI? = {
            GitHubCLI.locate(environment: AppStores.current.environment).map(GitHubCLI.process)
        },
        onSaved: @escaping (Saved) -> Void
    ) {
        self.configPath = configPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secrets = secrets
        self.gitHubCLI = gitHubCLI
        self.linearClient = linearClient
        self.onSaved = onSaved
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
        self.section = section
        self.existing = existing
        self.configProblem = configProblem
        if let editing {
            draft = EditRepo.draft(for: editing)
            keyEdited = true
            // A connected repo's base branch is never replaced by the source's default branch.
            baseBranchEdited = true
        }
        if key == nil || section == .routing { loadLinear() }
    }

    var title: String {
        if let key = editing?.key { return section.sheetTitle(key: key) }
        return AddRepo.sheetTitle
    }

    /// The entry Save writes, or what stops it.
    var validation: Result<RepositoryEntry, AddRepoProblem> {
        if let configProblem { return .failure(AddRepoProblem(configProblem)) }
        if let editing { return EditRepo.entry(for: draft, editing: editing, existing: existing) }
        return flow.entry
    }

    /// The Add Repo sheet's state, for its steps' checks and lines.
    var flow: AddRepoFlow {
        AddRepoFlow(
            draft: draft,
            existing: existing,
            inspectingFolder: isInspectingFolder,
            defaultBranch: defaultBranch,
            workflowCheck: workflowCheck,
            landing: landing,
            workflowText: workflowText,
            landedWorkflow: landedWorkflow,
            projects: linear,
            labels: labelsState,
            editing: editing != nil,
            // A Symphony that isn't running can't connect the repo now: it stays on polling until Finish Setup….
            instantUpdates: instantUpdatesOn && setupCheck?.phase != .onNextStart
        )
    }

    /// The Source sheet's line on the source picked, nil while it is still the repo's own.
    var editSourceResult: AddRepoSourceResult? {
        guard let editing, !EditRepo.isSourceUnchanged(draft, editing: editing) else { return nil }
        return flow.sourceResult
    }

    /// The Linear routing sheet's Default repo checkbox.
    var defaultOption: EditRepo.DefaultOption? {
        editing.map { EditRepo.defaultOption(editing: $0, existing: existing, isOn: draft.isDefault) }
    }

    /// Why Continue, or Connect on Review, is off on the page shown; nil while it is on.
    var stepProblem: AddRepoProblem? {
        if let configProblem { return AddRepoProblem(configProblem) }
        return flow.problem(at: step)
    }

    /// `owner/repo`, or the local folder, the WORKFLOW.md step talks about.
    var workflowSource: String {
        if draft.mode == .localFolder, case let .success(checkout)? = draft.folder {
            return (checkout.path as NSString).abbreviatingWithTildeInPath
        }
        return draft.gitHub ?? ""
    }

    var canSave: Bool {
        if case .success = validation { return !isInspectingFolder && !isSaving && labelsState != .loading }
        return false
    }

    /// Whether the picked project's labels can be typed in the Linear routing sheet: once Linear answered.
    var canEditLabels: Bool {
        linear == .loaded && labelsState == .loaded
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
            // The field commits on focus loss too, as Save is pressed: only a typed change checks the repo again.
            guard branch != self.draft.baseBranch else { return }
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
            self.loadLabels()
        })
    }

    /// The picked labels, as the label field edits them.
    var pickedLabels: Binding<[String]> {
        Binding(get: { self.draft.labels }, set: { self.draft.labels = $0 })
    }

    func isLabelPicked(_ name: String) -> Binding<Bool> {
        Binding(get: { self.draft.labels.contains(name) }, set: { picked in
            self.draft.labels.removeAll { $0 == name }
            if picked { self.draft.labels.append(name) }
        })
    }

    // MARK: Actions

    /// Goes on to the next page, or connects the repo on Review.
    func goForward() {
        guard stepProblem == nil, !isSaving, step != .check, step != .instantUpdates else { return }
        if let next = flow.step(after: step) {
            step = next
        } else {
            save()
        }
    }

    func goBack() {
        guard !isSaving, let previous = flow.step(before: step) else { return }
        step = previous
    }

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
    /// a project Linear doesn't list. A new repo's route names the project by its ID, and its team when it has one.
    func loadLabels() {
        labels = []
        let picked = draft.project
        let projectID = picked.flatMap { name in projects.first { $0.name == name }?.id }
        if editing == nil {
            draft.projectID = projectID
            draft.team = nil
        }
        guard let client, projectID != nil || editing != nil else {
            labelsState = .loaded
            pruneLabels()
            return
        }
        labelsState = .loading
        Task {
            let result = await client.scope(forProject: projectID)
            // Another project was picked meanwhile; its own load fills the labels.
            guard draft.project == picked else { return }
            switch result {
            case let .success(scope):
                labels = scope.labels
                if editing == nil { draft.team = scope.teamKey }
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
        // A QA pass opens the panel in the checkout it prepared, then presses Choose.
        if let folder = AppStores.current.qaMode?.openPanelDirectory { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pickFolder(url.path)
    }

    func pickFolder(_ path: String) {
        isInspectingFolder = true
        pickedFolder = path
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
        if editing == nil, landedWorkflow == nil, case let .missing(stack, _) = workflowCheck, landing != .skip {
            addWorkflow(stack, then: entry)
            return
        }
        if let editing, section == .review {
            saveChecked(editing, to: entry)
            return
        }
        do {
            let file = SymphonyConfigFile(path: configPath)
            if let editing {
                try file.editRepository(editing, to: entry)
                saveError = nil
                onSaved(.edited(
                    from: editing,
                    to: entry,
                    previousDefault: EditRepo.previousDefault(from: editing, to: entry, existing: existing)
                ))
            } else {
                let madeDefault = try file.connectRepository(entry)
                saveError = nil
                let reached = apply()
                onSaved(.added(key: entry.key, madeDefault: madeDefault, workflow: landedWorkflow))
                startCheck(AddRepoSetupCheck(key: entry.key, route: entry.route, apply: reached))
            }
        } catch {
            saveError = "Couldn't save symphony.yml: \(error.localizedDescription)"
        }
    }

    // MARK: Check setup

    /// Goes to Check setup, and checks unless Symphony isn't running.
    private func startCheck(_ check: AddRepoSetupCheck) {
        step = .check
        setupCheck = check
        if check.phase == .checking { runCheck() }
    }

    /// Check Again, and the check after a settings fix.
    func checkAgain() {
        guard var check = setupCheck, check.phase != .onNextStart else { return }
        check.phase = .checking
        setupCheck = check
        runCheck()
    }

    private func runCheck() {
        checkTask?.cancel()
        guard let key = setupCheck?.key else { return }
        let check = checkRepo
        checkTask = Task {
            let result = await check(key)
            guard !Task.isCancelled, setupCheck?.key == key else { return }
            switch result {
            case let .checked(payload):
                setupCheck?.phase = .checked(payload)
            case let .failed(message):
                setupCheck?.phase = .failed(message)
            }
        }
    }

    // MARK: Instant updates (S13)

    /// Asks Symphony whether instant updates are on, so the sheet ends with them. Only when adding a repo.
    func loadInstantUpdates() {
        guard editing == nil else { return }
        let read = readGitHubUpdates
        Task {
            if case let .updated(section) = await read() { instantUpdatesOn = section.isInstant }
        }
    }

    /// Check setup's Done: on to Instant updates while they are on, else the sheet closes.
    func finishCheck() {
        guard let check = setupCheck, flow.steps.contains(.instantUpdates) else { return finish() }
        checkTask?.cancel()
        step = .instantUpdates
        let send = gitHubUpdatesRequest
        let read = readGitHubUpdates
        let controller = AddRepoInstantUpdatesController(key: check.key, services: AddRepoInstantUpdatesController.Services(
            send: { await send($0, $1) }, read: { await read() }
        ))
        controller.onChange = { [weak self, weak controller] step in
            guard let self, let controller, instantController === controller else { return }
            instantUpdates = step
        }
        instantController = controller
        instantUpdates = controller.step
        Task { await controller.start() }
    }

    func retryInstantUpdates(_ rowID: String) {
        guard let controller = instantController else { return }
        Task { await controller.retry(rowID) }
    }

    /// Done: the card shows the repo connected, and the sheet closes.
    func finishInstantUpdates() {
        if let section = instantUpdates?.section { onGitHubUpdates(section) }
        finish()
    }

    /// Skip: the repo stays on polling, and the sheet closes; a repo Symphony couldn't take back keeps it open with why.
    func skipInstantUpdates() {
        guard let controller = instantController else { return finish() }
        instantSkipError = nil
        Task {
            if let problem = await controller.skip() {
                instantSkipError = problem
            } else {
                finish()
            }
        }
    }

    /// Start Symphony: it checks the repo as it starts, and opens Setup if something is wrong.
    func startSymphonyAndClose() {
        startSymphony()
        finish()
    }

    /// Done, or Close: the repo stays saved, and the errors stay on the Setup page.
    func finish() {
        checkTask?.cancel()
        instantController?.close()
        close()
    }

    /// A row's button: a fix opens its sheet; an `open` fix goes where the operator fixes it.
    func perform(_ action: SetupPage.Action, on row: SetupPage.Row, ticket: String? = nil) {
        switch action {
        case let .fix(.configEdit(path, action, value)):
            guard fixSheet?.isWorking != true else { return }
            fixSheet = SetupFixRunner.configSheet(row.problem, path: path, action: action, value: value, configPath: configPath)
        case .fix:
            guard fixSheet?.isWorking != true else { return }
            fixSheet = SetupFixSheet(problem: row.problem, ticket: ticket)
        case let .open(destination):
            openDestination(destination)
        }
    }

    func cancelFix() {
        guard fixSheet?.isWorking != true else { return }
        fixSheet = nil
    }

    /// The fix sheet's verb: makes the fix, then shows the repo's problems after it.
    func confirmFix(_ sheet: SetupFixSheet) {
        guard !sheet.isWorking, sheet.canConfirm, let key = setupCheck?.key else { return }
        var working = sheet
        working.start()
        fixSheet = working
        fixMessage = nil
        Task {
            switch await SetupFixRunner.run(working, configPath: configPath, checkConfig: configCheck, request: setupRequest) {
            case let .fixed(payload, backup):
                fixSheet = nil
                fixMessage = SetupBanner.fixed(working, backup: backup).text
                if let payload, setupCheck?.key == key {
                    setupCheck?.phase = .checked(payload.forRepo(key))
                } else {
                    checkAgain()
                }
            case .unchanged:
                fixSheet = nil
                checkAgain()
            case let .failed(message):
                guard fixSheet?.id == working.id else { return }
                working.fail(message)
                fixSheet = working
            }
        }
    }

    /// Writes the edited entry once `symphony check` passes on the result; a rejection stays in the sheet and nothing
    /// is written.
    private func saveChecked(_ editing: RepositoryEntry, to entry: RepositoryEntry) {
        let file = SymphonyConfigFile(path: configPath)
        let check = configCheck
        isSaving = true
        saveError = nil
        savingMessage = "Running symphony check…"
        Task {
            let result: Result<ConfigCheckResult, Error>
            do {
                result = .success(try await file.rewrite({ try EditRepo.updating(editing, to: entry, in: $0) }, checkingWith: check))
            } catch {
                result = .failure(error)
            }
            isSaving = false
            savingMessage = nil
            switch result {
            case .success(.passed):
                onSaved(.edited(from: editing, to: entry, previousDefault: nil))
            case let .success(.failed(message)):
                saveError = "symphony check rejected this, so nothing was saved: \(ConfigCheck.reasonFirst(message))"
            case let .failure(error):
                saveError = "Couldn't save symphony.yml: \(error.localizedDescription)"
            }
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
        guard editing == nil || section == .source else { return }
        switch draft.mode {
        case .localFolder:
            guard case let .success(checkout)? = draft.folder else {
                workflowCheck = .idle
                defaultBranch = nil
                return
            }
            defaultBranch = checkout.defaultBranch
            workflowCheck = checkout.hasWorkflow ? .present : .missing(folderStack ?? WorkflowStack(), branch: nil)
            redraftWorkflow()
        case .gitHub:
            guard let gitHub = draft.gitHub else {
                workflowCheck = .idle
                defaultBranch = nil
                return
            }
            guard let cli = gitHubCLI() else {
                defaultBranch = nil
                workflowCheck = .failed(GitHubCLI.missingMessage)
                return
            }
            workflowCheck = .checking
            defaultBranch = nil
            let branch = baseBranchEdited ? draft.baseBranch : nil
            workflowProbe = Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                let result = await Task.detached { cli.probe(gitHub, branch: branch) }.value
                guard !Task.isCancelled else { return }
                switch result {
                case let .success(probe):
                    defaultBranch = probe.defaultBranch
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

    /// Fills the key from the repo's name until the engineer types one.
    private func suggestKey() {
        guard !keyEdited, let gitHub = draft.gitHub else { return }
        draft.key = AddRepo.suggestedKey(for: GitHubRepoInput.name(gitHub), existing: existing.map(\.key))
    }
}

/// The Add Repo sheet, one question per page: where the repo's code comes from, which Linear issues it takes, its
/// WORKFLOW.md when it has none, then a review with its key and base branch. 520pt square, so its footer stays on a
/// 1024×768 screen on every page.
struct AddRepoView: View {
    static let size = CGSize(width: 520, height: 520)

    @ObservedObject var model: AddRepoViewModel
    let cancel: () -> Void

    var body: some View {
        let flow = model.flow
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.title).font(.headline)
                AddRepoStepIndicator(steps: flow.steps, current: model.step)
            }
            .padding([.top, .horizontal], 16)
            .padding(.bottom, 8)
            Divider()
            Group {
                if let configProblem = model.configProblem {
                    AddRepoWarningBox(message: configProblem)
                        .padding(16)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    page(flow)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // A late result of Connect would otherwise land the WORKFLOW.md for a source or branch changed meanwhile.
            .disabled(model.isSaving)
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    @ViewBuilder private func page(_ flow: AddRepoFlow) -> some View {
        switch model.step {
        case .source:
            sourcePage(flow)
        case .linear:
            linearPage(flow)
        case .workflow:
            workflowPage
        case .review:
            reviewPage(flow)
        case .instantUpdates:
            if let instant = model.instantUpdates {
                ScrollView {
                    AddRepoInstantUpdatesPage(step: instant, skipError: model.instantSkipError, retry: model.retryInstantUpdates)
                }
            }
        case .check:
            if let check = model.setupCheck {
                ScrollView {
                    AddRepoCheckPage(check: check, fixMessage: model.fixMessage, actions: SetupPageActions(
                        perform: { action, row, ticket in model.perform(action, on: row, ticket: ticket) }
                    ))
                }
                .sheet(item: fixSheet) { sheet in
                    SetupFixSheetView(sheet: sheet, cancel: model.cancelFix, confirm: { model.confirmFix(sheet) }, open: model.openDestination)
                }
            }
        }
    }

    private var fixSheet: Binding<SetupFixSheet?> {
        Binding(get: { model.fixSheet }, set: { if $0 == nil { model.cancelFix() } })
    }

    @ViewBuilder private var footer: some View {
        if model.step == .instantUpdates, let instant = model.instantUpdates {
            AddRepoInstantUpdatesFooter(step: instant, skip: model.skipInstantUpdates, finish: model.finishInstantUpdates)
        } else if model.step == .check, let check = model.setupCheck {
            checkFooter(check)
        } else {
            stepFooter
        }
    }

    private func checkFooter(_ check: AddRepoSetupCheck) -> some View {
        AddRepoCheckFooter(
            check: check,
            canStart: model.canStartSymphony(),
            doneTitle: model.flow.steps.contains(.instantUpdates) ? AddRepoInstantUpdates.continueTitle : AddRepoSetupCheck.doneTitle,
            checkAgain: model.checkAgain,
            start: model.startSymphonyAndClose,
            finish: model.finishCheck,
            close: model.finish
        )
    }

    private var stepFooter: some View {
        let problem = model.stepProblem
        let isLast = model.step == .review
        return HStack {
            Button("Cancel", role: .cancel, action: cancel)
                .keyboardShortcut(.cancelAction)
            Spacer()
            if model.isSaving {
                ProgressView().controlSize(.small)
                Text(model.savingMessage ?? "Saving…")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button(AddRepoFlow.backTitle, action: model.goBack)
                .disabled(model.step == .source || model.isSaving)
            Button(isLast ? AddRepoFlow.connectTitle : AddRepoFlow.continueTitle, action: model.goForward)
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil || model.isSaving || (isLast && !model.canSave))
                .help(problem?.message ?? "")
        }
        .padding(12)
    }

    // MARK: Source

    private func sourcePage(_ flow: AddRepoFlow) -> some View {
        Form {
            Section {
                Picker("Source", selection: model.mode) {
                    ForEach(AddRepoDraft.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                switch model.draft.mode {
                case .gitHub:
                    TextField("GitHub repo", text: model.gitHubInput, prompt: Text(verbatim: "https://github.com/owner/repo"))
                    Text("Symphony keeps its own clone. Your checkouts aren't touched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .localFolder:
                    LabeledContent("Folder") {
                        HStack {
                            Text(model.pickedFolder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "No folder chosen")
                                .foregroundStyle(model.pickedFolder == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Choose…", action: model.chooseFolder)
                        }
                    }
                    Text("Agents work in worktrees of this checkout. It needs a GitHub origin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let result = flow.sourceResult {
                    AddRepoSourceResultRow(result: result)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Linear

    private func linearPage(_ flow: AddRepoFlow) -> some View {
        Form {
            Section("Linear routing") {
                ForEach(flow.linearRows, id: \.self) { row in
                    linearRow(row, flow: flow)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func linearRow(_ row: AddRepoFlow.LinearRow, flow: AddRepoFlow) -> some View {
        switch row {
        case .project:
            HStack {
                Picker("Project", selection: model.project) {
                    Text(flow.projectPlaceholder).tag(String?.none)
                    ForEach(model.projects) { project in
                        Text(project.name).tag(String?.some(project.name))
                    }
                }
                .disabled(!flow.canPickProject)
                if model.linear == .loading { ProgressView().controlSize(.small) }
            }
        case .labels:
            LabeledContent("Labels") {
                HStack {
                    LabelTokenField(labels: model.pickedLabels, suggestions: model.labelChoices, placeholder: flow.labelsPlaceholder)
                        .disabled(!flow.canPickLabels)
                    if model.labelsState == .loading { ProgressView().controlSize(.small) }
                }
            }
        case let .twin(message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .preview:
            Label(flow.routePreview, systemImage: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case let .warning(message):
            AddRepoWarningBox(message: message) {
                Button(AddRepoFlow.retryTitle, action: model.loadLinear)
                Button(AddRepoFlow.openSettingsTitle) { model.openSettings() }
            }
        }
    }

    // MARK: WORKFLOW.md

    @ViewBuilder private var workflowPage: some View {
        if case let .missing(stack, _) = model.workflowCheck {
            WorkflowSetupPage(
                message: model.workflowCheck.missingMessage(source: model.workflowSource) ?? "",
                found: stack.summary,
                draft: model.workflowDraft,
                landing: $model.landing,
                choices: WorkflowLanding.choices(for: model.draft.mode),
                baseBranch: model.draft.baseBranch.trimmingCharacters(in: .whitespaces),
                landed: model.landedWorkflow
            )
            .padding(16)
        }
    }

    // MARK: Review

    private func reviewPage(_ flow: AddRepoFlow) -> some View {
        let keyProblem = AddRepo.keyProblem(model.draft.key, existing: flow.existing.map(\.key))
        let branchProblem = AddRepo.baseBranchProblem(model.draft.baseBranch)
        return Form {
            Section {
                LabeledContent("Source") { summary(flow.sourceSummary) }
                LabeledContent("Linear") { summary(flow.routePreview) }
                LabeledContent("Route") { summary(flow.routeWritten) }
                LabeledContent(WorkflowTemplate.fileName) { summary(flow.workflowSummary) }
            }
            Section {
                TextField("Repo key", text: model.key, prompt: Text("Filled in from the repo name"))
                if let keyProblem { inlineProblem(keyProblem.message) }
                TextField("Base branch", text: model.baseBranch, prompt: Text(AddRepo.defaultBaseBranch))
                if let branchProblem { inlineProblem(branchProblem.message) }
            }
            Section {
                if let defaultLine = flow.defaultLine {
                    Text(defaultLine).fixedSize(horizontal: false, vertical: true)
                }
                Text(AddRepo.nextLine(apply: model.apply()))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let saveError = model.saveError {
                    AddRepoWarningBox(message: saveError)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func summary(_ text: String) -> some View {
        Text(text)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func inlineProblem(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// SU11, the Check setup page: "Checking setup for <repo>…", then the repo's problems with their fixes, as on the Setup
/// page, and once no error is left, the route Connect wrote. Outside the sheet's model and its scroll view so it also
/// renders offscreen.
struct AddRepoCheckPage: View {
    let check: AddRepoSetupCheck
    var fixMessage: String?
    var actions = SetupPageActions()
    var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            sentence
            if let page = check.page(now: now) {
                groups(page.errors, severity: .error)
                groups(page.warnings, severity: .warning)
            }
            if !check.written.isEmpty {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                    Text("Written to symphony.yml")
                        .font(DesignTokens.TypeStyle.label.font)
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DesignTokens.Space.s3, verticalSpacing: DesignTokens.Space.s1) {
                        ForEach(check.written, id: \.self) { line in
                            GridRow {
                                Text(line.label).foregroundStyle(.secondary)
                                Text(line.value)
                                    .font(DesignTokens.TypeStyle.mono.font)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            if let fixMessage {
                Label(fixMessage, systemImage: DesignTokens.Status.done.symbol)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DesignTokens.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sentence: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
            mark
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                Text(check.headline)
                    .font(DesignTokens.TypeStyle.rowTitle.font)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let detail = check.detail {
                    Text(detail)
                        .font(DesignTokens.TypeStyle.callout.font)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var mark: some View {
        switch check.phase {
        case .checking:
            ProgressView().controlSize(.small).accessibilityLabel("Checking")
        case .failed:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(DesignTokens.Status.you.tint).accessibilityHidden(true)
        case .onNextStart:
            Image(systemName: "clock").foregroundStyle(.secondary).accessibilityHidden(true)
        case let .checked(payload):
            if !payload.errors.isEmpty {
                Image(systemName: SetupSeverityMark.error.symbol).foregroundStyle(SetupSeverityMark.error.tint).accessibilityHidden(true)
            } else if !payload.warnings.isEmpty {
                Image(systemName: SetupSeverityMark.warning.symbol).foregroundStyle(SetupSeverityMark.warning.tint).accessibilityHidden(true)
            } else {
                Image(systemName: DesignTokens.Status.done.symbol).foregroundStyle(DesignTokens.Status.done.tint).accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private func groups(_ groups: [SetupPage.Group], severity: SetupPayload.Severity) -> some View {
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                Text(severity == .error ? SetupPage.errorsTitle : SetupPage.warningsTitle)
                    .font(DesignTokens.TypeStyle.label.font)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(groups.flatMap(\.rows)) { row in
                    SetupRowView(row: row, severity: severity, actions: actions)
                    Divider()
                }
            }
        }
    }
}

/// SU11's footer: Close, then Check Again or Start Symphony, and Done, off with its reason while the repo has an error.
/// Closing keeps the repo saved.
struct AddRepoCheckFooter: View {
    let check: AddRepoSetupCheck
    var canStart = false
    /// Done, or Continue while Instant updates follow.
    var doneTitle = AddRepoSetupCheck.doneTitle
    var checkAgain: () -> Void = {}
    var start: () -> Void = {}
    var finish: () -> Void = {}
    var close: () -> Void = {}

    var body: some View {
        HStack {
            Button("Close", role: .cancel, action: close)
                .keyboardShortcut(.cancelAction)
            Spacer()
            if let problem = check.doneProblem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if check.offersCheckAgain {
                Button(AddRepoSetupCheck.checkAgainTitle, action: checkAgain)
            }
            if check.offersStart {
                Button(AddRepoSetupCheck.startTitle, action: start)
                    .disabled(!canStart)
            }
            Button(doneTitle, action: finish)
                .keyboardShortcut(.defaultAction)
                .disabled(!check.canFinish)
                .help(check.doneProblem ?? "")
        }
        .padding(12)
    }
}

/// "1 Source › 2 Linear › 3 WORKFLOW.md › 4 Review", the page shown in bold and those done checked, on one line: with
/// more steps than fit, the steps done show by their tick alone, and the others by name alone (`AddRepoStepIndicatorFit`).
struct AddRepoStepIndicator: View {
    let steps: [AddRepoStep]
    let current: AddRepoStep

    var body: some View {
        let index = steps.firstIndex(of: current) ?? 0
        ViewThatFits(in: .horizontal) {
            row(.full)
            row(.compact)
            row(.currentOnly)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(index + 1) of \(steps.count): \(current.rawValue)")
    }

    private func row(_ fit: AddRepoStepIndicatorFit) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(fit.marks(steps, current: current).enumerated()), id: \.element.step) { position, mark in
                if position > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 3) {
                    if mark.isDone {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                    } else if let number = mark.number {
                        Text("\(number)")
                            .monospacedDigit()
                    }
                    if let name = mark.name {
                        Text(name)
                    }
                }
                .font(.callout)
                .fontWeight(mark.isCurrent ? .semibold : .regular)
                .foregroundStyle(mark.isCurrent ? .primary : .secondary)
                .lineLimit(1)
                .help(mark.name == nil ? mark.step.rawValue : "")
            }
        }
    }
}

/// The Source page's line on what the sheet found, or why it can't use the source, in red.
struct AddRepoSourceResultRow: View {
    let result: AddRepoSourceResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch result.style {
            case .checking:
                ProgressView().controlSize(.small)
            case .found:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .note:
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            case .problem:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
            Text(result.text)
                .foregroundStyle(result.style == .problem ? Color.red : result.style == .found ? .primary : .secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A warning in a box, with the buttons that fix it.
struct AddRepoWarningBox<Actions: View>: View {
    let message: String
    var showsActions = true
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsActions {
                HStack {
                    Spacer()
                    actions
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}

extension AddRepoWarningBox where Actions == EmptyView {
    init(message: String) {
        self.init(message: message, showsActions: false) { EmptyView() }
    }
}

/// S13, the Instant updates page: "Instant updates for <repo>", what it does and why, then the webhook and the test
/// update, each done, working or failed with Retry. Outside the sheet's model so it also renders offscreen.
struct AddRepoInstantUpdatesPage: View {
    let step: AddRepoInstantUpdates
    var skipError: String?
    var retry: (_ rowID: String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            Text(step.title)
                .font(DesignTokens.TypeStyle.rowTitle.font)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(step.explanation)
                .font(DesignTokens.TypeStyle.body.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GitHubUpdatesSetupRows(rows: step.rows) { _, rowID in retry(rowID) }
            if let skipError {
                Label(skipError, systemImage: DesignTokens.Status.problem.symbol)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(DesignTokens.Status.problem.tint)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DesignTokens.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// S13's footer: Skip (the repo stays on polling), then Done, off with its reason until the test update arrived.
struct AddRepoInstantUpdatesFooter: View {
    let step: AddRepoInstantUpdates
    var skip: () -> Void = {}
    var finish: () -> Void = {}

    var body: some View {
        HStack {
            Button(AddRepoInstantUpdates.skipTitle, action: skip)
                .keyboardShortcut(.cancelAction)
                .disabled(!step.canSkip)
                .help("Leaves \(step.key) on polling.")
            Spacer()
            if let problem = step.doneProblem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(AddRepoInstantUpdates.doneTitle, action: finish)
                .keyboardShortcut(.defaultAction)
                .disabled(!step.canFinish)
                .help(step.doneProblem ?? "")
        }
        .padding(12)
    }
}
