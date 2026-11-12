import Darwin
import XCTest
@testable import SymphonyBarCore

/// TP-1475: a quit after the app stopped Symphony for an update hung with a ticket page open.
final class QuitPlanTests: XCTestCase {
    func testTicketPageOpenAndSymphonyStoppedForTheUpdateQuitsNow() {
        let plan = QuitPlan(symphonyRunning: false, symphonyStopping: false, stoppedToQuit: true, holdsAnswer: false, holdsLook: true)
        XCTAssertTrue(plan.endsNow)
        XCTAssertFalse(plan.sendsLook)
    }

    func testHeldAnswerAndSymphonyStoppedForTheUpdateQuitsNow() {
        let plan = QuitPlan(symphonyRunning: false, symphonyStopping: false, stoppedToQuit: true, holdsAnswer: true, holdsLook: true)
        XCTAssertTrue(plan.endsNow)
        XCTAssertFalse(plan.sendsHeldAnswer)
    }

    func testNothingHeldAndNothingRunningQuitsNow() {
        let plan = QuitPlan(symphonyRunning: false, symphonyStopping: false, stoppedToQuit: false, holdsAnswer: false, holdsLook: false)
        XCTAssertTrue(plan.endsNow)
    }

    func testASymphonyTheAppDoesNotRunStillGetsTheLookAndTheAnswer() {
        let plan = QuitPlan(symphonyRunning: false, symphonyStopping: false, stoppedToQuit: false, holdsAnswer: true, holdsLook: true)
        XCTAssertFalse(plan.endsNow)
        XCTAssertTrue(plan.sendsHeldAnswer)
        XCTAssertTrue(plan.sendsLook)
        XCTAssertFalse(plan.stopsSymphony)
        XCTAssertFalse(plan.confirmsActiveRuns)
    }

    func testARunningSymphonyGetsTheSendsThenStopsAfterConfirming() {
        let plan = QuitPlan(symphonyRunning: true, symphonyStopping: false, stoppedToQuit: false, holdsAnswer: true, holdsLook: true)
        XCTAssertFalse(plan.endsNow)
        XCTAssertTrue(plan.stopsSymphony)
        XCTAssertTrue(plan.sendsHeldAnswer)
        XCTAssertTrue(plan.sendsLook)
        XCTAssertTrue(plan.confirmsActiveRuns)
    }

    func testAStoppingSymphonyIsNotConfirmedAgain() {
        let plan = QuitPlan(symphonyRunning: true, symphonyStopping: true, stoppedToQuit: true, holdsAnswer: false, holdsLook: false)
        XCTAssertTrue(plan.stopsSymphony)
        XCTAssertFalse(plan.confirmsActiveRuns)
    }

    func testABoundedSendThatAnswersFinishesInTime() async {
        let finished = await Bounded.wait(seconds: 5) {}
        XCTAssertTrue(finished)
    }

    func testABoundedSendThatNeverAnswersDoesNotHoldTheQuit() async {
        let started = Date()
        let finished = await Bounded.wait(seconds: 0.1) {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        }
        XCTAssertFalse(finished)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testStopCompletesAtOnceWhenSymphonyAlreadyExited() {
        var waiters = StopWaiters()
        var completed = false
        XCTAssertFalse(waiters.add({ completed = true }, running: false))
        XCTAssertTrue(completed)
        XCTAssertTrue(waiters.isEmpty)
    }

    func testStopWaitsForTheExitWhileSymphonyRuns() {
        var waiters = StopWaiters()
        var completed = 0
        XCTAssertTrue(waiters.add({ completed += 1 }, running: true))
        XCTAssertTrue(waiters.add(nil, running: true))
        XCTAssertEqual(completed, 0)
        waiters.exited().forEach { $0() }
        XCTAssertEqual(completed, 1)
        XCTAssertTrue(waiters.exited().isEmpty)
    }

    func testLockedFlag() {
        let flag = LockedFlag()
        XCTAssertFalse(flag.isSet)
        flag.set(true)
        XCTAssertTrue(flag.isSet)
    }

    func testNotQuitReasonSaysTheVersionStays() {
        XCTAssertEqual(
            UpdateLaunch.notQuitReason(logPath: "~/Library/Logs/symphony/update.log"),
            "the app didn't quit in time, so this version stays and Symphony starts again; see ~/Library/Logs/symphony/update.log"
        )
    }
}

/// The app watches the update helper: its exit while the app runs means the update didn't apply.
final class ProcessExitWatchTests: XCTestCase {
    private let queue = DispatchQueue(label: "ProcessExitWatchTests")
    private var directory: URL!

    override func setUpWithError() throws {
        directory = uniqueTemporaryDirectory("ProcessExitWatchTests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testReportsTheHelpersExitAndReapsIt() throws {
        let exited = expectation(description: "helper exited")
        var status: ChildExit?
        let pid = try ChildProcess.spawnDetached(helper("exit 1"), logURL: directory.appendingPathComponent("log"))
        let watch = ProcessExitWatch(pid: pid, queue: queue) { exit in
            status = exit
            exited.fulfill()
        }

        wait(for: [exited], timeout: 5)
        XCTAssertEqual(queue.sync { status }, .exited(1))
        XCTAssertEqual(watch.pid, pid)
        // Reaped: no zombie is left with that pid.
        XCTAssertNotEqual(kill(pid, 0), 0)
    }

    func testACancelledWatchReportsNothing() throws {
        let pid = try ChildProcess.spawnDetached(helper("sleep 0.3"), logURL: directory.appendingPathComponent("log"))
        let reported = expectation(description: "no report")
        reported.isInverted = true
        let watch = ProcessExitWatch(pid: pid, queue: queue) { _ in reported.fulfill() }
        queue.sync { watch.cancel() }

        wait(for: [reported], timeout: 1)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    private func helper(_ script: String) -> ChildLaunch {
        ChildLaunch(
            executable: "/bin/sh",
            arguments: ["-c", script],
            workingDirectory: directory.path,
            environment: ["PATH": "/usr/bin:/bin"]
        )
    }
}
