import XCTest
@testable import SymphonyBarCore

final class UpdateLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateLogTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLinesAreTimestampedAndAppended() throws {
        let log = UpdateLog(directory: directory.appendingPathComponent("logs"), source: "build 774")
        let at = Date(timeIntervalSince1970: 1_793_417_888) // 2026-10-31T03:38:08Z

        log.append("drain done: agent runs finished and Symphony stopped", at: at)
        log.append("handing v0.0.1.774 over to the update helper; quitting", at: at.addingTimeInterval(1))

        XCTAssertEqual(log.url.lastPathComponent, "update.log")
        XCTAssertEqual(
            try String(contentsOf: log.url, encoding: .utf8),
            "2026-10-31T03:38:08Z [build 774] drain done: agent runs finished and Symphony stopped\n"
                + "2026-10-31T03:38:09Z [build 774] handing v0.0.1.774 over to the update helper; quitting\n"
        )
    }

    func testAnUnwritableLogChangesNothing() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A file where the log's folder should be: neither the folder nor the log can be made.
        let blocked = directory.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let log = UpdateLog(directory: blocked, source: "build 1")

        log.append("lost")

        XCTAssertFalse(FileManager.default.fileExists(atPath: log.url.path))
    }

    func testPathAbbreviatesTheHomeFolder() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let log = UpdateLog(directory: home.appendingPathComponent("Library/Logs/symphony"), source: "build 1")

        XCTAssertEqual(log.path, "~/Library/Logs/symphony/update.log")
    }

    func testRotatesOnlyALargeLog() throws {
        let log = UpdateLog(directory: directory, source: "build 1")
        let old = directory.appendingPathComponent("update.log.1")

        log.rotateIfLarge(maxBytes: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "no log, nothing to rotate")

        log.append("short")
        let small = try String(contentsOf: log.url, encoding: .utf8)
        log.rotateIfLarge(maxBytes: 1_000)
        XCTAssertEqual(try String(contentsOf: log.url, encoding: .utf8), small)

        try Data("older".utf8).write(to: old)
        log.rotateIfLarge(maxBytes: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.url.path))
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), small, "the older rotated log is replaced")
    }

    func testLaunchMarkerAndFailure() throws {
        let cache = directory.appendingPathComponent("cache")

        UpdateLaunch.markLaunched(in: cache, build: 774)
        XCTAssertEqual(
            try String(contentsOf: cache.appendingPathComponent(UpdateLaunch.launchedName), encoding: .utf8),
            "774\n"
        )

        XCTAssertFalse(UpdateLaunch.takeFailure(in: cache))
        try Data("30\n".utf8).write(to: cache.appendingPathComponent(UpdateLaunch.failedName))
        XCTAssertTrue(UpdateLaunch.takeFailure(in: cache))
        XCTAssertFalse(UpdateLaunch.takeFailure(in: cache), "read once, so a later launch doesn't act on it again")

        try Data("30\n".utf8).write(to: cache.appendingPathComponent(UpdateLaunch.failedName))
        UpdateLaunch.clearFailure(in: cache)
        XCTAssertFalse(UpdateLaunch.takeFailure(in: cache), "an update clears what an earlier one left")
    }
}
