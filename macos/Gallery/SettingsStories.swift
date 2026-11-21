// The design-system components a Settings page is built of (TP-1574): the catalog's Toggle (its stories by the
// catalog's names, `docs/design/catalog/stories.js`), and the number field, the time field, the settings row and its
// group, the settings line (TP-1576) and the in-page section list, which the catalog has no entry for. Each story is a variation of its own
// (`toggle-on`), so the gallery's board shows them together under their names. The resting stories are live: in the
// gallery they can be clicked, typed in, stepped, hovered and focused; the hover, pressed, focus and error ones are
// drawn in that state.
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// A live story's value, kept while the gallery shows it.
private struct LiveValue<Value, Content: View>: View {
    @State var value: Value
    let content: (Binding<Value>) -> Content

    var body: some View { content($value) }
}

// MARK: - Toggle

/// The catalog's Toggle story: Notify me about new questions, its effect line and its reason, in a shown state.
@MainActor
func toggleStory(on: Bool = true, state: DesignTokens.Interaction? = nil, disabled: Bool = false) -> AnyView {
    let toggle = LiveValue(value: on) { isOn in
        SettingsGroup {
            DirectorToggle(
                "Notify me about new questions", isOn: isOn, effect: "A notification for each new question in the Inbox.",
                disabledReason: disabled ? "Notifications are off for Symphony in System Settings." : nil, drawnAs: state
            )
        }
    }
    return AnyView(toggle.frame(width: CGFloat(DesignTokens.SettingsRow.toggleWidth)))
}

// MARK: - Number field

/// The stop timeout's number field: 10 seconds, from 1 to 120, in a shown state.
@MainActor
func numberFieldStory(
    _ value: Int = 10, state: DesignTokens.Field.State? = nil, stepperHover: Int? = nil, error: String? = nil, reason: String? = nil
) -> AnyView {
    let field = LiveValue(value: value) { value in
        NumberField(
            "Stop timeout", value: value, in: 1...120, unit: "seconds", help: "How long Symphony gets to stop before it is ended.",
            error: error, disabledReason: reason, drawnAs: state, drawnStepperHover: stepperHover
        )
    }
    return AnyView(field.frame(width: fieldStoryWidth, alignment: .leading))
}

/// The stop timeout typed past its range on a page that says so: the field keeps 900, and the error says the range.
@MainActor
func numberFieldOutOfRangeStory() -> AnyView {
    let field = LiveValue(value: 900) { value in
        NumberField(
            "Stop timeout", value: value, in: 1...600, accepts: Int.min...Int.max, unit: "seconds",
            error: value.wrappedValue > 600 ? "The stop timeout must be between 1 and 600 seconds." : nil, drawnAs: .focused
        )
    }
    return AnyView(field.frame(width: fieldStoryWidth, alignment: .leading))
}

/// The summary size limit, a five-digit value: the field widens so 50000 shows whole, the unit after it (TP-1576).
@MainActor
func numberFieldLongValueStory() -> AnyView {
    let field = LiveValue(value: 50_000) { value in
        NumberField("Summary size limit", value: value, in: 1...Int.max, accepts: Int.min...Int.max, unit: "tokens", drawnAs: .rest)
    }
    return AnyView(field.frame(width: fieldStoryWidth, alignment: .leading))
}

// MARK: - Time field

/// The update time's field: 03:00, in a shown state.
@MainActor
func timeFieldStory(
    _ time: TimeOfDay = .defaultUpdateTime, state: DesignTokens.Field.State? = nil, part: TimeField.Part? = nil,
    error: String? = nil, reason: String? = nil
) -> AnyView {
    let field = LiveValue(value: time) { time in
        TimeField(
            "Install at", time: time, help: "On the Mac's clock, every day.", error: error, disabledReason: reason, drawnAs: state,
            drawnPart: part
        )
    }
    return AnyView(field.frame(width: fieldStoryWidth, alignment: .leading))
}

// MARK: - Settings row and group

let settingsStoryWidth: CGFloat = 520

