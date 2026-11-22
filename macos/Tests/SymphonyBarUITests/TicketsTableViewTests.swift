import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// TP-1501: the Tickets table as designed, over the `tickets-designed` fixture (the catalog's `TICKET_ROWS`). A
/// situation's glyph and word are never cut, down to the window's minimum width; the default columns fit a laptop's
/// page without scrolling sideways; Title and Situation share the width left, two parts to three.
@MainActor
final class TicketsTableViewTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/director-app/tickets-designed/api/v1")
    private static let reference = ISO8601DateFormatter().date(from: "2026-11-12T16:00:00Z")!

    private func read(_ name: String) throws -> Data { try Data(contentsOf: Self.fixtures.appendingPathComponent(name)) }

    private func rows() throws -> [TicketsRow] {
        try XCTUnwrap(TicketsPayload.decode(try read("tickets.json"))).rows
    }

    private func situations() throws -> [String: Situation] {
        Situation.byTicket(state: try read("state.json"))
    }

    /// The table's width on a page `window` pt wide less the sidebar, with the details beside it or not.
    private func tableWidth(window: Double, details: Bool) -> Double {
        let page = window - DesignTokens.Layout.sidebarWidth - 2 * DesignTokens.ControlBar.pageInset
        let table = page - (details ? DesignTokens.Tickets.detailsWidth + DesignTokens.Tickets.columnGap : 0)
        return table - 2 * DesignTokens.Tickets.tableInset
    }

    /// The default columns drawn on a page `window` pt wide, their widths in `available`, and the table's columns.
    private func layout(window: Double, available: Double) throws -> (columns: [DataTableColumn<TicketsRow>], widths: [Double]) {
        let rows = try rows()
        let page = window - DesignTokens.Layout.sidebarWidth
        let shown = TicketsQuery().drawnColumns(catalog: TicketColumn.catalog, scope: .all, width: page)
        let columns = TicketsTableColumns.columns(shown, rows: rows, situations: try situations(), reference: Self.reference)
        let measured = DataTableCache<TicketsRow>().layout(rows: rows, columns: columns, sort: nil).measured
        return (columns, DesignTokens.Table.widths(available: available, columns: columns.map(\.width), measured: measured))
    }

    /// The glyph and the word of a row's situation as drawn, alone.
    private func leadWidth(_ text: SituationText) -> Double {
        let host = NSHostingView(rootView: TicketSituationLead(text: text).fixedSize())
        return Double(host.fittingSize.width)
    }

    func testNoSituationWordIsCutAtTheWindowsMinimumWidth() throws {
        let rows = try rows()
        let state = TicketsTableState(situations: try situations(), reference: Self.reference)
        for details in [false, true] {
            let available = tableWidth(window: DesignTokens.Layout.minWindowWidth, details: details)
            let (columns, widths) = try layout(window: DesignTokens.Layout.minWindowWidth, available: available)
            let index = try XCTUnwrap(columns.firstIndex { $0.id == "situation" })
            let room = widths[index] - 2 * DesignTokens.Table.cellPadding
            for row in rows {
                let shown = state.situation(row)
                let drawn = leadWidth(shown)
                XCTAssertLessThanOrEqual(drawn, room, "\(row.identifier)'s “\(shown.word)” is cut (details \(details))")
            }
        }
    }

    func testTheSituationsLeastWidthHoldsTheWidestWordAsDrawn() throws {
        let state = TicketsTableState(situations: try situations(), reference: Self.reference)
        for row in try rows() {
            let shown = state.situation(row)
            XCTAssertGreaterThanOrEqual(TicketSituationCell.leadWidth(word: shown.word), leadWidth(shown), row.identifier)
        }
    }

    func testTheDefaultColumnsFitALaptopsPageWithTheDetails() throws {
        let available = tableWidth(window: 1440, details: true)
        let (columns, widths) = try layout(window: 1440, available: available)
        XCTAssertEqual(columns.map(\.title), ["Ticket", "Title", "Epic", "Situation", "Since", "Priority"])
        XCTAssertLessThanOrEqual(widths.reduce(0, +), available + 0.5, "the table scrolls sideways")
        let title = widths[1]
        let situation = widths[3]
        XCTAssertEqual(title / situation, 2.0 / 3.0, accuracy: 0.001)
    }

    func testRepoAndLabelsShowFrom1600PtOfPage() throws {
        let window = 1600 + DesignTokens.Layout.sidebarWidth
        let (columns, widths) = try layout(window: window, available: tableWidth(window: window, details: true))
        XCTAssertEqual(columns.map(\.title), ["Ticket", "Title", "Repo", "Epic", "Situation", "Since", "Labels", "Priority"])
        XCTAssertLessThanOrEqual(widths.reduce(0, +), tableWidth(window: window, details: true) + 0.5)
    }

    func testAChipColumnIsMeasuredWithTheChipsRoom() throws {
        let rows = try rows()
        let columns = TicketsTableColumns.columns(
            TicketColumn.catalog.filter { ["epic", "labels"].contains($0.name) }, rows: rows, reference: Self.reference
        )
        let measured = DataTableCache<TicketsRow>().layout(rows: rows, columns: columns, sort: nil).measured
        let epic = NSHostingView(rootView: Chip("Annual plans", kind: .epic).fixedSize()).fittingSize.width
        XCTAssertGreaterThanOrEqual(measured[0], Double(epic) + 2 * DesignTokens.Table.cellPadding - 1)
        let labels = NSHostingView(rootView: TicketLabelChips(labels: ["billing", "decision"]).fixedSize()).fittingSize.width
        XCTAssertGreaterThanOrEqual(measured[1], Double(labels) + 2 * DesignTokens.Table.cellPadding - 1)
        XCTAssertEqual(TicketsTableColumns.labelsRoom([]), 0)
    }

    func testAServerSortedTableKeepsTheRowsOrder() throws {
        let rows = try rows()
        let columns = TicketsTableColumns.columns(TicketColumn.catalog, rows: rows, reference: Self.reference)
        // The table hands the cache no sort when the server sorted: the rows stay as given.
        XCTAssertEqual(DataTableCache<TicketsRow>().layout(rows: rows, columns: columns, sort: nil).rows.map(\.id), rows.map(\.id))
        XCTAssertEqual(TicketsTableColumns.situationMinimum(leads: []), DesignTokens.Table.minShareWidth)
    }

    func testARowWithoutASituationReadsAsUnknown() {
        let state = TicketsTableState(situations: [:], reference: Self.reference)
        let shown = state.situation(TicketsRow(identifier: "TP-9", values: [:]))
        XCTAssertEqual(shown.kind, .unknown)
    }
}
