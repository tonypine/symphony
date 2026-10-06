import XCTest
@testable import SymphonyBarCore

final class TokenLimitsTests: XCTestCase {
    private let config = """
        # Symphony operator config.
        agent:
          runtime: claude
          concurrency:
            max_total: 2  # two agents
          limits:
            max_turns: 8
            # Stop one runaway ticket.
            tokens_per_issue: 100000000   # 100M
            tokens_per_day: 1000000000  # 1B, resets at UTC midnight

        workspaces:
          root: ~/work

        """

    private let configLimits = TokenLimits(perDay: .tokens(1_000_000_000), perIssue: .tokens(100_000_000))

    // MARK: Reading

    func testReadsBothLimits() throws {
        XCTAssertEqual(try TokenLimits.values(in: config), configLimits)
    }

    func testNullValuesReadAsOff() throws {
        for value in ["null", "~", "", "Null", "NULL", "null  # no cap"] {
            let yaml = "agent:\n  limits:\n    tokens_per_day: \(value)\n    tokens_per_issue: \(value)\n"
            XCTAssertEqual(try TokenLimits.values(in: yaml), TokenLimits(perDay: .off, perIssue: .off), value)
        }
    }

    func testMissingKeysReadAsSymphonysDefaults() throws {
        let defaults = TokenLimits(perDay: .tokens(5_000_000), perIssue: .tokens(500_000))
        XCTAssertEqual(try TokenLimits.values(in: ""), defaults)
        XCTAssertEqual(try TokenLimits.values(in: "agent:\n  runtime: codex\n"), defaults)
        XCTAssertEqual(try TokenLimits.values(in: "agent:\n  limits:\n    max_turns: 8\n"), defaults)
        XCTAssertEqual(TokenLimits(), defaults)
        XCTAssertEqual(
            try TokenLimits.values(in: "agent:\n  limits:\n    tokens_per_day: null\n"),
            TokenLimits(perDay: .off, perIssue: .tokens(500_000))
        )
    }

    func testIgnoresLimitsOutsideAgent() throws {
        let yaml = """
            limits:
              tokens_per_day: 7
            agent:
              limits:
                # tokens_per_day: 9
                tokens_per_day_extra: 4
            """
        XCTAssertEqual(try TokenLimits.values(in: yaml), TokenLimits())
    }

    func testRefusesValuesItCannotRead() {
        XCTAssertThrowsError(try TokenLimits.values(in: "agent:\n  limits:\n    tokens_per_day: lots\n")) { error in
            XCTAssertEqual(error as? TokenLimitsError, .unreadable(key: "tokens_per_day", value: "lots"))
        }
        XCTAssertThrowsError(try TokenLimits.values(in: "agent:\n  limits: {tokens_per_day: 5}\n")) { error in
            XCTAssertEqual(error as? TokenLimitsError, .notABlock("limits"))
        }
        XCTAssertEqual(
            TokenLimitsError.unreadable(key: "tokens_per_day", value: "lots").errorDescription,
            "`tokens_per_day: lots` in symphony.yml is not a whole number or null. Change it by hand."
        )
        XCTAssertEqual(
            TokenLimitsError.notABlock("limits").errorDescription,
            "`limits:` in symphony.yml is not an indented block. Change the token limits by hand."
        )
    }

    // MARK: Writing

    func testWritesANumberOnOneLine() throws {
        let updated = try TokenLimits.updating(
            config,
            from: configLimits,
            to: TokenLimits(perDay: .tokens(2_000_000_000), perIssue: configLimits.perIssue)
        )

        XCTAssertEqual(changedLines(config, updated), ["    tokens_per_day: 2000000000  # 1B, resets at UTC midnight"])
        XCTAssertEqual(try TokenLimits.values(in: updated).perDay, .tokens(2_000_000_000))
    }

