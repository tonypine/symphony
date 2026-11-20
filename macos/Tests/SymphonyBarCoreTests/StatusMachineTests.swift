import XCTest
@testable import SymphonyBarCore

final class StatusMachineTests: XCTestCase {
    private let working = StateSnapshot(running: 2, retrying: 1)
    private let paused = StateSnapshot(running: 0, retrying: 0, pause: .init(reason: "deploy freeze"))

    private func machine(_ events: StatusMachine.Event...) -> StatusMachine {
        var machine = StatusMachine()
        events.forEach { machine.handle($0) }
        return machine
    }

    func testStartsStopped() {
        let machine = machine()

        XCTAssertEqual(machine.status, .stopped)
        XCTAssertTrue(machine.canStart)
        XCTAssertFalse(machine.canStop)
        XCTAssertEqual(machine.nextPollInterval, 5)
    }

    func testNothingAnsweringStaysStopped() {
        XCTAssertEqual(machine(.polled(.unreachable)).status, .stopped)
    }

    func testStartingUntilSymphonyAnswers() {
        let machine = machine(.started, .polled(.unreachable))

        XCTAssertEqual(machine.status, .starting)
        XCTAssertEqual(machine.nextPollInterval, 1)
        XCTAssertFalse(machine.canStart)
        XCTAssertTrue(machine.canStop)
    }

    func testStartingToRunning() {
        let machine = machine(.started, .polled(.unreachable), .polled(.state(working)))

        XCTAssertEqual(machine.status, .running(working, external: false))
        XCTAssertEqual(machine.nextPollInterval, 5)
        XCTAssertFalse(machine.canStart)
        XCTAssertTrue(machine.canStop)
    }

    func testRunningToPausedAndBack() {
        var machine = machine(.started, .polled(.state(working)), .polled(.state(paused)))
        XCTAssertEqual(machine.status, .paused(paused, external: false))
        XCTAssertTrue(machine.canStop)

        machine.handle(.polled(.state(working)))
        XCTAssertEqual(machine.status, .running(working, external: false))
    }

    func testStartingStraightToPaused() {
        // Pauses outlive restarts, so Symphony can come up paused.
        XCTAssertEqual(machine(.started, .polled(.state(paused))).status, .paused(paused, external: false))
    }

    func testStopRequestedIsStopped() {
        let machine = machine(.started, .polled(.state(working)), .exited(.signaled(15), requested: true))

        XCTAssertEqual(machine.status, .stopped)
        XCTAssertTrue(machine.canStart)
        XCTAssertFalse(machine.canStop)
    }

    func testStopWhileStartingIsStopped() {
        XCTAssertEqual(machine(.started, .exited(.signaled(15), requested: true)).status, .stopped)
    }

    func testUnexpectedExitIsAnErrorUntilTheNextStart() {
        var machine = machine(.started, .polled(.state(working)), .exited(.exited(1), requested: false))
        XCTAssertEqual(machine.status, .error("Symphony exited with status 1"))
        XCTAssertTrue(machine.canStart)
        XCTAssertFalse(machine.canStop)

        machine.handle(.polled(.unreachable))
        XCTAssertEqual(machine.status, .error("Symphony exited with status 1"))

        machine.handle(.started)
        XCTAssertEqual(machine.status, .starting)
    }

    func testOneMissedPollIsSlowNotAnError() {
        var machine = machine(.started, .polled(.state(working)), .polled(.unreachable))
        XCTAssertEqual(machine.status, .running(working, external: false))
        XCTAssertTrue(machine.slowToAnswer)
        XCTAssertEqual(machine.nextPollInterval, 5)

        machine.handle(.polled(.state(paused)))
        XCTAssertEqual(machine.status, .paused(paused, external: false))
        XCTAssertFalse(machine.slowToAnswer)

        machine.handle(.polled(.unreachable))
        XCTAssertEqual(machine.status, .paused(paused, external: false))
        XCTAssertTrue(machine.slowToAnswer)
    }

