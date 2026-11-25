import Foundation
import XCTest
@testable import SymphonyBarCore

/// The facts a ticket's events carry in a fixed shape (TP-1683), read from the server's own answer: the Elixir
/// controller test writes the facts fixture from Symphony's events, and this test decodes that same file.
@MainActor
final class TicketFactsTests: XCTestCase {
    private let reference = TicketPage.date("2026-10-18T11:20:00Z")!
    private let picture = "7763409689b96f805ef476477c10d809e7c5e3b42df5f4ceb05f69833bb1582d"

    static func factsFeed() throws -> Data {
        let feed = TicketEventsTests.director("ticket-facts").appendingPathComponent("api/v1/repos/web-shop/tickets/SHOP-410/events.json")
        return try Data(contentsOf: feed)
    }

    private func event(_ payload: TicketEventsPayload, _ id: String) throws -> TicketEventsPayload.Event {
        try XCTUnwrap(payload.events.first { $0.id == id }, "the fixture holds \(id)")
    }

    private func steps(_ payload: TicketEventsPayload) -> [TicketPage.Step] {
        payload.steps(reference: reference) { _ in "" }
    }

    // MARK: - The server's answer

    func testAPictureIsItsEvidencesScreenshotWithItsAddress() throws {
        let payload = try XCTUnwrap(TicketEventsPayload.decode(Self.factsFeed()))
        let facts = try event(payload, "fx-10").facts

        XCTAssertEqual(facts.pictures, [
            TicketPicture(
                caption: "Settings after the relaunch, filter still Failed", step: "1",
                screenshot: TicketScreenshot(id: picture, label: "Settings after the relaunch", path: "api/v1/artifacts/\(picture)", available: true)
            ),
        ])
        XCTAssertEqual(try event(payload, "fx-10").payload.environment, "fixture")
        // The fixture keeps the picture's bytes at its address.
        let bytes = try Data(contentsOf: TicketEventsTests.director("ticket-facts").appendingPathComponent("api/v1/artifacts/\(picture).png"))
        XCTAssertEqual(Array(bytes.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        // Evidence that carries no file has no picture.
        XCTAssertEqual(try event(payload, "fx-11").facts.pictures, [])
    }

    func testAMeasurementIsItsNameNumberAndUnit() throws {
        let payload = try XCTUnwrap(TicketEventsPayload.decode(Self.factsFeed()))

        XCTAssertEqual(try event(payload, "fx-11").facts.measures, [
            TicketMeasure(name: "Window width", value: 1440, unit: "pt", expected: 1440),
            TicketMeasure(name: "Filter restored after launch", value: 0.42, unit: "s", expected: nil),
        ])
    }

    func testAStepsAnswerIsItsResultOrEachWalkedStepsResultWithTheirMeasures() throws {
        let payload = try XCTUnwrap(TicketEventsPayload.decode(Self.factsFeed()))

        let evidence = try XCTUnwrap(try event(payload, "fx-10").facts.answer?.result)
        XCTAssertEqual(evidence.status, "pass")
        XCTAssertEqual(evidence.expected, "The filter is still Failed after a relaunch")
        XCTAssertEqual(evidence.actual, "It is Failed")

        let check = try XCTUnwrap(try event(payload, "fx-12").facts.answer?.result)
        XCTAssertEqual(check.judgement, .done)
        XCTAssertEqual(check.measures, [TicketMeasure(name: "Rows shown", value: 3, unit: "rows", expected: 3)])

        let walk = try XCTUnwrap(try event(payload, "fx-14").facts.answer)
        XCTAssertNil(walk.result)
        XCTAssertEqual(walk.results.map(\.step), [2, 3])
        XCTAssertEqual(walk.results.map(\.state), [.done, .failed])
        XCTAssertEqual(walk.results[1].result.expected, "The filter menu names the filter")
        XCTAssertEqual(walk.results[1].result.measures, [TicketMeasure(name: "Menu label width", value: 0, unit: "pt", expected: 80)])
        XCTAssertEqual(walk.judgement, .failed)
    }

    func testAReviewVerdictCarriesItsFindingsWithTheirFilesAndLines() throws {
        let payload = try XCTUnwrap(TicketEventsPayload.decode(Self.factsFeed()))
        let verdict = try event(payload, "fx-06")

        XCTAssertEqual(verdict.payload.kind, "code_review")
        XCTAssertEqual(verdict.payload.outcome, "rework")
        XCTAssertEqual(verdict.facts.findings, [
            ReviewFinding(
                summary: "The filter is read before the settings load, so a relaunch shows All.", file: "lib/web_shop/settings.ex",
                lineRange: .init(start: 42, end: 47), quotedSnippet: "filter = settings.filter || :all",
                suggestedFix: "Read the filter once the settings have loaded."
            ),
            ReviewFinding(
                summary: "The default filter is not the one D1 chose.", file: "lib/web_shop/filter.ex", lineRange: .init(start: 9, end: 9),
                quotedSnippet: "@default :all", suggestedFix: "Default to :failed, as D1 says.", decision: "D1", sinceLastReview: .unchanged
            ),
        ])
        // QA's verdict has no code review findings.
        XCTAssertEqual(try event(payload, "fx-15").facts.findings, [])
    }

    func testARunsChangesAreItsFilesAndItsCommits() throws {
        let payload = try XCTUnwrap(TicketEventsPayload.decode(Self.factsFeed()))
        let changes = try XCTUnwrap(try event(payload, "fx-04").facts.changes)

        XCTAssertEqual(changes.startHead, "aaa1111")
        XCTAssertEqual(changes.head, "bbb2222")
        XCTAssertEqual(changes.commits, [
            .init(sha: "c0ffee1a2b3c4d5e6f708192a3b4c5d6e7f80912", subject: "Keep the filter in settings"),
            .init(sha: "bbb2222aa41f00d", subject: "Restore the filter at launch"),
        ])
        XCTAssertEqual(changes.files, [
            .init(path: "lib/web_shop/filter.ex", status: .added),
            .init(path: "lib/web_shop/settings.ex", status: .modified),
            .init(path: "lib/web_shop/tab.ex", status: .renamed, from: "lib/web_shop/pane.ex"),
        ])
        // The list was cut: three commits, two listed.
        XCTAssertEqual(changes.commitCount, 3)
        XCTAssertEqual(changes.fileCount, 3)
        // The run's other events change nothing.
        XCTAssertNil(try event(payload, "fx-03").facts.changes)
    }

    func testTheFactsFixturesTimelineBuildsAndEveryOtherEventCarriesNoFact() throws {
        let payload = try XCTUnwrap(TicketEventsPayload.decode(Self.factsFeed()))

        XCTAssertEqual(steps(payload).compactMap(\.runID), ["run-impl-1", "run-review-1", "run-qa-1"])
        let withFacts = payload.events.filter { !$0.facts.isEmpty }.map(\.id)
        XCTAssertEqual(withFacts, ["fx-04", "fx-06", "fx-10", "fx-11", "fx-12", "fx-14"])
    }

    // MARK: - Older shapes

    func testAnEventInAnOlderShapeStillDecodesAndThePageStillBuilds() throws {
        let feed = """
        {"timeline": [
          {"id": "o1", "seq": 1, "at": "2026-10-18T10:01:00Z", "type": "evidence",
           "payload": {"caption": "Old evidence", "artifacts": ["x"], "status": "pass", "details": "kept in text", "step": 2},
           "artifacts": [{"id": "a1", "kind": "screenshot", "label": "Shot", "url": null}]},
          {"id": "o2", "seq": 2, "at": "2026-10-18T10:02:00Z", "type": "evidence",
           "payload": {"caption": "Odd measures", "measures": [{"name": "Width", "value": "wide", "unit": "pt"}, {"name": "No unit", "value": 3},
                                                               {"name": "Height", "value": 900, "unit": "pt", "expected": "900"}, 7]}},
          {"id": "o3", "seq": 3, "at": "2026-10-18T10:03:00Z", "type": "verdict.recorded",
           "payload": {"kind": "code_review", "outcome": "rework", "details": {"missed": ["old"]}}},
          {"id": "o4", "seq": 4, "at": "2026-10-18T10:04:00Z", "type": "verdict.recorded",
           "payload": {"kind": "code_review", "outcome": "rework", "findings": [
             "a finding in text", {"file": "lib/a.ex", "line_range": "12-14", "since_last_review": "moved", "quoted_snippet": "  keep(indent)\\n"},
             {"line_range": {"start": 1, "end": 2}}]}},
          {"id": "o5", "seq": 5, "at": "2026-10-18T10:05:00Z", "type": "run.changed",
           "payload": {"run_id": "r1", "files": {"path": "a"}, "commits": "abc"}},
          {"id": "o6", "seq": 6, "at": "2026-10-18T10:06:00Z", "type": "run.changed",
           "payload": {"run_id": "r1", "start_head": "aaa", "head": 7, "commits": [{"subject": "no sha"}, {"sha": "abc"}],
                       "files": [{"path": "b", "status": "copied"}, {"status": "added"}, {"path": "c"}], "commit_count": "many"}},
          {"id": "o7", "seq": 7, "at": "2026-10-18T10:07:00Z", "type": "step.completed",
           "payload": {"step_id": "check", "title": "Check", "mode": "orchestrated", "outcome": "passed",
                       "result": {"status": "pass", "measures": "fast"}, "results": [{"step": 1, "status": "fail", "measures": [{"value": 1}]}]}},
          {"id": "o8", "seq": 8, "at": "2026-10-18T10:08:00Z", "type": "evidence", "payload": "not a map"}
        ]}
        """
        let payload = try XCTUnwrap(TicketEventsPayload.decode(Data(feed.utf8)))
        XCTAssertEqual(payload.events.map(\.id), ["o1", "o2", "o3", "o4", "o5", "o6", "o7", "o8"])

        // An evidence written before: its picture reads, its step of another type is nothing, its status stays text.
        let old = try event(payload, "o1").facts
        XCTAssertEqual(old.pictures, [
            TicketPicture(caption: "Old evidence", step: nil, screenshot: TicketScreenshot(id: "a1", label: "Shot", path: "api/v1/artifacts/a1", available: true)),
        ])
        XCTAssertNil(old.answer)
        XCTAssertEqual(old.measures, [])

        // A measure missing its number or unit, or not a map, is left out; an expected of another type is nothing.
        XCTAssertEqual(try event(payload, "o2").facts.measures, [TicketMeasure(name: "Height", value: 900, unit: "pt", expected: nil)])

        // A verdict from before findings were fields has none; a finding in text or with no summary and no file is
        // left out, and a line range of another type or an unknown word is nothing more than that.
        XCTAssertEqual(try event(payload, "o3").facts.findings, [])
        XCTAssertEqual(try event(payload, "o4").facts.findings, [
            ReviewFinding(file: "lib/a.ex", lineRange: nil, quotedSnippet: "  keep(indent)\n", sinceLastReview: .unknown("moved")),
        ])

        // Changes of another shape are none; a commit without its sha, a file without its path are left out, an
        // unknown status is kept as unknown, and a count of another type reads as the list's.
        XCTAssertNil(try event(payload, "o5").facts.changes)
        let changes = try XCTUnwrap(try event(payload, "o6").facts.changes)
        XCTAssertEqual(changes.startHead, "aaa")
        XCTAssertNil(changes.head)
        XCTAssertEqual(changes.commits, [.init(sha: "abc")])
        XCTAssertEqual(changes.files, [.init(path: "b", status: .unknown("copied")), .init(path: "c", status: .unknown(""))])
        XCTAssertEqual(changes.commitCount, 1)
        XCTAssertEqual(changes.fileCount, 2)

        // A step answer whose measures are of another shape keeps its status and has no measures.
        let answer = try XCTUnwrap(try event(payload, "o7").facts.answer)
        XCTAssertEqual(answer.result?.status, "pass")
        XCTAssertEqual(answer.result?.measures, [])
        XCTAssertEqual(answer.results.first?.result.measures, [])

        XCTAssertTrue(try event(payload, "o8").facts.isEmpty)

        // The timeline builds from the feed that holds them: one row each.
        XCTAssertEqual(steps(payload).count, 8)
    }

    func testTheSharedFeedFromBeforeTheseFactsStillReadsWithNoneButItsScreenshots() throws {
        let payload = try TicketEventsTests.sharedPayload()

        for event in payload.events {
            let facts = event.facts
            XCTAssertEqual(facts.measures, [], event.id)
            XCTAssertEqual(facts.findings, [], event.id)
            XCTAssertNil(facts.changes, event.id)
        }
        XCTAssertFalse(steps(payload).isEmpty)
    }
}
