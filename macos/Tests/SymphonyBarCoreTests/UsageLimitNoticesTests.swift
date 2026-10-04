import XCTest
@testable import SymphonyBarCore

final class UsageLimitNoticesTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let now = Date(timeIntervalSince1970: 1_790_943_362) // 2026-10-02 12:16:02 UTC

    private var claudeLimit: StateSnapshot.UsageLimit {
        .init(window: "five_hour", phase: .paused, resumeAt: now.addingTimeInterval(120))
    }

    private func poll(_ limits: [StateSnapshot.UsageLimit], operatorPause: Bool = false) -> StatusPoll {
        .state(StateSnapshot(running: 1, pause: operatorPause ? .init() : nil, usageLimits: limits))
    }

    private func notices(_ polls: [StatusPoll]) -> [[UsageLimitNotice]] {
        var diff = UsageLimitNotices()
        return polls.map { diff.notices(for: $0, now: now, timeZone: utc) }
    }

    private let paused = UsageLimitNotice(title: "Symphony paused", body: "Claude 5-hour limit, resumes ~12:18")
    private let resumed = UsageLimitNotice(title: "Symphony resumed", body: "Claude limit reset")

    func testAnnouncesThePauseAndTheResumeOnce() {
        XCTAssertEqual(
            notices([poll([]), poll([claudeLimit]), poll([claudeLimit]), poll([]), poll([])]),
            [[], [paused], [], [resumed], []]
        )
    }

    func testAHoldAlreadyInPlaceAtLaunchIsNotAnnounced() {
        XCTAssertEqual(notices([poll([claudeLimit]), poll([claudeLimit]), poll([])]), [[], [], [resumed]])
    }

    func testAHoldAlreadyInPlaceWhenSymphonyAnswersAgainIsNotAnnounced() {
        XCTAssertEqual(
            notices([poll([]), .unreachable, poll([claudeLimit]), .failed("HTTP 500"), poll([])]),
            [[], [], [], [], []]
        )
    }

    func testTheCanaryCountsAsStillPaused() {
        var canary = claudeLimit
        canary.phase = .canary

        XCTAssertEqual(
            notices([poll([]), poll([claudeLimit]), poll([canary]), poll([claudeLimit]), poll([canary]), poll([])]),
            [[], [paused], [], [], [], [resumed]]
        )
    }

    func testAHeadroomHoldIsNotAPause() {
        let headroom = StateSnapshot.UsageLimit(window: "five_hour", phase: .headroom, utilization: 0.91)

        XCTAssertEqual(
            notices([poll([]), poll([headroom]), poll([claudeLimit]), poll([headroom]), poll([])]),
            [[], [], [paused], [resumed], []]
        )
    }

    func testTheResumeWaitsWhileTheOperatorPauseIsOn() {
        XCTAssertEqual(
            notices([
                poll([]),
                poll([claudeLimit], operatorPause: true),
                poll([], operatorPause: true),
                poll([]),
            ]),
            [[], [paused], [], []]
        )
    }

    func testResumesOncePerProviderWhenItsLastHoldClears() {
        let opus = StateSnapshot.UsageLimit(scope: "opus", window: "seven_day_opus", resumeAt: now.addingTimeInterval(86_400))
        let codex = StateSnapshot.UsageLimit(provider: "openai", window: nil)

        XCTAssertEqual(
            notices([poll([]), poll([claudeLimit, opus, codex]), poll([opus]), poll([])]),
            [
                [],
                [
                    paused,
                    .init(title: "Symphony paused", body: "Claude weekly Opus limit, resumes ~Oct 3 12:16"),
                    .init(title: "Symphony paused", body: "Codex usage limit"),
                ],
                [.init(title: "Symphony resumed", body: "Codex limit reset")],
                [resumed],
            ]
        )
    }
}
