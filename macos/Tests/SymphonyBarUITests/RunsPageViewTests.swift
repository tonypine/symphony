import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// Factory › Runs (TP-1538): a kind's widest line fits the laptop viewport's page beside its name, and the page draws
/// every row under its Save bar.
@MainActor
final class RunsPageViewTests: XCTestCase {
    private let yaml = """
        runs:
          default:
            harness: claude
            provider: anthropic
            model: claude-opus-5-5
            effort: medium
          qa:
            model: claude-sonnet-5-5
            fallbacks:
              - { provider: openrouter, model: deepseek/deepseek-flash }
              - { harness: opencode, provider: opencode-go, model: deepseek-v4-pro }

        """

    private func page() throws -> RunsPage {
        var page = RunsPage()
        page.load(try RunProfilesConfig.scopedProfiles(in: yaml), repositories: ["web-shop"])
        return page
    }

    private func fittingSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// The laptop viewport (1440 pt) less the widest sidebar and the page's sides.
    private var laptopPage: Double {
        1440 - DesignTokens.Layout.maxSidebarWidth - 2 * DesignTokens.RunsPage.sides
    }

    func testTheWidestRowFitsTheLaptopPage() throws {
        let page = try page()
        let qa = try XCTUnwrap(page.rows.first { $0.kind == .qa })
        let size = fittingSize(RunsRowView(row: qa, actions: .none, drawn: RunsPageDrawn()))
        XCTAssertLessThanOrEqual(Double(size.width), laptopPage, "the QA row is \(Int(size.width)) pt wide")
        XCTAssertGreaterThan(size.width, DesignTokens.RunsPage.kindWidth)
    }

    func testEachLineIsOneLineTallAndAKindWithNoFallbackKeepsItsNoteBesideAddAFallback() throws {
        let page = try page()
        let list = DesignTokens.ReorderableList.self
        let qa = try XCTUnwrap(page.rows.first { $0.kind == .qa })
        let implementation = try XCTUnwrap(page.rows.first { $0.kind == .implementation })
        let tall = fittingSize(RunsRowView(row: qa, actions: .none, drawn: RunsPageDrawn())).height
        let short = fittingSize(RunsRowView(row: implementation, actions: .none, drawn: RunsPageDrawn())).height
        XCTAssertEqual(Double(tall - short), 2 * (list.lineHeight + list.gap), accuracy: 2, "two more lines, nothing else")
    }

    func testThePageDrawsWithTheBarAndEveryState() throws {
        var page = try page()
        page.pick(.model, of: 0, kind: .implementation, to: "claude-sonnet-5-5")
        for save in [RunsPage.Save.editing, .saving, .saved, .refused("runs.qa resolves no model")] {
            var shown = page
            if save != .editing { _ = shown.beginSave() }
            switch save {
            case .saved: shown.finishSave(.saved(shown.editor!.profiles))
            case .refused(let reason): shown.finishSave(.refused(reason))
            default: break
            }
            let host = NSHostingView(rootView: RunsPageView(
                page: shown, actions: .none, drawn: RunsPageDrawn(modelOpen: ("qa", 1), query: "deep", dragging: ("qa", 2))
            ))
            host.frame = CGRect(x: 0, y: 0, width: 1180, height: 900)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(shown.save, save)
        }
        XCTAssertEqual(RunsPageDrawn(modelOpen: ("qa", 1)), RunsPageDrawn(modelOpen: ("qa", 1)))
        XCTAssertNotEqual(RunsPageDrawn(modelOpen: ("qa", 1)), RunsPageDrawn(dragging: ("qa", 1)))
    }
}
