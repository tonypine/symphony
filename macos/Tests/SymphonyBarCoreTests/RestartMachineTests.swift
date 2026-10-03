import XCTest
@testable import SymphonyBarCore

final class RestartMachineTests: XCTestCase {
    private typealias Effect = RestartMachine.Effect
    private typealias Event = RestartMachine.Event

    private let began = Date(timeIntervalSince1970: 1_000_000)
    private let runsTimeout: TimeInterval = 30 * 60
    private let log = "~/Library/Logs/symphony/menubar-child.log"
    private let pausedNote = "\n\nDispatch stays paused; choose Resume Dispatch once Symphony runs."

    private func pausedPoll(running: Int) -> StatusPoll {
        .state(StateSnapshot(running: running, pause: .init(reason: ControlAction.pauseReason)))
    }

    private func begin(alreadyPaused: Bool = false) -> (RestartMachine, [Effect]) {
        var machine = RestartMachine()
        let effects = machine.begin(
            alreadyPaused: alreadyPaused,
            runsTimeout: runsTimeout,
            logPath: log,
            now: began
        )
        return (machine, effects)
    }

    /// A restart that paused dispatch and is waiting for agent runs.
    private func waiting(alreadyPaused: Bool = false) -> RestartMachine {
        var (machine, _) = begin(alreadyPaused: alreadyPaused)
        _ = machine.handle(.configChecked(.passed), now: began)
        if !alreadyPaused { _ = machine.handle(.controlFinished(.pause, .done), now: began) }
        return machine
    }

    /// A restart that stopped Symphony and started it again, waiting for it to answer.
    private func waitingForAnswer(alreadyPaused: Bool = false) -> RestartMachine {
        var machine = waiting(alreadyPaused: alreadyPaused)
        _ = machine.handle(.polled(pausedPoll(running: 0)), now: began)
        _ = machine.handle(.exited(.signaled(15)), now: began)
        _ = machine.handle(.startFinished(error: nil), now: began)
        return machine
    }

    func testConfigErrorAbortsWithSymphonyUntouched() {
        var (machine, effects) = begin()
        XCTAssertEqual(effects, [.checkConfig])
        XCTAssertEqual(machine.phase, .checkingConfig)
        XCTAssertTrue(machine.isRestarting)
        XCTAssertEqual(machine.menuLine, "Restarting: checking symphony.yml…")

        effects = machine.handle(.configChecked(.failed("Config error in /ops/symphony.yml: bad key")))

        // Only an alert: no pause, no stop.
        XCTAssertEqual(
            effects,
            [
                .alert(
                    title: "Symphony wasn't restarted",
                    message: "Config error in /ops/symphony.yml: bad key\n\nSymphony keeps running."
                )
            ]
        )
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertFalse(machine.isRestarting)
        XCTAssertEqual(machine.menuLine, "Config error in /ops/symphony.yml: bad key")
    }

    func testPauseFailureAbortsWithSymphonyUntouched() {
        var (machine, _) = begin()
        XCTAssertEqual(machine.handle(.configChecked(.passed)), [.send(.pause)])
        XCTAssertEqual(machine.menuLine, "Restarting: pausing dispatch…")

        let effects = machine.handle(.controlFinished(.pause, .failed("Couldn't pause Symphony: HTTP 500")))

        XCTAssertEqual(
            effects,
            [.alert(title: "Symphony wasn't restarted", message: "Couldn't pause Symphony: HTTP 500\n\nSymphony keeps running.")]
        )
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertFalse(machine.pausedByRestart)
        XCTAssertEqual(machine.menuLine, "Couldn't pause Symphony: HTTP 500")
    }

