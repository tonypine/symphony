import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// TP-1647: on Home a ticket's title is the way into its page, on the slot cards, the epic slot card's band and every
/// row. Under the pointer the title shows the pointing hand and is underlined in its own colour; at rest it is drawn as
/// before. The clicks themselves, with the mouse on the window, are the window test's (`macos/Tests/home-drag-test.py`,
/// its `title-` scenarios); here the pointer, the underline and which ticket each title opens.
@MainActor
final class HomeTitleLinkTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    /// A ticket waiting on the person: its dot does not pulse, so two drawings of it match pixel for pixel.
    private let ticket = SlotCardModel(
        identifier: "TP-1594", title: "A QA pass walks the checks that share a screen and state in one session", status: .you, stage: 1,
        since: "48 min", word: "Waiting on you", sentence: "may a grouped step hold more than six checks?", tokens: [], tokenTotal: 0,
        tokenCap: nil, plan: "The plan of a pass groups the checks that share a screen and state.", proved: 8, checks: 9, next: nil,
        pullRequest: nil
    )

    private let row = QueueRowModel(
        number: 4, identifier: "TP-977", title: "Give agents one tool to request a protected change, and pause the ticket on it",
        lead: .glyph("clock", .textSecondary), repo: "symphony"
    )

    private let done = DoneRowModel(
        identifier: "TP-1622", title: "Engine: the queue's order is stored as one sort key per ticket", epic: "TP-1597", pullRequest: "#1053",
        repo: "symphony", when: "20 min ago"
    )

    /// A view drawn offscreen at 1x, `size` big, as RGBA rows from the top.
    private func pixels(_ view: some View, size: CGSize) throws -> [UInt8] {
        let renderer = ImageRenderer(
            content: view.frame(width: size.width, height: size.height, alignment: .topLeading)
                .environment(\.offscreenSnapshot, true)
                .environment(\.colorScheme, .light)
        )
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    /// The rows of pixels (from the top) where two drawings `width` wide differ: where at least `pixels` pixels of the
    /// row differ by more than `tolerance` in a channel. An underline changes a whole run of the row at full strength;
    /// an offscreen drawing made under load can shift the anti-aliasing of a few edge pixels here and there by a little,
    /// which is not a change of the drawing (TP-1647: the tests step once saw such pixels on 14 scattered rows).
    private func differingRows(_ one: [UInt8], _ two: [UInt8], width: Int, tolerance: Int = 48, pixels: Int = 6) -> Set<Int> {
        var counts: [Int: Int] = [:]
        for index in stride(from: 0, to: min(one.count, two.count), by: 4)
        where (0..<4).contains(where: { abs(Int(one[index + $0]) - Int(two[index + $0])) > tolerance }) {
            counts[index / 4 / width, default: 0] += 1
        }
        return Set(counts.filter { $0.value >= pixels }.keys)
    }

    // MARK: - c5: the pointing hand; the underline only under the pointer

    func testTheTitleShowsThePointingHandAndIsUnderlinedOnlyUnderThePointer() {
        XCTAssertTrue(TitleLink.hand, "the pointer over a title is the pointing hand")
        XCTAssertNotNil(TitleLink.pointer, "the title sets the pointing hand, as a control that can be pressed does")
        XCTAssertTrue(TitleLink.underlined(hovered: true))
        XCTAssertFalse(TitleLink.underlined(hovered: false), "at rest the title is drawn as before, with no underline")
        XCTAssertEqual(TitleLink.actionTitle("TP-1619"), "Open TP-1619")
    }

    /// Every title on Home is a title link, so each shows the hand and the underline the same way: the slot card's and
    /// the strip line's, a queue row's (queue rows, sub-ticket rows and the rows to come under an epic slot card), a
    /// done row's (Recently done, an epic slot card's done list, a queue epic's block) and the epic's in the band.
    func testEveryTitleOnHomeIsATitleLinkOpeningItsOwnTicket() throws {
        let slotCard = try source("macos/Sources/SymphonyBarUI/DesignSystem/SlotCard.swift")
        XCTAssertEqual(slotCard.components(separatedBy: ".titleLink(ticket.identifier, hovered: titleHovered, open: onOpen)").count - 1, 2, "the card and the strip line")
        let queueRow = try source("macos/Sources/SymphonyBarUI/DesignSystem/QueueRow.swift")
        XCTAssertTrue(queueRow.contains(".titleLink(row.identifier, hovered: titleHovered, open: onOpen)"))
        let doneRow = try source("macos/Sources/SymphonyBarUI/DesignSystem/DoneRow.swift")
        XCTAssertTrue(doneRow.contains(".titleLink(row.identifier, hovered: titleHovered, open: onOpen)"))
        let epicCard = try source("macos/Sources/SymphonyBarUI/DesignSystem/EpicSlotCard.swift")
        XCTAssertTrue(epicCard.contains(".titleLink(epic.identifier, open: onOpen)"), "the epic's title in the band opens the epic")
        XCTAssertTrue(epicCard.contains("inEpic: true, onAction: onAction, onOpen: onOpen"), "the card in work opens its sub-ticket")
        XCTAssertEqual(epicCard.components(separatedBy: "onOpen: onOpen").count - 1, 4, "the card in work, the done rows and both lists' rows to come")
    }

    // MARK: - c1, c3: Home sends every title's click to the ticket's page

    func testHomeOpensTheTicketsPageFromEveryTitle() throws {
        let home = try source("macos/Sources/SymphonyBar/HomeView.swift")
        XCTAssertEqual(home.components(separatedBy: "onOpen: actions.openTicket").count - 1, 2, "the slot card and the epic slot card")
        XCTAssertEqual(home.components(separatedBy: "open: actions.openTicket").count - 1, 3, "the strip, Recently done and the queue")
        XCTAssertEqual(home.components(separatedBy: "onOpen: open").count - 1, 3, "the queue's rows, its done rows and the strip's lines")
        let window = try source("macos/Sources/SymphonyBar/SymphonyWindowView.swift")
        XCTAssertTrue(window.contains("openTicket: { [weak self] in self?.openTicket($0) }"), "Home's open is the ticket's page")
    }

    // MARK: - c7, c9: the hover underlines the title, and nothing else changes

    func testAHoveredTitleOnTheSlotCardIsUnderlinedAndNothingElseOnTheCardChanges() throws {
        let size = CGSize(width: 1120, height: 300)
        let rest = try pixels(SlotCard(slot: 2, ticket: ticket, onOpen: { _ in }), size: size)
        let hovered = try pixels(SlotCard(slot: 2, ticket: ticket, titleHovered: true, onOpen: { _ in }), size: size)
        let rows = differingRows(rest, hovered, width: Int(size.width))
        XCTAssertFalse(rows.isEmpty, "the hovered title draws its underline")
        let queue = DesignTokens.HomeQueue.self
        let header = Int(queue.cardTopPadding)..<Int(queue.cardTopPadding + queue.headerHeight)
        XCTAssertTrue(rows.allSatisfy { header.contains($0) }, "only the header's line changes: \(rows.sorted())")
        let link = try pixels(SlotCard(slot: 2, ticket: ticket, onOpen: { _ in }), size: size)
        let plain = try pixels(SlotCard(slot: 2, ticket: ticket), size: size)
        XCTAssertEqual(differingRows(link, plain, width: Int(size.width)), [], "at rest a clickable title looks as the title always did")
    }

    func testAHoveredTitleOnEachKindOfRowIsUnderlinedWithinTheRow() throws {
        let width = 1120
        let size = CGSize(width: CGFloat(width), height: DesignTokens.HomeQueue.rowHeight)
        let numberWidth = QueueRow.numberWidth(widest: 9)
        let views: [(String, AnyView, AnyView)] = [
            ("queue row", AnyView(QueueRow(row, numberWidth: numberWidth, look: .rest, onOpen: { _ in })),
             AnyView(QueueRow(row, numberWidth: numberWidth, look: .rest, titleHovered: true, onOpen: { _ in }))),
            ("done row", AnyView(DoneRow(done, hovered: false, onOpen: { _ in })),
             AnyView(DoneRow(done, hovered: false, titleHovered: true, onOpen: { _ in }))),
            ("quiet done row", AnyView(DoneRow(done, cells: .queue, hovered: false, nesting: .init(numberCell: numberWidth), onOpen: { _ in })),
             AnyView(DoneRow(done, cells: .queue, hovered: false, nesting: .init(numberCell: numberWidth), titleHovered: true, onOpen: { _ in }))),
            ("strip line", AnyView(SlotStripLine(slot: 1, ticket: ticket, numberWidth: numberWidth, state: .rest, onOpen: { _ in })),
             AnyView(SlotStripLine(slot: 1, ticket: ticket, numberWidth: numberWidth, state: .rest, titleHovered: true, onOpen: { _ in }))),
        ]
        for (name, rest, hovered) in views {
            let rows = differingRows(try pixels(rest, size: size), try pixels(hovered, size: size), width: width)
            XCTAssertFalse(rows.isEmpty, "the \(name)'s hovered title draws its underline")
        }
        let link = try pixels(QueueRow(row, numberWidth: numberWidth, look: .rest, onOpen: { _ in }), size: size)
        let plain = try pixels(QueueRow(row, numberWidth: numberWidth, look: .rest), size: size)
        XCTAssertEqual(differingRows(link, plain, width: width), [], "at rest a row's clickable title looks as it always did")
    }

    func testTheGalleryShowsTheSlotCardsTitleUnderThePointer() throws {
        let variations = try source("macos/Gallery/component-variations.txt").split(separator: "\n").map(String.init)
        XCTAssertTrue(variations.contains("slot-card-title-hovered"))
        XCTAssertTrue(try source("macos/Gallery/HomeQueueStories.swift").contains("titleHovered: true"))
    }
}
