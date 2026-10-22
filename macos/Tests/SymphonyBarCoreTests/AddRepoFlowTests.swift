import XCTest
@testable import SymphonyBarCore

final class AddRepoFlowTests: XCTestCase {
    private let checkout = LocalCheckout(path: "/Users/me/code/web", gitHub: "acme/web", hasWorkflow: false, defaultBranch: "main")
    private let api = RepositoryEntry(key: "api", route: RepositoryRoute(projects: ["Web"], labels: ["api"]))

    /// A GitHub repo with a `WORKFLOW.md`, a key, a project and labels: every step lets it through.
    private var ready: AddRepoFlow {
        AddRepoFlow(
            draft: AddRepoDraft(gitHubInput: "acme/web", key: "web", project: "Web", labels: ["frontend"]),
            existing: [api],
            defaultBranch: "main",
            workflowCheck: .present
        )
    }

    private func problems(_ flow: AddRepoFlow) -> [AddRepoStep: String] {
        Dictionary(uniqueKeysWithValues: flow.steps.compactMap { step in flow.problem(at: step).map { (step, $0.message) } })
    }

    // MARK: Steps

    func testTheWorkflowStepShowsOnlyForARepoWithoutOne() {
        var flow = ready
        XCTAssertEqual(flow.steps, [.source, .linear, .review, .check])
        XCTAssertEqual(flow.step(after: .source), .linear)
        XCTAssertEqual(flow.step(after: .linear), .review)
        XCTAssertEqual(flow.step(before: .review), .linear)

        flow.workflowCheck = .missing(WorkflowStack(), branch: "main")
        XCTAssertEqual(flow.steps, [.source, .linear, .workflow, .review, .check])
        XCTAssertEqual(flow.step(after: .linear), .workflow)
        XCTAssertEqual(flow.step(after: .workflow), .review)
        XCTAssertEqual(flow.step(before: .review), .workflow)
        XCTAssertEqual(flow.step(before: .workflow), .linear)
        XCTAssertNil(flow.step(before: .source))
        XCTAssertNil(flow.step(after: .review))

        for check in [WorkflowCheck.idle, .checking, .failed("gh is missing")] {
            flow.workflowCheck = check
            XCTAssertEqual(flow.steps, [.source, .linear, .review, .check], "\(check)")
        }
        // A step that is gone still leads on, as when the base branch changes on Review.
        XCTAssertEqual(flow.step(after: .workflow), .review)
        XCTAssertEqual(flow.step(before: .workflow), .linear)
    }

    /// SU11: Connect saves on Review and goes on to Check setup, which has no way back or on, and nothing to stop.
    func testCheckSetupComesAfterConnectWithNoWayBack() {
        let flow = ready
        XCTAssertNil(flow.step(after: .review))
        XCTAssertNil(flow.step(after: .check))
        XCTAssertNil(flow.step(before: .check))
        XCTAssertNil(flow.problem(at: .check))
        XCTAssertEqual(AddRepoStep.check.rawValue, "Check setup")
    }

    /// The step indicator's three fits, on Review of the six steps a repo without a WORKFLOW.md has while instant updates
    /// are on. A name is never cut: a step shows by name, or by its tick or number alone.
    func testTheStepIndicatorShowsLessOfEachStepAsItFitsLess() {
        let six: [AddRepoStep] = [.source, .linear, .workflow, .review, .check, .instantUpdates]
        func marks(_ fit: AddRepoStepIndicatorFit) -> [String] {
            fit.marks(six, current: .review).map { mark in
                [mark.isDone ? "✓" : nil, mark.number.map(String.init), mark.name].compactMap { $0 }.joined(separator: " ")
                    + (mark.isCurrent ? "*" : "")
            }
        }

        XCTAssertEqual(AddRepoStepIndicatorFit.allCases, [.full, .compact, .currentOnly])
        XCTAssertEqual(marks(.full), ["✓ Source", "✓ Linear", "✓ WORKFLOW.md", "4 Review*", "5 Check setup", "6 Instant updates"])
        XCTAssertEqual(marks(.compact), ["✓", "✓", "✓", "Review*", "Check setup", "Instant updates"])
        XCTAssertEqual(marks(.currentOnly), ["✓", "✓", "✓", "4 Review*", "5", "6"])

        // On the first page nothing is done; on the last, everything before it is.
        XCTAssertEqual(AddRepoStepIndicatorFit.compact.marks(six, current: .source).map(\.name), six.map(\.rawValue))
        XCTAssertEqual(
            AddRepoStepIndicatorFit.compact.marks(six, current: .instantUpdates).map(\.name),
            [nil, nil, nil, nil, nil, "Instant updates"]
        )
        XCTAssertEqual(
            AddRepoStepIndicatorFit.full.marks([.source, .linear], current: .source),
            [AddRepoStepMark(step: .source, isCurrent: true, number: 1, name: "Source"), AddRepoStepMark(step: .linear, number: 2, name: "Linear")]
        )
    }

