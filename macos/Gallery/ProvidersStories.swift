import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

// Factory › Providers (TP-1534): the page as the catalog draws it (`providersPage`), from the catalog's four providers:
// Anthropic in use with its two windows and three runs on it, OpenCode Go and OpenRouter in use with no window to
// read, OpenAI not in use. Each story is one state the walkthrough reaches, and Runs with a provider paused. The Key
// block (TP-1540) of a provider set up with an API key: OpenCode Go not in use with no key, a key under test, a test
// that works (Enable offered) and one that fails, enabled (Disable and Remove Key), and off with its key set. Anthropic
// stops new runs at 90 % (TP-1535): "Stop new runs at" under its meters, each with its mark, and a story at that reserve.
// OpenCode Go's usage is read too (TP-1642): its 5 hours, Week and Month with "Stop new runs at" 90 %, and at that
// reserve, its week at 92 %.

/// Symphony's clock for the stories: Tuesday 17 November 2026, 14:00 UTC.
private let providersNow = Date(timeIntervalSince1970: 1_794_924_000)

/// The catalog's providers, Anthropic in `anthropic`'s state, stopping new runs at 90 %; at that reserve when
/// `atReserve`, its week at 90 %. OpenCode Go with its three windows and a 90 % reserve when `openCodeGoUsage` is set,
/// at that reserve when it is `.atReserve`.
func galleryProviders(
    anthropic: (paused: Bool, held: Bool) = (false, false), atReserve: Bool = false, openCodeGoInUse: Bool = true,
    openCodeGoUsage: GalleryOpenCodeGoUsage? = nil
) -> [StateSnapshot.Provider] {
    let hour: TimeInterval = 3600
    let held = anthropic.held || atReserve
    let week = anthropic.held ? 1 : atReserve ? 0.9 : 0.62
    return [
        .init(
            id: "anthropic", name: "Anthropic", inUse: true, paused: anthropic.paused,
            pausedSince: anthropic.paused ? providersNow.addingTimeInterval(-12 * 60) : nil,
            held: held, heldUntil: held ? providersNow.addingTimeInterval(48 * hour) : nil,
            usageWindows: [
                .init(name: "five_hour", utilization: 0.41, resetsAt: providersNow.addingTimeInterval(2 * hour + 20 * 60)),
                .init(name: "seven_day", utilization: week, resetsAt: providersNow.addingTimeInterval(48 * hour)),
            ],
            harnesses: ["claude"], kinds: ["implementation", "breakdown", "rework", "code_review", "qa"], working: atReserve ? 0 : 3,
            tokensToday: 14_600_000, reserve: 0.9, atReserve: atReserve
        ),
        openCodeGoUsage.map(galleryOpenCodeGo) ?? (openCodeGoInUse
            ? .init(
                id: "opencode-go", name: "OpenCode Go", inUse: true, harnesses: ["claude", "codex", "opencode"],
                kinds: ["landing"], fallbackFor: ["implementation", "breakdown"], working: 1, tokensToday: 3_100_000
            )
            : .init(id: "opencode-go", name: "OpenCode Go", harnesses: ["claude", "codex", "opencode"])),
        .init(
            id: "openrouter", name: "OpenRouter", inUse: true, harnesses: ["claude"], kinds: ["ci_fix"], fallbackFor: ["qa"],
            tokensToday: 900_000
        ),
        .init(id: "openai", name: "OpenAI", harnesses: ["codex"]),
    ]
}

/// OpenCode Go's usage as Symphony reads it (TP-1642): below its reserve, or at it.
enum GalleryOpenCodeGoUsage {
    case belowReserve, atReserve
}

/// OpenCode Go every kind's fallback, its 5 hours, Week and Month read, stopping new runs at 90 %; at that reserve its
/// week is at 92 % and new runs on it wait until the week resets.
private func galleryOpenCodeGo(_ usage: GalleryOpenCodeGoUsage) -> StateSnapshot.Provider {
    let hour: TimeInterval = 3600
    let atReserve = usage == .atReserve
    let weekResets = providersNow.addingTimeInterval(72 * hour)
    return .init(
        id: "opencode-go", name: "OpenCode Go", inUse: true, held: atReserve, heldUntil: atReserve ? weekResets : nil,
        usageWindows: [
            .init(name: "five_hour", utilization: 0.3, resetsAt: providersNow.addingTimeInterval(2 * hour)),
            .init(name: "seven_day", utilization: atReserve ? 0.92 : 0.64, resetsAt: weekResets),
            .init(name: "monthly", utilization: 0.55, resetsAt: providersNow.addingTimeInterval(20 * 24 * hour)),
        ],
        harnesses: ["claude", "codex", "opencode"], fallbackFor: ["implementation", "breakdown", "code_review", "qa"],
        working: atReserve ? 0 : 1, tokensToday: 3_100_000, reserve: 0.9, atReserve: atReserve
    )
}

