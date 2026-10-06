import Foundation

/// The Edit Repo sheet's checks and the entry it writes: the Add Repo sheet opened on a connected repo, kept free
/// of SwiftUI so they can be unit tested.
public enum EditRepo {
    public static let buttonTitle = "Edit…"

    public static func sheetTitle(key: String) -> String {
        "Edit \(key)"
    }

    /// The draft the sheet opens with. A local folder repo's draft has no folder picked: Save keeps the entry's
    /// folder until another one is chosen. An entry without a base branch leaves the field empty.
    public static func draft(for entry: RepositoryEntry) -> AddRepoDraft {
        let source = entry.workspace.source?.trimmingWhitespace() ?? ""
        return AddRepoDraft(
            mode: source.isEmpty ? .localFolder : .gitHub,
            gitHubInput: source,
            key: entry.key,
            baseBranch: entry.baseBranch ?? "",
            project: entry.route.projects?.first,
            labels: entry.route.labels ?? [],
            acceptanceGate: AcceptanceGateChoice(override: entry.acceptanceGateMode)
        )
    }

    /// `original` changed as the draft says, or the first thing that stops it. Only what the sheet edits changes:
    /// the key, the default flag, the route's team and assignee, `fetch_before_dispatch` and keys the app doesn't
    /// know stay. The acceptance gate mode changes only when its picker moved, so a value Symphony rejects stays
    /// until another one is picked; Inherit removes it. An unchanged source keeps the entry's workspace and workflow as they are. `existing` is the
    /// `repositories:` list now, with `original` in it.
    public static func entry(
        for draft: AddRepoDraft,
        editing original: RepositoryEntry,
        existing: [RepositoryEntry]
    ) -> Result<RepositoryEntry, AddRepoProblem> {
        var entry = original
        let originalSource = original.workspace.source?.trimmingWhitespace() ?? ""
        let fetch = original.workspace.fetchBeforeDispatch

        switch draft.mode {
        case .gitHub:
            let input = draft.gitHubInput.trimmingWhitespace()
            guard !input.isEmpty else { return .failure(AddRepoProblem("Paste a GitHub repo URL or owner/repo.")) }
            guard let gitHub = GitHubRepoInput.normalize(input) else {
                return .failure(AddRepoProblem(
                    "Use a GitHub repo as https://github.com/owner/repo, git@github.com:owner/repo.git or owner/repo."
                ))
            }
            let unchanged = !originalSource.isEmpty
                && (input == originalSource || GitHubRepoInput.normalize(originalSource) == gitHub)
            if !unchanged {
                // Symphony reads a managed repo's WORKFLOW.md from its clone, and refuses `repo` or
                // `strategy: clone` next to `source`.
                entry.workflow = nil
                entry.workspace = RepositoryWorkspace(source: gitHub, fetchBeforeDispatch: fetch)
            }
        case .localFolder:
            switch draft.folder {
            case nil:
                if !originalSource.isEmpty { return .failure(AddRepoProblem("Choose the folder of a git checkout.")) }
            case let .failure(problem)?:
                return .failure(problem)
            case let .success(checkout)?:
                if !checkout.hasWorkflow { return .failure(checkout.missingWorkflowProblem) }
                entry.workflow = checkout.workflowPath
                entry.workspace = RepositoryWorkspace(strategy: "worktree", repo: checkout.path, fetchBeforeDispatch: fetch)
            }
        }

        let baseBranch = draft.baseBranch.trimmingWhitespace()
        entry.baseBranch = baseBranch.isEmpty ? nil : baseBranch

        // A route with several projects keeps them while the first one stays picked.
        let project = draft.project?.trimmingWhitespace() ?? ""
        if project != (original.route.projects?.first ?? "") {
            entry.route.projects = project.isEmpty ? nil : [project]
        }
        let labels = draft.labels.map { $0.trimmingWhitespace() }.filter { !$0.isEmpty }
        if Set(labels) != Set(original.route.labels ?? []) {
            entry.route.labels = labels.isEmpty ? nil : labels
        }

        if draft.acceptanceGate != AcceptanceGateChoice(override: original.acceptanceGateMode) {
            entry.acceptanceGateMode = draft.acceptanceGate.override
        }

        let others = existing.filter { $0.key != original.key }
        if AddRepo.isUnscoped(entry.route), entry.isDefault != true, !others.isEmpty {
            return .failure(AddRepoProblem(
                "Pick a project or labels. Symphony needs a route for every repo but the default one."
            ))
        }
        if let twin = others.first(where: { AddRepo.sameRoute($0.route, entry.route) }) {
            return .failure(AddRepoProblem(
                "`\(twin.key)` already takes the issues of this project and labels. Pick other labels or another project."
            ))
        }
        return .success(entry)
    }