    func testAReadyDraftPassesEveryStep() {
        XCTAssertEqual(problems(ready), [:])
        XCTAssertEqual(ready.entry, .success(RepositoryEntry(
            key: "web",
            baseBranch: "main",
            route: RepositoryRoute(projects: ["Web"], labels: ["frontend"]),
            workspace: RepositoryWorkspace(source: "acme/web")
        )))
    }

    // MARK: Source

    func testSourceContinue() {
        func problem(_ change: (inout AddRepoFlow) -> Void) -> String? {
            var flow = ready
            change(&flow)
            return flow.problem(at: .source)?.message
        }

        XCTAssertNil(problem { _ in })
        XCTAssertEqual(problem { $0.draft.gitHubInput = "" }, "Paste a GitHub repo URL or owner/repo.")
        XCTAssertEqual(
            problem { $0.draft.gitHubInput = "acme" },
            "Use a GitHub repo as https://github.com/owner/repo, git@github.com:owner/repo.git or owner/repo."
        )
        XCTAssertEqual(problem { $0.workflowCheck = .checking }, "Checking the repo for a WORKFLOW.md…")
        // A repo gh couldn't check still connects, as it is.
        XCTAssertNil(problem { $0.workflowCheck = .failed("Couldn't find the GitHub CLI (gh).") })
        XCTAssertNil(problem { $0.workflowCheck = .missing(WorkflowStack(), branch: "main") })

        XCTAssertEqual(problem { $0.draft.mode = .localFolder }, "Choose the folder of a git checkout.")
        XCTAssertEqual(problem { $0.draft.mode = .localFolder; $0.inspectingFolder = true }, "Checking the folder…")
        XCTAssertEqual(
            problem { $0.draft.mode = .localFolder; $0.draft.folder = .failure(AddRepoProblem("~/notes isn't a git checkout.")) },
            "~/notes isn't a git checkout."
        )
        XCTAssertNil(problem { $0.draft.mode = .localFolder; $0.draft.folder = .success(checkout) })
        // Only a folder is being inspected: a GitHub URL doesn't wait for it.
        XCTAssertNil(problem { $0.inspectingFolder = true })
    }

    func testSourceResultRow() {
        var flow = ready
        XCTAssertEqual(flow.sourceResult, AddRepoSourceResult("acme/web · default branch main · has WORKFLOW.md", style: .found))

        flow.workflowCheck = .missing(WorkflowStack(), branch: "main")
        XCTAssertEqual(flow.sourceResult, AddRepoSourceResult(
            "acme/web · default branch main · No WORKFLOW.md on main: you can set one up in a later step",
            style: .found
        ))
        flow.workflowCheck = .checking
        XCTAssertEqual(flow.sourceResult, AddRepoSourceResult("Checking acme/web for a WORKFLOW.md…", style: .checking))
        flow.workflowCheck = .failed("gh isn't logged in.")
        flow.defaultBranch = nil
        XCTAssertEqual(flow.sourceResult, AddRepoSourceResult("acme/web · gh isn't logged in.", style: .note))

        flow.draft.gitHubInput = ""
        XCTAssertNil(flow.sourceResult)
        flow.draft.gitHubInput = "acme"
        XCTAssertEqual(flow.sourceResult?.style, .note)

        flow.draft.mode = .localFolder
        XCTAssertNil(flow.sourceResult)
        flow.inspectingFolder = true
        XCTAssertEqual(flow.sourceResult, AddRepoSourceResult("Checking the folder…", style: .checking))
        flow.inspectingFolder = false
        flow.draft.folder = .failure(AddRepoProblem("~/notes isn't a git checkout."))
        XCTAssertEqual(flow.sourceResult, AddRepoSourceResult("~/notes isn't a git checkout.", style: .problem))
        flow.draft.folder = .success(checkout)
        flow.defaultBranch = "main"
        flow.workflowCheck = .missing(WorkflowStack(), branch: nil)
        XCTAssertEqual(flow.sourceResult, AddRepoSourceResult(
            "/Users/me/code/web · acme/web · default branch main · No WORKFLOW.md: you can set one up in a later step",
            style: .found
        ))
        flow.workflowCheck = .idle
        XCTAssertEqual(flow.sourceResult, AddRepoSourceResult("/Users/me/code/web · acme/web · default branch main", style: .found))
    }

