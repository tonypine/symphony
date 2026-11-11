import SymphonyBarCore
import XCTest
@testable import SymphonyBarUI

/// The Lifecycle section's stages keep every name whole: side by side while the names fit on one line, stacked as rows
/// in a narrower main column (a desktop's just past the breakpoint, beside the rail and the decisions).
final class StageStripTests: XCTestCase {
    /// The waiting ticket's stages, with the longest name the fixture has.
    private let titles = ["Coding", "Code Review ×3", "QA", "Merging", "Done"]

    /// The room the stages get inside the Lifecycle card, in a main column `main` wide.
    private func strip(main: Double, widest: CGFloat) -> CGFloat {
        min(CGFloat(main), widest) - 2 * DesignTokens.Space.s4
    }

    func testTheStagesSitSideBySideOnALaptopAndAWideDesktop() {
        let needed = LifecycleSection.stripWidth(titles: titles)
        let laptop = TicketPageLayout.arrangement(page: TicketPageLayout.laptopPageWidth, decisions: true)
        let desktop = TicketPageLayout.arrangement(page: TicketPageLayout.desktopPageWidth, decisions: true)

        XCTAssertLessThanOrEqual(needed, strip(main: laptop.mainWidth, widest: LifecycleSection.laptopWidth))
        XCTAssertLessThanOrEqual(needed, strip(main: desktop.mainWidth, widest: LifecycleSection.desktopWidth))
    }

    func testJustPastTheBreakpointBesideTheDecisionsTheStagesStack() {
        let narrow = TicketPageLayout.arrangement(page: 1610, decisions: true)

        XCTAssertGreaterThan(LifecycleSection.stripWidth(titles: titles), strip(main: narrow.mainWidth, widest: LifecycleSection.desktopWidth))
    }

    func testTheWidestNameSetsEveryCell() {
        let short = LifecycleSection.stripWidth(titles: ["QA", "QA"])
        let long = LifecycleSection.stripWidth(titles: ["QA", "Code Review ×3"])

        XCTAssertGreaterThan(long, short)
        XCTAssertEqual(LifecycleSection.stripWidth(titles: ["Code Review ×3", "QA"]), long)
        XCTAssertEqual(LifecycleSection.stripWidth(titles: []), 0)
    }
}