    func testOwnedSymphonyThatStopsAnsweringKeepsItsLastAnswer() {
        // TP-1562: a Symphony the app runs is alive, so its pages stay with the last answer, marked as not current.
        let start = Date(timeIntervalSince1970: 1_000)
        var machine = StatusMachine()
        machine.handle(.started, at: start)
        machine.handle(.polled(.state(working)), at: start)
        for poll in 1...StatusMachine.missedPollsBeforeError {
            machine.handle(.polled(.unreachable), at: start.addingTimeInterval(5 * Double(poll)))
        }

        XCTAssertEqual(StatusMachine.missedPollsBeforeError, 2)
        XCTAssertEqual(machine.status, .running(working, external: false))
        XCTAssertEqual(machine.lag(now: start.addingTimeInterval(12)), "Symphony isn't answering · 12 s")
        XCTAssertEqual(machine.lag(now: start.addingTimeInterval(185)), "Symphony isn't answering · 3 min")
        XCTAssertFalse(machine.slowToAnswer)
        XCTAssertTrue(machine.canStop)
        XCTAssertFalse(machine.canStart)

        machine.handle(.polled(.unreachable), at: start.addingTimeInterval(15))
        XCTAssertEqual(machine.status, .running(working, external: false))

        // Back to current with the next answer, with no restart.
        machine.handle(.polled(.state(paused)), at: start.addingTimeInterval(20))
        XCTAssertEqual(machine.status, .paused(paused, external: false))
        XCTAssertNil(machine.lag(now: start.addingTimeInterval(20)))
    }

    func testOneLatePollIsSlowWithoutALag() {
        let machine = machine(.started, .polled(.state(working)), .polled(.unreachable))

        XCTAssertTrue(machine.slowToAnswer)
        XCTAssertNil(machine.lag())
    }

    func testSlowStateWithHealthAnsweringKeepsThePagesAndNeverAlerts() {
        // The state read takes 20 s and more while the health read answers: Symphony is slow, not down.
        let start = Date(timeIntervalSince1970: 1_000)
        var machine = StatusMachine()
        machine.handle(.started, at: start)
        machine.handle(.polled(.state(working)), at: start)
        for tick in 1...24 {
            let now = start.addingTimeInterval(5 * Double(tick))
            machine.handle(.health(answering: true), at: now)
            machine.handle(.polled(.unreachable), at: now)
            XCTAssertFalse(machine.takeNotAnsweringAlert(now: now, limit: 60), "tick \(tick)")
        }
        let now = start.addingTimeInterval(120)

        XCTAssertEqual(machine.status, .running(working, external: false))
        XCTAssertEqual(machine.lag(now: now), "Symphony isn't answering · 2 min")
        XCTAssertFalse(machine.notAnswering(now: now, limit: 60))

        // The late answer is used when it arrives.
        machine.handle(.polled(.state(paused)), at: now)
        XCTAssertEqual(machine.status, .paused(paused, external: false))
        XCTAssertNil(machine.lag(now: now))
    }

    func testHealthNotAnsweringWithTheProcessAliveAlertsOnceAfterTheLimit() {
        let start = Date(timeIntervalSince1970: 1_000)
        var machine = StatusMachine()
        machine.handle(.started, at: start)
        machine.handle(.polled(.state(working)), at: start)
        var alerts: [Int] = []
        for tick in 1...30 {
            let now = start.addingTimeInterval(5 * Double(tick))
            machine.handle(.health(answering: false), at: now)
            machine.handle(.polled(.unreachable), at: now)
            if machine.takeNotAnsweringAlert(now: now, limit: 60) { alerts.append(5 * tick) }
            // The pages stay all along.
            XCTAssertEqual(machine.status, .running(working, external: false))
        }

        XCTAssertEqual(alerts, [60], "one notification, at the limit")
        XCTAssertTrue(machine.notAnswering(now: start.addingTimeInterval(150), limit: 60))
        XCTAssertEqual(machine.silence(now: start.addingTimeInterval(150)), "2 min")

        // An answer ends it; the next silence alerts again.
        machine.handle(.polled(.state(working)), at: start.addingTimeInterval(155))
        XCTAssertFalse(machine.notAnswering(now: start.addingTimeInterval(155), limit: 60))
        machine.handle(.polled(.unreachable), at: start.addingTimeInterval(260))
        XCTAssertTrue(machine.takeNotAnsweringAlert(now: start.addingTimeInterval(260), limit: 60))
    }

