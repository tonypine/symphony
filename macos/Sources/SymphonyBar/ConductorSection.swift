import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// Settings › Conductor: whether Symphony runs the Conductor (`conductor.enabled`), the junctions of a ticket's life it
/// runs at, one row each (`conductor.junctions`), how long one turn may take (`conductor.timeout_ms`), whether it may file
/// a linked ticket and how many per ticket (`conductor.file_tickets`, `conductor.max_filed_tickets`), how long Grooming
/// may take and how many rounds a final check may add (`conductor.grooming_timeout_ms`, `conductor.final_check_rounds`), and its watch over
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
        numberRow(
            label, key: "conductor.watch.\(key)", reason: watchReason,
            text: Binding(
                get: { String(settings.watch[keyPath: value]) },
                set: { text in if let number = Int(text) { settings.watch[keyPath: value] = number } }
            )
        )
    }

    /// A row of a whole number typed in a text field, `key` its help, off with `reason`.
    private func numberRow(_ label: String, key: String, error: String? = nil, reason: String?, text: Binding<String>) -> some View {
        SettingsRow(label, error: error, disabledReason: reason) {
            DirectorTextField(nil, text: text, mono: true)
                .frame(width: DesignTokens.SettingsRow.fieldWidth)
                .help(key)
        }
    }

    /// A row of one switch, `key` its help, off with `reason`. `spoken` is what VoiceOver reads, when not the title.
    private func switchRow(_ title: String, key: String, spoken: String? = nil, reason: String?, isOn: Binding<Bool>) -> some View {
        SettingsRow(title, disabledReason: reason) {
            DirectorSwitch(spoken, isOn: isOn)
                .help(key)
        }
    }

    var body: some View {
        SettingsGroup("Conductor (saved in symphony.yml)") {
            switchRow("Run the Conductor", key: "conductor.enabled", reason: sectionReason, isOn: $settings.enabled)
            ForEach(ConductorJunction.settable) { junction in
                switchRow(
                    junction.title, key: "conductor.junctions: \(junction.rawValue)",
                    spoken: "Run the Conductor \(junction.title.lowercased())", reason: detailReason,
                    isOn: Binding(
                        get: { settings.runs(at: junction) },
                        set: { settings = settings.setting(junction, on: $0) }
                    )
                )
            }
            numberRow(
                "Time limit in seconds", key: "conductor.timeout_ms", error: error, reason: detailReason,
                text: Binding(
                    get: { String(settings.timeoutSeconds) },
                    set: { text in if let seconds = Int(text) { settings = settings.setting(timeoutSeconds: seconds) } }
                )
            )
            numberRow(
                "Grooming time limit in seconds", key: "conductor.grooming_timeout_ms", reason: detailReason,
                text: Binding(
                    get: { String(settings.groomingTimeoutSeconds) },
                    set: { text in if let seconds = Int(text) { settings = settings.setting(groomingTimeoutSeconds: seconds) } }
                )
            )
            numberRow(
                "Final check rounds before it asks you", key: "conductor.final_check_rounds", reason: detailReason,
                text: Binding(
                    get: { String(settings.finalCheckRounds) },
                    set: { text in if let rounds = Int(text) { settings = settings.setting(finalCheckRounds: rounds) } }
                )
            )
            switchRow("File linked tickets", key: "conductor.file_tickets", reason: detailReason, isOn: $settings.fileTickets)
            numberRow(
                "Tickets one ticket may file", key: "conductor.max_filed_tickets", reason: filingReason,
                text: Binding(
                    get: { String(settings.maxFiledTickets) },
                    set: { text in if let number = Int(text) { settings.maxFiledTickets = number } }
                )
            )
            switchRow("Watch running runs", key: "conductor.watch.enabled", reason: detailReason, isOn: $settings.watch.enabled)
            limitField("Look at a run after minutes", key: "run_minutes", value: \.runMinutes)
            limitField("Look at a run after tokens", key: "run_tokens", value: \.runTokens)
            limitField("Minutes between looks at a run", key: "min_interval_minutes", value: \.minIntervalMinutes)
            limitField("Looks per run", key: "max_turns_per_run", value: \.maxTurnsPerRun)
            switchRow(
                "May stop a run, with a question to you", key: "conductor.watch.allow_stop", reason: watchReason,
                isOn: $settings.watch.allowStop
            )
        }
    }
}
