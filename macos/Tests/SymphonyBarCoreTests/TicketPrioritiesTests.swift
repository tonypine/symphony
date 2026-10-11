import XCTest
@testable import SymphonyBarCore

final class TicketPrioritiesTests: XCTestCase {
    private let config = """
        # Symphony operator config.
        tickets:
          priorities: [urgent, high]   # only these may start
        agent:
          runtime: codex

        """

    // MARK: Reading

    func testReadsAnInlineList() throws {
        XCTAssertEqual(try TicketPriorities.values(in: config), TicketPriorities(priorities: [.urgent, .high]))
    }

    func testReadsABlockList() throws {
        let yaml = "tickets:\n  priorities:\n    - urgent\n    - high\n"
        XCTAssertEqual(try TicketPriorities.values(in: yaml), TicketPriorities(priorities: [.urgent, .high]))
    }

    func testReadsNamesNumbersAndAliases() throws {
        XCTAssertEqual(TicketPriority.named("No Priority"), TicketPriority.none)
        let yaml = "tickets:\n  priorities: [1, high, No Priority, 4]\n"
        XCTAssertEqual(
            try TicketPriorities.values(in: yaml),
            TicketPriorities(priorities: [.urgent, .high, .low, .none])
        )
    }

    func testMissingEmptyAndNullReadAsEveryPriority() throws {
        let none = TicketPriorities()
        XCTAssertEqual(try TicketPriorities.values(in: ""), none)
        XCTAssertEqual(try TicketPriorities.values(in: "agent:\n  runtime: codex\n"), none)
        XCTAssertEqual(try TicketPriorities.values(in: "tickets:\n  priorities: []\n"), none)
        XCTAssertEqual(try TicketPriorities.values(in: "tickets:\n  priorities: null\n"), none)
        XCTAssertEqual(TicketPriorities(), none)
    }

    func testIgnoresPrioritiesOutsideTickets() throws {
        let yaml = "priorities: [urgent]\nagent:\n  priorities: [high]\n"
        XCTAssertEqual(try TicketPriorities.values(in: yaml), TicketPriorities())
    }

    func testRefusesWhatItCannotRead() {
        XCTAssertThrowsError(try TicketPriorities.values(in: "tickets:\n  priorities: [urgent, whenever]\n")) { error in
            XCTAssertEqual(error as? TicketPrioritiesError, .unreadable(key: "priorities", value: "whenever"))
        }
        XCTAssertThrowsError(try TicketPriorities.values(in: "tickets: {priorities: [urgent]}\n")) { error in
            XCTAssertEqual(error as? TicketPrioritiesError, .notABlock("tickets"))
        }
        XCTAssertEqual(
            TicketPrioritiesError.unreadable(key: "priorities", value: "whenever").errorDescription,
            "`priorities: whenever` in symphony.yml is not a Linear priority. Change it by hand."
        )
        XCTAssertEqual(
            TicketPrioritiesError.notABlock("tickets").errorDescription,
            "`tickets:` in symphony.yml is not an indented block. Change the allowed ticket priorities by hand."
        )
    }

    // MARK: Writing

    func testWritesAnInlineListOnOneLine() throws {
        let updated = try TicketPriorities.updating(
            config,
            from: TicketPriorities(priorities: [.urgent, .high]),
            to: TicketPriorities(priorities: [.urgent, .high, .low])
        )

        XCTAssertEqual(changedLines(config, updated), ["  priorities: [urgent, high, low]   # only these may start"])
        XCTAssertEqual(try TicketPriorities.values(in: updated), TicketPriorities(priorities: [.urgent, .high, .low]))
    }

    func testWritesLinearOrderWhateverTheSetOrder() throws {
        let updated = try TicketPriorities.updating(
            "tickets:\n  priorities: []\n",
            from: TicketPriorities(),
            to: TicketPriorities(priorities: [.none, .low, .urgent])
        )
        XCTAssertEqual(updated, "tickets:\n  priorities: [urgent, low, none]\n")
    }

    func testClearsTheFilter() throws {
        let updated = try TicketPriorities.updating(
            config,
            from: TicketPriorities(priorities: [.urgent, .high]),
            to: TicketPriorities()
        )

        XCTAssertEqual(changedLines(config, updated), ["  priorities: []   # only these may start"])
        XCTAssertEqual(try TicketPriorities.values(in: updated), TicketPriorities())
    }

    func testUnchangedPrioritiesLeaveTheTextAlone() throws {
        let existing = TicketPriorities(priorities: [.urgent, .high])
        XCTAssertEqual(try TicketPriorities.updating(config, from: existing, to: existing), config)
    }

    func testInsertsTheSectionWhenMissing() throws {
        XCTAssertEqual(
            try TicketPriorities.updating("agent:\n  runtime: codex\n", from: TicketPriorities(), to: TicketPriorities(priorities: [.urgent])),
            "agent:\n  runtime: codex\ntickets:\n  priorities: [urgent]\n"
        )
    }

    func testRefusesToWriteIntoAnInlineSection() {
        XCTAssertThrowsError(
            try TicketPriorities.updating("tickets: {priorities: [urgent]}\n", from: TicketPriorities(priorities: [.urgent]), to: TicketPriorities(priorities: [.high]))
        ) { error in
            XCTAssertEqual(error as? TicketPrioritiesError, .notABlock("tickets"))
        }
    }

    // MARK: The file

    func testFileWriteRunsTheCheckOnTheNewTextFirst() async throws {
        let (directory, url) = try writeConfig()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = SymphonyConfigFile(path: url.path)
        let new = TicketPriorities(priorities: [.urgent, .high, .low])
        var checked: String?

        let result = try await file.writeTicketPriorities(new, from: try file.readTicketPriorities()) { path in
            checked = try? String(contentsOfFile: path, encoding: .utf8)
            return .passed
        }

        XCTAssertEqual(result, .passed)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(checked, written)
        XCTAssertEqual(try file.readTicketPriorities(), new)
        XCTAssertEqual(try siblings(of: url), ["symphony.yml"])
    }

    func testFileWriteLeavesTheFileWhenTheCheckFails() async throws {
        let (directory, url) = try writeConfig()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await SymphonyConfigFile(path: url.path).writeTicketPriorities(
            TicketPriorities(priorities: [.high]),
            from: TicketPriorities(priorities: [.urgent, .high])
        ) { _ in .failed("tickets.priorities is invalid") }

        XCTAssertEqual(result, .failed("tickets.priorities is invalid"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), config)
        XCTAssertEqual(try siblings(of: url), ["symphony.yml"])
    }

    // MARK: Helpers

    private func writeConfig() throws -> (URL, URL) {
        let directory = uniqueTemporaryDirectory("ticket-priorities")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("symphony.yml")
        try config.write(to: url, atomically: false, encoding: .utf8)
        return (directory, url)
    }

    private func siblings(of url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).sorted()
    }

    /// Lines of `updated` that differ from `original`, for texts with the same number of lines.
    private func changedLines(_ original: String, _ updated: String) -> [String] {
        let before = original.components(separatedBy: "\n")
        let after = updated.components(separatedBy: "\n")
        XCTAssertEqual(before.count, after.count)
        return zip(before, after).filter { $0 != $1 }.map(\.1)
    }
}
