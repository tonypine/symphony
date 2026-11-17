import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// TP-1530: the Searchable pop-up, the Save bar, the List card and the Progress meter. The keys drive the searchable
/// list's `MenuSession` as its open panel does: typing narrows it, the arrows move, Return picks and the pop-up shows
/// the pick, Escape closes and keeps the value.
@MainActor
final class FactoryComponentsTests: XCTestCase {
    private let anthropic = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
    private let openrouter = ["deepseek/deepseek-flash", "deepseek/deepseek-v4-pro", "anthropic/claude-haiku-4.5", "openai/gpt-5"]
    private var picked: [String] = []
    private var closed = 0

    private func session(_ models: [String], highlighted: Int? = 0) -> MenuSession {
        let items = models.map { model in MenuItem(model, checked: model == models.first) { self.picked.append(model) } }
        let session = MenuSession(items: items, highlighted: highlighted, search: MenuSearch(noun: "model"))
        session.onClose = { [unowned self] in self.closed += 1 }
        return session
    }

    private func type(_ text: String, in session: MenuSession) {
        for letter in text { XCTAssertTrue(session.handle(.text(String(letter)))) }
    }

    private func fittingSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    // MARK: - Searchable pop-up: the keys

    func testTypingNarrowsTheListAndLightsTheFirstChoiceLeft() {
        let session = session(openrouter)
        type("deep", in: session)
        XCTAssertEqual(session.query, "deep")
        XCTAssertEqual(session.items.map(\.title), ["deepseek/deepseek-flash", "deepseek/deepseek-v4-pro"])
        XCTAssertEqual(session.highlighted, 0)
        type("seek/deepseek-v", in: session)
        XCTAssertEqual(session.items.map(\.title), ["deepseek/deepseek-v4-pro"], "the list narrows with each letter")
        XCTAssertFalse(session.isClosed, "typing never picks")
    }

    func testTheArrowsMoveThroughWhatIsLeftAndReturnPicksIt() {
        let session = session(openrouter)
        type("deep", in: session)
        XCTAssertTrue(session.handle(.down))
        XCTAssertEqual(session.highlighted, 1)
        XCTAssertTrue(session.handle(.down))
        XCTAssertEqual(session.highlighted, 0, "Down from the last wraps to the first")
        session.handle(.up)
        XCTAssertTrue(session.handle(.pick))
        XCTAssertEqual(picked, ["deepseek/deepseek-v4-pro"])
        XCTAssertTrue(session.isClosed)
        XCTAssertEqual(closed, 1)
    }

    func testEscapeClosesWithoutPicking() {
        let session = session(anthropic)
        type("haiku", in: session)
        XCTAssertTrue(session.handle(.escape))
        XCTAssertTrue(session.isClosed)
        XCTAssertEqual(picked, [], "the value stays")
        XCTAssertEqual(closed, 1)
    }

    func testDeleteTakesALetterBackAndAnEmptyFieldBringsEveryChoiceBackOnTheTickedOne() {
        let session = session(anthropic, highlighted: 0)
        type("so", in: session)
        XCTAssertEqual(session.items.map(\.title), ["claude-sonnet-5-5"])
        XCTAssertTrue(session.handle(.deleteBackward))
        XCTAssertEqual(session.query, "s")
        XCTAssertTrue(session.handle(.deleteBackward))
        XCTAssertEqual(session.query, "")
        XCTAssertEqual(session.items.map(\.title), anthropic)
        XCTAssertEqual(session.highlighted, 0, "the ticked choice is lit again")
        XCTAssertTrue(session.handle(.deleteBackward), "Delete on an empty field does nothing but keeps the key")
        XCTAssertEqual(session.query, "")
    }

    func testNothingMatchingLeavesNoChoiceAndReturnPicksNothing() {
        let session = session(anthropic)
        type("gpt", in: session)
        XCTAssertTrue(session.items.isEmpty)
        XCTAssertNil(session.highlighted)
        XCTAssertTrue(session.handle(.pick))
        XCTAssertFalse(session.isClosed)
        XCTAssertEqual(picked, [])
    }

    func testTheSideArrowsStayInTheField() {
        let session = session(anthropic)
        XCTAssertTrue(session.handle(.left))
        XCTAssertTrue(session.handle(.right))
        XCTAssertFalse(session.isClosed)
        XCTAssertEqual(session.highlighted, 0)
    }

