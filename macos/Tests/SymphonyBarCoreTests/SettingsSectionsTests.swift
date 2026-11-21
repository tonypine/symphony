import XCTest
@testable import SymphonyBarCore

/// The Settings page's sections (TP-1575): the old window's form blocks, grouped into a short list.
final class SettingsSectionsTests: XCTestCase {
    func testEveryBlockOfTheFormIsInExactlyOneSection() {
        let shown = SettingsSection.allCases.flatMap(\.blocks)
        XCTAssertEqual(shown.count, SettingsBlock.allCases.count)
        XCTAssertEqual(Set(shown), Set(SettingsBlock.allCases))
        for block in SettingsBlock.allCases {
            XCTAssertEqual(SettingsSection.allCases.filter { $0.blocks.contains(block) }, [block.section])
        }
    }

    func testTheSectionsAreAShortNamedList() {
        XCTAssertEqual(
            SettingsSection.allCases.map(\.title),
            ["Symphony", "Notifications", "Updates", "Agents", "Tickets", "GitHub and Linear", "Review and QA", "Records", "Environment"]
        )
        XCTAssertLessThan(SettingsSection.allCases.count, SettingsBlock.allCases.count / 2)
        for section in SettingsSection.allCases {
            XCTAssertFalse(section.blocks.isEmpty)
            XCTAssertFalse(section.symbol.isEmpty)
            XCTAssertEqual(section.id, section.rawValue)
        }
        XCTAssertEqual(SettingsSection.first, .symphony)
        XCTAssertEqual(Set(SettingsBlock.allCases.map(\.title)).count, SettingsBlock.allCases.count)
    }

    func testTheBlocksKeepTheFormsOrderInsideTheirSection() {
        XCTAssertEqual(SettingsSection.symphony.blocks, [.symphony, .developmentMode])
        XCTAssertEqual(SettingsSection.agents.blocks, [.agents, .timeouts, .conductor])
        XCTAssertEqual(SettingsSection.tickets.blocks, [.tickets, .boardStates, .dispatch, .dispatchLoops])
        XCTAssertEqual(SettingsSection.connections.blocks, [.gitHubUpdates, .linearWebhooks])
        XCTAssertEqual(SettingsSection.review.blocks, [.codeReview, .riskRules, .phases, .macAppQA])
        XCTAssertEqual(SettingsSection.records.blocks, [.ledger, .reports])
        XCTAssertEqual(SettingsSection.notifications.blocks, [.notifications])
        XCTAssertEqual(SettingsSection.updates.blocks, [.updates])
        XCTAssertEqual(SettingsSection.environment.blocks, [.environment])
    }

    func testAnErrorLineNamesTheSectionThatHoldsItsBlock() {
        XCTAssertEqual(SettingsBlock.timeouts.pointer, "Timeouts, under Agents")
        XCTAssertEqual(SettingsBlock.phases.pointer, "Phases, under Review and QA")
        XCTAssertEqual(SettingsBlock.gitHubUpdates.pointer, "GitHub updates, under GitHub and Linear")
        XCTAssertEqual(SettingsBlock.environment.pointer, "Environment")
        XCTAssertEqual(SettingsBlock.symphony.pointer, "Symphony")
        XCTAssertEqual(SettingsBlock.developmentMode.pointer, "Development mode, under Symphony")
    }

    func testASectionCountsItsBlocksSaveRefused() {
        let failing: Set<SettingsBlock> = [.timeouts, .conductor, .ledger]
        XCTAssertEqual(SettingsSection.agents.failures(failing), 2)
        XCTAssertEqual(SettingsSection.records.failures(failing), 1)
        XCTAssertEqual(SettingsSection.symphony.failures(failing), 0)
        XCTAssertEqual(SettingsSection.agents.failures([]), 0)
    }

    func testEachValidationIssueBelongsToTheBlockOfItsField() {
        let cases: [(SettingsIssue, SettingsBlock)] = [
            (.configPathMissing, .symphony), (.configPathNotAbsolute, .symphony), (.configPathNotFile, .symphony),
            (.stopTimeoutOutOfRange, .symphony), (.restartTimeoutOutOfRange, .symphony),
            (.checkoutPathMissing, .developmentMode), (.checkoutPathNotAbsolute, .developmentMode),
            (.checkoutPathNotDirectory, .developmentMode), (.commandPrefixUnbalancedQuotes, .developmentMode),
            (.embeddedSymphonyMissing, .developmentMode),
            (.linearAPIKeyMissing, .environment), (.environmentNameInvalid("1X"), .environment),
            (.environmentNameDuplicate("X"), .environment), (.environmentNameReserved("LINEAR_API_KEY"), .environment),
        ]
        for (issue, block) in cases {
            XCTAssertEqual(issue.block, block, "\(issue)")
        }
        // An empty symphony.yml path, refused while another section shows, sends the person to Symphony.
        XCTAssertEqual(SettingsIssue.configPathMissing.block.section, .symphony)
    }
}