    /// True when Symphony must restart to use the change: it sets up a repo's source and workflow when it starts,
    /// but reads routes from `symphony.yml` while it runs.
    public static func needsRestart(from original: RepositoryEntry, to entry: RepositoryEntry) -> Bool {
        original.workspace != entry.workspace || original.workflow != entry.workflow || original.baseBranch != entry.baseBranch
    }

    /// True when Save changes the repo's acceptance gate mode, so it runs `symphony check` first.
    public static func changesAcceptanceGate(from original: RepositoryEntry, to entry: RepositoryEntry) -> Bool {
        original.acceptanceGateMode != entry.acceptanceGateMode
    }

    /// `yaml` with the repo `original.key` rewritten to `entry`. When the sheet leaves the acceptance gate mode as
    /// it was, the entry keeps the mode `yaml` holds now, so a Save doesn't undo a mode set elsewhere, such as the
    /// status menu's kill switch, while the sheet was open.
    public static func updating(_ original: RepositoryEntry, to entry: RepositoryEntry, in yaml: String) throws -> String {
        var entry = entry
        if !changesAcceptanceGate(from: original, to: entry),
           let current = try RepositoriesConfig.entries(in: yaml).first(where: { $0.key == original.key }) {
            entry.acceptanceGateMode = current.acceptanceGateMode
        }
        return try RepositoriesConfig.updating(original.key, to: entry, in: yaml)
    }

    /// How the change reaches Symphony: nil when Symphony reads it from `symphony.yml` without a restart.
    public static func apply(status: SymphonyStatus, from original: RepositoryEntry, to entry: RepositoryEntry) -> AddRepoApply? {
        needsRestart(from: original, to: entry) ? AddRepo.apply(status: status) : nil
    }

    /// The alert asking before a restart that waits for `runs` agent runs.
    public static func restartQuestion(key: String, runs: Int) -> (title: String, message: String) {
        (
            "Restart Symphony to apply the change to \(key)?",
            "\(AddRepo.activeRuns(runs)) Restart pauses dispatch, waits for them to finish, then starts Symphony again, "
                + "which sets up \(key) from its new settings."
        )
    }

    /// What the window says after saving, for how the change reaches Symphony.
    public static func savedMessage(key: String, apply: AddRepoApply?) -> String {
        switch apply {
        case nil:
            return "Saved \(key). Symphony reads the change from symphony.yml, so its next poll uses it."
        case .restart?, .askToRestart?:
            return "Saved \(key). Symphony restarts to apply it."
        case .onNextStart?:
            return "Saved \(key). Symphony uses it when it starts."
        case .restartManually?:
            return "Saved \(key). Restart Symphony to apply it."
        }
    }
}

/// Disconnecting a repo: its entry leaves `repositories:`, and nothing on disk is deleted.
public enum DisconnectRepo {
    public static let buttonTitle = "Disconnect…"
    public static let confirmTitle = "Disconnect"

