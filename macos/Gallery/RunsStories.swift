import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

// Factory › Runs (TP-1538): the page as the catalog draws it, from a `symphony.yml` with Default, QA's own model and
// two fallbacks, web-shop's own values, and each harness's command and small models (TP-1539). Each story is one
// state the walkthrough reaches.

private let runsYAML = """
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
      code_review:
        effort: high
    repositories:
      - key: web-shop
        runs:
          qa:
            effort: low
      - key: docs
    execution:
      harnesses:
        claude:
          command: claude --dangerously-skip-permissions
          small_model:
            anthropic: claude-haiku-5-5
            openrouter: deepseek/deepseek-flash
        opencode:
          command: opencode
          small_model:
            opencode-go: hy4-flash

    """

/// The page loaded from `runsYAML`, then changed by `change`.
@MainActor
func runsPageState(_ change: (inout RunsPage) -> Void = { _ in }) -> RunsPage {
    var page = RunsPage()
    page.load(try! RunProfilesConfig.scopedProfiles(in: runsYAML), repositories: try! RunProfilesConfig.repositoryKeys(in: runsYAML))
    change(&page)
    return page
}

/// The page in a window `window` pt wide, beside the sidebar, drawn unscrolled at its whole height: the picture
/// renderer draws a scroll view empty.
@MainActor
func runsScreen(_ page: RunsPage, drawn: RunsPageDrawn? = nil, window: CGFloat) -> some View {
    RunsPageView(page: page, actions: .none, drawn: drawn, scrolls: false)
        .frame(width: window - DesignTokens.Layout.sidebarWidth, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(DesignTokens.Surface.window.color)
}

/// The page's states, by name: what opens, a pick not saved, a fallback added and dragged, saving, saved, refused, and
/// one repository's own values.
@MainActor
let runsStates: [(name: String, page: RunsPage, drawn: RunsPageDrawn?)] = [
    ("runs-page", runsPageState(), nil),
    ("runs-page-model-open", runsPageState(), RunsPageDrawn(modelOpen: ("qa", 0), query: "sonn")),
    ("runs-page-one-change", runsPageState { $0.pick(.model, of: 0, kind: .qa, to: "claude-opus-5-5") }, nil),
    ("runs-page-fallback-dragged", runsPageState {
        $0.addFallback(.qa)
        $0.reorder(.qa, to: [0, 3, 1, 2])
    }, RunsPageDrawn(dragging: ("qa", 1))),
    ("runs-page-saving", runsPageState {
        $0.pick(.model, of: 0, kind: .qa, to: "claude-opus-5-5")
        _ = $0.beginSave()
    }, nil),
    ("runs-page-saved", runsPageState {
        $0.pick(.model, of: 0, kind: .qa, to: "claude-opus-5-5")
        if let editor = $0.beginSave() { $0.finishSave(.saved(editor.profiles)) }
    }, nil),
    ("runs-page-refused", runsPageState {
        $0.pick(.model, of: 0, kind: .qa, to: "claude-opus-5-5")
        _ = $0.beginSave()
        $0.finishSave(.refused("runs.qa.fallbacks[1]: opencode reaches no provider opencode-go"))
    }, nil),
    ("runs-page-repository", runsPageState { $0.show(.repository("web-shop")) }, nil),
    ("runs-page-small-model-changed", runsPageState {
        $0.pickSmallModel("claude-sonnet-5-5", of: .claude, on: RunProfilesConfig.anthropic)
    }, nil),
    ("runs-page-conductor", runsPageState { $0.pick(.effort, of: 0, kind: .conductor, to: "high") }, nil),
]
