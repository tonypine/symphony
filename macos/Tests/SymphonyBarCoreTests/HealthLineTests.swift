import Foundation
import XCTest
@testable import SymphonyBarCore

final class HealthLineTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    func testConnectedSaysTheBuildThatRunsAndThatSymphonyAnswers() throws {
        let control = DispatchControl(window: .connected, paused: false, state: try state("home"), now: Date(), timeZone: utc)
        let updated = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-07T14:20:05Z"))
        let line = HealthLine(
            window: .connected,
            dispatch: control,
            build: DiagnosticsPayload.Build(version: "0.0.1.412", sha: "9f54098c3a1e5b7d2f4c6a8e0b1d3f5a7c9e1b3d"),
            appVersion: "0.0.1.400",
            lastUpdate: updated,
            timeZone: utc
        )
        XCTAssertEqual(line.dispatch, "Dispatch on")
        XCTAssertEqual(line.build, HealthLine.Part(text: "Symphony 0.0.1.412 · 9f54098"))
        XCTAssertEqual(line.connection, HealthLine.Part(text: "Answering", status: .done, help: "Updated 14:20:05"))
        XCTAssertEqual(line.parts.map(\.text), ["Symphony 0.0.1.412 · 9f54098", "Answering"])
        XCTAssertEqual(line.accessibilityLabel, "Dispatch on, Symphony 0.0.1.412 · 9f54098, Symphony answering")
    }

    func testABuildWithoutItsShaSaysItsVersion() {
        let line = HealthLine(
            window: .connected,
            dispatch: DispatchControl(window: .connected, paused: false, state: nil, now: Date()),
            build: DiagnosticsPayload.Build(version: "0.0.1.412", sha: nil),
            appVersion: "",
            lastUpdate: nil
        )
        XCTAssertEqual(line.build?.text, "Symphony 0.0.1.412")
        XCTAssertNil(line.connection.help)
    }

    func testWhileSymphonyDoesNotAnswerTheLineSaysWhyAndNamesTheAppsVersion() {
        for (window, word) in [(WindowState.stopped, "Stopped"), (.starting, "Starting…"), (.notAnswering, "Not answering"), (.firstLaunch, "Not set up")] {
            let line = HealthLine(
                window: window,
                dispatch: DispatchControl(window: window, paused: false, state: nil, now: Date()),
                build: DiagnosticsPayload.Build(version: "0.0.1.412", sha: "9f54098"),
                appVersion: "0.0.1.400",
                lastUpdate: nil
            )
            XCTAssertEqual(line.connection.text, word)
            XCTAssertEqual(line.connection.status, window.connectionStatus)
            XCTAssertEqual(line.build?.text, "App 0.0.1.400")
            XCTAssertTrue(line.accessibilityLabel.hasSuffix("Symphony \(word.lowercased())"))
        }
        let unknown = HealthLine(
            window: .stopped,
            dispatch: DispatchControl(window: .stopped, paused: false, state: nil, now: Date()),
            build: nil,
            appVersion: "",
            lastUpdate: nil
        )
        XCTAssertNil(unknown.build)
        XCTAssertEqual(unknown.parts.map(\.text), ["Stopped"])
        // A version Symphony leaves empty names no build.
        let empty = HealthLine(
            window: .connected,
            dispatch: DispatchControl(window: .connected, paused: false, state: nil, now: Date()),
            build: DiagnosticsPayload.Build(version: "", sha: "9f54098"),
            appVersion: "",
            lastUpdate: nil
        )
        XCTAssertNil(empty.build)
    }

    private func state(_ name: String) throws -> OverviewState {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/\(name)/api/v1/state.json")
        return try XCTUnwrap(OverviewState.decode(try Data(contentsOf: url)))
    }
}
