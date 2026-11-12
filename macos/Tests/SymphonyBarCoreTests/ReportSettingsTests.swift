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

    // MARK: Cadence and triggers

    func testReadsTheCadenceAndTheTriggersWithTheirDefaults() throws {
        let defaults = try ReportSettings.values(in: "")
        XCTAssertEqual(defaults.cadence, .sixHours)
        XCTAssertEqual(ReportTrigger.allCases.filter { defaults.isOn($0) }, [.ticketShipped, .pausedByRule])

        let yaml = """
            reports:
              cadence: hourly
              triggers:
                epic_closed: true
                ticket_shipped: false
                ci_fix_loop: ~

            """
        let read = try ReportSettings.values(in: yaml)
        XCTAssertEqual(read.cadence, .hourly)
        XCTAssertEqual(ReportTrigger.allCases.filter { read.isOn($0) }, [.epicClosed, .pausedByRule])
        XCTAssertEqual(try ReportSettings.values(in: "reports:\n  cadence: \"daily\"\n").cadence, .daily)
        XCTAssertEqual(try ReportSettings.values(in: "reports:\n  cadence: none\n").cadence, ReportCadence.none)
    }

    func testRefusesAnUnknownCadenceAndATriggerThatIsNotOnOrOff() {
        XCTAssertThrowsError(try ReportSettings.values(in: "reports:\n  cadence: weekly\n")) { error in
            XCTAssertEqual(error as? ReportSettingsError, .unknownCadence("weekly"))
        }
        XCTAssertThrowsError(try ReportSettings.values(in: "reports:\n  triggers:\n    epic_closed: maybe\n")) { error in
            XCTAssertEqual(error as? ReportSettingsError, .notOnOrOff(key: "reports.triggers.epic_closed", value: "maybe"))
        }
        XCTAssertEqual(
            ReportSettingsError.unknownCadence("weekly").errorDescription,
            "`reports.cadence: weekly` in symphony.yml is not none, hourly, six_hours or daily. Change it by hand."
        )
        XCTAssertEqual(
            ReportSettingsError.notOnOrOff(key: "reports.triggers.epic_closed", value: "maybe").errorDescription,
            "`reports.triggers.epic_closed: maybe` in symphony.yml is not true or false. Change it by hand."
        )
    }

    func testWritesTheHourlyCadenceAndTheEpicClosedTrigger() throws {
        let loaded = try ReportSettings.values(in: config)
        var new = loaded
        new.cadence = .hourly
        new.triggers[.epicClosed] = true
        let after = try ReportSettings.updating(config, from: loaded, to: new)
        XCTAssertTrue(after.contains("reports:\n  cadence: hourly\n  triggers:\n    epic_closed: true\n  model: claude-sonnet-5-5  # a stronger writer\n"), after)
        XCTAssertEqual(try ReportSettings.values(in: after), new)
    }

    func testCadenceAndTriggerTitles() {
        XCTAssertEqual(ReportCadence.allCases.map(\.title), ["Never", "Every hour", "Every six hours", "Every day"])
        XCTAssertEqual(ReportCadence.sixHours.id, "six_hours")
        XCTAssertEqual(ReportTrigger.epicClosed.id, "epic_closed")
        XCTAssertEqual(ReportTrigger.allCases.map(\.title), [
            "A ticket shipped", "An epic closed", "A ticket's CI fix loop passed three rounds", "Self-heal filed a fix ticket",
            "A release installed", "The factory paused by a rule",
        ])
    }
}
