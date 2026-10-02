/// Pure description of the menu bar item, kept free of AppKit so it can be unit tested.
public enum StatusMenu {
    /// SF Symbol shown in the menu bar. Rendered as a template image so it follows light and dark menu bars.
    public static let iconSymbolName = "music.note.list"

    /// Accessibility description for the status item button.
    public static let accessibilityLabel = "Symphony"

    /// Title of the menu item that starts Symphony.
    public static let startTitle = "Start Symphony"

    /// Title of the menu item that stops Symphony, and its title while a stop is under way.
    public static let stopTitle = "Stop Symphony"
    public static let stoppingTitle = "Stopping Symphony…"

    /// Title of the menu item that opens the Settings window.
    public static let settingsTitle = "Settings…"

    /// Key equivalent for Settings (used with Command), the macOS convention.
    public static let settingsKeyEquivalent = ","

    /// Title of the menu item that quits the app.
    public static let quitTitle = "Quit Symphony"

    /// Key equivalent for Quit (used with Command).
    public static let quitKeyEquivalent = "q"

    /// Text for the alert shown before quitting stops Symphony, or nil when no run is active.
    /// `activeRuns` is nil when Symphony's state couldn't be read.
    public static func quitConfirmation(activeRuns: Int?) -> String? {
        switch activeRuns {
        case 0:
            return nil
        case 1:
            return "1 agent run is active. Quitting stops Symphony and ends it."
        case let count?:
            return "\(count) agent runs are active. Quitting stops Symphony and ends them."
        case nil:
            return "Symphony is running, and its active runs couldn't be checked. Quitting stops Symphony and ends any runs."
        }
    }

    /// Notification text for a Symphony that exited without being asked to.
    public static func unexpectedExitMessage(_ exit: ChildExit, logPath: String) -> String {
        "Symphony \(exit.summary). See \(logPath)."
    }
}
