import SwiftUI
import SymphonyBarCore

/// What the Set Up WORKFLOW.md sheet of a connected repo shows: the repo read for a draft, the draft as the engineer
/// edited it, and how it lands. A failure stays in the sheet.
@MainActor
final class WorkflowSetupSheetModel: ObservableObject {
    enum Load: Equatable {
        case reading
        case ready(ConnectedWorkflowSetup.Found)
        case failed(String)
    }

    let setup: ConnectedWorkflowSetup
    @Published private(set) var load = Load.reading
    @Published var draft = ""
    @Published var landing = WorkflowLanding.pullRequest
    /// True while Create adds the file.
    @Published private(set) var isCreating = false
    /// Why the last Create failed.
    @Published private(set) var createError: String?

    private let gitHubCLI: () -> GitHubCLI?
    private let onCreated: (PendingWorkflow) -> Void

    init(
        setup: ConnectedWorkflowSetup,
        gitHubCLI: @escaping () -> GitHubCLI? = {
            GitHubCLI.locate(environment: AppStores.current.environment).map(GitHubCLI.process)
        },
        onCreated: @escaping (PendingWorkflow) -> Void
    ) {
        self.setup = setup
        self.gitHubCLI = gitHubCLI
        self.onCreated = onCreated
        read()
    }

    /// Reads the repo, off the main thread, and drafts the file from what it found.
    func read() {
        load = .reading
        let setup = setup
        let cli = gitHubCLI()
        Task {
            let result = await Task.detached { setup.read(cli: cli) }.value
            switch result {
            case let .success(found):
                draft = setup.draft(found)
                load = .ready(found)
            case let .failure(problem):
                load = .failed(problem.message)
            }
        }
    }

    var canCreate: Bool {
        guard case .ready = load else { return false }
        return !isCreating && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Adds the draft the way `landing` says, off the main thread; on success the sheet hands the file on.
    func create() {
        guard canCreate, case let .ready(found) = load else { return }
        let setup = setup
        let text = draft
        let landing = landing
        let cli = landing == .pullRequest ? gitHubCLI() : nil
        isCreating = true
        createError = nil
        Task {
            let result = await Task.detached { setup.create(text, landing: landing, found: found, cli: cli) }.value
            isCreating = false
            switch result {
            case let .success(pending):
                onCreated(pending)
            case let .failure(problem):
                createError = problem.message
            }
        }
    }
}

/// The WORKFLOW.md page of Add Repo, on its own for a connected repo that has none, with Create.
struct WorkflowSetupSheet: View {
    @ObservedObject var model: WorkflowSetupSheetModel
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.setup.sheetTitle)
                .font(.headline)
                .padding([.top, .horizontal], 16)
                .padding(.bottom, 8)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                content
                if let createError = model.createError {
                    AddRepoWarningBox(message: createError)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .disabled(model.isCreating)
            Divider()
            footer
        }
        .frame(width: AddRepoView.size.width, height: AddRepoView.size.height)
    }

    @ViewBuilder private var content: some View {
        switch model.load {
        case .reading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading \(model.setup.source) for a draft…")
                    .foregroundStyle(.secondary)
            }
        case let .failed(message):
            AddRepoWarningBox(message: message) {
                Button(AddRepoFlow.retryTitle, action: model.read)
            }
        case let .ready(found):
            WorkflowSetupPage(
                message: found.message(source: model.setup.source),
                found: found.stack.summary,
                draft: $model.draft,
                landing: $model.landing,
                choices: model.setup.choices,
                baseBranch: found.baseBranch
            )
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel, action: cancel)
                .keyboardShortcut(.cancelAction)
            Spacer()
            if model.isCreating {
                ProgressView().controlSize(.small)
                Text(model.landing == .pullRequest ? "Opening a pull request…" : "Writing WORKFLOW.md…")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button(ConnectedWorkflowSetup.createTitle, action: model.create)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canCreate)
        }
        .padding(12)
    }
}
