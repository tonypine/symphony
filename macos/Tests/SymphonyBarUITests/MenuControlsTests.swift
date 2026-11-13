import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// TP-1508: the Segmented control, the Pop-up and the Menu button, and the menu the app draws for them. The keys and
/// the pointer drive `MenuSession` as the open menu does; the faces are their control height; the open menu reads as
/// a menu of menu items.
@MainActor
final class MenuControlsTests: XCTestCase {
    private var picked: [String] = []
    private var closed = 0

    /// The catalog's Menu button story: Todo, In Progress, Rework, a separator, Backlog (with ⌘⌫), Canceled in red;
    /// Backlog off with its reason.
    private func moves() -> [MenuItem] {
        [
            MenuItem("Todo") { self.picked.append("Todo") },
            MenuItem("In Progress") { self.picked.append("In Progress") },
            MenuItem("Rework") { self.picked.append("Rework") },
            .separator,
            MenuItem("Backlog", shortcut: "⌘ ⌫", disabledReason: "Moves wait while a run is working.") { self.picked.append("Backlog") },
            MenuItem("Canceled", destructive: true) { self.picked.append("Canceled") },
        ]
    }

    private func session(_ items: [MenuItem], highlighted: Int? = nil) -> MenuSession {
        let session = MenuSession(items: items, highlighted: highlighted)
        session.onClose = { [unowned self] in self.closed += 1 }
        return session
    }

    // MARK: - Keys

    func testDownAndReturnPickTheNextItemAndCloseTheMenuFirst() {
        var order: [String] = []
        let session = MenuSession(items: [MenuItem("symphony") { order.append("picked symphony") }, MenuItem("web-shop") { order.append("picked web-shop") }], highlighted: 0)
        session.onClose = { order.append("closed") }
        XCTAssertTrue(session.handle(.down))
        XCTAssertEqual(session.highlighted, 1)
        XCTAssertTrue(session.handle(.pick))
        XCTAssertEqual(order, ["closed", "picked web-shop"])
        XCTAssertTrue(session.isClosed)
        XCTAssertFalse(session.handle(.down), "a closed menu answers no key")
    }

    func testTheKeysSkipTheSeparatorAndTheItemThatIsOff() {
        let session = session(moves())
        session.handle(.down)
        XCTAssertEqual(session.highlighted, 0)
        session.handle(.end)
        XCTAssertEqual(session.highlighted, 5)
        session.handle(.up)
        XCTAssertEqual(session.highlighted, 2)
        session.handle(.home)
        XCTAssertEqual(session.highlighted, 0)
        session.handle(.up)
        XCTAssertEqual(session.highlighted, 5, "Up from the top wraps to the foot")
    }

    func testTypingJumpsToAnItem() {
        let session = session(moves())
        session.handle(.text("r"), at: 10)
        XCTAssertEqual(session.highlighted, 2)
        session.handle(.text("c"), at: 20)
        XCTAssertEqual(session.highlighted, 5)
    }

    func testEscapeClosesWithoutPicking() {
        let session = session(moves(), highlighted: 1)
        XCTAssertTrue(session.handle(.escape))
        XCTAssertEqual(closed, 1)
        XCTAssertTrue(picked.isEmpty)
        session.close()
        XCTAssertEqual(closed, 1, "closing twice tells once")
    }

    func testAnItemThatIsOffCantBePickedAndAHighlightCantStartOnIt() {
        let session = session(moves(), highlighted: 4)
        XCTAssertNil(session.highlighted)
        session.pick(4)
        session.pick(3)
        XCTAssertTrue(picked.isEmpty)
        XCTAssertEqual(closed, 0)
        session.pick(5)
        XCTAssertEqual(picked, ["Canceled"])
        XCTAssertEqual(closed, 1)
    }

    func testThePointerLightsAnItemAndLeavingTheItemsPutsItOut() {
        let session = session(moves())
        session.hover(1)
        XCTAssertEqual(session.highlighted, 1)
        session.hover(4)
        XCTAssertNil(session.highlighted, "an item that is off does not light")
        session.hover(2)
        session.hover(nil)
        XCTAssertNil(session.highlighted)
    }

    func testReturnWithNothingLitDoesNothingButKeepsTheKey() {
        let session = session(moves())
        XCTAssertTrue(session.handle(.pick))
        XCTAssertTrue(session.handle(.left))
        XCTAssertTrue(session.handle(.right))
        XCTAssertEqual(closed, 0)
    }

    // MARK: - Submenus

    private func railMore() -> [MenuItem] {
        [
            .submenu("Move to…", items: [MenuItem("Todo") { self.picked.append("Todo") }, MenuItem("Rework") { self.picked.append("Rework") }]),
            MenuItem("Restart…") { self.picked.append("Restart") },
            .separator,
            MenuItem("Stop Run…", destructive: true) { self.picked.append("Stop") },
        ]
    }