    func testWritesNullOnOneLine() throws {
        let updated = try TokenLimits.updating(
            config,
            from: configLimits,
            to: TokenLimits(perDay: .off, perIssue: .off)
        )

        XCTAssertEqual(changedLines(config, updated), [
            "    tokens_per_issue: null   # 100M",
            "    tokens_per_day: null  # 1B, resets at UTC midnight",
        ])
        XCTAssertEqual(try TokenLimits.values(in: updated), TokenLimits(perDay: .off, perIssue: .off))
    }

    func testTurningACapOffAndOnAgainGivesTheSameBytes() throws {
        let off = try TokenLimits.updating(config, from: configLimits, to: TokenLimits(perDay: .off, perIssue: .off))
        XCTAssertEqual(try TokenLimits.updating(off, from: TokenLimits(perDay: .off, perIssue: .off), to: configLimits), config)
    }

    func testUnchangedLimitsLeaveTheTextAlone() throws {
        XCTAssertEqual(try TokenLimits.updating(config, from: configLimits, to: configLimits), config)
        // An empty value reads as off; it's left as it is rather than rewritten to null.
        let empty = "agent:\n  limits:\n    tokens_per_day:\n"
        let off = TokenLimits(perDay: .off)
        XCTAssertEqual(try TokenLimits.updating(empty, from: off, to: off), empty)
    }

    func testFillsAnEmptyValue() throws {
        XCTAssertEqual(
            try TokenLimits.updating(
                "agent:\n  limits:\n    tokens_per_day:   # none\n",
                from: TokenLimits(perDay: .off),
                to: TokenLimits(perDay: .tokens(3))
            ),
            "agent:\n  limits:\n    tokens_per_day: 3 # none\n"
        )
    }

    func testInsertsMissingKeysAndSections() throws {
        let off = TokenLimits(perDay: .off, perIssue: .off)

        XCTAssertEqual(
            try TokenLimits.updating("agent:\n  limits:\n    max_turns: 8\n", from: TokenLimits(), to: off),
            "agent:\n  limits:\n    tokens_per_issue: null\n    tokens_per_day: null\n    max_turns: 8\n"
        )
        XCTAssertEqual(
            try TokenLimits.updating("agent:\n  runtime: codex\n", from: TokenLimits(), to: TokenLimits(perDay: .off)),
            "agent:\n  limits:\n    tokens_per_day: null\n  runtime: codex\n"
        )
        XCTAssertEqual(
            try TokenLimits.updating("issues:\n  provider: linear\n", from: TokenLimits(), to: TokenLimits(perDay: .tokens(9))),
            "issues:\n  provider: linear\nagent:\n  limits:\n    tokens_per_day: 9\n"
        )
    }

    func testRefusesToWriteIntoAnInlineSection() {
        XCTAssertThrowsError(
            try TokenLimits.updating("agent:\n  limits: {max_turns: 8}\n", from: TokenLimits(), to: TokenLimits(perDay: .off))
        ) { error in
            XCTAssertEqual(error as? TokenLimitsError, .notABlock("limits"))
        }
    }

    // MARK: The file

    func testFileWriteRunsTheCheckOnTheNewTextFirst() async throws {
        let (directory, url) = try writeConfig()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = SymphonyConfigFile(path: url.path)
        let new = TokenLimits(perDay: .tokens(2_000_000_000), perIssue: configLimits.perIssue)
        var checked: String?

        let result = try await file.writeTokenLimits(new, from: try file.readTokenLimits()) { path in
            checked = try? String(contentsOfFile: path, encoding: .utf8)
            return .passed
        }

        XCTAssertEqual(result, .passed)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(checked, written)
        XCTAssertEqual(changedLines(config, written), ["    tokens_per_day: 2000000000  # 1B, resets at UTC midnight"])
        XCTAssertEqual(try file.readTokenLimits(), new)
        XCTAssertEqual(try siblings(of: url), ["symphony.yml"])
    }

