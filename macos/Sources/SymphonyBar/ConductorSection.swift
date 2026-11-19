import SwiftUI
import SymphonyBarCore

/// Settings › Conductor: whether Symphony runs the Conductor (`conductor.enabled`), the junctions of a ticket's life it
/// runs at, one row each (`conductor.junctions`), and how long one turn may take (`conductor.timeout_ms`). The junctions
/// and the time limit wait while it is off.
struct ConductorSection: View {
    @Binding var settings: ConductorSettings
    /// Why `symphony check` refused the changed settings; nil when nothing was refused.
    let error: String?
    /// Off until a symphony.yml has been read, and while Save checks it.
    let editable: Bool

    var body: some View {
        Section {
            Toggle("Run the Conductor", isOn: $settings.enabled)
                .help("conductor.enabled")
            ForEach(ConductorJunction.allCases) { junction in
                Toggle(junction.title, isOn: Binding(
                    get: { settings.runs(at: junction) },
                    set: { settings = settings.setting(junction, on: $0) }
                ))
                .accessibilityLabel("Run the Conductor \(junction.title.lowercased())")
                .help("conductor.junctions: \(junction.rawValue)")
                .disabled(!settings.enabled)
            }
            LabeledContent("Time limit") {
                HStack {
                    TextField("Time limit in seconds", value: Binding(
                        get: { settings.timeoutSeconds },
                        set: { settings = settings.setting(timeoutSeconds: $0) }
                    ), format: .number)
                    .labelsHidden()
                    .monospacedDigit()
                    .frame(width: 90)
                    .accessibilityLabel("Conductor time limit in seconds")
                    Text("seconds")
                }
            }
            .help("conductor.timeout_ms")
            .disabled(!settings.enabled)
            if let error {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("Conductor (saved in symphony.yml)")
        }
        .disabled(!editable)
    }
}
