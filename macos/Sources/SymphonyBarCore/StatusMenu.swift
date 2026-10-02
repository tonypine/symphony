/// Pure description of the menu bar item, kept free of AppKit so it can be unit tested.
public enum StatusMenu {
    /// SF Symbol shown in the menu bar. Rendered as a template image so it follows light and dark menu bars.
    public static let iconSymbolName = "music.note.list"

    /// Accessibility description for the status item button.
    public static let accessibilityLabel = "Symphony"

    /// Title of the menu item that opens the Settings window.
    public static let settingsTitle = "Settings…"

    /// Key equivalent for Settings (used with Command), the macOS convention.
    public static let settingsKeyEquivalent = ","

    /// Title of the menu item that quits the app.
    public static let quitTitle = "Quit Symphony"

    /// Key equivalent for Quit (used with Command).
    public static let quitKeyEquivalent = "q"
}
