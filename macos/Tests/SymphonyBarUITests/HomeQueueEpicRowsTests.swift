import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// TP-1645: an epic in Home's queue and the dependency marker, drawn from the `home-queue-epics` fixture's read with the
/// Gallery's components: the epic's row with its chevron and its done count, a sub-ticket's row one step in with its
/// elbow and its number inside the epic, an epic's done row with no number, and the marker of each unmet dependency.
@MainActor
final class HomeQueueEpicRowsTests: XCTestCase {
    private let reference = ISO8601DateFormatter().date(from: "2026-10-07T14:20:00Z")!

    private func fixtureRead(view: String? = nil) throws -> HomeRead {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/home-queue-epics/api/v1")
        let fixture = try XCTUnwrap(HomeQueueFixture(try Data(contentsOf: directory.appendingPathComponent(HomeQueueFixture.fileName))))
        let views = try? Data(contentsOf: directory.appendingPathComponent("views.json"))
        let query = "offset=0&limit=100" + (view.map { "&view=\($0)" } ?? "")
        return try XCTUnwrap(HomeRead.decode(fixture.answer(query: query, views: views, slotCount: nil)))
    }

    private func row(_ identifier: String, in read: HomeRead) throws -> HomeRead.Row {
        try XCTUnwrap(read.queue.rows.first { $0.identifier == identifier })
    }

    // MARK: - c1: the epic's row and its sub-rows, numbered inside it

    func testAnEpicsRowHasItsChevronAndItsSubRowsSitOneStepInWithTheirNumberInsideIt() throws {
        let read = try fixtureRead()
        let epic = HomeQueueCards.row(try row("TP-975", in: read))
        XCTAssertEqual(epic.epic, QueueRowModel.Epic(done: 2, total: 8, open: true, showingDone: false))
        XCTAssertEqual(epic.depth, 0)
        XCTAssertEqual(epic.marks, [], "an epic's row carries its done count, not a state badge")
        XCTAssertEqual(epic.numberText, "6")

        let closed = HomeQueueCards.row(try row("TP-975", in: read), fold: HomeQueueFold(closed: ["TP-975"], showingDone: ["TP-975"]))
        XCTAssertEqual(closed.epic?.open, false)
        XCTAssertEqual(closed.epic?.showingDone, false, "a closed epic shows no done rows")
        XCTAssertEqual(QueueEpicChevron.symbol(open: true), "chevron.down")
        XCTAssertEqual(QueueEpicChevron.symbol(open: false), "chevron.right")

        let sub = HomeQueueCards.row(try row("TP-977", in: read))
        XCTAssertEqual(sub.depth, 1)
        XCTAssertEqual(sub.numberText, "6.2")
        XCTAssertEqual(sub.number, 6)
        XCTAssertNil(sub.epic)
        XCTAssertEqual(QueueNumberText.split("6.2").whole, "6")
        XCTAssertEqual(QueueNumberText.split("6.2").fraction, ".2")
        XCTAssertEqual(QueueNumberText.split("1,243").fraction, "")
        XCTAssertEqual(DesignTokens.HomeQueue.subRowStep, 28, "a sub-row's state glyph starts where its epic's identifier starts")
    }

    /// Where each part of `row` stands in a row 900 wide.
    private func parts(_ row: QueueRowModel, look: QueueRow.Look = .rest, fraction: CGFloat) -> [QueueRow.Part: CGRect] {
        let probes = Dictionary(uniqueKeysWithValues: QueueRow.Part.allCases.map { ($0, NSView()) })
        let host = NSHostingView(
            rootView: QueueRow(row, numberWidth: QueueRow.numberWidth(widest: 6), fractionWidth: fraction, look: look)
                .frame(width: 900)
                .environment(\.queueRowProbes, probes)
                .environment(\.offscreenSnapshot, true)
        )
        host.frame = CGRect(x: 0, y: 0, width: 900, height: DesignTokens.HomeQueue.rowHeight)
        host.layoutSubtreeIfNeeded()
        return probes.mapValues { $0.convert($0.bounds, to: host) }
    }

