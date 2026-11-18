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

    /// The laptop viewport (1440 pt) less the sidebar and the page's sides.
    private var laptopPage: Double {
        1440 - DesignTokens.Layout.sidebarWidth - 2 * DesignTokens.RunsPage.sides
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
        let unscrolled = NSHostingView(rootView: RunsPageView(page: page, actions: .none, scrolls: false))
        unscrolled.frame = CGRect(x: 0, y: 0, width: 1180, height: 900)
        unscrolled.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(unscrolled.fittingSize.height, 400, "unscrolled, the page is drawn at its whole height")
        XCTAssertEqual(RunsPageDrawn(modelOpen: ("qa", 1)), RunsPageDrawn(modelOpen: ("qa", 1)))
        XCTAssertNotEqual(RunsPageDrawn(modelOpen: ("qa", 1)), RunsPageDrawn(dragging: ("qa", 1)))
    }

    func testTheHarnessesBlockFitsTheLaptopPageWithOneLinePerHarness() throws {
        let page = try page()
        let rows = page.harnessRows
        XCTAssertEqual(rows.map(\.harness), [.claude, .opencode])
        XCTAssertEqual(rows[0].smallModels.map(\.provider), [RunProfilesConfig.anthropic, RunProfilesConfig.openRouter])
        let block = fittingSize(RunsHarnessesView(rows: rows, actions: .none).frame(width: laptopPage))
        let one = fittingSize(RunsHarnessesView(rows: Array(rows.prefix(1)), actions: .none).frame(width: laptopPage))
        let row = fittingSize(RunsHarnessRowView(row: rows[0], actions: .none).frame(width: laptopPage))
        XCTAssertLessThan(row.height, 2 * DesignTokens.Control.small.height, "a harness and its small models fit one line")
        XCTAssertGreaterThan(block.height, one.height + row.height - 1, "each harness is a row of its own")

        var repository = page
        repository.show(.repository("web-shop"))
        let all = NSHostingView(rootView: RunsPageView(page: page, actions: .none, scrolls: false))
        let oneRepository = NSHostingView(rootView: RunsPageView(page: repository, actions: .none, scrolls: false))
        for host in [all, oneRepository] {
            host.frame = CGRect(x: 0, y: 0, width: 1180, height: 900)
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertGreaterThan(all.fittingSize.height, oneRepository.fittingSize.height, "a repository's values show no Harnesses")
    }
}
