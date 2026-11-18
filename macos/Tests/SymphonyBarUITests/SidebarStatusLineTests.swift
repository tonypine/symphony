import AppKit
import SwiftUI
import SymphonyBarCore
import XCTest
@testable import SymphonyBarUI

/// The window's sidebar and status line (TP-1498), as shared components: their sizes in each form, and what they say.
@MainActor
final class SidebarStatusLineTests: XCTestCase {
    private enum Place: Hashable { case home, journal, work, setup }

    private let entries: [SidebarEntry<Place>] = [
        SidebarEntry(id: .home, title: "Home", symbol: "house", help: "Home (⌘1)", count: 2, countRole: .you, spoken: "2 waiting"),
        SidebarEntry(id: .journal, title: "Journal", symbol: "book.pages"),
        SidebarEntry(id: .work, title: "Work", symbol: "square.grid.2x2"),
        SidebarEntry(id: .setup, title: "Setup", symbol: "wrench", child: true),
    ]

    private func size(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view.environment(\.offscreenSnapshot, true))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    func testTheSidebarIs232PointsAndFoldsTo60() {
        XCTAssertEqual(size(Sidebar(entries, current: .work) { _ in }.frame(height: 300)).width, 232, accuracy: 0.5)
        XCTAssertEqual(size(Sidebar(entries, current: .work, collapsed: true) { _ in }.frame(height: 300)).width, 60, accuracy: 0.5)
    }

    func testAnEntryWithoutHelpIsHelpedByItsName() {
        XCTAssertEqual(entries[1].help, "Journal")
        XCTAssertEqual(entries[0].help, "Home (⌘1)")
        XCTAssertFalse(entries[0].child)
        XCTAssertTrue(entries[3].child)
    }

    func testTheSidebarAnnouncesTheCurrentDestination() {
        XCTAssertEqual(SidebarText.label, "Destinations")
        XCTAssertEqual(SidebarText.value(current: "Work"), "Work, current")
        XCTAssertEqual(SidebarText.value(current: nil), "")
    }

    func testTheSidebarDrawsInEveryForm() {
        for collapsed in [false, true] {
            for active in [false, true] {
                let image = ImageRenderer(
                    content: Sidebar(entries, current: .work, collapsed: collapsed, windowActive: active, drawn: [.journal: .hover]) { _ in }
                        .frame(height: 300)
                        .environment(\.offscreenSnapshot, true)
                ).nsImage
                XCTAssertNotNil(image, "collapsed \(collapsed), window in front \(active)")
            }
        }
    }

    // The catalog's `:focus-visible`: the ring shows for focus the keyboard moved, never for the focus the window hands
    // its first row on opening, nor after a click, nor while the window is not in front.
    func testOnlyAKeyPressMakesTheFocusVisible() throws {
        let key = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
        ))
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0
        ))
        XCTAssertTrue(FocusOrigin.byKeyboard(key))
        XCTAssertFalse(FocusOrigin.byKeyboard(click))
        XCTAssertFalse(FocusOrigin.byKeyboard(nil), "the focus a window hands on opening")
    }

    // QA (TP-1498): the arrow keys and Tab moved the focus through the rows but no ring showed, because the key press
    // was read when the focus change reached the view, after it stopped being the app's current event. The input in
    // use is now followed from the events themselves: a key press turns the ring on, a click turns it off.
    func testTheKeyboardIsInUseFromAKeyPressUntilAClick() throws {
        func key(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            ))
        }
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0
            ))
        }
        let down = try key(String(UnicodeScalar(NSDownArrowFunctionKey)!), 125)
        let shortcut = try key("2", 19, .command)

        let modality = InputModality()
        XCTAssertFalse(modality.keyboard, "the focus a window hands on opening")
        modality.receive(shortcut)
        XCTAssertFalse(modality.keyboard, "a shortcut picks, it does not move the focus")
        modality.receive(down)
        XCTAssertTrue(modality.keyboard)
        modality.receive(try mouse(.leftMouseUp))
        XCTAssertTrue(modality.keyboard, "only a press ends it")
        modality.receive(shortcut)
        XCTAssertTrue(modality.keyboard)
        modality.receive(try mouse(.leftMouseDown))
        XCTAssertFalse(modality.keyboard, "after a click")
        modality.receive(try key("\t", 48))
        XCTAssertTrue(modality.keyboard)
        modality.receive(try mouse(.rightMouseDown))
        XCTAssertFalse(modality.keyboard)
        modality.receive(down)
        modality.receive(try mouse(.otherMouseDown))
        XCTAssertFalse(modality.keyboard)
    }

    func testARowDrawsTheRingOnlyForTheKeyboardsFocusInAWindowInFront() {
        XCTAssertTrue(Sidebar<Place>.showsRing(true, byKeyboard: true, windowActive: true))
        XCTAssertFalse(Sidebar<Place>.showsRing(true, byKeyboard: false, windowActive: true), "after a click")
        XCTAssertFalse(Sidebar<Place>.showsRing(true, byKeyboard: true, windowActive: false), "window behind")
        XCTAssertFalse(Sidebar<Place>.showsRing(false, byKeyboard: true, windowActive: true))
    }

    func testTheStatusLineIs30PointsTall() throws {
        let build = DiagnosticsPayload.Build(version: "0.0.1.926", sha: "a0be0aa")
        let control = DispatchControl(window: .connected, paused: true, state: nil, now: Date())
        let line = HealthLine(
            window: .connected, dispatch: control, build: build, appVersion: "",
            lastUpdate: nil, counts: HealthLine.Counts(inProgress: 7, queued: 18, needYou: 2)
        )
        let drawn = size(StatusLine(line) { DispatchStatusControl(control, open: true) {} }.frame(width: 968))
        XCTAssertEqual(drawn.height, 30, accuracy: 0.5)
        let image = ImageRenderer(
            content: StatusLine(line) { DispatchStatusControl(control, drawnAs: .hover) {} }
                .frame(width: 968)
                .environment(\.offscreenSnapshot, true)
        ).nsImage
        XCTAssertNotNil(image)
    }
}
