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
        XCTAssertFalse(control.canStart)
        XCTAssertTrue(control.pauseFacts.isEmpty)
        XCTAssertTrue(control.limits.isEmpty)
    }

    /// c6 (TP-1590): an update Symphony has ready holds nothing, so dispatch reads as on and Pause stays.
    func testAnUpdateReadyLeavesDispatchOnAndNamesTheVersion() throws {
        let ready = UpdateHold(release: nil, downloading: false, drain: RestartMachine(), ready: "0.0.1.1056")
        let control = DispatchControl(window: .connected, paused: false, state: try state("tickets"), update: ready, now: Date(), timeZone: utc)

        XCTAssertEqual(control.mode, .on)
        XCTAssertEqual(control.word, "Dispatch on · v0.0.1.1056 ready")
        XCTAssertNil(control.updatingTo)
        XCTAssertTrue(control.canPause)
        XCTAssertTrue(control.offersPause, "the popover keeps Pause Dispatch beside Cancel Update, as the menu does")
        XCTAssertTrue(control.canCancelUpdate)
        XCTAssertFalse(control.canUpdateNow)
        XCTAssertEqual(control.update?.waitingLine, "Installs at the first moment no agent run is active")
        XCTAssertEqual(control.accessibilityLabel, "Dispatch on · v0.0.1.1056 ready, 2 working")
    }

    func testPausedSaysWhoWhenAndWhyInOrange() throws {
        let control = DispatchControl(window: .connected, paused: true, state: try state("paused"), now: Date(), timeZone: utc)
        XCTAssertEqual(control.mode, .paused)
        XCTAssertEqual(control.word, "Paused · Deploy freeze")
        XCTAssertEqual(control.status, .you)
        XCTAssertEqual(control.status.color, .statusYou)
        XCTAssertEqual(control.pauseFacts, [
            TicketList.Fact(label: "By", value: "You"),
            TicketList.Fact(label: "Since", value: "14:03"),
            TicketList.Fact(label: "Why", value: "Deploy freeze"),
        ])
        XCTAssertTrue(control.canResume)
        XCTAssertFalse(control.canPause)
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

    /// Anthropic at its reserve and OpenCode Go at its weekly limit: the bar names both, each once (TP-1617).
    func testHoldingNamesEveryProviderAtItsLimit() throws {
        let control = DispatchControl(window: .connected, paused: false, state: try state("fallback-limit"), now: Date(), timeZone: utc)
        XCTAssertEqual(control.mode, .holding)
        XCTAssertEqual(control.word, "Holding · Claude and OpenCode Go limits")
        XCTAssertEqual(control.limits.count, 2)

        let three = [StateSnapshot.UsageLimit(), .init(provider: "opencode-go"), .init(provider: "openrouter"), .init(provider: "opencode-go")]
        XCTAssertEqual(DispatchControl.limitsWord(three), "Claude, OpenCode Go and OpenRouter limits")
        XCTAssertEqual(DispatchControl.limitsWord([.init(reason: "model_api_unreachable")]), "limit")
    }

    /// The popover offers Try Now beside the paused limit it checks (TP-1471).
    func testHoldingOffersTryNowForAPausedLimit() throws {
        let control = DispatchControl(window: .connected, paused: false, state: try state("holding"), now: Date(), timeZone: utc)
        XCTAssertTrue(control.canTryNow)
        XCTAssertEqual(control.tryNow?.phase, .paused)
        XCTAssertEqual(DispatchControl.tryNowTitle, "Try Now")

        let checking = OverviewState(snapshot: StateSnapshot(usageLimits: [.init(phase: .canary)]))
        XCTAssertFalse(DispatchControl(window: .connected, paused: false, state: checking, now: Date()).canTryNow)
        let headroom = OverviewState(snapshot: StateSnapshot(usageLimits: [.init(phase: .headroom)]))
        XCTAssertFalse(DispatchControl(window: .connected, paused: false, state: headroom, now: Date()).canTryNow)
        XCTAssertFalse(DispatchControl(window: .stopped, paused: false, state: nil, now: Date()).canTryNow)
    }

    func testSymphonyStoppedOffersStartOnlyWhenStopped() {
        let stopped = DispatchControl(window: .stopped, paused: false, state: nil, now: Date())
        XCTAssertEqual(stopped.mode, .stopped)
        XCTAssertEqual(stopped.word, "Symphony stopped")
        XCTAssertEqual(stopped.accessibilityLabel, "Symphony stopped")
        XCTAssertTrue(stopped.canStart)
        XCTAssertFalse(stopped.canPause)
        XCTAssertFalse(stopped.canResume)
        XCTAssertEqual(DispatchControl(window: .starting, paused: false, state: nil, now: Date()).word, "Symphony starting")
        XCTAssertEqual(DispatchControl(window: .notAnswering, paused: false, state: nil, now: Date()).word, "Symphony not answering")
        XCTAssertEqual(DispatchControl(window: .firstLaunch, paused: false, state: nil, now: Date()).word, "Symphony not set up")
        XCTAssertFalse(DispatchControl(window: .starting, paused: false, state: nil, now: Date()).canStart)
    }

    // MARK: - D12a: the sheet

    func testPauseSheetSendsItsReasonOrTheMenusOne() throws {
        XCTAssertEqual(PauseSheet.action(reason: "  Deploy freeze \n"), .pauseWithReason("Deploy freeze"))
        XCTAssertEqual(try body(PauseSheet.action(reason: "Deploy freeze")), ["reason": "Deploy freeze"])
        XCTAssertEqual(try body(PauseSheet.action(reason: "  ")), ["reason": ControlAction.pauseReason])
        let request = ControlAPI.request(.pauseWithReason("x"), base: URL(string: "http://h")!, token: "t")
        XCTAssertEqual(request.url?.path, "/api/v1/control/pause")
        XCTAssertNil(ControlAction.pauseWithReason("x").moveIdentifier)
        XCTAssertEqual(ControlAPI.result(.pauseWithReason("x"), statusCode: 500, data: Data()), .failed("Couldn't pause Symphony: HTTP 500"))
        XCTAssertTrue(PauseSheet.happens.contains("until you resume"))
        XCTAssertTrue(PauseSheet.stays.contains("go on to their end"))
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
        XCTAssertFalse(control.offersPause)
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

    // MARK: - The status line's word (TP-1498)

    func testTheStatusLineSaysDispatchPausedAndKeepsTheReasonForItsHelp() {
        let paused = DispatchControl(window: .connected, paused: true, state: nil, now: Date())
        XCTAssertEqual(paused.lineWord, "Dispatch paused")
        XCTAssertEqual(paused.word, "Paused")
        XCTAssertEqual(paused.status, .you, "the dot turns orange")
        XCTAssertFalse(paused.live)

        let on = DispatchControl(window: .connected, paused: false, state: nil, now: Date())
        XCTAssertEqual(on.lineWord, "Dispatch on")
        XCTAssertTrue(on.live)

        let stopped = DispatchControl(window: .stopped, paused: false, state: nil, now: Date())
        XCTAssertEqual(stopped.lineWord, stopped.word)
        XCTAssertFalse(stopped.live)
    }
}
