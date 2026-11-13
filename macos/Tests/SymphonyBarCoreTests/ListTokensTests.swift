import XCTest
@testable import SymphonyBarCore

/// TP-1507: the Row's states, the tree's lines and its keys, and the progress strip's segments and counts, as the
/// catalog's Row, `.t-kids`, `.q-behind` and `.epic-strip` draw them.
final class ListTokensTests: XCTestCase {
    // MARK: - Row

    func testARowIsOneLineAtThirtyFourOrTwoAtFiftyTwo() {
        XCTAssertEqual(DesignTokens.Row.height(twoLines: false), 34)
        XCTAssertEqual(DesignTokens.Row.height(twoLines: true), 52)
        // Two lines of text (18 pt and 16 pt, 2 apart) fill 52 with the row's room above and below.
        XCTAssertEqual(DesignTokens.Row.inset * 2 + 18 + DesignTokens.Row.lineGap + 16, 52)
        XCTAssertEqual(DesignTokens.Row.inset * 2 + 18, 34)
    }

    func testASelectedRowFillsWithTheAccentAndTurnsGreyWithTheWindowBehind() {
        let row = DesignTokens.Row.self
        XCTAssertNil(row.fill(.rest, windowActive: true))
        XCTAssertEqual(row.fill(.hover, windowActive: true), .surfaceHover)
        XCTAssertEqual(row.fill(.press, windowActive: true), .surfacePressed)
        XCTAssertEqual(row.fill(.selection, windowActive: true), .accent)
        XCTAssertEqual(row.fill(DesignTokens.Interaction(hovered: true, pressed: true, selected: true), windowActive: true), .accent)
        XCTAssertEqual(row.fill(.selection, windowActive: false), .surfacePressed)
        XCTAssertNil(row.fill(DesignTokens.Interaction(hovered: true, selected: true, disabled: true), windowActive: true))
        XCTAssertNil(row.fill(.focus, windowActive: true))
        XCTAssertTrue(row.onAccent(.selection, windowActive: true))
        XCTAssertFalse(row.onAccent(.selection, windowActive: false))
        XCTAssertFalse(row.onAccent(.hover, windowActive: true))
        XCTAssertFalse(row.onAccent(DesignTokens.Interaction(selected: true, disabled: true), windowActive: true))
    }

    // MARK: - Tree

    /// The catalog's queue: a chain of nine, a fork (SHOP-311 under which SHOP-312 and SHOP-313 wait, SHOP-314 under
    /// SHOP-312), a ticket alone, and a chain of three.
    static let queue: [TreeNode<String>] = {
        func chain(_ idents: [String]) -> TreeNode<String> {
            TreeNode(idents[0], children: idents.count > 1 ? [chain(Array(idents.dropFirst()))] : [])
        }
        return [
            chain(["TP-1481", "TP-1482", "TP-1483", "TP-1493", "TP-1484", "TP-1485", "TP-1486", "TP-1487", "TP-1488"]),
            TreeNode("SHOP-311", children: [TreeNode("SHOP-312", children: [TreeNode("SHOP-314")]), TreeNode("SHOP-313")]),
            TreeNode("BIL-308"),
            chain(["MOT-93", "MOT-94", "MOT-95"]),
        ]
    }()

    func testAChainPastTwoStepsFoldsIntoAPillCountingWhatItHides() {
        let lines = TreeLines.lines(Self.queue, foldDepth: 2)
        XCTAssertEqual(lines.map(\.key), [
            .row("TP-1481"), .row("TP-1482"), .row("TP-1483"), .more("TP-1483"),
            .row("SHOP-311"), .row("SHOP-312"), .row("SHOP-314"), .row("SHOP-313"),
            .row("BIL-308"),
            .row("MOT-93"), .row("MOT-94"), .row("MOT-95"),
        ])
        XCTAssertEqual(lines.map(\.depth), [0, 1, 2, 3, 0, 1, 2, 1, 0, 0, 1, 2])
        XCTAssertEqual(lines[3].hidden, 6)
        XCTAssertEqual(DesignTokens.Tree.More.text(lines[3].hidden), "+6")
        XCTAssertEqual(DesignTokens.Tree.More.help(6), "Show the 6 behind it")
        XCTAssertEqual(lines[3].root, "TP-1481")
        XCTAssertEqual(Self.queue[0].descendants, 8)
    }

