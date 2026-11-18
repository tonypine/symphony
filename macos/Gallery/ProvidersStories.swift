import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

// Factory › Providers (TP-1534): the page as the catalog draws it (`providersPage`), from the catalog's four providers:
// Anthropic in use with its two windows and three runs on it, OpenCode Go and OpenRouter in use with no window to
// read, OpenAI not in use. Each story is one state the walkthrough reaches, and Runs with a provider paused.

/// Symphony's clock for the stories: Tuesday 17 November 2026, 14:00 UTC.
private let providersNow = Date(timeIntervalSince1970: 1_794_924_000)

/// The catalog's providers, Anthropic in `anthropic`'s state.
func galleryProviders(anthropic: (paused: Bool, held: Bool) = (false, false)) -> [StateSnapshot.Provider] {
    let hour: TimeInterval = 3600
    return [
        .init(
            id: "anthropic", name: "Anthropic", inUse: true, paused: anthropic.paused,
            pausedSince: anthropic.paused ? providersNow.addingTimeInterval(-12 * 60) : nil,
            held: anthropic.held, heldUntil: anthropic.held ? providersNow.addingTimeInterval(48 * hour) : nil,
            usageWindows: [
                .init(name: "five_hour", utilization: 0.41, resetsAt: providersNow.addingTimeInterval(2 * hour + 20 * 60)),
                .init(name: "seven_day", utilization: anthropic.held ? 1 : 0.62, resetsAt: providersNow.addingTimeInterval(48 * hour)),
            ],
            harnesses: ["claude"], kinds: ["implementation", "breakdown", "rework", "code_review", "qa"], working: 3,
            tokensToday: 14_600_000
        ),
        .init(
            id: "opencode-go", name: "OpenCode Go", inUse: true, harnesses: ["claude", "codex", "opencode"],
            kinds: ["landing"], fallbackFor: ["implementation", "breakdown"], working: 1, tokensToday: 3_100_000
        ),
        .init(
            id: "openrouter", name: "OpenRouter", inUse: true, harnesses: ["claude"], kinds: ["ci_fix"], fallbackFor: ["qa"],
            tokensToday: 900_000
        ),
        .init(id: "openai", name: "OpenAI", harnesses: ["codex"]),
    ]
}

/// The page in a window `window` pt wide, beside the sidebar, drawn unscrolled at its whole height.
@MainActor
func providersScreen(_ providers: [StateSnapshot.Provider], selection: String? = nil, window: CGFloat) -> some View {
    ProvidersPageView(
        page: ProvidersPage(providers: providers, now: providersNow, timeZone: TimeZone(identifier: "UTC")!),
        selection: selection, actions: .none, scrolls: false
    )
    .frame(width: window - DesignTokens.Layout.sidebarWidth, alignment: .top)
    .fixedSize(horizontal: false, vertical: true)
    .background(DesignTokens.Surface.window.color)
}

/// The page's states, by name: Anthropic available, paused, at its limit, a provider with no usage to read and one
/// not in use.
@MainActor
let providersStates: [(name: String, providers: [StateSnapshot.Provider], selection: String?)] = [
    ("providers-page", galleryProviders(), nil),
    ("providers-page-paused", galleryProviders(anthropic: (true, false)), nil),
    ("providers-page-at-its-limit", galleryProviders(anthropic: (false, true)), nil),
    ("providers-page-no-usage", galleryProviders(), "opencode-go"),
    ("providers-page-not-in-use", galleryProviders(), "openai"),
]

/// Factory › Runs while Anthropic is paused: each line on Anthropic says so.
@MainActor
func runsWithProviderPaused() -> RunsPage {
    runsPageState { $0.showProviders(galleryProviders(anthropic: (true, false))) }
}
