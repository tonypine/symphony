import Foundation

/// The pages of the Add Repo sheet, in order. The WORKFLOW.md page shows only for a repo that has none. Connect, on
/// Review, saves the repo and goes on to Check setup, which has no way back. Instant updates (S13) shows only while
/// they are on, after Check setup.
public enum AddRepoStep: String, CaseIterable, Equatable {
    case source = "Source"
    case linear = "Linear"
    case workflow = "WORKFLOW.md"
    case review = "Review"
    case check = "Check setup"
    case instantUpdates = "Instant updates"

    fileprivate var order: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

/// One step in the Add Repo sheet's step indicator: a tick once done, else its number, and its name, as much as the
/// sheet's width lets show.
public struct AddRepoStepMark: Equatable {
    public var step: AddRepoStep
    public var isDone: Bool
    public var isCurrent: Bool
    /// Its number, nil once done (its tick shows instead) and where it shows by name alone.
    public var number: Int?
    /// Its name, nil where it shows by its tick or number alone.
    public var name: String?

    public init(step: AddRepoStep, isDone: Bool = false, isCurrent: Bool = false, number: Int? = nil, name: String? = nil) {
        self.step = step
        self.isDone = isDone
        self.isCurrent = isCurrent
        self.number = number
        self.name = name
    }
}

/// How much of each step the Add Repo sheet's step indicator shows, from the most to the least. The indicator shows
/// the first that fits on one line, so a name never wraps.
public enum AddRepoStepIndicatorFit: CaseIterable, Equatable {
    /// "✓ Source › ✓ Linear › 3 Review › 4 Check setup": each step's tick or number, and its name.
    case full
    /// "✓ › ✓ › WORKFLOW.md › Review › Check setup › Instant updates": the steps done by their tick alone, the others by
    /// name alone. All six steps fit this way on every page of the 520 pt sheet.
    case compact
    /// "✓ › ✓ › 3 WORKFLOW.md › 4 › 5 › 6": only the current step named.
    case currentOnly

    /// The indicator's steps, done up to `current`.
    public func marks(_ steps: [AddRepoStep], current: AddRepoStep) -> [AddRepoStepMark] {
        let index = steps.firstIndex(of: current) ?? 0
        return steps.enumerated().map { position, step in
            let isDone = position < index
            let isCurrent = step == current
            let named: Bool
            let numbered: Bool
            switch self {
            case .full:
                (named, numbered) = (true, !isDone)
            case .compact:
                (named, numbered) = (!isDone, false)
            case .currentOnly:
                (named, numbered) = (isCurrent, !isDone)
            }
            return AddRepoStepMark(
                step: step, isDone: isDone, isCurrent: isCurrent, number: numbered ? position + 1 : nil, name: named ? step.rawValue : nil
            )
        }
    }
}

/// How a list the sheet asks Linear for loads.
public enum LinearLoad: Equatable {
    case loading
    case loaded
    case failed(String)
}

/// The line under the source on the Source page: what the sheet found, or why it can't use the source.
public struct AddRepoSourceResult: Equatable {
    public enum Style: Equatable {
        /// The sheet is still checking; it shows a spinner.
        case checking
        /// The source checks out.
        case found
        /// Something the sheet couldn't check, which doesn't stop Continue.
        case note
        /// What stops Continue, shown in red.
        case problem
    }

    public var text: String
    public var style: Style

    public init(_ text: String, style: Style) {
        self.text = text
        self.style = style
    }
}

/// What the Add Repo sheet knows at one moment, and what each of its steps lets through. The sheet's model fills it
/// in from its state; it is kept free of SwiftUI so each step's Continue is unit tested.
public struct AddRepoFlow: Equatable {
    /// The rows of the Linear page, in order. A Linear failure adds the warning box under the pickers, which keep
    /// their place.
    public enum LinearRow: Equatable, Hashable {
        case project
        case labels
        /// Another repo already takes the issues of this project and labels.
        case twin(String)
        case preview
        /// What Linear said, with Retry and Open Settings….
        case warning(String)
    }

