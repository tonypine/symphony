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

    public static let path = "api/v1/repos"

    public static func reposURL(base: URL) -> URL {
        base.appendingPathComponent(path)
    }

    /// The repos in what the window's client got for `path`.
    public static func poll(_ result: EndpointResult) -> ReposPoll {
        switch result {
        case let .loaded(data): poll(data: data, statusCode: 200)
        case .unsupported: .unsupported
        case let .failed(message): .failed(message)
        }
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


/// A label, its value, and an optional detail shown under it and on hover.
public struct RepoField: Equatable {
    public enum Tone: Equatable {
        case normal
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

/// What can be done to a repo from the Repos window. A nil problem means the action is on.
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
}

/// The `symphony.yml` the Repos window reads, read once per refresh.
public struct ReposConfig: Equatable {
    public enum Repos: Equatable {
        /// Settings has no `symphony.yml` path.
        case noPath
        /// The file or its `repositories:` couldn't be read; the message says why.
        case unreadable(String)
        case entries([RepositoryEntry])
    }

    public var path: String
    public var repos: Repos
    /// `auto_review.acceptance_gate.mode`, nil when it can't be read.
    public var globalGate: AcceptanceGateMode?
    /// Where Symphony keeps its own clones.
    public var clonesRoot: URL

    public init(path: String, repos: Repos, globalGate: AcceptanceGateMode? = nil, clonesRoot: URL? = nil) {
        self.path = path
        self.repos = repos
        self.globalGate = globalGate
        self.clonesRoot = clonesRoot ?? ManagedClones.root(in: "", configPath: path)
    }

    /// Reads the `symphony.yml` at `path`, as Settings holds it.
    public static func read(path: String) -> ReposConfig {
        let path = path.trimmingWhitespace()
        guard !path.isEmpty else { return ReposConfig(path: path, repos: .noPath) }
        let file = SymphonyConfigFile(path: path)
        let repos: Repos
        do {
            repos = .entries(try file.readRepositories())
        } catch {
            repos = .unreadable(error.localizedDescription)
        }
        return ReposConfig(
            path: path,
            repos: repos,
            globalGate: try? file.readAcceptanceGateMode(),
            clonesRoot: try? file.readClonesRoot()
        )
    }

    public var shownPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// The repositories, or why Edit and Disconnect can't change `symphony.yml`.
    public var entries: Result<[RepositoryEntry], AddRepoProblem> {
        switch repos {
        case .noPath:
            return .failure(AddRepoProblem("Set the symphony.yml path in Settings first."))
        case let .unreadable(message):
            return .failure(AddRepoProblem("Couldn't read the repos in \(shownPath): \(message)"))
        case let .entries(entries):
            return .success(entries)
        }
    }
}

/// The Repos window's toolbar chip: Symphony's state, said once for the whole window.
public enum ReposChip: Equatable {
    case running
    case paused
    case starting
    case stopped
    case notAnswering

    public enum Dot: Equatable {
        case green
        case orange
        case grey
        case red
    }

    public init(status: SymphonyStatus) {
        switch status {
        case .running:
            self = .running
        case .paused:
            self = .paused
        case .starting:
            self = .starting
        case .stopped:
            self = .stopped
        case .error:
            self = .notAnswering
        }
    }

    public var title: String {
        switch self {
        case .running: return "Symphony running"
        case .paused: return "Symphony paused"
        case .starting: return "Symphony is starting…"
        case .stopped: return "Symphony stopped"
        case .notAnswering: return "Symphony isn't answering"
        }
    }

    public var dot: Dot {
        switch self {
        case .running: return .green
        case .paused: return .orange
        case .starting, .stopped: return .grey
        case .notAnswering: return .red
        }
    }
}

/// What the Repos window shows in place of repos.
public enum ReposEmptyState: Equatable {
    /// `repositories:` is empty or missing, or Symphony lists no repos: offers Add Repo….
    case noRepos
    /// Settings has no `symphony.yml` path: offers Open Settings….
    case noConfig
    /// The `symphony.yml` at `path` can't be read: shows the error, with Reveal in Finder and Try Again.
    case unreadable(path: String, message: String)

    public var title: String {
        switch self {
        case .noRepos: return "No repos connected"
        case .noConfig: return "Symphony doesn't know where its config is."
        case .unreadable: return "Couldn't read symphony.yml"
        }
    }

    public var message: String {
        switch self {
        case .noRepos:
            return "Connect a GitHub repo or a folder on this Mac, and pick which Linear issues go to it."
        case .noConfig:
            return "Set the path of symphony.yml in Settings."
        case let .unreadable(path, _):
            return (path as NSString).abbreviatingWithTildeInPath
        }
    }
}

/// One repo in the Repos window: its sidebar row and its detail.
public struct RepoDetail: Equatable, Identifiable {
    /// Where the repo's code comes from.
    public struct Source: Equatable {
        public enum Kind: Equatable {
            case local
            case managed
        }

        public var kind: Kind
        /// The local folder, or Symphony's clone once it exists, in full so it can be revealed in Finder.
        public var path: String?
        /// True for a managed repo Symphony hasn't cloned yet.
        public var notCloned: Bool
        public var baseBranch: String
        /// `owner/repo` of a managed clone, nil for a local folder.
        public var managedGitHub: String?

        public init(kind: Kind, path: String? = nil, notCloned: Bool = false, baseBranch: String, managedGitHub: String? = nil) {
            self.kind = kind
            self.path = path
            self.notCloned = notCloned
            self.baseBranch = baseBranch
            self.managedGitHub = managedGitHub
        }

        public var kindTitle: String {
            kind == .local ? "Local folder" : "Managed clone"
        }

        public var pathLabel: String {
            kind == .local ? "Folder" : "Clone"
        }

        public var shownPath: String? {
            path.map { ($0 as NSString).abbreviatingWithTildeInPath }
        }
    }

    /// Which Linear issues go to the repo.
    public struct Routing: Equatable {
        /// For example "Issues in Billing with label backend go to billing-api."
        public var sentence: String
        /// Project, labels, team and assignee, those that are set.
        public var fields: [RepoField]
        /// Set on the default repo.
        public var defaultLine: String?

        public init(sentence: String, fields: [RepoField] = [], defaultLine: String? = nil) {
            self.sentence = sentence
            self.fields = fields
            self.defaultLine = defaultLine
        }
    }

    /// An agent running on the repo.
    public struct Agent: Equatable {
        public var issueIdentifier: String
        /// The SSH worker it runs on, nil on this Mac.
        public var workerHost: String?
        /// Its worktree, set only on this Mac, where Finder can reveal it.
        public var worktreePath: String?
        /// "Running for 12m · last activity 3m ago", nil when Symphony's state doesn't list the run.
        public var activity: String?

        public init(issueIdentifier: String, workerHost: String? = nil, worktreePath: String? = nil, activity: String? = nil) {
            self.issueIdentifier = issueIdentifier
            self.workerHost = workerHost
            self.worktreePath = worktreePath
            self.activity = activity
        }

        /// "TP-7", or "TP-7 · on worker-1".
        public var title: String {
            workerHost.map { "\(issueIdentifier) · on \($0)" } ?? issueIdentifier
        }
    }

    /// What only a running Symphony knows: `WORKFLOW.md` and recent activity.
    public enum Live: Equatable {
        /// `agentsProblem` is set when Symphony listed the repos without their running agents.
        case status(workflow: RepoField, lastFetch: RepoField, agents: [Agent], agentsProblem: String?)
        /// One line in place of both sections, with Start Symphony when `canStart`.
        case folded(line: String, canStart: Bool)
    }

    /// The repo's acceptance gate.
    public struct Gate: Equatable {
        public var mode: RepoField
        public var record: String

        public init(mode: RepoField, record: String) {
            self.mode = mode
            self.record = record
        }
    }

    public var id: String { key }
    public var key: String
    public var isDefault: Bool
    /// `owner/repo`, nil when it isn't known.
    public var github: String?
    /// `owner/repo`, or the folder name.
    public var subtitle: String?
    public var source: Source
    public var routing: Routing
    public var live: Live
    /// Nil for a repo `symphony.yml` doesn't have.
    public var gate: Gate?
    public var actions: RepoActions
    public var health: RepoHealth

    public init(
        key: String,
        isDefault: Bool = false,
        github: String? = nil,
        subtitle: String? = nil,
        source: Source,
        routing: Routing,
        live: Live,
        gate: Gate? = nil,
        actions: RepoActions = RepoActions(),
        health: RepoHealth = .notChecked(status: .stopped, poll: nil)
    ) {
        self.key = key
        self.isDefault = isDefault
        self.github = github
        self.subtitle = subtitle
        self.source = source
        self.routing = routing
        self.live = live
        self.gate = gate
        self.actions = actions
        self.health = health
    }

    /// Agents running on the repo, 0 while Symphony doesn't say.
    public var agentCount: Int {
        guard case let .status(_, _, agents, _) = live else { return 0 }
        return agents.count
    }

    public var gitHubURL: URL? {
        github.flatMap { URL(string: "https://github.com/\($0)") }
    }

    /// What VoiceOver reads for the sidebar row: "billing-api, needs attention, default, 2 agents running".
    public var accessibilityLabel: String {
        var parts = [key, health.status.spoken]
        if isDefault { parts.append("default") }
        let count = agentCount
        if count > 0 { parts.append(count == 1 ? "1 agent running" : "\(count) agents running") }
        return parts.joined(separator: ", ")
    }
}

/// What the Repos window shows: the toolbar chip, and the repos or an empty state.
public struct ReposWindow: Equatable {
    public enum Content: Equatable {
        case empty(ReposEmptyState)
        case repos([RepoDetail])
    }

    public var chip: ReposChip
    public var content: Content

    public init(chip: ReposChip = .stopped, content: Content = .repos([])) {
        self.chip = chip
        self.content = content
    }

    public var repos: [RepoDetail] {
        guard case let .repos(repos) = content else { return [] }
        return repos
    }
}

/// Pure description of the Repos window, kept free of SwiftUI so it can be unit tested.
public enum ReposList {
    /// Title of the menu item that opens the Repos window, and of the window.
    public static let menuTitle = "Repos…"
    public static let windowTitle = "Repos"

    /// The capsule on the repo that takes the issues no route matches, and its tooltip.
    public static let defaultBadge = "Default"
    public static let defaultHelp = "Takes the issues no other repo's route matches."

    /// The line in place of WORKFLOW.md and Activity while Symphony is stopped.
    public static let stoppedLine = "Live status shows while Symphony runs."
    /// The same line for a Symphony too old to serve `GET /api/v1/repos`.
    public static let unsupportedLine = "Update Symphony to see live status."
    public static let notClonedLine = "Not cloned yet: Symphony clones it on the next dispatch"
    public static let noAgentsLine = "No agents running"
    public static let defaultBranchLine = "origin's default branch"

    /// Buttons of the window, besides Add Repo…, Edit…, Disconnect…, Remove Clone… and Start Symphony.
    public static let revealTitle = "Reveal in Finder"
    public static let revealWorktreeTitle = "Reveal Worktree"
    public static let openOnGitHubTitle = "Open on GitHub"
    public static let openSettingsTitle = "Open Settings…"
    public static let tryAgainTitle = "Try Again"
    /// Value of the WORKFLOW.md status when the file loads.
    public static let validWorkflow = "Valid"
    /// Label of the WORKFLOW.md status field.
    public static let workflowStatusLabel = "Status"

    /// The window for Symphony's `status`, the last repos poll (nil before the first) and `symphony.yml`. The repos
    /// come from Symphony while it answers with them, otherwise from `symphony.yml` with what only Symphony knows
    /// folded into one line. `pending` is the `WORKFLOW.md` the app wrote for a repo key and that isn't on its base
    /// branch yet. `cloneRemoval` says whether a managed repo's clone can be deleted.
    public static func window(
        status: SymphonyStatus,
        poll: ReposPoll?,
        config: ReposConfig,
        now: Date = Date(),
        pending: (_ key: String) -> PendingWorkflow? = { _ in nil },
        isDirectory: (String) -> Bool = ManagedClones.isDirectory,
        cloneRemoval: (_ gitHub: String) -> ManagedClones.Removal
    ) -> ReposWindow {
        let chip = ReposChip(status: status)
        let snapshot = snapshot(status)
        let entries = (try? config.entries.get()) ?? []
        var details: [RepoDetail]
        if isAnswering(status), case let .repos(repos, warning)? = poll {
            let runs = snapshot?.runs ?? []
            details = repos.map { repo in
                detail(repo, warning: warning, runs: runs, pending: pending(repo.key), now: now)
                    .withGate(entries, config.globalGate, snapshot)
            }
        } else {
            switch config.repos {
            case .noPath:
                return ReposWindow(chip: chip, content: .empty(.noConfig))
            case let .unreadable(message):
                return ReposWindow(chip: chip, content: .empty(.unreadable(path: config.path, message: message)))
            case let .entries(entries):
                let live = folded(status: status, poll: poll)
                let health = RepoHealth.notChecked(status: status, poll: poll)
                details = entries.map { entry in
                    detail(entry, live: live, health: health, config: config, isDirectory: isDirectory)
                        .withGate(entries, config.globalGate, snapshot)
                }
            }
        }
        guard !details.isEmpty else { return ReposWindow(chip: chip, content: .empty(.noRepos)) }
        for index in details.indices {
            details[index].actions = actions(for: details[index], entries: config.entries, cloneRemoval: cloneRemoval)
        }
        return ReposWindow(chip: chip, content: .repos(details))
    }

    /// The repo to select: `saved` while the window lists it, otherwise the first.
    public static func selection(saved: String?, in window: ReposWindow) -> String? {
        let keys = window.repos.map(\.key)
        if let saved, keys.contains(saved) { return saved }
        return keys.first
    }

    /// The repo to select once the window refreshes, and the repo still waiting to be selected. `pending`, the repo of
    /// the banner shown last, is selected the first time the window lists it, as a running Symphony lists a repo
    /// just added only once its next poll comes back. Otherwise `current` stays while listed, else `saved` is restored.
    public static func selection(
        current: String?,
        pending: String?,
        saved: String?,
        in window: ReposWindow
    ) -> (selection: String?, pending: String?) {
        let keys = window.repos.map(\.key)
        if let pending, keys.contains(pending) { return (pending, nil) }
        if let current, keys.contains(current) { return (current, pending) }
        return (selection(saved: saved, in: window), pending)
    }

    /// True while Symphony answers its state, so the app asks it for the repos.
    public static func isAnswering(_ status: SymphonyStatus) -> Bool {
        snapshot(status) != nil
    }

    static func snapshot(_ status: SymphonyStatus) -> StateSnapshot? {
        switch status {
        case let .running(snapshot, _), let .paused(snapshot, _):
            return snapshot
        case .stopped, .starting, .error:
            return nil
        }
    }

    /// The line in place of WORKFLOW.md and Activity while the repos come from `symphony.yml`.
    static func folded(status: SymphonyStatus, poll: ReposPoll?) -> RepoDetail.Live {
        switch status {
        case .stopped:
            return .folded(line: stoppedLine, canStart: true)
        case .starting:
            return .folded(line: "Symphony is starting… Live status shows once it runs.", canStart: false)
        case .error:
            return .folded(line: "Symphony isn't answering. Live status shows while Symphony runs.", canStart: true)
        case .running, .paused:
            switch poll {
            case .unsupported?:
                return .folded(line: unsupportedLine, canStart: false)
            case let .failed(message)?:
                return .folded(line: "Couldn't read the repos from Symphony: \(message)", canStart: false)
            case .unreachable?:
                return .folded(line: "Nothing answered on Symphony's control URL.", canStart: false)
            case .repos?, nil:
                return .folded(line: "Asking Symphony for the repos' live status…", canStart: false)
            }
        }
    }

    /// A repo as a running Symphony reports it, with the running entries of its state.
    static func detail(
        _ repo: RepoStatus,
        warning: String?,
        runs: [StateSnapshot.Run] = [],
        pending: PendingWorkflow? = nil,
        now: Date
    ) -> RepoDetail {
        let source: RepoDetail.Source
        let branch = baseBranch(repo.baseBranch)
        switch repo.source {
        case let .local(path):
            source = RepoDetail.Source(kind: .local, path: path, baseBranch: branch)
        case let .managed(github, clonePath, cloned):
            source = RepoDetail.Source(
                kind: .managed,
                path: cloned ? clonePath : nil,
                notCloned: !cloned,
                baseBranch: branch,
                managedGitHub: github
            )
        }
        return RepoDetail(
            key: repo.key,
            isDefault: repo.isDefault,
            github: repo.github,
            subtitle: repo.github ?? folderName(source.path),
            source: source,
            routing: routing(repo.route, key: repo.key, isDefault: repo.isDefault),
            live: .status(
                workflow: workflowField(repo.workflow),
                lastFetch: fetchField(repo.lastFetch, now: now),
                agents: repo.worktrees.map { worktree in
                    RepoDetail.Agent(
                        issueIdentifier: worktree.issueIdentifier,
                        workerHost: worktree.workerHost,
                        worktreePath: worktree.workerHost == nil ? worktree.path : nil,
                        activity: runs.first { $0.issueIdentifier == worktree.issueIdentifier }
                            .flatMap { activityLine($0, now: now) }
                    )
                },
                agentsProblem: warning.map { "Symphony couldn't list its running agents: \($0)" }
            ),
            health: RepoHealth.of(repo, warning: warning, runs: runs, pending: pending, now: now)
        )
    }

    /// "Running for 12m · last activity 3m ago", or the part Symphony reported.
    static func activityLine(_ run: StateSnapshot.Run, now: Date) -> String? {
        let age = { (date: Date) in StatusMenu.durationLabel(Int(now.timeIntervalSince(date))) }
        switch (run.startedAt, run.lastEventAt) {
        case let (started?, last?):
            return "Running for \(age(started)) · last activity \(age(last)) ago"
        case let (started?, nil):
            return "Running for \(age(started)) · no activity yet"
        case let (nil, last?):
            return "Last activity \(age(last)) ago"
        case (nil, nil):
            return nil
        }
    }

    /// A repo as `symphony.yml` configures it, with `live` in place of what only a running Symphony knows.
    static func detail(
        _ entry: RepositoryEntry,
        live: RepoDetail.Live,
        health: RepoHealth = .notChecked(status: .stopped, poll: nil),
        config: ReposConfig,
        isDirectory: (String) -> Bool
    ) -> RepoDetail {
        let branch = baseBranch(entry.baseBranch)
        let source: RepoDetail.Source
        var github: String?
        if let managed = entry.workspace.source?.trimmingWhitespace(), !managed.isEmpty {
            let repo = gitHubRepo(managed)
            let clone = ManagedClones.clonePath(root: config.clonesRoot, gitHub: repo).path
            let cloned = isDirectory((clone as NSString).appendingPathComponent(".git"))
            source = RepoDetail.Source(
                kind: .managed,
                path: cloned ? clone : nil,
                notCloned: !cloned,
                baseBranch: branch,
                managedGitHub: repo
            )
            github = repo
        } else {
            let path = entry.workspace.repo?.trimmingWhitespace() ?? ""
            source = RepoDetail.Source(
                kind: .local,
                path: path.isEmpty ? nil : (path as NSString).expandingTildeInPath,
                baseBranch: branch
            )
        }
        let isDefault = entry.isDefault ?? false
        return RepoDetail(
            key: entry.key,
            isDefault: isDefault,
            github: github,
            subtitle: github ?? folderName(source.path),
            source: source,
            routing: routing(entry.route, key: entry.key, isDefault: isDefault),
            live: live,
            health: health
        )
    }

    /// Edit and Disconnect need the repo in `symphony.yml`, read as `entries`.
    static func actions(
        for detail: RepoDetail,
        entries: Result<[RepositoryEntry], AddRepoProblem>,
        cloneRemoval: (_ gitHub: String) -> ManagedClones.Removal
    ) -> RepoActions {
        var actions = RepoActions(cloneRemoval: detail.source.managedGitHub.map(cloneRemoval))
        switch entries {
        case let .failure(problem):
            actions.editProblem = problem.message
            actions.disconnectProblem = problem.message
        case let .success(entries):
            actions.disconnectProblem = DisconnectRepo.problem(key: detail.key, entries: entries)
            actions.editProblem = entries.contains { $0.key == detail.key } ? nil : actions.disconnectProblem
        }
        return actions
    }

    /// The route sentence, then each part of the route that is set.
    static func routing(_ route: RepositoryRoute, key: String, isDefault: Bool) -> RepoDetail.Routing {
        let team = route.team?.trimmingWhitespace() ?? ""
        let projects = (route.projects ?? []).filter { !$0.trimmingWhitespace().isEmpty }
        let labels = (route.labels ?? []).filter { !$0.trimmingWhitespace().isEmpty }
        let assignee = route.assignee?.trimmingWhitespace() ?? ""

        var fields: [RepoField] = []
        if !projects.isEmpty {
            fields.append(RepoField(projects.count == 1 ? "Project" : "Projects", projects.joined(separator: ", ")))
        }
        if !labels.isEmpty { fields.append(RepoField(labels.count == 1 ? "Label" : "Labels", labels.joined(separator: ", "))) }
        if !team.isEmpty { fields.append(RepoField("Team", team)) }
        if !assignee.isEmpty { fields.append(RepoField("Assignee", assignee)) }

        guard !fields.isEmpty else {
            return RepoDetail.Routing(
                sentence: "\(key) has no Linear route of its own.",
                defaultLine: isDefault ? "It takes the issues no other repo's route matches." : nil
            )
        }
        var sentence = projects.isEmpty ? "Issues" : "Issues in \(spoken(projects, or: true))"
        if !team.isEmpty { sentence += projects.isEmpty ? " in team \(team)" : " of team \(team)" }
        if !labels.isEmpty { sentence += " with \(labels.count == 1 ? "label" : "labels") \(spoken(labels, or: false))" }
        if !assignee.isEmpty { sentence += " assigned to \(assignee)" }
        return RepoDetail.Routing(
            sentence: sentence + " go to \(key).",
            fields: fields,
            defaultLine: isDefault ? "It also takes the issues no other repo's route matches." : nil
        )
    }

    /// "a", "a or b", "a, b or c" (or "and").
    static func spoken(_ items: [String], or: Bool) -> String {
        let word = or ? "or" : "and"
        guard let last = items.last, items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " \(word) \(last)"
    }

    /// "Valid", "Invalid" with the error, "Missing", or a status this app doesn't know as Symphony words it.
    static func workflowField(_ workflow: RepoStatus.Workflow) -> RepoField {
        let path = workflow.path.map(abbreviated)
        switch workflow.state {
        case .valid:
            return RepoField(workflowStatusLabel, validWorkflow, detail: path)
        case .invalid:
            return RepoField(workflowStatusLabel, "Invalid", detail: workflow.error ?? path, tone: .problem)
        case .missing:
            return RepoField(workflowStatusLabel, "Missing", detail: workflow.error ?? path, tone: .problem)
        case let .other(status):
            return RepoField(workflowStatusLabel, status, detail: workflow.error ?? path)
        }
    }

    /// "5m ago", or "Failed 5m ago" with the error; "None yet" before the first fetch.
    static func fetchField(_ fetch: RepoStatus.Fetch?, now: Date) -> RepoField {
        let label = "Last fetch"
        guard let fetch else { return RepoField(label, "None yet") }
        let when = fetch.at.map { "\(StatusMenu.durationLabel(Int(now.timeIntervalSince($0)))) ago" }
        guard fetch.succeeded else {
            return RepoField(label, "Failed" + (when.map { " \($0)" } ?? ""), detail: fetch.error, tone: .problem)
        }
        return RepoField(label, when ?? "At an unknown time")
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

    /// The base branch, or what Symphony starts branches from when `symphony.yml` names none: `origin/HEAD`.
    static func baseBranch(_ branch: String?) -> String {
        let branch = branch?.trimmingWhitespace() ?? ""
        return branch.isEmpty ? defaultBranchLine : branch
    }

    private static func folderName(_ path: String?) -> String? {
        path.map { ($0 as NSString).lastPathComponent }
    }

    private static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

private extension RepoDetail {
    /// The detail with its gate from `symphony.yml`'s `entries` and the global mode, and the record in `snapshot`.
    func withGate(_ entries: [RepositoryEntry], _ global: AcceptanceGateMode?, _ snapshot: StateSnapshot?) -> RepoDetail {
        var detail = self
        detail.gate = entries.first { $0.key == key }.map { AcceptanceGate.repoGate($0, global: global, in: snapshot) }
        return detail
    }
}
