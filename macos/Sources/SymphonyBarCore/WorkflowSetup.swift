import Foundation

/// How the Add Repo sheet adds the `WORKFLOW.md` it drafted. Symphony never writes one without this pick.
public enum WorkflowLanding: String, CaseIterable, Equatable {
    case pullRequest = "Open a pull request"
    case localFile = "Write it into the checkout"
    case skip = "Don't create one now"

    /// What the sheet offers for a source: only a local folder has a checkout to write into.
    public static func choices(for mode: AddRepoDraft.Mode) -> [WorkflowLanding] {
        mode == .localFolder ? [.pullRequest, .localFile, .skip] : [.pullRequest, .skip]
    }

    /// The line under the picker.
    public func help(baseBranch: String) -> String {
        switch self {
        case .pullRequest:
            return "Symphony opens a pull request against \(baseBranch) that adds the file, so it goes through review. "
                + "Agents start on the repo once it merges."
        case .localFile:
            return "Symphony writes the file into the checkout and leaves it uncommitted. "
                + "Commit and push it to \(baseBranch): Symphony reads WORKFLOW.md from there."
        case .skip:
            return "The repo shows WORKFLOW.md as missing, and Symphony runs no agent on it, until one is added."
        }
    }
}

extension WorkflowLanding {
    /// Adds `text` as the repo's `WORKFLOW.md` this way: a pull request against `baseBranch` of `gitHub` through `cli`,
    /// or the file in `checkout`. Nil for `skip`, which adds nothing.
    public func land(
        _ text: String,
        gitHub: String,
        baseBranch: String,
        summary: String,
        checkout: LocalCheckout?,
        cli: GitHubCLI?
    ) -> Result<PendingWorkflow, AddRepoProblem>? {
        switch self {
        case .pullRequest:
            guard let cli else { return .failure(AddRepoProblem(GitHubCLI.missingMessage)) }
            return cli.openWorkflowPullRequest(gitHub, baseBranch: baseBranch, text: text, summary: summary)
        case .localFile:
            guard let checkout else { return .failure(AddRepoProblem("Choose the folder of a git checkout.")) }
            return checkout.writeWorkflow(text)
        case .skip:
            return nil
        }
    }
}

/// What the sheet knows about a repo's `WORKFLOW.md` before it is connected.
public enum WorkflowCheck: Equatable {
    /// No source is picked yet, or the sheet edits a connected repo.
    case idle
    case checking
    /// The repo has one, so the sheet skips the step.
    case present
    /// The repo has none on `branch`: the sheet offers a draft for the stack it found.
    case missing(WorkflowStack, branch: String?)
    /// The repo couldn't be checked; Save connects it without the step.
    case failed(String)

    /// What the step says about the file: that `source` (`owner/repo` or a folder) has none.
    public func missingMessage(source: String) -> String? {
        guard case let .missing(_, branch) = self else { return nil }
        let place = branch.map { "\(source) has no WORKFLOW.md on \($0)." } ?? "\(source) has no WORKFLOW.md."
        return place + " Symphony runs no agent on a repo without one, so the sheet drafted one from its files."
    }
}

/// A `WORKFLOW.md` the sheet added that Symphony can't read yet, for the Repos list.
public enum PendingWorkflow: Equatable {
    /// A pull request that adds the file, until it merges.
    case pullRequest(url: String)
    /// The file written into a local checkout, until it is pushed to the base branch.
    case localFile(path: String)

    /// The Repos list's `WORKFLOW.md` field while Symphony doesn't report the file valid.
    public var field: RepoField {
        switch self {
        case let .pullRequest(url):
            return RepoField(ReposList.workflowLabel, "pending: pull request open", detail: url)
        case let .localFile(path):
            return RepoField(
                ReposList.workflowLabel,
                "pending: written, not pushed",
                detail: "\((path as NSString).abbreviatingWithTildeInPath): commit and push it to the base branch."
            )
        }
    }

