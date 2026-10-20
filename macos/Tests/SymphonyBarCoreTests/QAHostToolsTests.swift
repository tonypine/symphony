import XCTest
@testable import SymphonyBarCore

final class QAHostToolsTests: XCTestCase {
    private let config = """
        # Symphony operator config.
        auto_review:
          playbooks:
            macos_app:
              requires: [go, pg_ctl]   # on the QA VM
        agent:
          runtime: codex

        """

    // MARK: Reading

    func testReadsAnInlineList() throws {
        XCTAssertEqual(try QAHostTools.values(in: config), QAHostTools(tools: ["go", "pg_ctl"]))
    }

    func testReadsABlockListAndASingleName() throws {
        let block = "auto_review:\n  playbooks:\n    macos_app:\n      requires:\n        - go\n        - jq\n"
        XCTAssertEqual(try QAHostTools.values(in: block), QAHostTools(tools: ["go", "jq"]))
        XCTAssertEqual(try QAHostTools.values(in: "auto_review:\n  playbooks:\n    macos_app:\n      requires: go\n"), QAHostTools(tools: ["go"]))
    }

    func testMissingEmptyAndNullReadAsNoTools() throws {
        let none = QAHostTools()
        XCTAssertEqual(try QAHostTools.values(in: ""), none)
        XCTAssertEqual(try QAHostTools.values(in: "auto_review:\n  model: x\n"), none)
        XCTAssertEqual(try QAHostTools.values(in: "auto_review:\n  playbooks:\n    macos_app:\n      requires: []\n"), none)
        XCTAssertEqual(try QAHostTools.values(in: "auto_review:\n  playbooks:\n    macos_app:\n      requires: null\n"), none)
        XCTAssertEqual(try QAHostTools.values(in: "auto_review:\n  playbooks:\n    web:\n      requires: [go]\n"), none)
    }

    func testRefusesAnInlineSection() {
        XCTAssertThrowsError(try QAHostTools.values(in: "auto_review:\n  playbooks: {macos_app: {requires: [go]}}\n")) { error in
            XCTAssertEqual(error as? QAHostToolsError, .notABlock("playbooks"))
        }
        XCTAssertEqual(
            QAHostToolsError.notABlock("playbooks").errorDescription,
            "`playbooks:` in symphony.yml is not an indented block. Change the QA host tools by hand."
        )
    }

    // MARK: The field

    func testTheFieldSplitsOnCommasAndSpacesWithoutRepeats() {
        XCTAssertEqual(QAHostTools(text: " go, pg_ctl  initdb,,go ").tools, ["go", "pg_ctl", "initdb"])
        XCTAssertEqual(QAHostTools(text: "").tools, [])
        XCTAssertEqual(QAHostTools(tools: ["go", "pg_ctl"]).text, "go, pg_ctl")
    }

    // MARK: Writing

    func testWritesAnInlineListOnOneLine() throws {
        let updated = try QAHostTools.updating(config, from: QAHostTools(tools: ["go", "pg_ctl"]), to: QAHostTools(tools: ["go", "pg_ctl", "jq"]))

        XCTAssertEqual(changedLines(config, updated), ["      requires: [go, pg_ctl, jq]   # on the QA VM"])
        XCTAssertEqual(try QAHostTools.values(in: updated), QAHostTools(tools: ["go", "pg_ctl", "jq"]))
    }

    func testClearsTheList() throws {
        let updated = try QAHostTools.updating(config, from: QAHostTools(tools: ["go", "pg_ctl"]), to: QAHostTools())
        XCTAssertEqual(changedLines(config, updated), ["      requires: []   # on the QA VM"])
    }

    func testUnchangedToolsLeaveTheTextAlone() throws {
        let existing = QAHostTools(tools: ["go", "pg_ctl"])
        XCTAssertEqual(try QAHostTools.updating(config, from: existing, to: existing), config)
    }

    func testInsertsTheSectionsWhenMissing() throws {
        XCTAssertEqual(
            try QAHostTools.updating("agent:\n  runtime: codex\n", from: QAHostTools(), to: QAHostTools(tools: ["go"])),
            "agent:\n  runtime: codex\nauto_review:\n  playbooks:\n    macos_app:\n      requires: [go]\n"
        )
        XCTAssertEqual(
            try QAHostTools.updating("auto_review:\n  playbooks:\n    macos_app:\n      build: make app\n", from: QAHostTools(), to: QAHostTools(tools: ["go"])),
            "auto_review:\n  playbooks:\n    macos_app:\n      requires: [go]\n      build: make app\n"
        )
    }

    func testRefusesWhatItCannotWrite() {
        XCTAssertThrowsError(try QAHostTools.updating(config, from: QAHostTools(), to: QAHostTools(tools: ["go", "pg:ctl"]))) { error in
            XCTAssertEqual(error as? QAHostToolsError, .invalidName("pg:ctl"))
        }
        let block = "auto_review:\n  playbooks:\n    macos_app:\n      requires:\n        - go\n"
        XCTAssertThrowsError(try QAHostTools.updating(block, from: QAHostTools(tools: ["go"]), to: QAHostTools(tools: ["jq"]))) { error in
            XCTAssertEqual(error as? QAHostToolsError, .blockList)
        }
        XCTAssertThrowsError(
            try QAHostTools.updating("auto_review:\n  playbooks: {}\n", from: QAHostTools(), to: QAHostTools(tools: ["go"]))
        ) { error in
            XCTAssertEqual(error as? QAHostToolsError, .notABlock("playbooks"))
        }
        XCTAssertEqual(QAHostToolsError.blockList.errorDescription, "`requires:` in symphony.yml is a block list. Change the QA host tools by hand.")
        XCTAssertEqual(
            QAHostToolsError.invalidName("pg:ctl").errorDescription,
            "`pg:ctl` is not an executable name. Use letters, digits, `.`, `_`, `+` or `-`."
        )
    }

    // MARK: The file

    func testFileWriteRunsTheCheckOnTheNewTextFirst() async throws {
        let directory = uniqueTemporaryDirectory("qa-host-tools")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("symphony.yml")
        try config.write(to: url, atomically: false, encoding: .utf8)
        let file = SymphonyConfigFile(path: url.path)
        let new = QAHostTools(tools: ["go"])
        var checked: String?

        let result = try await file.writeQAHostTools(new, from: try file.readQAHostTools()) { path in
            checked = try? String(contentsOfFile: path, encoding: .utf8)
            return .passed
        }

        XCTAssertEqual(result, .passed)
        XCTAssertEqual(checked, try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(try file.readQAHostTools(), new)
    }

    // MARK: Helpers

    /// Lines of `updated` that differ from `original`, for texts with the same number of lines.
    private func changedLines(_ original: String, _ updated: String) -> [String] {
        let before = original.components(separatedBy: "\n")
        let after = updated.components(separatedBy: "\n")
        XCTAssertEqual(before.count, after.count)
        return zip(before, after).filter { $0 != $1 }.map(\.1)
    }
}
