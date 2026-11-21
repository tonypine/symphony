import XCTest
@testable import SymphonyBarCore

/// The design-system components a Settings page is built of (TP-1574): the catalog's Toggle, the number field, the
/// time field, the settings row and its group, and the in-page section list. Their tokens, the rules their values
/// follow, and the Component Gallery's stories of each.
final class SettingsControlsTokensTests: XCTestCase {
    private typealias Switch = DesignTokens.Switch
    private typealias Number = DesignTokens.NumberField
    private typealias Time = DesignTokens.TimeField
    private typealias Sections = DesignTokens.SectionList

    // MARK: - Toggle

    func testTheSwitchIsTheCatalogs() {
        // `.switch { width: 40px; height: var(--control-sm) }`, its knob 20 pt 2 pt inside, 25 pt while pressed.
        XCTAssertEqual(Switch.width, 40)
        XCTAssertEqual(Switch.height, DesignTokens.Control.small.height)
        XCTAssertEqual(Switch.knobInset, 2)
        XCTAssertEqual(Switch.knobSize, 20)
        XCTAssertEqual(Switch.knobWidth(pressed: false), 20)
        XCTAssertEqual(Switch.knobWidth(pressed: true), 25)
        XCTAssertEqual(Switch.offTrackTint, 0.08)
        XCTAssertEqual(Switch.disabledOpacity, 0.45)
        XCTAssertEqual(Switch.edgeWidth, DesignTokens.Control.edgeWidth)
        XCTAssertEqual(Switch.knob, .textOnAccent)
        XCTAssertEqual(Switch.travel, .slide, "the knob travels on the lively spring")
        XCTAssertEqual(Switch.trackChange, .standard)
    }

    func testTheKnobTravelsToTheFarEndAndStretchesTowardIt() {
        XCTAssertEqual(Switch.knobOffset(on: false, pressed: false), 0)
        XCTAssertEqual(Switch.knobOffset(on: false, pressed: true), 0, "off and pressed, it stretches to the right")
        // `translateX(16px)` on, `translateX(11px)` on and pressed: its trailing edge stays put.
        XCTAssertEqual(Switch.knobOffset(on: true, pressed: false), 16)
        XCTAssertEqual(Switch.knobOffset(on: true, pressed: true), 11)
        XCTAssertEqual(Switch.knobOffset(on: true, pressed: true) + Switch.knobWidth(pressed: true), Switch.knobOffset(on: true, pressed: false) + Switch.knobSize)
    }

    func testTheTrackIsSunkenOffAndTheAccentOn() {
        XCTAssertEqual(Switch.track(on: false, hovered: false), .surfaceSunken)
        XCTAssertEqual(Switch.track(on: false, hovered: true), .surfaceSunken)
        XCTAssertEqual(Switch.track(on: true, hovered: false), .accent)
        XCTAssertEqual(Switch.track(on: true, hovered: true), .accentHover)
        XCTAssertEqual(Switch.edge(on: false, hovered: false), .strokeSeparator)
        XCTAssertEqual(Switch.edge(on: false, hovered: true), .strokeStrong)
        XCTAssertEqual(Switch.edge(on: true, hovered: false), .accentPressed)
        XCTAssertEqual(Switch.spoken(on: true), "on")
        XCTAssertEqual(Switch.spoken(on: false), "off")
    }

    // MARK: - Settings row

    func testTheRowIsTheCatalogsToggleRow() {
        let row = DesignTokens.SettingsRow.self
        XCTAssertEqual(row.verticalPadding, DesignTokens.Space.s3)
        XCTAssertEqual(row.horizontalPadding, DesignTokens.Space.s4)
        XCTAssertEqual(row.columnGap, DesignTokens.Space.s4)
        XCTAssertEqual(row.lineGap, 2)
        XCTAssertEqual(row.labelSize, 13)
        XCTAssertEqual(row.labelWeight, 500)
        XCTAssertEqual(row.radius, DesignTokens.Radius.row)
        XCTAssertEqual(row.elevation, .level1)
        XCTAssertEqual(row.surface, .surfaceContent)
        XCTAssertEqual(row.toggleWidth, 400)
        XCTAssertEqual(row.titleTracking, DesignTokens.KeyValue.groupHeadingTracking)
    }