    /// What the sheet's Save message adds.
    public var savedSentence: String {
        switch self {
        case let .pullRequest(url):
            return "Opened \(url) to add its WORKFLOW.md."
        case let .localFile(path):
            return "Wrote \((path as NSString).abbreviatingWithTildeInPath); commit and push it to the base branch."
        }
    }
}

/// The `WORKFLOW.md` files the sheet added, by repo key, kept in UserDefaults until Symphony reads them.
public final class PendingWorkflowStore {
    public static let key = "pendingWorkflows"

    private let defaults: KeyValueStore

    public init(defaults: KeyValueStore = UserDefaults.standard) {
        self.defaults = defaults
    }

    public func record(_ pending: PendingWorkflow, for repo: String) {
        var stored = storedEntries
        switch pending {
        case let .pullRequest(url):
            stored[repo] = ["pullRequest": url]
        case let .localFile(path):
            stored[repo] = ["localFile": path]
        }
        defaults.set(stored, forKey: Self.key)
    }

    /// Every entry that can be read, by repo key.
    public var all: [String: PendingWorkflow] {
        storedEntries.compactMapValues { value in
            guard let value = value as? [String: String] else { return nil }
            if let url = value["pullRequest"] { return .pullRequest(url: url) }
            return value["localFile"].map { .localFile(path: $0) }
        }
    }

    /// Forgets `repo`'s entry, as once Symphony reads its file or the repo is disconnected.
    public func clear(_ repo: String) {
        var stored = storedEntries
        guard stored.removeValue(forKey: repo) != nil else { return }
        defaults.set(stored.isEmpty ? nil : stored, forKey: Self.key)
    }

    private var storedEntries: [String: Any] {
        defaults.object(forKey: Self.key) as? [String: Any] ?? [:]
    }
}

extension ReposList {
    /// `display` with the `WORKFLOW.md` field of each repo in `pending` saying so, unless Symphony reads the file.
    public static func withPendingWorkflows(_ display: ReposDisplay, pending: [String: PendingWorkflow]) -> ReposDisplay {
        var display = display
        for index in display.rows.indices {
            guard let pending = pending[display.rows[index].key] else { continue }
            display.rows[index].fields = display.rows[index].fields.map { field in
                field.label == workflowLabel && field.value != validWorkflow ? pending.field : field
            }
        }
        return display
    }

    /// The keys of the repos whose `WORKFLOW.md` Symphony reports valid, whose pending entries are done.
    public static func validWorkflows(_ poll: ReposPoll?) -> [String] {
        guard case let .repos(repos, _)? = poll else { return [] }
        return repos.filter { $0.workflow.state == .valid }.map(\.key)
    }
}

/// Writes the drafted `WORKFLOW.md` into a local checkout, uncommitted.
extension LocalCheckout {
    public func writeWorkflow(_ text: String) -> Result<PendingWorkflow, AddRepoProblem> {
        let shown = (workflowPath as NSString).abbreviatingWithTildeInPath
        guard !FileManager.default.fileExists(atPath: workflowPath) else {
            return .failure(AddRepoProblem("\(shown) already exists, so Symphony left it as it is."))
        }
        do {
            try text.write(toFile: workflowPath, atomically: true, encoding: .utf8)
            return .success(.localFile(path: workflowPath))
        } catch {
            return .failure(AddRepoProblem("Couldn't write \(shown): \(error.localizedDescription)"))
        }
    }
}

/// The GitHub CLI, `gh`, with the login the engineer made with `gh auth login`. The sheet reads a repo's files and
/// opens the pull request through GitHub's API with it, so no checkout of the repo is touched.
public struct GitHubCLI {
    /// Runs `gh` with arguments; returns its exit status, standard output and standard error.
    public typealias Run = (_ arguments: [String]) -> (status: Int32, output: String, error: String)

