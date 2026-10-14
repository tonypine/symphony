import Foundation

/// The Edit sheets of a connected repo, one per section of its detail: Source, Linear routing and Review. Their
/// checks and the entry they write, kept free of SwiftUI so they can be unit tested.
public enum EditRepo {
    public static let buttonTitle = "Edit…"

    /// A section of the repo's detail with its own Edit sheet. Each sheet changes only its own fields.
    public enum Section: String, CaseIterable, Identifiable {
        case source = "Source"
        case routing = "Linear routing"
        case review = "Review"

        public var id: String { rawValue }

        /// "Review of billing-api": the key shows in the title and can't change.
        public func sheetTitle(key: String) -> String {
            "\(rawValue) of \(key)"
        }

        /// The item in the sidebar row's context menu.
        public var menuTitle: String {
            switch self {
            case .source: return "Edit Source…"
            case .routing: return "Edit Linear Routing…"
            case .review: return "Edit Review…"
            }
        }

        /// The Edit… button's help.
        public var help: String {
            switch self {
            case .source: return "Change where the code comes from and the base branch."
            case .routing: return "Change which Linear issues go to this repo, or make it the default repo."
            case .review: return "Change whether merges wait for you, and the built-in ticket patterns."
            }
        }

        /// The sheet's fixed size. At most 520pt tall, so its footer stays on a 1024×768 screen.
        public var sheetSize: CGSize {
            switch self {
            case .source: return CGSize(width: 480, height: 380)
            case .routing: return CGSize(width: 480, height: 420)
            case .review: return CGSize(width: 440, height: 360)
            }
        }
    }

