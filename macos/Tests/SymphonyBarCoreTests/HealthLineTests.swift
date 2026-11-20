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

    func testALateSymphonyKeepsItsBuildAndCountsMarkedAndOffersLogsAndRestart() throws {
        // TP-1562: the line says Symphony isn't answering, with how long; the counts are the last answer's.
        let window = WindowState.lagging("Symphony isn't answering · 30 s")
        let control = DispatchControl(window: window, paused: false, state: try state("home"), now: Date(), timeZone: utc)
        let line = HealthLine(
            window: window,
            dispatch: control,
            build: DiagnosticsPayload.Build(version: "0.0.1.412", sha: "9f54098"),
            appVersion: "0.0.1.400",
            lastUpdate: nil,
            counts: HealthLine.Counts(inProgress: 2, queued: 3, needYou: 1)
        )
        XCTAssertEqual(line.dispatch, "Dispatch on", "moves still go out")
        XCTAssertEqual(line.build?.text, "Symphony 0.0.1.412 · 9f54098")
        XCTAssertEqual(line.connection.text, "Symphony isn't answering · 30 s")
        XCTAssertEqual(line.connection.status, .problem)
        XCTAssertFalse(line.countsCurrent)
        XCTAssertEqual(line.actions, [.openLogs, .restartSymphony])
        XCTAssertEqual(
            line.accessibilityLabel,
            "Dispatch on, 2 in progress, 3 in the queue, 1 needs you, as of Symphony's last answer, "
                + "Symphony 0.0.1.412 · 9f54098, Symphony isn't answering · 30 s"
        )

        let current = HealthLine(
            window: .connected, dispatch: control, build: nil, appVersion: "", lastUpdate: nil,
            counts: HealthLine.Counts(inProgress: 2, queued: 3, needYou: 1)
        )
        XCTAssertTrue(current.countsCurrent)
        XCTAssertEqual(current.actions, [])
        XCTAssertEqual(current.accessibilityLabel, "Dispatch on, 2 in progress, 3 in the queue, 1 needs you, Symphony answering")
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

    // MARK: - The counts (TP-1498)

    func testTheCountsAreHomesBoardInProgressAndQueuedAndTheInboxsCount() throws {
        let board = HomeBoard(state: try state("home"), now: Date())
        // The Inbox's count, not the board's waiting on you group, so the line agrees with the sidebar and the Inbox.
        let counts = try XCTUnwrap(HealthLine.Counts(board: board, needYou: 5))
        func rows(_ kinds: [DesignTokens.SituationKind]) -> Int {
            board.groups.filter { kinds.contains($0.kind) }.map(\.count).reduce(0, +)
        }
        XCTAssertEqual(counts.inProgress, rows([.working, .ci, .build]))
        XCTAssertEqual(counts.queued, rows([.slot]))
        XCTAssertEqual(counts.needYou, 5)
        XCTAssertGreaterThan(counts.inProgress + counts.queued + counts.needYou, 0, "the fixture has tickets on the board")
    }

    func testTheCountsSayWhatTheyCount() {
        XCTAssertEqual(HealthLine.Counts(inProgress: 7, queued: 18, needYou: 2).texts, ["7 in progress", "18 in the queue", "2 need you"])
        XCTAssertEqual(HealthLine.Counts(inProgress: 0, queued: 0, needYou: 1).texts, ["0 in progress", "0 in the queue", "1 needs you"])
    }

    func testASymphonyWithoutTheDispatchOrderGivesNoCounts() throws {
        var board = HomeBoard(state: try state("home"), now: Date())
        board.hasOrder = false
        XCTAssertNil(HealthLine.Counts(board: board, needYou: 2))
    }

    func testTheLineReadsTheCountsAfterTheDispatchControl() {
        let line = HealthLine(
            window: .connected,
            dispatch: DispatchControl(window: .connected, paused: false, state: nil, now: Date()),
            build: DiagnosticsPayload.Build(version: "0.0.1.926", sha: "a0be0aa"),
            appVersion: "",
            lastUpdate: nil,
            counts: HealthLine.Counts(inProgress: 7, queued: 18, needYou: 2)
        )
        XCTAssertEqual(
            line.accessibilityLabel, "Dispatch on, 7 in progress, 18 in the queue, 2 need you, Symphony 0.0.1.926 · a0be0aa, Symphony answering"
        )
        let unread = HealthLine(
            window: .connected, dispatch: DispatchControl(window: .connected, paused: false, state: nil, now: Date()), build: nil,
            appVersion: "", lastUpdate: nil
        )
        XCTAssertNil(unread.counts)
        XCTAssertEqual(unread.accessibilityLabel, "Dispatch on, Symphony answering")
    }

    private func state(_ name: String) throws -> OverviewState {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/\(name)/api/v1/state.json")
        return try XCTUnwrap(OverviewState.decode(try Data(contentsOf: url)))
    }
}
