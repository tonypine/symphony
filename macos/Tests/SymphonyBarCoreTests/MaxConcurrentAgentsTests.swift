import XCTest
@testable import SymphonyBarCore

final class MaxConcurrentAgentsTests: XCTestCase {
    private let config = """
        # Symphony operator config.
        issues:
          provider: linear

        execution:
          prompts: {}
          concurrency:
            # Keep this low on a personal Linear key.
            max_total: 2  # two agents
            # max_by_issue_state:
            #   rework: 2
          limits:
            max_turns: 8

        workspaces:
          root: ~/work

        """

    func testReadsTheValue() {
        XCTAssertEqual(MaxConcurrentAgents.value(in: config), 2)
    }

    func testChangesOnlyTheValueOnTheMaxTotalLine() throws {
        let updated = try MaxConcurrentAgents.setting(3, in: config)

        XCTAssertEqual(updated, config.replacingOccurrences(of: "max_total: 2  # two agents", with: "max_total: 3  # two agents"))
        XCTAssertEqual(changedLines(config, updated), ["    max_total: 3  # two agents"])
        XCTAssertEqual(MaxConcurrentAgents.value(in: updated), 3)
    }

    func testSettingTheSameValueLeavesTheTextAlone() throws {
        XCTAssertEqual(try MaxConcurrentAgents.setting(2, in: config), config)
    }

    func testIgnoresMaxTotalOutsideAgentConcurrency() {
        let yaml = """
            pull_requests:
              learnings:
                max_total: 7
            concurrency:
              max_total: 8
            execution:
              prompts: {}
            """
        XCTAssertNil(MaxConcurrentAgents.value(in: yaml))
    }

    func testIgnoresCommentedOutKeys() {
        let yaml = """
            execution:
              concurrency:
                # max_total: 4
                max_by_issue_state:
                  rework: 2
            """
        XCTAssertNil(MaxConcurrentAgents.value(in: yaml))
    }

    func testIgnoresKeysThatOnlyStartWithMaxTotal() {
        let yaml = """
            execution:
              concurrency:
                max_total_extra: 4
            """
        XCTAssertNil(MaxConcurrentAgents.value(in: yaml))
    }

    func testNonNumericValueReadsAsNil() {
        XCTAssertNil(MaxConcurrentAgents.value(in: "execution:\n  concurrency:\n    max_total: lots\n"))
    }

    func testInsertsMissingKeyUnderConcurrency() throws {
        let yaml = """
            execution:
              concurrency:
                max_by_issue_state:
                  rework: 2
              limits:
                max_turns: 8

            """
        let updated = try MaxConcurrentAgents.setting(3, in: yaml)

        XCTAssertEqual(updated, """
            execution:
              concurrency:
                max_total: 3
                max_by_issue_state:
                  rework: 2
              limits:
                max_turns: 8

            """)
        XCTAssertEqual(MaxConcurrentAgents.value(in: updated), 3)
    }

    func testInsertsMissingKeyUnderAnEmptyConcurrency() throws {
        let yaml = "execution:\n  concurrency:\n  limits:\n    max_turns: 8\n"
        let updated = try MaxConcurrentAgents.setting(4, in: yaml)

        XCTAssertEqual(updated, "execution:\n  concurrency:\n    max_total: 4\n  limits:\n    max_turns: 8\n")
    }

    func testInsertsConcurrencyWhenAgentHasNone() throws {
        let yaml = """
            execution:
              prompts: {}
              limits:
                max_turns: 8
            """
        let updated = try MaxConcurrentAgents.setting(2, in: yaml)

        XCTAssertEqual(updated, """
            execution:
              concurrency:
                max_total: 2
              prompts: {}
              limits:
                max_turns: 8
            """)
    }

    func testInsertsUnderAnEmptyAgent() throws {
        let updated = try MaxConcurrentAgents.setting(2, in: "execution:\nworkspaces:\n  root: ~/work\n")

        XCTAssertEqual(updated, "execution:\n  concurrency:\n    max_total: 2\nworkspaces:\n  root: ~/work\n")
    }

    func testAddsAnExecutionSectionWhenTheFileHasNone() throws {
        let yaml = "# config\nissues:\n  provider: linear\n"
        let updated = try MaxConcurrentAgents.setting(3, in: yaml)

        XCTAssertEqual(updated, "# config\nissues:\n  provider: linear\nexecution:\n  concurrency:\n    max_total: 3\n")
        XCTAssertEqual(MaxConcurrentAgents.value(in: updated), 3)
    }

    func testAddsAnExecutionSectionToAFileWithoutATrailingNewline() throws {
        let updated = try MaxConcurrentAgents.setting(3, in: "issues:\n  provider: linear")

        XCTAssertEqual(updated, "issues:\n  provider: linear\nexecution:\n  concurrency:\n    max_total: 3")
    }

    func testAddsAnExecutionSectionToAnEmptyFile() throws {
        XCTAssertEqual(try MaxConcurrentAgents.setting(3, in: ""), "execution:\n  concurrency:\n    max_total: 3\n")
    }

    func testFollowsOddIndentation() throws {
        let yaml = """
            execution:
                prompts: {}
                concurrency:
                       max_total: 10
                limits:
                    max_turns: 8
            """
        let updated = try MaxConcurrentAgents.setting(2, in: yaml)

        XCTAssertEqual(changedLines(yaml, updated), ["           max_total: 2"])
        XCTAssertEqual(MaxConcurrentAgents.value(in: yaml), 10)
    }

