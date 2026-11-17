import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// TP-1510: the shared Table's order and measures. A sort orders the rows by its column's sort words and keeps ties
/// in the order given; a fitted column is as wide as its widest words or its title; the rows are measured again only
/// when they, the columns or the sort change.
@MainActor
final class DataTableTests: XCTestCase {
    struct Item: Identifiable {
        let id: String
        let name: String
        let count: Int
    }

    private let items = [
        Item(id: "a", name: "Workspace lifecycle docs", count: 9),
        Item(id: "b", name: "Checkout", count: 10),
        Item(id: "c", name: "Answer", count: 9),
    ]

    private let columns: [DataTableColumn<Item>] = [
        DataTableColumn("Name", id: "name", width: .share(1), text: \.name),
        DataTableColumn("Count", id: "count", alignment: .number, sortKey: { String($0.count) }) { "\($0.count) runs in all" },
        DataTableColumn("Id", id: "id", sortable: false, text: \.id),
    ]

    private func order(_ sort: DesignTokens.Table.Sort?) -> [String] {
        DataTableCache<Item>.sorted(items, columns: columns, sort: sort).map(\.id)
    }

    func testASortOrdersByItsColumnAndKeepsTiesInOrder() {
        XCTAssertEqual(order(nil), ["a", "b", "c"])
        XCTAssertEqual(order(DesignTokens.Table.Sort("name", ascending: true)), ["c", "b", "a"])
        XCTAssertEqual(order(DesignTokens.Table.Sort("count", ascending: false)), ["b", "a", "c"], "by value, not by its words")
        XCTAssertEqual(order(DesignTokens.Table.Sort("count", ascending: true)), ["a", "c", "b"], "a tie keeps its order")
        XCTAssertEqual(order(DesignTokens.Table.Sort("id", ascending: false)), ["a", "b", "c"], "a column that does not sort")
        XCTAssertEqual(order(DesignTokens.Table.Sort("gone", ascending: false)), ["a", "b", "c"])
    }

    func testAColumnsFirstClickFollowsItsKind() {
        XCTAssertTrue(columns[0].firstAscending, "words from A")
        XCTAssertFalse(columns[1].firstAscending, "numbers from the most")
    }

    func testAFittedColumnIsItsWidestWordsOrItsTitle() {
        let padding = 2 * DesignTokens.Table.cellPadding
        XCTAssertEqual(DataTableCache<Item>.measure(columns[0], rows: items), 0, "a column that shares is not measured")
        let count = DataTableCache<Item>.measure(columns[1], rows: items)
        let words = DataTableCache<Item>.width("10 runs in all", font: DataTableCache<Item>.numberFont)
        XCTAssertEqual(count, (words + padding).rounded(.up), accuracy: 1)
        let ids = DataTableCache<Item>.measure(columns[2], rows: items)
        XCTAssertGreaterThan(ids, padding, "the title is wider than a letter")
        XCTAssertEqual(DataTableCache<Item>.measure(columns[2], rows: []), ids, "an empty table keeps its titles")
        let badges = DataTableColumn<Item>("Id", id: "id", sortable: false, fitExtra: 30, text: \.id) { Text($0.id) }
        let widest = items.map { DataTableCache<Item>.width($0.id, font: DesignTokens.TypeStyle.body.nsFont) }.max() ?? 0
        XCTAssertEqual(DataTableCache<Item>.measure(badges, rows: items), (widest + 30 + padding).rounded(.up), accuracy: 1)
    }

    func testTheRowsAreMeasuredAgainOnlyWhenTheyOrTheSortChange() {
        let cache = DataTableCache<Item>()
        _ = cache.layout(rows: items, columns: columns, sort: nil)
        _ = cache.layout(rows: items, columns: columns, sort: nil)
        XCTAssertEqual(cache.measures, 1)
        let sorted = cache.layout(rows: items, columns: columns, sort: DesignTokens.Table.Sort("name", ascending: true))
        XCTAssertEqual(cache.measures, 2)
        XCTAssertEqual(sorted.rows.map(\.id), ["c", "b", "a"])
        XCTAssertEqual(sorted.measured.count, columns.count)
        _ = cache.layout(rows: Array(items.prefix(2)), columns: columns, sort: DesignTokens.Table.Sort("name", ascending: true))
        XCTAssertEqual(cache.measures, 3)
    }

    func testARowWhoseContentChangesUnderTheSameIdIsDrawnAsItIsNow() {
        let cache = DataTableCache<Item>()
        let byCount = DesignTokens.Table.Sort("count", ascending: false)
        let first = cache.layout(rows: items, columns: columns, sort: byCount)
        XCTAssertEqual(first.rows.map(\.id), ["b", "a", "c"])
        let changed = [
            Item(id: "a", name: "Workspace lifecycle docs", count: 9),
            Item(id: "b", name: "Checkout", count: 1),
            Item(id: "c", name: "Answer", count: 12_345),
        ]
        let next = cache.layout(rows: changed, columns: columns, sort: byCount)
        XCTAssertEqual(cache.measures, 2, "new words under the same ids are measured again")
        XCTAssertEqual(next.rows.map(\.id), ["c", "a", "b"], "the sort follows the new numbers")
        XCTAssertEqual(next.rows.map(\.count), [12_345, 9, 1], "the rows handed back are the ones just given")
        XCTAssertGreaterThan(next.measured[1], first.measured[1], "the wider number widens its fitted column")
    }

    func testARowWithTheSameWordsIsHandedBackAsGivenWithoutMeasuring() {
        struct Run: Identifiable {
            let id: Int
            let name: String
            let hidden: Int
        }
        let cache = DataTableCache<Run>()
        let columns = [DataTableColumn<Run>("Name", id: "name", width: .share(1), text: \.name)]
        _ = cache.layout(rows: [Run(id: 1, name: "One", hidden: 0)], columns: columns, sort: nil)
        let next = cache.layout(rows: [Run(id: 1, name: "One", hidden: 7)], columns: columns, sort: nil)
        XCTAssertEqual(cache.measures, 1)
        XCTAssertEqual(next.rows.map(\.hidden), [7], "a cell drawn from more than its words still shows the new row")
    }

    func testABadgeTakesItsPaddingAndGlyphBeyondItsWord() {
        let size = DesignTokens.Badge.Size.small
        XCTAssertEqual(size.tableRoom, size.leading + size.trailing + size.glyph + DesignTokens.Badge.gap)
    }
}