    /// The Source sheet of a connected repo has no WORKFLOW.md step: it refuses a folder without one.
    func testSourceResultRowWhileEditing() {
        var flow = ready
        flow.editing = true
        flow.workflowCheck = .missing(WorkflowStack(), branch: "main")
        XCTAssertEqual(flow.sourceResult, AddRepoSourceResult(
            "acme/web · default branch main · No WORKFLOW.md on main: Symphony runs no agents on it until one is added",
            style: .note
        ))
        flow.draft.mode = .localFolder
        flow.draft.folder = .success(LocalCheckout(path: "/Users/me/code/web", gitHub: "acme/web", hasWorkflow: false))
        XCTAssertEqual(flow.sourceResult, AddRepoSourceResult(
            "/Users/me/code/web has no WORKFLOW.md. Add one before connecting the repo.",
            style: .problem
        ))
        flow.workflowCheck = .present
        flow.draft.folder = .success(checkout)
        XCTAssertEqual(flow.sourceResult, AddRepoSourceResult(
            "/Users/me/code/web · acme/web · default branch main · has WORKFLOW.md",
            style: .found
        ))
    }

    // MARK: Linear

    func testLinearContinue() {
        func problem(_ change: (inout AddRepoFlow) -> Void) -> String? {
            var flow = ready
            change(&flow)
            return flow.problem(at: .linear)?.message
        }

        XCTAssertNil(problem { _ in })
        XCTAssertEqual(problem { $0.projects = .loading }, "Loading projects from Linear…")
        XCTAssertEqual(problem { $0.projects = .failed("Linear rejected the API key.") }, "Linear rejected the API key.")
        XCTAssertEqual(problem { $0.draft.project = nil }, "Pick the Linear project whose issues go to this repo.")
        XCTAssertEqual(problem { $0.draft.project = " " }, "Pick the Linear project whose issues go to this repo.")
        XCTAssertEqual(problem { $0.labels = .loading }, "Loading the project's labels…")
        // Labels that failed to load leave the route without labels, which is allowed.
        XCTAssertNil(problem { $0.labels = .failed("Network error") })
        XCTAssertEqual(
            problem { $0.draft.labels = ["api"] },
            "`api` already takes the issues of this project and labels. Pick other labels or another project."
        )
    }

