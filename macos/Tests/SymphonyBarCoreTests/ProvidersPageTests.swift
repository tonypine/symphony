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

    // MARK: The reserve (TP-1535)

    private func reserved(_ reserve: Double? = 0.9, atReserve: Bool = false) -> StateSnapshot.Provider {
        var provider = anthropic()
        provider.reserve = reserve
        if atReserve {
            provider.atReserve = true
            provider.held = true
            provider.heldUntil = now.addingTimeInterval(48 * hour)
            provider.usageWindows[1].utilization = 0.91
        }
        return provider
    }

    func testAProviderWhoseUsageSymphonyReadsHasStopNewRunsAtAndEachMeterItsMark() throws {
        let detail = try XCTUnwrap(page([reserved(), openAI]).detail("anthropic"))
        XCTAssertEqual(detail.reserve, .init(percent: 90, choices: [50, 60, 70, 75, 80, 85, 90, 95], saving: false))
        XCTAssertEqual(detail.reserve?.title, "90 %")
        XCTAssertEqual(detail.usage.map(\.stop), [90, 90])
        XCTAssertEqual(ProvidersPage.reserveTitle, "Stop new runs at")

        // No reserve: no mark, and the pop-up says so.
        let none = try XCTUnwrap(page([reserved(nil)]).detail(nil))
        XCTAssertEqual(none.reserve?.percent, nil)
        XCTAssertEqual(none.reserve?.title, "No reserve")
        XCTAssertEqual(none.usage.map(\.stop), [nil, nil])

        // A share the pop-up doesn't usually offer is offered too, in order.
        XCTAssertEqual(page([reserved(0.83)]).detail(nil)?.reserve?.choices, [50, 60, 70, 75, 80, 83, 85, 90, 95])
    }

    /// OpenCode Go's usage is read too (TP-1642): its 5-hour, weekly and monthly windows are meters with their reset
    /// times and the reserve's mark, and it has "Stop new runs at" like Anthropic.
    func testOpenCodeGoHasItsWindowsAndStopNewRunsAtLikeAnthropic() throws {
        let go = StateSnapshot.Provider(
            id: "opencode-go", name: "OpenCode Go", inUse: true,
            usageWindows: [
                .init(name: "five_hour", utilization: 0.3, resetsAt: now.addingTimeInterval(hour)),
                .init(name: "monthly", utilization: 0.5, resetsAt: now.addingTimeInterval(14 * 24 * hour)),
                .init(name: "seven_day", utilization: 0.92, resetsAt: now.addingTimeInterval(48 * hour)),
            ],
            harnesses: ["claude", "codex", "opencode"], fallbackFor: ["implementation"], reserve: 0.9
        )
        let detail = try XCTUnwrap(page([anthropic(), go]).detail("opencode-go"))
        XCTAssertEqual(detail.reserve, .init(percent: 90, choices: [50, 60, 70, 75, 80, 85, 90, 95], saving: false))
        // Shortest window first, whatever order the windows come in: 5 hours, Week, Month.
        XCTAssertEqual(detail.usage.map(\.label), ["5 hours", "Week", "Month"])
        XCTAssertEqual(detail.usage.map(\.percent), [30, 92, 50])
        XCTAssertEqual(detail.usage.map(\.stop), [90, 90, 90])
        XCTAssertEqual(detail.usage.map(\.resets), ["today 15:00", "Thu 19 Nov, 14:00", "Tue 1 Dec, 14:00"])
        // Anthropic's weeks keep their place after the 5 hours; a window the app doesn't know comes last.
        var anthropic = anthropic()
        anthropic.usageWindows = ["other", "seven_day_opus", "seven_day", "five_hour"].map { .init(name: $0, utilization: 0.1) }
        XCTAssertEqual(try XCTUnwrap(page([anthropic]).detail(nil)).usage.map(\.id), ["five_hour", "seven_day", "seven_day_opus", "other"])
    }

    func testAProviderWhoseUsageSymphonyCantReadHasNoStopNewRunsAt() throws {
        XCTAssertNil(try XCTUnwrap(page([openAI]).detail(nil)).reserve)
        XCTAssertNil(try XCTUnwrap(page([openRouter]).detail(nil)).reserve)
    }

    func testASavedReserveShowsAtOnceAndTheMarkMovesUntilSymphonySaysTheSame() throws {
        let saved = ProvidersPage(providers: [reserved()], now: now, timeZone: utc, savedReserves: ["anthropic": 80], savingReserve: nil)
        let detail = try XCTUnwrap(saved.detail(nil))
        XCTAssertEqual(detail.reserve?.percent, 80)
        XCTAssertEqual(detail.usage.map(\.stop), [80, 80])
        let cleared = ProvidersPage(providers: [reserved()], now: now, timeZone: utc, savedReserves: ["anthropic": Int?.none])
        XCTAssertNil(try XCTUnwrap(cleared.detail(nil)).reserve?.percent)
        let saving = ProvidersPage(providers: [reserved()], now: now, timeZone: utc, savingReserve: "anthropic")
        XCTAssertEqual(saving.detail(nil)?.reserve?.saving, true)

        // Once Symphony's state says 80 %, the saved one goes; a different one stays.
        XCTAssertEqual(ProvidersPage.settledReserves(["anthropic": 80], providers: [reserved(0.8)]), [:])
        XCTAssertEqual(ProvidersPage.settledReserves(["anthropic": 80], providers: [reserved(0.9)]), ["anthropic": 80])
        XCTAssertEqual(ProvidersPage.settledReserves(["anthropic": Int?.none], providers: [reserved(nil)]), [:])
        XCTAssertEqual(ProvidersPage.settledReserves(["anthropic": 80], providers: nil), ["anthropic": 80])
    }

    func testAProviderAtItsReserveSaysSoAndWhenItResumes() throws {
        let detail = try XCTUnwrap(page([reserved(atReserve: true)]).detail(nil))
        XCTAssertEqual(detail.state.word, "At your reserve")
        XCTAssertEqual(detail.state.status, .you)
        XCTAssertEqual(detail.state.cause, "The week is at 91 %, where you stop new runs.")
        XCTAssertEqual(detail.state.waits, "New runs start on their fallbacks, or wait. Resumes Thu 19 Nov, 14:00.")
        XCTAssertEqual(page([reserved(atReserve: true)]).sections[0].cards[0].statusLine, "At your reserve · until Thu 14:00")

        var unknown = reserved(nil, atReserve: true)
        unknown.heldUntil = nil
        unknown.usageWindows = []
        let state = try XCTUnwrap(page([unknown]).detail(nil)).state
        XCTAssertEqual(state.cause, "It is at your reserve, where you stop new runs.")
        XCTAssertEqual(state.short, "At your reserve")
        // The Director's pause reads before the reserve.
        var paused = reserved(atReserve: true)
        paused.paused = true
        XCTAssertEqual(page([paused]).detail(nil)?.state.word, "Paused")
        XCTAssertEqual(ProvidersPage.windowSubject("five_hour"), "The 5 hours")
        XCTAssertEqual(ProvidersPage.windowSubject("seven_day_opus"), "The Opus week")
        XCTAssertEqual(ProvidersPage.windowSubject("seven_day_sonnet"), "The Sonnet week")
        XCTAssertEqual(ProvidersPage.windowSubject("monthly_credits"), "The monthly credits")
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
        XCTAssertEqual(ProvidersPage.windowLabel("monthly"), "Month")
        XCTAssertEqual(ProvidersPage.windowSubject("monthly"), "The month")
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

    func testARunsLineOnAProviderAtItsReserveSaysSo() throws {
        let page = try runsPage().showing([reserved(atReserve: true)])
        XCTAssertEqual(page.rows.first { $0.isDefault }?.lines.first?.providerNote, .init(status: .you, text: "Anthropic is at its 90 % reserve"))
        XCTAssertEqual(RunsPage.ProviderNote.of(reserved(nil, atReserve: true))?.text, "Anthropic is at its reserve")
    }

    // MARK: Keys (TP-1540)

    private let openCodeGo = StateSnapshot.Provider(id: "opencode-go", name: "OpenCode Go", harnesses: ["claude", "codex", "opencode"])

    private func keyed(_ keys: ProviderKeys, _ editor: ProviderKeyEditor = ProviderKeyEditor()) -> ProvidersPage {
        ProvidersPage(providers: [anthropic(), openRouter, openCodeGo], now: now, timeZone: utc, keys: keys, keyEditor: editor)
    }

    func testAProviderNotInUseWithNoKeyHasAnEmptyKeyBlockAndNoEnable() throws {
        let detail = try XCTUnwrap(keyed(ProviderKeys()).detail("opencode-go"))
        let key = try XCTUnwrap(detail.key)
        XCTAssertEqual(key.variable, "OPENCODE_API_KEY")
        XCTAssertEqual(key.text, "")
        XCTAssertFalse(key.stored)
        XCTAssertFalse(key.canTest)
        XCTAssertNil(key.toggle, "no Enable yet")
        XCTAssertNil(key.result)
        XCTAssertEqual(detail.state.word, "Off")
        XCTAssertEqual(detail.state.cause, "It has no key.")
        XCTAssertEqual(detail.facts.first, .init(label: "Key", value: "OPENCODE_API_KEY · not set"))
        // Anthropic signs in through its harness: no Key block, no Key fact.
        let anthropic = try XCTUnwrap(keyed(ProviderKeys()).detail("anthropic"))
        XCTAssertNil(anthropic.key)
        XCTAssertFalse(anthropic.facts.contains { $0.label == "Key" })
        // Until the keys are read, no provider has a Key block, and nothing reads Off.
        XCTAssertNil(page([openCodeGo]).detail(nil)?.key)
        XCTAssertEqual(page([openCodeGo]).detail(nil)?.state.word, "Not in use")
    }

    func testAHeldProviderInUseReadsAtItsLimitEvenWithNoKeyInTheApp() throws {
        // Symphony runs on OpenCode Go and holds it at its weekly limit (TP-1617); the app's own key store has no key.
        let until = now.addingTimeInterval(15 * hour)
        let held = StateSnapshot.Provider(
            id: "opencode-go", name: "OpenCode Go", inUse: true, held: true, heldUntil: until,
            harnesses: ["claude"], fallbackFor: ["ci_fix"]
        )
        let page = ProvidersPage(providers: [anthropic(), held], now: now, timeZone: utc, keys: ProviderKeys(), keyEditor: ProviderKeyEditor())
        let detail = try XCTUnwrap(page.detail("opencode-go"))
        XCTAssertEqual(detail.state.word, "Limit reached")
        XCTAssertEqual(detail.state.status, .problem)
        XCTAssertEqual(detail.state.short, "Limit reached · until Wed 05:00")
        XCTAssertEqual(detail.state.waits, "New runs start on their fallbacks, or wait. Resumes Wed 18 Nov, 05:00.")
        XCTAssertEqual(page.sections[0].cards.last?.statusLine, "Limit reached · until Wed 05:00")
        // At its reserve, the same: the hold reads, not Off.
        let reserved = StateSnapshot.Provider(id: "opencode-go", name: "OpenCode Go", inUse: true, harnesses: ["claude"], atReserve: true)
        XCTAssertEqual(page.state(reserved).word, "At your reserve")
        // Not in use and held by Symphony, the hold reads too, as the status menu says it: not Off, not Not in use.
        var idleReserved = reserved
        idleReserved.inUse = false
        XCTAssertEqual(page.state(idleReserved).word, "At your reserve")
        XCTAssertEqual(ProvidersPage(providers: [idleReserved], now: now, timeZone: utc).state(idleReserved).word, "At your reserve")
        var idleHeld = held
        idleHeld.inUse = false
        XCTAssertEqual(page.state(idleHeld).word, "Limit reached")
        // Not in use, or in use and not held, a provider with no key stays Off.
        XCTAssertEqual(page.state(openCodeGo).word, "Off")
        let free = StateSnapshot.Provider(id: "opencode-go", name: "OpenCode Go", inUse: true, harnesses: ["claude"])
        XCTAssertEqual(page.state(free).word, "Off")
    }

    func testATestThatPassesOffersEnableAndEnableMakesItAvailable() throws {
        var editor = ProviderKeyEditor()
        var keys = ProviderKeys()
        editor.edit("opencode-go", to: "sk-go", keys: keys)
        XCTAssertEqual(keyed(keys, editor).detail("opencode-go")?.key?.canTest, true)
        _ = editor.beginTest("opencode-go", keys: keys)
        XCTAssertEqual(keyed(keys, editor).detail("opencode-go")?.key?.testing, true)
        keys = try XCTUnwrap(editor.finishTest("opencode-go", key: "sk-go", result: .works("OpenCode Go accepted the key · 2 models"), keys: keys))

        let tested = try XCTUnwrap(keyed(keys, editor).detail("opencode-go"))
        XCTAssertEqual(tested.key?.result, .works("OpenCode Go accepted the key · 2 models"))
        XCTAssertEqual(tested.key?.toggle, true, "Enable")
        XCTAssertEqual(tested.key?.stored, true)
        XCTAssertEqual(tested.state.word, "Off")
        XCTAssertEqual(tested.state.cause, "You turned it off.")

        let enabled = try XCTUnwrap(keyed(keys.enabling("opencode-go", true), editor).detail("opencode-go"))
        XCTAssertEqual(enabled.state.word, "Available")
        XCTAssertEqual(enabled.state.status, .done)
        XCTAssertEqual(enabled.key?.toggle, false, "Disable")
        XCTAssertEqual(enabled.facts.first?.value, "OPENCODE_API_KEY · set")
        XCTAssertEqual(keyed(keys.enabling("opencode-go", true), editor).sections.last?.cards.last?.statusLine, "Available")
    }

    func testDisableTurnsAProviderOffAndKeepsItsKey() throws {
        let enabled = ProviderKeys(keys: ["opencode-go": "sk-go", "openrouter": "sk-or"], enabled: ["opencode-go", "openrouter"])
        let disabled = enabled.enabling("opencode-go", false)
        XCTAssertEqual(disabled.keys, enabled.keys, "Disable keeps the key")

        let detail = try XCTUnwrap(keyed(disabled).detail("opencode-go"))
        XCTAssertEqual(detail.state.word, "Off")
        XCTAssertEqual(detail.facts.first?.value, "OPENCODE_API_KEY · set")
        XCTAssertEqual(detail.key?.stored, true)
        XCTAssertEqual(keyed(disabled).sections.last?.cards.last?.statusLine, "Off")

        // Provider on Factory › Runs no longer offers OpenCode Go.
        let choices = { (page: RunsPage) -> [String?] in
            page.rows.first { $0.kind == nil }!.lines[0].fields.first { $0.field == .provider }!.choices.map(\.value)
        }
        XCTAssertTrue(choices(try runsPage().showing(nil, off: enabled.off)).contains("opencode-go"))
        XCTAssertFalse(choices(try runsPage().showing(nil, off: disabled.off)).contains("opencode-go"))
    }

    func testAKeyTestsResultReadsAsASituationLine() {
        XCTAssertEqual(ProvidersPage.state(.works("ok")).status, .done)
        XCTAssertEqual(ProvidersPage.state(.works("ok")).spoken, "Works. ok")
        XCTAssertEqual(ProvidersPage.state(.fails("no")).status, .problem)
        XCTAssertEqual(ProvidersPage.state(.fails("no")).word, "Failed")
    }

    func testAnEnabledProviderInUseReadsAsBeforeAndThePausePrevails() throws {
        let keys = ProviderKeys(keys: ["openrouter": "sk-or"], enabled: ["openrouter"])
        XCTAssertEqual(keyed(keys).detail("openrouter")?.state.word, "Available")
        XCTAssertEqual(keyed(keys).detail("openrouter")?.move, .pause)
        XCTAssertEqual(keyed(ProviderKeys(keys: ["openrouter": "sk-or"])).detail("openrouter")?.state.word, "Off")
        var paused = openRouter
        paused.paused = true
        let page = ProvidersPage(providers: [paused], now: now, timeZone: utc, keys: ProviderKeys())
        XCTAssertEqual(page.detail(nil)?.state.word, "Paused")
    }

    func testRunsProviderOffersOnlyEnabledProvidersExceptOnALineAlreadySetToOne() throws {
        let keys = ProviderKeys(keys: ["opencode-go": "sk-go", "openrouter": "sk-or"], enabled: ["opencode-go", "openrouter"])
        let on = try runsPage().showing(nil, off: keys.off)
        let providerChoices = { (page: RunsPage, kind: RunKind?, line: Int) -> [String?] in
            page.rows.first { $0.kind == kind }!.lines[line].fields.first { $0.field == .provider }!.choices.map(\.value)
        }
        XCTAssertEqual(providerChoices(on, nil, 0), ["anthropic", "openrouter", "opencode-go"])

        let off = try runsPage().showing(nil, off: keys.enabling("opencode-go", false).off)
        XCTAssertEqual(providerChoices(off, nil, 0), ["anthropic", "openrouter"], "OpenCode Go is no longer offered")
        // QA's last fallback is already set to OpenCode Go: it keeps it, and says the provider is off.
        let qa = try XCTUnwrap(off.rows.first { $0.kind == .qa })
        XCTAssertEqual(providerChoices(off, .qa, 2), ["opencode-go"])
        XCTAssertEqual(qa.lines[2].providerNote, .init(status: .idle, text: "OpenCode Go is off"))
        XCTAssertNil(qa.lines[1].providerNote)
        // Off reads before a pause.
        let both = try runsPage().showing([anthropic(), StateSnapshot.Provider(id: "opencode-go", name: "OpenCode Go", inUse: true, paused: true)], off: ["opencode-go"])
        XCTAssertEqual(both.rows.first { $0.kind == .qa }?.lines[2].providerNote?.text, "OpenCode Go is off")
    }
}