    func testATenSecondGapSendsNoAlert() {
        let start = Date(timeIntervalSince1970: 1_000)
        var machine = StatusMachine()
        machine.handle(.started, at: start)
        machine.handle(.polled(.state(working)), at: start)
        for tick in 1...2 {
            let now = start.addingTimeInterval(5 * Double(tick))
            machine.handle(.health(answering: false), at: now)
            machine.handle(.polled(.unreachable), at: now)
            XCTAssertFalse(machine.takeNotAnsweringAlert(now: now, limit: 60))
        }
        XCTAssertFalse(machine.notAnswering(now: start.addingTimeInterval(10), limit: 60))
        XCTAssertNotNil(machine.lag(now: start.addingTimeInterval(10)))
    }

    func testAHealthReadThatAnsweredResetsTheSilence() {
        let start = Date(timeIntervalSince1970: 1_000)
        var machine = StatusMachine()
        machine.handle(.started, at: start)
        machine.handle(.polled(.state(working)), at: start)
        machine.handle(.polled(.unreachable), at: start.addingTimeInterval(50))
        machine.handle(.health(answering: true), at: start.addingTimeInterval(55))
        machine.handle(.polled(.unreachable), at: start.addingTimeInterval(55))
        machine.handle(.polled(.unreachable), at: start.addingTimeInterval(70))

        XCTAssertFalse(machine.notAnswering(now: start.addingTimeInterval(70), limit: 60))
        XCTAssertTrue(machine.notAnswering(now: start.addingTimeInterval(115), limit: 60))
    }

    func testNoAlertWithoutAnAnswerToKeep() {
        // Starting, or an external Symphony gone: the placeholder shows, and the menu says so on its own.
        var machine = machine(.started, .polled(.unreachable))
        XCTAssertFalse(machine.notAnswering(now: Date().addingTimeInterval(600), limit: 60))
        machine = self.machine(.polled(.state(working)), .polled(.unreachable), .polled(.unreachable))
        XCTAssertEqual(machine.status, .stopped)
        XCTAssertFalse(machine.notAnswering(now: Date().addingTimeInterval(600), limit: 60))
        XCTAssertNil(machine.lag())
    }

    func testDurationsReadInSecondsThenMinutes() {
        XCTAssertEqual(StatusMachine.duration(0), "0 s")
        XCTAssertEqual(StatusMachine.duration(59.4), "59 s")
        XCTAssertEqual(StatusMachine.duration(60), "1 min")
        XCTAssertEqual(StatusMachine.duration(-3), "0 s")
    }

    func testAnAnswerBetweenMissesStartsTheCountAgain() {
        let machine = machine(
            .started, .polled(.state(working)), .polled(.unreachable), .polled(.state(working)), .polled(.unreachable)
        )

        XCTAssertEqual(machine.status, .running(working, external: false))
        XCTAssertTrue(machine.slowToAnswer)
    }

    func testAFailedPollKeepsTheLastAnswerWithItsMessage() {
        let machine = machine(.started, .polled(.state(working)), .polled(.failed("Snapshot timed out")))

        XCTAssertEqual(machine.status, .running(working, external: false))
        XCTAssertEqual(machine.lag(), "Snapshot timed out")
        XCTAssertEqual(machine.nextPollInterval, 5)
        XCTAssertTrue(machine.canStop)
    }

    func testAFailedPollBeforeAnyStateIsAnError() {
        let machine = machine(.started, .polled(.failed("HTTP 500")))

        XCTAssertEqual(machine.status, .error("HTTP 500"))
        XCTAssertNil(machine.lag())
    }

    func testAFailedPollWhileSlowShowsItsMessageThenTheSilence() {
        var machine = machine(.started, .polled(.state(working)), .polled(.unreachable), .polled(.failed("HTTP 500")))
        XCTAssertEqual(machine.status, .running(working, external: false))
        XCTAssertEqual(machine.lag(), "HTTP 500")
        XCTAssertFalse(machine.slowToAnswer)

        machine.handle(.polled(.unreachable))
        XCTAssertEqual(machine.lag(), "HTTP 500")
        machine.handle(.polled(.unreachable))
        XCTAssertEqual(machine.lag()?.hasPrefix("Symphony isn't answering · "), true)
    }