    func testUnderTheRowsLabelIsTheReasonTheErrorOrTheHelpNeverTwo() {
        let row = DesignTokens.SettingsRow.self
        XCTAssertNil(row.footnote(help: nil, error: nil, disabledReason: nil))
        XCTAssertEqual(row.footnote(help: "How long.", error: nil, disabledReason: nil), .help("How long."))
        XCTAssertEqual(row.footnote(help: "How long.", error: "One minute at least.", disabledReason: nil), .error("One minute at least."))
        XCTAssertEqual(row.footnote(help: "How long.", error: "One minute at least.", disabledReason: "In use."), .reason("In use."))
        XCTAssertEqual(row.footnote(help: "How long.", error: " ", disabledReason: ""), .help("How long."))
        XCTAssertEqual(row.label(disabled: false), .textPrimary)
        XCTAssertEqual(row.label(disabled: true), .textTertiary)
    }

    // MARK: - Number field

    func testTheNumberStaysInsideItsRange() {
        XCTAssertEqual(Number.clamp(0, to: 1...60), 1)
        XCTAssertEqual(Number.clamp(30, to: 1...60), 30)
        XCTAssertEqual(Number.clamp(90, to: 1...60), 60)
        XCTAssertEqual(Number.step(30, by: 1, in: 1...60), 31)
        XCTAssertEqual(Number.step(30, by: -5, in: 1...60), 25)
        XCTAssertEqual(Number.step(60, by: 1, in: 1...60), 60, "it stops at its maximum")
        XCTAssertEqual(Number.step(1, by: -1, in: 1...60), 1, "it stops at its minimum")
        XCTAssertEqual(Number.step(58, by: 5, in: 1...60), 60)
        XCTAssertEqual(Number.step(99, by: -1, in: 1...60), 59, "a value outside the range steps from its end")
        XCTAssertEqual(Number.step(Int.max - 1, by: 5, in: 0...Int.max), Int.max, "no overflow past the top")
        XCTAssertEqual(Number.step(Int.min + 1, by: -5, in: Int.min...0), Int.min, "no overflow past the bottom")
    }

    func testAHalfOfTheStepperIsOffAtTheEndItMovesToward() {
        XCTAssertTrue(Number.canStep(30, by: 1, in: 1...60))
        XCTAssertTrue(Number.canStep(30, by: -1, in: 1...60))
        XCTAssertFalse(Number.canStep(60, by: 1, in: 1...60))
        XCTAssertTrue(Number.canStep(60, by: -1, in: 1...60))
        XCTAssertFalse(Number.canStep(1, by: -1, in: 1...60))
        XCTAssertTrue(Number.canStep(1, by: 1, in: 1...60))
        XCTAssertFalse(Number.canStep(5, by: 1, in: 5...5), "a range of one value has nowhere to go")
    }

    func testTypedTextIsAWholeNumberBroughtInsideTheRange() {
        XCTAssertEqual(Number.parse("42", in: 1...60), 42)
        XCTAssertEqual(Number.parse(" 42 ", in: 1...60), 42)
        XCTAssertEqual(Number.parse("1,000", in: 1...5000), 1000)
        XCTAssertEqual(Number.parse("1\u{2019}000", in: 1...5000), 1000)
        XCTAssertEqual(Number.parse("1_000", in: 1...5000), 1000)
        XCTAssertEqual(Number.parse("1 000", in: 1...5000), 1000)
        XCTAssertEqual(Number.parse("900", in: 1...60), 60)
        XCTAssertEqual(Number.parse("0", in: 1...60), 1)
        XCTAssertEqual(Number.parse("-4", in: 1...60), 1)
        XCTAssertEqual(Number.parse("99999999999999999999999", in: 1...60), 60, "too long for a number, still past the top")
        XCTAssertEqual(Number.parse("-99999999999999999999999", in: 1...60), 1)
        XCTAssertNil(Number.parse("", in: 1...60))
        XCTAssertNil(Number.parse("   ", in: 1...60))
        XCTAssertNil(Number.parse("ten", in: 1...60))
        XCTAssertNil(Number.parse("1.5", in: 1...60))
        XCTAssertNil(Number.parse("-", in: 1...60))
        XCTAssertNil(Number.parse("12a99999999999999999999", in: 1...60))
    }

