import Foundation
@testable import SymphonyBarCore
import XCTest

/// The ticket read's `lifecycle` and `phase_path` as the Lifecycle section and the Phase path say them, from the
/// fixtures in `Tests/Fixtures/lifecycle`: a ticket mid-way (back in Rework the second time, Code Review sent it back),
/// one Done and one at 95 % of its cap.
final class LifecycleTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/lifecycle")

    private let reference = ISO8601DateFormatter().date(from: "2026-10-08T11:21:00Z")!

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func read(_ name: String) throws -> TicketLifecycleRead {
        try XCTUnwrap(TicketLifecycleRead.decode(Data(contentsOf: Self.fixtures.appendingPathComponent("\(name).json"))))
    }

    private func lifecycle(_ name: String) throws -> LifecycleModel {
        let read = try read(name)
        return LifecycleModel.build(try XCTUnwrap(read.lifecycle), path: read.phasePath)
    }

    private func path(_ name: String) throws -> PhasePathModel {
        PhasePathModel.build(try XCTUnwrap(try read(name).phasePath), reference: reference, calendar: utc)
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    // MARK: - Decoding

    func testTheLifecycleFixtureDecodesEveryStageWithItsStateVisitsTimeAndTokens() throws {
        let lifecycle = try XCTUnwrap(try read("mid-way").lifecycle)
        XCTAssertEqual(lifecycle.current, "coding")
        XCTAssertEqual(lifecycle.stages.map(\.id), ["coding", "code_review", "qa", "merging", "done"])
        XCTAssertEqual(lifecycle.stages.map(\.state), [.current, .sentBack, .notYet, .notYet, .notYet])
        XCTAssertEqual(lifecycle.stages[1], TicketLifecycle.Stage(
            id: "code_review", name: "Code Review", state: .sentBack, visits: 2, timeMs: 3_300_000, agentTimeMs: 600_000, tokens: 500_000,
            runs: 2
        ))
        XCTAssertEqual(lifecycle.tokens, TicketLifecycle.Tokens(total: 3_600_000, cap: 8_000_000))
        XCTAssertNil(try read("done").lifecycle?.current)
    }

    func testThePhasePathFixtureDecodesThePhasesInOrderAndEveryMoveWithItsTime() throws {
        let path = try XCTUnwrap(try read("mid-way").phasePath)
        XCTAssertEqual(path.current, "Rework")
        XCTAssertEqual(path.phases, [
            TicketPhasePath.Phase(phase: "In Progress", count: 1, timeMs: 2_400_000, firstEnteredAt: date("2026-10-08T09:00:00Z")),
            TicketPhasePath.Phase(phase: "Code Review", count: 2, timeMs: 3_300_000, firstEnteredAt: date("2026-10-08T09:40:00Z")),
            TicketPhasePath.Phase(phase: "Rework", count: 2, timeMs: 2_760_000, firstEnteredAt: date("2026-10-08T10:10:00Z")),
        ])
        XCTAssertEqual(path.moves.first, TicketPhasePath.Move(from: "Todo", to: "In Progress", at: date("2026-10-08T09:00:00Z")))
        XCTAssertEqual(path.moves.map(\.to), ["In Progress", "Code Review", "Rework", "Code Review", "Rework"])
    }

    func testAnOlderReadWithoutEitherFieldDecodesToNothingAndMissingValuesTakeTheirDefaults() throws {
        let older = try XCTUnwrap(TicketLifecycleRead.decode(Data(#"{"identifier": "TP-1"}"#.utf8)))
        XCTAssertEqual(older, TicketLifecycleRead(lifecycle: nil, phasePath: nil))
        XCTAssertNil(TicketLifecycleRead.decode(Data("[]".utf8)))

        let sparse = try XCTUnwrap(TicketLifecycleRead.decode(Data(#"""
        {"lifecycle": {"stages": [{"id": "qa"}], "tokens": {}}, "phase_path": {"phases": [{"phase": "Todo"}], "moves": [{"to": "Todo"}]}}
        """#.utf8)))
        XCTAssertEqual(sparse.lifecycle, TicketLifecycle(
            current: nil, stages: [TicketLifecycle.Stage(id: "qa", name: "qa", state: .notYet)], tokens: TicketLifecycle.Tokens(total: 0)
        ))
        XCTAssertEqual(sparse.phasePath, TicketPhasePath(current: nil, phases: [TicketPhasePath.Phase(phase: "Todo")], moves: [TicketPhasePath.Move(to: "Todo")]))
        let empty = try XCTUnwrap(TicketLifecycleRead.decode(Data(#"{"lifecycle": {}, "phase_path": {}}"#.utf8)))
        XCTAssertEqual(empty.lifecycle, TicketLifecycle(current: nil, stages: [], tokens: TicketLifecycle.Tokens(total: 0)))
        XCTAssertEqual(empty.phasePath, TicketPhasePath(current: nil, phases: []))
    }

    // MARK: - The Lifecycle section

    func testATicketInReworkReadsCodingAsCurrentAndSaysWhichVisitAndWhoSentItBack() throws {
        let model = try lifecycle("mid-way")
        XCTAssertEqual(model.whereLine, "In Coding, the 3rd time: Code Review sent it back")
        XCTAssertEqual(model.summary, "1 h 3 min of work in 5 runs")
        XCTAssertTrue(model.live)
        XCTAssertEqual(model.stages.map(\.title), ["Coding", "Code Review", "QA", "Merging", "Done"])
        XCTAssertEqual(model.stages.map(\.line).map(plain), ["Now · 3 times · 1 h 26 min so far", "Sent back · 2 times · 55 min", "Not yet", "Not yet", "Not yet"])
        XCTAssertEqual(model.stages.map(\.status), [.working, .you, .idle, .idle, .idle])
        XCTAssertEqual(model.stages[0].accessibilityLabel, "Coding, entered 3 times, now, 1 hour 26 minutes so far")
        XCTAssertEqual(model.stages[1].accessibilityLabel, "Code Review, entered 2 times, sent back, 55 minutes")
        XCTAssertEqual(model.stages[2].accessibilityLabel, "QA, not yet")
    }

    func testATicketQASentBackThatWaitsOnTheDirectorSaysSoInOneSentenceWithCodingPaused() {
        let lifecycle = TicketLifecycle(current: "coding", stages: [
            .init(id: "coding", name: "Coding", state: .paused, visits: 3, timeMs: 5_400_000, agentTimeMs: 3_000_000, runs: 3),
            .init(id: "code_review", name: "Code Review", state: .passed, visits: 2, timeMs: 1_200_000, agentTimeMs: 600_000, runs: 2),
            .init(id: "qa", name: "QA", state: .sentBack, visits: 1, timeMs: 1_140_000, agentTimeMs: 1_000_000, runs: 1),
            .init(id: "merging", name: "Merging", state: .notYet),
            .init(id: "done", name: "Done", state: .notYet),
        ], tokens: .init(total: 6_000_000, cap: 8_000_000))
        let path = TicketPhasePath(current: "Rework", phases: [], moves: [
            .init(from: "Code Review", to: "Rework"), .init(from: "Rework", to: "Code Review"), .init(from: "Code Review", to: "QA"),
            .init(from: "QA", to: "Rework"),
        ])
        let waiting = Situation(kind: .you, cause: "Implementation run 3 asked how the paused line's times should read.")
        let model = LifecycleModel.build(lifecycle, path: path, situation: waiting)
        XCTAssertEqual(model.whereLine, "In Coding, the 3rd time: QA sent it back, and it waits on your answer")
        XCTAssertEqual(model.summary, "1 h 16 min of work in 6 runs")
        XCTAssertFalse(model.live)
        XCTAssertEqual(model.stages.map(\.line).map(plain), ["Paused · 3 times · 1 h 30 min", "Passed · 2 times · 20 min", "Sent back · 19 min", "Not yet", "Not yet"])
        XCTAssertEqual(model.stages.map(\.status), [.idle, .done, .you, .idle, .idle])
        XCTAssertEqual(model.stages[0].accessibilityLabel, "Coding, entered 3 times, paused, 1 hour 30 minutes")
        // A ticket that can still spend keeps the cap's warning.
        XCTAssertEqual(model.tokens.note, "Getting close: 25 % left of the ticket's cap.")
        // Without the phase path the stage that reads sent back names the sender.
        XCTAssertEqual(LifecycleModel.build(lifecycle, situation: waiting).whereLine, "In Coding, the 3rd time: QA sent it back, and it waits on your answer")
    }

    func testTheHeadlineSaysWhatAHeldTicketWaitsOnWithoutASendBack() {
        let lifecycle = TicketLifecycle(current: "code_review", stages: [
            .init(id: "coding", name: "Coding", state: .passed, visits: 1),
            .init(id: "code_review", name: "Code Review", state: .current, visits: 1),
        ], tokens: .init(total: 0))
        func line(_ kind: DesignTokens.SituationKind) -> String {
            LifecycleModel.build(lifecycle, situation: Situation(kind: kind, cause: "x")).whereLine
        }
        XCTAssertEqual(line(.ci), "In Code Review: it waits on CI")
        XCTAssertEqual(line(.you), "In Code Review: it waits on your answer")
        XCTAssertEqual(line(.blocked), "In Code Review: it waits on another ticket")
        XCTAssertEqual(line(.slot), "In Code Review: it waits for a free slot")
        XCTAssertEqual(line(.working), "In Code Review")
        XCTAssertEqual(LifecycleModel.build(lifecycle).whereLine, "In Code Review")
    }

    func testAFinishedTicketSaysHowItEndedFromItsSituation() {
        let done = TicketLifecycle(current: nil, stages: [
            .init(id: "coding", name: "Coding", state: .passed, visits: 1, agentTimeMs: 600_000, runs: 1),
            .init(id: "done", name: "Done", state: .passed, visits: 1),
        ], tokens: .init(total: 7_000_000, cap: 8_000_000))
        func line(_ kind: DesignTokens.SituationKind, _ cause: String) -> String {
            LifecycleModel.build(done, situation: Situation(kind: kind, cause: cause)).whereLine
        }
        XCTAssertEqual(line(.done, "Merged as PR #741 at 21:05."), "Done: merged as PR #741 at 21:05")
        XCTAssertEqual(line(.done, "It is done."), "Done")
        XCTAssertEqual(line(.cancelled, "You cancelled it; PR #741 was closed."), "Cancelled: you cancelled it; PR #741 was closed")
        XCTAssertEqual(line(.cancelled, "It was cancelled."), "Cancelled")
        XCTAssertEqual(LifecycleModel.build(done, path: TicketPhasePath(current: "Canceled", phases: [])).whereLine, "Cancelled")
        XCTAssertEqual(LifecycleModel.build(done).whereLine, "Done")
        XCTAssertEqual(LifecycleModel.build(done).summary, "10 min of work in 1 run")
    }

    func testAFinishedTicketKeepsItsBarAndTotalsWithoutTheCapsWarning() {
        let shipped = TicketLifecycle(current: nil, stages: [
            .init(id: "coding", name: "Coding", state: .passed, visits: 1, tokens: 6_200_000),
            .init(id: "done", name: "Done", state: .passed, visits: 1),
        ], tokens: .init(total: 6_200_000, cap: 8_000_000))
        let model = LifecycleModel.build(shipped, situation: Situation(kind: .done, cause: "Merged as PR #741 at 21:05."))
        XCTAssertEqual(model.tokens.value, "6.2M of 8M tokens · 77 %")
        XCTAssertEqual(model.tokens.segments.first?.value, "6.2M")
        XCTAssertNil(model.tokens.note)
        XCTAssertEqual(model.tokens.level, .normal)
        XCTAssertEqual(model.tokens.accessibilityLabel, "Ticket total, 6.2M of 8M tokens · 77 %, Coding 6.2M")
        // Still working at the same share, it warns.
        let working = TicketLifecycle(current: "coding", stages: [.init(id: "coding", name: "Coding", state: .current, tokens: 6_200_000)], tokens: shipped.tokens)
        XCTAssertEqual(LifecycleModel.build(working).tokens.note, "Getting close: 23 % left of the ticket's cap.")
    }

    func testTheSummaryCountsRunsOrFallsBackToTheTimeAlone() {
        let older = TicketLifecycle(current: "coding", stages: [.init(id: "coding", name: "Coding", state: .current, agentTimeMs: 2_400_000)], tokens: .init(total: 0))
        XCTAssertEqual(LifecycleModel.build(older).summary, "40 min of work")
        XCTAssertEqual(LifecycleModel.ordinal(2), "2nd")
        XCTAssertEqual(LifecycleModel.ordinal(3), "3rd")
        XCTAssertEqual(LifecycleModel.ordinal(4), "4th")
        XCTAssertEqual(LifecycleModel.ordinal(11), "11th")
        XCTAssertEqual(LifecycleModel.ordinal(12), "12th")
        XCTAssertEqual(LifecycleModel.ordinal(13), "13th")
        XCTAssertEqual(LifecycleModel.ordinal(21), "21st")
        XCTAssertEqual(LifecycleModel.ordinal(22), "22nd")
        XCTAssertEqual(LifecycleModel.ordinal(23), "23rd")
    }

    func testTheTokenBarSplitsTheTicketsTokensByStageAgainstItsCap() throws {
        let bar = try lifecycle("mid-way").tokens
        XCTAssertEqual(bar.segments.map(\.id), ["coding", "code_review", "qa", "merging"])
        XCTAssertEqual(bar.segments.map(\.series), [.series1, .series2, .series3, .series4])
        XCTAssertEqual(bar.segments.map(\.value), ["3.1M", "500K", "0", "0"])
        XCTAssertEqual(bar.value, "3.6M of 8M tokens · 45 %")
        XCTAssertEqual(bar.level, .normal)
        XCTAssertEqual(bar.note, "55 % of the ticket's cap left.")
        XCTAssertEqual(bar.scale, 8_000_000)
        XCTAssertEqual(bar.accessibilityLabel, "Ticket total, 3.6M of 8M tokens · 45 %, Coding 3.1M, Code Review 500K, 55 % of the ticket's cap left.")
    }

    func testATicketAt95PercentOfItsCapTurnsTheBarToTheProblemColour() throws {
        let model = try lifecycle("near-cap")
        XCTAssertEqual(model.whereLine, "In QA")
        XCTAssertEqual(model.stages.map(\.line).map(plain), ["Passed · 1 h 30 min", "Passed · 2 times · 35 min", "Now · 22 min so far", "Not yet", "Not yet"])
        XCTAssertEqual(model.stages[1].title, "Code Review")
        XCTAssertEqual(model.summary, "2 h 7 min of work in 5 runs")
        XCTAssertEqual(model.tokens.value, "7.6M of 8M tokens · 95 %")
        XCTAssertEqual(model.tokens.level, .atLimit)
        XCTAssertEqual(model.tokens.note, "Almost at the cap: the run finishes, the next one waits.")
    }

    func testADoneTicketHasEveryStagePassedNothingLiveAndNoCapNote() throws {
        let model = try lifecycle("done")
        XCTAssertEqual(model.whereLine, "Done")
        XCTAssertEqual(model.summary, "1 h 39 min of work in 6 runs")
        XCTAssertFalse(model.live)
        XCTAssertEqual(model.stages.map(\.line).map(plain), ["Passed · 2 times · 1 h 20 min", "Passed · 2 times · 40 min", "Passed · 36 min", "Passed · 12 min", "Passed"])
        XCTAssertEqual(model.tokens.value, "4.7M of 8M tokens · 58 %")
        XCTAssertNil(model.tokens.note)
    }

    func testTheCapsNoteSaysHowCloseItIsFrom75PercentAndPastIt() {
        func bar(_ total: Int, cap: Int?) -> LifecycleModel.TokenBar {
            LifecycleModel.tokenBar(TicketLifecycle(current: nil, stages: [], tokens: TicketLifecycle.Tokens(total: total, cap: cap)))
        }
        XCTAssertEqual(bar(6_000_000, cap: 8_000_000).level, .near)
        XCTAssertEqual(bar(6_000_000, cap: 8_000_000).note, "Getting close: 25 % left of the ticket's cap.")
        XCTAssertEqual(bar(9_000_000, cap: 8_000_000).value, "9M of 8M tokens · 100 %")
        XCTAssertEqual(bar(9_000_000, cap: 8_000_000).note, "At the cap: no new run starts.")
        XCTAssertEqual(bar(9_000_000, cap: 8_000_000).scale, 9_000_000)
        // No cap: the total alone, no note, no colour.
        XCTAssertEqual(bar(3_600_000, cap: nil).value, "3.6M tokens in all")
        XCTAssertNil(bar(3_600_000, cap: nil).note)
        XCTAssertNil(bar(3_600_000, cap: 0).fraction)
        XCTAssertEqual(bar(0, cap: nil).value, "Nothing yet")
        XCTAssertEqual(bar(0, cap: nil).accessibilityLabel, "Ticket total, Nothing yet")
    }

    func testATicketOutsideTheStagesOrNotStartedSaysSo() {
        let stages = [
            TicketLifecycle.Stage(id: "coding", name: "Coding", state: .passed, visits: 1, timeMs: 60_000),
            TicketLifecycle.Stage(id: "done", name: "Done", state: .notYet),
        ]
        let outside = TicketLifecycle(current: nil, stages: stages, tokens: TicketLifecycle.Tokens(total: 0))
        XCTAssertEqual(LifecycleModel.build(outside, path: TicketPhasePath(current: "Todo", phases: [])).whereLine, "In Todo, outside the stages")
        XCTAssertEqual(LifecycleModel.build(outside).whereLine, "Outside the stages")
        let fresh = TicketLifecycle(current: nil, stages: [TicketLifecycle.Stage(id: "coding", name: "Coding", state: .notYet)], tokens: .init(total: 0))
        XCTAssertEqual(LifecycleModel.build(fresh).whereLine, "Not started yet")
        XCTAssertEqual(LifecycleModel.build(fresh).summary, "No run yet")
    }

    /// TP-1652: an epic waiting on its sub-tickets, with no stage of its own, says only the tokens its Conductor runs
    /// used: no "Not started yet", no "No run yet", no stage "Not yet"; with no tokens the section is not drawn.
    func testAnEpicWorkedByItsSubTicketsSaysOnlyItsOwnTokens() {
        let names = [("coding", "Coding"), ("code_review", "Code Review"), ("qa", "QA"), ("merging", "Merging"), ("done", "Done")]
        let untouched = names.map { TicketLifecycle.Stage(id: $0.0, name: $0.1, state: .notYet) }
        let epic = TicketLifecycle(current: nil, stages: untouched, tokens: .init(total: 120_000))
        let waiting = Situation(kind: .subTickets, cause: "1 of 4 done.")
        let model = LifecycleModel.build(epic, situation: waiting, conductorTokens: 120_000)
        XCTAssertTrue(model.tokensOnly)
        XCTAssertTrue(model.drawn)
        XCTAssertEqual(model.tokens.total, 120_000)
        XCTAssertEqual(model.tokens.value, "120K tokens in all")
        XCTAssertEqual(model.tokens.segments.filter(\.isConductor).map(\.tokens), [120_000])

        let unspent = TicketLifecycle(current: nil, stages: untouched, tokens: .init(total: 0))
        XCTAssertFalse(LifecycleModel.build(unspent, situation: waiting).drawn)

        // Ended by its sub-tickets, it still has no stage of its own; an ordinary ticket before its first run keeps its section.
        let done = Situation(kind: .done, cause: "It is done.")
        XCTAssertTrue(LifecycleModel.build(epic, situation: done, hasSubTickets: true).tokensOnly)
        XCTAssertFalse(LifecycleModel.build(epic, situation: done).tokensOnly)
        XCTAssertFalse(LifecycleModel.build(unspent).tokensOnly)
        XCTAssertTrue(LifecycleModel.build(unspent).drawn)

        // An epic that did work of its own (a stage entered, or one current) draws its stages as any ticket does.
        var worked = untouched
        worked[0] = TicketLifecycle.Stage(id: "coding", name: "Coding", state: .passed, visits: 1, runs: 1)
        XCTAssertFalse(LifecycleModel.build(TicketLifecycle(current: nil, stages: worked, tokens: .init(total: 1)), situation: waiting).tokensOnly)
        XCTAssertFalse(LifecycleModel.build(TicketLifecycle(current: "coding", stages: untouched, tokens: .init(total: 1)), situation: waiting).tokensOnly)
    }

    func testAStageLineSaysItsWordItsVisitsWhenMoreThanOneAndItsTime() {
        let coding = TicketLifecycle.Stage(id: "coding", name: "Coding", state: .current, visits: 1, timeMs: 120_000)
        XCTAssertEqual(plain(LifecycleModel.stage(of: coding).line), "Now · 2 min so far")
        let review = TicketLifecycle.Stage(id: "code_review", name: "Code Review", state: .current, visits: 1)
        XCTAssertEqual(plain(LifecycleModel.stage(of: review).line), "Now")
        let back = TicketLifecycle.Stage(id: "qa", name: "QA", state: .sentBack, visits: 1, timeMs: 1_140_000)
        XCTAssertEqual(plain(LifecycleModel.stage(of: back).line), "Sent back · 19 min")
        let paused = TicketLifecycle.Stage(id: "coding", name: "Coding", state: .paused, visits: 4, timeMs: 5_400_000)
        XCTAssertEqual(plain(LifecycleModel.stage(of: paused).line), "Paused · 4 times · 1 h 30 min")
        let skipped = TicketLifecycle.Stage(id: "qa", name: "QA", state: .skipped)
        XCTAssertEqual(plain(LifecycleModel.stage(of: skipped).line), "Skipped")
        XCTAssertEqual(LifecycleModel.stage(of: skipped).status, .idle)
    }

    func testAStageLineWrapsOnlyBetweenItsParts() {
        let paused = TicketLifecycle.Stage(id: "coding", name: "Coding", state: .paused, visits: 2, timeMs: 5_100_000)
        XCTAssertEqual(LifecycleModel.stage(of: paused).line, "Paused · 2\u{00A0}times · 1\u{00A0}h\u{00A0}25\u{00A0}min")
        let coding = TicketLifecycle.Stage(id: "coding", name: "Coding", state: .current, visits: 3, timeMs: 5_160_000)
        XCTAssertEqual(LifecycleModel.stage(of: coding).line, "Now · 3\u{00A0}times · 1\u{00A0}h\u{00A0}26\u{00A0}min\u{00A0}so\u{00A0}far")
    }

    func testTheNewStageStatesDecode() throws {
        let read = try XCTUnwrap(TicketLifecycleRead.decode(Data(#"""
        {"lifecycle": {"stages": [{"id": "coding", "state": "paused", "runs": 4}, {"id": "qa", "state": "sent_back"}]}}
        """#.utf8)))
        XCTAssertEqual(read.lifecycle?.stages.map(\.state), [.paused, .sentBack])
        XCTAssertEqual(read.lifecycle?.stages.map(\.runs), [4, 0])
    }

    // MARK: - The Phase path

    func testThePhasePathShowsEachPhaseOnceWithItsCountTimeAndMoveTimes() throws {
        let model = try path("mid-way")
        XCTAssertEqual(model.phases.map(\.name), ["In Progress", "Code Review", "Rework"])
        XCTAssertEqual(model.phases.map(\.countLabel), [nil, "×2", "×2"])
        XCTAssertEqual(model.phases.map(\.state), [.passed, .passed, .current])
        XCTAssertEqual(model.phases.map(\.time), ["40 min", "55 min", "46 min so far"])
        XCTAssertEqual(model.phases.map(\.entered), [["09:00"], ["09:40", "10:40"], ["10:10", "11:05"]])
        XCTAssertEqual(model.phases[2].status, .you)
        XCTAssertEqual(model.phases[2].accessibilityLabel, "Rework, entered 2 times, 46 minutes so far, now, entered at 10:10, 11:05")
        XCTAssertEqual(model.phases[1].accessibilityLabel, "Code Review, entered 2 times, 55 minutes in all, entered at 09:40, 10:40")
        XCTAssertEqual(model.summary, "5 moves so far · sent back twice")
        XCTAssertEqual(model.accessibilityLabel, "Phases, in the order the ticket entered them")
    }

    func testADoneTicketsPathSaysHowLongItTookAndMovesOnAnotherDayCarryTheirDate() throws {
        let model = try path("done")
        XCTAssertEqual(model.phases.map(\.name), ["In Progress", "Code Review", "Rework", "QA", "Merging", "Done"])
        XCTAssertEqual(model.phases.last?.time, nil)
        XCTAssertEqual(model.phases.last?.status, .done)
        XCTAssertEqual(model.phases.last?.state, .current)
        XCTAssertEqual(model.phases.first?.entered, ["Wed 7 Oct 15:23"])
        XCTAssertEqual(model.summary, "7 moves in 18 h 26 min")
    }

    func testThePhaseInNowWorksAndASecondCIFixVisitCounts() throws {
        let model = try path("near-cap")
        XCTAssertEqual(model.phases.map(\.name), ["In Progress", "Code Review", "CI Fix", "QA"])
        XCTAssertEqual(model.phases.last?.status, .working)
        XCTAssertEqual(model.summary, "5 moves so far")
    }

    func testTheSummaryCountsSendsBackAndAPathWithoutMoves() {
        func summary(_ moves: [TicketPhasePath.Move], current: String?) -> String {
            PhasePathModel.summary(TicketPhasePath(current: current, phases: [], moves: moves), ended: current == "Done")
        }
        let back = TicketPhasePath.Move(to: "Rework")
        XCTAssertEqual(summary([back], current: "Rework"), "1 move so far · sent back once")
        XCTAssertEqual(summary([back, back, back], current: "Rework"), "3 moves so far · sent back 3 times")
        XCTAssertEqual(summary([TicketPhasePath.Move(to: "Done")], current: "Done"), "1 move")
        XCTAssertEqual(summary([], current: "Todo"), "In Todo, no move yet")
        XCTAssertEqual(summary([], current: nil), "No move yet")
    }

    func testAPhaseWithoutItsMovesFallsBackToWhenItWasFirstEntered() {
        let path = TicketPhasePath(current: nil, phases: [TicketPhasePath.Phase(phase: "Todo", timeMs: 0, firstEnteredAt: date("2026-10-08T08:00:00Z"))])
        let model = PhasePathModel.build(path, reference: reference, calendar: utc)
        XCTAssertEqual(model.phases.first?.entered, ["08:00"])
        XCTAssertNil(model.phases.first?.time)
        XCTAssertEqual(model.phases.first?.accessibilityLabel, "Todo, entered at 08:00")
    }

    /// A stage line with its non-breaking spaces read as plain ones.
    private func plain(_ line: String) -> String {
        line.replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