    func testASubRowsStateGlyphStandsWhereItsEpicsIdentifierStandsAndHoverShiftsNothing() throws {
        let read = try fixtureRead()
        let fraction = QueueRow.fractionWidth(characters: 2)
        let epic = parts(HomeQueueCards.row(try row("TP-975", in: read)), fraction: fraction)
        let sub = parts(HomeQueueCards.row(try row("TP-977", in: read)), fraction: fraction)
        XCTAssertEqual((sub[.lead] ?? .null).minX, (epic[.identifier] ?? .null).minX, accuracy: 0.5)
        XCTAssertEqual((sub[.elbow] ?? .null).minX, (epic[.lead] ?? .null).minX, accuracy: 0.5, "the elbow stands under the chevron")
        XCTAssertGreaterThan((epic[.doneCount] ?? .null).width, 0, "the epic's row draws its done count")
        XCTAssertLessThan((epic[.doneCount] ?? .null).maxX, (epic[.repo] ?? .null).minX, "the done count stands before the repo")
        XCTAssertGreaterThan((sub[.dependencies] ?? .null).width, 0, "TP-977 waits for TP-976")
        let hovered = parts(HomeQueueCards.row(try row("TP-977", in: read)), look: .hover, fraction: fraction)
        for part in [QueueRow.Part.elbow, .lead, .identifier, .title, .dependencies] {
            XCTAssertEqual(hovered[part] ?? .null, sub[part] ?? .null, "\(part) keeps its place on hover")
        }
        XCTAssertEqual((hovered[.handle] ?? .null).midX, (sub[.number] ?? .null).midX, accuracy: 0.5, "the handle takes the number's place")
        XCTAssertGreaterThan(fraction, 0)
        XCTAssertEqual(QueueRow.fractionWidth(characters: 0), 0, "the cell widens only while sub-rows are on screen")
        XCTAssertGreaterThan(QueueRow.fractionWidth(characters: 3), fraction)
        XCTAssertEqual(DesignTokens.HomeQueue.fractionTemplate(characters: 3), ".00")
        XCTAssertEqual(QueueDropLine.indent(numberCell: 30), 30 + DesignTokens.HomeQueue.rowPartGap + DesignTokens.HomeQueue.subRowStep)
    }

    func testAnEpicsRowSaysItsFoldItsDoneCountAndWhatItsSubRowsWaitFor() throws {
        let read = try fixtureRead()
        let epic = HomeQueueCards.row(try row("TP-975", in: read))
        XCTAssertEqual(QueueRow.accessibilityLabel(epic, picked: false), "Number 6, TP-975, Protected-change requests: ask, allow, record, open, 2 of 8 done")
        XCTAssertEqual(QueueRow.toggleTitle(open: true), "Hide sub-tickets")
        XCTAssertEqual(QueueRow.toggleTitle(open: false), "Show sub-tickets")
        XCTAssertEqual(QueueRow.toggleDoneTitle(showing: false), "Show done sub-tickets")
        XCTAssertEqual(QueueRow.toggleDoneTitle(showing: true), "Hide done sub-tickets")
        let sub = HomeQueueCards.row(try row("TP-977", in: read))
        XCTAssertTrue(QueueRow.accessibilityLabel(sub, picked: true).hasSuffix("waits for TP-976, Dragged"))
    }

    // MARK: - c2: the done count is a control; the done rows are quiet, with an elbow and no number

