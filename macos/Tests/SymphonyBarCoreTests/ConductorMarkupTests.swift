@testable import SymphonyBarCore
import XCTest

/// The Conductor's markup read into blocks and phrases: what each marker makes, what is left as written, and that no
/// word is ever dropped.
final class ConductorMarkupTests: XCTestCase {
    private func phrases(_ text: String) -> [ConductorMarkup.Phrase] {
        guard case let .paragraph(phrases)? = ConductorMarkup(text).blocks.first else {
            XCTFail("\(text) is not a paragraph")
            return []
        }
        return phrases
    }

    func testPlainTextIsItsParagraphs() {
        let markup = ConductorMarkup("The first run built the filter.\nIts tests pass.\n\nCode Review looks at the empty state.")
        XCTAssertEqual(markup.blocks, [
            .paragraph([.plain("The first run built the filter.\nIts tests pass.")]),
            .paragraph([.plain("Code Review looks at the empty state.")]),
        ])
        XCTAssertEqual(markup.roles, [.headline, .body])
        XCTAssertEqual(markup.plainText, "The first run built the filter.\nIts tests pass.\nCode Review looks at the empty state.")
    }

    func testEmptyTextHasNoBlocks() {
        XCTAssertTrue(ConductorMarkup("").isEmpty)
        XCTAssertTrue(ConductorMarkup(" \n \n").isEmpty)
    }

    func testBoldItalicCodeAndLinks() throws {
        let destination = try XCTUnwrap(URL(string: "https://example.com/a"))
        XCTAssertEqual(
            phrases("a **bold** and *italic* and `code` and [a link](https://example.com/a)."),
            [
                .plain("a "), .bold([.plain("bold")]), .plain(" and "), .italic([.plain("italic")]), .plain(" and "), .code("code"),
                .plain(" and "), .link(label: [.plain("a link")], destination: destination), .plain("."),
            ]
        )
    }

    func testMarkersNest() {
        XCTAssertEqual(phrases("**a *b* c**"), [.bold([.plain("a "), .italic([.plain("b")]), .plain(" c")])])
        XCTAssertEqual(phrases("{done}**passed**{/}"), [.status(.done, [.bold([.plain("passed")])])])
    }

    func testStatusTagsColourTheirPhrase() {
        XCTAssertEqual(
            phrases("{problem}one problem{/}, {done}the rest{/}, {you}your call{/}"),
            [
                .status(.problem, [.plain("one problem")]), .plain(", "), .status(.done, [.plain("the rest")]), .plain(", "),
                .status(.you, [.plain("your call")]),
            ]
        )
    }

    func testUnknownTagsAndUnbalancedMarkersStayAsWritten() {
        for text in [
            "{unknown}words{/}", "{problem}never closed", "stray {/} close", "**no end", "one * star", "2 * 3 * 4", "`no end", "``",
            "[label](not a url)", "[label](ftp://example.com)", "[label](javascript:alert)", "[no destination]", "{problem}{/}", "{", "}",
        ] {
            XCTAssertEqual(ConductorMarkup(text).plainText, text, "\(text) loses no word")
        }
        XCTAssertEqual(phrases("**no end"), [.plain("**no end")])
        XCTAssertEqual(phrases("a {unknown}x{/} b"), [.plain("a {unknown}x{/} b")])
        XCTAssertEqual(phrases("[label](ftp://example.com)"), [.plain("[label](ftp://example.com)")])
    }

    func testAnUnbalancedMarkerDoesNotSpoilTheRest() {
        XCTAssertEqual(phrases("**open and `code` here"), [.plain("**open and "), .code("code"), .plain(" here")])
    }

    func testBulletLists() {
        let markup = ConductorMarkup("Why:\n\n- the strip is **red**;\n- the line reads `Next`.\nThen done.")
        XCTAssertEqual(markup.blocks, [
            .paragraph([.plain("Why:")]),
            .list([[.plain("the strip is "), .bold([.plain("red")]), .plain(";")], [.plain("the line reads "), .code("Next"), .plain(".")]]),
            .paragraph([.plain("Then done.")]),
        ])
        XCTAssertEqual(markup.plainText, "Why:\n- the strip is red;\n- the line reads Next.\nThen done.")
    }

    func testAFencedBlockMarksAddedAndRemovedLines() {
        let markup = ConductorMarkup("Fix:\n\n```swift\n- case .done: .status(.done)\n+ case .done: return .status(.done)\n  context\n```\n\nDone.")
        XCTAssertEqual(markup.blocks[1], .codeBlock([
            .init(text: "- case .done: .status(.done)", change: .removed), .init(text: "+ case .done: return .status(.done)", change: .added),
            .init(text: "  context", change: .unchanged),
        ]))
        XCTAssertEqual(markup.blocks.count, 3)
        // Markers inside a code block are code.
        XCTAssertEqual(ConductorMarkup("```\n**not bold**\n```").blocks, [.codeBlock([.init(text: "**not bold**", change: .unchanged)])])
    }

    func testAFenceThatNeverClosesIsPlainText() {
        let markup = ConductorMarkup("```\n- left open\n+ so plain")
        XCTAssertEqual(markup.plainText, "```\n- left open\n+ so plain")
        XCTAssertFalse(markup.blocks.contains { if case .codeBlock = $0 { true } else { false } })
    }

    func testTheFirstParagraphIsTheHeadlineAndALastNextParagraphIsQuiet() {
        let markup = ConductorMarkup("QA passed.\n\n- one\n\nMiddle.\n\nNext: Merging.")
        XCTAssertEqual(markup.roles, [.headline, .body, .body, .next])
        // Only a last paragraph is `Next:`, and a lone one is the headline.
        XCTAssertEqual(ConductorMarkup("Next: a\n\nThen more.").roles, [.headline, .body])
        XCTAssertEqual(ConductorMarkup("Next: only").roles, [.headline])
        // A list first has no headline.
        XCTAssertEqual(ConductorMarkup("- a\n\nWords.").roles, [.body, .body])
    }

    func testOneLineStripsTheMarkupAndTheBreaks() {
        let markup = ConductorMarkup("**First** build {problem}failure{/}.\n\n- see `a.swift`\n\nNext: wait.")
        XCTAssertEqual(markup.oneLine, "First build failure. - see a.swift Next: wait.")
    }

    func testWindowsLineEndsRead() {
        XCTAssertEqual(ConductorMarkup("One.\r\n\r\nTwo.").blocks.count, 2)
    }
}
