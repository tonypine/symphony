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