/// One row in its group: the restart timeout with its number field, its help, its error or its reason.
@MainActor
func settingsRowStory(help: String? = nil, error: String? = nil, reason: String? = nil, value: Int = 5) -> AnyView {
    let row = LiveValue(value: value) { minutes in
        SettingsGroup {
            SettingsRow("Restart timeout", help: help, error: error, disabledReason: reason) {
                NumberField(value: minutes, in: 1...60, unit: "minutes")
            }
        }
    }
    return AnyView(row.frame(width: settingsStoryWidth))
}

/// The Updates group: a pop-up, the time field, a switch and a number field, under its title and over its footer.
@MainActor
func settingsGroupStory(minutes: Int = 30) -> AnyView {
    struct UpdatesGroup: View {
        @State var mode = "At a set time"
        @State var time = TimeOfDay.defaultUpdateTime
        @State var notify = true
        @State var minutes: Int

        var body: some View {
            SettingsGroup("Updates", footer: "Symphony installs a new release by itself at the time you set.") {
                SettingsRow("Update mode") {
                    PopUp(nil, selection: $mode, choices: ["Manually", "At a set time", "On release"].map { PopUpChoice($0, $0) })
                }
                SettingsRow("Time", help: "On the Mac's clock, every day.") { TimeField(time: $time) }
                SettingsRow("Notify me when it installs", help: "A notification after each update.") { DirectorSwitch(isOn: $notify) }
                SettingsRow("Check for releases every", error: minutes < 15 ? "GitHub allows a check every 15 minutes at most." : nil) {
                    NumberField(value: $minutes, in: 5...1440, step: 5, unit: "minutes")
                }
            }
        }
    }
    return AnyView(UpdatesGroup(minutes: minutes).frame(width: settingsStoryWidth))
}

// MARK: - Settings line

/// A group with a line that is no one setting: the words over its rows, an error line naming where its reason shows,
/// and a variable's name and value with the button that removes it.
@MainActor
func settingsLineStory(_ kind: String) -> AnyView {
    struct Lines: View {
        let kind: String
        @State var on = true
        @State var name = "API_BASE_URL"
        @State var value = "http://localhost:8090"

        var body: some View {
            SettingsGroup("Tickets") {
                switch kind {
                case "error":
                    SettingsRow("Urgent") { DirectorSwitch(isOn: $on) }
                    SettingsLine("symphony check rejected these ticket priorities; the reason shows above Save.", error: true)
                case "with-fields":
                    SettingsLine {
                        HStack(spacing: DesignTokens.Space.s2) {
                            DirectorTextField(nil, text: $name, placeholder: "NAME", mono: true).controlLabel("Name")
                            DirectorTextField(nil, text: $value, placeholder: "Value").controlLabel("Value")
                            IconButton("minus.circle", help: "Remove this variable", size: .small) {}
                        }
                    }
                    SettingsLine {
                        Button("Add Variable") {}.directorButton(.quiet, size: .small, glyph: "plus")
                    }
                default:
                    SettingsLine("Only the chosen priorities start new work. With none chosen, every priority may.")
                    SettingsRow("Urgent") { DirectorSwitch(isOn: $on) }
                }
            }
        }
    }
    return AnyView(Lines(kind: kind).frame(width: settingsStoryWidth))
}

// MARK: - Section list

/// Settings' sections, as the page will list them.
enum SettingsSectionStory: String, CaseIterable {
    case symphony, notifications, updates, budget, tickets, conductor

    var title: String {
        switch self {
        case .symphony: "Symphony"
        case .notifications: "Notifications"
        case .updates: "Updates"
        case .budget: "Agents and budget"
        case .tickets: "Tickets"
        case .conductor: "Conductor"
        }
    }

    var symbol: String {
        switch self {
        case .symphony: "gearshape"
        case .notifications: "bell"
        case .updates: "arrow.down.circle"
        case .budget: "gauge.with.dots.needle.33percent"
        case .tickets: "ticket"
        case .conductor: "wand.and.stars"
        }
    }
}

let sectionListStoryHeight: CGFloat = 240

