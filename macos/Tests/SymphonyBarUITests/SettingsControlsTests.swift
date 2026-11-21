import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// TP-1574: the design-system components a Settings page is built of, as shared components: the switch and its row,
/// the number field, the time field, the settings row and its group, and the in-page section list. Their sizes, and
/// what they say.
@MainActor
final class SettingsControlsTests: XCTestCase {
    private enum Section: Hashable { case symphony, notifications, updates }

    private let sections: [SidebarEntry<Section>] = [
        SidebarEntry(id: .symphony, title: "Symphony", symbol: "gearshape"),
        SidebarEntry(id: .notifications, title: "Notifications", symbol: "bell"),
        SidebarEntry(id: .updates, title: "Updates", symbol: "arrow.down.circle"),
    ]

    private func size(_ view: some View, width: CGFloat? = nil) -> CGSize {
        let host = NSHostingView(rootView: view.frame(width: width).environment(\.offscreenSnapshot, true))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    private func liveSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layout()
        return host.fittingSize
    }

    // MARK: - Toggle

    func testTheSwitchIs40By24InEveryState() {
        let states: [DesignTokens.Interaction] = [.rest, .hover, .press, .focus, .off]
        for on in [true, false] {
            for state in states {
                let face = size(SwitchFace(on: on, state: state, reduceMotion: true))
                XCTAssertEqual(face.width, 40, accuracy: 0.5, "\(on) \(state)")
                XCTAssertEqual(face.height, 24, accuracy: 0.5, "\(on) \(state)")
            }
        }
        let live = liveSize(DirectorSwitch("Notify me", isOn: .constant(true)))
        XCTAssertEqual(live.width, 40, accuracy: 0.5)
        XCTAssertEqual(live.height, 24, accuracy: 0.5)
    }

    func testTheToggleRowsEffectLineAddsToItAndTheReasonTakesItsPlace() {
        let width: CGFloat = 400
        let bare = size(DirectorToggle("Notify me about new questions", isOn: .constant(true)), width: width).height
        let effect = size(
            DirectorToggle("Notify me about new questions", isOn: .constant(true), effect: "A notification for each new question."),
            width: width
        ).height
        let reason = size(
            DirectorToggle(
                "Notify me about new questions", isOn: .constant(false), effect: "A notification for each new question.",
                disabledReason: "Notifications are off.", drawnAs: .rest
            ),
            width: width
        ).height
        XCTAssertGreaterThan(effect, bare)
        XCTAssertGreaterThan(reason, bare, "the reason takes the effect line's place")
        // `padding: var(--space-3) …` around the switch's 24 pt.
        XCTAssertEqual(bare, 24 + 2 * 12, accuracy: 0.5)
    }

    // MARK: - Number field

    func testTheNumberFieldIsTheControlHeights() {
        for size in DesignTokens.Control.allCases {
            let still = self.size(NumberField(value: .constant(30), in: 1...60, size: size, drawnAs: .rest))
            XCTAssertEqual(still.height, size.height, accuracy: 0.5, "\(size)")
            let live = liveSize(NumberField(value: .constant(30), in: 1...60, unit: "minutes", size: size))
            XCTAssertEqual(live.height, size.height, accuracy: 0.5, "a live \(size) field")
        }
    }

    func testTheNumberFieldsUnitAndLinesAddToIt() {
        let bare = size(NumberField(value: .constant(30), in: 1...60, drawnAs: .rest))
        let unit = size(NumberField(value: .constant(30), in: 1...60, unit: "minutes", drawnAs: .rest))
        XCTAssertGreaterThan(unit.width, bare.width)
        XCTAssertEqual(bare.width, DesignTokens.NumberField.width + DesignTokens.NumberField.stepperWidth, accuracy: 0.5)
        let labelled = size(NumberField("Restart timeout", value: .constant(30), in: 1...60, drawnAs: .rest)).height
        let helped = size(NumberField("Restart timeout", value: .constant(30), in: 1...60, help: "How long.", drawnAs: .rest)).height
        let error = size(
            NumberField("Restart timeout", value: .constant(30), in: 1...60, help: "How long.", error: "Too short.", drawnAs: .focused)
        ).height
        let reason = size(
            NumberField("Restart timeout", value: .constant(30), in: 1...60, help: "How long.", disabledReason: "In use.", drawnAs: .rest)
        ).height
        XCTAssertGreaterThan(labelled, bare.height)
        XCTAssertGreaterThan(helped, labelled)
        XCTAssertEqual(error, helped, accuracy: 0.5, "the error takes the help's place")
        XCTAssertGreaterThanOrEqual(reason, helped - 0.5, "the reason takes the help's place")
    }

