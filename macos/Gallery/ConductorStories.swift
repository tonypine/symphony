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

/// Settings › Conductor holding `settings`, live: its toggles and its field change what it draws. The picture renderer
/// draws a scroll-backed form empty, so a still draws the section's rows unscrolled, its switches as the form's.
private struct ConductorSettingsStory: View {
    /// The width the story draws the section at: the old Settings window's form width.
    static let width: CGFloat = 840

    @State var settings: ConductorSettings
    let error: String?
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    var body: some View {
        if offscreenSnapshot {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                ConductorSection(settings: $settings, error: error, editable: true)
            }
            .toggleStyle(.switch)
            .padding(DesignTokens.Space.s5)
            .frame(width: Self.width, alignment: .leading)
        } else {
            Form {
                ConductorSection(settings: $settings, error: error, editable: true)
            }
            .formStyle(.grouped)
            .frame(width: Self.width, height: error == nil ? 300 : 340)
        }
    }
}

/// The section in a Settings form, at a fixed story width.
@MainActor
func conductorSettings(_ settings: ConductorSettings, error: String?) -> some View {
    ConductorSettingsStory(settings: settings, error: error)
        .background(DesignTokens.Surface.window.color)
}
