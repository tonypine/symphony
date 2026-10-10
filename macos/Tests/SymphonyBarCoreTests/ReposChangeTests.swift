import XCTest
@testable import SymphonyBarCore

final class ReposChangeTests: XCTestCase {
    private let began = Date(timeIntervalSince1970: 1_000_000)
    private let runsTimeout: TimeInterval = 30 * 60

    // MARK: Banners

    func testAddedEditedAndDisconnectedBannersSayWhatTheChangeDid() {
        let cases: [(ReposChange, ReposBanner)] = [
            (
                .added(key: "billing", apply: .onNextStart, madeDefault: nil),
                ReposBanner(key: "billing", text: "Added billing. Symphony connects it when it starts.")
            ),
            (
                .added(key: "billing", apply: .restart, madeDefault: "billing"),
                ReposBanner(
                    key: "billing",
                    text: "Added billing. Symphony restarts to connect it. billing is now the default repo, so it keeps "
                        + "the issues no route matches."
                )
            ),
            (
                .added(key: "web", apply: .onNextStart, madeDefault: nil, workflow: .pullRequest(url: "https://github.com/acme/web/pull/7")),
                ReposBanner(
                    key: "web",
                    text: "Added web. Symphony connects it when it starts. Opened https://github.com/acme/web/pull/7 to add its "
                        + "WORKFLOW.md."
                )
            ),
            (
                .edited(key: "api", apply: nil),
                ReposBanner(key: "api", text: "Saved api. Symphony reads the change from symphony.yml, so its next poll uses it.")
            ),
            (
                .edited(key: "api", apply: .onNextStart),
                ReposBanner(key: "api", text: EditRepo.savedMessage(key: "api", apply: .onNextStart))
            ),
            (
                .disconnected(key: "billing", apply: .onNextStart, newDefault: nil, next: "api"),
                ReposBanner(key: "api", text: "Disconnected billing.")
            ),
            (
                .disconnected(key: "billing", apply: .restartManually, newDefault: "api", next: "api"),
                ReposBanner(key: "api", text: "Disconnected billing. Restart Symphony to drop it. api is now the default repo.")
            ),
        ]
        for (change, banner) in cases {
            XCTAssertEqual(change.banner, banner, "\(change)")
        }
    }

    func testCloneBannersAndWriteErrors() {
        XCTAssertEqual(
            ReposChange.cloneRemoved(key: "api", path: "/var/clones/api").banner,
            ReposBanner(key: "api", text: "Removed Symphony's clone of api at /var/clones/api.")
        )
        XCTAssertEqual(
            ReposChange.cloneKept(key: "api", reason: "TP-7 runs on it").banner,
            ReposBanner(key: "api", text: "Didn't remove the clone: TP-7 runs on it", style: .error)
        )
        let errors: [(String?, String)] = [
            ("api", "Couldn't save symphony.yml: disk full"),
            ("api", "Couldn't disconnect api: disk full"),
            ("api", "Couldn't remove the clone: permission denied"),
            (nil, "symphony.yml can't be read"),
        ]
        for (key, message) in errors {
            let change = ReposChange.failed(key: key, message: message)
            XCTAssertEqual(change.banner, ReposBanner(key: key, text: message, style: .error))
            XCTAssertEqual(change.laterBanner, change.banner)
        }
        let removed = ReposChange.cloneRemoved(key: "api", path: "/c")
        XCTAssertEqual(removed.laterBanner, removed.banner)
        let kept = ReposChange.cloneKept(key: "api", reason: "busy")
        XCTAssertEqual(kept.laterBanner, kept.banner)
    }

    func testLaterBannersSayToRestartFromTheMenu() {
        XCTAssertEqual(
            ReposChange.added(key: "billing", apply: .askToRestart(runs: 1), madeDefault: nil).laterBanner,
            ReposBanner(key: "billing", text: "Added billing. Restart Symphony from the menu to connect it.")
        )
        XCTAssertEqual(
            ReposChange.edited(key: "api", apply: .askToRestart(runs: 2)).laterBanner,
            ReposBanner(key: "api", text: "Saved api. Restart Symphony from the menu to apply it.")
        )
        XCTAssertEqual(
            ReposChange.disconnected(key: "billing", apply: .askToRestart(runs: 1), newDefault: nil, next: "api").laterBanner,
            ReposBanner(key: "api", text: "Disconnected billing. Restart Symphony from the menu to drop it.")
        )
    }

    func testTheBannerShowsOnItsRepoAndSurvivesAPollThatDoesntListIt() {
        let banner = ReposBanner(key: "billing", text: "Added billing.")
        XCTAssertTrue(banner.isShown(on: "billing", listed: ["api", "billing"]))
        XCTAssertFalse(banner.isShown(on: "api", listed: ["api", "billing"]))
        // A running Symphony lists only the repos it started with, until it restarts.
        XCTAssertTrue(banner.isShown(on: "api", listed: ["api"]))
        XCTAssertTrue(ReposBanner(key: nil, text: "x", style: .error).isShown(on: "api", listed: ["api"]))
        XCTAssertTrue(ReposBanner(key: nil, text: "x").isShown(on: nil, listed: []))
    }

    func testDisconnectSelectsTheNextRepoElseThePreviousOne() {
        XCTAssertEqual(DisconnectRepo.nextSelection(after: "a", in: ["a", "b", "c"]), "b")
        XCTAssertEqual(DisconnectRepo.nextSelection(after: "b", in: ["a", "b", "c"]), "c")
        XCTAssertEqual(DisconnectRepo.nextSelection(after: "c", in: ["a", "b", "c"]), "b")
        XCTAssertEqual(DisconnectRepo.nextSelection(after: "a", in: ["a"]), nil)
        XCTAssertEqual(DisconnectRepo.nextSelection(after: "z", in: ["a", "b"]), "a")
        XCTAssertEqual(DisconnectRepo.nextSelection(after: "z", in: []), nil)
    }