    func testAnUnexpectedExitIsAnErrorAtOnceWhileSlow() {
        var machine = machine(
            .started, .polled(.state(working)), .polled(.unreachable), .exited(.exited(1), requested: false)
        )
        XCTAssertEqual(machine.status, .error("Symphony exited with status 1"))
        XCTAssertFalse(machine.slowToAnswer)

        machine.handle(.polled(.unreachable))
        XCTAssertEqual(machine.status, .error("Symphony exited with status 1"))
    }

    func testAttachesToAnExternalSymphony() {
        let machine = machine(.polled(.state(working)))

        XCTAssertEqual(machine.status, .running(working, external: true))
        XCTAssertFalse(machine.canStart)
        XCTAssertFalse(machine.canStop)
    }

    func testExternalPausedAndStopped() {
        var machine = machine(.polled(.state(working)), .polled(.state(paused)))
        XCTAssertEqual(machine.status, .paused(paused, external: true))
        XCTAssertFalse(machine.canStart)
        XCTAssertFalse(machine.canStop)

        machine.handle(.polled(.unreachable))
        XCTAssertEqual(machine.status, .paused(paused, external: true))
        XCTAssertTrue(machine.slowToAnswer)
        XCTAssertFalse(machine.canStart)

        machine.handle(.polled(.unreachable))
        XCTAssertEqual(machine.status, .stopped)
        XCTAssertFalse(machine.slowToAnswer)
        XCTAssertTrue(machine.canStart)
    }

    func testExternalSymphonyWhoseHealthAnswersStaysRunning() {
        // A busy external Symphony still holds the control URL: no second one is offered.
        var machine = machine(.polled(.state(working)))
        for _ in 0..<5 {
            machine.handle(.health(answering: true))
            machine.handle(.polled(.unreachable))
        }

        XCTAssertEqual(machine.status, .running(working, external: true))
        XCTAssertNotNil(machine.lag())
        XCTAssertFalse(machine.canStart)

        machine.handle(.health(answering: false))
        machine.handle(.polled(.unreachable))
        XCTAssertEqual(machine.status, .running(working, external: true))
        machine.handle(.polled(.unreachable))
        XCTAssertEqual(machine.status, .stopped)
        XCTAssertTrue(machine.canStart)
    }

    func testExternalSymphonyGetsTheSameGraceBeforeStartIsOffered() {
        var machine = machine(.polled(.state(working)))
        for _ in 1..<StatusMachine.missedPollsBeforeError {
            machine.handle(.polled(.unreachable))
            XCTAssertEqual(machine.status, .running(working, external: true))
            XCTAssertTrue(machine.slowToAnswer)
            XCTAssertFalse(machine.canStart)
        }

        machine.handle(.polled(.unreachable))
        XCTAssertEqual(machine.status, .stopped)
        XCTAssertFalse(machine.slowToAnswer)
        XCTAssertTrue(machine.canStart)
        XCTAssertFalse(machine.canStop)
    }

    func testExternalFailureIsAnErrorThatAllowsStart() {
        let machine = machine(.polled(.failed("Symphony answered with HTTP 404")))

        XCTAssertEqual(machine.status, .error("Symphony answered with HTTP 404"))
        XCTAssertTrue(machine.canStart)
        XCTAssertFalse(machine.canStop)
    }

    func testAnAnswerClearsAnEarlierCrash() {
        var machine = machine(.started, .exited(.exited(1), requested: false), .polled(.state(working)))
        XCTAssertEqual(machine.status, .running(working, external: true))

        machine.handle(.polled(.unreachable))
        machine.handle(.polled(.unreachable))
        XCTAssertEqual(machine.status, .stopped)
    }

    func testExitDropsTheLastAnswer() {
        // Until the next poll, the exited process's last answer isn't shown as running.
        XCTAssertEqual(machine(.started, .polled(.state(working)), .exited(.exited(0), requested: true)).status, .stopped)
    }
}