    func testRightOpensASubmenuOnItsFirstItemAndLeftClosesIt() {
        let session = session(railMore(), highlighted: 0)
        var shown: [Int?] = []
        session.onSubmenu = { child, index in shown.append(child == nil ? nil : index) }
        session.handle(.right)
        XCTAssertEqual(shown, [0])
        XCTAssertEqual(session.child?.highlighted, 0)
        session.handle(.down)
        XCTAssertEqual(session.child?.highlighted, 1, "the submenu takes the keys")
        XCTAssertEqual(session.highlighted, 0)
        session.handle(.left)
        XCTAssertNil(session.child)
        XCTAssertEqual(shown, [0, nil])
        session.handle(.pick)
        XCTAssertNotNil(session.child, "Return on a submenu opens it")
        session.handle(.escape)
        XCTAssertNil(session.child, "Escape closes the submenu only")
        XCTAssertEqual(closed, 0)
    }

    func testAPickInASubmenuClosesTheWholeMenuThenRuns() {
        let session = session(railMore(), highlighted: 0)
        session.handle(.right)
        session.handle(.down)
        session.handle(.pick)
        XCTAssertEqual(picked, ["Rework"])
        XCTAssertEqual(closed, 1)
        XCTAssertTrue(session.isClosed)
        XCTAssertTrue(session.child?.isClosed ?? true)
    }

    func testHoveringASubmenuOpensItAndAnotherItemClosesIt() {
        let session = session(railMore())
        session.hover(0)
        XCTAssertNotNil(session.child)
        XCTAssertNil(session.child?.highlighted, "opened by the pointer, nothing lit in it yet")
        session.hover(nil)
        XCTAssertEqual(session.highlighted, 0, "the pointer crossing to the submenu keeps its item lit")
        session.hover(1)
        XCTAssertNil(session.child)
        XCTAssertEqual(session.highlighted, 1)
    }

    func testAnEmptySubmenuIsOff() {
        XCTAssertFalse(MenuItem.submenu("Repo", items: []).enabled)
        XCTAssertFalse(MenuItem.separator.enabled)
        XCTAssertFalse(MenuItem("Backlog", disabledReason: "No.") {}.enabled)
        XCTAssertTrue(MenuItem("Todo") {}.enabled)
        XCTAssertEqual(MenuItem("symphony", checked: true, disabledReason: "Only one repo.") {}.accessibilityText, "symphony, checked, Only one repo.")
    }

    // MARK: - The pop-up's list

    func testThePopUpsListTicksTheCurrentChoiceAndOpensOnIt() {
        var repo: String? = "symphony"
        let popUp = PopUp(
            "Repo", selection: Binding(get: { repo }, set: { repo = $0 }),
            choices: popUpChoices(all: "All repos", ["symphony", "web-shop"])
        )
        let menu = popUp.menu()
        XCTAssertEqual(menu.items.map(\.title), ["All repos", "", "symphony", "web-shop"])
        XCTAssertTrue(menu.items[1].isSeparator)
        XCTAssertEqual(menu.items.map(\.checked), [false, nil, true, false])
        XCTAssertEqual(menu.highlighted, 2)
        // Down and Return pick the next repo.
        let session = MenuSession(items: menu.items, highlighted: menu.highlighted)
        session.handle(.down)
        session.handle(.pick)
        XCTAssertEqual(repo, "web-shop")
    }

    func testAChoiceThatIsOffSaysWhy() {
        let popUp = PopUp(
            nil, selection: .constant(InsightsUnit.day),
            choices: InsightsUnit.allCases.map { PopUpChoice($0, $0.title, disabledReason: $0 == .halfHour ? InsightsSlice.tooManyBars : nil) }
        )
        let items = popUp.menu().items
        XCTAssertEqual(items.first?.disabledReason, InsightsSlice.tooManyBars)
        XCTAssertFalse(items[0].enabled)
    }

    // MARK: - Faces

    private func fittingSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    func testEveryFaceIsItsControlHeight() {
        for size in DesignTokens.Control.allCases {
            XCTAssertEqual(fittingSize(SegmentedFace(titles: ["Day", "Week", "Month"], selected: 1, size: size, reduceMotion: true)).height, size.height, accuracy: 0.5, "\(size)")
            XCTAssertEqual(fittingSize(MenuControlFace(.menu(title: "Move to…", glyph: nil), size: size, reduceMotion: true)).height, size.height, accuracy: 0.5)
            XCTAssertEqual(fittingSize(MenuControlFace(.popUp(label: "Repo", value: "All repos"), size: size, reduceMotion: true)).height, size.height, accuracy: 0.5)
        }
    }

