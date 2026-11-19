import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// Factory › Providers (TP-1534): the list and the picked provider's page fit the laptop viewport side by side, a
/// provider with no usage to read draws no Usage block, and Runs lines on a paused provider draw their note.
@MainActor
final class ProvidersPageViewTests: XCTestCase {
    private let anthropic = StateSnapshot.Provider(
        id: "anthropic", name: "Anthropic", inUse: true, paused: true, pausedSince: Date(timeIntervalSinceNow: -720),
        usageWindows: [.init(name: "five_hour", utilization: 0.41), .init(name: "seven_day", utilization: 0.62)],
        harnesses: ["claude"], kinds: ["implementation"], working: 3, tokensToday: 14_600_000
    )
    private let openAI = StateSnapshot.Provider(id: "openai", name: "OpenAI", harnesses: ["codex"])

    private func fittingSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    func testThePageFitsTheLaptopViewportBesideTheSidebar() {
        let page = ProvidersPage(providers: [anthropic, openAI])
        let width = 1440 - DesignTokens.Layout.sidebarWidth
        let host = NSHostingView(rootView: ProvidersPageView(page: page, selection: nil, actions: .none, scrolls: false).frame(width: width))
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(Double(host.fittingSize.width), width)
        let main = width - 2 * DesignTokens.ProvidersPage.sides - DesignTokens.ProvidersPage.listWidth - DesignTokens.ProvidersPage.columnGap
        XCTAssertGreaterThan(main, 600, "the page beside the list keeps room for its meters")
    }

    func testABlockWithNothingToSayIsNotDrawn() throws {
        let page = ProvidersPage(providers: [anthropic, openAI])
        let withUsage = fittingSize(ProviderDetailView(detail: try XCTUnwrap(page.detail("anthropic")), actions: .none).frame(width: 800))
        // A provider whose usage Symphony can't read: no meters and no "Stop new runs at".
        var unread = anthropic
        unread.id = "openrouter"
        unread.usageWindows = []
        let without = fittingSize(
            ProviderDetailView(detail: try XCTUnwrap(ProvidersPage(providers: [unread]).detail(nil)), actions: .none).frame(width: 800)
        )
        XCTAssertGreaterThan(withUsage.height, without.height + 2 * DesignTokens.ProvidersPage.meterGap, "the Usage block is gone")
    }

    /// "Stop new runs at" (TP-1535) is drawn under the meters, and a pick asks for the reserve to be saved; with no
    /// window read yet the Usage block holds it alone.
    func testStopNewRunsAtIsDrawnAndAPickSavesIt() throws {
        var reserved = anthropic
        reserved.reserve = 0.9
        var picked: [(String, Int?)] = []
        let actions = ProvidersPageActions(select: { _ in }, send: { _ in }, setReserve: { picked.append(($0, $1)) })
        let detail = try XCTUnwrap(ProvidersPage(providers: [reserved]).detail(nil))
        let reserve = try XCTUnwrap(detail.reserve)
        let row = ProviderReserveRow(id: detail.id, name: detail.name, reserve: reserve, actions: actions)
        XCTAssertGreaterThanOrEqual(Double(fittingSize(row.frame(width: 600)).height), DesignTokens.ProvidersPage.reserveControl.height)
        row.actions.setReserve("anthropic", 80)
        XCTAssertEqual(picked.map(\.0), ["anthropic"])
        XCTAssertEqual(picked.map(\.1), [80])

        var unread = reserved
        unread.usageWindows = []
        let alone = fittingSize(ProviderDetailView(detail: try XCTUnwrap(ProvidersPage(providers: [unread]).detail(nil)), actions: actions).frame(width: 800))
        var unknown = unread
        unknown.id = "openrouter"
        let none = fittingSize(ProviderDetailView(detail: try XCTUnwrap(ProvidersPage(providers: [unknown]).detail(nil)), actions: actions).frame(width: 800))
        XCTAssertGreaterThan(alone.height, none.height, "the Usage block holds Stop new runs at")

        // While a save is on its way the row draws its spinner and asks for nothing more.
        let saving = ProvidersPage.ReserveControl(percent: 90, choices: [80, 90], saving: true)
        XCTAssertGreaterThan(fittingSize(ProviderReserveRow(id: "anthropic", name: "Anthropic", reserve: saving, ruled: false, actions: actions)).width, 0)
        ProvidersPageActions.none.setReserve("anthropic", nil)
    }

    func testPauseSendsItsControl() throws {
        var sent: [ControlAction] = []
        let actions = ProvidersPageActions(select: { _ in }, send: { sent.append($0) })
        let detail = try XCTUnwrap(ProvidersPage(providers: [anthropic]).detail(nil))
        let view = ProviderDetailView(detail: detail, actions: actions)
        _ = fittingSize(view.frame(width: 800))
        view.actions.send(try XCTUnwrap(detail.action))
        XCTAssertEqual(sent, [.resumeProvider("anthropic", name: "Anthropic")])
        // The still picture's actions do nothing.
        ProvidersPageActions.none.select("anthropic")
        ProvidersPageActions.none.send(.pauseProvider("anthropic", name: "Anthropic"))
        XCTAssertEqual(sent.count, 1)
    }

