import Foundation

/// A repo's health in the Repos window: the sidebar glyph, the header line and the Needs attention box.
public struct RepoHealth: Equatable {
    public enum Status: Equatable {
        case healthy
        case needsAttention
        case notWorking
        /// Symphony isn't answering with the repos, so nothing was checked.
        case notChecked

        /// What VoiceOver reads for the glyph.
        public var spoken: String {
            switch self {
            case .healthy: return "healthy"
            case .needsAttention: return "needs attention"
            case .notWorking: return "not working"
            case .notChecked: return "not checked"
            }
        }
    }

    public enum Severity: Equatable {
        case error
        case warning
        /// Shown in the box, but not a problem: it doesn't change the status or the count.
        case info
    }

    /// A button that fixes a problem, or helps to.
    public enum Fix: Equatable {
        /// The local file, or the file on GitHub at the base branch.
        case openWorkflow(URL)
        case viewPullRequest(URL)
        case revealInFinder(path: String)
        case copyError(String)
        case openOnGitHub(URL)
        /// Asks first, then `POST /api/v1/control/stop` with the issue identifier.
        case stopRun(issueIdentifier: String)
        case openInLinear(URL)
        case revealWorktree(path: String)

        public var title: String {
            switch self {
            case .openWorkflow: return "Open WORKFLOW.md"
            case .viewPullRequest: return "View Pull Request"
            case .revealInFinder: return ReposList.revealTitle
            case .copyError: return "Copy Error"
            case .openOnGitHub: return ReposList.openOnGitHubTitle
            case .stopRun: return RepoHealth.stopRunTitle
            case .openInLinear: return "Open in Linear"
            case .revealWorktree: return ReposList.revealWorktreeTitle
            }
        }
    }

    /// One line of the Needs attention box.
    public struct Problem: Equatable, Identifiable {
        /// Stable across polls, so a line keeps its place and its Stop Run failure.
        public var id: String
        public var severity: Severity
        public var title: String
        /// Symphony's error, shown selectable.
        public var detail: String?
        /// What happens next, for example "Symphony tries again before the next dispatch."
        public var note: String?
        public var fixes: [Fix]

        public init(id: String, severity: Severity, title: String, detail: String? = nil, note: String? = nil, fixes: [Fix] = []) {
            self.id = id
            self.severity = severity
            self.title = title
            self.detail = detail
            self.note = note
            self.fixes = fixes
        }
    }

    public static let stopRunTitle = "Stop Run…"
    public static let boxTitle = "Needs attention"
    /// A run with no activity for this long is stuck: Symphony's own stall timeout (5 minutes by default) should
    /// have restarted it.
    public static let stuckAfter: TimeInterval = 10 * 60
    public static let fetchRetryNote = "Symphony tries again before the next dispatch."

    public var status: Status
    /// The box's lines, errors first, then warnings, then information.
    public var problems: [Problem]
    /// Why nothing was checked, for example "Symphony is stopped".
    public var notCheckedReason: String?

    public init(status: Status, problems: [Problem] = [], notCheckedReason: String? = nil) {
        self.status = status
        self.problems = problems
        self.notCheckedReason = notCheckedReason
    }

    /// Nothing checked, with why.
    public static func notChecked(_ reason: String) -> RepoHealth {
        RepoHealth(status: .notChecked, notCheckedReason: reason)
    }

    /// Errors and warnings, without the information lines.
    public var problemCount: Int {
        problems.filter { $0.severity != .info }.count
    }

    /// The box shows while there is a problem, with the information lines under it.
    public var showsBox: Bool {
        problemCount > 0
    }

    /// The header line: "Healthy", "1 problem", "2 problems", "Not checked: Symphony is stopped".
    public var summary: String {
        switch status {
        case .notChecked:
            return notCheckedReason.map { "Not checked: \($0)" } ?? "Not checked"
        case .healthy:
            return "Healthy"
        case .needsAttention, .notWorking:
            let count = problemCount
            return count == 1 ? "1 problem" : "\(count) problems"
        }
    }

    /// The question Stop Run… asks first.
    public static func stopQuestion(issueIdentifier: String) -> (title: String, message: String) {
        (
            "Stop the run on \(issueIdentifier)?",
            "Symphony stops the agent now. The issue stays where it is in Linear, and Symphony may start it again on a "
                + "later poll."
        )
    }

    public static let stopConfirmTitle = "Stop Run"

    /// What the window says once the stop went through.
    public static func stoppedMessage(issueIdentifier: String) -> String {
        "Stopped the run on \(issueIdentifier)."
    }

    /// Why nothing is checked while the repos come from `symphony.yml`.
    public static func notChecked(status: SymphonyStatus, poll: ReposPoll?) -> RepoHealth {
        switch status {
        case .stopped:
            return notChecked("Symphony is stopped")
        case .starting:
            return notChecked("Symphony is starting")
        case .error:
            return notChecked("Symphony isn't answering")
        case .running, .paused:
            switch poll {
            case .unsupported?:
                return notChecked("Symphony is too old to report it")
            case .failed?:
                return notChecked("Symphony couldn't list the repos")
            case .unreachable?:
                return notChecked("Symphony isn't answering")
            case .repos?, nil:
                return notChecked("asking Symphony")
            }
        }
    }