    func testAMenuWithoutASearchStillJumpsOnLettersAndIgnoresDelete() {
        let menu = MenuSession(items: anthropic.map { MenuItem($0) {} })
        menu.find("haiku")
        XCTAssertEqual(menu.items.count, 3, "only a searchable list narrows")
        XCTAssertTrue(menu.handle(.deleteBackward))
        XCTAssertEqual(menu.query, "")
        XCTAssertTrue(menu.handle(.text("c")))
        XCTAssertEqual(menu.highlighted, 0, "type-ahead, as before")
        XCTAssertEqual(menu.items.count, 3)
    }

    func testAClosedListTakesNoQuery() {
        let session = session(anthropic)
        session.close()
        session.find("haiku")
        XCTAssertEqual(session.query, "")
        XCTAssertEqual(session.items.count, 3)
    }

    func testSpaceAndDeleteEditTheFieldOnlyInASearchableList() {
        XCTAssertEqual(MenuPresenter.searchKey(code: 49), .text(" "))
        XCTAssertEqual(MenuPresenter.searchKey(code: 51), .deleteBackward)
        XCTAssertNil(MenuPresenter.searchKey(code: 36), "Return still picks")
        XCTAssertEqual(MenuPresenter.key(code: 49), .pick, "Space picks in a menu")
        XCTAssertNil(MenuPresenter.key(code: 51), "Delete goes on to the app from a menu")
    }

    // MARK: - Searchable pop-up: the control

    func testAPickFromTheTypedListBecomesThePopUpsValue() {
        var value = "claude-opus-5-5"
        let popUp = SearchablePopUp(
            "Model", selection: Binding(get: { value }, set: { value = $0 }), choices: anthropic.map { PopUpChoice($0, $0) }, noun: "model",
            mono: true
        )
        let menu = popUp.menu()
        XCTAssertEqual(menu.items.map(\.checked), [true, false, false], "the current value is ticked")
        XCTAssertEqual(menu.highlighted, 0, "and lit as the list opens")
        let session = MenuSession(items: menu.items, highlighted: menu.highlighted, search: MenuSearch(noun: "model"))
        type("haik", in: session)
        XCTAssertTrue(session.handle(.pick))
        XCTAssertEqual(value, "claude-haiku-5-5")
    }

    func testTheDrawnListKeepsWhatTheQueryKeepsWithTheChoiceLit() {
        let popUp = SearchablePopUp(
            "Model", selection: .constant("deepseek/deepseek-flash"), choices: openrouter.map { PopUpChoice($0, $0) }, noun: "model"
        )
        let finding = popUp.drawnList(.init(query: "deep", highlighted: "deepseek/deepseek-v4-pro"))
        XCTAssertEqual(finding.items.map(\.title), ["deepseek/deepseek-flash", "deepseek/deepseek-v4-pro"])
        XCTAssertEqual(finding.highlighted, 1)
        XCTAssertEqual(finding.items.first?.checked, true)
        let none = popUp.drawnList(.init(query: "zzz"))
        XCTAssertTrue(none.items.isEmpty)
        XCTAssertNil(none.highlighted)
    }

    func testTheOpenListIsItsFieldOverItsChoicesAndCutsALongOne() {
        let list = DesignTokens.SearchableList.self
        let items = anthropic.map { MenuItem($0, checked: false) {} }
        let size = fittingSize(MenuList(items: items, search: MenuSearch(noun: "model")))
        XCTAssertEqual(size.width, list.width, accuracy: 0.5)
        XCTAssertEqual(size.height, list.choicesTop + 3 * DesignTokens.Menu.itemHeight + list.padding, accuracy: 0.5)
        let long = (1...12).map { MenuItem("model-\($0)", checked: false) {} }
        XCTAssertEqual(MenuList(items: long, search: MenuSearch(noun: "model")).scrollHeight, list.listHeight)
        XCTAssertNil(MenuList(items: items, search: MenuSearch(noun: "model")).scrollHeight)
        let cut = fittingSize(MenuList(items: long, highlighted: 11, search: MenuSearch(noun: "model")))
        XCTAssertEqual(cut.height, list.choicesTop + list.listHeight + list.padding, accuracy: 0.5)
        let nothing = fittingSize(MenuList(items: [], search: MenuSearch(noun: "model"), query: "gpt"))
        XCTAssertEqual(nothing.width, list.width, accuracy: 0.5)
        XCTAssertGreaterThan(nothing.height, list.choicesTop + list.padding, "one line says nothing matches")
    }

