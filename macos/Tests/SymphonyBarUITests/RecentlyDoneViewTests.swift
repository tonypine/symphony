import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// TP-1644: Home's Recently done as drawn. The done row, a design-system component whose cells after the check, the
/// identifier and the title are the place's; the section's head with its range control and fold; the section above In
/// progress with six rows showing and the rest scrolled inside it, folded to its head, and not drawn at all when
/// nothing finished in the week; and the Gallery's stories of both components.
@MainActor
final class RecentlyDoneViewTests: XCTestCase {
    private let reference = ISO8601DateFormatter().date(from: "2026-10-07T14:20:00Z")!

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func fittingSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view.environment(\.offscreenSnapshot, true).environment(\.timeZone, TimeZone(identifier: "UTC")!))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    private let row = DoneRowModel(
        identifier: "TP-1622", title: "Engine: the queue's order is stored as one sort key per ticket", epic: "TP-1597", pullRequest: "#1053",
        repo: "symphony", when: "20 min ago"
    )

    /// A list read on `range` with `today` and `week` done and the range's first `entries`.
    private func list(_ range: HomeRead.DoneRange = .today, today: Int, week: Int, entries: Int, open: Bool = true) -> RecentlyDoneList {
        var list = RecentlyDoneList(range: range, open: open)
        let done = (0..<entries).map { index in
            HomeRead.DoneEntry(identifier: "TP-\(2000 + index)", title: "Done ticket \(index)", repoKey: "symphony", doneAt: reference)
        }
        list.take(HomeRead.RecentlyDone(range: range, today: today, week: week, entries: done))
        return list
    }

    // MARK: - c6: the done row's cells are the place's

    func testTheDoneRowDrawsTheCellsThePlaceAsksFor() {
        XCTAssertEqual(DoneRow.parts(.all), [.check, .identifier, .title, .epic, .pullRequest, .repo, .when])
        XCTAssertEqual(DoneRow.parts(.slotCard), [.check, .identifier, .title, .pullRequest, .when])
        XCTAssertEqual(DoneRow.parts(.queue), [.check, .identifier, .title, .when])
        XCTAssertEqual(DoneRow.parts(.all, epic: false), [.check, .identifier, .title, .pullRequest, .repo, .when], "no epic, no flag")
        XCTAssertEqual(DoneRow.Cells.all, [.epic, .pullRequest, .repo, .when])

        XCTAssertEqual(
            DoneRow.accessibilityLabel(row, cells: .all),
            "Done, TP-1622, Engine: the queue's order is stored as one sort key per ticket, part of TP-1597, pull request #1053, symphony, 20 min ago"
        )
        XCTAssertEqual(
            DoneRow.accessibilityLabel(row, cells: .slotCard),
            "Done, TP-1622, Engine: the queue's order is stored as one sort key per ticket, pull request #1053, 20 min ago"
        )
        XCTAssertEqual(DoneRow.accessibilityLabel(row, cells: .queue), "Done, TP-1622, Engine: the queue's order is stored as one sort key per ticket, 20 min ago")
        XCTAssertEqual(DoneRow.accessibilityIdentifier("TP-1622"), "done-row-TP-1622")
    }

    func testTheDoneRowIsOneLineAtTheQueueRowsHeightWithEveryCellSet() {
        let queue = DesignTokens.HomeQueue.self
        var bare = row
        bare.epic = nil
        bare.pullRequest = nil
        bare.title = String(repeating: "A very long title that runs past the row's end ", count: 6)
        for model in [row, bare] {
            for cells in [DoneRow.Cells.all, .slotCard, .queue] {
                let size = fittingSize(DoneRow(model, cells: cells).frame(width: 1120))
                XCTAssertEqual(size.height, queue.rowHeight, accuracy: 0.5, "one line: \(cells)")
                XCTAssertEqual(size.width, 1120, accuracy: 0.5)
            }
        }
        XCTAssertEqual(fittingSize(DoneRow(row, hovered: true).frame(width: 600)).height, queue.rowHeight, accuracy: 0.5)
        XCTAssertEqual(queue.pullRequestCell, 58)
        XCTAssertEqual(queue.repoCell, 68)
        XCTAssertEqual(queue.whenCell, 76)
    }

    func testAnEntryBecomesADoneRow() {
        let entry = HomeRead.DoneEntry(
            identifier: "TP-1622", title: "Engine", repoKey: "symphony", doneAt: reference.addingTimeInterval(-20 * 60), pullRequestNumber: 1053,
            epic: HomeRead.EpicRef(identifier: "TP-1597")
        )
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(
            HomeQueueCards.done(entry, reference: reference, timeZone: utc),
            DoneRowModel(identifier: "TP-1622", title: "Engine", epic: "TP-1597", pullRequest: "#1053", repo: "symphony", when: "20 min ago")
        )
        XCTAssertEqual(
            HomeQueueCards.done(HomeRead.DoneEntry(identifier: "A"), reference: reference, timeZone: utc),
            DoneRowModel(identifier: "A", title: "A", repo: "", when: "")
        )
    }

    // MARK: - c2: the head, and six rows showing with the rest scrolled inside the section

    func testTheHeadHasTheTitleTheCountTheRangeControlAndTheChevron() {
        XCTAssertEqual(RecentlyDoneHead.twistSymbol(open: true), "chevron.down")
        XCTAssertEqual(RecentlyDoneHead.twistSymbol(open: false), "chevron.right")
        XCTAssertEqual(RecentlyDoneHead.foldValue(open: true), "Open")
        XCTAssertEqual(RecentlyDoneHead.foldValue(open: false), "Folded")
        XCTAssertEqual(RecentlyDoneHead.rangeLabel, "Range")
        for count in ["5", nil] {
            for open in [true, false] {
                let head = RecentlyDoneHead(range: .constant(.week), count: count, open: open, hovered: !open) {}
                XCTAssertEqual(fittingSize(head.frame(width: 1120)).height, DesignTokens.HomeQueue.headHeight, accuracy: 0.5, "one line")
            }
        }
    }

    func testSixRowsShowAndTheRestScrollInsideTheSection() {
        let queue = DesignTokens.HomeQueue.self
        XCTAssertEqual(HomeRecentlyDone.listHeight(rows: 0), 0)
        XCTAssertEqual(HomeRecentlyDone.listHeight(rows: 1), queue.rowHeight)
        XCTAssertEqual(HomeRecentlyDone.listHeight(rows: 6), 6 * 36 - 2)
        XCTAssertEqual(HomeRecentlyDone.listHeight(rows: 10), HomeRecentlyDone.listHeight(rows: 6), "past six, the rows scroll")

        let head = queue.headHeight + queue.recentBottom
        let ten = fittingSize(HomeRecentlyDone(list: list(.week, today: 5, week: 10, entries: 10), reference: reference).frame(width: 1120))
        XCTAssertEqual(ten.height, head + queue.headBottom + HomeRecentlyDone.listHeight(rows: 6), accuracy: 0.5)
        let three = fittingSize(HomeRecentlyDone(list: list(today: 3, week: 10, entries: 3), reference: reference).frame(width: 1120))
        XCTAssertEqual(three.height, head + queue.headBottom + HomeRecentlyDone.listHeight(rows: 3), accuracy: 0.5)
        // Folded: the head alone.
        let folded = fittingSize(HomeRecentlyDone(list: list(today: 3, week: 10, entries: 3, open: false), reference: reference).frame(width: 1120))
        XCTAssertEqual(folded.height, head, accuracy: 0.5)
    }

    // MARK: - c4: the empty rules

    func testTheSectionKeepsItsHeadAloneWhenTodayIsEmptyAndIsNotDrawnWhenTheWeekIs() {
        let queue = DesignTokens.HomeQueue.self
        let todayEmpty = list(today: 0, week: 4, entries: 0)
        XCTAssertNil(todayEmpty.countText)
        let head = fittingSize(HomeRecentlyDone(list: todayEmpty, reference: reference).frame(width: 1120))
        XCTAssertEqual(head.height, queue.headHeight + queue.recentBottom, accuracy: 0.5, "the head, with no rows")

        let none = fittingSize(HomeRecentlyDone(list: list(today: 0, week: 0, entries: 0), reference: reference).frame(width: 1120))
        XCTAssertEqual(none.height, 0, accuracy: 0.5, "not drawn")
    }

    /// Home draws the section first, above In progress.
    func testHomeDrawsRecentlyDoneAboveInProgress() throws {
        let home = try String(contentsOf: Self.root.appendingPathComponent("macos/Sources/SymphonyBar/HomeView.swift"), encoding: .utf8)
        let section = try XCTUnwrap(home.range(of: "HomeRecentlyDone("))
        let progress = try XCTUnwrap(home.range(of: "            progress\n"))
        XCTAssertLessThan(section.lowerBound, progress.lowerBound)
    }

    // MARK: - c7: the Gallery's stories

    func testTheGalleryHasTheDoneRowAndTheHeadWithTheirStories() throws {
        let variations = try String(contentsOf: Self.root.appendingPathComponent("macos/Gallery/component-variations.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        for name in [
            "done-row-all-cells", "done-row-pull-request-and-when", "done-row-when-only", "done-row-without-an-epic", "done-row-long-title",
            "recently-done-head-with-a-count", "recently-done-head-without-a-count", "recently-done-head-week", "recently-done-head-folded",
        ] {
            XCTAssertTrue(variations.contains(name), "the gallery lists \(name)")
        }
        let entries = try String(contentsOf: Self.root.appendingPathComponent("macos/Gallery/Entries.swift"), encoding: .utf8)
        for id in ["done-row", "recently-done-head"] {
            XCTAssertTrue(entries.contains("id: \"\(id)\""), "the gallery has an entry for \(id)")
        }
        XCTAssertTrue(entries.contains("SymphonyBarUI/DesignSystem/DoneRow.swift"))
        XCTAssertTrue(entries.contains("SymphonyBarUI/DesignSystem/RecentlyDoneHead.swift"))
    }
}
