import Foundation
@testable import SymphonyBarCore
import XCTest

/// How long Tickets takes to build with every ticket shown (TP-1541): 1,000 rows read from `GET /api/v1/tickets`, the
/// rows a search finds, and every cell's data, its tracked ticket looked up among 200 the state lists. The window
/// works the rows out once per read or keystroke and a cell reads its ticket by its identifier, so the whole build
/// stays well inside one frame's worth of work.
final class TicketsSpeedTests: XCTestCase {
    /// The budget for decoding the rows and building every cell's data once, on the CI runner.
    static let budget: TimeInterval = 0.150

    static let rowCount = 1_000
    static let trackedCount = 200

    private static let now = Date(timeIntervalSince1970: 1_793_000_000)
    private static let columns = TicketColumn.defaultColumns + ["phase", "situation_since"]
    private static let kinds = ["waiting_on_you", "working", "waiting_for_slot", "done", "cancelled"]

    /// 1,000 rows of every default column, as the server answers a view with no filter.
    static func payload() -> Data {
        let catalog = TicketColumn.catalog.filter { columns.contains($0.name) }
            .map { #"{"name": "\#($0.name)", "type": "\#($0.type)", "description": "\#($0.description)"}"# }
        let created = ISO8601DateFormatter().string(from: now.addingTimeInterval(-86_400))
        let rows = (1 ... rowCount).map { number in
            #"{"issue_id": "issue-\#(number)", "identifier": "TP-\#(number)", "title": "Ticket \#(number) does a thing", "#
                + #""repo": "\#(number.isMultiple(of: 3) ? "web" : "symphony")", "epic": "TP-\#(number / 50 + 1)", "#
                + #""phase": "\#(number.isMultiple(of: 5) ? "In Progress" : "Done")", "#
                + #""situation": "\#(kinds[number % kinds.count])", "situation_since": "\#(created)", "#
                + #""priority": \#(number % 5), "labels": ["bug", "agent", "backend", "ui"], "created_at": "\#(created)"}"#
        }
        return Data(#"{"columns": [\#(catalog.joined(separator: ", "))], "count": \#(rowCount), "tickets": [\#(rows.joined(separator: ", "))]}"#.utf8)
    }

    /// The state's 200 tracked tickets: every fifth row's.
    static func list() -> TicketList {
        let watching = (1 ... trackedCount).map { index in
            OverviewState.Ticket(issueID: "issue-\(index * 5)", identifier: "TP-\(index * 5)", title: "Ticket \(index * 5)", repoKey: "symphony", state: "In Progress")
        }
        return TicketList(state: OverviewState(generatedAt: now, watching: watching), now: now, timeZone: .gmt)
    }

    /// What every cell of `rows` reads: its tracked ticket, and its text or situation line.
    static func cells(_ rows: [TicketsRow], list: TicketList) -> Int {
        let columns = TicketColumn.catalog.filter { TicketColumn.defaultColumns.contains($0.name) }
        var filled = 0
        for row in rows {
            let tracked = list.row(row.identifier)
            for column in columns {
                switch column.name {
                case "situation": if row.situation(tracked: tracked?.situation) != nil { filled += 1 }
                case "labels": filled += row.labels.prefix(3).count
                default: if !row.cell(column, reference: now).isEmpty { filled += 1 }
                }
            }
        }
        return filled
    }

    func testTheFixtureHolds1000RowsAnd200TrackedTickets() throws {
        let payload = try XCTUnwrap(TicketsPayload.decode(Self.payload()))
        XCTAssertEqual(payload.rows.count, Self.rowCount)
        XCTAssertEqual(payload.count, Self.rowCount)
        XCTAssertEqual(Self.list().rows.count, Self.trackedCount)
    }

    func testACellFindsItsTrackedTicketByItsIdentifierInAnyCase() throws {
        let list = Self.list()
        XCTAssertEqual(list.row("TP-5")?.title, "Ticket 5")
        XCTAssertEqual(list.row("tp-1000")?.identifier, "TP-1000")
        XCTAssertNil(list.row("TP-6"))
        XCTAssertNil(list.row("TP-5 "))

        // A list whose rows change finds the new ones and no longer the old.
        var changed = list
        changed.rows = [try XCTUnwrap(list.row("TP-10"))]
        XCTAssertEqual(changed.row("tp-10")?.identifier, "TP-10")
        XCTAssertNil(changed.row("TP-5"))
    }

    func testTheSearchFindsTheSameRowsAsEachRowsOwnMatch() throws {
        let payload = try XCTUnwrap(TicketsPayload.decode(Self.payload()))
        XCTAssertEqual(payload.rows(matching: "").count, Self.rowCount)
        XCTAssertEqual(payload.rows(matching: "  "), payload.rows)
        XCTAssertEqual(payload.rows(matching: " tp-100 ").map(\.identifier), ["TP-100", "TP-1000"])
        XCTAssertEqual(payload.rows(matching: "ticket 99 does ").map(\.identifier), ["TP-99"])
        XCTAssertEqual(payload.rows(matching: "TP-12").map(\.identifier), payload.rows.filter { $0.matches("TP-12") }.map(\.identifier))
    }

    func testATimeReadByHandIsTheFormattersTime() throws {
        let whole = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for text in ["1970-01-01T00:00:00Z", "2026-10-07T14:00:00Z", "2024-02-29T23:59:59Z", "1999-12-31T12:30:15Z", "2100-03-01T00:00:00Z"] {
            XCTAssertEqual(TicketsPayload.utcTime(text), whole.date(from: text), text)
            XCTAssertEqual(TicketsPayload.time(text), whole.date(from: text), text)
        }
        let micro = try XCTUnwrap(TicketsPayload.utcTime("2026-10-07T14:00:00.123456Z"))
        XCTAssertEqual(micro.timeIntervalSince1970, try XCTUnwrap(fractional.date(from: "2026-10-07T14:00:00.123Z")).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(TicketsPayload.utcTime("2026-10-07T14:00:00.5Z")?.timeIntervalSince1970, 1_791_381_600.5)

        // Any other shape is the formatters' to read: an offset, a bad digit, a date out of range, no fraction after the dot.
        for text in ["2026-10-07T14:00:00+02:00", "2026-10-07T14:00:00", "2026-1x-07T14:00:00Z", "2026-13-07T14:00:00Z",
                     "2026-10-07T24:00:00Z", "2026-10-07 14:00:00Z", "2026-10-07T14:00:00.Z", "2026-10-07T14:00:00,5Z",
                     "2026-10-07T14:00:00.1234567890Z", "2026-10-07T14:00:00ZZ", "yesterday"] {
            XCTAssertNil(TicketsPayload.utcTime(text), text)
        }
        XCTAssertEqual(TicketsPayload.time("2026-10-07T16:00:00+02:00"), whole.date(from: "2026-10-07T14:00:00Z"))
        XCTAssertNil(TicketsPayload.time("yesterday"))
    }

    func testOneThousandRowsAndTheirCellsBuildWithinTheBudget() throws {
        let data = Self.payload()
        let list = Self.list()
        func build(_ search: String) -> Int {
            guard let payload = TicketsPayload.decode(data) else { return 0 }
            return Self.cells(payload.rows(matching: search), list: list)
        }
        // Every row, and every cell but an empty one, is built.
        XCTAssertGreaterThan(build(""), Self.rowCount * TicketColumn.defaultColumns.count)
        XCTAssertGreaterThan(build("Ticket"), 0)

        // The best of five builds, so one slow moment of a shared runner doesn't fail it.
        var best = TimeInterval.infinity
        for _ in 0 ..< 5 {
            let began = Date()
            _ = build("")
            best = min(best, Date().timeIntervalSince(began))
        }
        print("TicketsSpeedTests: 1,000 rows and their cells built in \(String(format: "%.1f", best * 1_000)) ms (budget \(Int(Self.budget * 1_000)) ms)")
        XCTAssertLessThan(best, Self.budget, "Building 1,000 rows and their cells took \(Int(best * 1_000)) ms")
    }
}