    /// The health of `repo` as a running Symphony reports it. `warning` is set when Symphony listed the repos
    /// without their running agents; `runs` are the running entries of `/api/v1/state`.
    public static func of(
        _ repo: RepoStatus,
        warning: String?,
        runs: [StateSnapshot.Run],
        pending: PendingWorkflow?,
        now: Date
    ) -> RepoHealth {
        var problems: [Problem] = []
        if let workflow = workflowProblem(repo, pending: pending) { problems.append(workflow) }
        if let fetch = repo.lastFetch, !fetch.succeeded { problems.append(fetchProblem(fetch, repo: repo, now: now)) }
        problems += repo.worktrees.compactMap { stuckProblem($0, runs: runs, now: now) }
        if let warning {
            problems.append(Problem(id: "agents", severity: .info, title: "Symphony couldn't list its running agents", detail: warning))
        }
        if case .managed(_, _, false) = repo.source {
            problems.append(Problem(id: "clone", severity: .info, title: ReposList.notClonedLine))
        }
        // Filtered per severity rather than sorted, so lines of the same severity keep their order.
        problems = [Severity.error, .warning, .info].flatMap { severity in problems.filter { $0.severity == severity } }

        let status: Status
        if problems.contains(where: { $0.severity == .error }) {
            status = .notWorking
        } else if problems.contains(where: { $0.severity == .warning }) {
            status = .needsAttention
        } else {
            status = .healthy
        }
        return RepoHealth(status: status, problems: problems)
    }

    /// The last activity of a run: its last event, or its start before the first.
    public static func lastActivity(_ run: StateSnapshot.Run) -> Date? {
        run.lastEventAt ?? run.startedAt
    }

    // MARK: Problems

    private static func workflowProblem(_ repo: RepoStatus, pending: PendingWorkflow?) -> Problem? {
        if let pending {
            switch pending {
            case let .pullRequest(url):
                return Problem(
                    id: "workflow",
                    severity: .warning,
                    title: "WORKFLOW.md is waiting on its pull request",
                    note: "Symphony uses it once the pull request merges into \(branchName(repo)).",
                    fixes: URL(string: url).map { [.viewPullRequest($0)] } ?? []
                )
            case let .localFile(path):
                return Problem(
                    id: "workflow",
                    severity: .warning,
                    title: "WORKFLOW.md is written but not pushed",
                    detail: (path as NSString).abbreviatingWithTildeInPath,
                    note: "Symphony uses it once it is on \(branchName(repo)).",
                    fixes: [.revealInFinder(path: path)]
                )
            }
        }
        switch repo.workflow.state {
        case .missing:
            return Problem(
                id: "workflow",
                severity: .warning,
                title: "WORKFLOW.md is missing",
                detail: "Symphony found no WORKFLOW.md on \(branchName(repo))."
            )
        case .invalid:
            return Problem(
                id: "workflow",
                severity: .error,
                title: "WORKFLOW.md is invalid",
                detail: repo.workflow.error,
                fixes: workflowURL(repo).map { [.openWorkflow($0)] } ?? []
            )
        case .valid, .other:
            return nil
        }
    }

    private static func fetchProblem(_ fetch: RepoStatus.Fetch, repo: RepoStatus, now: Date) -> Problem {
        let when = fetch.at.map { " \(StatusMenu.durationLabel(Int(now.timeIntervalSince($0)))) ago" } ?? ""
        var fixes: [Fix] = []
        if let error = fetch.error { fixes.append(.copyError(error)) }
        if let url = gitHubURL(repo.github) { fixes.append(.openOnGitHub(url)) }
        return Problem(
            id: "fetch",
            severity: .error,
            title: "The last fetch failed\(when)",
            detail: fetch.error,
            note: fetchRetryNote,
            fixes: fixes
        )
    }

    private static func stuckProblem(_ worktree: RepoStatus.Worktree, runs: [StateSnapshot.Run], now: Date) -> Problem? {
        guard let run = runs.first(where: { $0.issueIdentifier == worktree.issueIdentifier }),
              let last = lastActivity(run)
        else { return nil }
        let idle = now.timeIntervalSince(last)
        guard idle >= stuckAfter else { return nil }
        var fixes: [Fix] = [.stopRun(issueIdentifier: run.issueIdentifier)]
        if let url = run.url { fixes.append(.openInLinear(url)) }
        if worktree.workerHost == nil, let path = worktree.path { fixes.append(.revealWorktree(path: path)) }
        return Problem(
            id: "stuck-\(run.issueIdentifier)",
            severity: .warning,
            title: "\(run.issueIdentifier) has shown no activity for \(StatusMenu.durationLabel(Int(idle)))",
            note: "Symphony's stall timeout should have restarted it, so it looks stuck.",
            fixes: fixes
        )
    }

    // MARK: Helpers

    private static func branchName(_ repo: RepoStatus) -> String {
        let branch = repo.baseBranch?.trimmingWhitespace() ?? ""
        return branch.isEmpty ? "the default branch" : branch
    }

    private static func gitHubURL(_ github: String?) -> URL? {
        github.flatMap { URL(string: "https://github.com/\($0)") }
    }

    /// The local file, or for a managed clone the file on GitHub at the base branch (`HEAD` for the default one).
    static func workflowURL(_ repo: RepoStatus) -> URL? {
        switch repo.source {
        case let .local(path):
            if let file = repo.workflow.path { return URL(fileURLWithPath: file) }
            return path.map { URL(fileURLWithPath: $0).appendingPathComponent("WORKFLOW.md") }
        case let .managed(github, clonePath, _):
            var file = "WORKFLOW.md"
            if let path = repo.workflow.path, let clonePath, path.hasPrefix(clonePath + "/") {
                file = String(path.dropFirst(clonePath.count + 1))
            }
            let branch = repo.baseBranch?.trimmingWhitespace() ?? ""
            return URL(string: "https://github.com/\(github)/blob/\(branch.isEmpty ? "HEAD" : branch)/\(file)")
        }
    }
}
