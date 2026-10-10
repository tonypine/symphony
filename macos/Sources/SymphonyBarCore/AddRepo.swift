import Foundation

/// `owner/repo` from what an engineer pastes for a GitHub repo.
public enum GitHubRepoInput {
    /// `owner/repo` from `https://github.com/owner/repo` (a browser URL with more path after it too),
    /// `git@github.com:owner/repo.git`, `ssh://git@github.com/owner/repo.git` or `owner/repo`; nil for anything
    /// else. The names follow GitHub's rules, as Symphony checks `workspace.source`.
    public static func normalize(_ input: String) -> String? {
        var text = input.trimmingWhitespace()
        var isURL = false
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            isURL = true
        }
        let hosts = isURL ? ["github.com/", "www.github.com/"] : ["ssh://git@github.com/", "git@github.com:"]
        var hasHost = false
        for host in hosts where text.lowercased().hasPrefix(host) {
            text.removeFirst(host.count)
            hasHost = true
        }
        // A URL must be on github.com; without a scheme, the text is an SSH remote or `owner/repo`.
        if isURL && !hasHost { return nil }
        if isURL, let end = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = String(text[..<end]) }

        var parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        // A browser URL may go on to a page of the repo, such as `/pulls` or `/tree/main`.
        if isURL, parts.count > 2 { parts = Array(parts.prefix(2)) }
        guard parts.count == 2 else { return nil }
        let owner = parts[0]
        var repo = parts[1]
        if repo.lowercased().hasSuffix(".git") { repo.removeLast(4) }
        guard isOwner(owner), isRepo(repo) else { return nil }
        return "\(owner)/\(repo)"
    }

    /// The repo name of `owner/repo`.
    public static func name(_ ownerRepo: String) -> String {
        ownerRepo.split(separator: "/").last.map(String.init) ?? ownerRepo
    }

    private static func isOwner(_ owner: String) -> Bool {
        guard let first = owner.first, first.isASCII, first.isLetter || first.isNumber, owner.count <= 39 else { return false }
        return owner.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func isRepo(_ repo: String) -> Bool {
        guard (1...100).contains(repo.count), repo != ".", repo != "..", !repo.lowercased().hasSuffix(".git") else { return false }
        return repo.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }
}

/// A local git checkout picked as a repo's source.
public struct LocalCheckout: Equatable {
    /// The checkout's top folder, which may be above the folder that was picked.
    public var path: String
    /// `owner/repo` of its `origin` remote.
    public var gitHub: String
    /// Whether it has a `WORKFLOW.md` at its top.
    public var hasWorkflow: Bool
    /// The branch `origin/HEAD` points at, nil when the checkout doesn't record it.
    public var defaultBranch: String?

    public init(path: String, gitHub: String, hasWorkflow: Bool = true, defaultBranch: String? = nil) {
        self.path = path
        self.gitHub = gitHub
        self.hasWorkflow = hasWorkflow
        self.defaultBranch = defaultBranch
    }

    /// The `WORKFLOW.md` Symphony reads for the repo. Symphony resolves a relative `workflow` against the
    /// folder of `symphony.yml`, so the entry names it in full.
    public var workflowPath: String {
        (path as NSString).appendingPathComponent("WORKFLOW.md")
    }

    /// Runs git with arguments in a folder; returns its exit status and standard output.
    public typealias Git = (_ arguments: [String], _ folder: String) -> (status: Int32, output: String)

