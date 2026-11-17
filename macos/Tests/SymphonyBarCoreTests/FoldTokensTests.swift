import XCTest
@testable import SymphonyBarCore

/// TP-1511: the Key-value list's and the Collapsible card's measures, as the catalog's `components.css` sets them, and
/// what the card's head shows and says in each state.
final class FoldTokensTests: XCTestCase {
    func testTheKeyValueListsMeasuresAreTheCatalogs() {
        XCTAssertEqual(DesignTokens.KeyValue.columnGap, 16)
        XCTAssertEqual(DesignTokens.KeyValue.rowGap, 8)
        XCTAssertEqual(DesignTokens.KeyValue.compactRowGap, 6)
        XCTAssertEqual(DesignTokens.KeyValue.stackedLabelGap, 2)
        XCTAssertEqual(DesignTokens.KeyValue.stackedValueGap, 8)
        XCTAssertEqual(DesignTokens.KeyValue.groupGap, 16)
        XCTAssertEqual(DesignTokens.KeyValue.groupHeadingGap, 8)
        XCTAssertEqual(DesignTokens.KeyValue.valueGap, 8)
        XCTAssertEqual(DesignTokens.KeyValue.groupHeadingTracking, 0.08)
    }

    func testAListUnder300PointsIsStacked() {
        XCTAssertEqual(DesignTokens.KeyValue.Layout.fitting(299), .stacked)
        XCTAssertEqual(DesignTokens.KeyValue.Layout.fitting(300), .columns)
        XCTAssertEqual(DesignTokens.KeyValue.Layout.allCases, [.columns, .stacked])
    }

    func testTheCollapsibleCardsMeasuresAreTheCatalogs() {
        XCTAssertEqual(DesignTokens.Collapsible.headMinHeight, 48)
        XCTAssertEqual(DesignTokens.Collapsible.headVerticalPadding, 12)
        XCTAssertEqual(DesignTokens.Collapsible.headHorizontalPadding, 20)
        XCTAssertEqual(DesignTokens.Collapsible.headGap, 8)
        XCTAssertEqual(DesignTokens.Collapsible.chevronSize, 10)
        XCTAssertEqual(DesignTokens.Collapsible.bodyLeadingPadding, 18)
        XCTAssertEqual(DesignTokens.Collapsible.bodyPadding, 12)
        XCTAssertEqual(DesignTokens.Collapsible.rowEnterOffset, 6)
        XCTAssertEqual(DesignTokens.Collapsible.emptySummary, "None yet")
    }

    func testTheSummaryFadesAndTheChevronTurnsWhileOpen() {
        XCTAssertEqual(DesignTokens.Collapsible.summaryOpacity(expanded: false), 1)
        XCTAssertEqual(DesignTokens.Collapsible.summaryOpacity(expanded: true), 0)
        XCTAssertEqual(DesignTokens.Collapsible.chevronDegrees(expanded: false), 0)
        XCTAssertEqual(DesignTokens.Collapsible.chevronDegrees(expanded: true), 90)
    }

    func testVoiceOverReadsTheStateThenTheSummary() {
        XCTAssertEqual(DesignTokens.Collapsible.spokenValue(expanded: false, summary: "3 runs", empty: false), "collapsed, 3 runs")
        XCTAssertEqual(DesignTokens.Collapsible.spokenValue(expanded: true, summary: "3 runs", empty: false), "expanded")
        XCTAssertEqual(DesignTokens.Collapsible.spokenValue(expanded: false, summary: nil, empty: false), "collapsed")
        XCTAssertEqual(DesignTokens.Collapsible.spokenValue(expanded: false, summary: "", empty: false), "collapsed")
        XCTAssertEqual(DesignTokens.Collapsible.spokenValue(expanded: false, summary: "3 runs", empty: true), "None yet")
    }
}