    // MARK: Restart chip

    private func paused(running: Int) -> StatusPoll {
        .state(StateSnapshot(running: running, pause: .init(reason: ControlAction.pauseReason)))
    }

    private func begun(purpose: RestartMachine.Purpose = .restart) -> RestartMachine {
        var machine = RestartMachine()
        _ = machine.begin(alreadyPaused: false, purpose: purpose, runsTimeout: runsTimeout, logPath: "log", now: began)
        return machine
    }

    private func waiting(purpose: RestartMachine.Purpose = .restart, running: Int?) -> RestartMachine {
        var machine = begun(purpose: purpose)
        _ = machine.handle(.configChecked(.passed), now: began)
        _ = machine.handle(.controlFinished(.pause, .done), now: began)
        if let running { _ = machine.handle(.polled(paused(running: running)), now: began) }
        return machine
    }

    private let window = ReposWindow(
        chip: .paused,
        content: .repos([
            RepoDetail(
                key: "billing",
                source: .init(kind: .local, baseBranch: "main"),
                routing: .init(sentence: ""),
                live: .status(
                    workflow: RepoField("WORKFLOW.md", "Valid"),
                    lastFetch: RepoField("Last fetch", "OK"),
                    agents: [.init(issueIdentifier: "TP-7"), .init(issueIdentifier: "TP-9", workerHost: "worker-1")],
                    agentsProblem: nil
                )
            ),
            RepoDetail(
                key: "docs",
                source: .init(kind: .local, baseBranch: "main"),
                routing: .init(sentence: ""),
                live: .folded(line: "", canStart: false)
            ),
        ])
    )

    func testNoChipWhileNoRestartIsUnderWay() {
        XCTAssertNil(ReposRestartChip(machine: RestartMachine(), window: window))
    }

    func testTheChipSaysARestartIsPendingAndNamesTheRunsItWaitsOn() throws {
        let one = try XCTUnwrap(ReposRestartChip(machine: waiting(running: 1), window: window))
        XCTAssertEqual(one.title, "Restart pending: waiting on 1 run")
        XCTAssertEqual(one.line, "Waiting for 1 agent run…")
        XCTAssertEqual(one.runs, ["billing: TP-7", "billing: TP-9 · on worker-1"])
        XCTAssertTrue(one.showsCancel)
        XCTAssertTrue(one.showsRestartNow)
        XCTAssertFalse(one.restartNowEnabled)
        XCTAssertEqual(one.restartNowTitle, "Restart Now")
        XCTAssertEqual(one.cancelTitle, "Cancel Restart")

        XCTAssertEqual(ReposRestartChip(machine: waiting(running: 2), window: window)?.title, "Restart pending: waiting on 2 runs")
        XCTAssertEqual(ReposRestartChip(machine: waiting(running: nil), window: window)?.title, "Restart pending")
        XCTAssertEqual(ReposRestartChip(machine: begun(), window: ReposWindow())?.runs, [])
    }

    func testRestartNowTurnsOnOnceTheRunsOutlastTheTimeout() throws {
        var machine = waiting(running: 1)
        _ = machine.handle(.polled(paused(running: 1)), now: began.addingTimeInterval(runsTimeout))
        let chip = try XCTUnwrap(ReposRestartChip(machine: machine, window: window))
        XCTAssertTrue(chip.restartNowEnabled)
    }

    func testTheChipFollowsTheRestartUntilSymphonyIsBack() throws {
        let checking = try XCTUnwrap(ReposRestartChip(machine: begun(), window: window))
        XCTAssertEqual(checking.title, "Restart pending")
        // Neither offered before the restart waits for runs.
        XCTAssertFalse(checking.showsCancel)
        XCTAssertFalse(checking.showsRestartNow)

        var machine = waiting(running: 1)
        _ = machine.handle(.polled(paused(running: 0)), now: began)
        XCTAssertEqual(machine.phase, .stopping)
        XCTAssertEqual(ReposRestartChip(machine: machine, window: window)?.title, "Restarting Symphony…")
        XCTAssertEqual(ReposRestartChip(machine: machine, window: window)?.showsCancel, false)
        _ = machine.handle(.exited(.signaled(15)), now: began)
        XCTAssertEqual(ReposRestartChip(machine: machine, window: window)?.title, "Restarting Symphony…")
        _ = machine.handle(.startFinished(error: nil), now: began)
        XCTAssertEqual(ReposRestartChip(machine: machine, window: window)?.title, "Restarting Symphony…")
        _ = machine.handle(.polled(paused(running: 0)), now: began)
        XCTAssertEqual(machine.phase, .resuming)
        XCTAssertEqual(ReposRestartChip(machine: machine, window: window)?.title, "Restarting Symphony…")
        _ = machine.handle(.controlFinished(.resume, .done), now: began)
        // Back: the chip shows Symphony's state again.
        XCTAssertNil(ReposRestartChip(machine: machine, window: window))
    }

    func testAnUpdatesDrainSaysUpdate() throws {
        let chip = try XCTUnwrap(ReposRestartChip(machine: waiting(purpose: .update, running: 3), window: window))
        XCTAssertEqual(chip.title, "Update pending: waiting on 3 runs")
        XCTAssertEqual(chip.restartNowTitle, "Update Now")
        XCTAssertEqual(chip.cancelTitle, "Cancel Update")

        var machine = waiting(purpose: .update, running: 1)
        _ = machine.handle(.polled(paused(running: 0)), now: began)
        XCTAssertEqual(ReposRestartChip(machine: machine, window: window)?.title, "Updating Symphony…")
    }
}