    /// Checks that `folder` is in a git checkout whose `origin` is on GitHub, and whether it has a `WORKFLOW.md`.
    public static func inspect(
        _ folder: String,
        git: Git = runGit,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Result<LocalCheckout, AddRepoProblem> {
        let shown = (folder as NSString).abbreviatingWithTildeInPath
        let top = git(["rev-parse", "--show-toplevel"], folder)
        let path = top.output.trimmingWhitespace()
        guard top.status == 0, !path.isEmpty else { return .failure(AddRepoProblem("\(shown) isn't a git checkout.")) }
        let shownTop = (path as NSString).abbreviatingWithTildeInPath

        let origin = git(["remote", "get-url", "origin"], path)
        let url = origin.output.trimmingWhitespace()
        guard origin.status == 0, !url.isEmpty else {
            return .failure(AddRepoProblem("\(shownTop) has no origin remote. Symphony pushes agent branches to a GitHub origin."))
        }
        guard let gitHub = GitHubRepoInput.normalize(url) else {
            return .failure(AddRepoProblem("The origin of \(shownTop) isn't a GitHub repo: \(url)"))
        }
        var checkout = LocalCheckout(path: path, gitHub: gitHub)
        checkout.hasWorkflow = fileExists(checkout.workflowPath)
        let head = git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], path)
        let branch = head.output.trimmingWhitespace()
        if head.status == 0, branch.hasPrefix("origin/"), branch.count > "origin/".count {
            checkout.defaultBranch = String(branch.dropFirst("origin/".count))
        }
        return .success(checkout)
    }

    /// Why the Edit sheet can't move a repo to this checkout: it has no `WORKFLOW.md`.
    public var missingWorkflowProblem: AddRepoProblem {
        AddRepoProblem("\((path as NSString).abbreviatingWithTildeInPath) has no WORKFLOW.md. Add one before connecting the repo.")
    }

    /// Runs `/usr/bin/git -C folder arguments…`, waiting for it to exit.
    public static func runGit(_ arguments: [String], in folder: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder] + arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}

/// Why the Add Repo sheet can't save yet, in words the sheet shows.
public struct AddRepoProblem: Error, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// What the Add Repo sheet has filled in.
public struct AddRepoDraft: Equatable {
    public enum Mode: String, CaseIterable, Equatable {
        case gitHub = "GitHub URL"
        case localFolder = "Local folder"
    }

    public var mode: Mode
    /// What was pasted in GitHub URL mode.
    public var gitHubInput: String
    /// The result of inspecting the folder picked in Local folder mode, nil before one is picked.
    public var folder: Result<LocalCheckout, AddRepoProblem>?
    public var key: String
    public var baseBranch: String
    /// The name of the Linear project picked.
    public var project: String?
    public var labels: [String]
    /// The repo's acceptance gate mode, which only the Edit sheet shows.
    public var acceptanceGate: AcceptanceGateChoice

    public init(
        mode: Mode = .gitHub,
        gitHubInput: String = "",
        folder: Result<LocalCheckout, AddRepoProblem>? = nil,
        key: String = "",
        baseBranch: String = AddRepo.defaultBaseBranch,
        project: String? = nil,
        labels: [String] = [],
        acceptanceGate: AcceptanceGateChoice = .inherit
    ) {
        self.mode = mode
        self.gitHubInput = gitHubInput
        self.folder = folder
        self.key = key
        self.baseBranch = baseBranch
        self.project = project
        self.labels = labels
        self.acceptanceGate = acceptanceGate
    }

    /// `owner/repo` of the source the draft names, nil while it names none.
    public var gitHub: String? {
        switch mode {
        case .gitHub:
            return GitHubRepoInput.normalize(gitHubInput)
        case .localFolder:
            guard case let .success(checkout)? = folder else { return nil }
            return checkout.gitHub
        }
    }
}

/// How a saved repo reaches the running Symphony. Symphony reads new routes from `symphony.yml` while it runs,
/// but sets up a repo's workflow and Symphony's own clone only when it starts.
public enum AddRepoApply: Equatable {
    /// The app's Symphony runs no agent: restart it now.
    case restart
    /// The app's Symphony runs agents: ask before a restart that waits for them.
    case askToRestart(runs: Int)
    /// Symphony isn't running; it reads the repo when it starts.
    case onNextStart
    /// Symphony runs but the app can't restart it now: the app didn't start it, or it is still starting.
    case restartManually
}

/// The Add Repo sheet's checks and the entry it writes, kept free of SwiftUI so they can be unit tested.
public enum AddRepo {
    public static let defaultBaseBranch = "main"
    public static let buttonTitle = "Add Repo…"
    public static let sheetTitle = "Add Repo"