    /// TP-1576: a page that says why a typed value is out of range widens what typed text may set; the stepper keeps to
    /// the range.
    func testAFieldThatAcceptsMoreReadsTypedTextIntoTheWiderRange() {
        XCTAssertEqual(Number.typedRange(1...600, accepts: nil), 1...600)
        XCTAssertEqual(Number.typedRange(1...600, accepts: Int.min...Int.max), Int.min...Int.max)
        XCTAssertEqual(Number.typedRange(1...600, accepts: 100...200), 1...600, "it always holds the range")
        XCTAssertEqual(Number.typedRange(10...600, accepts: 0...20), 0...600)
        XCTAssertEqual(Number.parse("900", in: Number.typedRange(1...600, accepts: Int.min...Int.max)), 900)
        XCTAssertEqual(Number.step(900, by: -1, in: 1...600), 599, "the stepper steps back inside the range")
    }

    func testTheNumberFieldSaysItsValueAndRange() {
        XCTAssertEqual(Number.spoken(30, unit: "minutes"), "30 minutes")
        XCTAssertEqual(Number.spoken(30, unit: nil), "30")
        XCTAssertEqual(Number.spoken(30, unit: ""), "30")
        XCTAssertEqual(Number.rangeHint(1...60), "From 1 to 60")
        XCTAssertEqual(Number.upSymbol, "chevron.up")
        XCTAssertEqual(Number.downSymbol, "chevron.down")
        XCTAssertEqual(Number.unitGap, DesignTokens.Space.s2)
    }

    // MARK: - Time field

    func testTheTimeFieldsPartsAndTheirDigits() {
        let time = TimeOfDay(hour: 3, minute: 7)
        XCTAssertEqual(Time.value(time, .hour), 3)
        XCTAssertEqual(Time.value(time, .minute), 7)
        XCTAssertEqual(Time.digits(time, .hour), "03")
        XCTAssertEqual(Time.digits(TimeOfDay(hour: 21, minute: 45), .minute), "45")
        XCTAssertEqual(Time.Part.hour.maximum, 23)
        XCTAssertEqual(Time.Part.minute.maximum, 59)
        XCTAssertEqual(Time.Part.hour.spoken, "hour")
        XCTAssertEqual(Time.Part.minute.spoken, "minute")
        XCTAssertEqual(Time.separator, ":")
        XCTAssertEqual(Time.partTint, .selected)
    }

    func testAStepWrapsAroundItsPartWithoutCarrying() {
        XCTAssertEqual(Time.step(TimeOfDay(hour: 3, minute: 0), .hour, by: 1), TimeOfDay(hour: 4, minute: 0))
        XCTAssertEqual(Time.step(TimeOfDay(hour: 23, minute: 15), .hour, by: 1), TimeOfDay(hour: 0, minute: 15))
        XCTAssertEqual(Time.step(TimeOfDay(hour: 0, minute: 15), .hour, by: -1), TimeOfDay(hour: 23, minute: 15))
        XCTAssertEqual(Time.step(TimeOfDay(hour: 3, minute: 59), .minute, by: 1), TimeOfDay(hour: 3, minute: 0), "the hour stays")
        XCTAssertEqual(Time.step(TimeOfDay(hour: 3, minute: 0), .minute, by: -1), TimeOfDay(hour: 3, minute: 59))
        XCTAssertEqual(Time.step(TimeOfDay(hour: 3, minute: 10), .minute, by: -75), TimeOfDay(hour: 3, minute: 55))
    }

