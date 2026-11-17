import XCTest
@testable import SymphonyBarCore

/// TP-1530: what the Progress meter reads off a use against its cap, the Save bar's count and the Searchable pop-up's
/// search, as the catalog's stories say them.
final class ProgressMeterReadingTests: XCTestCase {
    private func tokens(_ used: Double, cap: Double = 5_000_000, resets: String = "at midnight") -> ProgressMeterReading {
        ProgressMeterReading(label: "Tokens today", used: used, cap: cap, unit: .tokens, resets: resets)
    }

    func testTheCatalogsStoriesReadAsItDrawsThem() {
        let calm = tokens(2_100_000)
        XCTAssertEqual(calm.percent, 42)
        XCTAssertEqual(calm.level, .calm)
        XCTAssertEqual(calm.value, "2.1M of 5M tokens · 42 %")
        XCTAssertEqual(calm.note, "Plenty left. Resets at midnight.")

        let near = tokens(4_100_000)
        XCTAssertEqual(near.level, .near)
        XCTAssertEqual(near.note, "Getting close: 18 % left until at midnight.")

        let atCap = tokens(4_900_000)
        XCTAssertEqual(atCap.level, .atCap)
        XCTAssertEqual(atCap.note, "Almost at the cap: runs still finish, new ones wait from 100 %.")

        let ticket = tokens(7_600_000, cap: 8_000_000, resets: "never: the cap is per ticket")
        XCTAssertEqual(ticket.value, "7.6M of 8M tokens · 95 %")
        XCTAssertEqual(ticket.level, .atCap)

        let empty = tokens(0)
        XCTAssertEqual(empty.percent, 0)
        XCTAssertEqual(empty.value, "0 of 5M tokens · 0 %")

        let full = tokens(6_000_000)
        XCTAssertEqual(full.percent, 100, "the share never passes the cap")
        XCTAssertEqual(full.note, "At the cap: no new run starts until at midnight.")
    }

    func testRunsAndSmallCountsAreSaidAsTheyAre() {
        XCTAssertEqual(ProgressMeterReading.amount(12, unit: .runs), "12")
        XCTAssertEqual(ProgressMeterReading.amount(12_400, unit: .tokens), "12K")
        XCTAssertEqual(ProgressMeterReading.amount(950, unit: .tokens), "950")
        XCTAssertEqual(ProgressMeterReading(label: "Runs", used: 3, cap: 4, unit: .runs, resets: "never").value, "3 of 4 runs · 75 %")
        XCTAssertEqual(ProgressMeterReading.percent(used: 5, cap: 0), 100, "a cap under 1 counts as 1")
        XCTAssertEqual(ProgressMeterReading.percent(used: -3, cap: 10), 0)
        XCTAssertEqual(ProgressMeterReading.spoken("Tokens today", percent: 42), "Tokens today, 42 percent")
    }

    func testAStopMarkTurnsTheLineOrangeFromItAndRedOnlyAtTheCap() {
        XCTAssertEqual(ProgressMeterReading.lineLevel(percent: 62, stop: nil), .calm)
        XCTAssertEqual(ProgressMeterReading.lineLevel(percent: 80, stop: nil), .near, "without a mark, as the full meter")
        XCTAssertEqual(ProgressMeterReading.lineLevel(percent: 96, stop: nil), .atCap)
        XCTAssertEqual(ProgressMeterReading.lineLevel(percent: 62, stop: 90), .calm)
        XCTAssertEqual(ProgressMeterReading.lineLevel(percent: 89, stop: 90), .calm, "orange only from the mark")
        XCTAssertEqual(ProgressMeterReading.lineLevel(percent: 90, stop: 90), .near)
        XCTAssertEqual(ProgressMeterReading.lineLevel(percent: 99, stop: 90), .near, "red only at 100 % with a mark")
        XCTAssertEqual(ProgressMeterReading.lineLevel(percent: 100, stop: 90), .atCap)
    }

    func testOnlyAShareInsideTheBarGetsAStopMark() {
        XCTAssertEqual(ProgressMeterReading.mark(90), 90)
        XCTAssertNil(ProgressMeterReading.mark(nil))
        XCTAssertNil(ProgressMeterReading.mark(0), "0 is no mark, as the catalog's control says")
        XCTAssertNil(ProgressMeterReading.mark(100))
        XCTAssertNil(ProgressMeterReading.mark(-5))
        XCTAssertEqual(ProgressMeterReading.clamped(140), 100)
        XCTAssertEqual(ProgressMeterReading.clamped(-1), 0)
    }

    func testTheSaveBarCountsOneChangeAndSeveral() {
        XCTAssertEqual(DesignTokens.SaveBar.unsaved(1), "1 change not saved")
        XCTAssertEqual(DesignTokens.SaveBar.unsaved(2), "2 changes not saved")
        XCTAssertNil(DesignTokens.SaveBar.unsaved(0), "no count with nothing to save")
    }

    func testTheSearchKeepsTheChoicesHoldingWhatIsTyped() {
        let search = MenuSearch(noun: "model")
        XCTAssertEqual(search.placeholder, "Find a model")
        XCTAssertEqual(search.noMatch("gpt"), "No model matches “gpt”.")
        XCTAssertTrue(MenuSearch.matches("deepseek/deepseek-flash", query: "deep"))
        XCTAssertTrue(MenuSearch.matches("openai/gpt-5", query: "GPT"), "case does not count")
        XCTAssertTrue(MenuSearch.matches("anthropic/claude-haiku-4.5", query: "haiku"), "anywhere in the title")
        XCTAssertFalse(MenuSearch.matches("claude-opus-5-5", query: "gpt"))
        XCTAssertTrue(MenuSearch.matches("kimi-k3", query: ""), "an empty query keeps everything")
    }
}
