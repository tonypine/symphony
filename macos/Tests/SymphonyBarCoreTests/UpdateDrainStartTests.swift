import XCTest
@testable import SymphonyBarCore

/// TP-1550: an update starts and its drain ends while Symphony's state fails to load.
final class UpdateDrainStartTests: XCTestCase {
    private let stateFails = StatusPoll.failed("Symphony answered with HTTP 500")
    private let failedStatus = SymphonyStatus.error("Symphony answered with HTTP 500")
    private let began = Date(timeIntervalSince1970: 1_793_417_888) // 2026-10-31T03:38:08Z
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateDrainStartTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func start(
        _ status: SymphonyStatus,
        running: Bool = true,
        starting: Bool = false,
        stopping: Bool = false,
        restarting: Bool = false,
        drain: DrainStatus? = nil
    ) -> UpdateDrainStart {
        UpdateDrainStart(
            status: status,
            symphonyRunning: running,
            symphonyStarting: starting,
            symphonyStopping: stopping,
            restarting: restarting,
            drain: drain
        )
    }

    // MARK: The drain read kept while the state fails

    func testOnlyAFailedStateFromTheAppsOwnSymphonyAsksForADrainRead() {
        var read = FailedStateDrainRead()

        XCTAssertTrue(read.polled(stateFails, symphonyRunning: true, restarting: false))
        XCTAssertFalse(read.polled(stateFails, symphonyRunning: false, restarting: false), "an external Symphony")
        XCTAssertFalse(read.polled(stateFails, symphonyRunning: true, restarting: true), "a drain reads it itself")
        XCTAssertFalse(read.polled(.unreachable, symphonyRunning: true, restarting: false), "no answer at all")
        XCTAssertFalse(read.polled(.state(StateSnapshot(running: 0)), symphonyRunning: true, restarting: false))
    }

    func testAReadIsKeptWhileTheStateFailsAndForgottenByAnyOtherPoll() {
        var read = FailedStateDrainRead()
        let drain = DrainStatus(running: 0, paused: false)

        XCTAssertTrue(read.received(drain, status: failedStatus))
        XCTAssertEqual(read.current(status: failedStatus), drain)
        XCTAssertNil(read.current(status: .running(StateSnapshot(running: 0), external: false)), "the state loads again")

        XCTAssertFalse(read.polled(.state(StateSnapshot(running: 0)), symphonyRunning: true, restarting: false))
        XCTAssertNil(read.read)
    }

    func testAReadThatComesBackOnceTheStateLoadsIsDropped() {
        var read = FailedStateDrainRead()

        XCTAssertFalse(read.received(DrainStatus(running: 0, paused: false), status: .stopped))
        XCTAssertNil(read.read)
    }

    // MARK: How the drain starts

    func testAStateThatLoadsStartsTheDrainAsBefore() {
        XCTAssertEqual(start(.running(StateSnapshot(running: 1), external: false)), .drain(alreadyPaused: false))
        XCTAssertEqual(start(.paused(StateSnapshot(running: 1), external: false)), .drain(alreadyPaused: true))
        XCTAssertEqual(
            UpdateDrainStart.drain(alreadyPaused: true).startLog,
            "dispatch already paused; waiting for agent runs, then stopping Symphony"
        )
    }

    func testAFailedStateWithADrainReadStartsTheDrainPausedAsTheReadSays() {
        let open = start(failedStatus, drain: DrainStatus(running: 0, paused: false))
        XCTAssertEqual(open, .drain(alreadyPaused: false))
        XCTAssertEqual(open.startLog, "pausing dispatch; waiting for agent runs, then stopping Symphony")

        XCTAssertEqual(start(failedStatus, drain: DrainStatus(running: 1, paused: true)), .drain(alreadyPaused: true))
    }

    func testAFailedStateWithoutADrainReadIsRefusedAsBefore() {
        XCTAssertEqual(start(failedStatus), .refused, "Symphony doesn't answer, or is older than the drain request")
        XCTAssertNil(UpdateDrainStart.refused.startLog)
        XCTAssertFalse(UpdateDrainStart.canInstall(status: failedStatus, symphonyRunning: true, drain: nil))
    }

    func testStartingStoppingOrRestartingIsRefusedEvenWithADrainRead() {
        let drain = DrainStatus(running: 0, paused: false)
        XCTAssertEqual(start(failedStatus, starting: true, drain: drain), .refused)
        XCTAssertEqual(start(failedStatus, stopping: true, drain: drain), .refused)
        XCTAssertEqual(start(failedStatus, restarting: true, drain: drain), .refused)
        XCTAssertEqual(start(.starting, drain: drain), .refused)
        XCTAssertEqual(start(.running(StateSnapshot(running: 0), external: true)), .refused, "an external Symphony")
    }