    /// A key for the repo `name` that no repo in `existing` uses: the name in lower case with characters a key
    /// can't hold replaced by `-`, then `-2`, `-3`… until it is free.
    public static func suggestedKey(for name: String, existing: [String]) -> String {
        var base = String(name.lowercased().map { isKeyCharacter($0) ? $0 : "-" })
        while let first = base.first, !(first.isLetter || first.isNumber) { base.removeFirst() }
        if base.isEmpty { base = "repo" }
        var key = base
        var number = 2
        while keyProblem(key, existing: existing) != nil {
            key = "\(base)-\(number)"
            number += 1
        }
        return key
    }

    /// Why `key` can't name a new repo, nil when it can. Symphony names each repo's workspaces after its key with
    /// other characters replaced by `_`, so two keys that only differ there collide.
    public static func keyProblem(_ key: String, existing: [String]) -> AddRepoProblem? {
        let key = key.trimmingWhitespace()
        guard !key.isEmpty else { return AddRepoProblem("Enter a repo key.") }
        guard let first = key.first, first.isLetter || first.isNumber, key.allSatisfy(isKeyCharacter) else {
            return AddRepoProblem("A repo key starts with a letter or digit and holds only letters, digits, `.`, `_` and `-`.")
        }
        // Compared without case too, as macOS folder names are.
        if existing.contains(where: { workspaceName($0).lowercased() == key.lowercased() }) {
            return AddRepoProblem("A repo with key `\(key)` already exists.")
        }
        return nil
    }

    /// The entry the draft adds, or the first thing that stops it. `existing` is the `repositories:` list now.
    public static func entry(for draft: AddRepoDraft, existing: [RepositoryEntry]) -> Result<RepositoryEntry, AddRepoProblem> {
        var workflow: String?
        var workspace = RepositoryWorkspace()
        switch draft.mode {
        case .gitHub:
            let input = draft.gitHubInput.trimmingWhitespace()
            guard !input.isEmpty else { return .failure(AddRepoProblem("Paste a GitHub repo URL or owner/repo.")) }
            guard let gitHub = GitHubRepoInput.normalize(input) else {
                return .failure(AddRepoProblem(
                    "Use a GitHub repo as https://github.com/owner/repo, git@github.com:owner/repo.git or owner/repo."
                ))
            }
            workspace.source = gitHub
        case .localFolder:
            switch draft.folder {
            case nil:
                return .failure(AddRepoProblem("Choose the folder of a git checkout."))
            case let .failure(problem)?:
                return .failure(problem)
            case let .success(checkout)?:
                workflow = checkout.workflowPath
                workspace.strategy = "worktree"
                workspace.repo = checkout.path
            }
        }

        let key = draft.key.trimmingWhitespace()
        if let problem = keyProblem(key, existing: existing.map(\.key)) { return .failure(problem) }
        let baseBranch = draft.baseBranch.trimmingWhitespace()
        guard !baseBranch.isEmpty else { return .failure(AddRepoProblem("Enter a base branch, such as main.")) }
        guard let project = draft.project?.trimmingWhitespace(), !project.isEmpty else {
            return .failure(AddRepoProblem("Pick the Linear project whose issues go to this repo."))
        }
        let labels = draft.labels.map { $0.trimmingWhitespace() }.filter { !$0.isEmpty }
        let route = RepositoryRoute(projects: [project], labels: labels.isEmpty ? nil : labels)
        if let twin = existing.first(where: { sameRoute($0.route, route) }) {
            return .failure(AddRepoProblem(
                "`\(twin.key)` already takes the issues of this project and labels. Pick other labels or another project."
            ))
        }
        return .success(RepositoryEntry(key: key, baseBranch: baseBranch, workflow: workflow, route: route, workspace: workspace))
    }

