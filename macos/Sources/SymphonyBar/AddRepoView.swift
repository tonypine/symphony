import AppKit
import SwiftUI
import SymphonyBarCore

/// What the Add Repo sheet edits and shows. Linear's projects and labels load when it opens, with the stored
/// `LINEAR_API_KEY`; the repos in `symphony.yml` are read once, to check the key and the route against them.
@MainActor
final class AddRepoViewModel: ObservableObject {
    enum LinearState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @Published var draft = AddRepoDraft()
    @Published private(set) var projects: [LinearProject] = []
    @Published private(set) var labels: [LinearLabel] = []
    @Published private(set) var linear = LinearState.loading
    /// Why the folder picked is still being checked.
    @Published private(set) var isInspectingFolder = false
    /// Why the last Save failed.
    @Published private(set) var saveError: String?

    /// Why the sheet can't add a repo at all: no `symphony.yml` is set, or its repos can't be read.
    let configProblem: String?
    let configPath: String
    private let existing: [RepositoryEntry]
    private let secrets: SecretsReader
    /// True once the key was typed, so picking another source no longer replaces it.
    private var keyEdited = false
    private let linearClient: (_ apiKey: String) -> LinearClient
    private let onSaved: (_ key: String, _ madeDefault: String?) -> Void

    init(
        configPath: String,
        secrets: SecretsReader,
        linearClient: @escaping (_ apiKey: String) -> LinearClient = { LinearClient(apiKey: $0) },
        onSaved: @escaping (_ key: String, _ madeDefault: String?) -> Void
    ) {
        self.configPath = configPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secrets = secrets
        self.linearClient = linearClient
        self.onSaved = onSaved
        if self.configPath.isEmpty {
            existing = []
            configProblem = "Set the symphony.yml path in Settings first."
        } else {
            do {
                existing = try SymphonyConfigFile(path: self.configPath).readRepositories()
                configProblem = nil
            } catch {
                existing = []
                let shown = (self.configPath as NSString).abbreviatingWithTildeInPath
                configProblem = "Couldn't read the repos in \(shown): \(error.localizedDescription)"
            }
        }
        loadLinear()
    }

    /// The entry Save writes, or what stops it.
    var validation: Result<RepositoryEntry, AddRepoProblem> {
        if let configProblem { return .failure(AddRepoProblem(configProblem)) }
        return AddRepo.entry(for: draft, existing: existing)
    }

    var canSave: Bool {
        if case .success = validation { return !isInspectingFolder }
        return false
    }

    /// The labels an issue in the picked project can carry.
    var labelChoices: [String] {
        LinearLabel.names(labels, for: projects.first { $0.name == draft.project })
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
            let result = await Task.detached { LocalCheckout.inspect(path) }.value
            draft.folder = result
            isInspectingFolder = false
            suggestKey()
        }
    }

    func save() {
        guard canSave, case let .success(entry) = validation else { return }
        do {
            let madeDefault = try SymphonyConfigFile(path: configPath).connectRepository(entry)
            saveError = nil
            onSaved(entry.key, madeDefault)
        } catch {
            saveError = "Couldn't save symphony.yml: \(error.localizedDescription)"
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
            Text(AddRepo.sheetTitle)
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
                    TextField("Base branch", text: $model.draft.baseBranch, prompt: Text(AddRepo.defaultBaseBranch))
                }
                Section("Linear routing") {
                    linear
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
        .frame(width: 520, height: 600)
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
            return .secondary
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
                Text("Choose a project…").tag(String?.none)
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
