import XCTest
@testable import SymphonyBarCore

final class ReportSettingsTests: XCTestCase {
    private let config = """
        # Symphony operator config.
        workspaces:
          root: ~/work

        reports:
          model: claude-sonnet-5-5  # a stronger writer

        """

    // MARK: Reading

    func testReadsTheModel() throws {
        XCTAssertEqual(try ReportSettings.values(in: config), ReportSettings(model: "claude-sonnet-5-5"))
        XCTAssertEqual(try ReportSettings.values(in: "reports:\n  model: \"claude-opus-5-5\"\n"), ReportSettings(model: "claude-opus-5-5"))
        XCTAssertEqual(try ReportSettings.values(in: "reports:\n  model: 'claude-opus-5-5'\n"), ReportSettings(model: "claude-opus-5-5"))
    }

    func testMissingNullAndBlankModelsReadAsTheCheapestCapableModel() throws {
        XCTAssertEqual(ReportSettings().model, "claude-haiku-5-5")
        XCTAssertEqual(try ReportSettings.values(in: ""), ReportSettings())
        XCTAssertEqual(try ReportSettings.values(in: "reports:\n"), ReportSettings())
        XCTAssertEqual(try ReportSettings.values(in: "reports:\n  model: ~\n"), ReportSettings())
        XCTAssertEqual(try ReportSettings.values(in: "reports:\n  model: \"\"\n"), ReportSettings())
    }

    func testRefusesAnInlineSection() {
        XCTAssertThrowsError(try ReportSettings.values(in: "reports: {model: x}\n")) { error in
            XCTAssertEqual(error as? ReportSettingsError, .notABlock("reports"))
        }
        XCTAssertThrowsError(try ReportSettings.updating("reports: {}\n", from: ReportSettings(), to: ReportSettings(model: "x"))) { error in
            XCTAssertEqual(error as? ReportSettingsError, .notABlock("reports"))
        }
        XCTAssertEqual(
            ReportSettingsError.notABlock("reports").errorDescription,
            "`reports:` in symphony.yml is not an indented block. Change the report settings by hand."
        )
    }

    // MARK: Writing

    func testRewritesOnlyTheModelLineKeepingItsComment() throws {
        let loaded = try ReportSettings.values(in: config)
        let after = try ReportSettings.updating(config, from: loaded, to: ReportSettings(model: "claude-opus-5-5"))
        let changed = zip(config.components(separatedBy: "\n"), after.components(separatedBy: "\n")).filter { $0 != $1 }.map(\.1)
        XCTAssertEqual(changed, ["  model: claude-opus-5-5  # a stronger writer"])
        XCTAssertEqual(try ReportSettings.updating(config, from: loaded, to: loaded), config)
    }

    func testInsertsTheSectionWhenMissingAndWritesTheDefaultForABlankModel() throws {
        XCTAssertEqual(
            try ReportSettings.updating("issues:\n  provider: linear\n", from: ReportSettings(), to: ReportSettings(model: "claude-sonnet-5-5")),
            "issues:\n  provider: linear\nreports:\n  model: claude-sonnet-5-5\n"
        )
        XCTAssertEqual(
            try ReportSettings.updating("reports:\n  model: x\n", from: ReportSettings(model: "x"), to: ReportSettings(model: "  ")),
            "reports:\n  model: claude-haiku-5-5\n"
        )
    }
}
