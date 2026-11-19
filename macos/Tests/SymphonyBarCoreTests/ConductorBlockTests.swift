@testable import SymphonyBarCore
import XCTest

/// The blocks of a Conductor message, read from the `blocks` of a `conductor.update`: each type's fields, and that a block
/// that does not read is skipped without failing the rest.
final class ConductorBlockTests: XCTestCase {
    private func blocks(_ json: String) throws -> [ConductorBlock] {
        let page = #"{"timeline":[{"id":"u1","at":"2026-10-08T09:00:00Z","type":"conductor.update","payload":{"text":"Words.","blocks":\#(json)},"artifacts":[],"children":[]}]}"#
        let history = try XCTUnwrap(TicketEventsPayload.decode(Data(page.utf8)))
        return try XCTUnwrap(ConductorMessage(event: history.events[0])).blocks
    }

    func testStepsReadTheirRowsAndSkipOneWithoutAName() throws {
        let read = try blocks(#"[{"type":"steps","run_id":"r1","run_kind":"rework","steps":[{"step_id":"code","title":"Write the code","outcome":"passed","duration_ms":180000},{"step_id":"build","title":"Build","outcome":"failed","returns_to":"Write the code"},{"outcome":"passed"},{"step_id":"lint","outcome":"skipped"}]}]"#)
        guard case let .steps(steps)? = read.first else { return XCTFail("\(read)") }
        XCTAssertEqual(steps.runID, "r1")
        XCTAssertEqual(steps.steps.map(\.title), ["Write the code", "Build", "lint"], "a step with no title falls back to its id; none at all is skipped")
        XCTAssertEqual(steps.steps[0].durationMs, 180_000)
        XCTAssertEqual(steps.steps[1].outcome, .failed)
        XCTAssertEqual(steps.steps[1].returnsTo, "Write the code")
        XCTAssertEqual(steps.steps[2].outcome, .skipped)
    }

    func testEvidenceReadsItsScreenshotsAsTheTimelineDrawsThem() throws {
        let read = try blocks(#"[{"type":"evidence","items":[{"event_id":"e1","artifact_id":"abc","caption":"Strip at 1440"},{"event_id":"e2"},{"artifact_id":"def"}]}]"#)
        guard case let .evidence(evidence)? = read.first else { return XCTFail("\(read)") }
        XCTAssertEqual(evidence.items.map(\.artifactID), ["abc", "def"])
        XCTAssertEqual(evidence.items[0].screenshot, TicketScreenshot(id: "abc", label: "Strip at 1440", path: "api/v1/artifacts/abc", available: true))
        XCTAssertEqual(evidence.items[1].screenshot.label, "Screenshot")
    }

    func testBudgetReadsItsCapAndPartsAndWorksOutWhatIsLeft() throws {
        let read = try blocks(#"[{"type":"budget","tokens_used":62000000,"tokens_cap":100000000,"parts":[{"kind":"qa","runs":2,"tokens":26000000},{"kind":"implementation","runs":3,"tokens":21000000},{"runs":1}]}]"#)
        guard case let .budget(budget)? = read.first else { return XCTFail("\(read)") }
        XCTAssertEqual(budget.parts.map(\.kind), ["qa", "implementation"])
        XCTAssertEqual(budget.tokensLeft, 38_000_000)
        XCTAssertEqual(budget.percent, 62)
        guard case let .budget(uncapped)? = try blocks(#"[{"type":"budget","tokens_used":5,"parts":[]}]"#).first else { return XCTFail() }
        XCTAssertNil(uncapped.tokensCap)
        XCTAssertNil(uncapped.tokensLeft)
        XCTAssertNil(uncapped.percent)
        XCTAssertEqual(try blocks(#"[{"type":"budget","parts":[]}]"#), [], "without its tokens it is nothing")
    }

    func testPathReadsItsStopsAndSkipsOneWithAnUnknownState() throws {
        let read = try blocks(#"[{"type":"path","stops":[{"phase":"Coding","state":"done","times":1},{"phase":"QA","state":"failed","times":2},{"phase":"Rework","state":"current","times":1,"run_number":2},{"phase":"Merge","state":"upcoming"},{"phase":"X","state":"sideways"}],"loops":1,"elapsed_ms":11520000}]"#)
        guard case let .path(path)? = read.first else { return XCTFail("\(read)") }
        XCTAssertEqual(path.stops.map(\.phase), ["Coding", "QA", "Rework", "Merge"])
        XCTAssertEqual(path.stops[1].times, 2)
        XCTAssertEqual(path.stops[2].runNumber, 2)
        XCTAssertEqual(path.stops[3].times, 1)
        XCTAssertEqual(path.loops, 1)
        XCTAssertEqual(path.elapsedMs, 11_520_000)
    }

    func testAttemptsReadTheirTriesAndWhetherTheyRepeat() throws {
        let read = try blocks(#"[{"type":"attempts","run_id":"r1","step_id":"build","title":"Build","same_line":true,"tries":[{"at":"2026-10-08T09:02:30Z","outcome":"failed","duration_ms":15000,"line":"a.swift:443: error"},{"at":"2026-10-08T09:04:45Z","outcome":"failed"}]}]"#)
        guard case let .attempts(attempts)? = read.first else { return XCTFail("\(read)") }
        XCTAssertTrue(attempts.sameLine)
        XCTAssertEqual(attempts.title, "Build")
        XCTAssertEqual(attempts.tries.count, 2)
        XCTAssertNotNil(attempts.tries[0].at)
        XCTAssertEqual(attempts.tries[0].line, "a.swift:443: error")
        XCTAssertNil(attempts.tries[1].line)
        XCTAssertTrue(attempts.tries[1].failed)
        guard case let .attempts(plain)? = try blocks(#"[{"type":"attempts","step_id":"b","tries":[{"outcome":"passed"}]}]"#).first else { return XCTFail() }
        XCTAssertFalse(plain.sameLine)
        XCTAssertFalse(plain.tries[0].failed)
        XCTAssertEqual(try blocks(#"[{"type":"attempts","step_id":"b","tries":[]}]"#), [])
    }

    func testCompareReadsATextOrAScreenshotOnEachSide() throws {
        let read = try blocks(#"[{"type":"compare","expected":{"text":"Needs a fix"},"actual":{"event_id":"e2","artifact_id":"abc"}}]"#)
        XCTAssertEqual(read, [.compare(.init(expected: .text("Needs a fix"), actual: .screenshot(artifactID: "abc", eventID: "e2")))])
        XCTAssertEqual(try blocks(#"[{"type":"compare","expected":{"text":"a"}}]"#), [], "a side missing is no compare")
        XCTAssertEqual(try blocks(#"[{"type":"compare","expected":{"text":"a"},"actual":{}}]"#), [])
    }

    func testFindingsReadTheirStatesAndCounts() throws {
        let read = try blocks(#"[{"type":"findings","open":1,"resolved":2,"items":[{"id":"f1","title":"Row reads Next in line","state":"open","severity":"high"},{"id":"f2","title":"Duplicate","state":"resolved"},{"title":"Third","state":"resolved"},{"id":"f4"}]}]"#)
        guard case let .findings(findings)? = read.first else { return XCTFail("\(read)") }
        XCTAssertEqual(findings.items.map(\.resolved), [false, true, true])
        XCTAssertEqual(findings.items[0].severity, "high")
        XCTAssertEqual(findings.open, 1)
        XCTAssertEqual(findings.resolved, 2)
        guard case let .findings(counted)? = try blocks(#"[{"type":"findings","items":[{"title":"A","state":"open"}]}]"#).first else { return XCTFail() }
        XCTAssertEqual(counted.open, 1)
        XCTAssertEqual(counted.resolved, 0)
    }

    func testEpicReadsItsRowsAndWhichIsCurrent() throws {
        let read = try blocks(#"[{"type":"epic","identifier":"TP-1381","title":"Phase 3b","rows":[{"identifier":"TP-1499","title":"Home","state":"done","current":false},{"identifier":"TP-1500","title":"Initiatives","state":"in_review","current":true},{"title":"No id"}]}]"#)
        guard case let .epic(epic)? = read.first else { return XCTFail("\(read)") }
        XCTAssertEqual(epic.rows.map(\.identifier), ["TP-1499", "TP-1500"])
        XCTAssertEqual(epic.rows.map(\.current), [false, true])
        XCTAssertEqual(epic.title, "Phase 3b")
        XCTAssertEqual(try blocks(#"[{"type":"epic","rows":[]}]"#), [])
    }

    func testQuestionReadsItsDecisionAndOptions() throws {
        let read = try blocks(#"[{"type":"question","decision_id":"d1","title":"Stop the run?","question":"Stop Rework run 2?","options":[{"label":"Stop","recommended":true},{"label":"Let it run"},{"recommended":true}]}]"#)
        guard case let .question(question)? = read.first else { return XCTFail("\(read)") }
        XCTAssertEqual(question.decisionID, "d1")
        XCTAssertEqual(question.options.map(\.label), ["Stop", "Let it run"])
        XCTAssertEqual(question.options.map(\.recommended), [true, false])
        XCTAssertEqual(try blocks(#"[{"type":"question","title":"No id"}]"#), [])
    }

    func testAnUnknownOrBrokenBlockIsSkippedAndTheOthersStay() throws {
        let read = try blocks(#"[{"type":"hologram","x":1},"steps",7,null,{"type":"budget","tokens_used":"lots"},{"type":"findings","items":"none"},{"type":"epic","identifier":"E","rows":[{"identifier":"A-1"}]},{"no_type":true}]"#)
        XCTAssertEqual(read.count, 1)
        guard case .epic? = read.first else { return XCTFail("\(read)") }
    }

    func testBlocksThatAreNotAListAreNone() throws {
        XCTAssertEqual(try blocks(#""steps""#), [])
        XCTAssertEqual(try blocks(#"{"type":"budget"}"#), [])
        XCTAssertEqual(try blocks("null"), [])
        XCTAssertEqual(try blocks("[]"), [])
    }

    func testAMessageWithoutBlocksHasNone() throws {
        let page = #"{"timeline":[{"id":"u1","at":"2026-10-08T09:00:00Z","type":"conductor.update","payload":{"text":"Words."},"artifacts":[],"children":[]}]}"#
        let history = try XCTUnwrap(TicketEventsPayload.decode(Data(page.utf8)))
        XCTAssertEqual(try XCTUnwrap(ConductorMessage(event: history.events[0])).blocks, [])
    }

    // MARK: - The run path's one line

    private func stop(_ phase: String, _ state: ConductorBlock.Path.Stop.State, times: Int = 1, run: Int? = nil) -> ConductorBlock.Path.Stop {
        .init(phase: phase, state: state, times: times, runNumber: run)
    }

    func testThePathShowsTheLastEndedTheCurrentAndTheNextAndFoldsTheRest() {
        let path = ConductorBlock.Path(stops: [
            stop("Backlog", .done), stop("Todo", .done), stop("Coding", .done), stop("QA", .failed, times: 2), stop("Rework", .current, run: 2),
            stop("QA", .upcoming), stop("Merge", .upcoming),
        ], loops: 1, elapsedMs: 11_520_000)
        let reading = ConductorPathReading(path)
        XCTAssertEqual(reading.lastEnded?.phase, "QA")
        XCTAssertEqual(reading.current?.phase, "Rework")
        XCTAssertEqual(reading.next?.phase, "QA")
        XCTAssertEqual(reading.earlier.map(\.phase), ["Backlog", "Todo", "Coding"])
        XCTAssertEqual(reading.later.map(\.phase), ["Merge"])
        XCTAssertEqual(reading.earlierText, "✓ 3 earlier")
        XCTAssertEqual(reading.laterText, "+1")
        XCTAssertEqual(reading.loopsLine, "1 loop through QA and rework · 3 h 12 min")
        XCTAssertEqual(ConductorPathReading.name(reading.lastEnded!), "QA ×2")
        XCTAssertEqual(ConductorPathReading.name(reading.current!), "Rework · run 2")
        XCTAssertEqual(reading.help, "Earlier: Backlog, done, Todo, done, Coding, done\nLater: Merge, upcoming")
        XCTAssertTrue(reading.accessibilityLabel.hasPrefix("Run path: Backlog, done; Todo, done"))
        XCTAssertTrue(reading.accessibilityLabel.contains("Merge, upcoming"), "the folded stops are read too")
    }

    func testAFailedEarlierStopMakesTheLeadingCountSayNoCheck() {
        let reading = ConductorPathReading(.init(stops: [
            stop("Coding", .done), stop("QA", .failed), stop("Rework", .done), stop("QA", .current), stop("Merge", .upcoming),
        ], loops: 0, elapsedMs: nil))
        XCTAssertEqual(reading.earlier.map(\.phase), ["Coding", "QA"])
        XCTAssertTrue(reading.earlierFailed)
        XCTAssertEqual(reading.earlierText, "2 earlier")
        XCTAssertNil(reading.laterText)
        XCTAssertNil(reading.loopsLine, "no loops, no line")
    }

    func testAShortPathFoldsNothing() {
        let reading = ConductorPathReading(.init(stops: [stop("Coding", .done), stop("QA", .current), stop("Merge", .upcoming)], loops: 2, elapsedMs: nil))
        XCTAssertNil(reading.earlierText)
        XCTAssertNil(reading.laterText)
        XCTAssertNil(reading.help)
        XCTAssertEqual(reading.loopsLine, "2 loops through QA and rework")
    }

    func testAPathAtItsStartOrEndHasNoLastEndedOrNoNext() {
        let start = ConductorPathReading(.init(stops: [stop("Coding", .current), stop("QA", .upcoming), stop("Merge", .upcoming)], loops: 0, elapsedMs: nil))
        XCTAssertNil(start.lastEnded)
        XCTAssertEqual(start.next?.phase, "QA")
        XCTAssertEqual(start.later.map(\.phase), ["Merge"])
        let end = ConductorPathReading(.init(stops: [stop("Coding", .done), stop("QA", .done), stop("Merge", .current)], loops: 0, elapsedMs: nil))
        XCTAssertNil(end.next)
        XCTAssertEqual(end.earlier.map(\.phase), ["Coding"])
    }

    func testAPathWithNoCurrentStopShowsWhereItStoppedAndWhatIsNext() {
        let reading = ConductorPathReading(.init(stops: [stop("Coding", .done), stop("QA", .done), stop("Merge", .upcoming)], loops: 0, elapsedMs: nil))
        XCTAssertNil(reading.current)
        XCTAssertEqual(reading.lastEnded?.phase, "QA")
        XCTAssertEqual(reading.next?.phase, "Merge")
        XCTAssertEqual(reading.earlier.map(\.phase), ["Coding"])
    }
}
