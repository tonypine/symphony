import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// Settings › Conductor: whether Symphony runs the Conductor (`conductor.enabled`), the junctions of a ticket's life it
/// runs at, one row each (`conductor.junctions`), how long one turn may take (`conductor.timeout_ms`), whether it may file
/// a linked ticket and how many per ticket (`conductor.file_tickets`, `conductor.max_filed_tickets`), and its watch over
/// running runs (`conductor.watch`): on or off, when it looks, how often, and whether it may stop a run. Everything
/// below the first switch waits while it is off, and the watch's limits wait while the watch is off.
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
    /// Why the watch's limits wait.
    static let watchOff = "Turn on Watch running runs first"
    /// Why the filing limit waits.
    static let filingOff = "Turn on File linked tickets first"

    private var sectionReason: String? { editable ? nil : Self.notEditable }
    private var detailReason: String? { sectionReason ?? (settings.enabled ? nil : Self.off) }
    private var watchReason: String? { detailReason ?? (settings.watch.enabled ? nil : Self.watchOff) }
    private var filingReason: String? { detailReason ?? (settings.fileTickets ? nil : Self.filingOff) }

    /// A whole-number field for one of the watch's limits.
    private func limitField(_ label: String, key: String, value: WritableKeyPath<ConductorWatchSettings, Int>) -> some View {
        DirectorTextField(
            label,
            text: Binding(
                get: { String(settings.watch[keyPath: value]) },
                set: { text in if let number = Int(text) { settings.watch[keyPath: value] = number } }
            ),
            disabledReason: watchReason,
            mono: true
        )
        .help("conductor.watch.\(key)")
    }

    var body: some View {
        Section {
            Toggle("Run the Conductor", isOn: $settings.enabled)
                .help("conductor.enabled")
                .disabledReason(sectionReason)
            ForEach(ConductorJunction.settable) { junction in
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
            Toggle("File linked tickets", isOn: $settings.fileTickets)
                .help("conductor.file_tickets")
                .disabledReason(detailReason)
            DirectorTextField(
                "Tickets one ticket may file",
                text: Binding(
                    get: { String(settings.maxFiledTickets) },
                    set: { text in if let number = Int(text) { settings.maxFiledTickets = number } }
                ),
                disabledReason: filingReason,
                mono: true
            )
            .help("conductor.max_filed_tickets")
            Toggle("Watch running runs", isOn: $settings.watch.enabled)
                .help("conductor.watch.enabled")
                .disabledReason(detailReason)
            limitField("Look at a run after minutes", key: "run_minutes", value: \.runMinutes)
            limitField("Look at a run after tokens", key: "run_tokens", value: \.runTokens)
            limitField("Minutes between looks at a run", key: "min_interval_minutes", value: \.minIntervalMinutes)
            limitField("Looks per run", key: "max_turns_per_run", value: \.maxTurnsPerRun)
            Toggle("May stop a run, with a question to you", isOn: $settings.watch.allowStop)
                .help("conductor.watch.allow_stop")
                .disabledReason(watchReason)
        } header: {
            Text("Conductor (saved in symphony.yml)")
        }
    }
}
