import AppKit
import XCTest
@testable import SymphonyBarUI

/// Whether a window has a sheet over it, from AppKit's sheet notifications, without a window.
final class SheetCoverTests: XCTestCase {
    private let window = NSObject()
    private var hasSheet = false
    private var changes: [Bool] = []

    private func cover() -> SheetCover {
        let cover = SheetCover()
        cover.changed = { [unowned self] in changes.append($0) }
        cover.watch(window, hasSheet: { [unowned self] in hasSheet })
        return cover
    }

    private func post(_ name: Notification.Name, from sender: AnyObject? = nil) {
        NotificationCenter.default.post(name: name, object: sender ?? window)
    }

    func testASheetCoversTheWindowUntilItEnds() {
        let cover = cover()
        XCTAssertFalse(cover.covered)
        hasSheet = true
        post(NSWindow.willBeginSheetNotification)
        XCTAssertTrue(cover.covered)
        hasSheet = false
        post(NSWindow.didEndSheetNotification)
        XCTAssertFalse(cover.covered)
        XCTAssertEqual(changes, [true, false])
    }

    func testTheWindowStaysCoveredWhileAnotherSheetIsUp() {
        let cover = cover()
        hasSheet = true
        post(NSWindow.willBeginSheetNotification)
        post(NSWindow.didEndSheetNotification)
        XCTAssertTrue(cover.covered)
        XCTAssertEqual(changes, [true])
    }

    func testItStartsCoveredWhenTheWindowAlreadyHasASheet() {
        hasSheet = true
        XCTAssertTrue(cover().covered)
        XCTAssertEqual(changes, [true])
    }

    func testAnotherWindowsSheetLeavesItUncovered() {
        let cover = cover()
        post(NSWindow.willBeginSheetNotification, from: NSObject())
        XCTAssertFalse(cover.covered)
        XCTAssertEqual(changes, [])
    }

    func testOutOfTheWindowNothingCoversItAndItSaysNothing() {
        let cover = cover()
        XCTAssertTrue(cover.watching)
        hasSheet = true
        post(NSWindow.willBeginSheetNotification)
        cover.watch(nil, hasSheet: { true })
        XCTAssertFalse(cover.covered)
        XCTAssertFalse(cover.watching)
        post(NSWindow.willBeginSheetNotification)
        XCTAssertFalse(cover.covered, "it stopped following the old window")
        XCTAssertEqual(changes, [true], "the view that replaces it may still see the window covered")
    }

    /// TP-1462: a view that left its window under a sheet and came back once the sheet ended still held the cover it
    /// was told of, so its paragraph drew nothing live and took no hover.
    func testBackInAWindowWithNoSheetItSaysItIsUncovered() {
        let cover = cover()
        hasSheet = true
        post(NSWindow.willBeginSheetNotification)
        cover.watch(nil, hasSheet: { true })
        hasSheet = false
        cover.watch(window, hasSheet: { [unowned self] in hasSheet })
        XCTAssertFalse(cover.covered)
        XCTAssertEqual(changes, [true, false])
    }

    /// The window can still name the sheet that ended while it posts the end: the cover asks again after it.
    func testASheetTheWindowStillNamesAtItsEndIsAskedAgainAfter() {
        let cover = cover()
        hasSheet = true
        post(NSWindow.willBeginSheetNotification)
        post(NSWindow.didEndSheetNotification)
        XCTAssertTrue(cover.covered)
        hasSheet = false
        let asked = expectation(description: "asked again")
        DispatchQueue.main.async { asked.fulfill() }
        wait(for: [asked], timeout: 1)
        XCTAssertFalse(cover.covered)
        XCTAssertEqual(changes, [true, false])
    }

    func testWatchingTheSameWindowAgainChangesNothing() {
        let cover = cover()
        cover.watch(window, hasSheet: { true })
        XCTAssertFalse(cover.covered)
        hasSheet = true
        post(NSWindow.willBeginSheetNotification)
        XCTAssertEqual(changes, [true], "one observer")
    }

    func testTheViewTakesNoClicksAndIsUncoveredOutOfAWindow() {
        let view = SheetCoverView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        XCTAssertNil(view.hitTest(CGPoint(x: 10, y: 10)))
        XCTAssertFalse(view.cover.watching, "not in its window yet, it knows of no sheet")
        view.viewDidMoveToWindow()
        XCTAssertFalse(view.cover.covered)
        XCTAssertFalse(view.cover.watching)
    }
}
