@testable import SymphonyBarCore
import XCTest

/// The notes Symphony wrote for a run's steps before the steps carried their answers, and the answers now on the steps
/// of every run kind, from `Tests/Fixtures/timeline/step-answers.json`.
final class MachineNoteTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/timeline/step-answers.json")

    private let reference = ISO8601DateFormatter().date(from: "2026-10-08T10:00:00Z")!

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func history() throws -> TicketEventsPayload { try XCTUnwrap(TicketEventsPayload.decode(Data(contentsOf: Self.fixture))) }

    // MARK: - The predicate

    func testAnyRunKindsStepAnswerNoteIsMachineWritten() {
        for kind in ["implementation", "rework", "code_review", "ci_fix", "landing", "breakdown", "epic_review", "qa", nil] as [String?] {
            XCTAssertTrue(MachineNote.isMachineWritten(#"The Write the code step answered: {"summary":"x"}"#, runKind: kind), "\(kind ?? "nil")")
            XCTAssertTrue(MachineNote.isMachineWritten(#"The Review step answered: [{"a":1}]"#, runKind: kind))
        }
    }

    func testTheMachinePrefixMustMatchExactly() {
        for note in [
            "The Write the code step answered: it went well",
            "The Write the code step answered:{",
            "the Write the code step answered: {",
            "I think The Write the code step answered: {",
            "The step answered: {",
            "Tests: the Write the code step answered: {",
            "The code step answered fine: {",
            #"The Write the code step answered {"a":1}"#,
            "",
        ] {
            XCTAssertFalse(MachineNote.isMachineWritten(note, runKind: "implementation"), note)
        }
    }

    func testTheQAShapesOnlyCountInAQARun() {
        let shapes = [
            "Check: Row: failed. Expected: A row. Actual: none.",
            "The QA review asked for a recheck of 2 checks",
            "The Verdict step of the QA pass gave no answer Symphony takes.",
        ]
        for shape in shapes {
            XCTAssertTrue(MachineNote.isMachineWritten(shape, runKind: "qa"), shape)
            XCTAssertFalse(MachineNote.isMachineWritten(shape, runKind: "implementation"), shape)
            XCTAssertFalse(MachineNote.isMachineWritten(shape, runKind: nil), shape)
        }
        XCTAssertFalse(MachineNote.isMachineWritten("QA found the row fine. Expected nothing more.", runKind: "qa"))
    }

    func testAPersonsOrAnAgentsOwnNoteIsNeverHidden() throws {
        func hidden(_ note: String, actor: String?) throws -> Bool {
            let who = actor.map { #","actor":{"kind":"\#($0)"}"# } ?? ""
            let page = #"{"timeline":[{"kind":"run","run_id":"r1","run_kind":"implementation","status":"ended","events":[{"id":"n1","at":"2026-10-08T09:01:00Z","type":"note","run_id":"r1"\#(who),"payload":{"text":"\#(note)"},"artifacts":[],"children":[]}]}]}"#
            let history = try XCTUnwrap(TicketEventsPayload.decode(Data(page.utf8)))
            return TimelineModel.isMachineNote(history.events[0], history: history)
        }
        XCTAssertTrue(try hidden("The Code step answered: {}", actor: nil))
        XCTAssertTrue(try hidden("The Code step answered: {}", actor: "machine"))
        XCTAssertFalse(try hidden("The Code step answered: {}", actor: "person"), "a person's note, even in the machine's words")
        XCTAssertFalse(try hidden("The build is red; I checked the Code step.", actor: "agent"))
        XCTAssertFalse(try hidden("Remember to check dark mode.", actor: nil))
    }

    func testANoteUnderNoRunOrAnUnknownRunStays() throws {
        let page = #"{"timeline":[{"id":"n2","at":"2026-10-08T09:01:00Z","type":"note","payload":{"text":"The Code step answered: {}"},"artifacts":[],"children":[]},{"id":"n3","at":"2026-10-08T09:02:00Z","type":"note","run_id":"gone","payload":{"text":"The Code step answered: {}"},"artifacts":[],"children":[]}]}"#
        let history = try XCTUnwrap(TicketEventsPayload.decode(Data(page.utf8)))
        XCTAssertEqual(history.events.map { TimelineModel.isMachineNote($0, history: history) }, [false, false])
    }

    func testTheOldNoteFoldsBehindShowAllEvents() throws {
        let model = TimelineModel.build(try history(), reference: reference, calendar: utc)
        XCTAssertNil(model.showing(allEvents: false).items.first { $0.id == "entry-a7" })
        XCTAssertNotNil(model.showing(allEvents: true).items.first { $0.id == "entry-a7" })
    }

    // MARK: - Answers on the steps

    func testAnAnswerReadsItsEntriesAndCapsThemAtTwelve() throws {
        func answer(_ list: String) throws -> StepAnswer? {
            let page = #"{"timeline":[{"kind":"run","run_id":"r1","run_kind":"rework","status":"ended","events":[{"id":"e1","at":"2026-10-08T09:01:00Z","type":"step.completed","run_id":"r1","payload":{"step_id":"c","outcome":"passed","answer":\#(list)},"artifacts":[],"children":[]}]}]}"#
            return try XCTUnwrap(TicketEventsPayload.decode(Data(page.utf8))).events[0].payload.answer
        }
        let read = try XCTUnwrap(answer(#"[{"label":"Summary","value":"Done.\nTwo lines."},{"label":"No value"},{"value":"no label"},"text",{"label":"Tests","value":"4"}]"#))
        XCTAssertEqual(read.entries, [.init(label: "Summary", value: "Done.\nTwo lines."), .init(label: "Tests", value: "4")])
        let many = (1...15).map { #"{"label":"L\#($0)","value":"v"}"# }.joined(separator: ",")
        XCTAssertEqual(try answer("[\(many)]")?.entries.count, 12)
        XCTAssertNil(try answer("[]"))
        XCTAssertNil(try answer(#""not a list""#))
        XCTAssertNil(try answer("[7, null]"))
    }

    func testAStepWithAnAnswerOrALongReasonCanUnfoldAndAShortReasonStaysInItsRow() throws {
        let run = try XCTUnwrap(RunGroupModel.groups(history(), reference: reference).first)
        XCTAssertEqual(run.steps.map(\.title), ["Write the code", "Tests"])
        XCTAssertEqual(run.steps[0].answer?.entries.count, 3)
        XCTAssertTrue(run.steps[0].canUnfold)
        XCTAssertTrue(run.steps[1].hasLongReason)
        XCTAssertTrue(run.steps[1].canUnfold)
        XCTAssertTrue(try XCTUnwrap(run.steps[1].reason).hasPrefix("The tests failed"), "the row's own reason place")
        var short = RunStep(id: "a", stepID: "a", title: "A", state: .failed)
        short.reasonDetail = "The build failed"
        XCTAssertFalse(short.hasLongReason)
        XCTAssertFalse(short.canUnfold)
    }

    func testARunsOwnReasonAndAnswerOnItsEndShowInItsHeaderDetail() throws {
        let run = try XCTUnwrap(RunGroupModel.groups(history(), reference: reference).first)
        XCTAssertEqual(run.endReason, "The Tests step failed twice")
        XCTAssertEqual(run.endAnswer?.entries, [.init(label: "Handoff", value: "Not handed off")])
        XCTAssertTrue(try XCTUnwrap(run.meta).hasSuffix("The Tests step failed twice"))
        XCTAssertEqual(run.meta, "Claude Opus 5.5 · 14 min · 1.8M tokens · The Tests step failed twice")
    }
}
