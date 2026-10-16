import XCTest
@testable import SymphonyBarCore

final class QAStatusMenuRequestTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = uniqueTemporaryDirectory("qa-status-menu")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func ask(pid: Int32) throws {
        let folder = root.appendingPathComponent(QAStatusMenuRequest.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent(QAStatusMenuRequest.fileName(pid: pid)))
    }

    func testAQAModeAppTakesItsOwnRequestOnce() throws {
        let request = try XCTUnwrap(QAStatusMenuRequest(qaMode: QAMode(root: root), pid: 4242))
        XCTAssertEqual(request.file.path, root.appendingPathComponent("status-menu/open-4242").path)
        XCTAssertFalse(request.take())

        try ask(pid: 4242)

        XCTAssertTrue(request.take())
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.file.path))
        XCTAssertFalse(request.take())
    }

    func testAnotherAppsRequestIsLeftForIt() throws {
        let request = try XCTUnwrap(QAStatusMenuRequest(qaMode: QAMode(root: root), pid: 4242))
        try ask(pid: 4343)

        XCTAssertFalse(request.take())
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("status-menu/open-4343").path))
    }

    func testAnAppOutsideQAModeIgnoresRequests() throws {
        try ask(pid: ProcessInfo.processInfo.processIdentifier)

        XCTAssertNil(QAStatusMenuRequest(qaMode: AppStores(environment: [:]).qaMode))
        XCTAssertNil(QAStatusMenuRequest(qaMode: nil, pid: 4242))
        // The app's own PID by default.
        let request = try XCTUnwrap(QAStatusMenuRequest(qaMode: QAMode(root: root)))
        XCTAssertTrue(request.take())
    }
}