    /// Why the repo `key` can't be disconnected, nil when it can.
    public static func problem(key: String, entries: [RepositoryEntry]) -> String? {
        guard entries.contains(where: { $0.key == key }) else {
            return "symphony.yml has no repo `\(key)`. Symphony keeps it until it restarts."
        }
        guard entries.count > 1 else { return "\(key) is the only repo, and Symphony needs at least one." }
        return nil
    }

    /// The keys that can become the default in place of `key`, nil when `key` isn't the default.
    public static func defaultCandidates(key: String, entries: [RepositoryEntry]) -> [String]? {
        guard entries.first(where: { $0.key == key })?.isDefault == true else { return nil }
        return entries.map(\.key).filter { $0 != key }
    }

    /// `yaml` without the entry `key` and its attached comment. Removing the default repo makes `newDefault` the
    /// default first. Never touches the files the entry names.
    public static func removing(_ key: String, newDefault: String?, from yaml: String) throws -> String {
        let entries = try RepositoriesConfig.entries(in: yaml)
        guard let entry = entries.first(where: { $0.key == key }) else { throw RepositoriesConfigError.notFound(key) }
        guard entries.count > 1 else { throw RepositoriesConfigError.lastRepository(key) }
        var text = yaml
        if entry.isDefault == true {
            guard let newDefault, newDefault != key, var next = entries.first(where: { $0.key == newDefault }) else {
                throw RepositoriesConfigError.invalidEntry("Pick the repo that becomes the default in place of `\(key)`.")
            }
            next.isDefault = true
            text = try RepositoriesConfig.updating(newDefault, to: next, in: text)
        }
        return try RepositoriesConfig.removing(key, from: text)
    }

    /// The alert asking before disconnecting `entry`.
    public static func question(for entry: RepositoryEntry, newDefaultNeeded: Bool) -> (title: String, message: String) {
        var message = "Symphony stops taking issues for \(entry.key), and its entry and comment leave symphony.yml."
        if let source = entry.workspace.source?.trimmingWhitespace(), !source.isEmpty {
            message += " Symphony's clone of \(ReposList.gitHubRepo(source)) stays on disk: to delete it, use "
                + "\(ManagedClones.buttonTitle) before disconnecting."
        } else if let repo = entry.workspace.repo?.trimmingWhitespace(), !repo.isEmpty {
            message += " The folder \(repo) and its branches stay as they are."
        }
        if newDefaultNeeded {
            message += " \(entry.key) is the default repo: pick the repo that takes the issues no route matches."
        }
        return ("Disconnect \(entry.key)?", message)
    }

    /// What the window says after disconnecting, for how the change reaches Symphony.
    public static func message(key: String, apply: AddRepoApply, newDefault: String?) -> String {
        var message: String
        switch apply {
        case .restart, .askToRestart:
            message = "Disconnected \(key). Symphony restarts to drop it."
        case .onNextStart:
            message = "Disconnected \(key)."
        case .restartManually:
            message = "Disconnected \(key). Restart Symphony to drop it."
        }
        if let newDefault { message += " \(newDefault) is now the default repo." }
        return message
    }

    /// The alert asking before a restart that waits for `runs` agent runs.
    public static func restartQuestion(key: String, runs: Int) -> (title: String, message: String) {
        (
            "Restart Symphony to drop \(key)?",
            "\(AddRepo.activeRuns(runs)) Restart pauses dispatch, waits for them to finish, then starts Symphony again "
                + "without \(key). Until then Symphony gives it no new issues."
        )
    }
}

/// Edits and disconnects a repo in a `symphony.yml` on disk. Each one writes atomically, and leaves the file
/// untouched when it throws.
extension SymphonyConfigFile {
    public func editRepository(_ original: RepositoryEntry, to entry: RepositoryEntry) throws {
        try rewrite { try EditRepo.updating(original, to: entry, in: $0) }
    }

    public func disconnectRepository(_ key: String, newDefault: String?) throws {
        try rewrite { try DisconnectRepo.removing(key, newDefault: newDefault, from: $0) }
    }
}
