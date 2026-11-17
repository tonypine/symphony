import XCTest
@testable import SymphonyBarCore

/// The catalog's Text field, Search field and multi-line input (TP-1509): `DesignTokens.Field`'s values and the
/// choices the three components draw from.
final class FieldTokensTests: XCTestCase {
    private typealias Field = DesignTokens.Field

    func testTheMeasuresAreTheCatalogs() {
        XCTAssertEqual(Field.gap, 6)
        XCTAssertEqual(Field.paddingScale, 0.7)
        XCTAssertEqual(Field.searchLeadingScale, 0.75)
        XCTAssertEqual(Field.searchTrailingScale, 0.6)
        XCTAssertEqual(Field.itemGap, DesignTokens.Space.s2)
        XCTAssertEqual(Field.edgeWidth, 1)
        // `0 0 0 4px` past the 1 pt edge.
        XCTAssertEqual(Field.edgeWidth + Field.haloWidth, 4)
        XCTAssertEqual(Field.accentedFocusEdge + Field.accentedFocusHalo, 5)
        XCTAssertEqual(Field.textWeight, 400)
        XCTAssertEqual(Field.searchGlyph, 13)
        XCTAssertEqual(Field.clearSize, 16)
        XCTAssertEqual(Field.clearGlyph, 8)
        XCTAssertEqual(Field.areaRadius, DesignTokens.Radius.row)
        XCTAssertEqual(Field.areaMinLines, 3)
        XCTAssertEqual(Field.areaMaxLines, 8)
        XCTAssertEqual(DesignTokens.KeyHint.keys(Field.searchShortcut), ["⌘", "F"])
        XCTAssertEqual(DesignTokens.KeyHint.keys(Field.sendShortcut), ["⌘", "↩"])
    }

    func testTheShakeIsTheCatalogsOnceOverTheSlowCurve() {
        XCTAssertEqual(Field.shakeOffsets, [-4, 3, -2, 0])
        XCTAssertEqual(Field.shakeTimes, [0.2, 0.45, 0.7, 1])
        XCTAssertEqual(Field.shakeOffsets.count, Field.shakeTimes.count)
        XCTAssertEqual(Field.shakeTimes, Field.shakeTimes.sorted())
        XCTAssertEqual(Field.shakeOffsets.last, 0, "the field comes to rest where it was")
    }

    func testTheTextFieldsSurfaceAndEdgeInEachState() {
        XCTAssertEqual(Field.fill(.text, .rest, disabled: false), .surfaceContent)
        XCTAssertEqual(Field.fill(.text, .hover, disabled: false), .surfaceContent)
        XCTAssertEqual(Field.fill(.text, .focused, disabled: false), .surfaceContent)
        XCTAssertEqual(Field.fill(.text, .rest, disabled: true), .surfaceRaised)
        XCTAssertEqual(Field.edge(.text, .rest), Field.Tone(.strokeStrong))
        XCTAssertEqual(Field.edge(.text, .hover), Field.Tone(.textPrimary, opacity: 0.28))
        XCTAssertEqual(Field.edge(.text, .focused), Field.Tone(.accent))
        XCTAssertEqual(Field.edge(.text, .focused, invalid: true), Field.Tone(.statusProblem))
        XCTAssertEqual(Field.edge(.text, .rest, invalid: true), Field.Tone(.statusProblem))
        XCTAssertEqual(Field.edge(.text, .hover, disabled: true), Field.Tone(.strokeSeparator))
        XCTAssertEqual(Field.edge(.text, .rest, accented: true), Field.Tone(.accent))
    }

    func testTheSearchFieldIsSunkenUntilFocused() {
        XCTAssertEqual(Field.fill(.search, .rest, disabled: false), .surfaceSunken)
        XCTAssertEqual(Field.fill(.search, .hover, disabled: false), .surfaceSunken)
        XCTAssertEqual(Field.fill(.search, .focused, disabled: false), .surfaceContent)
        XCTAssertEqual(Field.fill(.search, .rest, disabled: true), .surfaceRaised)
        XCTAssertEqual(Field.edge(.search, .rest), Field.Tone(.strokeSeparator))
        XCTAssertEqual(Field.edge(.search, .hover), Field.Tone(.strokeStrong))
        XCTAssertEqual(Field.edge(.search, .focused), Field.Tone(.accent))
    }

    func testTheHaloShowsWhileFocusedOrOnAnAccentedArea() {
        XCTAssertNil(Field.halo(.rest))
        XCTAssertNil(Field.halo(.hover))
        XCTAssertEqual(Field.halo(.focused), .accentTintStrong)
        XCTAssertEqual(Field.halo(.focused, invalid: true), .tintProblem)
        XCTAssertNil(Field.halo(.rest, invalid: true))
        XCTAssertNil(Field.halo(.focused, disabled: true))
        XCTAssertEqual(Field.halo(.rest, accented: true), .accentTint)
        XCTAssertNil(Field.halo(.rest, invalid: true, accented: true))
        XCTAssertEqual(Field.halo(.focused, accented: true), .accentTintStrong)
    }

    func testUnderTheFieldIsTheReasonTheErrorOrTheHelpNeverTwo() {
        XCTAssertNil(Field.footnote(help: nil, error: nil, disabledReason: nil))
        XCTAssertEqual(Field.footnote(help: "Shown to everyone.", error: nil, disabledReason: nil), .help("Shown to everyone."))
        XCTAssertEqual(Field.footnote(help: "Shown to everyone.", error: "Give a reason.", disabledReason: nil), .error("Give a reason."))
        XCTAssertEqual(Field.footnote(help: "Shown to everyone.", error: "Give a reason.", disabledReason: "Set by the rule."), .reason("Set by the rule."))
        // Blank words are no footnote.
        XCTAssertEqual(Field.footnote(help: "Shown to everyone.", error: "  ", disabledReason: ""), .help("Shown to everyone."))
        XCTAssertNil(Field.footnote(help: " ", error: nil, disabledReason: nil))
    }

    func testTheSearchFieldsCountAndNoMatchLine() {
        XCTAssertEqual(Field.matches(3), "3 found")
        XCTAssertEqual(Field.matches(1), "1 found")
        XCTAssertEqual(Field.matches(0), "None")
        XCTAssertEqual(
            Field.noMatch(" storybook ", searched: "Search looks at identifiers and titles."),
            "Nothing matches “storybook”. Search looks at identifiers and titles."
        )
        XCTAssertTrue(Field.hasQuery("catalog"))
        XCTAssertFalse(Field.hasQuery(""))
        XCTAssertFalse(Field.hasQuery("   "))
    }

    /// Escape clears the query first, then gives up the keyboard.
    func testEscapeClearsThenLetsGo() {
        XCTAssertEqual(Field.escape(query: "storybook"), .clear)
        XCTAssertEqual(Field.escape(query: " "), .clear)
        XCTAssertEqual(Field.escape(query: ""), .release)
    }

    func testTheStatesAndKinds() {
        XCTAssertEqual(Field.State.allCases, [.rest, .hover, .focused])
        XCTAssertEqual(Field.Kind.allCases, [.text, .search])
        XCTAssertEqual(Field.Tone(.accent).opacity, 1)
    }
}
