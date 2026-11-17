import XCTest
@testable import SymphonyBarCore

/// TP-1510: the catalog's Table. Fitted columns keep their width; the columns that share split what is left in their
/// proportions, none under its minimum, and past that the table scrolls. A header click sorts and a second reverses;
/// Up and Down move the pick; every second row at rest is banded; VoiceOver reads headers with their sort.
final class TableTokensTests: XCTestCase {
    typealias Table = DesignTokens.Table

    func testTheCatalogsMeasures() {
        XCTAssertEqual(Table.headerHeight, 32)
        XCTAssertEqual(Table.rowHeight, 36)
        XCTAssertEqual(Table.cellPadding, DesignTokens.Space.s3)
        XCTAssertEqual(Table.headerButton, .small)
        XCTAssertEqual(Table.sortGlyph, 9)
        XCTAssertEqual(Table.emptyHeight, 140)
        XCTAssertEqual(Table.band.light, DesignTokens.RGBA(24, 24, 48, 0.022))
        XCTAssertEqual(Table.band.dark, DesignTokens.RGBA(255, 255, 255, 0.022))
    }

    // MARK: - Widths

    func testFittedColumnsKeepTheirWidthAndTheSharesSplitTheRestInProportion() {
        let widths = Table.widths(available: 800, columns: [.fit, .share(2), .share(1), .fit], measured: [100, 0, 0, 100])
        XCTAssertEqual(widths, [100, 400, 200, 100])
    }

    func testAShareUnderItsMinimumTakesItAndTheOthersSplitWhatIsLeft() {
        let widths = Table.widths(
            available: 400, columns: [.fit, .share(3), .share(1, minimum: 100)], measured: [100, 0, 0]
        )
        XCTAssertEqual(widths, [100, 200, 100], "the small share would be 75, so it takes its 100 and the other the rest")
    }

    func testNoFittedColumnIsSqueezedAndTheTableGrowsPastItsWidth() {
        let widths = Table.widths(available: 200, columns: [.fit, .share(1), .fit], measured: [120, 0, 90])
        XCTAssertEqual(widths, [120, Table.minShareWidth, 90])
        XCTAssertGreaterThan(widths.reduce(0, +), 200, "wider than it has: it scrolls sideways")
    }

    func testOnlyFittedColumnsAndZeroWeights() {
        XCTAssertEqual(Table.widths(available: 500, columns: [.fit, .fit], measured: [80, 60]), [80, 60])
        XCTAssertEqual(Table.widths(available: 500, columns: [.share(0), .share(0)], measured: []), [250, 250])
        XCTAssertEqual(Table.widths(available: 500, columns: [.fit], measured: []), [0], "a column with no measure has none")
        XCTAssertNil(Table.Width.fit.weight)
        XCTAssertEqual(Table.Width.share(-1).weight, 0)
    }

    func testTheFirstColumnStaysInPlace() {
        XCTAssertEqual(Table.pinnedOffset(scrolled: 140), 140)
        XCTAssertEqual(Table.pinnedOffset(scrolled: -12), 0, "a bounce past the leading edge moves it with the table")
    }

    // MARK: - Sorting

    func testAClickSortsAndASecondReverses() {
        let first = Table.Sort.toggled(nil, column: "age")
        XCTAssertEqual(first, Table.Sort("age", ascending: false), "the catalog sorts a new column most first")
        XCTAssertEqual(Table.Sort.toggled(first, column: "age"), Table.Sort("age", ascending: true))
        XCTAssertEqual(Table.Sort.toggled(first, column: "ident", firstAscending: true), Table.Sort("ident", ascending: true))
    }

    func testNumbersSortByValueAndWordsAsFinderDoes() {
        XCTAssertTrue(Table.Sort.ordered("9", "10", ascending: true))
        XCTAssertTrue(Table.Sort.ordered("1,204", "980", ascending: false))
        XCTAssertTrue(Table.Sort.ordered("3.4M", "900K", ascending: false))
        XCTAssertTrue(Table.Sort.ordered("TP-9", "TP-10", ascending: true))
        XCTAssertFalse(Table.Sort.ordered("5", "5", ascending: true), "equal cells keep their order")
        XCTAssertEqual(Table.Sort.number("62%"), 62)
        XCTAssertEqual(Table.Sort.number("\u{2212}12"), -12)
        XCTAssertEqual(Table.Sort.number(" 2B "), 2e9)
        XCTAssertNil(Table.Sort.number("symphony"))
    }

    // MARK: - Keys

    func testUpAndDownMoveThePickAndHoldAtTheEnds() {
        XCTAssertEqual(Table.moved(nil, by: 1, count: 5), 0)
        XCTAssertEqual(Table.moved(nil, by: -1, count: 5), 4)
        XCTAssertEqual(Table.moved(2, by: 1, count: 5), 3)
        XCTAssertEqual(Table.moved(0, by: -1, count: 5), 0)
        XCTAssertEqual(Table.moved(4, by: 1, count: 5), 4)
        XCTAssertEqual(Table.moved(9, by: 1, count: 5), 0, "a pick no longer shown starts again")
        XCTAssertNil(Table.moved(nil, by: 1, count: 0))
    }

    // MARK: - Fills

    func testEverySecondRowAtRestIsBandedAndThePickIsTheAccent() {
        XCTAssertNil(Table.fill(0, selected: false, hovered: false))
        XCTAssertEqual(Table.fill(1, selected: false, hovered: false), .band)
        XCTAssertEqual(Table.fill(1, selected: false, hovered: true), .hover)
        XCTAssertEqual(Table.fill(1, selected: true, hovered: true), .accent)
        XCTAssertEqual(Table.fill(2, selected: true, hovered: false, windowActive: false), .inactiveSelection)
        XCTAssertFalse(Table.banded(3, selected: true, hovered: false))
    }

    // MARK: - VoiceOver

    func testAHeaderReadsItsSortAndARowItsCells() {
        XCTAssertEqual(
            Table.spokenHeader("Age", sort: Table.Sort("age", ascending: false), column: "age", ascending: "newest first", descending: "oldest first"),
            "Age, sorted, oldest first"
        )
        XCTAssertEqual(
            Table.spokenHeader("Age", sort: Table.Sort("age", ascending: true), column: "age", ascending: "newest first", descending: "oldest first"),
            "Age, sorted, newest first"
        )
        XCTAssertEqual(Table.spokenHeader("Repo", sort: Table.Sort("age", ascending: true), column: "repo", ascending: "", descending: ""), "Repo")
        XCTAssertEqual(Table.spokenHeader("Repo", sort: nil, column: "repo", ascending: "", descending: ""), "Repo")
        XCTAssertEqual(Table.spokenRow(titles: ["Ticket", "Repo", "Age"], cells: ["TP-1382", "", "3 h"]), "Ticket, TP-1382. Age, 3 h")
    }
}
