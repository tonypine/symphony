import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// TP-1646: the epic slot card, drawn from the `home-queue-epic-slot` fixture's read with the Gallery's components: the
/// band with the epic, its done count with its bar and its time in the slot, around the ordinary slot card of the
/// sub-ticket in work; below it the sub-tickets to come, numbered on from the done count, and above it the done ones,
/// oldest at the top; each list six rows high, scrolling inside itself.
@MainActor
final class EpicSlotCardTests: XCTestCase {
    private let reference = ISO8601DateFormatter().date(from: "2026-10-07T14:20:00Z")!
    private let utc = TimeZone(identifier: "UTC")!

    private func fixtureRead() throws -> HomeRead {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/home-queue-epic-slot/api/v1")
        let fixture = try XCTUnwrap(HomeQueueFixture(try Data(contentsOf: directory.appendingPathComponent(HomeQueueFixture.fileName))))
        return try XCTUnwrap(HomeRead.decode(fixture.answer(query: "offset=0&limit=100", views: nil, slotCount: nil)))
    }

    private func models() throws -> (epic: EpicSlotCardModel, ticket: SlotCardModel) {
        let slot = try XCTUnwrap(try fixtureRead().slots.first)
        let epic = try XCTUnwrap(slot.epic)
        let ticket = try XCTUnwrap(slot.ticket)
        return (HomeQueueCards.epicCard(epic, reference: reference, timeZone: utc), HomeQueueCards.card(ticket, reference: reference))
    }

    // MARK: - c1: the band names the epic, its count with a bar and its time in the slot, around the card in work

    func testTheBandNamesTheEpicItsDoneCountAndItsTimeInTheSlot() throws {
        let (epic, ticket) = try models()
        XCTAssertEqual(epic.identifier, "TP-1597")
        XCTAssertEqual(epic.title, "A real queue: a slot belongs to one ticket until it is done, and Home is the window to the queue")
        XCTAssertEqual(epic.doneText, "7 of 16 done")
        XCTAssertEqual(epic.fraction, 7.0 / 16.0, accuracy: 0.0001)
        XCTAssertEqual(epic.sinceText, "3 d in the slot", "since 2026-10-04 14:00, in the band's short form")
        XCTAssertEqual(EpicSlotCardModel.slotTime(3 * 86400 + 20 * 60), "3 d")
        XCTAssertEqual(EpicSlotCardModel.slotTime(86400), "1 d")
        XCTAssertEqual(EpicSlotCardModel.slotTime(3900), "1 h 5 min")
        XCTAssertEqual(EpicSlotCardModel.slotTime(14 * 60), "14 min")
        XCTAssertEqual(EpicSlotCardModel.slotTime(-5), "0 s")
        XCTAssertEqual(ticket.identifier, "TP-1619", "the card inside is the sub-ticket in work")
        XCTAssertNil(ticket.epic, "the band names the epic: the card carries no chip")
        XCTAssertEqual(SlotCard.sinceText("1 h 5 min", inEpic: true), "1 h 5 min on this ticket")
        XCTAssertEqual(SlotCard.sinceText("1 h 5 min", inEpic: false), "1 h 5 min in the slot")
        XCTAssertEqual(DesignTokens.HomeQueue.epicBandHeight, 36)
        XCTAssertEqual(DesignTokens.HomeQueue.epicBarWidth, 96)
        XCTAssertEqual(DesignTokens.HomeQueue.epicFrameInset, 4)
        XCTAssertEqual(DesignTokens.HomeQueue.epicFrameRadius, DesignTokens.Radius.card + 4)
        XCTAssertEqual(
            EpicSlotCard.accessibilityLabel(1, epic: epic, ticket: ticket.identifier), "Slot 1: TP-1597, 7 of 16 done, TP-1619 in work"
        )
        XCTAssertEqual(EpicSlotCard.bandLabel(epic), "TP-1597, \(epic.title), \(epic.sinceText)")
    }

    func testTheClosedCardIsTheBandAroundTheOrdinaryCard() throws {
        let (epic, ticket) = try models()
        // The card inside stands in the frame's 4 pt at each side.
        let card = height(SlotCard(slot: 1, ticket: ticket, inEpic: true), width: 1120 - 2 * DesignTokens.HomeQueue.epicFrameInset)
        let closed = height(EpicSlotCard(slot: 1, epic: epic, ticket: ticket))
        XCTAssertEqual(closed, card + DesignTokens.HomeQueue.epicBandHeight + DesignTokens.HomeQueue.epicFrameInset, accuracy: 0.5)
    }

