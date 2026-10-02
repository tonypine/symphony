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

    func testOwnedSymphonyThatStopsAnsweringIsAnError() {
        let machine = machine(.started, .polled(.state(working)), .polled(.unreachable))

        XCTAssertEqual(machine.status, .error("Symphony isn't answering"))
        XCTAssertTrue(machine.canStop)
        XCTAssertFalse(machine.canStart)
    }

    func testAFailedPollIsAnError() {
        let machine = machine(.started, .polled(.state(working)), .polled(.failed("Snapshot timed out")))

        XCTAssertEqual(machine.status, .error("Snapshot timed out"))
        XCTAssertEqual(machine.nextPollInterval, 5)
        XCTAssertTrue(machine.canStop)
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
        XCTAssertEqual(machine.status, .stopped)
        XCTAssertTrue(machine.canStart)
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
        XCTAssertEqual(machine.status, .stopped)
    }

    func testExitDropsTheLastAnswer() {
        // Until the next poll, the exited process's last answer isn't shown as running.
        XCTAssertEqual(machine(.started, .polled(.state(working)), .exited(.exited(0), requested: true)).status, .stopped)
    }
}
