import XCTest
@testable import SymphonyBarCore

/// Factory › Providers (TP-1534): the list's order and each card's one fact and state, the picked provider's page and
/// its blocks dropped when empty, Pause and Resume, and what a Runs line says of a paused or held provider.
final class ProvidersPageTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// Tuesday 17 November 2026, 14:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_794_924_000)
    private let hour: TimeInterval = 3600

    private func anthropic(paused: Bool = false, held: Bool = false, working: Int = 3) -> StateSnapshot.Provider {
        StateSnapshot.Provider(
            id: "anthropic", name: "Anthropic", inUse: true, paused: paused,
            pausedSince: paused ? now.addingTimeInterval(-12 * 60) : nil, held: held,
            heldUntil: held ? now.addingTimeInterval(48 * hour) : nil,
            usageWindows: [
                .init(name: "five_hour", utilization: 0.41, resetsAt: now.addingTimeInterval(2 * hour + 20 * 60)),
                .init(name: "seven_day", utilization: 0.62, resetsAt: now.addingTimeInterval(48 * hour)),
            ],
            harnesses: ["claude"], kinds: ["implementation", "code_review"], fallbackFor: [], working: working, tokensToday: 14_600_000
        )
    }

    private let openAI = StateSnapshot.Provider(id: "openai", name: "OpenAI", harnesses: ["codex"])
    private let openRouter = StateSnapshot.Provider(
        id: "openrouter", name: "OpenRouter", inUse: true, harnesses: ["claude"], fallbackFor: ["qa", "ci_fix"], tokensToday: 52_000
    )

    private func page(_ providers: [StateSnapshot.Provider]?) -> ProvidersPage {
        ProvidersPage(providers: providers, now: now, timeZone: utc)
    }

    // MARK: The list

    func testProvidersInUseAreListedFirstThenThoseNotInUse() {
        // Symphony lists them in use first; the page keeps that even when a list comes mixed.
        let page = page([openAI, anthropic(), openRouter])
        XCTAssertEqual(page.ordered.map(\.id), ["anthropic", "openrouter", "openai"])
        XCTAssertEqual(page.sections.map(\.title), ["In use", "Not in use"])
        XCTAssertEqual(page.sections.map { $0.cards.map(\.id) }, [["anthropic", "openrouter"], ["openai"]])
        // A group with no provider isn't drawn.
        XCTAssertEqual(self.page([anthropic()]).sections.map(\.title), ["In use"])
        XCTAssertEqual(self.page(nil).sections, [])
        XCTAssertNil(self.page([]).detail(nil))
    }

    func testEachCardHasOneFactAndItsStateInALine() {
        let cards = page([anthropic(), openRouter, openAI]).sections.flatMap(\.cards)
        // The share of the week when Symphony reads it, else the tokens today, else nothing.
        XCTAssertEqual(cards.map(\.fact), ["62 % of the week", "52K today", nil])
        XCTAssertEqual(cards.map(\.statusLine), ["3 working", "Available", "Not in use"])
        XCTAssertEqual(cards.map(\.status), [.done, .done, .idle])
        XCTAssertEqual(cards.map(\.live), [true, false, false])
        XCTAssertEqual(cards.map(\.title), ["Anthropic", "OpenRouter", "OpenAI"])

        let paused = page([anthropic(paused: true)]).sections[0].cards[0]
        XCTAssertEqual(paused.statusLine, "Paused by you · 12 min")
        XCTAssertEqual(paused.status, .you)
        XCTAssertFalse(paused.live)
        let held = page([anthropic(held: true)]).sections[0].cards[0]
        XCTAssertEqual(held.statusLine, "Limit reached · until Thu 14:00")
        XCTAssertEqual(held.status, .problem)
    }

    func testTheSelectionFallsBackToTheFirstAndTheArrowsMoveIt() {
        let page = page([openAI, anthropic(), openRouter])
        XCTAssertEqual(page.selected(nil)?.id, "anthropic")
        XCTAssertEqual(page.selected("gone")?.id, "anthropic")
        XCTAssertEqual(page.selected("openai")?.id, "openai")
        XCTAssertEqual(page.id(after: nil, step: 1), "openrouter")
        XCTAssertEqual(page.id(after: "openrouter", step: 1), "openai")
        XCTAssertEqual(page.id(after: "openai", step: 1), "openai", "it stays at the end")
        XCTAssertEqual(page.id(after: "anthropic", step: -1), "anthropic", "it stays at the top")
        XCTAssertNil(self.page([]).id(after: nil, step: 1))
    }

    // MARK: The page

    func testAProvidersPageShowsItsStateUsageAndFacts() throws {
        let detail = try XCTUnwrap(page([anthropic(), openAI]).detail("anthropic"))
        XCTAssertEqual(detail.name, "Anthropic")
        XCTAssertEqual(detail.id, "anthropic")
        XCTAssertEqual(detail.state.word, "Available")
        XCTAssertEqual(detail.state.cause, "3 runs are working on it.")
        XCTAssertNil(detail.state.waits)
        XCTAssertEqual(detail.state.spoken, "Available. 3 runs are working on it.")
        XCTAssertEqual(detail.move, .pause)
        XCTAssertEqual(detail.usage, [
            .init(id: "five_hour", label: "5 hours", percent: 41, resets: "today 16:20"),
            .init(id: "seven_day", label: "Week", percent: 62, resets: "Thu 19 Nov, 14:00"),
        ])
        XCTAssertEqual(detail.facts.map(\.label), ["Harnesses", "Runs set to it", "Working now", "Tokens today"])
        XCTAssertEqual(detail.facts.map(\.value), ["Claude", "Implementation, Code Review", "3 runs", "14.6M"])

        let one = try XCTUnwrap(page([anthropic(working: 1)]).detail(nil))
        XCTAssertEqual(one.state.cause, "1 run is working on it.")
        XCTAssertEqual(one.facts.first { $0.label == "Working now" }?.value, "1 run")
        let idle = try XCTUnwrap(page([anthropic(working: 0)]).detail(nil))
        XCTAssertEqual(idle.state.cause, "No run is on it now.")
        XCTAssertNil(idle.facts.first { $0.label == "Working now" })
    }

    func testBlocksWithNothingToSayAreDropped() throws {
        // OpenRouter: no window Symphony can read, so no Usage block; a fallback only.
        let fallback = try XCTUnwrap(page([openRouter]).detail(nil))
        XCTAssertEqual(fallback.usage, [])
        XCTAssertEqual(fallback.facts.map(\.label), ["Harnesses", "Fallback for", "Tokens today"])
        XCTAssertEqual(fallback.facts[1].value, "QA, CI Fix")
        // A window without a share is no meter.
        var unread = anthropic()
        unread.usageWindows = [.init(name: "five_hour", utilization: nil, resetsAt: nil)]
        XCTAssertEqual(try XCTUnwrap(page([unread]).detail(nil)).usage, [])
        // Not in use: no Pause, no runs, its harness only.
        let unused = try XCTUnwrap(page([openAI]).detail(nil))
        XCTAssertNil(unused.move)
        XCTAssertNil(unused.action)
        XCTAssertEqual(unused.state.word, "Not in use")
        XCTAssertEqual(unused.state.cause, "No kind of run is set to it.")
        XCTAssertEqual(unused.facts, [.init(label: "Harnesses", value: "Codex")])
        // A harness or a kind Symphony names and the app doesn't know reads as named.
        let strange = StateSnapshot.Provider(id: "x", harnesses: ["pi"], kinds: ["triage"])
        XCTAssertEqual(page([strange]).detail(nil)?.facts.map(\.value), ["pi", "triage"])
        XCTAssertEqual(page([strange]).detail(nil)?.name, "x")
    }

    func testAPausedProviderResumesAndSaysWhatWaits() throws {
        let detail = try XCTUnwrap(page([anthropic(paused: true)]).detail(nil))
        XCTAssertEqual(detail.state.word, "Paused")
        XCTAssertEqual(detail.state.cause, "You paused it 12 min ago.")
        XCTAssertEqual(detail.state.waits, "New runs start on their fallbacks, or wait.")
        XCTAssertEqual(detail.state.spoken, "Paused. You paused it 12 min ago. New runs start on their fallbacks, or wait.")
        XCTAssertEqual(detail.move, .resume)
        XCTAssertEqual(detail.action, .resumeProvider("anthropic", name: "Anthropic"))

        // A pause Symphony gave no time for, and a provider not in use that is paused: it still offers Resume.
        var unused = openAI
        unused.paused = true
        let paused = try XCTUnwrap(page([unused]).detail(nil))
        XCTAssertEqual(paused.state.cause, "You paused it.")
        XCTAssertNil(paused.state.waits)
        XCTAssertEqual(paused.move, .resume)
        XCTAssertEqual(page([unused]).sections[0].cards[0].statusLine, "Paused by you")
    }

    func testAProviderAtItsLimitSaysWhenItResumes() throws {
        let detail = try XCTUnwrap(page([anthropic(held: true)]).detail(nil))
        XCTAssertEqual(detail.state.word, "Limit reached")
        XCTAssertEqual(detail.state.cause, "Its usage limit is reached.")
        XCTAssertEqual(detail.state.waits, "New runs start on their fallbacks, or wait. Resumes Thu 19 Nov, 14:00.")
        XCTAssertEqual(detail.move, .pause)

        var soon = anthropic(held: true)
        soon.heldUntil = now.addingTimeInterval(hour)
        XCTAssertEqual(page([soon]).sections[0].cards[0].statusLine, "Limit reached · until 15:00")
        soon.heldUntil = nil
        XCTAssertEqual(page([soon]).sections[0].cards[0].statusLine, "Limit reached")
        XCTAssertEqual(page([soon]).detail(nil)?.state.waits, "New runs start on their fallbacks, or wait.")
        // The Director's pause reads before the limit.
        XCTAssertEqual(page([anthropic(paused: true, held: true)]).detail(nil)?.state.word, "Paused")
    }

    func testPauseAndResumeCallTheControlAPI() throws {
        XCTAssertEqual(ProvidersPage.action(.pause, provider: "anthropic", name: "Anthropic"), .pauseProvider("anthropic", name: "Anthropic"))
        XCTAssertEqual(ProvidersPage.action(.resume, provider: "anthropic", name: "Anthropic"), .resumeProvider("anthropic", name: "Anthropic"))
        XCTAssertEqual(try XCTUnwrap(page([anthropic()]).detail(nil)).action, .pauseProvider("anthropic", name: "Anthropic"))
        XCTAssertEqual(ProvidersPage.Move.pause.title, "Pause")
        XCTAssertEqual(ProvidersPage.Move.resume.title, "Resume")
        XCTAssertEqual(ProvidersPage.Move.pause.glyph, "pause.fill")
        XCTAssertEqual(ProvidersPage.Move.resume.glyph, "play.fill")
    }

    /// The page shows what the state says: the state read after Pause draws Paused and Resume at once, and the one
    /// after Resume draws Available again.
    func testTheNewStateShowsAtOnce() throws {
        XCTAssertEqual(page([anthropic()]).detail(nil)?.move, .pause)
        XCTAssertEqual(page([anthropic(paused: true)]).detail(nil)?.state.word, "Paused")
        XCTAssertEqual(page([anthropic(paused: true)]).detail(nil)?.move, .resume)
        XCTAssertEqual(page([anthropic()]).detail(nil)?.state.word, "Available")
    }

    func testWindowNames() {
        XCTAssertEqual(ProvidersPage.windowLabel("five_hour"), "5 hours")
        XCTAssertEqual(ProvidersPage.windowLabel("seven_day"), "Week")
        XCTAssertEqual(ProvidersPage.windowLabel("seven_day_opus"), "Week, Opus")
        XCTAssertEqual(ProvidersPage.windowLabel("seven_day_sonnet"), "Week, Sonnet")
        XCTAssertEqual(ProvidersPage.windowLabel("monthly_credits"), "Monthly credits")
        XCTAssertEqual(ProvidersPage.percent(1.2), 100)
        XCTAssertEqual(ProvidersPage.percent(-0.1), 0)
    }

    // MARK: Factory › Runs

    private let runsYAML = """
        runs:
          default:
            harness: claude
            provider: anthropic
            model: claude-opus-5-5
          qa:
            fallbacks:
              - { provider: openrouter, model: deepseek/deepseek-flash }
              - { harness: opencode, provider: opencode-go, model: kimi-k3 }

        """

    private func runsPage() throws -> RunsPage {
        var page = RunsPage()
        page.load(try RunProfilesConfig.scopedProfiles(in: runsYAML), repositories: [])
        return page
    }

    func testARunsLineOnAPausedOrHeldProviderSaysSo() throws {
        var held = openRouter
        held.held = true
        let opencode = StateSnapshot.Provider(id: "opencode-go", name: "OpenCode Go", inUse: true)
        let page = try runsPage().showing([anthropic(paused: true), held, opencode])
        let qa = try XCTUnwrap(page.rows.first { $0.kind == .qa })
        XCTAssertEqual(qa.lines.map(\.providerNote), [
            .init(status: .you, text: "Anthropic is paused"),
            .init(status: .problem, text: "OpenRouter is at its limit"),
            nil,
        ])
        // Every kind on Anthropic says it.
        XCTAssertEqual(page.rows.first { $0.isDefault }?.lines.first?.providerNote?.text, "Anthropic is paused")
        XCTAssertEqual(page.providerNotes.keys.sorted(), ["anthropic", "openrouter"])

        // Resumed, the lines say nothing; a Symphony that predates the list leaves them as they are.
        var resumed = page
        resumed.showProviders([anthropic()])
        XCTAssertTrue(resumed.rows.flatMap(\.lines).allSatisfy { $0.providerNote == nil })
        XCTAssertEqual(try runsPage().showing(nil).providerNotes, [:])
        XCTAssertNil(RunsPage.ProviderNote.of(anthropic()))
    }
}