    public static let continueTitle = "Continue"
    public static let backTitle = "Back"
    public static let connectTitle = "Connect"
    public static let openSettingsTitle = "Open Settings…"
    public static let retryTitle = "Retry"

    public var draft: AddRepoDraft
    /// The `repositories:` list now.
    public var existing: [RepositoryEntry]
    /// True while the folder picked is checked.
    public var inspectingFolder: Bool
    /// The default branch of the source, as GitHub or the checkout's `origin/HEAD` reports it.
    public var defaultBranch: String?
    public var workflowCheck: WorkflowCheck
    public var landing: WorkflowLanding
    /// The `WORKFLOW.md` draft as edited.
    public var workflowText: String
    /// The `WORKFLOW.md` Connect already added, when writing `symphony.yml` then failed.
    public var landedWorkflow: PendingWorkflow?
    public var projects: LinearLoad
    public var labels: LinearLoad
    /// True for the Source sheet of a connected repo, which has no WORKFLOW.md step to offer.
    public var editing: Bool
    /// True while instant GitHub updates are on, so the sheet ends by connecting the repo to them (S13).
    public var instantUpdates: Bool

    public init(
        draft: AddRepoDraft = AddRepoDraft(),
        existing: [RepositoryEntry] = [],
        inspectingFolder: Bool = false,
        defaultBranch: String? = nil,
        workflowCheck: WorkflowCheck = .idle,
        landing: WorkflowLanding = .pullRequest,
        workflowText: String = "",
        landedWorkflow: PendingWorkflow? = nil,
        projects: LinearLoad = .loaded,
        labels: LinearLoad = .loaded,
        editing: Bool = false,
        instantUpdates: Bool = false
    ) {
        self.draft = draft
        self.existing = existing
        self.inspectingFolder = inspectingFolder
        self.defaultBranch = defaultBranch
        self.workflowCheck = workflowCheck
        self.landing = landing
        self.workflowText = workflowText
        self.landedWorkflow = landedWorkflow
        self.projects = projects
        self.labels = labels
        self.editing = editing
        self.instantUpdates = instantUpdates
    }

    // MARK: Steps

    /// The steps the sheet shows: WORKFLOW.md only once the repo is known to have none, Instant updates only while they
    /// are on.
    public var steps: [AddRepoStep] {
        AddRepoStep.allCases.filter { ($0 != .workflow || hasNoWorkflow) && ($0 != .instantUpdates || instantUpdates) }
    }

    /// The step Continue goes to from `step`, nil on Review, where Connect saves first, and on Check setup.
    public func step(after step: AddRepoStep) -> AddRepoStep? {
        guard step.order < AddRepoStep.review.order else { return nil }
        return steps.first { $0.order > step.order }
    }

    /// The step Back goes to from `step`, nil on Source, and on Check setup and Instant updates, once the repo is saved.
    public func step(before step: AddRepoStep) -> AddRepoStep? {
        guard step.order < AddRepoStep.check.order else { return nil }
        return steps.last { $0.order < step.order }
    }

    /// Why Continue (Connect, on Review) is off on `step`, nil while it is on. Its help says the same.
    public func problem(at step: AddRepoStep) -> AddRepoProblem? {
        switch step {
        case .source:
            return sourceProblem
        case .linear:
            return linearProblem
        case .workflow:
            return workflowCheck.saveProblem(landing: landing, landed: landedWorkflow != nil, draft: workflowText)
        case .review:
            if let problem = AddRepo.keyProblem(draft.key, existing: existing.map(\.key)) { return problem }
            if let problem = AddRepo.baseBranchProblem(draft.baseBranch) { return problem }
            if case let .failure(problem) = entry { return problem }
            return nil
        case .check, .instantUpdates:
            return nil
        }
    }

    /// The entry Connect writes, or the first thing any step says stops it.
    public var entry: Result<RepositoryEntry, AddRepoProblem> {
        for step in steps where step.order < AddRepoStep.review.order {
            if let problem = problem(at: step) { return .failure(problem) }
        }
        return AddRepo.entry(for: draft, existing: existing)
    }

    private var hasNoWorkflow: Bool {
        if case .missing = workflowCheck { return true }
        return false
    }