    func testTheNumberFieldDrawsAValueOutsideItsRangeAtItsEnd() {
        // Drawn at 900 in 1…60 it is as wide as at 60: the value is shown inside the range.
        let past = size(NumberField(value: .constant(900), in: 1...60, drawnAs: .rest)).width
        let end = size(NumberField(value: .constant(60), in: 1...60, drawnAs: .rest)).width
        XCTAssertEqual(past, end, accuracy: 0.5)
        XCTAssertEqual(NumberField(value: .constant(1), in: 1...60, step: 0).step, 1, "a step is one at least")
    }

    // MARK: - Time field

    func testTheTimeFieldIsTheControlHeights() {
        for size in DesignTokens.Control.allCases {
            let still = self.size(TimeField(time: .constant(.defaultUpdateTime), size: size, drawnAs: .focused, drawnPart: .hour))
            XCTAssertEqual(still.height, size.height, accuracy: 0.5, "\(size)")
            let live = liveSize(TimeField(time: .constant(.defaultUpdateTime), size: size))
            XCTAssertEqual(live.height, size.height, accuracy: 0.5, "a live \(size) field")
        }
        let labelled = size(TimeField("Install at", time: .constant(.defaultUpdateTime), help: "Every day.", drawnAs: .rest)).height
        let error = size(
            TimeField("Install at", time: .constant(.defaultUpdateTime), help: "Every day.", error: "Outside working hours.", drawnAs: .rest)
        ).height
        XCTAssertGreaterThan(labelled, DesignTokens.Control.medium.height)
        XCTAssertEqual(error, labelled, accuracy: 0.5, "the error takes the help's place")
    }

    // MARK: - Settings row and group

    func testTheRowsLineIsOneOfHelpErrorOrReason() {
        let width: CGFloat = 520
        func row(help: String? = nil, error: String? = nil, reason: String? = nil) -> CGFloat {
            size(
                SettingsRow("Restart timeout", help: help, error: error, disabledReason: reason) {
                    NumberField(value: .constant(5), in: 1...60, unit: "minutes", drawnAs: .rest)
                },
                width: width
            ).height
        }
        let bare = row()
        let helped = row(help: "How long Symphony gets to restart.")
        XCTAssertEqual(bare, DesignTokens.Control.medium.height + 2 * DesignTokens.SettingsRow.verticalPadding, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(helped, bare)
        XCTAssertEqual(row(help: "How long Symphony gets to restart.", error: "One minute at least."), helped, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(row(help: "How long Symphony gets to restart.", reason: "In use."), helped - 0.5)
        XCTAssertEqual(SettingsRow<EmptyView>.spokenHint(.help("How long.")), "How long.")
        XCTAssertEqual(SettingsRow<EmptyView>.spokenHint(.error("Too short.")), "Too short.")
        XCTAssertEqual(SettingsRow<EmptyView>.spokenHint(.reason("In use.")), "In use.")
        XCTAssertEqual(SettingsRow<EmptyView>.spokenHint(nil), "")
    }

    func testAGroupHoldsItsRowsUnderItsTitleAndOverItsFooter() {
        let width: CGFloat = 520
        func toggle(_ label: String) -> some View { DirectorToggle(label, isOn: .constant(true), drawnAs: .rest) }
        let one = size(SettingsGroup { toggle("One") }, width: width).height
        let two = size(SettingsGroup { toggle("One"); toggle("Two") }, width: width).height
        let titled = size(SettingsGroup("Updates") { toggle("One"); toggle("Two") }, width: width).height
        let footed = size(SettingsGroup("Updates", footer: "Installs by itself.") { toggle("One"); toggle("Two") }, width: width).height
        let blank = size(SettingsGroup(" ", footer: "") { toggle("One"); toggle("Two") }, width: width).height
        XCTAssertEqual(two, 2 * one + HairlineDivider.thickness, accuracy: 0.5, "a hairline between two rows")
        XCTAssertGreaterThan(titled, two)
        XCTAssertGreaterThan(footed, titled)
        XCTAssertEqual(blank, two, accuracy: 0.5, "a blank title or footer is not drawn")
        XCTAssertEqual(SettingsGroup<EmptyView>.shown("Updates"), "Updates")
        XCTAssertNil(SettingsGroup<EmptyView>.shown("  "))
        XCTAssertNil(SettingsGroup<EmptyView>.shown(nil))
    }

    // MARK: - Section list

    func testTheSectionListIsItsWidthAndOneRowASection() {
        let list = size(SectionList(sections, current: .updates, windowActive: true) { _ in })
        let tokens = DesignTokens.Sidebar.self
        XCTAssertEqual(list.width, DesignTokens.SectionList.width, accuracy: 0.5)
        let rows = CGFloat(sections.count)
        XCTAssertEqual(list.height, rows * tokens.rowHeight + (rows - 1) * tokens.rowGap + 2 * DesignTokens.SectionList.inset, accuracy: 0.5)
        let drawn = size(SectionList(sections, current: .updates, windowActive: false, drawn: [.symphony: .hover, .notifications: .focus]) { _ in })
        XCTAssertEqual(drawn, list, "a drawn state changes no size")
    }
}
