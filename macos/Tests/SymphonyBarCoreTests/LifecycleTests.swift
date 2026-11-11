import Foundation
@testable import SymphonyBarCore
import XCTest

/// The ticket read's `lifecycle` and `phase_path` as the Lifecycle section and the Phase path say them, from the
/// fixtures in `Tests/Fixtures/lifecycle`: a ticket mid-way (back in Rework, Code Review entered three times), one
/// Done and one at 95 % of its cap.
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
        return LifecycleModel.build(try XCTUnwrap(read.lifecycle), phase: read.phasePath?.current)
    }

    private func path(_ name: String) throws -> PhasePathModel {
        PhasePathModel.build(try XCTUnwrap(try read(name).phasePath), reference: reference, calendar: utc)
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    // MARK: - Decoding

    func testTheLifecycleFixtureDecodesEveryStageWithItsStateVisitsTimeAndTokens() throws {
        let lifecycle = try XCTUnwrap(try read("mid-way").lifecycle)
        XCTAssertEqual(lifecycle.current, "code_review")
        XCTAssertEqual(lifecycle.stages.map(\.id), ["coding", "code_review", "qa", "merging", "done"])
        XCTAssertEqual(lifecycle.stages.map(\.state), [.passed, .current, .notYet, .notYet, .notYet])
        XCTAssertEqual(lifecycle.stages[1], TicketLifecycle.Stage(
            id: "code_review", name: "Code Review", state: .current, visits: 3, timeMs: 6_060_000, agentTimeMs: 1_500_000, tokens: 1_200_000
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

    func testATicketInReworkReadsCodeReviewAsCurrentWithItsThreeVisitsAndQANext() throws {
        let model = try lifecycle("mid-way")
        XCTAssertEqual(model.whereLine, "In Code Review, visit 3")
        XCTAssertEqual(model.summary, "1 h 3 min of agent work")
        XCTAssertTrue(model.live)
        XCTAssertEqual(model.stages.map(\.title), ["Coding", "Code Review ×3", "QA", "Merging", "Done"])
        XCTAssertEqual(model.stages.map(\.line), ["Passed · 40 min", "Now · in Rework · 1 h 41 min so far", "Not yet", "Not yet", "Not yet"])
        XCTAssertEqual(model.stages.map(\.status), [.done, .working, .idle, .idle, .idle])
        XCTAssertEqual(model.stages[1].accessibilityLabel, "Code Review, entered 3 times, now, in Rework, 1 hour 41 minutes so far")
        XCTAssertEqual(model.stages[2].accessibilityLabel, "QA, not yet")
    }

    func testTheTokenBarSplitsTheTicketsTokensByStageAgainstItsCap() throws {
        let bar = try lifecycle("mid-way").tokens
        XCTAssertEqual(bar.segments.map(\.id), ["coding", "code_review", "qa", "merging"])
        XCTAssertEqual(bar.segments.map(\.series), [.series1, .series2, .series3, .series4])
        XCTAssertEqual(bar.segments.map(\.value), ["2.4M", "1.2M", "0", "0"])
        XCTAssertEqual(bar.value, "3.6M of 8M tokens · 45 %")
        XCTAssertEqual(bar.level, .normal)
        XCTAssertEqual(bar.note, "55 % of the ticket's cap left.")
        XCTAssertEqual(bar.scale, 8_000_000)
        XCTAssertEqual(bar.accessibilityLabel, "Tokens, 3.6M of 8M tokens · 45 %, Coding 2.4M, Code Review 1.2M, 55 % of the ticket's cap left.")
    }

    func testATicketAt95PercentOfItsCapTurnsTheBarToTheProblemColour() throws {
        let model = try lifecycle("near-cap")
        XCTAssertEqual(model.whereLine, "In QA")
        XCTAssertEqual(model.stages.map(\.line), ["Passed · 1 h 30 min", "Passed · 35 min", "Now · 22 min so far", "Not yet", "Not yet"])
        XCTAssertEqual(model.stages[1].title, "Code Review ×2")
        XCTAssertEqual(model.tokens.value, "7.6M of 8M tokens · 95 %")
        XCTAssertEqual(model.tokens.level, .atLimit)
        XCTAssertEqual(model.tokens.note, "Almost at the cap: the run finishes, the next one waits.")
    }

    func testADoneTicketHasEveryStagePassedAndNothingLive() throws {
        let model = try lifecycle("done")
        XCTAssertEqual(model.whereLine, "Done")
        XCTAssertFalse(model.live)
        XCTAssertEqual(model.stages.map(\.line), ["Passed · 50 min", "Passed · 1 h 10 min", "Passed · 36 min", "Passed · 12 min", "Passed"])
        XCTAssertEqual(model.tokens.value, "4.7M of 8M tokens · 58 %")
        XCTAssertEqual(model.tokens.note, "42 % of the ticket's cap left.")
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
        XCTAssertEqual(bar(0, cap: nil).accessibilityLabel, "Tokens, Nothing yet")
    }

    func testATicketOutsideTheStagesOrNotStartedSaysSo() {
        let stages = [
            TicketLifecycle.Stage(id: "coding", name: "Coding", state: .passed, visits: 1, timeMs: 60_000),
            TicketLifecycle.Stage(id: "done", name: "Done", state: .notYet),
        ]
        let outside = TicketLifecycle(current: nil, stages: stages, tokens: TicketLifecycle.Tokens(total: 0))
        XCTAssertEqual(LifecycleModel.build(outside, phase: "Todo").whereLine, "In Todo, outside the stages")
        XCTAssertEqual(LifecycleModel.build(outside).whereLine, "Outside the stages")
        let fresh = TicketLifecycle(current: nil, stages: [TicketLifecycle.Stage(id: "coding", name: "Coding", state: .notYet)], tokens: .init(total: 0))
        XCTAssertEqual(LifecycleModel.build(fresh).whereLine, "Not started yet")
        XCTAssertEqual(LifecycleModel.build(fresh).summary, "No run yet")
    }

    func testAStageSaysThePhaseItIsInOnlyWhenThatIsNotItsOwnName() {
        let coding = TicketLifecycle.Stage(id: "coding", name: "Coding", state: .current, visits: 1, timeMs: 120_000)
        XCTAssertEqual(LifecycleModel.stage(of: coding, phase: "In Progress").line, "Now · 2 min so far")
        let review = TicketLifecycle.Stage(id: "code_review", name: "Code Review", state: .current, visits: 1)
        XCTAssertEqual(LifecycleModel.stage(of: review, phase: "Code Review").line, "Now")
        // A repository that renamed Code Review: the phase reads by its own name.
        XCTAssertEqual(LifecycleModel.stage(of: review, phase: "Review").line, "Now · in Review")
        let skipped = TicketLifecycle.Stage(id: "qa", name: "QA", state: .skipped)
        XCTAssertEqual(LifecycleModel.stage(of: skipped, phase: nil).line, "Skipped")
        XCTAssertEqual(LifecycleModel.stage(of: skipped, phase: nil).status, .idle)
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
}