    func testFileWriteLeavesTheFileWhenTheCheckFails() async throws {
        let (directory, url) = try writeConfig()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await SymphonyConfigFile(path: url.path).writeTokenLimits(
            TokenLimits(perDay: .tokens(-5), perIssue: configLimits.perIssue),
            from: configLimits
        ) { _ in .failed("agent.max_tokens_per_day must be greater than 0") }

        XCTAssertEqual(result, .failed("agent.max_tokens_per_day must be greater than 0"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), config)
        XCTAssertEqual(try siblings(of: url), ["symphony.yml"])
    }

    func testFileCheckNeverChangesTheFile() async throws {
        let (directory, url) = try writeConfig()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = SymphonyConfigFile(path: url.path)
        var checked: String?

        let passed = try await file.checkTokenLimits(TokenLimits(perDay: .off, perIssue: configLimits.perIssue), from: configLimits) { path in
            checked = try? String(contentsOfFile: path, encoding: .utf8)
            return .passed
        }
        let failed = try await file.checkTokenLimits(TokenLimits(perDay: .tokens(-5)), from: configLimits) { path in
            .failed("Config error in \(path): no")
        }

        XCTAssertEqual(passed, .passed)
        XCTAssertEqual(failed, .failed("Config error in \(url.path): no"))
        XCTAssertEqual(try TokenLimits.values(in: XCTUnwrap(checked)), TokenLimits(perDay: .off, perIssue: configLimits.perIssue))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), config)
        XCTAssertEqual(try siblings(of: url), ["symphony.yml"])
    }

    func testFileCheckSkipsUnchangedLimits() async throws {
        let (directory, url) = try writeConfig()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await SymphonyConfigFile(path: url.path).checkTokenLimits(configLimits, from: configLimits) { _ in
            XCTFail("nothing to check")
            return .failed("checked")
        }

        XCTAssertEqual(result, .passed)
    }

    func testFileErrorsWhenMissing() async {
        let missing = uniqueTemporaryDirectory("token-limits").appendingPathComponent("symphony.yml")
        let file = SymphonyConfigFile(path: missing.path)
        XCTAssertThrowsError(try file.readTokenLimits())
        do {
            _ = try await file.checkTokenLimits(TokenLimits(perDay: .off), from: TokenLimits()) { _ in .passed }
            XCTFail("expected an error")
        } catch {}
    }

    // MARK: The Settings field

    func testFieldFollowsTheLimit() {
        let on = TokenLimitField(.tokens(1_000_000_000), default: 5_000_000)
        XCTAssertTrue(on.isOn)
        XCTAssertEqual(on.text, "1000000000")
        XCTAssertEqual(on.limit, .tokens(1_000_000_000))

        var off = TokenLimitField(.off, default: 5_000_000)
        XCTAssertFalse(off.isOn)
        XCTAssertEqual(off.limit, .off)
        // Turning it on offers Symphony's default.
        off.isOn = true
        XCTAssertEqual(off.limit, .tokens(5_000_000))
    }

    func testFieldReadsTypedNumbers() {
        var field = TokenLimitField(.off, default: 1)
        field.isOn = true
        for (text, tokens) in [("2000000000", 2_000_000_000), (" 2,000,000,000 ", 2_000_000_000), ("1_000", 1_000), ("-5", -5)] {
            field.text = text
            XCTAssertEqual(field.limit, .tokens(tokens), text)
        }
        for text in ["", "lots", "1.5", "1e9"] {
            field.text = text
            XCTAssertNil(field.limit, text)
            XCTAssertEqual(field.hint, "Enter a whole number of tokens, such as 1000000000", text)
        }
        field.isOn = false
        XCTAssertEqual(field.limit, .off)
    }

    func testFieldHintShowsTheNumberReadably() {
        XCTAssertEqual(TokenLimitField(.tokens(1_000_000_000), default: 1).hint, "1,000,000,000 = 1B")
        XCTAssertEqual(TokenLimitField(.tokens(500_000), default: 1).hint, "500,000 = 500K")
    }

    func testCompactCounts() {
        XCTAssertEqual(TokenLimits.compact(1_000_000_000), "1B")
        XCTAssertEqual(TokenLimits.compact(2_500_000_000), "2.5B")
        XCTAssertEqual(TokenLimits.compact(999_960_000), "1B")
        XCTAssertEqual(TokenLimits.compact(156_465_114), "156.5M")
        XCTAssertEqual(TokenLimits.compact(5_000_000), "5M")
        XCTAssertEqual(TokenLimits.compact(500_000), "500K")
        XCTAssertEqual(TokenLimits.compact(1_250), "1.3K")
        XCTAssertEqual(TokenLimits.compact(999), "999")
        XCTAssertEqual(TokenLimits.compact(0), "0")
        XCTAssertEqual(TokenLimits.compact(-5), "-5")
        XCTAssertEqual(TokenLimits.grouped(1_000_000_000), "1,000,000,000")
    }

    // MARK: Today's usage

    /// 10:00 UTC on 2026-10-04, when it's 07:00 in UTC-3.
    private let now = Date(timeIntervalSince1970: 1_791_108_000)
    private let utcMinus3 = TimeZone(secondsFromGMT: -3 * 3600)!

    func testUsageWithADailyCap() {
        let budget = StateSnapshot.Budget(dailyLimit: 1_000_000_000, dailyUsed: 156_465_114, dailyRemaining: 843_534_886)
        XCTAssertEqual(
            TokenUsage.lines(budget, now: now, timeZone: utcMinus3),
            ["Used today: 156.5M of 1B tokens, 843.5M left. The count resets at 21:00."]
        )
    }

    func testUsageWithoutADailyCap() {
        XCTAssertEqual(
            TokenUsage.lines(.init(dailyUsed: 42), now: now, timeZone: utcMinus3),
            ["Used today: 42 tokens, no daily cap. The count resets at 21:00."]
        )
    }

    func testUsagePausedOnTheDailyCap() {
        let budget = StateSnapshot.Budget(dailyLimit: 1_000_000_000, dailyUsed: 1_000_400_000, dailyRemaining: 0, dailyPaused: true)
        XCTAssertEqual(
            TokenUsage.lines(budget, now: now, timeZone: utcMinus3),
            [
                "Used today: 1B of 1B tokens, 0 left. The count resets at 21:00.",
                "New runs are paused: today's cap is used up. They resume when the count resets at 21:00, "
                    + "or raise or turn off the cap.",
            ]
        )
    }

    func testUsageWorksOutWhatsLeftWhenSymphonyDoesNotSay() {
        let budget = StateSnapshot.Budget(dailyLimit: 1_000, dailyUsed: 1_500)
        XCTAssertEqual(
            TokenUsage.lines(budget, now: now, timeZone: utcMinus3),
            ["Used today: 1.5K of 1K tokens, 0 left. The count resets at 21:00."]
        )
    }

    func testUsageWhileSymphonyIsNotAnswering() {
        XCTAssertEqual(TokenUsage.lines(nil, now: now, timeZone: utcMinus3), ["Today's usage shows while Symphony is running."])
    }

    func testResetIsTheNextUTCMidnight() {
        XCTAssertEqual(TokenUsage.nextReset(after: now), Date(timeIntervalSince1970: 1_791_158_400))
        XCTAssertEqual(TokenUsage.nextReset(after: Date(timeIntervalSince1970: 1_791_158_400)), Date(timeIntervalSince1970: 1_791_244_800))
        XCTAssertEqual(TokenUsage.resetTime(after: now, timeZone: TimeZone(identifier: "UTC")!), "00:00 tomorrow")
        XCTAssertEqual(TokenUsage.resetTime(after: now, timeZone: TimeZone(secondsFromGMT: 2 * 3600)!), "02:00 tomorrow")
        XCTAssertEqual(TokenUsage.resetTime(after: now, timeZone: utcMinus3), "21:00")
    }

    // MARK: Helpers

    private func writeConfig() throws -> (URL, URL) {
        let directory = uniqueTemporaryDirectory("token-limits")
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