    // MARK: - c2: rows to come, in queue order, numbered on from the done count, with their markers

    func testRowsToComeAreQueueRowsNumberedOnFromTheDoneCount() throws {
        let (epic, _) = try models()
        XCTAssertEqual(
            epic.upcoming.map(\.identifier), ["TP-1623", "TP-1624", "TP-1607", "TP-1609", "TP-1610", "TP-1620", "TP-1625", "TP-1626"]
        )
        XCTAssertEqual(epic.upcoming.map(\.numberText), ["9", "10", "11", "12", "13", "14", "15", "16"], "7 done and one in work: 9 first")
        XCTAssertEqual(epic.upcoming.map(\.depth), Array(repeating: 0, count: 8), "on the band's columns, without a step")
        XCTAssertEqual(epic.upcoming[0].dependencies, [])
        XCTAssertEqual(epic.upcoming[1].dependencies, [DependencyMarkerModel(identifier: "TP-1623")])
        XCTAssertEqual(epic.upcoming[1].repo, "symphony")
        XCTAssertEqual(epic.widestNumber, 16)
    }

    // MARK: - c2, c3: the band opens what is to come below; the done count what is done above

    func testEachControlOpensItsOwnListAndTheDoneCountIsLiftedWhileItsListShows() throws {
        let (epic, ticket) = try models()
        let closed = height(EpicSlotCard(slot: 1, epic: epic, ticket: ticket))
        let list = EpicSlotCard.listHeight(rows: 8) + DesignTokens.HomeQueue.epicFrameInset
        let upcoming = height(EpicSlotCard(slot: 1, epic: epic, ticket: ticket, showsUpcoming: true))
        let done = height(EpicSlotCard(slot: 1, epic: epic, ticket: ticket, showsDone: true))
        let both = height(EpicSlotCard(slot: 1, epic: epic, ticket: ticket, showsUpcoming: true, showsDone: true))
        XCTAssertEqual(upcoming, closed + list, accuracy: 0.5)
        XCTAssertEqual(done, closed + EpicSlotCard.listHeight(rows: 7) + DesignTokens.HomeQueue.epicFrameInset, accuracy: 0.5)
        XCTAssertEqual(both, closed + list + EpicSlotCard.listHeight(rows: 7) + DesignTokens.HomeQueue.epicFrameInset, accuracy: 0.5)
        XCTAssertTrue(EpicSlotCard.doneLifted(showing: true, hovered: false))
        XCTAssertTrue(EpicSlotCard.doneLifted(showing: false, hovered: true))
        XCTAssertFalse(EpicSlotCard.doneLifted(showing: false, hovered: false))
        XCTAssertEqual(EpicSlotCard.upcomingTitle(open: false), "Show what is to come")
        XCTAssertEqual(EpicSlotCard.upcomingTitle(open: true), "Hide what is to come")
        XCTAssertEqual(EpicSlotCard.bandIdentifier(1), "epic-slot-band-1")
        XCTAssertEqual(EpicSlotCard.doneCountIdentifier(1), "epic-slot-done-count-1")
        XCTAssertEqual(EpicSlotCard.upcomingIdentifier(1), "epic-slot-upcoming-1")
        XCTAssertEqual(EpicSlotCard.doneListIdentifier(1), "epic-slot-done-1")
        XCTAssertEqual(EpicSlotCard.identifier(1), "epic-slot-card-1")
    }

    func testAnOpenListWithNothingInItDrawsNothing() throws {
        let (epic, ticket) = try models()
        var empty = epic
        empty.doneRows = []
        empty.upcoming = []
        let closed = height(EpicSlotCard(slot: 1, epic: empty, ticket: ticket))
        XCTAssertEqual(height(EpicSlotCard(slot: 1, epic: empty, ticket: ticket, showsUpcoming: true, showsDone: true)), closed, accuracy: 0.5)
    }