    func testTheDoneCountIsAControlWithAPressedStateAndTheDoneRowsShowOnlyWhen() throws {
        XCTAssertEqual(DesignTokens.HomeQueue.doneCount(done: 2, total: 11), "2 of 11 done")
        XCTAssertTrue(QueueDoneCount.lifted(pressed: true, hovered: false), "pressed while the done rows show")
        XCTAssertTrue(QueueDoneCount.lifted(pressed: false, hovered: true))
        XCTAssertFalse(QueueDoneCount.lifted(pressed: false, hovered: false))

        let read = try fixtureRead()
        let epic = try row("TP-975", in: read)
        let done = HomeQueueCards.done(epic.doneSubTickets[0], epic: epic.identifier, reference: reference, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(done.identifier, "TP-982")
        XCTAssertEqual(done.title, "Name the files a change may never touch")
        XCTAssertEqual(done.pullRequest, "#598")
        XCTAssertEqual(DoneRow.parts(.queue), [.check, .identifier, .title, .when], "no number, no handle, no Start: when alone")
        XCTAssertEqual(DoneRow.accessibilityLabel(done, cells: .queue), "Done, TP-982, Name the files a change may never touch, \(done.when)")

        // Nested, its check stands where a sub-row's state glyph stands.
        let width = QueueRow.numberWidth(widest: 6)
        let fraction = QueueRow.fractionWidth(characters: 2)
        let nested = NSHostingView(
            rootView: DoneRow(done, cells: .queue, nesting: DoneRow.Nesting(numberCell: width + fraction), picked: true)
                .frame(width: 900).environment(\.offscreenSnapshot, true)
        )
        nested.frame = CGRect(x: 0, y: 0, width: 900, height: DesignTokens.HomeQueue.rowHeight)
        nested.layoutSubtreeIfNeeded()
        XCTAssertEqual(nested.fittingSize.height, DesignTokens.HomeQueue.rowHeight, accuracy: 0.5)
        let deeper = NSHostingView(
            rootView: DoneRow(done, cells: .queue, nesting: DoneRow.Nesting(numberCell: width, depth: 2)).frame(width: 900)
                .environment(\.offscreenSnapshot, true)
        )
        deeper.layoutSubtreeIfNeeded()
        XCTAssertEqual(deeper.fittingSize.height, DesignTokens.HomeQueue.rowHeight, accuracy: 0.5)
    }

    // MARK: - c3: a marker for each unmet dependency, in both kinds; a met one shows nothing

    func testARowCarriesAMarkerForEachUnmetDependencyInBothKinds() throws {
        let read = try fixtureRead()
        XCTAssertEqual(HomeQueueCards.row(try row("TP-977", in: read)).dependencies, [DependencyMarkerModel(identifier: "TP-976")])
        let released = HomeQueueCards.row(try row("TP-1051", in: read)).dependencies
        XCTAssertEqual(released, [DependencyMarkerModel(identifier: "TP-1590", kind: .released)])
        XCTAssertEqual(released.first?.text, "TP-1590 released")
        XCTAssertEqual(released.first?.help, "Starts when TP-1590 is released")
        XCTAssertEqual(released.first?.accessibilityLabel, "waits for TP-1590 to be released")
        let done = DependencyMarkerModel(identifier: "TP-976")
        XCTAssertEqual(done.text, "TP-976")
        XCTAssertEqual(done.help, "Starts when TP-976 is done")
        XCTAssertEqual(done.accessibilityLabel, "waits for TP-976")
        XCTAssertEqual(HomeQueueCards.row(try row("TP-1700", in: read)).dependencies, [], "a met dependency shows nothing")
        XCTAssertEqual(HomeQueueCards.row(try row("TP-1590", in: read)).dependencies, [])

        let marker = NSHostingView(rootView: DependencyMarker(released[0]).environment(\.offscreenSnapshot, true))
        marker.layoutSubtreeIfNeeded()
        let short = NSHostingView(rootView: DependencyMarker(done).environment(\.offscreenSnapshot, true))
        short.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(marker.fittingSize.width, short.fittingSize.width, "the released kind says the word after the identifier")
    }

    // MARK: - c4: under a saved view the rows keep their form

    func testUnderASavedViewTheRowsKeepTheirNestingAndRealNumbers() throws {
        let read = try fixtureRead(view: "view-rework")
        let rows = read.queue.rows.map { HomeQueueCards.row($0) }
        XCTAssertEqual(rows.map(\.numberText), ["3", "6", "6.3", "6.6"])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 1, 1])
        XCTAssertNotNil(rows[1].epic, "the epic's row keeps its chevron and its done count")
    }

    // MARK: - c8: the Gallery has the epic row, the sub-ticket row and the dependency marker, with stories

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testTheGalleryListsTheEpicRowTheSubRowAndTheDependencyMarkerWithTheirStories() throws {
        let variations = try String(contentsOf: Self.root.appendingPathComponent("macos/Gallery/component-variations.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        for name in [
            "queue-epic-row-closed", "queue-epic-row-open", "queue-epic-row-done-shown", "queue-epic-row-done-count-hovered",
            "queue-sub-row-at-rest", "queue-sub-row-hovered", "dependency-marker-done", "dependency-marker-released",
        ] {
            XCTAssertTrue(variations.contains(name), "the gallery lists \(name)")
        }
        let entries = try String(contentsOf: Self.root.appendingPathComponent("macos/Gallery/Entries.swift"), encoding: .utf8)
        for (id, file) in [
            ("queue-epic-row", "SymphonyBarUI/DesignSystem/QueueEpicParts.swift"), ("queue-sub-row", "SymphonyBarUI/DesignSystem/QueueEpicParts.swift"),
            ("dependency-marker", "SymphonyBarUI/DesignSystem/DependencyMarker.swift"),
        ] {
            XCTAssertTrue(entries.contains("id: \"\(id)\""), "the gallery has an entry for \(id)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("macos/Sources/\(file)").path), "\(file) is in the design system")
        }
    }
}