    func testALinearFailureKeepsThePickersInPlace() {
        var flow = ready
        XCTAssertEqual(flow.linearRows, [.project, .labels, .preview])
        XCTAssertTrue(flow.canPickProject)
        XCTAssertTrue(flow.canPickLabels)

        flow.projects = .loading
        XCTAssertEqual(flow.linearRows, [.project, .labels, .preview])
        XCTAssertEqual(flow.projectPlaceholder, "Loading projects…")
        XCTAssertFalse(flow.canPickProject)

        for message in ["Linear rejected the API key.", "Linear lists no projects for this key.", "Query too complex"] {
            flow.projects = .failed(message)
            XCTAssertEqual(flow.linearRows, [.project, .labels, .preview, .warning(message)])
            XCTAssertEqual(flow.projectPlaceholder, "No projects")
            XCTAssertFalse(flow.canPickProject)
            XCTAssertFalse(flow.canPickLabels)
            XCTAssertEqual(flow.labelsPlaceholder, "Pick a project to list its labels")
        }

        flow.projects = .loaded
        flow.labels = .failed("Network error")
        XCTAssertEqual(flow.linearRows, [.project, .labels, .preview, .warning("Network error")])
        XCTAssertEqual(flow.labelsPlaceholder, "Labels couldn't be listed")

        flow.labels = .loaded
        flow.draft.labels = ["api"]
        XCTAssertEqual(flow.linearRows, [
            .project,
            .labels,
            .twin("`api` already takes the issues of this project and labels. Pick other labels or another project."),
            .preview,
        ])
    }

    func testPickerPlaceholders() {
        var flow = ready
        XCTAssertEqual(flow.projectPlaceholder, "Choose a project…")
        XCTAssertEqual(flow.labelsPlaceholder, "Optional: issues must carry all of them")
        flow.labels = .loading
        XCTAssertEqual(flow.labelsPlaceholder, "Loading labels…")
        XCTAssertFalse(flow.canPickLabels)
        flow.labels = .loaded
        flow.draft.project = nil
        XCTAssertEqual(flow.labelsPlaceholder, "Pick a project to list its labels")
        XCTAssertFalse(flow.canPickLabels)
    }

    func testRoutePreview() {
        var flow = ready
        XCTAssertEqual(flow.routePreview, "Issues in Web with label frontend go to web.")
        flow.draft.labels = []
        XCTAssertEqual(flow.routePreview, "Issues in Web go to web.")
        flow.draft.labels = ["a", " ", "b", "c"]
        XCTAssertEqual(flow.routePreview, "Issues in Web with labels a, b and c go to web.")
        flow.draft.labels = ["a", "b"]
        XCTAssertEqual(flow.routePreview, "Issues in Web with labels a and b go to web.")
        flow.draft.key = " "
        XCTAssertEqual(flow.routePreview, "Issues in Web with labels a and b go to this repo.")
        flow.draft.project = nil
        XCTAssertEqual(flow.routePreview, "Pick a project: its issues go to this repo.")
    }

    /// The preview names the project; the Review's Route line says what Connect writes: the project's ID and its team.
    func testRouteWrittenNamesTheProjectIDAndTeam() {
        var flow = ready
        flow.draft.projectID = "8e6f0c39"
        flow.draft.team = "TP"
        XCTAssertEqual(flow.routePreview, "Issues in Web with label frontend go to web.")
        XCTAssertEqual(flow.routeWritten, "Project ID 8e6f0c39 · team TP")
        flow.draft.team = nil
        XCTAssertEqual(flow.routeWritten, "Project ID 8e6f0c39 · no team: the project isn't in exactly one team")
        flow.draft.projectID = nil
        XCTAssertEqual(flow.routeWritten, "Project Web, by name: Linear didn't give its ID · no team: the project isn't in exactly one team")
        flow.draft.project = nil
        XCTAssertEqual(flow.routeWritten, "")
    }

    // MARK: WORKFLOW.md

    func testWorkflowContinue() {
        var flow = ready
        flow.workflowCheck = .missing(WorkflowStack(), branch: "main")
        flow.workflowText = "---\n---\n"
        XCTAssertNil(flow.problem(at: .workflow))

        flow.workflowText = " \n"
        XCTAssertEqual(
            flow.problem(at: .workflow)?.message,
            "The WORKFLOW.md draft is empty. Write one, or pick \"Don't create one now\"."
        )
        flow.landing = .skip
        XCTAssertNil(flow.problem(at: .workflow))
        flow.landing = .pullRequest
        flow.landedWorkflow = .pullRequest(url: "https://github.com/acme/web/pull/7")
        XCTAssertNil(flow.problem(at: .workflow))
    }

    // MARK: Review

