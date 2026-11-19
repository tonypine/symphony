import XCTest
@testable import SymphonyBarCore

/// "Stop new runs at" on Factory › Providers (TP-1535) writes `execution.providers.<provider>.reserve`, one line, and
/// leaves the rest of symphony.yml as it is.
final class ProviderReserveTests: XCTestCase {
    private let config = """
        # Symphony operator config.
        execution:
          # How runs are executed.
          providers:
            anthropic:
              reserve: 0.9  # leave room for my own sessions
          usage_limit:
            auto_pause: true

        """

    // MARK: Reading

    func testReadsTheReserveAsAWholePercent() throws {
        XCTAssertEqual(try ProviderReserve.value(of: "anthropic", in: config), 90)
        XCTAssertNil(try ProviderReserve.value(of: "anthropic", in: ""))
        XCTAssertNil(try ProviderReserve.value(of: "anthropic", in: "execution:\n  providers:\n    anthropic:\n      reserve: null\n"))
        XCTAssertEqual(try ProviderReserve.value(of: "anthropic", in: "execution:\n  providers:\n    anthropic:\n      reserve: 1\n"), 100)
    }

    func testAValueThatIsNoShareIsRefusedNamingTheKey() {
        XCTAssertThrowsError(try ProviderReserve.value(of: "anthropic", in: "execution:\n  providers:\n    anthropic:\n      reserve: high\n")) {
            XCTAssertEqual($0 as? ProviderReserveError, .unreadable(key: "execution.providers.anthropic.reserve", value: "high"))
        }
        XCTAssertThrowsError(try ProviderReserve.value(of: "anthropic", in: "execution:\n  providers:\n    anthropic:\n      reserve: 1.5\n"))
        XCTAssertThrowsError(try ProviderReserve.value(of: "anthropic", in: "execution:\n  providers: {anthropic: {reserve: 0.9}}\n")) {
            guard case .notABlock = $0 as? ProviderReserveError else { return XCTFail("\($0)") }
        }
    }

    // MARK: Writing

    func testSetsTheReserveOnItsOwnLineKeepingItsComment() throws {
        let lowered = try ProviderReserve.setting(80, of: "anthropic", in: config)
        XCTAssertEqual(lowered, config.replacingOccurrences(of: "reserve: 0.9 ", with: "reserve: 0.8 "))
        let finer = try ProviderReserve.setting(85, of: "anthropic", in: config)
        XCTAssertEqual(try ProviderReserve.value(of: "anthropic", in: finer), 85)
        XCTAssertTrue(finer.contains("reserve: 0.85") && finer.contains("# leave room for my own sessions"))
        let none = try ProviderReserve.setting(nil, of: "anthropic", in: config)
        XCTAssertNil(try ProviderReserve.value(of: "anthropic", in: none))
        XCTAssertTrue(none.contains("reserve: null"))
    }

    func testInsertsTheProvidersSectionWhenMissing() throws {
        let yaml = "# top\nexecution:\n  usage_limit:\n    auto_pause: true\n"
        let set = try ProviderReserve.setting(90, of: "anthropic", in: yaml)
        XCTAssertEqual(try ProviderReserve.value(of: "anthropic", in: set), 90)
        XCTAssertTrue(set.hasPrefix("# top\nexecution:\n"))
        XCTAssertTrue(set.contains("    auto_pause: true"))
    }

    func testAProviderWhoseUsageSymphonyCantReadTakesNoReserve() {
        XCTAssertTrue(ProviderReserve.takesReserve("anthropic"))
        XCTAssertFalse(ProviderReserve.takesReserve("openai"))
        XCTAssertThrowsError(try ProviderReserve.setting(80, of: "openai", in: config)) {
            XCTAssertEqual($0 as? ProviderReserveError, .notReadable("openai"))
            XCTAssertEqual($0.localizedDescription, "Symphony can't read OpenAI's usage, so it takes no reserve.")
        }
    }

    func testSharesAreWrittenAsYAMLReadsThem() {
        XCTAssertEqual(ProviderReserve.share(90), "0.9")
        XCTAssertEqual(ProviderReserve.share(85), "0.85")
        XCTAssertEqual(ProviderReserve.share(5), "0.05")
        XCTAssertEqual(ProviderReserve.share(100), "1")
        XCTAssertEqual(ProviderReserve.share(0), "0.01")
        XCTAssertEqual(ProviderReserve.percent(0.845), 85)
    }

    func testErrorsSayWhatToDo() {
        XCTAssertEqual(
            ProviderReserveError.notABlock("providers").localizedDescription,
            "`providers:` in symphony.yml is not an indented block. Change the reserve by hand."
        )
        XCTAssertEqual(
            ProviderReserveError.unreadable(key: "execution.providers.anthropic.reserve", value: "high").localizedDescription,
            "`execution.providers.anthropic.reserve: high` in symphony.yml is not a share from 0 to 1. Change it by hand."
        )
    }

    // MARK: The file

    /// The Director lowers "Stop new runs at" to 80 %: symphony.yml holds it under Anthropic, comments untouched.
    func testFileWriteRunsTheCheckOnTheNewTextFirst() async throws {
        let url = try writeConfig()
        let file = SymphonyConfigFile(path: url.path)
        var checked: String?

        let result = try await file.writeProviderReserve(80, of: "anthropic") { path in
            checked = try? String(contentsOfFile: path, encoding: .utf8)
            return .passed
        }

        XCTAssertEqual(result, .passed)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(checked, written)
        XCTAssertEqual(written, config.replacingOccurrences(of: "reserve: 0.9 ", with: "reserve: 0.8 "))
        XCTAssertEqual(try file.readProviderReserve(of: "anthropic"), 80)
    }

    func testFileWriteLeavesTheFileWhenTheCheckFails() async throws {
        let url = try writeConfig()

        let result = try await SymphonyConfigFile(path: url.path).writeProviderReserve(80, of: "anthropic") { _ in
            .failed("`execution.providers.anthropic.reserve` must be a share above 0 and at most 1")
        }

        XCTAssertEqual(result, .failed("`execution.providers.anthropic.reserve` must be a share above 0 and at most 1"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), config)
    }

    // MARK: Helpers

    private func writeConfig() throws -> URL {
        let directory = uniqueTemporaryDirectory("provider-reserve")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("symphony.yml")
        try config.write(to: url, atomically: false, encoding: .utf8)
        return url
    }
}
