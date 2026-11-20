import XCTest
@testable import SymphonyBarCore

final class ThumbnailRowPlanTests: XCTestCase {
    private func plan(_ count: Int, width: CGFloat) -> ThumbnailRowPlan {
        ThumbnailRowPlan(count: count, width: width, thumbnailWidth: 120, spacing: 8)
    }

    func testAllThumbnailsInOneRowWhenTheWidthHoldsThem() {
        let wide = plan(4, width: 4 * 120 + 3 * 8)
        XCTAssertEqual(wide.columns, 4)
        XCTAssertEqual(wide.shown, 4)
        XCTAssertEqual(wide.hidden, 0)
        XCTAssertFalse(wide.hasMoreTile)
    }

    func testOneRowLessAWhileAndTheyWrapToASecond() {
        let narrow = plan(5, width: 3 * 120 + 2 * 8 + 5)
        XCTAssertEqual(narrow.columns, 3)
        XCTAssertEqual(narrow.shown, 5)
        XCTAssertEqual(narrow.hidden, 0)
    }

    func testPastTwoRowsTheLastCellIsTheMoreTile() {
        let narrow = plan(13, width: 3 * 120 + 2 * 8)
        XCTAssertEqual(narrow.columns, 3)
        XCTAssertEqual(narrow.shown, 5)
        XCTAssertEqual(narrow.hidden, 8)
        XCTAssertTrue(narrow.hasMoreTile)
        XCTAssertEqual(narrow.shown + 1, narrow.columns * 2, "the thumbnails and the tile fill both rows")
    }

    func testExactlyTwoFullRowsHaveNoTile() {
        let full = plan(6, width: 3 * 120 + 2 * 8)
        XCTAssertEqual(full.shown, 6)
        XCTAssertEqual(full.hidden, 0)
        XCTAssertEqual(plan(7, width: 3 * 120 + 2 * 8).hidden, 2)
    }

    func testANarrowerWidthThanOneThumbnailIsOneColumn() {
        XCTAssertEqual(plan(1, width: 50).columns, 1)
        let column = plan(4, width: 50)
        XCTAssertEqual(column.columns, 1)
        XCTAssertEqual(column.shown, 1)
        XCTAssertEqual(column.hidden, 3)
        XCTAssertEqual(plan(2, width: 0).hidden, 0)
        XCTAssertEqual(plan(3, width: -10).columns, 1)
    }

    func testNoImagesAndOneImage() {
        XCTAssertEqual(plan(0, width: 400).shown, 0)
        XCTAssertEqual(plan(0, width: 400).hidden, 0)
        XCTAssertEqual(plan(1, width: 400).shown, 1)
        XCTAssertEqual(plan(-2, width: 400).shown, 0)
        XCTAssertEqual(ThumbnailRowPlan(count: 3, width: 100, thumbnailWidth: 0, spacing: 8).columns, 1)
    }

    func testTheTileSaysHowManyAreNotShown() {
        XCTAssertEqual(ThumbnailRowPlan.moreText(8), "+8")
        XCTAssertEqual(ThumbnailRowPlan.moreAccessibilityLabel(8), "8 more screenshots")
    }
}
