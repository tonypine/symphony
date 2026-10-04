import Foundation

/// One repo as Symphony's `GET /api/v1/repos` reports it.
public struct RepoStatus: Equatable {
    /// Where the repo's code comes from.
    public enum Source: Equatable {
        /// A local checkout that agent worktrees are made from.
        case local(path: String?)
        /// Symphony's own clone of a GitHub repo; `cloned` stays false until a dispatch makes it.
        case managed(github: String, clonePath: String?, cloned: Bool)
    }

    /// Whether `WORKFLOW.md` loads. A status this app doesn't know is kept as Symphony words it.
    public enum WorkflowState: Equatable {
        case valid
        case missing
        case invalid
        case other(String)
    }

    public struct Workflow: Equatable {
        public var path: String?
        public var state: WorkflowState
        /// Why the file is missing or invalid, as Symphony reports it.
        public var error: String?

        public init(path: String? = nil, state: WorkflowState, error: String? = nil) {
            self.path = path
            self.state = state
            self.error = error
        }
    }

    /// The last `git fetch origin` Symphony ran before a dispatch.
    public struct Fetch: Equatable {
        public var at: Date?
        public var succeeded: Bool
        public var error: String?

        public init(at: Date? = nil, succeeded: Bool, error: String? = nil) {
            self.at = at
            self.succeeded = succeeded
            self.error = error
        }
    }

    /// The worktree of a running agent.
    public struct Worktree: Equatable {
        public var issueIdentifier: String
        public var path: String?
        /// The SSH worker the agent runs on, nil on this host.
        public var workerHost: String?

        public init(issueIdentifier: String, path: String? = nil, workerHost: String? = nil) {
            self.issueIdentifier = issueIdentifier
            self.path = path
            self.workerHost = workerHost
        }
    }

    public var key: String
    public var isDefault: Bool
    public var baseBranch: String?
    public var source: Source
    /// `owner/repo`, nil when the repo has no GitHub remote.
    public var github: String?
    public var route: RepositoryRoute
    public var workflow: Workflow
    /// Nil until Symphony fetched the repo before a dispatch.
    public var lastFetch: Fetch?
    public var worktrees: [Worktree]

    public init(
        key: String,
        isDefault: Bool = false,
        baseBranch: String? = nil,
        source: Source = .local(path: nil),
        github: String? = nil,
        route: RepositoryRoute = RepositoryRoute(),
        workflow: Workflow = Workflow(state: .valid),
        lastFetch: Fetch? = nil,
        worktrees: [Worktree] = []
    ) {
        self.key = key
        self.isDefault = isDefault
        self.baseBranch = baseBranch
        self.source = source
        self.github = github
        self.route = route
        self.workflow = workflow
        self.lastFetch = lastFetch
        self.worktrees = worktrees
    }
}

/// The outcome of asking Symphony for its repos.
public enum ReposPoll: Equatable {
    /// `warning` is set when Symphony listed the repos without their running agents.
    case repos([RepoStatus], warning: String?)
    /// Nothing answered on the control URL.
    case unreachable
    /// Symphony answered 404: it is older than `GET /api/v1/repos`.
    case unsupported
    /// Something answered, but not with the repos; the message says what went wrong.
    case failed(String)
}

/// Reads Symphony's `GET /api/v1/repos`, served without a token like `/api/v1/state`.
public enum ReposAPI {
    /// Longer than the state poll's, as Symphony reads each checkout's `origin` remote to answer.
    public static let timeout: TimeInterval = 5

    public static func reposURL(base: URL) -> URL {
        base.appendingPathComponent("api/v1/repos")
    }