    func testRestartPausesWaitsForRunsStopsStartsAndResumes() {
        var (machine, _) = begin()
        XCTAssertEqual(machine.handle(.configChecked(.passed)), [.send(.pause)])
        XCTAssertEqual(machine.handle(.controlFinished(.pause, .done)), [.pollNow])
        XCTAssertTrue(machine.pausedByRestart)
        XCTAssertEqual(machine.phase, .waitingForRuns(running: nil))
        XCTAssertEqual(machine.menuLine, "Restarting: waiting for dispatch to pause…")

        // Waits while runs are active.
        XCTAssertEqual(machine.handle(.polled(pausedPoll(running: 2))), [])
        XCTAssertEqual(machine.menuLine, "Waiting for 2 agent runs…")
        XCTAssertEqual(machine.handle(.polled(pausedPoll(running: 1))), [])
        XCTAssertEqual(machine.menuLine, "Waiting for 1 agent run…")
        XCTAssertEqual(machine.handle(.polled(.unreachable)), [])
        XCTAssertEqual(machine.menuLine, "Waiting for 1 agent run…")

        // A poll from before the pause took hold doesn't count, even with nothing running.
        XCTAssertEqual(machine.handle(.polled(.state(StateSnapshot(running: 0)))), [])
        XCTAssertEqual(machine.phase, .waitingForRuns(running: 1))

        XCTAssertEqual(machine.handle(.polled(pausedPoll(running: 0))), [.stop])
        XCTAssertEqual(machine.menuLine, "Restarting: stopping Symphony…")
        XCTAssertEqual(machine.handle(.exited(.signaled(15))), [.start])
        XCTAssertEqual(machine.phase, .starting)
        XCTAssertEqual(machine.handle(.startFinished(error: nil)), [])
        XCTAssertEqual(machine.phase, .waitingForAnswer)
        XCTAssertEqual(machine.menuLine, "Restarting: waiting for Symphony to answer…")

        XCTAssertEqual(machine.handle(.polled(pausedPoll(running: 0))), [.send(.resume)])
        XCTAssertEqual(machine.menuLine, "Restarting: resuming dispatch…")
        XCTAssertEqual(machine.handle(.controlFinished(.resume, .done)), [])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertNil(machine.menuLine)
    }

    func testResumeOnlyAfterTheControlAPIAnswers() {
        var machine = waitingForAnswer()

        // The process has launched, but nothing answers yet, or it answers with an error.
        XCTAssertEqual(machine.handle(.polled(.unreachable), now: began.addingTimeInterval(1)), [])
        XCTAssertEqual(machine.handle(.polled(.failed("Symphony answered with HTTP 503")), now: began.addingTimeInterval(2)), [])
        XCTAssertEqual(machine.phase, .waitingForAnswer)

        XCTAssertEqual(machine.handle(.polled(pausedPoll(running: 0)), now: began.addingTimeInterval(3)), [.send(.resume)])
    }

    func testAlreadyPausedStaysPausedAfterRestart() {
        var (machine, effects) = begin(alreadyPaused: true)
        effects += machine.handle(.configChecked(.passed))
        XCTAssertEqual(machine.phase, .waitingForRuns(running: nil))
        effects += machine.handle(.polled(pausedPoll(running: 0)))
        effects += machine.handle(.exited(.signaled(15)))
        effects += machine.handle(.startFinished(error: nil))
        effects += machine.handle(.polled(pausedPoll(running: 0)))

        XCTAssertEqual(effects, [.checkConfig, .pollNow, .stop, .start])
        XCTAssertFalse(machine.pausedByRestart)
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertNil(machine.menuLine)
    }

    func testTimeoutOffersRestartNow() {
        var machine = waiting()
        XCTAssertTrue(machine.canCancel)

        _ = machine.handle(.polled(pausedPoll(running: 1)), now: began.addingTimeInterval(runsTimeout - 1))
        XCTAssertFalse(machine.offersRestartNow)
        XCTAssertEqual(machine.handle(.restartNow), [], "Restart Now isn't offered before the timeout")
        XCTAssertEqual(machine.phase, .waitingForRuns(running: 1))

        _ = machine.handle(.polled(pausedPoll(running: 1)), now: began.addingTimeInterval(runsTimeout))
        XCTAssertTrue(machine.offersRestartNow)
        XCTAssertEqual(machine.menuLine, "Waiting for 1 agent run…")

        XCTAssertEqual(machine.handle(.restartNow), [.stop])
        XCTAssertEqual(machine.phase, .stopping)
        XCTAssertFalse(machine.offersRestartNow)
        XCTAssertFalse(machine.canCancel)
    }

    func testCancelResumesTheDispatchTheRestartPaused() {
        var machine = waiting()
        _ = machine.handle(.polled(pausedPoll(running: 3)))

        XCTAssertEqual(machine.handle(.cancel), [.send(.resume)])
        XCTAssertEqual(machine.phase, .resuming)
        XCTAssertFalse(machine.canCancel)
        // Runs finishing now no longer stop Symphony.
        XCTAssertEqual(machine.handle(.polled(pausedPoll(running: 0))), [])

        XCTAssertEqual(machine.handle(.controlFinished(.resume, .done)), [])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertNil(machine.menuLine)
    }