    func testInsertedKeysFollowTheFilesIndentStep() throws {
        let fourSpaces = "execution:\n    prompts: {}\n"
        XCTAssertEqual(
            try MaxConcurrentAgents.setting(2, in: fourSpaces),
            "execution:\n    concurrency:\n        max_total: 2\n    prompts: {}\n"
        )

        let nestedSiblings = "execution:\n   concurrency:\n      max_by_issue_state: {}\n"
        XCTAssertEqual(
            try MaxConcurrentAgents.setting(2, in: nestedSiblings),
            "execution:\n   concurrency:\n      max_total: 2\n      max_by_issue_state: {}\n"
        )

        let emptyConcurrency = "execution:\n    concurrency:\n"
        XCTAssertEqual(
            try MaxConcurrentAgents.setting(2, in: emptyConcurrency),
            "execution:\n    concurrency:\n        max_total: 2\n"
        )
    }

    func testKeepsSpacingAndComments() throws {
        XCTAssertEqual(
            try MaxConcurrentAgents.setting(5, in: "execution:\n  concurrency:\n    max_total:   2   # note\n"),
            "execution:\n  concurrency:\n    max_total:   5   # note\n"
        )
        XCTAssertEqual(
            try MaxConcurrentAgents.setting(5, in: "execution:  # agents\n  concurrency: # caps\n    max_total: 2\n"),
            "execution:  # agents\n  concurrency: # caps\n    max_total: 5\n"
        )
    }

    func testFillsAnEmptyValue() throws {
        XCTAssertEqual(
            try MaxConcurrentAgents.setting(3, in: "execution:\n  concurrency:\n    max_total:\n"),
            "execution:\n  concurrency:\n    max_total: 3\n"
        )
        XCTAssertEqual(
            try MaxConcurrentAgents.setting(3, in: "execution:\n  concurrency:\n    max_total:   # pick one\n"),
            "execution:\n  concurrency:\n    max_total: 3 # pick one\n"
        )
    }

    func testKeepsWindowsLineEndings() throws {
        let yaml = "execution:\r\n  prompts: {}\r\n  concurrency:\r\n    max_total: 2\r\n"
        XCTAssertEqual(MaxConcurrentAgents.value(in: yaml), 2)
        XCTAssertEqual(
            try MaxConcurrentAgents.setting(3, in: yaml),
            "execution:\r\n  prompts: {}\r\n  concurrency:\r\n    max_total: 3\r\n"
        )
        XCTAssertEqual(
            try MaxConcurrentAgents.setting(3, in: "execution:\r\n  prompts: {}\r\n"),
            "execution:\r\n  concurrency:\r\n    max_total: 3\r\n  prompts: {}\r\n"
        )
    }

    func testRefusesInlineSections() {
        XCTAssertThrowsError(try MaxConcurrentAgents.setting(3, in: "execution: {concurrency: {max_total: 2}}\n")) { error in
            XCTAssertEqual(error as? MaxConcurrentAgentsError, .notABlock("execution"))
        }
        XCTAssertThrowsError(try MaxConcurrentAgents.setting(3, in: "execution:\n  concurrency: {max_total: 2}\n")) { error in
            XCTAssertEqual(error as? MaxConcurrentAgentsError, .notABlock("concurrency"))
        }
        XCTAssertNil(MaxConcurrentAgents.value(in: "execution:\n  concurrency: {max_total: 2}\n"))
        XCTAssertEqual(
            MaxConcurrentAgentsError.notABlock("concurrency").errorDescription,
            "`concurrency:` in symphony.yml is not an indented block. Change max_total by hand."
        )
    }

    func testFileReadAndWriteChangeOneLine() throws {
        let directory = uniqueTemporaryDirectory("max-concurrent-agents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("symphony.yml")
        try config.write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = SymphonyConfigFile(path: url.path)

        XCTAssertEqual(try file.readMaxConcurrentAgents(), 2)
        try file.writeMaxConcurrentAgents(3)

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(changedLines(config, written), ["    max_total: 3  # two agents"])
        XCTAssertEqual(try file.readMaxConcurrentAgents(), 3)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testFileWriteGoesThroughASymlink() throws {
        let directory = uniqueTemporaryDirectory("max-concurrent-agents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("real.yml")
        let link = directory.appendingPathComponent("symphony.yml")
        try config.write(to: target, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try SymphonyConfigFile(path: link.path).writeMaxConcurrentAgents(4)

        XCTAssertEqual(MaxConcurrentAgents.value(in: try String(contentsOf: target, encoding: .utf8)), 4)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    func testFileWriteLeavesAnUnchangedFileAlone() throws {
        let directory = uniqueTemporaryDirectory("max-concurrent-agents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("symphony.yml")
        try config.write(to: url, atomically: false, encoding: .utf8)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int

        try SymphonyConfigFile(path: url.path).writeMaxConcurrentAgents(2)

        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        XCTAssertEqual(before, after)
    }

    func testFileErrorsWhenMissing() {
        let missing = uniqueTemporaryDirectory("max-concurrent-agents").appendingPathComponent("symphony.yml")
        XCTAssertThrowsError(try SymphonyConfigFile(path: missing.path).readMaxConcurrentAgents())
        XCTAssertThrowsError(try SymphonyConfigFile(path: missing.path).writeMaxConcurrentAgents(2))
    }

    /// Lines of `updated` that differ from `original`, for texts with the same number of lines.
    private func changedLines(_ original: String, _ updated: String) -> [String] {
        let before = original.components(separatedBy: "\n")
        let after = updated.components(separatedBy: "\n")
        XCTAssertEqual(before.count, after.count)
        return zip(before, after).filter { $0 != $1 }.map(\.1)
    }
}
