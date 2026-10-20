import XCTest
@testable import SymphonyBarCore

/// SU11, the Add Repo sheet's Check setup step (TP-911).
final class AddRepoSetupCheckTests: XCTestCase {
    private let route = RepositoryRoute(team: "TP", projects: ["8e6f0c39"])

    private func problem(_ id: String, _ severity: SetupPayload.Severity, repos: [String] = ["web"]) -> SetupPayload.Problem {
        SetupPayload.Problem(id: id, severity: severity, category: "labels", title: id, consequence: "", repos: repos)
    }

    private func check(_ phase: AddRepoSetupCheck.Phase) -> AddRepoSetupCheck {
        AddRepoSetupCheck(key: "web", route: route, phase: phase)
    }

    func testTheStepStartsCheckingUnlessSymphonyIsStopped() {
        for apply in [AddRepoApply.restart, .askToRestart(runs: 2), .restartManually] {
            XCTAssertEqual(AddRepoSetupCheck(key: "web", route: route, apply: apply).phase, .checking, "\(apply)")
        }
        XCTAssertEqual(AddRepoSetupCheck(key: "web", route: route, apply: .onNextStart).phase, .onNextStart)
    }

    /// The acceptance criterion: Done is off while checking and while the repo has an error; on with warnings only and
    /// while Symphony isn't running.
    func testDoneWaitsForTheCheckAndForNoErrors() {
        let checking = check(.checking)
        XCTAssertFalse(checking.canFinish)
        XCTAssertEqual(checking.headline, "Checking setup for web…")
        XCTAssertEqual(checking.doneProblem, "Done is available once Symphony has checked web.")
        XCTAssertNil(checking.page())
        XCTAssertFalse(checking.offersCheckAgain)
        XCTAssertFalse(checking.offersStart)

        let error = check(.checked(SetupPayload(problems: [problem("labels:missing:TP:Blocked", .error), problem("key", .warning, repos: [])])))
        XCTAssertFalse(error.canFinish)
        XCTAssertEqual(error.doneProblem, "Done is available once there are no errors.")
        XCTAssertEqual(AddRepoSetupCheck.doneBlocked, "Done is available once there are no errors.")
        XCTAssertEqual(error.headline, "Setup has 1 error and 1 warning for web.")
        XCTAssertEqual(error.detail, "Fix each error here, or close the sheet: web stays saved and its errors stay on the Setup page.")
        XCTAssertEqual(error.page()?.errors.flatMap(\.rows).map(\.id), ["labels:missing:TP:Blocked"])
        XCTAssertEqual(error.page()?.errors.first?.rows.first?.actionTitle, nil)
        XCTAssertEqual(error.written, [])
        XCTAssertTrue(error.offersCheckAgain)

        let warnings = check(.checked(SetupPayload(problems: [problem("uncloned_repo:web", .warning)])))
        XCTAssertTrue(warnings.canFinish)
        XCTAssertNil(warnings.doneProblem)
        XCTAssertEqual(warnings.headline, "Setup has 1 warning for web.")
        XCTAssertEqual(warnings.detail, "Warnings don't stop web from taking tickets.")
        XCTAssertEqual(warnings.page()?.warnings.flatMap(\.rows).map(\.id), ["uncloned_repo:web"])

        let stopped = check(.onNextStart)
        XCTAssertTrue(stopped.canFinish)
        XCTAssertNil(stopped.doneProblem)
        XCTAssertTrue(stopped.offersStart)
        XCTAssertEqual(stopped.headline, "Symphony isn't running, so it checks web when it starts.")
        XCTAssertEqual(stopped.detail, "If something is wrong then, the Setup page opens. Start Symphony now, or later from the menu bar.")
        XCTAssertEqual(stopped.written, [])
    }

    func testACheckThatFailedKeepsDoneOffAndOffersCheckAgain() {
        let failed = check(.failed("Couldn't check the setup again: nothing answered at http://127.0.0.1:4000."))
        XCTAssertFalse(failed.canFinish)
        XCTAssertEqual(failed.headline, "Couldn't check setup for web.")
        XCTAssertEqual(failed.detail, "Couldn't check the setup again: nothing answered at http://127.0.0.1:4000.")
        XCTAssertEqual(failed.doneProblem, "Done is available once Symphony has checked web. Check again, or close: web stays saved.")
        XCTAssertTrue(failed.offersCheckAgain)
        XCTAssertNil(failed.payload)
    }

    /// With no error left, the step shows what Connect wrote: the project by its ID and the team.
    func testNoErrorShowsTheRouteWritten() {
        let healthy = check(.checked(SetupPayload()))
        XCTAssertTrue(healthy.canFinish)
        XCTAssertEqual(healthy.headline, "web is set up right.")
        XCTAssertNil(healthy.detail)
        XCTAssertEqual(healthy.written, [
            SetupPayload.Detail(label: "Project", value: "8e6f0c39"),
            SetupPayload.Detail(label: "Team", value: "TP"),
        ])

        var labelled = healthy
        labelled.route = RepositoryRoute(projects: ["8e6f0c39"], labels: ["api", "web"])
        XCTAssertEqual(labelled.written, [
            SetupPayload.Detail(label: "Project", value: "8e6f0c39"),
            SetupPayload.Detail(label: "Team", value: "Not set: the project isn't in exactly one team"),
            SetupPayload.Detail(label: "Labels", value: "api, web"),
        ])
        labelled.route.labels = ["api"]
        XCTAssertEqual(labelled.written.last, SetupPayload.Detail(label: "Label", value: "api"))
    }

    /// The step lists the repo's problems and the global ones, whatever Symphony sent.
    func testThePayloadKeepsTheReposProblemsAndTheGlobalOnes() {
        let payload = SetupPayload(problems: [problem("mine", .error), problem("theirs", .error, repos: ["api"]), problem("global", .warning, repos: [])])
        XCTAssertEqual(payload.forRepo("web").problems.map(\.id), ["mine", "global"])
        XCTAssertEqual(payload.forRepo("api").problems.map(\.id), ["theirs", "global"])
    }
}
