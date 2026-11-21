import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

// Settings › Conductor: the section as Settings draws it, off (its junctions and time limit wait), on at two junctions
// with its own time limit, and a change symphony check refused.

/// The section's states, by name.
let conductorSettingsStates: [(name: String, settings: ConductorSettings, error: String?)] = [
    ("off", ConductorSettings(), nil),
    ("on", ConductorSettings(enabled: true, junctions: [.afterCoding, .afterQAFail], timeoutMs: 120_000), nil),
    ("watching", ConductorSettings(
        enabled: true, timeoutMs: 120_000,
        watch: ConductorWatchSettings(enabled: true, runMinutes: 45, minIntervalMinutes: 15, maxTurnsPerRun: 2, allowStop: true)
    ), nil),
    ("refused", ConductorSettings(enabled: true), "symphony check rejected these settings, so nothing was saved: conductor.timeout_ms must be greater than 0"),
]

/// Settings › Conductor holding `settings`, live: its switches and its fields change what it draws. It is drawn as
/// Settings draws it, a design-system group of rows (TP-1576), at the page's width.
private struct ConductorSettingsStory: View {
    /// The width the story draws the section at: a Settings page's groups at their widest.
    static let width = CGFloat(DesignTokens.SettingsRow.pageMaxWidth)

    @State var settings: ConductorSettings
    let error: String?

    var body: some View {
        ConductorSection(settings: $settings, error: error, editable: true)
            .padding(DesignTokens.SettingsRow.pageInset)
            .frame(width: Self.width + 2 * CGFloat(DesignTokens.SettingsRow.pageInset), alignment: .leading)
    }
}

/// The section as Settings draws it, at a fixed story width.
@MainActor
func conductorSettings(_ settings: ConductorSettings, error: String?) -> some View {
    ConductorSettingsStory(settings: settings, error: error)
        .background(DesignTokens.Surface.window.color)
}
