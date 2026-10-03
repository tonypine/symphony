import Darwin
import XCTest
@testable import SymphonyBarCore

/// Spawns real processes to check process groups, signals and cleanup.
final class ChildProcessTests: XCTestCase {
    private let queue = DispatchQueue(label: "ChildProcessTests")
    private var directory: URL!
    private var log: URL!

    override func setUpWithError() throws {
        directory = uniqueTemporaryDirectory("ChildProcessTests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = try ChildLog.rotate(in: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func launch(_ script: String, environment: [String: String] = [:]) -> ChildLaunch {
        ChildLaunch(
            executable: "/bin/sh",
            arguments: ["-c", script],
            workingDirectory: directory.path,
            environment: environment.merging(["PATH": "/usr/bin:/bin"]) { mine, _ in mine }
        )
    }

    /// Spawns `script` and returns the child plus an expectation that records the exit.
    private func spawn(
        _ script: String,
        environment: [String: String] = [:]
    ) throws -> (ChildProcess, XCTestExpectation, () -> (ChildExit, Bool)?) {
        let exited = expectation(description: "child exited")
        var result: (ChildExit, Bool)?
        let child = try ChildProcess.spawn(
            launch(script, environment: environment),
            logURL: log,
            queue: queue,
            treeRefreshInterval: 0.05
        ) { exit, requested in
            result = (exit, requested)
            exited.fulfill()
        }
        return (child, exited, { self.queue.sync { result } })
    }

    private func logText() throws -> String {
        try String(contentsOf: log, encoding: .utf8)
    }

    /// Waits until the log has `count` lines and returns them.
    private func waitForLogLines(_ count: Int, timeout: TimeInterval = 5) throws -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let lines = try logText().split(separator: "\n").map(String.init)
            if lines.count >= count { return lines }
            usleep(20_000)
        }
        XCTFail("log never reached \(count) lines: \(try logText())")
        return []
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private func waitUntilGone(_ pid: pid_t, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isAlive(pid) { return true }
            usleep(20_000)
        }
        return false
    }

    func testRunsInTheCheckoutWithTheEnvironmentAndLogsBothStreams() throws {
        let (_, exited, result) = try spawn(
            "echo out; echo err >&2; pwd -P; echo \"$SECRET_VALUE\"; read line || echo stdin-empty",
            environment: ["SECRET_VALUE": "from env"]
        )
        wait(for: [exited], timeout: 10)

        XCTAssertEqual(result()?.0, .exited(0))
        XCTAssertEqual(result()?.1, false)
        let realDirectory = try XCTUnwrap(realpath(directory.path, nil).map { path in
            defer { free(path) }
            return String(cString: path)
        })
        XCTAssertEqual(try logText(), "out\nerr\n\(realDirectory)\nfrom env\nstdin-empty\n")
    }

    func testReportsTheExitStatus() throws {
        let (child, exited, result) = try spawn("exit 3")
        wait(for: [exited], timeout: 10)

        XCTAssertEqual(result()?.0, .exited(3))
        XCTAssertFalse(queue.sync { child.isRunning })
    }

    func testDetachedProcessRunsInItsOwnSessionAndLogs() throws {
        let marker = directory.appendingPathComponent("done")
        let pid = try ChildProcess.spawnDetached(launch("echo helper output; sleep 1; touch done"), logURL: log)

        XCTAssertEqual(getsid(pid), pid, "a new session, so the process outlives the app")
        XCTAssertNotEqual(getsid(pid), getsid(0))
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, 0), pid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try logText(), "helper output\n")
    }

    func testRunsInItsOwnProcessGroup() throws {
        let (child, exited, _) = try spawn("sleep 30")
        let record = try XCTUnwrap(ProcessTree.snapshot().first { $0.pid == child.pid })

        XCTAssertEqual(record.groupID, child.pid)
        XCTAssertNotEqual(record.groupID, getpgrp())

        queue.sync { child.stop(timeout: 5) }
        wait(for: [exited], timeout: 10)
    }

    func testStopSendsSigtermToTheWholeGroup() throws {
        // The grandchild shares the group, so SIGTERM reaches it too.
        let (child, exited, result) = try spawn("sleep 30 & echo $!; wait")
        let grandchild = try XCTUnwrap(pid_t(waitForLogLines(1)[0]))

        queue.sync { child.stop(timeout: 10) }
        wait(for: [exited], timeout: 10)

        XCTAssertEqual(result()?.0, .signaled(SIGTERM))
        XCTAssertEqual(result()?.1, true)
        XCTAssertTrue(waitUntilGone(grandchild))
    }

    func testStopEscalatesToSigkillAfterTheTimeout() throws {
        let (child, exited, result) = try spawn("trap '' TERM; echo ready; exec sleep 30")
        _ = try waitForLogLines(1)

        let stoppedAt = Date()
        queue.sync {
            child.stop(timeout: 0.3)
            child.stop(timeout: 0.3)  // A second stop changes nothing.
        }
        wait(for: [exited], timeout: 10)

        XCTAssertEqual(result()?.0, .signaled(SIGKILL))
        XCTAssertEqual(result()?.1, true)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(stoppedAt), 0.3)
    }

    func testStopKillsDescendantsThatLeftTheGroup() throws {
        // Like an Erlang port program: the grandchild starts its own session and ignores SIGTERM.
        let (child, exited, result) = try spawn(
            "/usr/bin/perl -MPOSIX -e '$|=1; my $p = fork(); if (!$p) { setsid(); $SIG{TERM} = q(IGNORE); exec q(/bin/sleep), 30 } print qq($p\\n); sleep 30'"
        )
        let grandchild = try XCTUnwrap(pid_t(waitForLogLines(1)[0]))
        let record = try XCTUnwrap(ProcessTree.snapshot().first { $0.pid == grandchild })
        XCTAssertEqual(record.groupID, grandchild, "grandchild should lead its own group")

        queue.sync { child.stop(timeout: 10) }
        wait(for: [exited], timeout: 10)

        XCTAssertEqual(result()?.1, true)
        XCTAssertTrue(waitUntilGone(grandchild), "grandchild \(grandchild) outlived the stop")
    }

    func testUnexpectedExitAlsoCleansUpDescendants() throws {
        let (_, exited, result) = try spawn(
            "/usr/bin/perl -MPOSIX -e '$|=1; my $p = fork(); if (!$p) { setsid(); exec q(/bin/sleep), 30 } print qq($p\\n); sleep 1; exit 7'"
        )
        let grandchild = try XCTUnwrap(pid_t(waitForLogLines(1)[0]))
        wait(for: [exited], timeout: 10)

        XCTAssertEqual(result()?.0, .exited(7))
        XCTAssertEqual(result()?.1, false)
        XCTAssertTrue(waitUntilGone(grandchild), "grandchild \(grandchild) outlived its parent")
    }

    func testExitCleansUpDescendantsWhoseParentExitedEarlier() throws {
        // The middle process exits first, so the grandchild is reparented to launchd while later tree refreshes
        // run. The same happens when Symphony exits and a refresh lands before the exit is handled.
        let (_, exited, result) = try spawn(
            "/usr/bin/perl -MPOSIX -e '$|=1; my $m = fork(); if (!$m) { my $p = fork(); if (!$p) { setsid(); exec q(/bin/sleep), 30 } print qq($p\\n); select(undef, undef, undef, 0.5); exit 0 } waitpid($m, 0); select(undef, undef, undef, 0.5); exit 7'"
        )
        let grandchild = try XCTUnwrap(pid_t(waitForLogLines(1)[0]))
        wait(for: [exited], timeout: 10)

        XCTAssertEqual(result()?.0, .exited(7))
        XCTAssertEqual(result()?.1, false)
        XCTAssertTrue(waitUntilGone(grandchild), "grandchild \(grandchild) outlived Symphony")
    }

    func testStopAfterExitDoesNothing() throws {
        let (child, exited, result) = try spawn("exit 0")
        wait(for: [exited], timeout: 10)

        queue.sync { child.stop(timeout: 0.1) }

        XCTAssertEqual(result()?.1, false)
        XCTAssertFalse(queue.sync { child.stopRequested })
    }

    func testSpawnFailsForAMissingProgramOrDirectory() {
        var bad = launch("true")
        bad.executable = "/nonexistent/program"
        XCTAssertThrowsError(try ChildProcess.spawn(bad, logURL: log, queue: queue) { _, _ in }) { error in
            XCTAssertEqual((error as? SpawnError)?.code, ENOENT)
            XCTAssertTrue("\(error)".contains("No such file or directory"))
        }

        let missingLog = directory.appendingPathComponent("missing/dir/log")
        XCTAssertThrowsError(try ChildProcess.spawn(launch("true"), logURL: missingLog, queue: queue) { _, _ in }) {
            error in
            XCTAssertEqual((error as? SpawnError)?.step, "open log")
        }
    }
}
