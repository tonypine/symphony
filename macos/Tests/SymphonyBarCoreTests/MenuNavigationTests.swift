import CoreGraphics
import XCTest
@testable import SymphonyBarCore

/// TP-1508: what the app's open menu and pop-up list do with the keys, and where they open.
final class MenuNavigationTests: XCTestCase {
    private typealias Line = MenuNavigation.Line

    /// Todo, In Progress, Rework, a separator, Backlog (off), Canceled: the catalog's Menu button story.
    private let lines: [Line] = [
        Line(title: "Todo"), Line(title: "In Progress"), Line(title: "Rework"), .separator,
        Line(title: "Backlog", enabled: false), Line(title: "Canceled"),
    ]

    // MARK: - Keys

    func testDownAndUpSkipSeparatorsAndItemsThatAreOffAndWrapRound() {
        XCTAssertEqual(MenuNavigation.move(from: nil, step: 1, in: lines), 0)
        XCTAssertEqual(MenuNavigation.move(from: nil, step: -1, in: lines), 5)
        XCTAssertEqual(MenuNavigation.move(from: 2, step: 1, in: lines), 5, "past the separator and Backlog")
        XCTAssertEqual(MenuNavigation.move(from: 5, step: 1, in: lines), 0, "round to the top")
        XCTAssertEqual(MenuNavigation.move(from: 0, step: -1, in: lines), 5, "round to the foot")
        XCTAssertEqual(MenuNavigation.move(from: 5, step: -1, in: lines), 2)
        XCTAssertEqual(MenuNavigation.move(from: 3, step: 1, in: lines), 0, "from a line the keys can't land on, the first")
        XCTAssertNil(MenuNavigation.move(from: nil, step: 1, in: [.separator, Line(title: "Off", enabled: false)]))
    }

    func testHomeAndEndGoToTheEnds() {
        XCTAssertEqual(MenuNavigation.end(false, in: lines), 0)
        XCTAssertEqual(MenuNavigation.end(true, in: lines), 5)
        XCTAssertNil(MenuNavigation.end(true, in: []))
    }

    func testTypingJumpsToTheFirstItemItStartsIgnoringCaseAndAccents() {
        var typeAhead = MenuNavigation.TypeAhead()
        XCTAssertEqual(typeAhead.type("r", at: 0, current: nil, in: lines), 2)
        var accents = MenuNavigation.TypeAhead()
        XCTAssertEqual(accents.type("C", at: 0, current: 0, in: [Line(title: "Todo"), Line(title: "Café")]), 1)
        XCTAssertEqual(accents.type("a", at: 0.2, current: 1, in: [Line(title: "Todo"), Line(title: "Café")]), 1)
        XCTAssertEqual(accents.query, "Ca")
    }

    func testLettersTypedTogetherSpellOneSearch() {
        var typeAhead = MenuNavigation.TypeAhead()
        let lines = [Line(title: "symphony"), Line(title: "shop"), Line(title: "site")]
        XCTAssertEqual(typeAhead.type("s", at: 0, current: nil, in: lines), 0)
        XCTAssertEqual(typeAhead.type("h", at: 0.3, current: 0, in: lines), 1)
        XCTAssertEqual(typeAhead.query, "sh")
        // A pause starts a new search.
        XCTAssertEqual(typeAhead.type("s", at: 2, current: 1, in: lines), 0)
        XCTAssertEqual(typeAhead.query, "s")
    }

    func testTheSameLetterAgainMovesOnAndTheSearchSkipsItemsThatAreOff() {
        var typeAhead = MenuNavigation.TypeAhead()
        let lines = [Line(title: "symphony"), Line(title: "shop", enabled: false), Line(title: "site")]
        XCTAssertEqual(typeAhead.type("s", at: 0, current: nil, in: lines), 0)
        XCTAssertEqual(typeAhead.type("s", at: 0.2, current: 0, in: lines), 2)
        XCTAssertEqual(typeAhead.type("s", at: 0.4, current: 2, in: lines), 0, "round again")
        XCTAssertNil(typeAhead.type("x", at: 3, current: 0, in: lines))
        XCTAssertNil(typeAhead.type("", at: 4, current: 0, in: lines))
        XCTAssertNil(typeAhead.type("a", at: 5, current: nil, in: []))
    }

    // MARK: - Layout