    func testReviewConnect() {
        func problem(_ change: (inout AddRepoFlow) -> Void) -> String? {
            var flow = ready
            change(&flow)
            return flow.problem(at: .review)?.message
        }

        XCTAssertNil(problem { _ in })
        XCTAssertEqual(problem { $0.draft.key = "api" }, "A repo with key `api` already exists.")
        XCTAssertEqual(problem { $0.draft.key = "API" }, "A repo with key `API` already exists.")
        XCTAssertEqual(problem { $0.draft.key = "" }, "Enter a repo key.")
        XCTAssertEqual(problem { $0.draft.baseBranch = " " }, "Enter a base branch, such as main.")
        // A base branch changed on Review checks the repo again; Connect waits for it.
        XCTAssertEqual(problem { $0.workflowCheck = .checking }, "Checking the repo for a WORKFLOW.md…")
        XCTAssertEqual(problem { $0.projects = .loading }, "Loading projects from Linear…")
        XCTAssertEqual(
            problem { $0.workflowCheck = .missing(WorkflowStack(), branch: "main") },
            "The WORKFLOW.md draft is empty. Write one, or pick \"Don't create one now\"."
        )
    }

    func testReviewSummary() {
        var flow = ready
        XCTAssertEqual(flow.sourceSummary, "acme/web on GitHub. Symphony keeps its own clone.")
        XCTAssertEqual(flow.workflowSummary, "The repo has one.")

        flow.workflowCheck = .missing(WorkflowStack(), branch: "main")
        XCTAssertEqual(flow.workflowSummary, "Connect opens a pull request against main that adds it.")
        flow.landing = .skip
        XCTAssertEqual(flow.workflowSummary, "None for now: the repo shows WORKFLOW.md as missing until one is added.")
        flow.landedWorkflow = .pullRequest(url: "https://github.com/acme/web/pull/7")
        XCTAssertEqual(flow.workflowSummary, PendingWorkflow.pullRequest(url: "https://github.com/acme/web/pull/7").savedSentence)
        flow.landedWorkflow = nil

        flow.draft.mode = .localFolder
        flow.draft.folder = .success(checkout)
        flow.landing = .localFile
        XCTAssertEqual(flow.sourceSummary, "/Users/me/code/web (acme/web). Agents work in worktrees of it.")
        XCTAssertEqual(flow.workflowSummary, "Connect writes it into /Users/me/code/web, uncommitted.")
        flow.draft.folder = nil
        XCTAssertEqual(flow.sourceSummary, "")
        XCTAssertEqual(flow.workflowSummary, "")

        flow.workflowCheck = .failed("gh isn't logged in.")
        XCTAssertEqual(flow.workflowSummary, "Not checked. gh isn't logged in.")
        flow.workflowCheck = .checking
        XCTAssertEqual(flow.workflowSummary, "Checking the repo for a WORKFLOW.md…")
        flow.workflowCheck = .idle
        XCTAssertEqual(flow.workflowSummary, "")
    }

    func testDefaultLine() {
        var flow = ready
        XCTAssertNil(flow.defaultLine)
        flow.existing = [RepositoryEntry(key: "notes-app")]
        XCTAssertEqual(flow.defaultLine, "notes-app becomes the default repo, so it keeps the issues no route matches.")
        flow.existing = [RepositoryEntry(key: "notes-app", isDefault: true)]
        XCTAssertNil(flow.defaultLine)
        flow.existing = []
        XCTAssertNil(flow.defaultLine)
    }

    func testNextLine() {
        XCTAssertEqual(AddRepo.nextLine(apply: .restart), "Symphony restarts to connect it.")
        XCTAssertEqual(
            AddRepo.nextLine(apply: .askToRestart(runs: 1)),
            "1 agent run is active. The app asks to restart Symphony after it finishes."
        )
        XCTAssertEqual(
            AddRepo.nextLine(apply: .askToRestart(runs: 2)),
            "2 agent runs are active. The app asks to restart Symphony after they finish."
        )
        XCTAssertEqual(AddRepo.nextLine(apply: .onNextStart), "Symphony isn't running: it connects the repo when it starts.")
        XCTAssertEqual(AddRepo.nextLine(apply: .restartManually), "Restart Symphony by hand to connect it: the app can't restart it now.")
    }
}