/// The page in a window `window` pt wide, beside the sidebar, drawn unscrolled at its whole height.
@MainActor
func providersScreen(
    _ providers: [StateSnapshot.Provider], selection: String? = nil, keys: GalleryProviderKeys = galleryProviderKeys(),
    window: CGFloat
) -> some View {
    ProvidersPageView(
        page: ProvidersPage(
            providers: providers, now: providersNow, timeZone: TimeZone(identifier: "UTC")!, keys: keys.keys, keyEditor: keys.editor
        ),
        selection: selection, actions: .none, scrolls: false
    )
    .frame(width: window - DesignTokens.Layout.sidebarWidth, alignment: .top)
    .fixedSize(horizontal: false, vertical: true)
    .background(DesignTokens.Surface.window.color)
}

/// The app's provider keys and the Key blocks' edits, as one story draws them.
struct GalleryProviderKeys {
    var keys: ProviderKeys
    var editor = ProviderKeyEditor()
}

private let galleryOpenRouterKey = "sk-or-v1-8f2c4e1a9b7d"
private let galleryOpenCodeGoKey = "sk-ocg-3d9a71e0c5b2"
private let openCodeGo = ProviderKeys.openCodeGo.id
private let openRouter = ProviderKeys.openRouter.id

/// OpenRouter's key set and enabled, as an install that saved it in the old Settings starts; OpenCode Go's key set
/// and enabled when `openCodeGo` is true, else no key.
func galleryProviderKeys(openCodeGo withKey: Bool = true, enabled: Bool = true) -> GalleryProviderKeys {
    var keys = [openRouter: galleryOpenRouterKey]
    var on: Set<String> = [openRouter]
    if withKey {
        keys[openCodeGo] = galleryOpenCodeGoKey
        if enabled { on.insert(openCodeGo) }
    }
    return GalleryProviderKeys(keys: ProviderKeys(keys: keys, enabled: on))
}

/// OpenCode Go's key typed into an empty field, then under test, then with the test's result when `result` is given.
func galleryKeyTest(_ result: ProviderKeyCheck.Result?) -> GalleryProviderKeys {
    var state = galleryProviderKeys(openCodeGo: false)
    state.editor.edit(openCodeGo, to: galleryOpenCodeGoKey, keys: state.keys)
    guard let key = state.editor.beginTest(openCodeGo, keys: state.keys), let result else { return state }
    if let stored = state.editor.finishTest(openCodeGo, key: key, result: result, keys: state.keys) { state.keys = stored }
    return state
}

/// The page's states, by name: Anthropic available, paused, at its limit, at its reserve, a provider with no usage to read,
/// OpenCode Go's usage and OpenCode Go at its reserve with no key in the app, and one not in use; then OpenCode Go's Key block: no key, a key under test, a test that works and one that fails, off with
/// its key set.
@MainActor
let providersStates: [(name: String, providers: [StateSnapshot.Provider], selection: String?, keys: GalleryProviderKeys)] = [
    ("providers-page", galleryProviders(), nil, galleryProviderKeys()),
    ("providers-page-paused", galleryProviders(anthropic: (true, false)), nil, galleryProviderKeys()),
    ("providers-page-at-its-limit", galleryProviders(anthropic: (false, true)), nil, galleryProviderKeys()),
    ("providers-page-at-your-reserve", galleryProviders(atReserve: true), nil, galleryProviderKeys()),
    ("providers-page-no-usage", galleryProviders(), "opencode-go", galleryProviderKeys()),
    ("providers-page-opencode-go-usage", galleryProviders(openCodeGoUsage: .belowReserve), "opencode-go", galleryProviderKeys()),
    (
        "providers-page-opencode-go-at-your-reserve", galleryProviders(openCodeGoUsage: .atReserve), "opencode-go",
        galleryProviderKeys(openCodeGo: false)
    ),
    ("providers-page-not-in-use", galleryProviders(), "openai", galleryProviderKeys()),
    ("providers-page-key-empty", galleryProviders(openCodeGoInUse: false), "opencode-go", galleryProviderKeys(openCodeGo: false)),
    ("providers-page-key-testing", galleryProviders(openCodeGoInUse: false), "opencode-go", galleryKeyTest(nil)),
    (
        "providers-page-key-works", galleryProviders(openCodeGoInUse: false), "opencode-go",
        galleryKeyTest(.works("OpenCode Go accepted the key · 12 models"))
    ),
    (
        "providers-page-key-failed", galleryProviders(openCodeGoInUse: false), "opencode-go",
        galleryKeyTest(.fails("OpenCode Go rejected the key. Check that it is correct and active."))
    ),
    ("providers-page-key-enabled", galleryProviders(openCodeGoInUse: false), "opencode-go", galleryProviderKeys()),
    ("providers-page-key-off", galleryProviders(openCodeGoInUse: false), "opencode-go", galleryProviderKeys(enabled: false)),
]

/// Factory › Runs while Anthropic is paused: each line on Anthropic says so.
@MainActor
func runsWithProviderPaused() -> RunsPage {
    runsPageState { $0.showProviders(galleryProviders(anthropic: (true, false))) }
}
