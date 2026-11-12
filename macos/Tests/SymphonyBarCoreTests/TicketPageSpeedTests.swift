import Foundation
@testable import SymphonyBarCore
import XCTest

/// How long the ticket page takes to build from a long history (TP-1478): 500 events over 15 runs, the size of a
/// ticket that went round Code Review and QA many times. The page and its timeline are rebuilt on every read the
/// Director makes while the page is open, so building them stays well inside one frame's worth of work.
final class TicketPageSpeedTests: XCTestCase {
    /// The budget for building the page and its timeline once, on the CI runner.
    static let budget: TimeInterval = 0.030

    private static let start = Date(timeIntervalSince1970: 1_793_000_000)

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// The time `seconds` after the start, as Symphony writes it: with microseconds on odd seconds, whole on even ones.
    private static func at(_ seconds: Int) -> String {
        let whole = ISO8601DateFormatter().string(from: start.addingTimeInterval(TimeInterval(seconds)))
        return seconds.isMultiple(of: 2) ? whole : whole.replacingOccurrences(of: "Z", with: ".\(String(format: "%06d", seconds * 37 % 1_000_000))Z")
    }

    private static func event(_ seq: Int, _ seconds: Int, _ type: String, title: String, payload: String = "{}") -> String {
        #"{"id": "e\#(seq)", "seq": \#(seq), "at": "\#(at(seconds))", "type": "\#(type)", "actor": {"kind": "machine"}, "#
            + #""payload": \#(payload), "summary": {"title": "\#(title)", "detail": "Event \#(seq)"}}"#
    }