    func testTheSegmentsShareTheWidthEqually() {
        let three = fittingSize(SegmentedFace(titles: ["Day", "Week", "Month"], selected: 0, reduceMotion: true)).width
        let longWord = fittingSize(SegmentedFace(titles: ["Day", "Day", "Month"], selected: 0, reduceMotion: true)).width
        XCTAssertEqual(three, longWord, accuracy: 0.5, "each segment is as wide as the widest")
    }

    func testTheOpenMenuIsAsTallAsItsItemsSaySoVoiceOverFindsThem() {
        let items = moves()
        let size = fittingSize(MenuList(items: items))
        XCTAssertEqual(size.height, MenuNavigation.height(of: items.map(\.line)), accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(size.width, DesignTokens.Menu.minWidth)
    }

    func testAMenuButtonDrawnOpenShowsItsMenuUnderIt() {
        let closed = fittingSize(MenuButton("Move to…") { self.moves() })
        let open = fittingSize(MenuButton("Move to…", drawnOpen: true) { self.moves() })
        XCTAssertEqual(closed.height, DesignTokens.Control.medium.height, accuracy: 0.5)
        XCTAssertEqual(open.height, closed.height + DesignTokens.Menu.gap + MenuNavigation.height(of: moves().map(\.line)), accuracy: 0.5)
    }

    // MARK: - VoiceOver and the keyboard

    func testTheOpenMenuIsAMenuOfMenuItemsThatAPressPicks() throws {
        let session = session(moves())
        let host = MenuHostingView(rootView: AnyView(MenuList(items: session.items).padding(MenuPresenter.shadowRoom)), session: session, label: "Move to…")
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        XCTAssertEqual(host.accessibilityRole(), .menu)
        XCTAssertEqual(host.accessibilityLabel(), "Move to…")
        let elements = try XCTUnwrap(host.accessibilityChildren() as? [MenuItemElement])
        XCTAssertEqual(elements.map { $0.accessibilityRole() }, Array(repeating: .menuItem, count: 5), "no element for the separator")
        XCTAssertEqual(elements.map { $0.accessibilityLabel() ?? "" }, ["Todo", "In Progress", "Rework", "Backlog, Moves wait while a run is working.", "Canceled"])
        XCTAssertEqual(elements.map { $0.isAccessibilityEnabled() }, [true, true, true, false, true])
        XCTAssertEqual(elements[1].accessibilityFrameInParentSpace().height, DesignTokens.Menu.itemHeight)
        XCTAssertTrue(elements[2].accessibilityPerformPress())
        XCTAssertEqual(picked, ["Rework"])
        host.announce(1)
        XCTAssertTrue(elements[1].isAccessibilitySelected())
        XCTAssertFalse(elements[0].isAccessibilitySelected())
    }

    func testTheControlIsAPopUpButtonToVoiceOverThatAPressOpens() {
        var pressed = 0
        let view = MenuAnchorView()
        XCTAssertFalse(view.isAccessibilityElement(), "no element until it knows what it is")
        view.access = MenuAnchorAccess(
            role: .popUpButton, label: "Repo", value: "All repos", help: nil, enabled: true, expanded: false, press: { pressed += 1 }
        )
        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .popUpButton)
        XCTAssertEqual(view.accessibilityLabel(), "Repo")
        XCTAssertEqual(view.accessibilityValue() as? String, "All repos")
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertTrue(view.accessibilityPerformShowMenu())
        XCTAssertEqual(pressed, 2)
        XCTAssertNil(view.hitTest(.zero), "clicks go to the face")
        view.access?.enabled = false
        view.access?.help = "Only one repo is set up."
        XCTAssertFalse(view.accessibilityPerformPress())
        XCTAssertFalse(view.isAccessibilityEnabled())
        XCTAssertEqual(view.accessibilityHelp(), "Only one repo is set up.")
        XCTAssertEqual(pressed, 2)
    }

    func testTheMenuKeysAreTheArrowsReturnSpaceAndEscape() {
        XCTAssertEqual(MenuPresenter.key(code: 126), .up)
        XCTAssertEqual(MenuPresenter.key(code: 125), .down)
        XCTAssertEqual(MenuPresenter.key(code: 123), .left)
        XCTAssertEqual(MenuPresenter.key(code: 124), .right)
        XCTAssertEqual(MenuPresenter.key(code: 36), .pick)
        XCTAssertEqual(MenuPresenter.key(code: 76), .pick)
        XCTAssertEqual(MenuPresenter.key(code: 49), .pick)
        XCTAssertEqual(MenuPresenter.key(code: 53), .escape)
        XCTAssertEqual(MenuPresenter.key(code: 115), .home)
        XCTAssertEqual(MenuPresenter.key(code: 119), .end)
        XCTAssertNil(MenuPresenter.key(code: 0), "a letter is typed, not a key")
    }
}