    // MARK: Source

    private var sourceProblem: AddRepoProblem? {
        if draft.mode == .localFolder, inspectingFolder { return AddRepoProblem("Checking the folder…") }
        if case let .failure(problem) = AddRepo.source(of: draft) { return problem }
        if workflowCheck == .checking { return AddRepoProblem("Checking the repo for a WORKFLOW.md…") }
        return nil
    }

    /// What the Source page shows under the source, nil while there is nothing to say.
    public var sourceResult: AddRepoSourceResult? {
        if draft.mode == .localFolder, inspectingFolder { return AddRepoSourceResult("Checking the folder…", style: .checking) }
        let gitHub: String
        switch AddRepo.source(of: draft) {
        case let .failure(problem):
            switch draft.mode {
            case .gitHub:
                // A half-typed URL: the hint shows once there is text, and only the folder's reasons are red.
                guard !draft.gitHubInput.trimmingWhitespace().isEmpty else { return nil }
                return AddRepoSourceResult(problem.message, style: .note)
            case .localFolder:
                return draft.folder == nil ? nil : AddRepoSourceResult(problem.message, style: .problem)
            }
        case .success:
            gitHub = draft.gitHub ?? ""
        }
        var parts = [gitHub]
        if draft.mode == .localFolder, case let .success(checkout)? = draft.folder {
            parts.insert((checkout.path as NSString).abbreviatingWithTildeInPath, at: 0)
        }
        if let defaultBranch { parts.append("default branch \(defaultBranch)") }
        switch workflowCheck {
        case .checking:
            return AddRepoSourceResult("Checking \(gitHub) for a WORKFLOW.md…", style: .checking)
        case .present:
            parts.append("has WORKFLOW.md")
        case let .missing(_, branch):
            let place = branch.map { " on \($0)" } ?? ""
            guard editing else {
                parts.append("No WORKFLOW.md\(place): you can set one up in a later step")
                break
            }
            // The Source sheet refuses a folder without one, and can't draft one.
            if draft.mode == .localFolder, case let .success(checkout)? = draft.folder {
                return AddRepoSourceResult(checkout.missingWorkflowProblem.message, style: .problem)
            }
            parts.append("No WORKFLOW.md\(place): Symphony runs no agents on it until one is added")
            return AddRepoSourceResult(parts.joined(separator: " · "), style: .note)
        case let .failed(message):
            parts.append(message)
            return AddRepoSourceResult(parts.joined(separator: " · "), style: .note)
        case .idle:
            break
        }
        return AddRepoSourceResult(parts.joined(separator: " · "), style: .found)
    }

    // MARK: Linear

    private var linearProblem: AddRepoProblem? {
        switch projects {
        case .loading:
            return AddRepoProblem("Loading projects from Linear…")
        case let .failed(message):
            return AddRepoProblem(message)
        case .loaded:
            break
        }
        guard let route = AddRepo.route(of: draft) else {
            return AddRepoProblem("Pick the Linear project whose issues go to this repo.")
        }
        if labels == .loading { return AddRepoProblem("Loading the project's labels…") }
        return AddRepo.twinProblem(route, existing: existing)
    }

    /// The rows of the Linear page. The pickers and the preview stay in place whatever Linear answers.
    public var linearRows: [LinearRow] {
        var rows: [LinearRow] = [.project, .labels]
        if let route = AddRepo.route(of: draft), let twin = AddRepo.twinProblem(route, existing: existing) {
            rows.append(.twin(twin.message))
        }
        rows.append(.preview)
        if case let .failed(message) = projects {
            rows.append(.warning(message))
        } else if case let .failed(message) = labels {
            rows.append(.warning(message))
        }
        return rows
    }

    /// Whether a project can be picked: once Linear listed them.
    public var canPickProject: Bool {
        projects == .loaded
    }

    /// What the project pop-up shows while no project is picked.
    public var projectPlaceholder: String {
        switch projects {
        case .loading:
            return "Loading projects…"
        case .failed:
            return "No projects"
        case .loaded:
            return "Choose a project…"
        }
    }