    /// The draft the sheets open with. A local folder repo's draft has no folder picked: Save keeps the entry's
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
            isDefault: entry.isDefault == true,
            manualReview: ManualReviewChoice(override: entry.manualReview),
            ticketPatternsBuiltIn: BuiltInTicketPatternsChoice(override: entry.ticketPatternsBuiltIn)
        )
    }

    /// `original` changed as the draft says, or the first thing that stops it. Only what the sheets edit changes:
    /// the key, the route's team and assignee, `fetch_before_dispatch` and keys the app doesn't know stay. An
    /// unchanged source keeps the entry's workspace and workflow as they are. `default` only moves here: turning it
    /// on takes it from the current default, which `updating` does in the same write. `existing` is the
    /// `repositories:` list now, with `original` in it.
    public static func entry(
        for draft: AddRepoDraft,
        editing original: RepositoryEntry,
        existing: [RepositoryEntry]
    ) -> Result<RepositoryEntry, AddRepoProblem> {
        var entry = original
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
            if !isSourceUnchanged(draft, editing: original) {
                // Symphony reads a managed repo's WORKFLOW.md from its clone, and refuses `repo` or
                // `strategy: clone` next to `source`.
                entry.workflow = nil
                entry.workspace = RepositoryWorkspace(source: gitHub, fetchBeforeDispatch: fetch)
            }
        case .localFolder:
            switch draft.folder {
            case nil:
                if !isSourceUnchanged(draft, editing: original) {
                    return .failure(AddRepoProblem("Choose the folder of a git checkout."))
                }
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

        entry.route = route(of: draft, editing: original)

        if draft.isDefault, original.isDefault != true {
            if let problem = defaultProblem(currentDefault(otherThan: original.key, in: existing)) {
                return .failure(problem)
            }
            entry.isDefault = true
        }

        // Manual review changes only when its checkbox moved, so a value Symphony rejects stays until the box is
        // turned on or off; off removes the key, leaving the repo on the default.
        if draft.manualReview != ManualReviewChoice(override: original.manualReview) {
            entry.manualReview = draft.manualReview.override
        }
        // Same as Settings removes the repo's key.
        entry.ticketPatternsBuiltIn = draft.ticketPatternsBuiltIn.override

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

    /// The route the draft gives `original`: its team and assignee stay, and a route with several projects keeps
    /// them while the first one stays picked.
    static func route(of draft: AddRepoDraft, editing original: RepositoryEntry) -> RepositoryRoute {
        var route = original.route
        let project = draft.project?.trimmingWhitespace() ?? ""
        if project != (original.route.projects?.first ?? "") {
            route.projects = project.isEmpty ? nil : [project]
        }
        let labels = draft.labels.map { $0.trimmingWhitespace() }.filter { !$0.isEmpty }
        if Set(labels) != Set(original.route.labels ?? []) {
            route.labels = labels.isEmpty ? nil : labels
        }
        return route
    }

    /// The Linear routing sheet's preview, as the detail will read once saved: "Issues in Billing with label
    /// backend go to api.", then that it also takes the issues no route matches when it is the default.
    public static func routePreview(for draft: AddRepoDraft, editing original: RepositoryEntry) -> [String] {
        let routing = ReposList.routing(route(of: draft, editing: original), key: original.key, isDefault: draft.isDefault)
        return [routing.sentence] + (routing.defaultLine.map { [$0] } ?? [])
    }

    /// True while the draft still names the entry's own source: the same GitHub repo however it is spelled, or the
    /// entry's folder while no other one is chosen.
    public static func isSourceUnchanged(_ draft: AddRepoDraft, editing original: RepositoryEntry) -> Bool {
        let originalSource = original.workspace.source?.trimmingWhitespace() ?? ""
        switch draft.mode {
        case .gitHub:
            let input = draft.gitHubInput.trimmingWhitespace()
            guard !originalSource.isEmpty, !input.isEmpty else { return false }
            return input == originalSource || GitHubRepoInput.normalize(originalSource) == GitHubRepoInput.normalize(input)
        case .localFolder:
            guard originalSource.isEmpty else { return false }
            guard case let .success(checkout)? = draft.folder else { return draft.folder == nil }
            return checkout.path == original.workspace.repo
        }
    }

    // MARK: Source

    /// The Source sheet's caption: what saving this source does on disk.
    public static func sourceCaption(for draft: AddRepoDraft, editing original: RepositoryEntry) -> String {
        let originalSource = original.workspace.source?.trimmingWhitespace() ?? ""
        let clone = originalSource.isEmpty ? nil : ReposList.gitHubRepo(originalSource)
        let unchanged = isSourceUnchanged(draft, editing: original)
        switch draft.mode {
        case .gitHub:
            if unchanged { return "Symphony keeps its own clone. Your checkouts aren't touched." }
            guard let clone else { return "Symphony makes its own clone on the next start. Your folder stays as it is." }
            return "Symphony makes its own clone of the new repo on the next start. Its clone of \(clone) stays on disk."
        case .localFolder:
            guard !unchanged, case .success? = draft.folder else {
                return "Agents work in worktrees of this checkout. It needs a GitHub origin and a WORKFLOW.md."
            }
            guard let clone else {
                return "Agents work in worktrees of this folder from the next start. Both folders stay as they are."
            }
            return "Agents work in worktrees of this folder from the next start. The folder stays as it is, and "
                + "Symphony's clone of \(clone) stays on disk."
        }
    }

    // MARK: Default repo

    public static let defaultTitle = "Default repo"
    public static let defaultExplanation = "Take the issues no other repo's route matches."

    /// The Linear routing sheet's Default repo checkbox: whether it can be turned on, and the caption under it.
    public struct DefaultOption: Equatable {
        public var isEnabled: Bool
        public var caption: String?

        public init(isEnabled: Bool, caption: String?) {
            self.isEnabled = isEnabled
            self.caption = caption
        }
    }

    /// The checkbox for `original`, `isOn` as the sheet has it. The default only moves by turning it on in another
    /// repo, so the default repo's own checkbox stays on. The caption names the default that loses it.
    public static func defaultOption(editing original: RepositoryEntry, existing: [RepositoryEntry], isOn: Bool) -> DefaultOption {
        if original.isDefault == true {
            return DefaultOption(
                isEnabled: false,
                caption: "\(original.key) is the default repo. To move the default, turn this on in another repo's Linear routing."
            )
        }
        let current = currentDefault(otherThan: original.key, in: existing)
        if let problem = defaultProblem(current) { return DefaultOption(isEnabled: false, caption: problem.message) }
        guard let current else {
            return DefaultOption(isEnabled: true, caption: isOn ? "Saving makes \(original.key) the default repo." : nil)
        }
        return DefaultOption(
            isEnabled: true,
            caption: isOn
                ? "Saving moves the default from \(current.key) to \(original.key)."
                : "\(current.key) is the default repo now."
        )
    }

    /// The repo whose `default: true` moves to `entry` once saved, nil when `entry` doesn't become the default or no
    /// repo was the default.
    public static func previousDefault(from original: RepositoryEntry, to entry: RepositoryEntry, existing: [RepositoryEntry]) -> String? {
        guard entry.isDefault == true, original.isDefault != true else { return nil }
        return currentDefault(otherThan: original.key, in: existing)?.key
    }

    static func currentDefault(otherThan key: String, in entries: [RepositoryEntry]) -> RepositoryEntry? {
        entries.first { $0.isDefault == true && $0.key != key }
    }

    /// Why the default can't move away from `current`: with no route of its own, Symphony would refuse it as a
    /// repo that isn't the default.
    static func defaultProblem(_ current: RepositoryEntry?) -> AddRepoProblem? {
        guard let current, AddRepo.isUnscoped(current.route) else { return nil }
        return AddRepoProblem(
            "\(current.key) has no Linear route of its own, so it stays the default. Give it a project or labels first."
        )
    }

    // MARK: Saving

    /// True when Symphony must restart to use the change: it sets up a repo's source and workflow when it starts,
    /// but reads routes from `symphony.yml` while it runs.
    public static func needsRestart(from original: RepositoryEntry, to entry: RepositoryEntry) -> Bool {
        original.workspace != entry.workspace || original.workflow != entry.workflow || original.baseBranch != entry.baseBranch
    }

    /// `yaml` with the repo `original.key` rewritten to `entry`. When `entry` becomes the default, the current
    /// default loses its `default: true` in the same text, so one write moves it; a current default with no route
    /// keeps it, and nothing changes.
    public static func updating(_ original: RepositoryEntry, to entry: RepositoryEntry, in yaml: String) throws -> String {
        var text = yaml
        if entry.isDefault == true, original.isDefault != true {
            for var current in try RepositoriesConfig.entries(in: yaml) where current.isDefault == true && current.key != original.key {
                if let problem = defaultProblem(current) { throw RepositoriesConfigError.invalidEntry(problem.message) }
                current.isDefault = nil
                text = try RepositoriesConfig.updating(current.key, to: current, in: text)
            }
        }
        return try RepositoriesConfig.updating(original.key, to: entry, in: text)
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

    /// What the window says after saving, for how the change reaches Symphony. `madeDefault` adds that the repo is
    /// now the default, in place of `previousDefault` when there was one.
    public static func savedMessage(
        key: String,
        apply: AddRepoApply?,
        madeDefault: Bool = false,
        previousDefault: String? = nil
    ) -> String {
        var message: String
        switch apply {
        case nil:
            message = "Saved \(key). Symphony reads the change from symphony.yml, so its next poll uses it."
        case .restart?, .askToRestart?:
            message = "Saved \(key). Symphony restarts to apply it."
        case .onNextStart?:
            message = "Saved \(key). Symphony uses it when it starts."
        case .restartManually?:
            message = "Saved \(key). Restart Symphony to apply it."
        }
        if madeDefault {
            message += " \(key) is now the default repo" + (previousDefault.map { " in place of \($0)." } ?? ".")
        }
        return message
    }
}

/// Disconnecting a repo: its entry leaves `repositories:`, and nothing on disk is deleted.
public enum DisconnectRepo {
    public static let buttonTitle = "Disconnect…"
    public static let confirmTitle = "Disconnect"
    public static let newDefaultTitle = "New default"
    /// Why the only repo can't be disconnected, as the button's help and the caption next to it.
    public static let lastRepoProblem = "Symphony needs at least one repo."

    /// Why the repo `key` can't be disconnected, nil when it can.
    public static func problem(key: String, entries: [RepositoryEntry]) -> String? {
        guard entries.contains(where: { $0.key == key }) else {
            return "symphony.yml has no repo `\(key)`. Symphony keeps it until it restarts."
        }
        guard entries.count > 1 else { return lastRepoProblem }
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

    /// What the Disconnect sheet shows for `entry` before the poll adds its clone's state.
    public struct Sheet: Equatable {
        public var key: String
        public var title: String
        public var message: String
        /// The repos that can become the default, nil when `key` isn't the default.
        public var candidates: [String]?
        /// `owner/repo` of a managed repo, whose clone the sheet can delete; nil for a local folder.
        public var gitHub: String?

        public init(entry: RepositoryEntry, entries: [RepositoryEntry]) {
            key = entry.key
            candidates = DisconnectRepo.defaultCandidates(key: entry.key, entries: entries)
            (title, message) = DisconnectRepo.question(for: entry, newDefaultNeeded: candidates != nil)
            let source = entry.workspace.source?.trimmingWhitespace() ?? ""
            gitHub = source.isEmpty ? nil : ReposList.gitHubRepo(source)
        }
    }

    /// The sheet's text on disconnecting `entry`: what happens and what stays on disk.
    public static func question(for entry: RepositoryEntry, newDefaultNeeded: Bool) -> (title: String, message: String) {
        var message = "Symphony stops taking issues for \(entry.key), and its entry and comment leave symphony.yml."
        if let source = entry.workspace.source?.trimmingWhitespace(), !source.isEmpty {
            message += " Symphony's clone of \(ReposList.gitHubRepo(source)) stays on disk unless you delete it too."
        } else if let repo = entry.workspace.repo?.trimmingWhitespace(), !repo.isEmpty {
            message += " The folder \(repo) and its branches stay as they are."
        }
        if newDefaultNeeded {
            message += " \(entry.key) is the default repo: pick the repo that takes the issues no route matches."
        }
        return ("Disconnect \(entry.key)?", message)
    }

    /// The sheet's **Also delete Symphony's clone** checkbox for a managed repo whose clone exists, nil otherwise.
    public struct CloneOption: Equatable {
        public var title: String
        /// The clone to delete, nil while the checkbox is off.
        public var path: String?
        /// Why the checkbox is off, shown under it.
        public var reason: String?

        public var isEnabled: Bool { path != nil }
    }

    /// The checkbox for `repo`, on only while `ManagedClones.removal` allows deleting its clone.
    public static func cloneOption(for repo: RepoDetail) -> CloneOption? {
        guard repo.source.kind == .managed, !repo.source.notCloned, let removal = repo.actions.cloneRemoval else {
            return nil
        }
        let shown = removal.path ?? repo.source.path
        let title = "Also delete Symphony's clone"
            + (shown.map { " (\(($0 as NSString).abbreviatingWithTildeInPath))" } ?? "")
        switch removal {
        case let .allowed(path):
            return CloneOption(title: title, path: path)
        case let .blocked(reason):
            return CloneOption(title: title, reason: reason)
        }
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