    func testASymphonyTheAppDoesntRunHasNothingToDrain() {
        let none = start(.stopped, running: false)
        XCTAssertEqual(none, .nothingToDrain)
        XCTAssertNil(none.startLog)
        XCTAssertTrue(UpdateDrainStart.canInstall(status: .stopped, symphonyRunning: false, drain: nil))
    }

    func testInstallUpdateIsOfferedWhileTheStateFailsOnceADrainReadAnswered() {
        let drain = DrainStatus(running: 0, paused: false)
        XCTAssertTrue(UpdateDrainStart.canInstall(status: failedStatus, symphonyRunning: true, drain: drain))
        XCTAssertTrue(
            UpdateDrainStart.canInstall(
                status: .running(StateSnapshot(running: 0), external: false),
                symphonyRunning: true,
                drain: nil
            )
        )
        XCTAssertFalse(UpdateDrainStart.canInstall(status: .starting, symphonyRunning: true, drain: drain))
    }

    // MARK: From a failed state to an installed update

    /// The app's path: a poll whose state fails asks for a drain read, the read starts the drain, the drain reads
    /// again after its own failed poll, stops Symphony, and the update log says the drain is done.
    private func drain(reads: [DrainStatus], log: UpdateLog) -> (RestartMachine, stopped: Bool) {
        var kept = FailedStateDrainRead()
        XCTAssertTrue(kept.polled(stateFails, symphonyRunning: true, restarting: false))
        XCTAssertTrue(kept.received(reads[0], status: failedStatus))

        let drainStart = start(failedStatus, drain: kept.current(status: failedStatus))
        guard case let .drain(alreadyPaused) = drainStart, let startLog = drainStart.startLog else {
            XCTFail("the drain doesn't start: \(drainStart)")
            return (RestartMachine(), false)
        }
        log.append(startLog, at: began)

        var machine = RestartMachine()
        var effects = machine.begin(
            alreadyPaused: alreadyPaused,
            purpose: .update,
            updatingTo: "0.0.1.1002",
            runsTimeout: 30 * 60,
            logPath: "~/Library/Logs/symphony/menubar-child.log",
            now: began
        )
        if effects == [.send(machine.pauseAction)] {
            effects = machine.handle(.controlFinished(machine.pauseAction, .done), now: began)
        }
        for read in reads.dropFirst() {
            XCTAssertEqual(machine.handle(.polled(stateFails), now: began), [.checkRuns])
            effects = machine.handle(.runsChecked(read), now: began)
        }
        guard effects == [.stop] else { return (machine, false) }
        let stopped = machine.handle(.exited(.signaled(15)), now: began) == [.stopped]
        if stopped { log.append(UpdateDrainStart.doneLog, at: began) }
        return (machine, stopped)
    }

    func testAnUpdateInstallsWhileTheStateFailsOnceNoRunIsLeft() throws {
        let log = UpdateLog(directory: directory, source: "build 1001")

        let (machine, stopped) = drain(
            reads: [DrainStatus(running: 0, paused: false), DrainStatus(running: 1, betweenTurns: 1, paused: true)],
            log: log
        )

        XCTAssertTrue(stopped, "Symphony stopped: the update hands over to the helper")
        XCTAssertTrue(machine.pausedByRestart)
        XCTAssertEqual(
            try String(contentsOf: log.url, encoding: .utf8),
            "2026-10-31T03:38:08Z [build 1001] pausing dispatch; waiting for agent runs, then stopping Symphony\n"
                + "2026-10-31T03:38:08Z [build 1001] drain done: agent runs finished and Symphony stopped\n"
        )
    }

    func testWhileTheStateFailsTheDrainStillWaitsForAWorkingRun() throws {
        let log = UpdateLog(directory: directory, source: "build 1001")

        let (machine, stopped) = drain(
            reads: [DrainStatus(running: 1, paused: true), DrainStatus(running: 1, paused: true)],
            log: log
        )

        XCTAssertFalse(stopped)
        XCTAssertEqual(machine.phase, .waitingForRuns(running: 1))
        XCTAssertEqual(machine.menuLine, "Waiting for 1 agent run…")
        XCTAssertEqual(
            try String(contentsOf: log.url, encoding: .utf8),
            "2026-10-31T03:38:08Z [build 1001] dispatch already paused; waiting for agent runs, then stopping Symphony\n"
        )
    }
}