    func testDoneRowsAreOldestFirstWithThePullRequestAndWhen() throws {
        let (epic, _) = try models()
        XCTAssertEqual(epic.doneRows.map(\.identifier), ["TP-1611", "TP-1612", "TP-1608", "TP-1615", "TP-1616", "TP-1606", "TP-1622"])
        XCTAssertEqual(epic.doneRows.first?.pullRequest, "#1047")
        XCTAssertEqual(epic.doneRows.last?.pullRequest, "#1053")
        XCTAssertEqual(epic.doneRows.last?.when, DoneWhen.text(ISO8601DateFormatter().date(from: "2026-10-07T13:45:00Z"), now: reference, timeZone: utc))
        XCTAssertEqual(DoneRow.parts(.slotCard), [.check, .identifier, .title, .pullRequest, .when])
        let nesting = DoneRow.Nesting(numberCell: 14, depth: 0, end: 8)
        XCTAssertFalse(nesting.quiet, "on a card a done row is not quiet")
        XCTAssertTrue(DoneRow.Nesting(numberCell: 14).quiet, "in the queue it is")
    }

    // MARK: - c4: six rows, then the list scrolls; the done list opens at its end

    func testEachListIsSixRowsHighAndTheDoneListOpensAtItsMostRecentRows() {
        XCTAssertEqual(EpicSlotCard.listHeight(rows: 8), 216, "six rows on the 36 pt pitch")
        XCTAssertEqual(EpicSlotCard.listHeight(rows: 6), 216)
        XCTAssertEqual(EpicSlotCard.listHeight(rows: 2), 72, "a short list is as tall as its rows")
        XCTAssertEqual(EpicSlotCard.listHeight(rows: -1), 0)
        XCTAssertEqual(EpicSlotCard.doneAnchor, .bottom)
        XCTAssertEqual(Array(EpicSlotCard.doneShown(Array(1...9))), [4, 5, 6, 7, 8, 9], "offscreen: the six most recent, oldest at the top")
        XCTAssertEqual(Array(EpicSlotCard.upcomingShown(Array(1...9))), [1, 2, 3, 4, 5, 6], "offscreen: the first six to come")
    }

    // MARK: - c6: where a drag in the list to come lands

    func testADragInTheListToComeLandsInTheGapUnderThePointer() {
        XCTAssertEqual(EpicSlotCard.gap(y: 0, from: 6, count: 8), 0)
        XCTAssertEqual(EpicSlotCard.gap(y: 300, from: 0, count: 8), 8)
        XCTAssertNil(EpicSlotCard.gap(y: 40, from: 1, count: 8), "its own place")
        XCTAssertNil(EpicSlotCard.gap(y: 70, from: 1, count: 8), "its own place")
        XCTAssertEqual(EpicSlotCard.gap(y: 110, from: 1, count: 8), 3)
    }

    func testTheCardDrawsInEveryState() throws {
        let (epic, ticket) = try models()
        for (upcoming, done) in [(false, false), (true, false), (false, true), (true, true)] {
            let host = NSHostingView(
                rootView: EpicSlotCard(
                    slot: 1, epic: epic, ticket: ticket, showsUpcoming: upcoming, showsDone: done, dropTarget: true, doneHovered: true,
                    hoveredRow: 1
                )
                .frame(width: 1120)
            )
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
    }

    /// Offscreen, where `ImageRenderer` draws no scroll view, both lists still draw their rows (TP-1646's QA found the
    /// Gallery's open stories blank): the done list's band of the snapshot and the list to come's carry ink, not only
    /// the frame's surface.
    @MainActor
    func testAnOffscreenSnapshotDrawsTheRowsOfBothLists() throws {
        let (epic, ticket) = try models()
        let card = EpicSlotCard(slot: 1, epic: epic, ticket: ticket, showsUpcoming: true, showsDone: true)
            .frame(width: 1120)
            .environment(\.offscreenSnapshot, true)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let list = Int(EpicSlotCard.listHeight(rows: 6))
        let band = Int(DesignTokens.HomeQueue.epicBandHeight)
        // Rows of pixels from the top of the image (the context's memory runs top down).
        func inked(_ rows: Range<Int>) -> Int {
            var colours = Set<UInt32>()
            for y in rows where y < height {
                for x in stride(from: 8, to: width - 8, by: 2) {
                    let i = (y * width + x) * 4
                    colours.insert(UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2]))
                }
            }
            return colours.count
        }
        XCTAssertGreaterThan(inked(band + 8 ..< band + list - 8), 8, "the done rows draw above the card")
        XCTAssertGreaterThan(inked(height - list ..< height - 12), 8, "the rows to come draw below the card")
    }

    private func height(_ view: some View, width: CGFloat = 1120) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width))
        return host.fittingSize.height
    }
}