    /// Whether labels can be typed: once the picked project's labels are listed.
    public var canPickLabels: Bool {
        projects == .loaded && draft.project != nil && labels == .loaded
    }

    /// What the empty label field shows.
    public var labelsPlaceholder: String {
        if labels == .loading { return "Loading labels…" }
        if projects != .loaded || draft.project == nil { return "Pick a project to list its labels" }
        if labels != .loaded { return "Labels couldn't be listed" }
        return "Optional: issues must carry all of them"
    }

    /// "Issues in Billing with label backend go to billing-api.", updated as the route and key change.
    public var routePreview: String {
        guard let route = AddRepo.route(of: draft), let project = draft.project?.trimmingWhitespace() else {
            return "Pick a project: its issues go to this repo."
        }
        let key = draft.key.trimmingWhitespace()
        let target = key.isEmpty ? "this repo" : key
        let labels = route.labels ?? []
        switch labels.count {
        case 0:
            return "Issues in \(project) go to \(target)."
        case 1:
            return "Issues in \(project) with label \(labels[0]) go to \(target)."
        default:
            let list = labels.dropLast().joined(separator: ", ") + " and " + (labels.last ?? "")
            return "Issues in \(project) with labels \(list) go to \(target)."
        }
    }

    // MARK: Review

    /// The Review page's Source line.
    public var sourceSummary: String {
        switch draft.mode {
        case .gitHub:
            return "\(draft.gitHub ?? "") on GitHub. Symphony keeps its own clone."
        case .localFolder:
            guard case let .success(checkout)? = draft.folder else { return "" }
            let path = (checkout.path as NSString).abbreviatingWithTildeInPath
            return "\(path) (\(checkout.gitHub)). Agents work in worktrees of it."
        }
    }

    /// The Review page's Route line: what Connect writes, the project by its ID and its team, as
    /// "Project ID 8e6f0c39-… · team TP".
    public var routeWritten: String {
        guard let route = AddRepo.route(of: draft), let project = route.projects?.first else { return "" }
        let id = draft.projectID?.trimmingWhitespace() ?? ""
        let projectPart = id.isEmpty ? "Project \(project), by name: Linear didn't give its ID" : "Project ID \(id)"
        guard let team = route.team else { return "\(projectPart) · no team: the project isn't in exactly one team" }
        return "\(projectPart) · team \(team)"
    }

    /// The Review page's WORKFLOW.md line: what Connect does about the file.
    public var workflowSummary: String {
        if let landedWorkflow { return landedWorkflow.savedSentence }
        let baseBranch = draft.baseBranch.trimmingWhitespace()
        switch workflowCheck {
        case .present:
            return "The repo has one."
        case .missing:
            switch landing {
            case .pullRequest:
                return "Connect opens a pull request against \(baseBranch) that adds it."
            case .localFile:
                guard case let .success(checkout)? = draft.folder else { return "" }
                return "Connect writes it into \((checkout.path as NSString).abbreviatingWithTildeInPath), uncommitted."
            case .skip:
                return "None for now: the repo shows WORKFLOW.md as missing until one is added."
            }
        case let .failed(message):
            return "Not checked. \(message)"
        case .checking:
            return "Checking the repo for a WORKFLOW.md…"
        case .idle:
            return ""
        }
    }

    /// "notes-app becomes the default repo, …" when adding this repo makes the only one the default.
    public var defaultLine: String? {
        AddRepo.madeDefault(existing: existing).map {
            "\($0) becomes the default repo, so it keeps the issues no route matches."
        }
    }
}

extension AddRepo {
    /// What happens once Connect writes the repo, for how it reaches Symphony.
    public static func nextLine(apply: AddRepoApply) -> String {
        switch apply {
        case .restart:
            return "Symphony restarts to connect it."
        case let .askToRestart(runs):
            return "\(activeRuns(runs)) The app asks to restart Symphony after \(runs == 1 ? "it finishes" : "they finish")."
        case .onNextStart:
            return "Symphony isn't running: it connects the repo when it starts."
        case .restartManually:
            return "Restart Symphony by hand to connect it: the app can't restart it now."
        }
    }
}