    func testAnOpenedChainShowsEveryRowAndNothingFoldsWithoutAFoldDepth() {
        let opened = TreeLines.lines(Self.queue, foldDepth: 2, opened: ["TP-1481"])
        XCTAssertEqual(opened.prefix(9).map(\.depth), Array(0 ... 8))
        XCTAssertFalse(opened.contains { if case .more = $0.key { true } else { false } })
        XCTAssertEqual(TreeLines.lines(Self.queue).count, 17)
    }

    func testEachRailRunsOnWhileItsGroupDoes() {
        let lines = TreeLines.lines(Self.queue, foldDepth: 2)
        let byKey = Dictionary(uniqueKeysWithValues: lines.map { ($0.key, $0.railsContinue) })
        XCTAssertEqual(byKey[.row("SHOP-311")], [])
        XCTAssertEqual(byKey[.row("SHOP-312")], [true])
        XCTAssertEqual(byKey[.row("SHOP-314")], [true, false])
        XCTAssertEqual(byKey[.row("SHOP-313")], [false])
        XCTAssertEqual(byKey[.more("TP-1483")], [false, false, false])
        XCTAssertEqual(byKey[.row("MOT-95")], [false, false])
        // The rails sit under each level's lead glyph, one step apart, and a child's row starts after its tick.
        XCTAssertEqual(DesignTokens.Tree.railX(level: 1), 20)
        XCTAssertEqual(DesignTokens.Tree.railX(level: 2), 52)
        XCTAssertLessThan(DesignTokens.Tree.railX(level: 1) + DesignTokens.Tree.railWidth + DesignTokens.Tree.tickWidth, DesignTokens.Tree.step)
    }

    func testTheArrowKeysWalkTheLinesInOrder() {
        let lines = TreeLines.lines(Self.queue, foldDepth: 2)
        XCTAssertEqual(TreeLines.move(from: nil, by: 1, in: lines), .row("TP-1481"))
        XCTAssertEqual(TreeLines.move(from: .row("TP-1483"), by: 1, in: lines), .more("TP-1483"))
        XCTAssertEqual(TreeLines.move(from: .more("TP-1483"), by: 1, in: lines), .row("SHOP-311"))
        XCTAssertEqual(TreeLines.move(from: .row("SHOP-311"), by: -1, in: lines), .more("TP-1483"))
        XCTAssertEqual(TreeLines.move(from: .row("TP-1481"), by: -1, in: lines), .row("TP-1481"))
        XCTAssertEqual(TreeLines.move(from: .row("MOT-95"), by: 1, in: lines), .row("MOT-95"))
        XCTAssertEqual(TreeLines.move(from: .row("gone"), by: 1, in: lines), .row("TP-1481"))
        XCTAssertNil(TreeLines.move(from: nil, by: 1, in: [TreeLine<String>]()))
    }

    func testTheRightArrowOpensAFoldFromItsPillOrTheRowAboveIt() {
        let lines = TreeLines.lines(Self.queue, foldDepth: 2)
        XCTAssertEqual(TreeLines.open(.more("TP-1483"), in: lines, opened: []), ["TP-1481"])
        XCTAssertEqual(TreeLines.open(.row("TP-1483"), in: lines, opened: ["MOT-93"]), ["MOT-93", "TP-1481"])
        XCTAssertNil(TreeLines.open(.row("TP-1482"), in: lines, opened: []))
        XCTAssertNil(TreeLines.open(.row("MOT-95"), in: lines, opened: []))
        XCTAssertNil(TreeLines.open(nil, in: lines, opened: []))
        XCTAssertNil(TreeLines.open(.more("TP-1483"), in: lines, opened: ["TP-1481"]))
    }

    func testTheLeftArrowClosesAnOpenedChainAndAHiddenRowHandsTheSelectionToThePill() throws {
        let hidden = try XCTUnwrap(TreeLines.close(.row("TP-1484"), in: Self.queue, foldDepth: 2, opened: ["TP-1481"]))
        XCTAssertEqual(hidden.opened, [])
        XCTAssertEqual(hidden.selection, .more("TP-1483"))
        let shown = try XCTUnwrap(TreeLines.close(.row("TP-1482"), in: Self.queue, foldDepth: 2, opened: ["TP-1481", "MOT-93"]))
        XCTAssertEqual(shown.opened, ["MOT-93"])
        XCTAssertEqual(shown.selection, .row("TP-1482"))
        XCTAssertNil(TreeLines.close(.row("TP-1482"), in: Self.queue, foldDepth: 2, opened: []))
        XCTAssertNil(TreeLines.close(nil, in: Self.queue, foldDepth: 2, opened: ["TP-1481"]))
    }