    /// `yaml` with `entry` added. When the file has one repo and it has no route and isn't the default, it becomes
    /// the default, so it keeps the issues no other route takes: Symphony refuses two repos where one has no route.
    /// Returns the key of the repo made the default, if any.
    public static func adding(_ entry: RepositoryEntry, to yaml: String) throws -> (text: String, madeDefault: String?) {
        let existing = try RepositoriesConfig.entries(in: yaml)
        var text = yaml
        var madeDefault: String?
        if existing.count == 1, var only = existing.first, isUnscoped(only.route), only.isDefault != true {
            only.isDefault = true
            text = try RepositoriesConfig.updating(only.key, to: only, in: text)
            madeDefault = only.key
        }
        return (try RepositoriesConfig.adding(entry, to: text), madeDefault)
    }

    /// How the saved repo reaches Symphony, from its status now.
    public static func apply(status: SymphonyStatus) -> AddRepoApply {
        switch status {
        case let .running(snapshot, external), let .paused(snapshot, external):
            if external { return .restartManually }
            return snapshot.running > 0 ? .askToRestart(runs: snapshot.running) : .restart
        case .starting:
            return .restartManually
        case .stopped, .error:
            return .onNextStart
        }
    }

    /// The alert asking before a restart that waits for `runs` agent runs.
    public static func restartQuestion(key: String, runs: Int) -> (title: String, message: String) {
        (
            "Restart Symphony to connect \(key)?",
            "\(activeRuns(runs)) Restart pauses dispatch, waits for them to finish, then starts Symphony again, "
                + "which sets up \(key) and, for a GitHub URL, clones it."
        )
    }

    /// "1 agent run is active." or "3 agent runs are active."
    static func activeRuns(_ runs: Int) -> String {
        "\(runs) \(runs == 1 ? "agent run is" : "agent runs are") active."
    }

    /// What the sheet says after saving, for how the repo reaches Symphony.
    public static func savedMessage(key: String, apply: AddRepoApply, madeDefault: String?, workflow: PendingWorkflow? = nil) -> String {
        var message: String
        switch apply {
        case .restart, .askToRestart:
            message = "Added \(key). Symphony restarts to connect it."
        case .onNextStart:
            message = "Added \(key). Symphony connects it when it starts."
        case .restartManually:
            message = "Added \(key). Restart Symphony to connect it."
        }
        if let madeDefault { message += " \(madeDefault) is now the default repo, so it keeps the issues no route matches." }
        if let workflow { message += " " + workflow.savedSentence }
        return message
    }

    // MARK: Helpers

    private static func isKeyCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "._-".contains(character))
    }

    /// The folder name Symphony makes from a key.
    private static func workspaceName(_ key: String) -> String {
        String(key.map { isKeyCharacter($0) ? $0 : "_" })
    }

    static func isUnscoped(_ route: RepositoryRoute) -> Bool {
        (route.team?.trimmingWhitespace() ?? "").isEmpty && (route.projects ?? []).isEmpty
            && (route.labels ?? []).isEmpty && (route.assignee?.trimmingWhitespace() ?? "").isEmpty
    }

    static func sameRoute(_ left: RepositoryRoute, _ right: RepositoryRoute) -> Bool {
        func text(_ value: String?) -> String { value?.trimmingWhitespace() ?? "" }
        func set(_ values: [String]?) -> Set<String> { Set((values ?? []).map { $0.trimmingWhitespace() }) }
        return text(left.team) == text(right.team) && set(left.projects) == set(right.projects)
            && set(left.labels) == set(right.labels) && text(left.assignee) == text(right.assignee)
    }
}

/// Adds a repo to a `symphony.yml` on disk. Writes atomically, and leaves the file untouched when it throws.
extension SymphonyConfigFile {
    /// Returns the key of the repo made the default, if any: see `AddRepo.adding`.
    @discardableResult
    public func connectRepository(_ entry: RepositoryEntry) throws -> String? {
        var madeDefault: String?
        try rewrite { text in
            let result = try AddRepo.adding(entry, to: text)
            madeDefault = result.madeDefault
            return result.text
        }
        return madeDefault
    }
}