    func testVoiceOverFindsTheChoicesUnderTheFieldAndFollowsTheNarrowing() throws {
        let session = session(anthropic)
        let room = MenuPresenter.shadowRoom
        let list = MenuSessionList(session: session, minWidth: DesignTokens.Menu.minWidth)
        let host = MenuHostingView(rootView: AnyView(list.padding(room)), session: session, label: "Model")
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let elements = try XCTUnwrap(host.accessibilityChildren() as? [MenuItemElement])
        XCTAssertEqual(elements.map { $0.accessibilityLabel() ?? "" }, ["claude-opus-5-5, checked", "claude-sonnet-5-5", "claude-haiku-5-5"])
        XCTAssertEqual(
            Double(elements[0].accessibilityFrame().maxY), Double(host.bounds.height - room) - DesignTokens.SearchableList.choicesTop,
            accuracy: 0.5, "the first choice is under the field"
        )
        type("haiku", in: session)
        let narrowed = try XCTUnwrap(host.accessibilityChildren() as? [MenuItemElement])
        XCTAssertEqual(narrowed.map { $0.accessibilityLabel() ?? "" }, ["claude-haiku-5-5"])
        XCTAssertTrue(narrowed[0].accessibilityPerformPress())
        XCTAssertEqual(picked, ["claude-haiku-5-5"])
    }

    func testThePopUpsFaceIsTheSmallControlInEveryFormAndDrawnOpenShowsItsList() {
        let small = DesignTokens.Control.small.height
        let face = MenuControlFace(.popUp(label: "Model", value: "claude-opus-5-5"), size: .small, monoValue: true, inheritedValue: true, reduceMotion: true)
        XCTAssertEqual(fittingSize(face).height, small, accuracy: 0.5)
        let choices = anthropic.map { PopUpChoice($0, $0) }
        let closed = fittingSize(SearchablePopUp("Model", selection: .constant("claude-opus-5-5"), choices: choices, noun: "model", mono: true))
        XCTAssertEqual(closed.height, small, accuracy: 0.5)
        let open = fittingSize(
            SearchablePopUp("Model", selection: .constant("claude-opus-5-5"), choices: choices, noun: "model", drawnOpen: .init())
        )
        let list = DesignTokens.SearchableList.self
        XCTAssertEqual(open.height, small + DesignTokens.Menu.gap + list.choicesTop + 3 * DesignTokens.Menu.itemHeight + list.padding, accuracy: 0.5)
    }

    // MARK: - Save bar

    func testRevertAndSaveCallBackAndSaveIsOffWithNothingToSaveOrWhileSaving() {
        var reverted = 0
        var saved = 0
        let bar = SaveBar(changes: 2, onRevert: { reverted += 1 }, onSave: { saved += 1 })
        XCTAssertTrue(bar.canSave)
        XCTAssertTrue(bar.showsRevert)
        bar.onRevert()
        bar.onSave()
        XCTAssertEqual(reverted, 1)
        XCTAssertEqual(saved, 1)
        XCTAssertFalse(SaveBar(changes: 0, onRevert: {}, onSave: {}).canSave, "Save is off while nothing has changed")
        XCTAssertFalse(SaveBar(changes: 0, onRevert: {}, onSave: {}).showsRevert)
        let saving = SaveBar(changes: 2, state: .saving, onRevert: {}, onSave: {})
        XCTAssertFalse(saving.canSave)
        XCTAssertFalse(saving.showsRevert)
        let refused = SaveBar(changes: 2, state: .refused("runs.qa resolves no model"), onRevert: {}, onSave: {})
        XCTAssertTrue(refused.canSave, "a refused save keeps its changes, to fix and save again")
        XCTAssertTrue(refused.showsRevert)
        XCTAssertEqual(SaveBar(changes: -1, onRevert: {}, onSave: {}).changes, 0)
    }

    func testTheBarIsASmallControlTallInEveryState() {
        let height = DesignTokens.Control.small.height + 2 * DesignTokens.SaveBar.verticalPadding
        let states: [(Int, SaveBarState)] = [(0, .editing), (2, .editing), (2, .saving), (0, .saved), (2, .refused("runs.qa resolves no model"))]
        for (changes, state) in states {
            let bar = SaveBar(changes: changes, state: state, onRevert: {}, onSave: {}) {
                PopUp("For", selection: .constant("All repositories"), choices: [PopUpChoice("All repositories", "All repositories")], size: .small)
            }
            XCTAssertEqual(fittingSize(bar.frame(width: 900)).height, height, accuracy: 0.5, "\(state)")
        }
    }

    // MARK: - List card

    func testTheCardSaysItsNameItsFactAndWhereItStands() {
        let card = ListCardContent(title: "Anthropic", fact: "62 % of the week", status: .done, statusLine: "3 working", live: true)
        XCTAssertEqual(card.spoken, "Anthropic, 62 % of the week, 3 working")
        let noFact = ListCardContent(title: "OpenAI", fact: "", status: .idle, statusLine: "Not in use")
        XCTAssertNil(noFact.shownFact, "an empty fact is not drawn")
        XCTAssertEqual(noFact.spoken, "OpenAI, Not in use")
        var pressed = 0
        let live = ListCard(card, selected: true) { pressed += 1 }
        live.action()
        XCTAssertEqual(pressed, 1)
    }

