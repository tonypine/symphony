import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SymphonyBarCore

@MainActor
final class TicketEventsTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// After the fixture's last event, so the running QA run counts its time to here.
    private let reference = TicketPage.date("2026-10-18T11:20:00Z")!

    /// The feed page TP-1192's Elixir test checks in: the answer the Mac timeline decodes.
    static var sharedFixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("test/fixtures/api/ticket_events_feed.json")
    }

    static func sharedPayload() throws -> TicketEventsPayload {
        try XCTUnwrap(TicketEventsPayload.decode(Data(contentsOf: sharedFixture)))
    }

    private func clock(_ date: Date) -> String {
        StatusMenu.clockTime(date, now: reference, timeZone: utc, dateFormat: "MMM d, HH:mm")
    }

    private func steps(_ payload: TicketEventsPayload) -> [TicketPage.Step] {
        payload.steps(reference: reference, clock: clock)
    }

    // MARK: - The shared fixture

    func testDecodesTheFixtureTheElixirTestChecksIn() throws {
        let payload = try Self.sharedPayload()

        XCTAssertEqual(payload.nextSince, "2026-10-18T11:13:00.000000Z")
        XCTAssertEqual(payload.events.map(\.id), (1 ... 16).map { String(format: "ev-%02d", $0) })
        XCTAssertEqual(Set(payload.runs.keys), ["run-impl-1", "run-qa-1", "run-qa-2"])
        let qa = try XCTUnwrap(payload.runs["run-qa-1"])
        XCTAssertEqual(qa.runKind, "qa")
        XCTAssertEqual(qa.runNumber, 1)
        XCTAssertEqual(qa.status, "ended")
        XCTAssertEqual(qa.verdict?.outcome, "fail")
        XCTAssertEqual(payload.runs["run-qa-2"]?.status, "running")
        XCTAssertEqual(payload.events.first { $0.id == "ev-16" }?.parent, "ev-15")
        XCTAssertFalse(payload.isEmpty)
    }

    func testEachRunIsAGroupHoldingItsEventsBetweenTheEventsOfNoRun() throws {
        let timeline = steps(try Self.sharedPayload())

        XCTAssertEqual(timeline.map(\.title), [
            "Entered In Progress from Todo", "Implementation run 1", "Entered QA from Code Review", "QA run 1",
            "Entered Rework from QA", TicketPage.noteByYou, "Entered QA from Code Review", "QA run 2",
        ])
        XCTAssertEqual(timeline.map(\.timeText), ["10:01", "10:02", "10:30", "10:31", "10:47", "10:50", "11:10", "11:11"])
        XCTAssertEqual(timeline.filter(\.isGroup).map(\.runID), ["run-impl-1", "run-qa-1", "run-qa-2"])
        // The Director's note reads as theirs.
        XCTAssertEqual(timeline[5].detail, "Keep the run header visible when the pane is narrow.")

        let implementation = timeline[1]
        XCTAssertEqual(implementation.result, .done)
        XCTAssertEqual(implementation.resultWord, "handoff")
        XCTAssertEqual(implementation.duration, "18 min")
        // The run's start and end are its header; what happened in it is inside.
        XCTAssertEqual(implementation.children.map(\.title), ["Note added"])
    }

    func testTheFailedQARunHoldsItsFindingsWithTheirScreenshotsAndTheResultLast() throws {
        let run = try XCTUnwrap(steps(try Self.sharedPayload()).first { $0.runID == "run-qa-1" })

        XCTAssertEqual(run.title, "QA run 1")
        XCTAssertEqual(run.result, .failed)
        XCTAssertEqual(run.resultWord, "failed")
        XCTAssertEqual(run.durationSeconds, 15 * 60)
        XCTAssertEqual(run.detail, "on bbb2222")
        XCTAssertEqual(run.children.map(\.title), ["QA found clipped at 1440×900", "QA found state missing", "QA verdict: fail"])
        XCTAssertEqual(run.children.map(\.result), [.failed, .failed, .failed])
        XCTAssertEqual(run.children[0].detail, "The run header is cut off.")

        let clipped = run.children[0].screenshots
        XCTAssertEqual(clipped.map(\.label), ["Run header at 1440×900", "Run header at 1100×800"])
        XCTAssertEqual(clipped.map(\.available), [true, true])
        XCTAssertEqual(clipped[0].path, "api/v1/artifacts/1a5944804739c3246135942da82f849565310c15e861390baa8bd75677fa48b0")
        XCTAssertEqual(clipped[0].accessibilityLabel, "Screenshot Run header at 1440×900, opens full size")
        let missing = try XCTUnwrap(run.children[1].screenshots.first)
        XCTAssertFalse(missing.available)
        XCTAssertEqual(missing.unavailableAccessibilityLabel, "Screenshot Verdict badge after refresh unavailable")

        XCTAssertEqual(run.foldAccessibilityLabel(folded: false), "Collapse QA run 1, failed")
        XCTAssertEqual(run.foldAccessibilityLabel(folded: true), "Expand QA run 1, failed")
    }

    func testARunUnderWaySaysRunningWithItsRepliesNested() throws {
        let run = try XCTUnwrap(steps(try Self.sharedPayload()).last)

        XCTAssertEqual(run.title, "QA run 2")
        XCTAssertEqual(run.result, .current)
        XCTAssertEqual(run.resultWord, "running")
        // Running from 11:11 to the reference, 11:20.
        XCTAssertEqual(run.durationSeconds, 9 * 60)
        XCTAssertEqual(run.foldAccessibilityLabel(folded: true), "Expand QA run 2, running")
        XCTAssertEqual(run.children.map(\.detail), ["Walking step 1 at 1440×900."])
        XCTAssertEqual(run.children[0].children.map(\.detail), ["The run header stays visible."])
    }

    // MARK: - Merging pages

    func testANewerPageReplacesTheRunHeaderAndAddsOnlyNewEvents() throws {
        var history = try Self.sharedPayload()
        let newer = try XCTUnwrap(TicketEventsPayload.decode(Data(Self.page(
            nextSince: "2026-10-18T11:30:00Z",
            entries: [Self.run("run-qa-2", number: 2, status: "ended", exit: "ended normally", verdict: "pass", ended: "2026-10-18T11:30:00Z", events: [
                Self.event("ev-16", seq: 16, type: "note", at: "2026-10-18T11:13:00Z", run: "run-qa-2", parent: "ev-15", title: "Note added", detail: "Edited."),
                Self.event("ev-17", seq: 17, type: "verdict.recorded", at: "2026-10-18T11:29:00Z", run: "run-qa-2", title: "QA verdict: pass", payload: #"{"kind":"qa","outcome":"pass"}"#),
                Self.event("ev-18", seq: 18, type: "run.ended", at: "2026-10-18T11:30:00Z", run: "run-qa-2", title: "QA run 2 ended", payload: #"{"exit":"ended normally"}"#),
            ])]
        ).utf8)))

        XCTAssertEqual(history.merge(newer), 2)
        XCTAssertEqual(history.nextSince, "2026-10-18T11:30:00Z")
        XCTAssertEqual(history.events.count, 18)
        XCTAssertEqual(history.merge(newer), 0, "the same page twice adds nothing")

        let run = try XCTUnwrap(steps(history).last)
        XCTAssertEqual(run.resultWord, "passed")
        XCTAssertEqual(run.result, .done)
        XCTAssertEqual(run.durationSeconds, 19 * 60)
        // The verdict closes the run; the edited reply replaced its first copy, under the event it answers.
        XCTAssertEqual(run.children.map(\.title), ["Note added", "QA verdict: pass"])
        XCTAssertEqual(run.children[0].children.map(\.detail), ["Edited."])
        XCTAssertEqual(run.children[1].result, .done)
    }

    func testAReplyOnALaterPageNestsUnderTheEventItAnswers() throws {
        var history = try Self.sharedPayload()
        // Symphony places a reply whose parent is on an earlier page in its run.
        let reply = Self.event("ev-17", seq: 17, type: "note", at: "2026-10-18T11:14:00Z", run: "run-qa-2", parent: "ev-15", title: "Note added", detail: "Step 2.")
        history.merge(try XCTUnwrap(TicketEventsPayload.decode(Data(Self.page(entries: [
            Self.run("run-qa-2", number: 2, status: "running", events: [reply]),
        ]).utf8))))

        let run = try XCTUnwrap(steps(history).last)
        XCTAssertEqual(run.children.count, 1)
        XCTAssertEqual(run.children[0].children.map(\.detail), ["The run header stays visible.", "Step 2."])
    }

    func testARunGroupHoldsEveryEventAndKeepsItsIDAcrossReads() throws {
        let notes = (1 ... 40).map { index in
            Self.event("n-\(index)", seq: index + 1, type: "note", at: String(format: "2026-10-18T12:%02d:00Z", index), run: "run-impl-2", title: "Note added", detail: "Step \(index)")
        }
        let first = try XCTUnwrap(TicketEventsPayload.decode(Data(Self.page(entries: [
            Self.run("run-impl-2", kind: "implementation", number: 2, status: "running", started: "2026-10-18T12:00:00Z", events: Array(notes.prefix(20))),
        ]).utf8)))
        var history = first
        history.merge(try XCTUnwrap(TicketEventsPayload.decode(Data(Self.page(entries: [
            Self.run("run-impl-2", kind: "implementation", number: 2, status: "running", started: "2026-10-18T12:00:00Z", events: Array(notes.suffix(20))),
        ]).utf8))))

        let before = try XCTUnwrap(steps(first).first)
        let after = try XCTUnwrap(steps(history).first)
        XCTAssertEqual(after.children.count, 40)
        XCTAssertEqual(after.children.last?.detail, "Step 40")
        // The fold is kept by run id: the group's identity is the same on every read.
        XCTAssertEqual(before.id, after.id)
        XCTAssertEqual(before.runID, after.runID)
    }

    func testARunWithNoEventOnThePagesStillShowsByItsStart() throws {
        let payload = try XCTUnwrap(TicketEventsPayload.decode(Data(Self.page(entries: [
            Self.run("run-a", kind: "code_review", number: 3, status: "ended", exit: "stopped_by_director", started: "2026-10-18T09:00:00Z", events: []),
            Self.run("run-b", kind: nil, number: nil, status: "ended", started: nil, events: []),
        ]).utf8)))

        // A run that says nowhere when it started has no place on the timeline.
        XCTAssertEqual(steps(payload).map(\.title), ["Code Review run 3"])
        XCTAssertEqual(steps(payload).first?.result, .stopped)
        XCTAssertEqual(steps(payload).first?.resultWord, "stopped by director")
    }

    // MARK: - Events the app reads in its own words, and the ones it doesn't know

    func testAnEventTypeTheAppDoesntKnowShowsItsSummary() throws {
        let payload = try XCTUnwrap(TicketEventsPayload.decode(Data(Self.page(entries: [
            Self.event("x-1", seq: 1, type: "epic.lane_opened", at: "2026-10-18T09:00:00Z", title: "Lane opened for SHOP-300", detail: "2 of 8 slots",
                       payload: #"{"outcome":42,"lanes":[1,2]}"#),
            Self.event("x-2", seq: 2, type: "epic.unsummarised", at: "2026-10-18T09:01:00Z"),
        ]).utf8)))

        let timeline = steps(payload)
        XCTAssertEqual(timeline.map(\.title), ["Lane opened for SHOP-300", "epic.unsummarised"])
        XCTAssertEqual(timeline[0].detail, "2 of 8 slots")
        XCTAssertEqual(timeline.map(\.result), [.done, .done])
        XCTAssertNil(timeline[1].detail)
    }

    func testRunTitlesAndStates() {
        XCTAssertEqual(TicketEventsPayload.runTitle(kind: "qa", number: 2), "QA run 2")
        XCTAssertEqual(TicketEventsPayload.runTitle(kind: "code_review", number: 1), "Code Review run 1")
        XCTAssertEqual(TicketEventsPayload.runTitle(kind: "ci_fix", number: 4), "CI Fix run 4")
        XCTAssertEqual(TicketEventsPayload.runTitle(kind: "implementation", number: nil), "Implementation run")
        XCTAssertEqual(TicketEventsPayload.runTitle(kind: nil, number: 1), "Agent run 1")
        XCTAssertEqual(TicketEventsPayload.runTitle(kind: "", number: 1), "Agent run 1")

        let verdicts: [(String?, String)] = [
            ("qa", "pass"), ("qa", "fail"), ("qa", "skip"), ("code_review", "approve"), ("code_review", "rework"),
            ("code_review", "block"), ("epic_review", "fail"), ("epic_review", "follow_ups_filed"),
        ]
        XCTAssertEqual(verdicts.map { TicketEventsPayload.verdictState(kind: $0.0, outcome: $0.1).1 }, [
            "passed", "failed", "skipped", "approved", "sent back", "blocked", "fail", "follow ups filed",
        ])
        XCTAssertEqual(verdicts.map { TicketEventsPayload.verdictState(kind: $0.0, outcome: $0.1).0 }, [
            .done, .failed, .done, .done, .failed, .failed, .failed, .done,
        ])
        XCTAssertEqual(TicketEventsPayload.exitState(nil).1, "ended")
        XCTAssertEqual(TicketEventsPayload.exitState("  ").0, .done)
        XCTAssertEqual(TicketEventsPayload.exitState("agent_failed").0, .failed)
        XCTAssertEqual(TicketEventsPayload.exitState("Cancelled").0, .stopped)
        XCTAssertEqual(TicketEventsPayload.exitState("handoff").0, .done)
    }

    func testAnEventsResultComesFromItsTypeAndPayload() throws {
        let payload = try XCTUnwrap(TicketEventsPayload.decode(Data(Self.page(entries: [
            Self.event("e-1", seq: 1, type: "hold.set", at: "2026-10-18T09:00:00Z", title: "Blocked"),
            Self.event("e-2", seq: 2, type: "run.ended", at: "2026-10-18T09:01:00Z", run: "gone", title: "Run ended", payload: #"{"exit":"crashed"}"#),
            Self.event("e-3", seq: 3, type: "verdict.recorded", at: "2026-10-18T09:02:00Z", title: "Verdict", payload: "null"),
            Self.event("e-4", seq: 4, type: "note", at: "2026-10-18T09:03:00Z", title: "Note added", actor: #"{"kind":"agent"}"#),
        ]).utf8)))

        // A run Symphony sent no header for leaves its events at the top.
        XCTAssertEqual(steps(payload).map(\.result), [.stopped, .failed, .done, .done])
        XCTAssertEqual(steps(payload).map(\.title), ["Blocked", "Run ended", "Verdict", "Note added"])
    }

    func testAScreenshotWithoutAURLOrLabelStillReads() throws {
        let payload = try XCTUnwrap(TicketEventsPayload.decode(Data(Self.page(entries: [
            Self.event("e-1", seq: 1, type: "evidence", at: "2026-10-18T09:00:00Z", title: "Evidence",
                       artifacts: #"[{"id":"abc","mime":"image/jpeg"},{"id":"log","kind":"log","mime":"text/plain"},{"id":"rel","kind":"screenshot","url":"api/v1/artifacts/rel","label":" "}]"#),
        ]).utf8)))

        let shots = try XCTUnwrap(steps(payload).first).screenshots
        XCTAssertEqual(shots, [
            TicketScreenshot(id: "abc", label: "without a label", path: "api/v1/artifacts/abc", available: true),
            TicketScreenshot(id: "rel", label: "without a label", path: "api/v1/artifacts/rel", available: true),
        ])
    }

    func testOrdersEventsWithoutASeqByWhenTheyHappened() throws {
        let payload = try XCTUnwrap(TicketEventsPayload.decode(Data(Self.page(entries: [
            Self.event("late", seq: nil, type: "note", at: "2026-10-18T09:05:00Z", title: "Late"),
            Self.event("early", seq: nil, type: "note", at: "2026-10-18T09:01:00Z", title: "Early"),
            Self.event("same", seq: nil, type: "note", at: "2026-10-18T09:05:00Z", title: "Same time"),
            Self.event("undated", seq: nil, type: "note", at: nil, title: "Undated"),
        ]).utf8)))

        XCTAssertEqual(payload.events.map(\.id), ["early", "late", "same", "undated"])
        XCTAssertEqual(steps(payload).last?.timeText, "")
        XCTAssertEqual(payload.newestEventAt, TicketPage.date("2026-10-18T09:05:00Z"))
        XCTAssertNil(TicketEventsPayload().newestEventAt)
        XCTAssertTrue(TicketEventsPayload().isEmpty)
    }

    func testABodyThatIsntAFeedPageDoesntDecode() {
        XCTAssertNil(TicketEventsPayload.decode(Data("not json".utf8)))
        XCTAssertNil(TicketEventsPayload.decode(Data(#"{"events":[]}"#.utf8)))
        XCTAssertNil(TicketEventsPayload.decode(Data(#"{"timeline":[{"kind":"run"}]}"#.utf8)))
        XCTAssertNil(TicketEventsPayload.decode(Data(#"{"timeline":[{"type":"note"}]}"#.utf8)))
    }

    func testTheFeedsPathCarriesTheRepoTheTicketAndTheCursor() {
        XCTAssertEqual(TicketPage.eventsPath("TP-1193", repoKey: "symphony"), "api/v1/repos/symphony/tickets/TP-1193/events?group=run")
        XCTAssertEqual(
            TicketPage.eventsPath("TP-1193", repoKey: "my repo", since: "2026-10-18T11:13:00.000000+01:00", limit: 200),
            "api/v1/repos/my%20repo/tickets/TP-1193/events?group=run&limit=200&since=2026-10-18T11:13:00.000000%2B01:00"
        )
    }

    // MARK: - Screenshots

    func testAScreenshotLoadsOnceAndIsKeptByID() async throws {
        let png = try Self.png()
        var requests: [String] = []
        let images = ArtifactImages(get: { @MainActor path in
            requests.append(path)
            return .answered(png, statusCode: 200)
        })
        let shot = TicketScreenshot(id: "a", label: "A", path: "api/v1/artifacts/a", available: true)

        XCTAssertEqual(images.image(shot), .loading)
        let load = images.load(shot)
        XCTAssertNil(images.load(shot), "a screenshot being read isn't read twice")
        await load?.value
        XCTAssertEqual(images.image(shot), .loaded(png))
        XCTAssertNil(images.load(shot))
        XCTAssertEqual(requests, ["api/v1/artifacts/a"])
    }

    func testAnUnavailableScreenshotShowsThePlaceholderNeverABrokenImage() async throws {
        let answers: [String: APIAnswer] = [
            "gone": .answered(Data(), statusCode: 410),
            "missing": .answered(Data(), statusCode: 404),
            "text": .answered(Data("not an image".utf8), statusCode: 200),
            "error": .answered(Data(), statusCode: 500),
            "down": .unreachable,
        ]
        var requests: [String] = []
        let images = ArtifactImages(get: { @MainActor path in
            requests.append(path)
            return answers[path] ?? .unreachable
        })
        func shot(_ id: String, available: Bool = true) -> TicketScreenshot {
            TicketScreenshot(id: id, label: id, path: id, available: available)
        }
        let ids = ["gone", "missing", "text", "error", "down"]

        // The feed says Symphony no longer keeps it: nothing is read.
        XCTAssertNil(images.load(shot("flagged", available: false)))
        XCTAssertEqual(images.image(shot("flagged", available: false)), .unavailable)
        for id in ids { await images.load(shot(id))?.value }
        XCTAssertEqual(ids.map { images.image(shot($0)) }, [.unavailable, .unavailable, .unavailable, .failed, .failed])

        // A 404, a 410 or bytes that aren't an image stay unavailable; a failure is read again when it shows.
        for id in ids { await images.load(shot(id))?.value }
        XCTAssertEqual(requests, ids + ["error", "down"])
    }

    func testKeepsAtMostItsCapacityDroppingTheOldest() async throws {
        let png = try Self.png()
        let images = ArtifactImages(get: { _ in .answered(png, statusCode: 200) })
        for index in 0 ... ArtifactImages.capacity {
            await images.load(TicketScreenshot(id: "\(index)", label: "", path: "\(index)", available: true))?.value
        }
        XCTAssertEqual(images.images.count, ArtifactImages.capacity)
        XCTAssertNil(images.images["0"])
    }

    // MARK: - Helpers

    /// A 4×3 PNG.
    nonisolated static func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func page(nextSince: String? = nil, entries: [String]) -> String {
        #"{"next_since":\#(nextSince.map { "\"\($0)\"" } ?? "null"),"timeline":[\#(entries.joined(separator: ","))]}"#
    }

    static func run(
        _ id: String, kind: String? = "qa", number: Int?, status: String, exit: String? = nil, verdict: String? = nil,
        started: String? = "2026-10-18T11:11:00Z", ended: String? = nil, events: [String]
    ) -> String {
        func text(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }
        let verdictJSON = verdict.map { #"{"kind":"qa","outcome":"\#($0)","head":"ccc3333","at":"2026-10-18T11:29:00Z"}"# } ?? "null"
        return #"{"kind":"run","run_id":"\#(id)","run_kind":\#(text(kind)),"run_number":\#(number.map(String.init) ?? "null"),"status":"\#(status)","exit":\#(text(exit)),"verdict":\#(verdictJSON),"started_at":\#(text(started)),"ended_at":\#(text(ended)),"head":null,"summary":null,"events":[\#(events.joined(separator: ","))]}"#
    }

    static func event(
        _ id: String, seq: Int?, type: String, at: String?, run: String? = nil, parent: String? = nil, title: String? = nil,
        detail: String? = nil, payload: String = "{}", actor: String = #"{"kind":"machine"}"#, artifacts: String = "[]"
    ) -> String {
        func text(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }
        let summary = title == nil && detail == nil ? "null" : #"{"title":\#(text(title)),"detail":\#(text(detail))}"#
        return #"{"id":"\#(id)","seq":\#(seq.map(String.init) ?? "null"),"at":\#(text(at)),"type":"\#(type)","run_id":\#(text(run)),"parent":\#(text(parent)),"actor":\#(actor),"summary":\#(summary),"payload":\#(payload),"artifacts":\#(artifacts),"children":[]}"#
    }
}