    /// Names the `gh` to run instead of the one on PATH, as QA passes do with a fake.
    public static let environmentKey = "SYMPHONY_BAR_GH"
    public static let missingMessage = "Couldn't find the GitHub CLI (gh) to check the repo for a WORKFLOW.md. "
        + "Install it with `brew install gh`, then run `gh auth login`."
    /// The branch the pull request adds `WORKFLOW.md` on, with `-2`, `-3`… when it is taken.
    public static let branch = "symphony/add-workflow"
    public static let pullRequestTitle = "Add WORKFLOW.md for Symphony"

    public let run: Run

    public init(run: @escaping Run) {
        self.run = run
    }

    /// The `gh` at `environmentKey`, else the first on PATH or in the Homebrew folders a Finder-launched app can't
    /// see on its PATH.
    public static func locate(
        environment: [String: String],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let path = environment[environmentKey]?.trimmingWhitespace(), !path.isEmpty {
            return isExecutable(path) ? path : nil
        }
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + ChildLaunch.fallbackPathDirectories
        return folders.map { ($0 as NSString).appendingPathComponent("gh") }.first(where: isExecutable)
    }

    /// Runs the `gh` at `executable`, waiting for it to exit.
    public static func process(_ executable: String) -> GitHubCLI {
        GitHubCLI { arguments in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            // gh asks nothing and prints no color when it isn't run from a terminal; say so anyway.
            environment["GH_PROMPT_DISABLED"] = "1"
            environment["NO_COLOR"] = "1"
            process.environment = environment
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            do {
                try process.run()
            } catch {
                return (-1, "", "Couldn't run \(executable): \(error.localizedDescription)")
            }
            // Read standard error alongside, so neither pipe fills up and blocks gh.
            var errorData = Data()
            let errorRead = DispatchGroup()
            errorRead.enter()
            DispatchQueue.global(qos: .utility).async {
                errorData = error.fileHandleForReading.readDataToEndOfFile()
                errorRead.leave()
            }
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            errorRead.wait()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: outputData, as: UTF8.self), String(decoding: errorData, as: UTF8.self))
        }
    }

    /// What the sheet learned from GitHub about a repo.
    public struct Probe: Equatable {
        public var defaultBranch: String
        /// The branch that was looked at: `branch` when one was asked for, else the default branch.
        public var branch: String
        public var hasWorkflow: Bool
        public var stack: WorkflowStack
    }

    /// Looks for `WORKFLOW.md` at the top of `branch` (the repo's default branch when nil) and guesses the stack from
    /// the files there.
    public func probe(_ repo: String, branch: String?) -> Result<Probe, AddRepoProblem> {
        let info = run(["api", "repos/\(repo)", "--jq", ".default_branch"])
        guard info.status == 0 else { return .failure(problem("Couldn't check \(repo) on GitHub", info)) }
        let defaultBranch = info.output.trimmingWhitespace()
        let asked = branch?.trimmingWhitespace() ?? ""
        let branch = asked.isEmpty ? defaultBranch : asked

        let listing = run(["api", contentsPath(repo, "", branch: branch), "--jq", ".[].name"])
        guard listing.status == 0 else {
            return .failure(problem("Couldn't list the files on \(branch) of \(repo)", listing))
        }
        let names = Set(listing.output.split(separator: "\n").map { String($0).trimmingWhitespace() }.filter { !$0.isEmpty })
        let files = RepoFiles(names: names) { path in
            let file = self.run(["api", self.contentsPath(repo, path, branch: branch), "-H", "Accept: application/vnd.github.raw"])
            return file.status == 0 ? file.output : nil
        }
        return .success(Probe(
            defaultBranch: defaultBranch,
            branch: branch,
            hasWorkflow: names.contains(WorkflowTemplate.fileName),
            stack: WorkflowTemplate.detect(files)
        ))
    }

    /// Opens a pull request against `baseBranch` of `repo` that adds `WORKFLOW.md` with `text`, on a new branch made
    /// through the API. Returns the pull request's URL. When the commit or the pull request fails, the branch is
    /// deleted again.
    public func openWorkflowPullRequest(
        _ repo: String,
        baseBranch: String,
        text: String,
        summary: String
    ) -> Result<PendingWorkflow, AddRepoProblem> {
        let base = run(["api", "repos/\(repo)/git/ref/heads/\(encoded(baseBranch))", "--jq", ".object.sha"])
        let sha = base.output.trimmingWhitespace()
        guard base.status == 0, !sha.isEmpty else {
            return .failure(problem("Couldn't read \(baseBranch) of \(repo)", base))
        }

        var branch: String?
        for attempt in 1...5 {
            let name = attempt == 1 ? Self.branch : "\(Self.branch)-\(attempt)"
            let created = run(["api", "-X", "POST", "repos/\(repo)/git/refs", "-f", "ref=refs/heads/\(name)", "-f", "sha=\(sha)"])
            if created.status == 0 {
                branch = name
                break
            }
            guard (created.error + created.output).contains("Reference already exists") else {
                return .failure(problem("Couldn't make the branch \(name) on \(repo)", created))
            }
        }
        guard let branch else {
            return .failure(AddRepoProblem("\(repo) already has branches \(Self.branch) to \(Self.branch)-5. Delete the old ones first."))
        }

        let commit = run([
            "api", "-X", "PUT", "repos/\(repo)/contents/\(WorkflowTemplate.fileName)",
            "-f", "message=\(Self.pullRequestTitle)",
            "-f", "content=\(Data(text.utf8).base64EncodedString())",
            "-f", "branch=\(branch)",
        ])
        guard commit.status == 0 else {
            return .failure(removing(branch, of: repo, after: problem("Couldn't commit WORKFLOW.md to \(branch) of \(repo)", commit)))
        }

        let body = """
            Symphony's Add Repo sheet drafted this `WORKFLOW.md` from the files at the repo's top (\(summary)), and it \
            was reviewed there before this pull request was opened.

            Symphony reads `WORKFLOW.md` from `\(baseBranch)`: once this merges, it runs agents on the issues routed to \
            this repo. Agents can't change the file themselves.
            """
        let pullRequest = run([
            "pr", "create", "--repo", repo, "--base", baseBranch, "--head", branch,
            "--title", Self.pullRequestTitle, "--body", body,
        ])
        let url = pullRequest.output.split(separator: "\n").map { String($0).trimmingWhitespace() }.last { $0.hasPrefix("https://") }
        guard pullRequest.status == 0, let url else {
            return .failure(removing(branch, of: repo, after: problem("Couldn't open the pull request from \(branch) of \(repo)", pullRequest)))
        }
        return .success(.pullRequest(url: url))
    }

    /// Deletes `branch`, which a failed `openWorkflowPullRequest` made, so trying again starts clean rather than
    /// leaving it behind and making the next one. Returns `failure`, saying so when the branch is left.
    private func removing(_ branch: String, of repo: String, after failure: AddRepoProblem) -> AddRepoProblem {
        let deleted = run(["api", "-X", "DELETE", "repos/\(repo)/git/refs/heads/\(encoded(branch))"])
        guard deleted.status != 0 else { return failure }
        return AddRepoProblem("\(failure.message)\nThe branch \(branch) is still on \(repo); delete it on GitHub.")
    }

    private func contentsPath(_ repo: String, _ path: String, branch: String) -> String {
        "repos/\(repo)/contents\(path.isEmpty ? "" : "/" + path)?ref=\(encoded(branch))"
    }

    private func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?&#="))) ?? text
    }

    /// `prefix` with what gh said: the first line of its error, or a hint to log in.
    private func problem(_ prefix: String, _ result: (status: Int32, output: String, error: String)) -> AddRepoProblem {
        let error = result.error.trimmingWhitespace()
        if error.contains("gh auth login") {
            return AddRepoProblem("\(prefix): gh isn't logged in to GitHub. Run `gh auth login`, then try again.")
        }
        let line = error.split(separator: "\n").first.map(String.init) ?? "gh exited with status \(result.status)"
        return AddRepoProblem("\(prefix): \(line)")
    }
}
