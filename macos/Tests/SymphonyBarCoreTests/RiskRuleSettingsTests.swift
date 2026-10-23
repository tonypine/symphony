import XCTest
@testable import SymphonyBarCore

final class RiskRuleSettingsTests: XCTestCase {
    func testMissingOrNullKeysAreSymphonysDefaults() throws {
        XCTAssertEqual(try RiskRuleSettings.values(in: ""), RiskRuleSettings())
        XCTAssertEqual(try RiskRuleSettings.values(in: "auto_review:\n  model: x\n"), RiskRuleSettings())
        let nulls = try RiskRuleSettings.values(in: block("size_counts: null\n      on_match:\n        paths:"))
        XCTAssertEqual(nulls.sizeCounts, .total)
        for rule in RiskRule.allCases {
            XCTAssertEqual(nulls.match(for: rule), .inform)
        }
    }

    func testReadsEachRuleAndTheSizeCount() throws {
        let yaml = block("size_counts: added  # deletions don't count\n      on_match:\n        busy_files: ask\n        paths: inform")
        let settings = try RiskRuleSettings.values(in: yaml)
        XCTAssertEqual(settings.sizeCounts, .added)
        XCTAssertEqual(settings.match(for: .busyFiles), .ask)
        XCTAssertEqual(settings.match(for: .paths), .inform)
        XCTAssertEqual(settings.match(for: .dependencies), .inform)
    }

    func testAnotherValueIsReported() {
        XCTAssertThrowsError(try RiskRuleSettings.values(in: block("on_match:\n        busy_files: warn"))) { error in
            XCTAssertEqual(error as? RiskRuleSettingsError, .unreadable(key: "busy_files", value: "warn"))
        }
        XCTAssertThrowsError(try RiskRuleSettings.values(in: block("size_counts: removed"))) { error in
            XCTAssertEqual(error as? RiskRuleSettingsError, .unreadable(key: "size_counts", value: "removed"))
        }
    }

    func testAnInlineBlockIsReported() {
        let yaml = "auto_review:\n  acceptance_gate:\n    escalate: {labels: []}\n"
        XCTAssertThrowsError(try RiskRuleSettings.values(in: yaml)) { error in
            XCTAssertEqual(error as? RiskRuleSettingsError, .notABlock("escalate"))
        }
        XCTAssertThrowsError(try RiskRuleSettings.updating(yaml, from: RiskRuleSettings(), to: RiskRuleSettings(sizeCounts: .added))) { error in
            XCTAssertEqual(error as? RiskRuleSettingsError, .notABlock("escalate"))
        }
    }

    func testUpdatingWritesOnlyWhatChangedAndAddsTheMissingBlocks() throws {
        let yaml = "auto_review:\n  model: x\n"
        XCTAssertEqual(try RiskRuleSettings.updating(yaml, from: RiskRuleSettings(), to: RiskRuleSettings()), yaml)

        let asking = RiskRuleSettings(onMatch: [.busyFiles: .ask])
        let written = try RiskRuleSettings.updating(yaml, from: RiskRuleSettings(), to: asking)
        XCTAssertEqual(
            written,
            "auto_review:\n  acceptance_gate:\n    escalate:\n      on_match:\n        busy_files: ask\n  model: x\n"
        )
        XCTAssertEqual(try RiskRuleSettings.values(in: written), asking)
    }

    func testUpdatingRewritesTheLineAndKeepsTheOtherRules() throws {
        let yaml = block("max_changed_lines: 900\n      size_counts: total  # every line")
        XCTAssertEqual(
            try RiskRuleSettings.updating(yaml, from: RiskRuleSettings(), to: RiskRuleSettings(sizeCounts: .added)),
            block("max_changed_lines: 900\n      size_counts: added  # every line")
        )
    }

    func testEveryRuleHasAMatchWhateverWasGiven() {
        XCTAssertEqual(RiskRuleSettings().onMatch.count, RiskRule.allCases.count)
        XCTAssertEqual(RiskRuleSettings(onMatch: [.paths: .ask]).onMatch[.dependencies], .inform)
    }

    func testEveryChoiceHasWords() {
        for rule in RiskRule.allCases {
            XCTAssertFalse(rule.title.isEmpty)
            XCTAssertFalse(rule.explanation.isEmpty)
            XCTAssertEqual(rule.id, rule.rawValue)
        }
        for match in RiskRuleMatch.allCases {
            XCTAssertFalse(match.title.isEmpty)
            XCTAssertEqual(match.id, match.rawValue)
        }
        for count in ChangeSizeCount.allCases {
            XCTAssertFalse(count.title.isEmpty)
            XCTAssertFalse(count.explanation.isEmpty)
            XCTAssertEqual(count.id, count.rawValue)
        }
        XCTAssertEqual(RiskRule.allCases.map(\.rawValue), ["paths", "diff_patterns", "dependencies", "max_changed_lines", "busy_files"])
    }

    func testErrorDescriptions() {
        XCTAssertEqual(
            RiskRuleSettingsError.notABlock("escalate").errorDescription,
            "`escalate:` in symphony.yml is not an indented block. Change the risk rules by hand."
        )
        XCTAssertEqual(
            RiskRuleSettingsError.unreadable(key: "size_counts", value: "removed").errorDescription,
            "`size_counts: removed` in symphony.yml is not a value Symphony takes. Change it by hand."
        )
    }

    func testTheFileIsWrittenOnlyWhenTheCheckPasses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("symphony.yml").path
        try "auto_review:\n  model: x\n".write(toFile: path, atomically: true, encoding: .utf8)
        let file = SymphonyConfigFile(path: path)
        let asking = RiskRuleSettings(onMatch: [.paths: .ask], sizeCounts: .added)

        let rejected = try await file.writeRiskRuleSettings(asking, from: RiskRuleSettings()) { _ in .failed("nope") }
        XCTAssertEqual(rejected, .failed("nope"))
        XCTAssertEqual(try file.readRiskRuleSettings(), RiskRuleSettings())

        let passed = try await file.writeRiskRuleSettings(asking, from: RiskRuleSettings()) { _ in .passed }
        XCTAssertEqual(passed, .passed)
        let read = try file.readRiskRuleSettings()
        XCTAssertEqual(read.match(for: .paths), .ask)
        XCTAssertEqual(read.sizeCounts, .added)
    }

    /// `auto_review.acceptance_gate.escalate` holding `lines`.
    private func block(_ lines: String) -> String {
        "auto_review:\n  acceptance_gate:\n    escalate:\n      \(lines)\n"
    }
}
