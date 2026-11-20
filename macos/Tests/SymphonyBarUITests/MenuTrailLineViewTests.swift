import AppKit
import SymphonyBarCore
import XCTest
@testable import SymphonyBarUI

/// The menu line with a trailing text (TP-1536): its state ends at the menu's right edge at any width.
final class MenuTrailLineViewTests: XCTestCase {
    private let dot = NSImage(size: NSSize(width: 8, height: 8))
    private let edge = DesignTokens.Menu.padding + DesignTokens.Menu.itemInset

    func testTheTrailEndsAtTheTrailingInsetWhateverTheMenusWidth() {
        for (trail, width) in [("1 working", 260.0), ("Limit reached · until Wed 18:05", 399.0), ("Paused by you · 43 days", 520.0)] {
            let bounds = NSRect(x: 0, y: 0, width: width, height: 24)
            let layout = MenuTrailLineView.layout(in: bounds, title: "Resume Anthropic", trail: trail, image: dot)
            XCTAssertEqual(layout.trail.maxX, width - edge, "\(trail) at \(width) pt")
            XCTAssertGreaterThan(layout.trail.width, 0)
            XCTAssertLessThanOrEqual(layout.title.maxX + DesignTokens.Menu.hintGap, layout.trail.minX)
        }
    }

    func testTheImageAndTitleStartAtTheLeadingInset() {
        let bounds = NSRect(x: 0, y: 0, width: 300, height: 24)
        let layout = MenuTrailLineView.layout(in: bounds, title: "Pause Anthropic", trail: "2 working", image: dot)
        XCTAssertEqual(layout.image.minX, edge)
        XCTAssertEqual(layout.image.midY, bounds.midY)
        XCTAssertEqual(layout.title.minX, edge + dot.size.width + DesignTokens.Menu.itemGap)
        XCTAssertEqual(layout.highlight, bounds.insetBy(dx: DesignTokens.Menu.padding, dy: 0))

        let plain = MenuTrailLineView.layout(in: bounds, title: "Pause Anthropic", trail: "2 working", image: nil)
        XCTAssertEqual(plain.title.minX, edge)
        XCTAssertEqual(plain.image.width, 0)
    }

    func testTheTitleGivesWayToTheTrailWhenTheLineIsNarrow() {
        let bounds = NSRect(x: 0, y: 0, width: 120, height: 24)
        let layout = MenuTrailLineView.layout(in: bounds, title: "Resume Anthropic", trail: "Limit reached · until Wed 18:05", image: dot)
        XCTAssertEqual(layout.trail.maxX, 120 - edge)
        XCTAssertEqual(layout.title.width, 0)
    }

    func testItStartsAtItsNaturalWidthAndStretchesWithTheMenu() {
        let view = MenuTrailLineView(title: "Pause Anthropic", trail: "2 working", image: dot, accessibilityLabel: "x") {}
        let natural = MenuTrailLineView.naturalWidth(title: "Pause Anthropic", trail: "2 working", image: dot)
        XCTAssertEqual(view.frame.width, natural)
        XCTAssertGreaterThan(natural, MenuTrailLineView.naturalWidth(title: "Pause Anthropic", trail: "2 working", image: nil))
        XCTAssertEqual(view.frame.height, MenuTrailLineView.rowHeight)
        XCTAssertGreaterThan(MenuTrailLineView.rowHeight, 0)
        XCTAssertTrue(view.autoresizingMask.contains(.width))
        let layout = MenuTrailLineView.layout(in: view.bounds, title: view.title, trail: view.trail, image: view.image)
        XCTAssertEqual(layout.title.maxX + DesignTokens.Menu.hintGap, layout.trail.minX, accuracy: 1)
    }

    func testAClickOrVoiceOversPressChoosesTheLine() throws {
        var chosen = 0
        let view = MenuTrailLineView(title: "Resume Anthropic", trail: "Paused by you", image: dot, accessibilityLabel: "Resume Anthropic, paused by you") {
            chosen += 1
        }
        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .menuItem)
        XCTAssertEqual(view.accessibilityLabel(), "Resume Anthropic, paused by you")
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertEqual(chosen, 1)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0
        ))
        view.mouseUp(with: event)
        XCTAssertEqual(chosen, 2)
    }

    func testItDrawsPlainAndHighlightedWithoutAWindow() throws {
        let item = NSMenuItem(title: "Resume Anthropic", action: nil, keyEquivalent: "")
        let view = MenuTrailLineView(title: "Resume Anthropic", trail: "Paused by you", image: dot, accessibilityLabel: "x") {}
        item.view = view
        XCTAssertFalse(view.isHighlighted)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
    }
}