    func testSettingAPartKeepsTheOtherAndStaysInside() {
        let time = TimeOfDay(hour: 3, minute: 30)
        XCTAssertEqual(Time.setting(time, .hour, to: 18), TimeOfDay(hour: 18, minute: 30))
        XCTAssertEqual(Time.setting(time, .minute, to: 5), TimeOfDay(hour: 3, minute: 5))
        XCTAssertEqual(Time.setting(time, .hour, to: 40), TimeOfDay(hour: 23, minute: 30))
        XCTAssertEqual(Time.setting(time, .minute, to: -2), TimeOfDay(hour: 3, minute: 0))
    }

    func testTheTimeSurvivesTheRoundTripThroughTheField() {
        for minutes in stride(from: 0, to: TimeOfDay.minutesPerDay, by: 7) {
            let time = TimeOfDay(minutesSinceMidnight: minutes)!
            let hour = Time.value(time, .hour)
            let minute = Time.value(time, .minute)
            let rebuilt = Time.setting(Time.setting(TimeOfDay.defaultUpdateTime, .hour, to: hour), .minute, to: minute)
            XCTAssertEqual(rebuilt, time)
            XCTAssertEqual("\(Time.digits(time, .hour))\(Time.separator)\(Time.digits(time, .minute))", time.label)
            XCTAssertEqual(Time.step(Time.step(time, .minute, by: 1), .minute, by: -1), time)
        }
    }

    func testDigitsTypeAPartAndMoveOnWhenItIsWhole() {
        // 1 then 8: 18, done.
        XCTAssertEqual(Time.type(1, into: .hour, after: nil), Time.Typed(value: 1, pending: 1, done: false))
        XCTAssertEqual(Time.type(8, into: .hour, after: 1), Time.Typed(value: 18, pending: nil, done: true))
        // 2 then 9: past 23, so 23.
        XCTAssertEqual(Time.type(9, into: .hour, after: 2), Time.Typed(value: 23, pending: nil, done: true))
        // 3 can start no hour of two digits: 03, done.
        XCTAssertEqual(Time.type(3, into: .hour, after: nil), Time.Typed(value: 3, pending: nil, done: true))
        XCTAssertEqual(Time.type(5, into: .minute, after: nil), Time.Typed(value: 5, pending: 5, done: false))
        XCTAssertEqual(Time.type(6, into: .minute, after: nil), Time.Typed(value: 6, pending: nil, done: true))
        XCTAssertEqual(Time.type(9, into: .minute, after: 5), Time.Typed(value: 59, pending: nil, done: true))
        XCTAssertEqual(Time.type(12, into: .minute, after: nil), Time.Typed(value: 9, pending: nil, done: true), "a digit is 0 to 9")
    }

    func testTheKeyboardMovesBetweenTheParts() {
        XCTAssertEqual(Time.neighbour(of: .hour, forward: true), .minute)
        XCTAssertEqual(Time.neighbour(of: .minute, forward: false), .hour)
        XCTAssertNil(Time.neighbour(of: .hour, forward: false))
        XCTAssertNil(Time.neighbour(of: .minute, forward: true))
    }

    // MARK: - Section list

    func testTheSectionListIsDrawnWithTheSidebarsRows() {
        XCTAssertEqual(Sections.rowGap, DesignTokens.Sidebar.rowGap)
        XCTAssertEqual(Sections.inset, DesignTokens.Sidebar.inset)
        XCTAssertEqual(Sections.width, 200)
        XCTAssertEqual(Sections.label, "Sections")
        XCTAssertEqual(Sections.spoken(current: "Updates"), "Updates, current")
        XCTAssertEqual(Sections.spoken(current: nil), "")
    }

