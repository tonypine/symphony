import Foundation

/// Pure description of the menu bar item, kept free of AppKit so it can be unit tested.
public enum StatusMenu {
    /// SF Symbol shown in the menu bar for each status. Rendered as a template image so it follows
    /// light and dark menu bars.
    public static func iconSymbolName(for status: SymphonyStatus) -> String {
        switch status {
        case .stopped:
            return "stop.circle"
        case .starting:
            return "hourglass"
        case .running:
            return "music.note.list"
        case .paused:
            return "pause.circle"
        case .error:
            return "exclamationmark.triangle"
        }
    }

    /// Accessibility description for the status item button.
    public static let accessibilityLabel = "Symphony"

    /// Tooltip and accessibility description for the status item, for example "Symphony: running".
    public static func iconLabel(for status: SymphonyStatus) -> String {
        "\(accessibilityLabel): \(statusWord(status))"
    }

    /// First line of the menu, for example "Symphony is running (external)".
    public static func statusTitle(_ status: SymphonyStatus) -> String {
        if case .error = status { return "Symphony has a problem" }
        return "Symphony is \(statusWord(status))"
    }

    /// Lines shown under the status title, ending with the last Pause or Resume error when there is one.
    public static func detailLines(
        _ status: SymphonyStatus,
        controlError: String? = nil,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> [String] {
        let lines: [String]
        switch status {
        case .stopped, .starting:
            lines = []
        case let .running(snapshot, _):
            lines = [countsLine(snapshot)]
        case let .paused(snapshot, _):
            lines = [countsLine(snapshot)] + (snapshot.pause.map { [pauseLine($0, now: now, timeZone: timeZone)] } ?? [])
        case let .error(message):
            lines = [message]
        }
        return lines + (controlError.map { [$0] } ?? [])
    }

    /// For example "2 running · 1 retrying".
    public static func countsLine(_ snapshot: StateSnapshot) -> String {
        "\(snapshot.running) running · \(snapshot.retrying) retrying"
    }

    /// For example "Paused since 14:03: deploy freeze". Shows the date too when the pause began on another day.
    public static func pauseLine(_ pause: StateSnapshot.Pause, now: Date, timeZone: TimeZone) -> String {
        var line = "Paused"
        if let since = pause.since {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = calendar.isDate(since, inSameDayAs: now) ? "HH:mm" : "MMM d, HH:mm"
            line += " since \(formatter.string(from: since))"
        }
        if let reason = pause.reason?.trimmingWhitespace(), !reason.isEmpty {
            line += ": \(reason)"
        }
        return line
    }

    private static func statusWord(_ status: SymphonyStatus) -> String {
        switch status {
        case .stopped:
            return "stopped"
        case .starting:
            return "starting…"
        case let .running(_, external):
            return external ? "running (external)" : "running"
        case let .paused(_, external):
            return external ? "paused (external)" : "paused"
        case .error:
            return "error"
        }
    }

    /// Titles of the menu items that open Symphony's dashboard in the browser and its log.
    public static let openDashboardTitle = "Open Dashboard"
    public static let openLogsTitle = "Open Logs"

    /// Title of the menu item that starts Symphony.
    public static let startTitle = "Start Symphony"

    /// Title of the menu item that stops Symphony, and its title while a stop is under way.
    public static let stopTitle = "Stop Symphony"
    public static let stoppingTitle = "Stopping Symphony…"

    /// Title of the menu item that pauses dispatch. A pause only holds new dispatch, so the title says
    /// active runs carry on.
    public static let pauseTitle = "Pause Dispatch (active runs continue)"
    public static let pausingTitle = "Pausing Dispatch…"

    /// Title of the menu item that resumes dispatch.
    public static let resumeTitle = "Resume Dispatch"
    public static let resumingTitle = "Resuming Dispatch…"

    /// Pause is offered while Symphony answers and dispatches, whether or not the app started it.
    public static func canPause(_ status: SymphonyStatus) -> Bool {
        if case .running = status { return true }
        return false
    }

    /// Resume is offered while dispatch is paused, whoever paused it.
    public static func canResume(_ status: SymphonyStatus) -> Bool {
        if case .paused = status { return true }
        return false
    }

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
