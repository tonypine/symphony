import XCTest
@testable import SymphonyBarCore

final class QAScriptTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = uniqueTemporaryDirectory("qa-script")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPendingCommandsAreReadInNameOrderSkippingHiddenFiles() throws {
        let commands = root.appendingPathComponent("commands", isDirectory: true)
        XCTAssertEqual(QAScript.pendingCommands(in: commands), [])

        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        try "Restart Symphony\n".write(to: commands.appendingPathComponent("002"), atomically: false, encoding: .utf8)
        try " Start Symphony ".write(to: commands.appendingPathComponent("001"), atomically: false, encoding: .utf8)
        // Still being written: a test renames it once complete.
        try "Quit".write(to: commands.appendingPathComponent(".003"), atomically: false, encoding: .utf8)

        XCTAssertEqual(
            QAScript.pendingCommands(in: commands),
            [
                QAScript.Command(file: commands.appendingPathComponent("001"), title: "Start Symphony"),
                QAScript.Command(file: commands.appendingPathComponent("002"), title: "Restart Symphony"),
            ]
        )
    }

    func testStatusIsWrittenAsJSONWithANullSymphonyPID() throws {
        var status = QAScript.Status(
            pid: 42,
            version: "0.0.1.108",
            build: 108,
            appPath: "/qa/Applications/Symphony.app",
            symphonyPID: nil,
            menu: [QAScript.MenuItem(title: "Start Symphony", enabled: true)],
            alerts: [QAScript.Alert(title: "Symphony wasn't restarted", message: "symphony.yml is broken")],
            presses: [QAScript.Press(command: "001", title: "Restart Symphony", result: .pressed)]
        )
        let file = root.appendingPathComponent("status.json")

        try QAScript.write(status, to: file)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        XCTAssertEqual(object["pid"] as? Int, 42)
        XCTAssertEqual(object["build"] as? Int, 108)
        XCTAssertEqual(object["app_path"] as? String, "/qa/Applications/Symphony.app")
        XCTAssertTrue(object["symphony_pid"] is NSNull)
        XCTAssertEqual((object["menu"] as? [[String: Any]])?.first?["enabled"] as? Bool, true)
        XCTAssertEqual((object["presses"] as? [[String: Any]])?.first?["result"] as? String, "pressed")
        XCTAssertEqual(try JSONDecoder().decode(QAScript.Status.self, from: Data(contentsOf: file)), status)

        status.symphonyPID = 4321
        try QAScript.write(status, to: file)
        XCTAssertEqual(try JSONDecoder().decode(QAScript.Status.self, from: Data(contentsOf: file)).symphonyPID, 4321)
    }
}
