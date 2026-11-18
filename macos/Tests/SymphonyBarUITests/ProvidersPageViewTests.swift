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
        var unread = anthropic
        unread.usageWindows = []
        let without = fittingSize(
            ProviderDetailView(detail: try XCTUnwrap(ProvidersPage(providers: [unread]).detail(nil)), actions: .none).frame(width: 800)
        )
        XCTAssertGreaterThan(withUsage.height, without.height + 2 * DesignTokens.ProvidersPage.meterGap, "the Usage block is gone")
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
}
