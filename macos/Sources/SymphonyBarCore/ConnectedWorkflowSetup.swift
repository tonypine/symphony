import Foundation

/// A `WORKFLOW.md` for a repo that is already connected but has none, set up from its Needs attention row on the same
/// page as Add Repo's step. It reads the repo, drafts the file and lands it as Add Repo does; `symphony.yml` is left
/// as it is.
public struct ConnectedWorkflowSetup: Equatable {
    public static let buttonTitle = "Set Up WORKFLOW.md…"
    public static let createTitle = "Create"

    /// The repo's key in `symphony.yml`, which the pending store keeps the file under.
    public var key: String
    /// `owner/repo`.
    public var gitHub: String
    /// The base branch `symphony.yml` names, nil for the repo's default branch.
    public var baseBranch: String?
    /// The local folder the repo's code comes from, nil for a managed repo, which is read on GitHub.
    public var checkout: String?

    public init(key: String, gitHub: String, baseBranch: String? = nil, checkout: String? = nil) {
        self.key = key
        self.gitHub = gitHub
        let branch = baseBranch?.trimmingWhitespace() ?? ""
        self.baseBranch = branch.isEmpty ? nil : branch
        let folder = checkout?.trimmingWhitespace() ?? ""
        self.checkout = folder.isEmpty ? nil : folder
    }

    /// The set-up of `repo` as Symphony reports it; nil without its `owner/repo`, which the draft and the pull request
    /// need.
    public static func of(_ repo: RepoStatus) -> ConnectedWorkflowSetup? {
        let gitHub: String?
        let checkout: String?
        switch repo.source {
        case let .local(path):
            gitHub = repo.github
            checkout = path
        case let .managed(github, _, _):
            gitHub = repo.github ?? github
            checkout = nil
        }
        guard let gitHub = gitHub?.trimmingWhitespace(), !gitHub.isEmpty else { return nil }
        return ConnectedWorkflowSetup(key: repo.key, gitHub: gitHub, baseBranch: repo.baseBranch, checkout: checkout)
    }

    public var sheetTitle: String {
        "Set Up WORKFLOW.md for \(key)"
    }

    /// `owner/repo`, or the local folder, the page talks about.
    public var source: String {
        checkout.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? gitHub
    }

    /// How the file can land: a pull request first, and for a local folder the file in the checkout. Not creating one
    /// is Cancel.
    public var choices: [WorkflowLanding] {
        WorkflowLanding.choices(for: checkout == nil ? .gitHub : .localFolder).filter { $0 != .skip }
    }

    /// What reading the repo found, for the page.
    public struct Found: Equatable {
        public var stack: WorkflowStack
        /// The branch the file is drafted for and lands on.
        public var baseBranch: String
        /// The local folder's checkout, nil for a managed repo.
        public var checkout: LocalCheckout?

        public init(stack: WorkflowStack, baseBranch: String, checkout: LocalCheckout? = nil) {
            self.stack = stack
            self.baseBranch = baseBranch
            self.checkout = checkout
        }

        /// The page's first line, as Add Repo's step words it.
        public func message(source: String) -> String {
            WorkflowCheck.missing(stack, branch: baseBranch).missingMessage(source: source) ?? ""
        }
    }

    /// Reads the repo to draft from: the working tree of a local folder, or the base branch on GitHub through `cli`.
    /// Runs git or `gh`, so call it off the main thread.
    public func read(
        cli: GitHubCLI?,
        inspect: (String) -> Result<LocalCheckout, AddRepoProblem> = { LocalCheckout.inspect($0) },
        files: (String) -> RepoFiles = RepoFiles.checkout
    ) -> Result<Found, AddRepoProblem> {
        if let checkout {
            return inspect(checkout).map { found in
                Found(
                    stack: WorkflowTemplate.detect(files(found.path)),
                    baseBranch: baseBranch ?? found.defaultBranch ?? AddRepo.defaultBaseBranch,
                    checkout: found
                )
            }
        }
        guard let cli else { return .failure(AddRepoProblem(GitHubCLI.missingMessage)) }
        return cli.probe(gitHub, branch: baseBranch).flatMap { probe in
            guard !probe.hasWorkflow else {
                return .failure(AddRepoProblem(
                    "\(gitHub) has a WORKFLOW.md on \(probe.branch) now. Symphony reads it before the next dispatch."
                ))
            }
            return .success(Found(stack: probe.stack, baseBranch: probe.branch))
        }
    }

    /// The draft the page opens with.
    public func draft(_ found: Found) -> String {
        WorkflowTemplate.render(found.stack, gitHub: gitHub, baseBranch: found.baseBranch)
    }

    /// Adds `text` as the repo's `WORKFLOW.md` the way `landing` says, as Add Repo does: a failed pull request leaves
    /// no branch behind. Runs `gh` or writes a file, so call it off the main thread.
    public func create(
        _ text: String,
        landing: WorkflowLanding,
        found: Found,
        cli: GitHubCLI?
    ) -> Result<PendingWorkflow, AddRepoProblem> {
        let text = text.hasSuffix("\n") ? text : text + "\n"
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(AddRepoProblem("The WORKFLOW.md draft is empty. Write one, or press Cancel."))
        }
        return landing.land(
            text,
            gitHub: gitHub,
            baseBranch: found.baseBranch,
            summary: found.stack.summary,
            checkout: found.checkout,
            cli: cli
        ) ?? .failure(AddRepoProblem("Pick how to add the WORKFLOW.md."))
    }

    /// The banner once Create added the file.
    public func createdMessage(_ pending: PendingWorkflow) -> String {
        switch pending {
        case let .pullRequest(url):
            return "Opened \(url) to add the WORKFLOW.md of \(key)."
        case let .localFile(path):
            return "Wrote \((path as NSString).abbreviatingWithTildeInPath) for \(key); commit and push it to the base branch."
        }
    }
}