    /// 15 runs of 30 events each (start, 13 steps started and completed, end, evidence and verdict; the last run still
    /// working) and 50 events of no run between them: 500 events over about three days.
    static func feed() -> Data {
        var entries: [String] = []
        var seq = 0
        var clock = 0
        func next(_ gap: Int) -> (Int, Int) {
            seq += 1
            clock += gap
            return (seq, clock)
        }
        for run in 1 ... 15 {
            for index in 0 ..< (run <= 5 ? 4 : 3) {
                let (s, t) = next(240)
                entries.append(event(s, t, index.isMultiple(of: 2) ? "phase.entered" : "rule.action", title: "Between runs \(index)"))
            }
            let live = run == 15
            let runStart = clock + 60
            var members: [String] = []
            let (s0, t0) = next(60)
            members.append(event(s0, t0, "run.started", title: "Run started", payload: #"{"model": "opus", "effort": "high"}"#))
            for step in 1 ... 13 {
                let (s1, t1) = next(90)
                members.append(event(s1, t1, "step.started", title: "Step \(step)", payload: #"{"step_id": "s\#(step)", "title": "Step \#(step)"}"#))
                let (s2, t2) = next(120)
                members.append(event(s2, t2, "step.completed", title: "Step \(step) passed",
                                     payload: #"{"step_id": "s\#(step)", "outcome": "passed", "duration_ms": 120000}"#))
            }
            let (s3, t3) = next(30)
            members.append(event(s3, t3, "evidence", title: "Evidence"))
            let (s4, t4) = next(30)
            members.append(event(s4, t4, live ? "note" : "run.ended", title: live ? "Note" : "Run ended", payload: #"{"exit": "handoff"}"#))
            let (s5, t5) = next(30)
            members.append(event(s5, t5, "verdict.recorded", title: "Verdict", payload: #"{"kind": "code_review", "outcome": "approve"}"#))
            let header = #""kind": "run", "run_id": "run-\#(run)", "run_kind": "implementation", "run_number": \#(run), "#
                + #""status": "\#(live ? "running" : "ended")", "exit": \#(live ? "null" : #""handoff""#), "#
                + #""started_at": "\#(at(runStart))", "ended_at": \#(live ? "null" : #""\#(at(t5))""#), "head": "abcdef1234567""#
            entries.append("{\(header), \"events\": [\(members.joined(separator: ", "))]}")
        }
        return Data(#"{"timeline": [\#(entries.joined(separator: ", "))], "next_since": "\#(at(clock))"}"#.utf8)
    }

    func testTheFixtureHolds500EventsOver15Runs() throws {
        let history = try XCTUnwrap(TicketEventsPayload.decode(Self.feed()))
        XCTAssertEqual(history.events.count, 500)
        XCTAssertEqual(history.runs.count, 15)
        // Every time reads, plain and fractional alike, once, when the feed is decoded.
        XCTAssertEqual(history.events.compactMap(\.date).count, 500)
        XCTAssertEqual(history.runs.values.compactMap(\.startedDate).count, 15)
        XCTAssertEqual(history.runs.values.compactMap(\.endedDate).count, 14)
    }

    func testARunRecordsTimesAreReadOnceWhenDecoded() throws {
        struct Record: Decodable { let endedAt: TicketPage.DecodedTime? }
        func decode(_ json: String) throws -> Record { try JSONDecoder().decode(Record.self, from: Data(json.utf8)) }
        XCTAssertEqual(try decode(#"{"endedAt": "2026-10-26T07:33:00Z"}"#).endedAt?.date, Date(timeIntervalSince1970: 1_792_999_980))
        XCTAssertNotNil(try decode(#"{"endedAt": "2026-10-26T07:33:00.123456Z"}"#).endedAt?.date)
        XCTAssertNil(try decode(#"{"endedAt": "not a time"}"#).endedAt?.date)
        XCTAssertNil(try decode(#"{"endedAt": null}"#).endedAt)
    }

    func testASharedFormatterIsKeptPerPatternLocaleAndTimeZone() {
        let date = Self.start
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(SharedDateFormatter.string(date, format: "HH:mm", timeZone: .gmt), "07:33")
        XCTAssertEqual(SharedDateFormatter.string(date, format: "HH:mm", timeZone: tokyo), "16:33")
        XCTAssertEqual(SharedDateFormatter.string(date, format: "HH:mm", timeZone: .gmt), "07:33")
        XCTAssertEqual(SharedDateFormatter.string(date, format: "EEE d MMM", timeZone: .gmt), "Mon 26 Oct")
        XCTAssertEqual(SharedDateFormatter.string(date, format: "MMMd", template: true, locale: SharedDateFormatter.british, timeZone: .gmt), "26 Oct")
        XCTAssertEqual(SharedDateFormatter.string(date, format: "MMMd", template: true, timeZone: .gmt), "Oct 26")
    }

    func testTheTicketPageAndItsTimelineBuildWithinTheBudget() throws {
        let history = try XCTUnwrap(TicketEventsPayload.decode(Self.feed()))
        let reference = Self.start.addingTimeInterval(3 * 86_400)
        let calendar = utc
        func build() -> (TicketPage, TimelineModel) {
            let page = TicketPage(identifier: "TP-1463", sources: TicketPage.Sources(events: history), now: reference, timeZone: calendar.timeZone)
            let timeline = TimelineModel.build(history, reference: reference, calendar: calendar)
            return (page, timeline)
        }
        // The page reads the whole history: every run and event of no run is on it.
        let (page, timeline) = build()
        XCTAssertFalse(page.timeline.isEmpty)
        XCTAssertFalse(timeline.items.isEmpty)

        // The best of five builds, so one slow moment of a shared runner doesn't fail it.
        var best = TimeInterval.infinity
        for _ in 0 ..< 5 {
            let began = Date()
            _ = build()
            best = min(best, Date().timeIntervalSince(began))
        }
        print("TicketPageSpeedTests: page and timeline built in \(String(format: "%.1f", best * 1_000)) ms (budget \(Int(Self.budget * 1_000)) ms)")
        XCTAssertLessThan(best, Self.budget, "Building the ticket page and its timeline took \(Int(best * 1_000)) ms")
    }
}