    func testTheMenuIsItsItemsSeparatorsAndPadding() {
        // 5 items of 28 pt, one separator of 11 pt, 5 pt above and below.
        XCTAssertEqual(MenuNavigation.height(of: lines), 5 * 28 + 11 + 10)
        XCTAssertEqual(MenuNavigation.tops(of: lines), [5, 33, 61, 89, 100, 128])
        XCTAssertEqual(DesignTokens.Menu.separatorSpan, 11)
    }

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 220, height: 160)

    func testItOpensUnderItsControlOnItsLeadingEdge() {
        let anchor = CGRect(x: 100, y: 600, width: 90, height: 30)
        let frame = MenuNavigation.frame(size: size, anchor: anchor, visible: screen)
        XCTAssertEqual(frame, CGRect(x: 100, y: 600 - 6 - 160, width: 220, height: 160))
    }

    func testATrailingMenuLinesUpWithTheControlsTrailingEdge() {
        let anchor = CGRect(x: 700, y: 600, width: 90, height: 30)
        let frame = MenuNavigation.frame(size: size, anchor: anchor, visible: screen, alignment: .trailing)
        XCTAssertEqual(frame.maxX, 790)
    }

    func testNearTheBottomItOpensAbove() {
        let anchor = CGRect(x: 100, y: 60, width: 90, height: 30)
        let frame = MenuNavigation.frame(size: size, anchor: anchor, visible: screen)
        XCTAssertEqual(frame.minY, 96, "6 pt over the control's top")
    }

    func testNearAnEdgeItMovesInToStayOnTheScreen() {
        let right = MenuNavigation.frame(size: size, anchor: CGRect(x: 1400, y: 600, width: 30, height: 30), visible: screen)
        XCTAssertEqual(right.maxX, 1440 - 8)
        let left = MenuNavigation.frame(size: size, anchor: CGRect(x: 0, y: 600, width: 30, height: 30), visible: screen, alignment: .trailing)
        XCTAssertEqual(left.minX, 8)
        // No room under or over a tall menu: it stays on the screen, its top kept.
        let tall = MenuNavigation.frame(size: CGSize(width: 220, height: 880), anchor: CGRect(x: 100, y: 400, width: 90, height: 30), visible: screen)
        XCTAssertEqual(tall.minY, 8)
    }

    func testAMenuTallerThanTheScreenIsCutToItSoItsFirstItemsStayOnIt() {
        XCTAssertEqual(MenuNavigation.maxHeight(visible: screen), 900 - 16)
        XCTAssertEqual(MenuNavigation.maxHeight(visible: CGRect(x: 0, y: 0, width: 400, height: 20)), 38, "never under one item")
        let taller = CGSize(width: 220, height: 2000)
        let anchors = [400.0, 860, 10].map { CGRect(x: 100, y: $0, width: 90, height: 30) }
        for anchor in anchors {
            let frame = MenuNavigation.frame(size: taller, anchor: anchor, visible: screen)
            XCTAssertEqual(frame.height, 884)
            XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(frame), "\(frame) inside the screen")
        }
        let submenu = MenuNavigation.submenuFrame(size: taller, item: CGRect(x: 100, y: 500, width: 220, height: 28), visible: screen)
        XCTAssertEqual(submenu.height, 884)
        XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(submenu))
    }

    func testASubmenuOpensBesideItsItemOrOnTheOtherSideAtTheEdge() {
        let item = CGRect(x: 100, y: 500, width: 220, height: 28)
        let beside = MenuNavigation.submenuFrame(size: size, item: item, visible: screen)
        XCTAssertEqual(beside.minX, 325)
        XCTAssertEqual(beside.maxY, 533, "its first item level with the item")
        let atEdge = MenuNavigation.submenuFrame(size: size, item: CGRect(x: 1200, y: 500, width: 220, height: 28), visible: screen)
        XCTAssertEqual(atEdge.maxX, 1195)
        let low = MenuNavigation.submenuFrame(size: size, item: CGRect(x: 100, y: 10, width: 220, height: 28), visible: screen)
        XCTAssertEqual(low.minY, 8)
    }

    // MARK: - Tokens

    func testTheSegmentedThumbSlidesByEqualShares() {
        XCTAssertEqual(DesignTokens.Segmented.thumbOffset(index: 0, count: 3, width: 300), 0)
        XCTAssertEqual(DesignTokens.Segmented.thumbOffset(index: 2, count: 3, width: 300), 200)
        XCTAssertEqual(DesignTokens.Segmented.thumbOffset(index: 7, count: 3, width: 300), 200, "kept on the last")
        XCTAssertEqual(DesignTokens.Segmented.thumbOffset(index: 1, count: 0, width: 300), 0)
        XCTAssertEqual(DesignTokens.Segmented.fewest, 2)
        XCTAssertEqual(DesignTokens.Segmented.most, 5)
    }

    func testTheMenuIsTheCatalogs() {
        let menu = DesignTokens.Menu.self
        XCTAssertEqual(menu.radius, 12)
        XCTAssertEqual(menu.itemHeight, 28)
        XCTAssertEqual(menu.itemRadius, 7)
        XCTAssertEqual(menu.minWidth, 220)
        XCTAssertEqual(menu.gap, 6)
        XCTAssertEqual(menu.elevation, .level3)
        XCTAssertEqual(menu.glass, .thick)
        XCTAssertEqual(DesignTokens.Motion.Curve.slide.timing(reduceMotion: false), .spring(duration: 0.5, bounce: 0.1))
    }

    func testThePeriodSegmentsAreShort() {
        XCTAssertEqual(InsightsPreset.allCases.map(\.segment), ["Today", "7 days", "30 days", "90 days", "1 year"])
    }
}
