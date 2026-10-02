import Darwin
import XCTest
@testable import SymphonyBarCore

final class ShellQuoteTests: XCTestCase {
    func testPlainWordsAreLeftAlone() {
        XCTAssertEqual(ShellWords.quote("./bin/symphony"), "./bin/symphony")
        XCTAssertEqual(ShellWords.quote("--config"), "--config")
        XCTAssertEqual(ShellWords.quote("A=b"), "A=b")
    }

    func testOtherWordsAreSingleQuoted() {
        XCTAssertEqual(ShellWords.quote(""), "''")
        XCTAssertEqual(ShellWords.quote("a b"), "'a b'")
        XCTAssertEqual(ShellWords.quote("$HOME"), "'$HOME'")
        XCTAssertEqual(ShellWords.quote("it's"), "'it'\\''s'")
    }

    func testQuotedWordsSplitBackToTheSameWords() {
        let words = ["", "a b", "it's", "\"q\"", "back\\slash", "$(rm -rf /)", "tab\there", "ünï"]

        XCTAssertEqual(ShellWords.split(words.map(ShellWords.quote).joined(separator: " ")), words)
    }
}

final class ChildLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = uniqueTemporaryDirectory("ChildLogTests").appendingPathComponent("logs", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func contents(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    func testDefaultDirectoryIsUnderLibraryLogs() {
        XCTAssertEqual(
            ChildLog.defaultDirectory(home: URL(fileURLWithPath: "/Users/me")).path,
            "/Users/me/Library/Logs/symphony"
        )
    }

    func testFirstRotationCreatesTheDirectoryAndAnEmptyLog() throws {
        let log = try ChildLog.rotate(in: directory)

        XCTAssertEqual(log.lastPathComponent, "menubar-child.log")
        XCTAssertEqual(try contents("menubar-child.log"), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("menubar-child.log.1").path))
    }

    func testEachRotationKeepsOnlyThePreviousRun() throws {
        let log = try ChildLog.rotate(in: directory)
        try "first run".write(to: log, atomically: false, encoding: .utf8)
        try ChildLog.rotate(in: directory)

        XCTAssertEqual(try contents("menubar-child.log"), "")
        XCTAssertEqual(try contents("menubar-child.log.1"), "first run")

        try "second run".write(to: log, atomically: false, encoding: .utf8)
        try ChildLog.rotate(in: directory)

        XCTAssertEqual(try contents("menubar-child.log.1"), "second run")
    }
}

final class ChildExitTests: XCTestCase {
    func testDecodesWaitStatuses() {
        XCTAssertEqual(ChildExit(waitStatus: 0), .exited(0))
        XCTAssertEqual(ChildExit(waitStatus: 3 << 8), .exited(3))
        XCTAssertEqual(ChildExit(waitStatus: SIGTERM), .signaled(SIGTERM))
        XCTAssertEqual(ChildExit(waitStatus: SIGKILL), .signaled(SIGKILL))
        // Core dump flag (0x80) doesn't change the signal.
        XCTAssertEqual(ChildExit(waitStatus: SIGSEGV | 0x80), .signaled(SIGSEGV))
    }

    func testSummaries() {
        XCTAssertEqual(ChildExit.exited(1).summary, "exited with status 1")
        XCTAssertEqual(ChildExit.signaled(9).summary, "was killed by signal 9")
    }
}

final class ProcessTreeTests: XCTestCase {
    private func record(_ pid: pid_t, parent: pid_t, group: pid_t? = nil, start: UInt64 = 1) -> ProcessRecord {
        ProcessRecord(pid: pid, parentPID: parent, groupID: group ?? pid, startTime: start)
    }

    func testFindsAllDescendantsBreadthFirst() {
        let table = [
            record(1, parent: 0),
            record(10, parent: 1),
            record(11, parent: 10),
            record(12, parent: 10),
            record(13, parent: 11),
            record(20, parent: 1),
            record(21, parent: 20),
        ]

        XCTAssertEqual(ProcessTree.descendants(of: 10, in: table).map(\.pid), [11, 12, 13])
        XCTAssertEqual(ProcessTree.descendants(of: 13, in: table), [])
        XCTAssertEqual(ProcessTree.descendants(of: 99, in: table), [])
    }

    func testIgnoresSelfParentedAndCyclicRows() {
        let table = [record(0, parent: 0), record(5, parent: 6), record(6, parent: 5), record(7, parent: 5)]

        XCTAssertEqual(ProcessTree.descendants(of: 0, in: table), [])
        XCTAssertEqual(ProcessTree.descendants(of: 5, in: table).map(\.pid), [6, 7])
    }

    func testSurvivorsMustMatchPidAndStartTime() {
        let recorded = [record(11, parent: 10, start: 100), record(12, parent: 10, start: 200), record(13, parent: 10)]
        let now = [record(11, parent: 1, start: 100), record(12, parent: 1, start: 999)]

        XCTAssertEqual(ProcessTree.survivors(of: recorded, in: now).map(\.pid), [11])
    }

    func testSnapshotSeesThisProcess() throws {
        let me = try XCTUnwrap(ProcessTree.snapshot().first { $0.pid == getpid() })

        XCTAssertEqual(me.parentPID, getppid())
        XCTAssertEqual(me.groupID, getpgrp())
        XCTAssertGreaterThan(me.startTime, 0)
    }
}

final class SymphonyStateTests: XCTestCase {
    func testBaseURLComesFromTheControlURLFileWithADefault() {
        XCTAssertEqual(SymphonyState.baseURL(controlURLContents: "http://127.0.0.1:4010\n").absoluteString, "http://127.0.0.1:4010")
        XCTAssertEqual(SymphonyState.baseURL(controlURLContents: nil), SymphonyState.defaultBaseURL)
        XCTAssertEqual(SymphonyState.baseURL(controlURLContents: "  "), SymphonyState.defaultBaseURL)
        XCTAssertEqual(SymphonyState.baseURL(controlURLContents: "/tmp/x"), SymphonyState.defaultBaseURL)
        XCTAssertEqual(SymphonyState.defaultBaseURL.absoluteString, "http://127.0.0.1:4000")
    }

    func testBaseURLReadsTheControlURLFile() throws {
        let directory = uniqueTemporaryDirectory("control-url")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("control_url")

        XCTAssertEqual(SymphonyState.baseURL(controlURLFile: file), SymphonyState.defaultBaseURL)
        try "http://127.0.0.1:4010\n".write(to: file, atomically: false, encoding: .utf8)
        XCTAssertEqual(SymphonyState.baseURL(controlURLFile: file).absoluteString, "http://127.0.0.1:4010")
    }

    func testStateURL() {
        XCTAssertEqual(
            SymphonyState.stateURL(base: URL(string: "http://127.0.0.1:4000")!).absoluteString,
            "http://127.0.0.1:4000/api/v1/state"
        )
    }
}
