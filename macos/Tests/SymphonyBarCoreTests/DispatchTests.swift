import Foundation
import XCTest
@testable import SymphonyBarCore

final class DispatchTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    // MARK: - C2: the dispatch control

    func testDispatchOnListsWhatIsWorkingAndQueued() throws {
        let control = DispatchControl(window: .connected, paused: false, state: try state("tickets"), now: Date(), timeZone: utc)
        XCTAssertEqual(control.mode, .on)
        XCTAssertEqual(control.word, "Dispatch on")
        XCTAssertEqual(control.status, .done)
        XCTAssertEqual(control.working, ["SHOP-305 · Checkout total rounding", "API-131 · Rate limit headers"])
        XCTAssertEqual(control.queued.count, DispatchControl.listLimit)
        XCTAssertEqual(control.moreQueued, 3)
        XCTAssertEqual(control.moreWorking, 0)
        XCTAssertEqual(control.accessibilityLabel, "Dispatch on, 2 working")
        XCTAssertTrue(control.canPause)
        XCTAssertFalse(control.canResume)
        XCTAssertTrue(control.canForce)
        XCTAssertFalse(control.canStart)
        XCTAssertTrue(control.pauseFacts.isEmpty)
        XCTAssertTrue(control.limits.isEmpty)
    }

    func testPausedSaysWhoWhenAndWhyInOrange() throws {
        let control = DispatchControl(window: .connected, paused: true, state: try state("paused"), now: Date(), timeZone: utc)
        XCTAssertEqual(control.mode, .paused)
        XCTAssertEqual(control.word, "Paused · Deploy freeze")
        XCTAssertEqual(control.status, .you)
        XCTAssertEqual(control.status.color, .orange)
        XCTAssertEqual(control.pauseFacts, [
            TicketList.Fact(label: "By", value: "You"),
            TicketList.Fact(label: "Since", value: "14:03"),
            TicketList.Fact(label: "Why", value: "Deploy freeze"),
        ])
        XCTAssertTrue(control.canResume)
        XCTAssertFalse(control.canPause)
        XCTAssertTrue(control.canForce)
    }

    func testAPauseFromTheMenuOrWithoutAStateSaysSo() {
        let menu = OverviewState(snapshot: StateSnapshot(pause: .init(reason: ControlAction.pauseReason)))
        XCTAssertEqual(DispatchControl(window: .connected, paused: true, state: menu, now: Date()).pauseFacts.first?.value, "You, from the menu bar")

        let unread = DispatchControl(window: .connected, paused: true, state: nil, now: Date())
        XCTAssertEqual(unread.word, "Paused")
        XCTAssertEqual(unread.pauseFacts, [TicketList.Fact(label: "By", value: "You"), TicketList.Fact(label: "Why", value: "No reason given")])
    }

    func testHoldingNamesTheLimitAndWhenItResets() throws {
        let control = DispatchControl(window: .connected, paused: false, state: try state("holding"), now: Date(), timeZone: utc)
        XCTAssertEqual(control.mode, .holding)
        XCTAssertEqual(control.word, "Holding · Claude limit")
        XCTAssertEqual(control.status, .idle)
        XCTAssertTrue(control.limits[0].hasPrefix("Paused: Claude limit, resumes ~16:00"))
        XCTAssertTrue(control.canPause)

        let unreachable = OverviewState(snapshot: StateSnapshot(usageLimits: [.init(reason: "model_api_unreachable")]))
        XCTAssertEqual(DispatchControl(window: .connected, paused: false, state: unreachable, now: Date()).word, "Holding · Claude API unreachable")

        let canary = OverviewState(snapshot: StateSnapshot(usageLimits: [.init(phase: .canary)]))
        XCTAssertEqual(DispatchControl(window: .connected, paused: false, state: canary, now: Date()).mode, .on)

        let budget = OverviewState(snapshot: StateSnapshot(budget: .init(dailyPaused: true)))
        let held = DispatchControl(window: .connected, paused: false, state: budget, now: Date())
        XCTAssertEqual(held.word, "Holding · token budget")
        XCTAssertEqual(held.limits, ["Daily token budget used up, resets at midnight UTC"])
    }

    func testSymphonyStoppedOffersStartOnlyWhenStopped() {
        let stopped = DispatchControl(window: .stopped, paused: false, state: nil, now: Date())
        XCTAssertEqual(stopped.mode, .stopped)
        XCTAssertEqual(stopped.word, "Symphony stopped")
        XCTAssertEqual(stopped.accessibilityLabel, "Symphony stopped")
        XCTAssertTrue(stopped.canStart)
        XCTAssertFalse(stopped.canPause)
        XCTAssertFalse(stopped.canResume)
        XCTAssertFalse(stopped.canForce)
        XCTAssertEqual(DispatchControl(window: .starting, paused: false, state: nil, now: Date()).word, "Symphony starting")
        XCTAssertEqual(DispatchControl(window: .notAnswering, paused: false, state: nil, now: Date()).word, "Symphony not answering")
        XCTAssertEqual(DispatchControl(window: .firstLaunch, paused: false, state: nil, now: Date()).word, "Symphony not set up")
        XCTAssertFalse(DispatchControl(window: .starting, paused: false, state: nil, now: Date()).canStart)
    }

    // MARK: - D12a and D12b: the sheets

    func testPauseSheetSendsItsReasonOrTheMenusOne() throws {
        XCTAssertEqual(PauseSheet.action(reason: "  Deploy freeze \n"), .pauseWithReason("Deploy freeze"))
        XCTAssertEqual(try body(PauseSheet.action(reason: "Deploy freeze")), ["reason": "Deploy freeze"])
        XCTAssertEqual(try body(PauseSheet.action(reason: "  ")), ["reason": ControlAction.pauseReason])
        let request = ControlAPI.request(.pauseWithReason("x"), base: URL(string: "http://h")!, token: "t")
        XCTAssertEqual(request.url?.path, "/api/v1/control/pause")
        XCTAssertNil(ControlAction.pauseWithReason("x").moveIdentifier)
        XCTAssertEqual(ControlAPI.result(.pauseWithReason("x"), statusCode: 500, data: Data()), .failed("Couldn't pause Symphony: HTTP 500"))
        XCTAssertTrue(PauseSheet.happens.contains("forced tickets included"))
        XCTAssertTrue(PauseSheet.stays.contains("go on to their end"))
    }

    func testForceSheetFindsTheTicketAsItIsTyped() throws {
        let list = TicketList(state: try state("tickets"), now: Date(), timeZone: utc)
        XCTAssertNil(ForceSheet.identifier("   "))
        XCTAssertEqual(ForceSheet.identifier(" shop-320 "), "SHOP-320")
        XCTAssertEqual(ForceSheet.matches("shop-3", in: list).count, ForceSheet.suggestionLimit)
        XCTAssertEqual(ForceSheet.matches("SHOP-32", in: list).map(\.identifier), ["SHOP-320", "SHOP-325", "SHOP-322"])
        XCTAssertEqual(ForceSheet.matches("API-131", in: list).map(\.identifier), ["API-131"])
        XCTAssertTrue(ForceSheet.matches("", in: list).isEmpty)
        XCTAssertTrue(ForceSheet.matches("SHOP", in: nil).isEmpty)

        XCTAssertEqual(ForceSheet.summary("shop-320", in: list), "Order history filters\nTodo · Queued")
        XCTAssertEqual(ForceSheet.summary("SHOP-325", in: list), "Express checkout\nTodo · Queued · already forced")
        XCTAssertEqual(ForceSheet.summary("TP-9", in: list), "Symphony doesn't track TP-9 yet. It looks it up in Linear when you force it.")
        XCTAssertNil(ForceSheet.summary("", in: list))

        XCTAssertTrue(ForceSheet.canForce("SHOP-320", in: list))
        XCTAssertTrue(ForceSheet.canForce("TP-9", in: list))
        XCTAssertFalse(ForceSheet.canForce("SHOP-325", in: list))
        XCTAssertFalse(ForceSheet.canForce(" ", in: list))
        XCTAssertTrue(ForceSheet.keeps.contains("never moves a ticket"))
        XCTAssertTrue(ForceSheet.skips.contains("forced allowance"))
    }

    // MARK: - Helpers

    private func body(_ action: ControlAction) throws -> [String: String] {
        let request = ControlAPI.request(action, base: URL(string: "http://h")!, token: "t")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
    }

    private func state(_ name: String) throws -> OverviewState {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-app/\(name)/api/v1/state.json")
        return try XCTUnwrap(OverviewState.decode(try Data(contentsOf: url)))
    }

    // MARK: - S3a, S3b: an update holds dispatch

    private let since = Date(timeIntervalSince1970: 1_000_000)

    /// Dispatch paused on `reason`: an update's `build` reason carrying `version`, or the Director's without one.
    private func updatePaused(reason: String = "updating to v0.0.1.42", version: String? = "0.0.1.42", running: Int = 1) -> OverviewState {
        let pauseReason = version.map { StateSnapshot.PauseReason(kind: .build, text: reason, since: since, version: $0) }
            ?? StateSnapshot.PauseReason(kind: .person, text: reason, since: since)
        return OverviewState(
            snapshot: StateSnapshot(running: running, pause: .init(reason: reason, since: since), pauseReasons: [pauseReason]),
            generatedAt: since,
            running: (0..<running).map { OverviewState.Run(identifier: "TP-\($0 + 1)", title: "Run \($0 + 1)") }
        )
    }

    func testAnUpdateWaitingForRunsOffersCancelUpdateInPlaceOfResume() {
        let update = UpdateHold(version: "0.0.1.42", step: .waiting(runs: 1))
        let control = DispatchControl(window: .connected, paused: true, state: updatePaused(), update: update, now: since, timeZone: utc)

        XCTAssertEqual(control.mode, .paused)
        XCTAssertEqual(control.word, "Paused · Updating to v0.0.1.42")
        XCTAssertEqual(control.status, .you)
        XCTAssertEqual(control.accessibilityLabel, "Dispatch paused, updating to v0.0.1.42")
        XCTAssertEqual(control.pauseFacts, [
            TicketList.Fact(label: "By", value: "an update to v0.0.1.42"),
            TicketList.Fact(label: "Since", value: "13:46"),
            TicketList.Fact(label: "Why", value: "updating to v0.0.1.42"),
        ])
        XCTAssertEqual(control.update?.waitingLine, "Waiting for 1 agent run")
        XCTAssertEqual(control.working, ["TP-1 · Run 1"])
        XCTAssertTrue(control.canCancelUpdate)
        XCTAssertFalse(control.canUpdateNow)
        XCTAssertFalse(control.canResume)
        XCTAssertFalse(control.canPause)
        XCTAssertTrue(control.canForce)
        XCTAssertEqual(DispatchControl.cancelUpdateTitle, "Cancel Update")
        XCTAssertEqual(DispatchControl.updateNowTitle, "Update Now Anyway")
    }

    func testAnUpdatePastTheTimeoutAlsoOffersUpdateNowAnyway() {
        let update = UpdateHold(version: "0.0.1.42", step: .waiting(runs: 2), offersUpdateNow: true)
        let control = DispatchControl(window: .connected, paused: true, state: updatePaused(running: 2), update: update, now: since, timeZone: utc)

        XCTAssertEqual(control.update?.waitingLine, "Waiting for 2 agent runs")
        XCTAssertTrue(control.canCancelUpdate)
        XCTAssertTrue(control.canUpdateNow)
        XCTAssertFalse(control.canResume)
    }

    func testAnUpdateOffersNothingWhileItDownloadsOrStopsSymphony() {
        let downloading = DispatchControl(
            window: .connected, paused: false, state: OverviewState(), update: UpdateHold(version: "0.0.1.42", step: .preparing), now: since
        )
        XCTAssertEqual(downloading.mode, .on)
        XCTAssertEqual(downloading.word, "Updating to v0.0.1.42")
        XCTAssertEqual(downloading.accessibilityLabel, "Dispatch on, updating to v0.0.1.42")
        XCTAssertFalse(downloading.canCancelUpdate || downloading.canUpdateNow || downloading.canPause || downloading.canResume)

        let held = OverviewState(snapshot: StateSnapshot(budget: .init(dailyPaused: true)))
        let holding = DispatchControl(window: .connected, paused: false, state: held, update: UpdateHold(version: "0.0.1.42", step: .preparing), now: since)
        XCTAssertEqual(holding.mode, .holding)
        XCTAssertEqual(holding.accessibilityLabel, "Updating to v0.0.1.42")

        let stopping = UpdateHold(version: "0.0.1.42", step: .stopping, offersUpdateNow: true)
        let paused = DispatchControl(window: .connected, paused: true, state: updatePaused(running: 0), update: stopping, now: since, timeZone: utc)
        XCTAssertEqual(paused.word, "Paused · Updating to v0.0.1.42")
        XCTAssertFalse(paused.canCancelUpdate || paused.canUpdateNow || paused.canResume)

        let stopped = DispatchControl(window: .stopped, paused: false, state: nil, update: stopping, now: since)
        XCTAssertEqual(stopped.mode, .stopped)
        XCTAssertEqual(stopped.word, "Updating to v0.0.1.42")
        XCTAssertEqual(stopped.accessibilityLabel, "Updating to v0.0.1.42")
        XCTAssertFalse(stopped.canStart, "the update starts the new version's Symphony")
        XCTAssertFalse(stopped.canCancelUpdate || stopped.canUpdateNow)
    }

    func testAnUpdatesPauseLeftBehindStillSaysSoAndOffersResume() {
        let control = DispatchControl(window: .connected, paused: true, state: updatePaused(), now: since, timeZone: utc)
        XCTAssertEqual(control.word, "Paused · Updating to v0.0.1.42")
        XCTAssertEqual(control.pauseFacts.first, TicketList.Fact(label: "By", value: "an update to v0.0.1.42"))
        XCTAssertNil(control.update)
        XCTAssertTrue(control.canResume)
        XCTAssertFalse(control.canCancelUpdate)
    }

    /// The version is the `build` reason's field, never read out of the reason's text: an older Symphony's update
    /// pause, with no reasons, shows its line as any pause does.
    func testAnUpdatesVersionComesFromTheReasonsFieldNotItsText() {
        let field = DispatchControl(
            window: .connected, paused: true, state: updatePaused(reason: "an update's pause", version: "0.0.1.700"), now: since, timeZone: utc
        )
        XCTAssertEqual(field.word, "Paused · Updating to v0.0.1.700")
        XCTAssertEqual(field.pauseFacts.first, TicketList.Fact(label: "By", value: "an update to v0.0.1.700"))

        let older = OverviewState(snapshot: StateSnapshot(pause: .init(reason: "updating to v0.0.1.42", since: since)), generatedAt: since)
        let control = DispatchControl(window: .connected, paused: true, state: older, now: since, timeZone: utc)
        XCTAssertNil(control.updatingTo)
        XCTAssertEqual(control.word, "Paused · updating to v0.0.1.42")
        XCTAssertEqual(control.pauseFacts.first, TicketList.Fact(label: "By", value: "You"))
    }

    func testAnUpdateKeepsThePauseTheUserMade() {
        let update = UpdateHold(version: "0.0.1.42", step: .waiting(runs: 1))
        let control = DispatchControl(window: .connected, paused: true, state: updatePaused(reason: "Deploy freeze", version: nil), update: update, now: since, timeZone: utc)
        XCTAssertEqual(control.word, "Paused · Updating to v0.0.1.42")
        XCTAssertEqual(control.pauseFacts.first, TicketList.Fact(label: "By", value: "You"))
        XCTAssertEqual(control.pauseFacts.last, TicketList.Fact(label: "Why", value: "Deploy freeze"))
        XCTAssertTrue(control.canCancelUpdate)
    }
}
