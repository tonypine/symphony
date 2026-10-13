import XCTest
@testable import SymphonyBarCore

final class BuiltInTicketPatternsTests: XCTestCase {
    func testAMissingOrNullKeyIsOn() throws {
        XCTAssertTrue(try BuiltInTicketPatterns.isOn(in: ""))
        XCTAssertTrue(try BuiltInTicketPatterns.isOn(in: "auto_review:\n  model: x\n"))
        XCTAssertTrue(try BuiltInTicketPatterns.isOn(in: block("ticket_patterns_builtin: null")))
        XCTAssertTrue(try BuiltInTicketPatterns.isOn(in: block("ticket_patterns_builtin:")))
    }

    func testReadsTrueAndFalse() throws {
        XCTAssertTrue(try BuiltInTicketPatterns.isOn(in: block("ticket_patterns_builtin: True")))
        XCTAssertFalse(try BuiltInTicketPatterns.isOn(in: block("ticket_patterns_builtin: false  # only ours")))
    }

    func testAnotherValueIsReported() {
        XCTAssertThrowsError(try BuiltInTicketPatterns.isOn(in: block("ticket_patterns_builtin: maybe"))) { error in
            XCTAssertEqual(error as? BuiltInTicketPatternsError, .unreadable("maybe"))
        }
    }

    func testAnInlineBlockIsReported() {
        let yaml = "auto_review:\n  acceptance_gate:\n    escalate: {labels: []}\n"
        XCTAssertThrowsError(try BuiltInTicketPatterns.isOn(in: yaml)) { error in
            XCTAssertEqual(error as? BuiltInTicketPatternsError, .notABlock("escalate"))
        }
        XCTAssertThrowsError(try BuiltInTicketPatterns.setting(false, in: yaml)) { error in
            XCTAssertEqual(error as? BuiltInTicketPatternsError, .notABlock("escalate"))
        }
    }

    func testSettingAddsTheMissingBlocks() throws {
        let yaml = "auto_review:\n  model: x\n"
        let off = try BuiltInTicketPatterns.setting(false, in: yaml)
        XCTAssertEqual(
            off,
            "auto_review:\n  acceptance_gate:\n    escalate:\n      ticket_patterns_builtin: false\n  model: x\n"
        )
        XCTAssertFalse(try BuiltInTicketPatterns.isOn(in: off))
    }

    func testSettingRewritesTheLineAndKeepsTheOtherRules() throws {
        let yaml = block("ticket_patterns:\n        - 'ours'\n      ticket_patterns_builtin: false  # misfires")
        XCTAssertEqual(
            try BuiltInTicketPatterns.setting(true, in: yaml),
            block("ticket_patterns:\n        - 'ours'\n      ticket_patterns_builtin: true  # misfires")
        )
    }

    func testTheRepoChoiceMapsToItsOverride() {
        for choice in BuiltInTicketPatternsChoice.allCases {
            XCTAssertEqual(BuiltInTicketPatternsChoice(override: choice.override), choice)
            XCTAssertFalse(choice.title.isEmpty)
            XCTAssertFalse(choice.explanation.isEmpty)
            XCTAssertEqual(choice.id, choice.rawValue)
        }
        XCTAssertNil(BuiltInTicketPatternsChoice.inherit.override)
        XCTAssertEqual(BuiltInTicketPatternsChoice.off.override, false)
    }

    func testErrorDescriptions() {
        XCTAssertEqual(
            BuiltInTicketPatternsError.notABlock("escalate").errorDescription,
            "`escalate:` in symphony.yml is not an indented block. Change the built-in ticket patterns by hand."
        )
        XCTAssertEqual(
            BuiltInTicketPatternsError.unreadable("maybe").errorDescription,
            "`ticket_patterns_builtin: maybe` in symphony.yml is not true or false. Change it by hand."
        )
    }

    func testTheFileIsWrittenOnlyWhenTheCheckPasses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("symphony.yml").path
        try "auto_review:\n  model: x\n".write(toFile: path, atomically: true, encoding: .utf8)
        let file = SymphonyConfigFile(path: path)

        let rejected = try await file.writeBuiltInTicketPatterns(false) { _ in .failed("nope") }
        XCTAssertEqual(rejected, .failed("nope"))
        XCTAssertTrue(try file.readBuiltInTicketPatterns())

        let passed = try await file.writeBuiltInTicketPatterns(false) { _ in .passed }
        XCTAssertEqual(passed, .passed)
        XCTAssertFalse(try file.readBuiltInTicketPatterns())
    }

    /// `auto_review.acceptance_gate.escalate` holding `lines`.
    private func block(_ lines: String) -> String {
        "auto_review:\n  acceptance_gate:\n    escalate:\n      \(lines)\n"
    }
}
