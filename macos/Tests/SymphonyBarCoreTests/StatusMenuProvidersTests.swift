import XCTest
@testable import SymphonyBarCore

/// The menu bar menu's Providers block (TP-1536): a line per provider in use, in Symphony's order, "Pause" or "Resume"
/// and its name, a status dot and its state on the right, and the control a click sends; no block without one.
final class StatusMenuProvidersTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// Tuesday 17 November 2026, 14:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_794_924_000)
    private let hour: TimeInterval = 3600

    private func lines(_ providers: [StateSnapshot.Provider]?, paused: Bool = false) -> [StatusMenu.ProviderLine] {
        var snapshot = StateSnapshot(running: 1, retrying: 0)
        snapshot.providers = providers
        let status: SymphonyStatus = paused ? .paused(snapshot, external: false) : .running(snapshot, external: false)
        return StatusMenu.providerLines(status, now: now, timeZone: utc)
    }

    private let anthropic = StateSnapshot.Provider(id: "anthropic", name: "Anthropic", inUse: true, kinds: ["implementation"], working: 2)
    private let openRouter = StateSnapshot.Provider(id: "openrouter", name: "OpenRouter", inUse: true, fallbackFor: ["qa"])
    private let openAI = StateSnapshot.Provider(id: "openai", name: "OpenAI", harnesses: ["codex"])

    func testALinePerProviderInUseInSymphonysOrder() {
        let lines = lines([openRouter, openAI, anthropic])
        XCTAssertEqual(lines.map(\.id), ["openrouter", "anthropic"])
        XCTAssertEqual(lines.map(\.title), ["Pause OpenRouter", "Pause Anthropic"])
        // Dispatch paused still lists them: a provider's pause is its own.
        XCTAssertEqual(self.lines([anthropic], paused: true).map(\.id), ["anthropic"])
    }

    func testNoBlockWithoutAProviderInUse() {
        XCTAssertEqual(lines(nil), [])
        XCTAssertEqual(lines([]), [])
        XCTAssertEqual(lines([openAI]), [])
        var snapshot = StateSnapshot(running: 0, retrying: 0)
        snapshot.providers = [anthropic]
        for status: SymphonyStatus in [.stopped, .starting, .error("boom")] {
            XCTAssertEqual(StatusMenu.providerLines(status, now: now, timeZone: utc), [])
        }
    }

    func testTitlesAndStatesForEachState() {
        var paused = anthropic
        paused.paused = true
        paused.pausedSince = now.addingTimeInterval(-12 * 60)
        var held = anthropic
        held.held = true
        held.heldUntil = now.addingTimeInterval(2 * hour)
        var reserve = anthropic
        reserve.held = true
        reserve.atReserve = true
        reserve.reserve = 0.9
        reserve.usageWindows = [.init(name: "seven_day", utilization: 0.91)]
        var idle = openRouter
        idle.working = 0

        let cases: [(StateSnapshot.Provider, String, DesignTokens.Status, String)] = [
            (anthropic, "Pause Anthropic", .done, "2 working"),
            (idle, "Pause OpenRouter", .done, "Available"),
            (paused, "Resume Anthropic", .you, "Paused by you · 12 min"),
            (held, "Pause Anthropic", .problem, "Limit reached · until 16:00"),
            (reserve, "Pause Anthropic", .you, "At your reserve"),
        ]
        for (provider, title, status, state) in cases {
            let line = lines([provider])[0]
            XCTAssertEqual(line.title, title)
            XCTAssertEqual(line.status, status, title)
            XCTAssertEqual(line.state, state)
        }
        XCTAssertEqual(lines([paused])[0].spoken, "Paused. You paused it 12 min ago. New runs start on their fallbacks, or wait.")
    }

    func testAClickSendsPauseOrResumeForThatProvider() {
        var paused = anthropic
        paused.paused = true
        XCTAssertEqual(lines([anthropic])[0].action, .pauseProvider("anthropic", name: "Anthropic"))
        XCTAssertEqual(lines([paused])[0].action, .resumeProvider("anthropic", name: "Anthropic"))
        XCTAssertEqual(StatusMenu.providersTitle, "Providers")
    }
}