    func testTheLeftArrowOnAHiddenRowHandsTheSelectionToThePillOfItsOwnBranch() throws {
        let tree = [TreeNode("R", children: [TreeNode("A", children: [
            TreeNode("B", children: [TreeNode("B1")]), TreeNode("C", children: [TreeNode("C1", children: [TreeNode("C2")])]),
        ])])]
        let folded = TreeLines.lines(tree, foldDepth: 2).map(\.key)
        XCTAssertEqual(folded, [.row("R"), .row("A"), .row("B"), .more("B"), .row("C"), .more("C")])
        let fromC1 = try XCTUnwrap(TreeLines.close(.row("C1"), in: tree, foldDepth: 2, opened: ["R"]))
        XCTAssertEqual(fromC1.opened, [])
        XCTAssertEqual(fromC1.selection, .more("C"))
        XCTAssertEqual(try XCTUnwrap(TreeLines.close(.row("C2"), in: tree, foldDepth: 2, opened: ["R"])).selection, .more("C"))
        XCTAssertEqual(try XCTUnwrap(TreeLines.close(.row("B1"), in: tree, foldDepth: 2, opened: ["R"])).selection, .more("B"))
    }

    // MARK: - Progress strip

    func testUpToThirtyItemsDrawOneSegmentEachInOrder() {
        let items: [DesignTokens.ProgressStrip.Item] = [.init(.done), .init(.working, live: true), .init(.you), .init(nil)]
        XCTAssertEqual(DesignTokens.ProgressStrip.segments(items).map(\.status), [.done, .working, .you, nil])
        XCTAssertEqual(DesignTokens.ProgressStrip.segments(items).map(\.live), [false, true, false, false])
        XCTAssertEqual(DesignTokens.ProgressStrip.segments(items).map(\.weight), [1, 1, 1, 1])
        let thirty = Array(repeating: DesignTokens.ProgressStrip.Item(.done), count: 30)
        XCTAssertEqual(DesignTokens.ProgressStrip.segments(thirty).count, 30)
    }

    func testPastThirtyTheStatesShareTheStripInProportion() {
        let items = Array(repeating: DesignTokens.ProgressStrip.Item(nil), count: 16) + Array(repeating: .init(.done), count: 18)
            + [.init(.working, live: true), .init(.working), .init(.problem), .init(.idle)]
        let segments = DesignTokens.ProgressStrip.segments(items)
        XCTAssertEqual(segments.map(\.status), [.done, .problem, .working, .idle, nil])
        XCTAssertEqual(segments.map(\.weight), [18, 1, 2, 1, 16])
        XCTAssertEqual(segments.map(\.live), [false, false, true, false, false])
    }

    func testEachStateHasItsStatusColourAndWaitingOnesTheRestColour() {
        XCTAssertEqual(DesignTokens.ProgressStrip.color(.done), .statusDone)
        XCTAssertEqual(DesignTokens.ProgressStrip.color(.working), .statusWorking)
        XCTAssertEqual(DesignTokens.ProgressStrip.color(.you), .statusYou)
        XCTAssertEqual(DesignTokens.ProgressStrip.color(.problem), .statusProblem)
        XCTAssertEqual(DesignTokens.ProgressStrip.color(.forced), .statusForced)
        XCTAssertEqual(DesignTokens.ProgressStrip.color(.idle), .surfacePressed)
        XCTAssertEqual(DesignTokens.ProgressStrip.color(nil), .surfacePressed)
    }

    func testTheStripSaysItsCounts() {
        let items = Array(repeating: DesignTokens.ProgressStrip.Item(.done), count: 3) + [.init(.working, live: true)]
            + Array(repeating: .init(nil), count: 21) + [.init(.idle)]
        XCTAssertEqual(DesignTokens.ProgressStrip.spoken(items), "3 done, 1 working, 22 waiting")
        XCTAssertEqual(
            DesignTokens.ProgressStrip.spoken([.init(.you), .init(.problem), .init(.forced)]),
            "1 needing a fix, 1 waiting on you, 1 forced"
        )
        XCTAssertEqual(DesignTokens.ProgressStrip.spoken([]), "Nothing yet")
    }

    func testAnEpicsSubTicketsAndAPeeksParentGiveTheirStripItems() {
        let parent = TicketPeek.Parent(text: "TP-891", done: 1, total: 3, children: [.done, .working, .idle])
        XCTAssertEqual(parent.stripItems, [.init(.done), .init(.working, live: true), .init(nil)])
    }
}