    func testOneSectionIsCurrentAndAClickMakesAnotherCurrent() {
        let ids = ["symphony", "notifications", "updates"]
        XCTAssertEqual(Sections.current(ids, current: "updates"), "updates")
        XCTAssertEqual(Sections.current(ids, current: "gone"), "symphony", "a section the list lacks shows the first")
        XCTAssertEqual(Sections.current(ids, current: nil), "symphony")
        XCTAssertNil(Sections.current([String](), current: "updates"))
        XCTAssertEqual(Sections.picking("notifications", in: ids, current: "updates"), "notifications")
        XCTAssertEqual(Sections.picking("updates", in: ids, current: "updates"), "updates")
        XCTAssertEqual(Sections.picking("gone", in: ids, current: "updates"), "updates", "a click on nothing it holds changes nothing")
    }

    func testTheArrowKeysMoveThroughTheSectionsAndStopAtTheEnds() {
        let ids = ["symphony", "notifications", "updates"]
        XCTAssertEqual(Sections.moved(ids, from: "symphony", down: true), "notifications")
        XCTAssertEqual(Sections.moved(ids, from: "updates", down: true), "updates")
        XCTAssertEqual(Sections.moved(ids, from: "notifications", down: false), "symphony")
        XCTAssertEqual(Sections.moved(ids, from: "symphony", down: false), "symphony")
        XCTAssertEqual(Sections.moved(ids, from: nil, down: true), "symphony")
        XCTAssertEqual(Sections.moved(ids, from: "gone", down: false), "symphony")
    }

    // MARK: - The gallery's stories

    /// Each new component's stories are in the Component Gallery, which draws every one in light and in dark. The
    /// list is `SymphonyGallery --check`'s, held to the gallery's stories.
    func testTheGalleryShowsEveryStateOfEachComponent() throws {
        let variations = CatalogCounterparts.variations(try CatalogCounterpartsTests.read("macos/Gallery/component-variations.txt"))
        let expected: [String: [String]] = [
            "toggle": ["on", "off", "hover", "pressed", "focused", "disabled-with-reason"],
            "number-field": [
                "rest", "hover", "focused", "disabled-with-reason", "error", "at-its-minimum", "at-its-maximum", "typed-out-of-range",
            ],
            "time-field": ["rest", "hover", "focused", "disabled-with-reason", "error"],
            "settings-row": ["with-help", "error", "disabled-with-reason", "label-alone"],
            "settings-group": ["updates", "with-an-error"],
            "settings-line": ["text", "error", "with-fields"],
            "section-list": ["rest", "row-hover", "row-pressed", "row-focused", "window-not-focused"],
        ]
        for (component, stories) in expected {
            for story in stories {
                XCTAssertTrue(variations.contains("\(component)-\(story)"), "\(component)-\(story) is not in the gallery")
            }
        }
    }

    /// TP-1576: every design-system component the Settings page draws its sections, rows and Save bar with has its
    /// stories in the Component Gallery, so the page is the Gallery's components used as their stories show them.
    func testEveryComponentTheSettingsPageUsesHasItsStories() throws {
        let variations = CatalogCounterparts.variations(try CatalogCounterpartsTests.read("macos/Gallery/component-variations.txt"))
        let components = [
            "section-list", "settings-group", "settings-row", "settings-line", "toggle", "number-field", "time-field", "pop-up",
            "segmented-control", "text-field", "text-area", "button", "icon-button", "menu-button", "save-bar", "collapsible-card",
        ]
        for component in components {
            XCTAssertTrue(variations.contains { $0.hasPrefix(component + "-") }, "\(component) has no story in the gallery")
        }
        XCTAssertTrue(variations.contains("save-bar-save-waits"), "the Save bar waiting on a value out of range")
    }

    func testTheSettingsPagesMeasures() {
        let row = DesignTokens.SettingsRow.self
        XCTAssertEqual(row.pageInset, DesignTokens.Space.s6)
        XCTAssertGreaterThan(row.pageMaxWidth, row.toggleWidth)
        XCTAssertLessThan(row.fieldWidth, row.pageMaxWidth / 2)
        XCTAssertLessThan(row.previewMinHeight, row.previewMaxHeight)
    }
}