    func testCancelLeavesAUserPauseAlone() {
        var machine = waiting(alreadyPaused: true)

        XCTAssertEqual(machine.handle(.cancel), [])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testResumeFailureIsShownInTheMenu() {
        var machine = waitingForAnswer()
        _ = machine.handle(.polled(pausedPoll(running: 0)))

        XCTAssertEqual(machine.handle(.controlFinished(.resume, .failed("Couldn't resume Symphony: HTTP 401"))), [])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.menuLine, "Couldn't resume Symphony: HTTP 401")
    }

    func testStartFailureSurfacesAnError() {
        var machine = waiting()
        _ = machine.handle(.polled(pausedPoll(running: 0)))
        _ = machine.handle(.exited(.signaled(15)))

        let effects = machine.handle(.startFinished(error: "Linear API key not set. Add it in Settings."))

        XCTAssertEqual(
            effects,
            [
                .alert(
                    title: "Symphony didn't come back",
                    message: "Couldn't start Symphony: Linear API key not set. Add it in Settings." + pausedNote
                )
            ]
        )
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.menuLine, "Couldn't start Symphony: Linear API key not set. Add it in Settings.")
    }

    func testExitBeforeAnsweringSurfacesAnErrorWithTheLog() {
        var machine = waitingForAnswer(alreadyPaused: true)

        let effects = machine.handle(.exited(.exited(1)))

        XCTAssertEqual(
            effects,
            [.alert(title: "Symphony didn't come back", message: "Symphony exited with status 1 before it answered. See \(log).")]
        )
        XCTAssertEqual(machine.menuLine, "Symphony exited with status 1 before it answered. See \(log).")
    }

    func testNoAnswerWithinTheTimeoutSurfacesAnError() {
        var machine = waitingForAnswer()
        let deadline = began.addingTimeInterval(RestartMachine.answerTimeout)

        XCTAssertEqual(machine.handle(.polled(.unreachable), now: deadline.addingTimeInterval(-1)), [])
        let effects = machine.handle(.polled(.unreachable), now: deadline)

        XCTAssertEqual(
            effects,
            [
                .alert(
                    title: "Symphony didn't come back",
                    message: "Symphony didn't answer within 120 seconds of starting. See \(log)." + pausedNote
                )
            ]
        )
        XCTAssertEqual(machine.phase, .idle)
    }

    func testSymphonyExitingBeforeTheStopCancelsTheRestart() {
        for prepare in [
            { (machine: inout RestartMachine) in },
            { (machine: inout RestartMachine) in _ = machine.handle(.configChecked(.passed)) },
            { (machine: inout RestartMachine) in
                _ = machine.handle(.configChecked(.passed))
                _ = machine.handle(.controlFinished(.pause, .done))
            },
        ] {
            var (machine, _) = begin()
            prepare(&machine)

            XCTAssertEqual(machine.handle(.exited(.exited(1))), [])
            XCTAssertEqual(machine.phase, .idle)
            XCTAssertEqual(machine.menuLine, "Restart cancelled: Symphony exited with status 1")
        }
    }

    func testBeginIsIgnoredWhileRestartingAndClearsTheLastError() {
        var (machine, _) = begin()
        XCTAssertEqual(machine.begin(alreadyPaused: true, runsTimeout: runsTimeout, logPath: log), [])
        XCTAssertEqual(machine.phase, .checkingConfig)

        _ = machine.handle(.configChecked(.failed("Config error")))
        XCTAssertEqual(machine.menuLine, "Config error")

        XCTAssertEqual(machine.begin(alreadyPaused: false, runsTimeout: runsTimeout, logPath: log), [.checkConfig])
        XCTAssertNil(machine.error)
    }

    func testEventsOutsideTheirStepAreIgnored() {
        var idle = RestartMachine()
        XCTAssertEqual(idle.handle(.polled(pausedPoll(running: 0))), [])
        XCTAssertEqual(idle.handle(.exited(.exited(1))), [])
        XCTAssertEqual(idle.handle(.cancel), [])
        XCTAssertEqual(idle, RestartMachine())

        var (checking, _) = begin()
        XCTAssertEqual(checking.handle(.restartNow), [])
        XCTAssertEqual(checking.handle(.cancel), [])
        XCTAssertEqual(checking.handle(.controlFinished(.resume, .done)), [])
        XCTAssertEqual(checking.phase, .checkingConfig)
    }

    // MARK: Update

    private func beginUpdate(alreadyPaused: Bool = false) -> (RestartMachine, [Effect]) {
        var machine = RestartMachine()
        let effects = machine.begin(
            alreadyPaused: alreadyPaused,
            purpose: .update,
            runsTimeout: runsTimeout,
            logPath: log,
            now: began
        )
        return (machine, effects)
    }

    func testUpdateDrainsThenStopsWithoutStarting() {
        var (machine, effects) = beginUpdate()
        XCTAssertEqual(effects, [.checkConfig])
        XCTAssertEqual(machine.purpose, .update)
        XCTAssertEqual(machine.menuLine, "Updating: checking symphony.yml…")

        XCTAssertEqual(machine.handle(.configChecked(.passed), now: began), [.send(.pause)])
        XCTAssertEqual(machine.menuLine, "Updating: pausing dispatch…")
        XCTAssertEqual(machine.handle(.controlFinished(.pause, .done), now: began), [.pollNow])
        XCTAssertEqual(machine.handle(.polled(pausedPoll(running: 2)), now: began), [])
        XCTAssertEqual(machine.menuLine, "Waiting for 2 agent runs…")
        XCTAssertEqual(machine.handle(.polled(pausedPoll(running: 0)), now: began), [.stop])
        XCTAssertEqual(machine.menuLine, "Updating: stopping Symphony…")

        effects = machine.handle(.exited(.signaled(15)), now: began)

        XCTAssertEqual(effects, [.stopped])
        XCTAssertFalse(machine.isRestarting)
        XCTAssertTrue(machine.pausedByRestart, "the relaunched app resumes the dispatch the update paused")
        XCTAssertNil(machine.menuLine)
    }

    /// TP-339: running the new version's Symphony deletes the running version's unpacked release, so an update
    /// checks symphony.yml with the running Symphony and starts none before it hands over to the relaunched app.
    func testUpdateRunsNoOtherSymphonyBeforeTheOldOneStops() {
        for waiting in [[Event.polled(pausedPoll(running: 0))], [.polled(pausedPoll(running: 1)), .restartNow]] {
            var (machine, effects) = beginUpdate()
            var now = began
            for event in [.configChecked(.passed), .controlFinished(.pause, .done)] + waiting + [.exited(.signaled(15))] {
                now = now.addingTimeInterval(runsTimeout)
                effects += machine.handle(event, now: now)
            }

            XCTAssertEqual(effects, [.checkConfig, .send(.pause), .pollNow, .stop, .stopped])
        }
    }

    func testUpdateKeepsAPauseTheUserMade() {
        var (machine, _) = beginUpdate(alreadyPaused: true)
        XCTAssertEqual(machine.handle(.configChecked(.passed), now: began), [.pollNow])
        XCTAssertEqual(machine.handle(.polled(pausedPoll(running: 0)), now: began), [.stop])

        XCTAssertEqual(machine.handle(.exited(.signaled(15)), now: began), [.stopped])
        XCTAssertFalse(machine.pausedByRestart)
    }

    func testUpdateNowAnywayAfterTheTimeout() {
        var (machine, _) = beginUpdate()
        _ = machine.handle(.configChecked(.passed), now: began)
        _ = machine.handle(.controlFinished(.pause, .done), now: began)
        _ = machine.handle(.polled(pausedPoll(running: 1)), now: began.addingTimeInterval(runsTimeout))
        XCTAssertTrue(machine.offersRestartNow)

        XCTAssertEqual(machine.handle(.restartNow, now: began.addingTimeInterval(runsTimeout)), [.stop])
        XCTAssertEqual(machine.handle(.exited(.signaled(15)), now: began), [.stopped])
    }

    func testNewBinaryConfigErrorRefusesTheUpdate() {
        var (machine, _) = beginUpdate()

        let effects = machine.handle(.configChecked(.failed("Config error: unknown key")), now: began)

        XCTAssertEqual(
            effects,
            [.alert(title: "Symphony wasn't updated", message: "Config error: unknown key\n\nSymphony keeps running.")]
        )
        XCTAssertFalse(machine.isRestarting)
    }

    func testSymphonyExitingDuringTheDrainCancelsTheUpdate() {
        var (machine, _) = beginUpdate()
        _ = machine.handle(.configChecked(.passed), now: began)

        XCTAssertEqual(machine.handle(.exited(.exited(1)), now: began), [])
        XCTAssertFalse(machine.isRestarting)
        XCTAssertEqual(machine.menuLine, "Update cancelled: Symphony \(ChildExit.exited(1).summary)")
    }
}