    func testEveryStateOfTheCardIsTheSameSize() {
        let card = ListCardContent(title: "Anthropic", fact: "62 % of the week", status: .done, statusLine: "3 working")
        let rest = fittingSize(ListCardFace(card, reduceMotion: true).frame(width: 340))
        XCTAssertEqual(rest.width, 340, accuracy: 0.5)
        for state in [DesignTokens.Interaction.hover, .selection, .focus] {
            for focused in [true, false] {
                let size = fittingSize(ListCardFace(card, state: state, windowFocused: focused, reduceMotion: true).frame(width: 340))
                XCTAssertEqual(size.height, rest.height, accuracy: 0.5, "\(state) never moves the list")
            }
        }
        XCTAssertEqual(fittingSize(StatusDot(.done, diameter: DesignTokens.ListCard.dot)).width, 7, accuracy: 0.5)
    }

    // MARK: - Progress meter

    func testTheOneLineFormDrawsTheShareAndAStopMarkOnlyWhenOneIsGiven() {
        let marked = ProgressMeter(line: "Week", percent: 62, stop: 90, resets: "Thu 19 Nov, 14:00")
        XCTAssertEqual(marked.percent, 62)
        XCTAssertEqual(marked.stop, 90)
        XCTAssertEqual(marked.level, .calm)
        XCTAssertEqual(marked.spoken, "Week, 62 percent")
        XCTAssertNil(ProgressMeter(line: "Week", percent: 62).stop, "no stop mark when none is given")
        XCTAssertNil(ProgressMeter(line: "Week", percent: 62, stop: 0).stop)
        XCTAssertEqual(ProgressMeter(line: "Week", percent: 90, stop: 90).level, .near)
        XCTAssertEqual(ProgressMeter(line: "Week", percent: 100, stop: 90).level, .atCap)
        XCTAssertEqual(ProgressMeter(line: "Week", percent: 130).percent, 100)
    }

    /// The pixels of a view drawn offscreen at 1x, as RGBA rows.
    private func pixels(_ view: some View, size: CGSize) -> (width: Int, height: Int, bytes: [UInt8]) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return (0, 0, []) }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (width, height, bytes)
    }

    func testTheStopMarkChangesOnlyItsOwnColumnsAndTheTrackKeepsItsHeight() {
        // The catalog's track is 6 pt with or without a stop mark: the tick alone reaches past it. Drawn with and
        // without a mark, the two meters differ only in the tick's few columns, never along the track or its fill.
        let size = CGSize(width: 640, height: 40)
        let plain = pixels(ProgressMeter(line: "Week", percent: 62), size: size)
        let marked = pixels(ProgressMeter(line: "Week", percent: 62, stop: 90), size: size)
        XCTAssertGreaterThan(plain.width, 0)
        XCTAssertEqual(plain.width, marked.width)
        XCTAssertEqual(plain.height, marked.height)
        var columns = Set<Int>()
        for y in 0 ..< plain.height {
            for x in 0 ..< plain.width {
                let index = (y * plain.width + x) * 4
                if plain.bytes[index ..< index + 4] != marked.bytes[index ..< index + 4] { columns.insert(x) }
            }
        }
        XCTAssertFalse(columns.isEmpty, "the stop mark is drawn")
        let span = (columns.max() ?? 0) - (columns.min() ?? 0) + 1
        XCTAssertLessThanOrEqual(CGFloat(span), DesignTokens.ProgressMeter.stopWidth + 2, "only the tick's columns change")
    }

    func testTheFullFormIsTheCatalogsWidthAndReadsItsShare() {
        let reading = ProgressMeterReading(label: "Tokens today", used: 4_100_000, cap: 5_000_000, resets: "at midnight")
        let meter = ProgressMeter(reading)
        XCTAssertEqual(meter.percent, 82)
        XCTAssertEqual(meter.level, .near)
        XCTAssertNil(meter.stop, "the full form has no stop mark")
        XCTAssertEqual(meter.spoken, "Tokens today, 82 percent")
        XCTAssertEqual(fittingSize(meter).width, DesignTokens.ProgressMeter.width, accuracy: 0.5)
        let line = fittingSize(ProgressMeter(line: "Week", percent: 62, stop: 90, resets: "Thu 19 Nov, 14:00").frame(width: 640))
        XCTAssertEqual(line.width, 640, accuracy: 0.5)
    }
}