/// The section list with Updates current, live (a click makes another section current) or with a row drawn in a state.
@MainActor
func sectionListStory(drawn: [SettingsSectionStory: DesignTokens.Interaction] = [:], windowActive: Bool? = nil) -> AnyView {
    let entries = SettingsSectionStory.allCases.map { SidebarEntry(id: $0, title: $0.title, symbol: $0.symbol) }
    let list = LiveValue(value: SettingsSectionStory.updates) { current in
        SectionList(entries, current: current.wrappedValue, windowActive: windowActive, drawn: drawn) { current.wrappedValue = $0 }
    }
    return AnyView(list.frame(height: sectionListStoryHeight, alignment: .top))
}

// MARK: - Stories

/// Every story of the entries.
@MainActor
let settingsStories: [ComponentStory] = {
    func toggle(_ id: String, height: CGFloat = 72, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(
            component: "toggle", id: id, title: "Toggle", width: CGFloat(DesignTokens.SettingsRow.toggleWidth), height: height, draw: draw
        )
    }
    func number(_ id: String, height: CGFloat = 80, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "number-field", id: id, title: "Number field", width: fieldStoryWidth, height: height, draw: draw)
    }
    func time(_ id: String, height: CGFloat = 80, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "time-field", id: id, title: "Time field", width: fieldStoryWidth, height: height, draw: draw)
    }
    func row(_ id: String, height: CGFloat = 72, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "settings-row", id: id, title: "Settings row", width: settingsStoryWidth, height: height, draw: draw)
    }
    func group(_ id: String, height: CGFloat = 300, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "settings-group", id: id, title: "Settings group", width: settingsStoryWidth, height: height, draw: draw)
    }
    func line(_ id: String, height: CGFloat = 140, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "settings-line", id: id, title: "Settings line", width: settingsStoryWidth, height: height, draw: draw)
    }
    func sections(_ id: String, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(
            component: "section-list", id: id, title: "Section list", width: CGFloat(DesignTokens.SectionList.width),
            height: sectionListStoryHeight, draw: draw
        )
    }
    return [
        toggle("on") { toggleStory() },
        toggle("off") { toggleStory(on: false) },
        toggle("hover") { toggleStory(state: .hover) },
        toggle("pressed") { toggleStory(state: .press) },
        toggle("focused") { toggleStory(state: .focus) },
        toggle("disabled-with-reason") { toggleStory(on: false, disabled: true) },
        number("rest") { numberFieldStory() },
        number("hover") { numberFieldStory(state: .hover, stepperHover: 1) },
        number("focused") { numberFieldStory(state: .focused) },
        number("at-its-minimum") { numberFieldStory(1) },
        number("at-its-maximum") { numberFieldStory(120) },
        number("error") { numberFieldStory(1, state: .focused, error: "Give Symphony 5 seconds at least to stop.") },
        number("disabled-with-reason") { numberFieldStory(reason: "Symphony is stopping: the timeout is in use.") },
        number("typed-out-of-range") { numberFieldOutOfRangeStory() },
        number("long-value") { numberFieldLongValueStory() },
        time("rest") { timeFieldStory() },
        time("hover") { timeFieldStory(state: .hover) },
        time("focused") { timeFieldStory(state: .focused, part: .hour) },
        time("error") { timeFieldStory(TimeOfDay(hour: 9, minute: 30), state: .focused, part: .minute, error: "Pick a time outside working hours.") },
        time("disabled-with-reason") { timeFieldStory(reason: "Updates install on release, not at a set time.") },
        row("with-help") { settingsRowStory(help: "How long Symphony gets to restart before it is ended.") },
        row("error") { settingsRowStory(error: "A restart needs one minute at least.", value: 1) },
        row("disabled-with-reason") { settingsRowStory(reason: "Symphony is restarting: the timeout is in use.") },
        row("label-alone", height: 56) { settingsRowStory() },
        group("updates") { settingsGroupStory() },
        group("with-an-error") { settingsGroupStory(minutes: 10) },
        line("text") { settingsLineStory("text") },
        line("error") { settingsLineStory("error") },
        line("with-fields") { settingsLineStory("with-fields") },
        sections("rest") { sectionListStory() },
        sections("row-hover") { sectionListStory(drawn: [.notifications: .hover]) },
        sections("row-pressed") { sectionListStory(drawn: [.notifications: .press]) },
        sections("row-focused") { sectionListStory(drawn: [.tickets: .focus]) },
        sections("window-not-focused") { sectionListStory(windowActive: false) },
    ]
}()