    /// Asks the Symphony whose control URL is in `stateRoot` for its repos. `fallback` is the control URL used
    /// while Symphony hasn't written one.
    public static func fetch(
        stateRoot: URL,
        fallback: URL?,
        transport: ControlAPI.Transport = { try await URLSession.shared.data(for: $0) }
    ) async -> ReposPoll {
        guard let base = StateRoot.controlURL(in: stateRoot, fallback: fallback) else { return .unreachable }
        let request = URLRequest(
            url: reposURL(base: base),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        guard let (data, response) = try? await transport(request) else { return .unreachable }
        return poll(data: data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Turns a repos response into a poll result.
    public static func poll(data: Data, statusCode: Int) -> ReposPoll {
        let payload = try? decoder.decode(Payload.self, from: data)
        switch statusCode {
        case 200:
            break
        case 404:
            return .unsupported
        default:
            let message = payload?.error?.message ?? payload?.error?.code
            return .failed(message.map { "\($0) (HTTP \(statusCode))" } ?? "Symphony answered with HTTP \(statusCode)")
        }
        guard let payload, let repos = payload.repos else { return .failed("Symphony's repos couldn't be read") }
        let warning = payload.error.map { $0.message ?? $0.code ?? "Symphony reported an error" }
        return .repos(repos.map(status), warning: warning)
    }

    private static func status(_ repo: Payload.Repo) -> RepoStatus {
        RepoStatus(
            key: repo.key,
            isDefault: repo.default ?? false,
            baseBranch: repo.baseBranch,
            source: source(repo.source),
            github: repo.github,
            route: RepositoryRoute(
                team: repo.routing?.team,
                projects: repo.routing?.projects,
                labels: repo.routing?.labels,
                assignee: repo.routing?.assignee
            ),
            workflow: RepoStatus.Workflow(
                path: repo.workflow?.path,
                state: workflowState(repo.workflow?.status),
                error: repo.workflow?.error
            ),
            lastFetch: repo.lastFetch.map { fetch in
                RepoStatus.Fetch(at: fetch.at.flatMap(parseDate), succeeded: fetch.result == "ok", error: fetch.error)
            },
            worktrees: (repo.worktrees ?? []).compactMap { worktree in
                guard let identifier = worktree.issueIdentifier ?? worktree.issueId else { return nil }
                return RepoStatus.Worktree(issueIdentifier: identifier, path: worktree.path, workerHost: worktree.workerHost)
            }
        )
    }

    private static func source(_ source: Payload.Source?) -> RepoStatus.Source {
        guard let source, source.kind == "managed", let github = source.github else {
            return .local(path: source?.path)
        }
        return .managed(github: github, clonePath: source.clonePath, cloned: source.cloned ?? false)
    }

    private static func workflowState(_ text: String?) -> RepoStatus.WorkflowState {
        switch text {
        case "valid":
            return .valid
        case "missing":
            return .missing
        case "invalid":
            return .invalid
        default:
            return .other(text ?? "unknown")
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Symphony writes whole-second UTC timestamps, for example `2026-10-02T12:16:02Z`.
    private static func parseDate(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }

    private struct Payload: Decodable {
        struct Source: Decodable {
            let kind: String?
            let path: String?
            let github: String?
            let clonePath: String?
            let cloned: Bool?
        }

        struct Routing: Decodable {
            let team: String?
            let projects: [String]?
            let labels: [String]?
            let assignee: String?
        }

        struct Workflow: Decodable {
            let path: String?
            let status: String?
            let error: String?
        }

        struct Fetch: Decodable {
            let at: String?
            let result: String?
            let error: String?
        }

        struct Worktree: Decodable {
            let issueId: String?
            let issueIdentifier: String?
            let path: String?
            let workerHost: String?
        }

        struct Repo: Decodable {
            let key: String
            let `default`: Bool?
            let baseBranch: String?
            let source: Source?
            let github: String?
            let routing: Routing?
            let workflow: Workflow?
            let lastFetch: Fetch?
            let worktrees: [Worktree]?
        }

        struct Failure: Decodable {
            let code: String?
            let message: String?
        }

        let repos: [Repo]?
        let error: Failure?
    }
}

/// One line of a repo's row: a label, its value, and an optional detail shown under it and on hover.
public struct RepoField: Equatable {
    public enum Tone: Equatable {
        case normal
        /// Symphony isn't answering, so the value isn't known.
        case unavailable
        /// Something needs the engineer's attention, such as an invalid `WORKFLOW.md` or a failed fetch.
        case problem
    }

    public var label: String
    public var value: String
    public var detail: String?
    public var tone: Tone

    public init(_ label: String, _ value: String, detail: String? = nil, tone: Tone = .normal) {
        self.label = label
        self.value = value
        self.detail = detail
        self.tone = tone
    }
}

/// What can be done to a repo from its row. A nil problem means the action is on.
public struct RepoActions: Equatable {
    /// Why Edit is off.
    public var editProblem: String?
    /// Why Disconnect is off.
    public var disconnectProblem: String?
    /// Whether Symphony's clone can be deleted, nil for a repo that isn't a managed clone.
    public var cloneRemoval: ManagedClones.Removal?

    public init(editProblem: String? = nil, disconnectProblem: String? = nil, cloneRemoval: ManagedClones.Removal? = nil) {
        self.editProblem = editProblem
        self.disconnectProblem = disconnectProblem
        self.cloneRemoval = cloneRemoval
    }

    /// Why actions are off, each reason once, to show under the row.
    public var notes: [String] {
        var notes: [String] = []
        for problem in [editProblem, disconnectProblem] {
            if let problem, !notes.contains(problem) { notes.append(problem) }
        }
        if case let .blocked(reason)? = cloneRemoval { notes.append(reason) }
        return notes
    }
}

/// A row of the Repos window.
public struct RepoRow: Equatable, Identifiable {
    public var id: String { key }
    public var key: String
    public var isDefault: Bool
    public var fields: [RepoField]
    /// `owner/repo` of a managed clone, nil for a local folder.
    public var managedGitHub: String?
    public var actions: RepoActions

    public init(
        key: String,
        isDefault: Bool,
        fields: [RepoField],
        managedGitHub: String? = nil,
        actions: RepoActions = RepoActions()
    ) {
        self.key = key
        self.isDefault = isDefault
        self.fields = fields
        self.managedGitHub = managedGitHub
        self.actions = actions
    }
}

/// What the Repos window shows: a notice above the rows when they don't come from a running Symphony.
public struct ReposDisplay: Equatable {
    public var notice: String?
    public var rows: [RepoRow]

    public init(notice: String? = nil, rows: [RepoRow] = []) {
        self.notice = notice
        self.rows = rows
    }
}

/// Pure description of the Repos window, kept free of SwiftUI so it can be unit tested.
public enum ReposList {
    /// Title of the menu item that opens the Repos window, and of the window.
    public static let menuTitle = "Repos…"
    public static let windowTitle = "Symphony Repos"

    /// Marker next to the key of the repo that takes the issues no route matches, and its tooltip.
    public static let defaultMarker = "default"
    public static let defaultHelp = "Takes the issues no other repo's route matches."

    /// Field labels, in row order.
    public static let sourceLabel = "Source"
    public static let githubLabel = "GitHub"
    public static let linearLabel = "Linear"
    public static let workflowLabel = "WORKFLOW.md"
    public static let lastFetchLabel = "Last fetch"
    public static let agentsLabel = "Agents"

    /// Value of a field only a running Symphony knows.
    public static let unavailable = "unavailable"

    /// The Repos window for Symphony's `status` and the last repos poll, nil before the first. The repos come
    /// from Symphony only while it answers; otherwise the rows come from the `symphony.yml` at `configPath`
    /// with their live fields marked unavailable, and `readConfig` reads its repositories.
    public static func display(
        status: SymphonyStatus,
        poll: ReposPoll?,
        configPath: String,
        readConfig: (String) throws -> [RepositoryEntry],
        now: Date = Date()
    ) -> ReposDisplay {
        if isAnswering(status), case let .repos(repos, warning)? = poll {
            return ReposDisplay(
                notice: warning.map { "Symphony couldn't list its running agents: \($0)" }
                    ?? (repos.isEmpty ? "Symphony lists no repos." : nil),
                rows: repos.map { row($0, now: now) }
            )
        }
        return configured(reason: reason(status: status, poll: poll), configPath: configPath, readConfig: readConfig)
    }

    /// True while Symphony answers its state, so the app asks it for the repos.
    public static func isAnswering(_ status: SymphonyStatus) -> Bool {
        switch status {
        case .running, .paused:
            return true
        case .stopped, .starting, .error:
            return false
        }
    }

    /// Why the rows come from `symphony.yml`, as the start of a sentence.
    static func reason(status: SymphonyStatus, poll: ReposPoll?) -> String {
        switch status {
        case .stopped:
            return "Symphony is stopped"
        case .starting:
            return "Symphony is starting"
        case .error:
            return "Symphony isn't answering"
        case .running, .paused:
            switch poll {
            case .unsupported?:
                return "This Symphony doesn't list its repos; update it to see their live status"
            case let .failed(message)?:
                return "Couldn't read the repos from Symphony: \(message)"
            case .unreachable?:
                return "Nothing answered on Symphony's control URL"
            case .repos?, nil:
                return "Asking Symphony for the repos' status"
            }
        }
    }

    /// The repos in `symphony.yml`, with `reason` saying why their live fields are unavailable.
    static func configured(
        reason: String,
        configPath: String,
        readConfig: (String) throws -> [RepositoryEntry]
    ) -> ReposDisplay {
        let path = configPath.trimmingWhitespace()
        guard !path.isEmpty else { return ReposDisplay(notice: "\(reason). No symphony.yml is set in Settings.") }
        let shownPath = (path as NSString).abbreviatingWithTildeInPath
        let entries: [RepositoryEntry]
        do {
            entries = try readConfig(path)
        } catch {
            return ReposDisplay(notice: "\(reason). Couldn't read the repos in \(shownPath): \(error.localizedDescription)")
        }
        guard !entries.isEmpty else {
            return ReposDisplay(notice: "\(reason). \(shownPath) has no repositories: section.")
        }
        return ReposDisplay(
            notice: "\(reason). Showing the repos in \(shownPath); live fields are unavailable.",
            rows: entries.map(row)
        )
    }

    /// A repo as a running Symphony reports it.
    public static func row(_ repo: RepoStatus, now: Date = Date()) -> RepoRow {
        var managedGitHub: String?
        if case let .managed(github, _, _) = repo.source { managedGitHub = github }
        return RepoRow(
            key: repo.key,
            isDefault: repo.isDefault,
            fields: [
                sourceField(repo.source),
                RepoField(githubLabel, repo.github ?? "no GitHub remote"),
                linearField(repo.route),
                workflowField(repo.workflow),
                fetchField(repo.lastFetch, now: now),
                agentsField(repo.worktrees),
            ],
            managedGitHub: managedGitHub
        )
    }

    /// A repo as `symphony.yml` configures it, with what only a running Symphony knows marked unavailable.
    public static func row(_ entry: RepositoryEntry) -> RepoRow {
        let source: RepoField
        let github: RepoField
        var managedGitHub: String?
        if let managed = entry.workspace.source?.trimmingWhitespace(), !managed.isEmpty {
            let repo = gitHubRepo(managed)
            source = RepoField(sourceLabel, "Managed clone of \(repo)")
            github = RepoField(githubLabel, repo)
            managedGitHub = repo
        } else {
            let path = entry.workspace.repo?.trimmingWhitespace()
            source = RepoField(sourceLabel, "Local folder", detail: path.flatMap { $0.isEmpty ? nil : $0 })
            github = RepoField(githubLabel, unavailable, tone: .unavailable)
        }
        return RepoRow(
            key: entry.key,
            isDefault: entry.isDefault ?? false,
            fields: [
                source,
                github,
                linearField(entry.route),
                RepoField(workflowLabel, unavailable, detail: entry.workflow ?? "WORKFLOW.md", tone: .unavailable),
                RepoField(lastFetchLabel, unavailable, tone: .unavailable),
                RepoField(agentsLabel, unavailable, tone: .unavailable),
            ],
            managedGitHub: managedGitHub
        )
    }

    /// `display` with each row's actions: Edit and Disconnect need the repo in `symphony.yml`, read as `entries`,
    /// and `cloneRemoval` says whether a managed repo's clone can be deleted.
    public static func withActions(
        _ display: ReposDisplay,
        entries: Result<[RepositoryEntry], AddRepoProblem>,
        cloneRemoval: (_ gitHub: String) -> ManagedClones.Removal
    ) -> ReposDisplay {
        var display = display
        for index in display.rows.indices {
            var row = display.rows[index]
            switch entries {
            case let .failure(problem):
                row.actions.editProblem = problem.message
                row.actions.disconnectProblem = problem.message
            case let .success(entries):
                row.actions.disconnectProblem = DisconnectRepo.problem(key: row.key, entries: entries)
                row.actions.editProblem = entries.contains { $0.key == row.key } ? nil : row.actions.disconnectProblem
            }
            row.actions.cloneRemoval = row.managedGitHub.map(cloneRemoval)
            display.rows[index] = row
        }
        return display
    }

    static func sourceField(_ source: RepoStatus.Source) -> RepoField {
        switch source {
        case let .local(path):
            return RepoField(sourceLabel, "Local folder", detail: path.map(abbreviated))
        case let .managed(github, clonePath, cloned):
            let detail = cloned ? clonePath.map(abbreviated) : "not cloned yet: Symphony clones it on the first dispatch"
            return RepoField(sourceLabel, "Managed clone of \(github)", detail: detail)
        }
    }

    /// For example "team ENG · project web-platform · labels frontend, api · assignee me".
    static func linearField(_ route: RepositoryRoute) -> RepoField {
        var parts: [String] = []
        if let team = route.team?.trimmingWhitespace(), !team.isEmpty { parts.append("team \(team)") }
        if let projects = route.projects, !projects.isEmpty {
            parts.append("\(projects.count == 1 ? "project" : "projects") \(projects.joined(separator: ", "))")
        }
        if let labels = route.labels, !labels.isEmpty {
            parts.append("\(labels.count == 1 ? "label" : "labels") \(labels.joined(separator: ", "))")
        }
        if let assignee = route.assignee?.trimmingWhitespace(), !assignee.isEmpty { parts.append("assignee \(assignee)") }
        return RepoField(linearLabel, parts.isEmpty ? "no route" : parts.joined(separator: " · "))
    }

    /// "found, valid", "found, invalid" with the error, or "missing" with the error.
    static func workflowField(_ workflow: RepoStatus.Workflow) -> RepoField {
        let path = workflow.path.map(abbreviated)
        switch workflow.state {
        case .valid:
            return RepoField(workflowLabel, "found, valid", detail: path)
        case .invalid:
            return RepoField(workflowLabel, "found, invalid", detail: workflow.error ?? path, tone: .problem)
        case .missing:
            return RepoField(workflowLabel, "missing", detail: workflow.error ?? path, tone: .problem)
        case let .other(status):
            return RepoField(workflowLabel, status, detail: workflow.error ?? path)
        }
    }

    /// "5m ago, ok", or "5m ago, failed" with the error; "none yet" before the first fetch.
    static func fetchField(_ fetch: RepoStatus.Fetch?, now: Date) -> RepoField {
        guard let fetch else { return RepoField(lastFetchLabel, "none yet") }
        let when = fetch.at.map { "\(StatusMenu.durationLabel(Int(now.timeIntervalSince($0)))) ago" } ?? "at an unknown time"
        return fetch.succeeded
            ? RepoField(lastFetchLabel, "\(when), ok")
            : RepoField(lastFetchLabel, "\(when), failed", detail: fetch.error, tone: .problem)
    }

    /// "TP-1, TP-2 (on worker-1)", or "none" while no agent runs on the repo.
    static func agentsField(_ worktrees: [RepoStatus.Worktree]) -> RepoField {
        guard !worktrees.isEmpty else { return RepoField(agentsLabel, "none") }
        let value = worktrees.map { worktree in
            worktree.workerHost.map { "\(worktree.issueIdentifier) (on \($0))" } ?? worktree.issueIdentifier
        }
        let paths = worktrees.compactMap { $0.path.map(abbreviated) }
        let detail = paths.isEmpty ? nil : paths.joined(separator: "\n")
        return RepoField(agentsLabel, value.joined(separator: ", "), detail: detail)
    }

    /// `owner/repo` from a `workspace.source`: `owner/repo`, a github.com URL or an SSH remote.
    static func gitHubRepo(_ source: String) -> String {
        var repo = source
        for prefix in ["https://github.com/", "http://github.com/", "ssh://git@github.com/", "git@github.com:"]
        where repo.hasPrefix(prefix) {
            repo.removeFirst(prefix.count)
        }
        if repo.hasSuffix("/") { repo.removeLast() }
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        return repo
    }

    private static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
