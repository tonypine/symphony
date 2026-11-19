@testable import SymphonyBarCore
import XCTest

/// The Conductor speaking, from `Tests/Fixtures/timeline/conductor-watch.json`: a message at a junction is an entry of
/// the timeline; what it said while it watched a run is drawn inside that run's group, after the last step that started
/// before it; a message about a run the page does not have falls back to the timeline.
final class ConductorMessageTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/timeline/conductor-watch.json")

    private let reference = ISO8601DateFormatter().date(from: "2026-10-08T10:00:00Z")!

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func model() throws -> TimelineModel {
        let history = try XCTUnwrap(TicketEventsPayload.decode(Data(contentsOf: Self.fixture)))
        return TimelineModel.build(history, reference: reference, calendar: utc)
    }

    private func event(_ payload: String, type: String = "conductor.update") throws -> TicketEventsPayload.Event {
        let json = #"{"id":"e1","seq":1,"at":"2026-10-08T09:20:00Z","type":"\#(type)","run_id":"run-c1","payload":\#(payload),"artifacts":[],"children":[]}"#
        return try JSONDecoder().decode(TicketEventsPayload.Event.self, from: Data(json.utf8))
    }

    // MARK: - The payload

    func testAPayloadWithoutAWatchIsAJunctionMessage() throws {
        let message = try XCTUnwrap(ConductorMessage(event: event(#"{"junction":"after_coding","text":" Built. "}"#), runTitle: "Conductor run 2"))
        XCTAssertEqual(message.text, "Built.")
        XCTAssertEqual(message.junction, .afterCoding)
        XCTAssertEqual(message.junctionWords, "after coding")
        XCTAssertEqual(message.runTitle, "Conductor run 2")
        XCTAssertNil(message.watch)
        XCTAssertFalse(message.actedOnRun)
        XCTAssertNil(message.watchedRunID)
    }

    func testEveryJunctionHasItsWords() {
        XCTAssertEqual(ConductorJunction.allCases.map(\.words), ["after coding", "after QA failed", "after rework", "before merge"])
    }

    func testAnUnknownJunctionHasNoWords() throws {
        let message = try XCTUnwrap(ConductorMessage(event: event(#"{"junction":"somewhere_new","text":"Hello."}"#)))
        XCTAssertNil(message.junction)
        XCTAssertNil(message.junctionWords)
    }

    func testAWatchPayloadReadsWhatItHas() throws {
        let message = try XCTUnwrap(ConductorMessage(event: event(
            #"{"text":"Look at line 443.","watch":{"run_id":"run-2","trigger":"step_failed_twice","steered":true,"when":"next_turn","stopped":false}}"#
        )))
        XCTAssertEqual(message.watch, ConductorWatch(runID: "run-2", trigger: "step_failed_twice", steered: true, when: "next_turn", stopped: false))
        XCTAssertEqual(message.watchedRunID, "run-2")
        XCTAssertTrue(message.actedOnRun)
        XCTAssertEqual(message.watch?.action, "steered this run")
        XCTAssertEqual(message.watch?.timing, "at its next turn")
    }

    func testAWatchReadsEveryFieldAsOptional() throws {
        for (payload, expected) in [
            (#"{"text":"x","watch":{}}"#, ConductorWatch()),
            (#"{"text":"x","watch":{"run_id":7,"steered":"yes","when":3,"stopped":null,"trigger":[]}}"#, ConductorWatch()),
            (#"{"text":"x","watch":{"run_id":"r","stopped":true}}"#, ConductorWatch(runID: "r", stopped: true)),
            (#"{"text":"x","watch":{"run_id":"  "}}"#, ConductorWatch()),
        ] {
            XCTAssertEqual(try XCTUnwrap(ConductorMessage(event: event(payload))).watch, expected, payload)
        }
        // A watch that is not a map is no watch.
        XCTAssertNil(try XCTUnwrap(ConductorMessage(event: event(#"{"text":"x","watch":"run-2"}"#))).watch)
        XCTAssertNil(try XCTUnwrap(ConductorMessage(event: event(#"{"text":"x","watch":null}"#))).watch)
    }

    func testWhatTheConductorDidToTheRun() {
        XCTAssertEqual(ConductorWatch(stopped: true).action, "stopped this run")
        XCTAssertEqual(ConductorWatch(steered: true, stopped: true).action, "stopped this run")
        XCTAssertEqual(ConductorWatch(steered: true, when: "now").timing, "now")
        XCTAssertNil(ConductorWatch().action)
        XCTAssertNil(ConductorWatch(steered: true, when: "later").timing)
        XCTAssertNil(ConductorWatch(steered: true).timing)
        XCTAssertFalse(ConductorWatch(runID: "r").acted)
    }

    func testOnlyAnUpdateWithTextIsAMessage() throws {
        XCTAssertNil(ConductorMessage(event: try event(#"{"text":"  "}"#)))
        XCTAssertNil(ConductorMessage(event: try event(#"{"junction":"after_coding"}"#)))
        XCTAssertNil(ConductorMessage(event: try event(#"{"text":"Read."}"#, type: "conductor.steer")))
    }

    func testTheMessageForVoiceOverStartsWithTheConductorAndReadsThePlainWords() throws {
        let junction = try XCTUnwrap(ConductorMessage(event: event(#"{"junction":"after_qa_fail","text":"**QA found {problem}one problem{/}.**"}"#)))
        XCTAssertEqual(junction.accessibilityLabel(time: "17:44"), "Conductor, after QA failed, 17:44, QA found one problem.")
        let steered = try XCTUnwrap(ConductorMessage(event: event(#"{"text":"Look at `a.swift`.","watch":{"run_id":"r","steered":true,"when":"now"}}"#)))
        XCTAssertEqual(steered.accessibilityLabel(time: nil), "Conductor, steered this run, now, Look at a.swift.")
    }

    // MARK: - On the timeline

    func testAJunctionMessageIsAnEntryThatCarriesTheConductorsWords() throws {
        let entries = try model().items.compactMap { item -> TimelineEntry? in
            if case let .entry(entry) = item { return entry }
            return nil
        }
        let junction = try XCTUnwrap(entries.first { $0.id == "c4" })
        let message = try XCTUnwrap(junction.conductor)
        XCTAssertEqual(message.junction, .afterQAFail)
        XCTAssertEqual(message.runTitle, "Conductor run 1", "the footer's words stay with the message, for its help")
        XCTAssertEqual(junction.kind, .update)
        XCTAssertFalse(junction.isMechanical)
        XCTAssertNil(try XCTUnwrap(entries.first { $0.id == "c5" }.map(\.conductor)).flatMap(\.junction))
    }

    func testAWatchOfARunOnThePageIsNoEntryOfTheTimeline() throws {
        let ids = try model().items.compactMap { item -> String? in
            if case let .entry(entry) = item { return entry.id }
            return nil
        }
        XCTAssertEqual(Set(ids), ["c4", "c5"], "c2 and c3 are inside run-2's group")
    }

    func testAWatchOfARunThePageDoesNotHaveFallsBackToTheTimeline() throws {
        let entry = try XCTUnwrap(model().items.compactMap { item -> TimelineEntry? in
            if case let .entry(entry) = item, entry.id == "c5" { return entry }
            return nil
        }.first)
        XCTAssertEqual(entry.conductor?.text, "Watching a run this page does not have.")
        XCTAssertEqual(entry.conductor?.watchedRunID, "run-gone")
    }

    // MARK: - Inside a run

    func testWhatItSaidWhileWatchingIsInsideTheRunAfterTheLastStepThatStartedBeforeIt() throws {
        let run = try XCTUnwrap(model().run("run-2"))
        XCTAssertEqual(run.steps.map(\.title), ["Read the open findings", "Write the code", "Build", "Write the code", "Build"])
        XCTAssertEqual(run.conductorMessages.map(\.id), ["c2", "c3"])
        // 09:02:45 comes after Build (the third step); 09:04:20 after the second Write the code (it started 09:03:00).
        XCTAssertEqual(run.conductorMessages.map(\.afterStep), [2, 3])
        XCTAssertFalse(run.conductorMessages[0].message.actedOnRun)
        XCTAssertTrue(run.conductorMessages[1].message.actedOnRun)
        XCTAssertEqual(run.conductorMessages[1].message.watch?.timing, "at its next turn")
        XCTAssertEqual(run.conductorMessages[0].message.runTitle, "Conductor run 1")
    }

    func testTheConductorsOwnRunHoldsNoMessagesOfItsOwn() throws {
        XCTAssertEqual(try XCTUnwrap(model().run("run-c1")).conductorMessages, [])
    }

    func testAStepsTimePlacesAMessage() {
        func at(_ time: String) -> Date { ISO8601DateFormatter().date(from: "2026-10-08T\(time)Z")! }
        let steps = [RunStep(id: "a", stepID: "a", title: "A", state: .done), RunStep(id: "b", stepID: "b", title: "B", state: .done)]
        let spans: [Int: RunGroupModel.StepSpan] = [
            0: .init(start: at("09:00:00"), end: at("09:01:00")), 1: .init(start: at("09:02:00"), end: nil),
        ]
        XCTAssertNil(RunGroupModel.afterStep(at("08:59:59"), steps: steps, spans: spans), "before the first step")
        XCTAssertEqual(RunGroupModel.afterStep(at("09:00:00"), steps: steps, spans: spans), 0)
        XCTAssertEqual(RunGroupModel.afterStep(at("09:01:30"), steps: steps, spans: spans), 0, "between two steps")
        XCTAssertEqual(RunGroupModel.afterStep(at("09:05:00"), steps: steps, spans: spans), 1)
        XCTAssertEqual(RunGroupModel.afterStep(nil, steps: steps, spans: spans), 1, "no time: last")
        XCTAssertEqual(RunGroupModel.afterStep(at("09:05:00"), steps: steps, spans: [:]), 1, "no step times: last")
        XCTAssertNil(RunGroupModel.afterStep(at("09:05:00"), steps: [], spans: [:]))
    }

    func testASteerThatSaysTheMessagesWordsIsDroppedAndAnotherStaysItsOwnRow() throws {
        let run = try XCTUnwrap(model().run("run-2"))
        XCTAssertEqual(run.steers.map(\.id), ["r8"], "r11 says what c3 says; its delivery is c3's chip")
    }

    func testASteerWithNoMessageBesideItStays() throws {
        let history = try XCTUnwrap(TicketEventsPayload.decode(Data(contentsOf: Self.fixture)))
        let run = try XCTUnwrap(history.runs["run-2"])
        let events = history.events.filter { $0.runID == "run-2" }
        let group = RunGroupModel.group(run, events: events, reference: reference)
        XCTAssertEqual(group.steers.map(\.id), ["r8", "r11"])
        XCTAssertEqual(group.conductorMessages, [])
    }
}
