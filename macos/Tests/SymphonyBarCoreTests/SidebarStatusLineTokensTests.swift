import XCTest
@testable import SymphonyBarCore

/// The window's sidebar and status line as the catalog draws them (TP-1498): `.win-side`, `.nav-row`, `.win-status` and
/// `.dispatch` in `docs/design/catalog/components.css`.
final class SidebarStatusLineTokensTests: XCTestCase {
    func testTheSidebarIsTheCatalogs() {
        let side = DesignTokens.Sidebar.self
        XCTAssertEqual(side.width, 232)
        XCTAssertEqual(side.collapsedWidth, 60)
        XCTAssertEqual(DesignTokens.Layout.sidebarWidth, 232)
        XCTAssertEqual(DesignTokens.Layout.collapsedSidebarWidth, 60)
        XCTAssertEqual(side.width(collapsed: false), 232)
        XCTAssertEqual(side.width(collapsed: true), 60)
        XCTAssertEqual(side.rowHeight, 30, "--control-md")
        XCTAssertEqual(side.rowRadius, DesignTokens.Control.medium.radius, "--radius-control-md")
        XCTAssertEqual(side.rowGap, 2)
        XCTAssertEqual(side.topInset, DesignTokens.WindowBar.height, "the window buttons' room is as tall as the bar")
        XCTAssertEqual(side.glyph, 16)
        XCTAssertEqual(side.childIndent, DesignTokens.Space.s2 + 16)
        XCTAssertEqual(side.weight, 500)
        XCTAssertEqual(side.currentWeight, 600)
        XCTAssertEqual(side.fold, .fold)
        XCTAssertEqual(side.separator, .strokeSeparator)
    }

    func testTheCurrentDestinationIsTheAccentTintInTheFrontWindowAndThePressedGreyBehind() {
        let side = DesignTokens.Sidebar.self
        XCTAssertEqual(side.fill(.rest, current: true, windowActive: true), .accentTint)
        XCTAssertEqual(side.text(current: true, child: false, hovered: false, windowActive: true), .accentText)
        XCTAssertEqual(side.glyphColor(current: true, windowActive: true), .accentText)

        XCTAssertEqual(side.fill(.rest, current: true, windowActive: false), .surfacePressed)
        XCTAssertEqual(side.text(current: true, child: false, hovered: false, windowActive: false), .textPrimary)
        XCTAssertEqual(side.glyphColor(current: true, windowActive: false), .textSecondary)
    }

    func testARowShowsHoverAndPressedAndNothingAtRest() {
        let side = DesignTokens.Sidebar.self
        XCTAssertNil(side.fill(.rest, current: false, windowActive: true))
        XCTAssertEqual(side.fill(.hover, current: false, windowActive: true), .surfaceHover)
        XCTAssertEqual(side.fill(.press, current: false, windowActive: true), .surfacePressed)
        XCTAssertEqual(side.fill(.press, current: true, windowActive: true), .surfacePressed, "a press shows on the current row too")
        XCTAssertNil(side.fill(.focus, current: false, windowActive: true), "keyboard focus is the ring, not a fill")
        XCTAssertEqual(side.text(current: false, child: false, hovered: false, windowActive: true), .textPrimary)
        XCTAssertEqual(side.text(current: false, child: true, hovered: false, windowActive: true), .textSecondary, "a page under Factory")
        XCTAssertEqual(side.text(current: false, child: true, hovered: true, windowActive: true), .textPrimary)
        XCTAssertEqual(side.glyphColor(current: false, windowActive: true), .textSecondary)
    }

    func testTheStatusLineIsTheCatalogs() {
        let line = DesignTokens.StatusLine.self
        XCTAssertEqual(line.height, 30)
        XCTAssertEqual(line.leadingPadding, DesignTokens.Space.s2)
        XCTAssertEqual(line.trailingPadding, DesignTokens.Space.s4)
        XCTAssertEqual(line.gap, DesignTokens.Space.s3)
        XCTAssertEqual(line.glass, .glass)
        XCTAssertEqual(line.separatorHeight, 16)
        XCTAssertEqual(line.build, .textTertiary)

        let dispatch = DesignTokens.StatusLine.Dispatch.self
        XCTAssertEqual(dispatch.control, .small, "--control-sm")
        XCTAssertEqual(dispatch.textSize, 12)
        XCTAssertEqual(dispatch.weight, 500)
        XCTAssertEqual(dispatch.chevron, 10)
        XCTAssertNil(dispatch.fill(.rest, open: false))
        XCTAssertEqual(dispatch.fill(.hover, open: false), .surfaceHover)
        XCTAssertEqual(dispatch.fill(.press, open: false), .surfacePressed)
        XCTAssertEqual(dispatch.fill(.rest, open: true), .surfacePressed, "pressed while its menu is open")
    }
}
