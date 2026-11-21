import XCTest
@testable import SymphonyBarCore

/// The Settings page's Save bar counts the settings that differ from the values read (TP-1576).
final class FormValuesTests: XCTestCase {
    private func values(_ settings: AppSettings, phases: PhaseSettings = PhaseSettings(), key: String = "") -> FormValues {
        FormValues([("settings", settings), ("phases", phases), ("linearAPIKey", key)])
    }

    func testThreeEditsInOneSettingsStructCountAsThree() {
        let read = values(AppSettings())
        var edited = AppSettings()
        edited.startOnLaunch.toggle()
        edited.stopTimeoutSeconds += 5
        edited.updateMode = .manual

        XCTAssertEqual(read.changes(to: values(edited)), 3)
    }

    func testAnEditPutBackByHandCountsAsNone() {
        let read = values(AppSettings())
        var edited = AppSettings()
        edited.stopTimeoutSeconds += 5
        XCTAssertEqual(read.changes(to: values(edited)), 1)

        edited.stopTimeoutSeconds -= 5
        XCTAssertEqual(read.changes(to: values(edited)), 0)
        XCTAssertEqual(read, values(edited))
    }

    func testEditsAcrossValuesAddUpAndAListIsOneSetting() {
        let read = values(AppSettings())
        var edited = AppSettings()
        edited.restartTimeoutMinutes += 1
        let step = PhaseStep(stepID: "test", mode: .machine, commands: [StepCommand(run: "mix test")])
        let phases = PhaseSettings(lists: [.implementation: PhaseSteps(steps: [step], isDefault: false)])

        XCTAssertEqual(read.changes(to: values(edited, phases: phases, key: "lin_api_new")), 3)
    }

    func testValuesAReadFillsInLaterAreNoChange() {
        var read = values(AppSettings())
        let filled = values(AppSettings(), key: "lin_api_saved")
        XCTAssertEqual(read.changes(to: filled), 1)

        read.take(FormValues([("linearAPIKey", "lin_api_saved")]))
        XCTAssertEqual(read.changes(to: filled), 0)
    }

    func testASettingOnlyOneSideHoldsCountsAsChanged() {
        XCTAssertEqual(FormValues([("a", 1)]).changes(to: FormValues([("b", 1)])), 2)
    }

    func testAValueThatIsNotEquatableIsComparedByItsDescription() {
        struct Plain { var names: [Plain?] = [] }
        XCTAssertEqual(FormValues([("list", [Plain()])]).changes(to: FormValues([("list", [Plain()])])), 0)
        XCTAssertEqual(FormValues([("list", [Plain()])]).changes(to: FormValues([("list", [Plain(), Plain()])])), 1)
    }
}
