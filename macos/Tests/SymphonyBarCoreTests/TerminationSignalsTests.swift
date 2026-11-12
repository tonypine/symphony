import Darwin
import XCTest
@testable import SymphonyBarCore

/// Sends real signals to the test process, with the handler installed so they don't end it.
final class TerminationSignalsTests: XCTestCase {
    private let queue = DispatchQueue(label: "TerminationSignalsTests")
    private var directory: URL!
    private var log: URL!

    override func setUpWithError() throws {
        directory = uniqueTemporaryDirectory("TerminationSignalsTests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = try ChildLog.rotate(in: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCallsTheHandlerForEachSignalAndKeepsTheProcessAlive() {
        let received = expectation(description: "signals handled")
        received.expectedFulfillmentCount = 3
        var numbers: [Int32] = []
        let signals = TerminationSignals(queue: queue) { number in
            numbers.append(number)
            received.fulfill()
        }
        defer { signals.cancel() }

        for number in TerminationSignals.defaultSignals { kill(getpid(), number) }

        wait(for: [received], timeout: 5)
        XCTAssertEqual(queue.sync { Set(numbers) }, Set(TerminationSignals.defaultSignals))
    }

    func testCancelRestoresTheDefaultAction() {
        let signals = TerminationSignals(signals: [SIGHUP], queue: queue) { _ in }
        signals.cancel()

        var action = sigaction()
        sigaction(SIGHUP, nil, &action)
        XCTAssertEqual(unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self), unsafeBitCast(SIG_DFL, to: Int.self))
    }

    /// TP-1475: the handler's queue (the app's main queue) is stuck and Symphony has already stopped, so the
    /// fallback ends the process on its own.
    func testFallbackEndsTheProcessWhenTheQueueIsStuckAndNothingIsLeftToStop() {
        let stuck = DispatchQueue(label: "TerminationSignalsTests.stuck")
        stuck.suspend()
        defer { stuck.resume() }
        let exited = expectation(description: "fallback exit")
        let signals = TerminationSignals(
            signals: [SIGUSR2],
            queue: stuck,
            fallback: .init(after: 0.05, canExit: { true }, exit: { number in
                XCTAssertEqual(number, SIGUSR2)
                exited.fulfill()
            })
        ) { _ in }
        defer { signals.cancel() }

        kill(getpid(), SIGUSR2)

        wait(for: [exited], timeout: 5)
    }

    /// While Symphony still runs, the fallback leaves the process alone: exiting would leave Symphony running.
    func testFallbackWaitsWhileSymphonyRuns() {
        let stuck = DispatchQueue(label: "TerminationSignalsTests.stuck")
        stuck.suspend()
        defer { stuck.resume() }
        let exited = expectation(description: "no fallback exit")
        exited.isInverted = true
        let checked = expectation(description: "fallback checked")
        let signals = TerminationSignals(
            signals: [SIGUSR2],
            queue: stuck,
            fallback: .init(after: 0.05, canExit: {
                checked.fulfill()
                return false
            }, exit: { _ in exited.fulfill() })
        ) { _ in }
        defer { signals.cancel() }

        kill(getpid(), SIGUSR2)

        wait(for: [checked], timeout: 5)
        wait(for: [exited], timeout: 0.3)
    }

    /// What the app does on SIGTERM: stop the child, which stops its group and the agents that left it.
    func testSigtermStopsTheChildAndItsAgents() throws {
        let exited = expectation(description: "child exited")
        let launch = ChildLaunch(
            executable: "/bin/sh",
            arguments: [
                "-c",
                // Like an agent under Erlang: own session, and it ignores SIGTERM and stdin EOF.
                "/usr/bin/perl -MPOSIX -e '$|=1; my $p = fork(); if (!$p) { setsid(); $SIG{TERM} = q(IGNORE); exec q(/bin/sleep), 30 } print qq($p\\n); sleep 30'",
            ],
            workingDirectory: directory.path,
            environment: ["PATH": "/usr/bin:/bin"]
        )
        let child = try ChildProcess.spawn(launch, logURL: log, queue: queue, treeRefreshInterval: 0.05) { _, _ in
            exited.fulfill()
        }
        let agent = try XCTUnwrap(pid_t(waitForFirstLogLine()))

        let signals = TerminationSignals(queue: queue) { _ in child.stop(timeout: 5) }
        defer { signals.cancel() }
        kill(getpid(), SIGTERM)

        wait(for: [exited], timeout: 10)
        XCTAssertTrue(waitUntilGone(child.pid), "Symphony \(child.pid) outlived SIGTERM")
        XCTAssertTrue(waitUntilGone(agent), "agent \(agent) outlived SIGTERM")
    }

    private func waitForFirstLogLine(timeout: TimeInterval = 5) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let line = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").first {
                return String(line)
            }
            usleep(20_000)
        }
        XCTFail("the child never logged its agent's pid")
        return ""
    }

    private func waitUntilGone(_ pid: pid_t, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            usleep(20_000)
        }
        return false
    }
}
