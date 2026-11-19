import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// Settings › Conductor: whether Symphony runs the Conductor (`conductor.enabled`), the junctions of a ticket's life it
/// runs at, one row each (`conductor.junctions`), and how long one turn may take (`conductor.timeout_ms`). The junctions
/// and the time limit wait while it is off.
struct ConductorSection: View {
    @Binding var settings: ConductorSettings
    /// Why `symphony check` refused the changed settings; nil when nothing was refused.
    let error: String?
    /// Off until a symphony.yml has been read, and while Save checks it.
    let editable: Bool

    /// Why every control waits: no symphony.yml read yet, or Save checking it.
    static let notEditable = "Waits for symphony.yml to be read or saved"
    /// Why the junctions and the time limit wait.
    static let off = "Turn on Run the Conductor first"

    private var sectionReason: String? { editable ? nil : Self.notEditable }
    private var detailReason: String? { sectionReason ?? (settings.enabled ? nil : Self.off) }

    var body: some View {
        Section {
            Toggle("Run the Conductor", isOn: $settings.enabled)
                .help("conductor.enabled")
                .disabledReason(sectionReason)
            ForEach(ConductorJunction.allCases) { junction in
                Toggle(junction.title, isOn: Binding(
                    get: { settings.runs(at: junction) },
                    set: { settings = settings.setting(junction, on: $0) }
                ))
                .accessibilityLabel("Run the Conductor \(junction.title.lowercased())")
                .help("conductor.junctions: \(junction.rawValue)")
                .disabledReason(detailReason)
            }
            DirectorTextField(
                "Time limit in seconds",
                text: Binding(
                    get: { String(settings.timeoutSeconds) },
                    set: { text in if let seconds = Int(text) { settings = settings.setting(timeoutSeconds: seconds) } }
                ),
                error: error,
                disabledReason: detailReason,
                mono: true
            )
            .help("conductor.timeout_ms")
        } header: {
            Text("Conductor (saved in symphony.yml)")
        }
    }
}