    func testARunsLineOnAPausedProviderDrawsItsNote() {
        let note = RunsPage.ProviderNote(status: .you, text: "Anthropic is paused")
        XCTAssertGreaterThan(fittingSize(RunsProviderNoteView(note: note)).width, DesignTokens.RunsPage.offDot + DesignTokens.RunsPage.offNoteInset)
        XCTAssertGreaterThan(fittingSize(ProviderSituationLine(state: ProvidersPage(providers: [anthropic]).state(anthropic)).frame(width: 600)).height, 0)
    }

    // MARK: The Key block (TP-1540)

    func testAProviderSetUpWithAKeyDrawsItsKeyBlock() throws {
        let openCodeGo = StateSnapshot.Provider(id: "opencode-go", name: "OpenCode Go", harnesses: ["opencode"])
        let without = try XCTUnwrap(ProvidersPage(providers: [openCodeGo]).detail(nil))
        var editor = ProviderKeyEditor()
        var keys = ProviderKeys()
        editor.edit("opencode-go", to: "sk-go", keys: keys)
        _ = editor.beginTest("opencode-go", keys: keys)
        keys = try XCTUnwrap(editor.finishTest("opencode-go", key: "sk-go", result: .works("OpenCode Go accepted the key"), keys: keys))
        let with = try XCTUnwrap(ProvidersPage(providers: [openCodeGo], keys: keys, keyEditor: editor).detail(nil))
        XCTAssertEqual(with.key?.toggle, true)
        let plain = fittingSize(ProviderDetailView(detail: without, actions: .none).frame(width: 800)).height
        let keyed = fittingSize(ProviderDetailView(detail: with, actions: .none).frame(width: 800)).height
        XCTAssertGreaterThan(keyed, plain + DesignTokens.ProvidersPage.control.height, "the Key block is drawn")

        // The test's result is one line, however long it is.
        let short = fittingSize(ProviderSituationLine(state: ProvidersPage.state(.works("ok")), oneLine: true).frame(width: 400)).height
        let long = fittingSize(
            ProviderSituationLine(state: ProvidersPage.state(.fails(String(repeating: "rejected ", count: 40))), oneLine: true).frame(width: 400)
        ).height
        XCTAssertEqual(long, short, accuracy: 1)

        // While a test runs, the block shows it; Disable while on; each action reaches its handler.
        var calls: [String] = []
        let actions = ProvidersPageActions(
            select: { _ in }, send: { _ in }, editKey: { calls.append("edit \($0) \($1)") }, testKey: { calls.append("test \($0)") },
            setEnabled: { calls.append("enable \($0) \($1)") }, removeKey: { calls.append("remove \($0)") }
        )
        let on = try XCTUnwrap(ProvidersPage(providers: [openCodeGo], keys: keys.enabling("opencode-go", true), keyEditor: editor).detail(nil)?.key)
        XCTAssertEqual(on.toggle, false)
        _ = fittingSize(ProviderKeyBlock(id: "opencode-go", name: "OpenCode Go", key: on, actions: actions).frame(width: 800))
        var testing = editor
        _ = testing.beginTest("opencode-go", keys: keys)
        let running = try XCTUnwrap(ProvidersPage(providers: [openCodeGo], keys: keys, keyEditor: testing).detail(nil)?.key)
        XCTAssertTrue(running.testing)
        _ = fittingSize(ProviderKeyBlock(id: "opencode-go", name: "OpenCode Go", key: running, actions: actions).frame(width: 800))
        actions.editKey("opencode-go", "k")
        actions.testKey("opencode-go")
        actions.setEnabled("opencode-go", false)
        actions.removeKey("opencode-go")
        XCTAssertEqual(calls, ["edit opencode-go k", "test opencode-go", "enable opencode-go false", "remove opencode-go"])
        // The still picture's actions do nothing.
        ProvidersPageActions.none.editKey("opencode-go", "k")
        ProvidersPageActions.none.testKey("opencode-go")
        ProvidersPageActions.none.setEnabled("opencode-go", true)
        ProvidersPageActions.none.removeKey("opencode-go")
    }

    func testTheSecureFieldDrawsItsKeyMasked() {
        XCTAssertEqual(DirectorTextField.stillText("sk-go", placeholder: "OPENCODE_API_KEY", secure: true), "•••••")
        XCTAssertEqual(DirectorTextField.stillText("", placeholder: "OPENCODE_API_KEY", secure: true), "OPENCODE_API_KEY")
        XCTAssertEqual(DirectorTextField.stillText("sk-go", placeholder: "", secure: false), "sk-go")
    }
}
