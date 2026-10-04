import Foundation

/// Pure description of the menu bar item, kept free of AppKit so it can be unit tested.
public enum StatusMenu {
    /// SF Symbol shown in the menu bar for each status. Rendered as a template image so it follows
    /// light and dark menu bars. A usage-limit hold shows as paused too.
    public static func iconSymbolName(for status: SymphonyStatus) -> String {
        switch status {
        case .stopped:
            return "stop.circle"
        case .starting:
            return "hourglass"
        case let .running(snapshot, _):
            return snapshot.usageLimits.isEmpty ? "music.note.list" : "pause.circle"
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

    /// Shown while Start, Restart, Update or Settings waits to read the Keychain, which is usually a password prompt.
    public static let keychainWaitingLine = "Waiting for Keychain access…"

    /// Lines shown under the status title, then the Keychain wait, the restart's progress or error and the last
    /// Pause or Resume error when there are any.
    public static func detailLines(
        _ status: SymphonyStatus,
        waitingForKeychain: Bool = false,
        restartLine: String? = nil,
        controlError: String? = nil,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> [String] {
        let lines: [String]
        switch status {
        case .stopped, .starting:
            lines = []
        case let .running(snapshot, _), let .paused(snapshot, _):
            // The operator pause first, then the usage-limit holds, then what an update would release.
            lines = [countsLine(snapshot)] + (snapshot.pause.map { [pauseLine($0, now: now, timeZone: timeZone)] } ?? [])
                + snapshot.usageLimits.map { usageLimitLine($0, now: now, timeZone: timeZone) }
                + (updateUnblocksLine(snapshot.updateUnblocks).map { [$0] } ?? [])
        case let .error(message):
            lines = [message]
        }
        return lines + [waitingForKeychain ? keychainWaitingLine : nil, restartLine, controlError].compactMap { $0 }
    }

    /// Which Symphony Start runs: "Symphony v1.2.3 (embedded)" or "Development: <checkout>".
    public static func sourceLine(_ settings: AppSettings, appVersion: String?, embeddedAvailable: Bool) -> String {
        let settings = settings.trimmed()
        if settings.developmentMode {
            let checkout = settings.checkoutPath.isEmpty
                ? "no checkout folder set" : (settings.checkoutPath as NSString).abbreviatingWithTildeInPath
            return "Development: \(checkout)"
        }
        guard embeddedAvailable else { return "No embedded Symphony: turn on Development mode" }
        guard let version = appVersion?.trimmingWhitespace(), !version.isEmpty else { return "Symphony (embedded)" }
        return "Symphony v\(version) (embedded)"
    }

    /// "Update to unblock 2 tickets" while tickets wait only for the running Symphony to include a merged fix,
    /// nil when none does.
    public static func updateUnblocksLine(_ count: Int) -> String? {
        switch count {
        case ...0:
            return nil
        case 1:
            return "Update to unblock 1 ticket"
        default:
            return "Update to unblock \(count) tickets"
        }
    }

    /// For example "2 running · 1 retrying".
    public static func countsLine(_ snapshot: StateSnapshot) -> String {
        "\(snapshot.running) running · \(snapshot.retrying) retrying"
    }

    /// For example "Paused since 14:03: deploy freeze". Shows the date too when the pause began on another day.
    public static func pauseLine(_ pause: StateSnapshot.Pause, now: Date, timeZone: TimeZone) -> String {
        var line = "Paused"
        if let since = pause.since {
            line += " since \(clockTime(since, now: now, timeZone: timeZone, dateFormat: "MMM d, HH:mm"))"
        }
        if let reason = pause.reason?.trimmingWhitespace(), !reason.isEmpty {
            line += ": \(reason)"
        }
        return line
    }

    /// For example "Paused: Claude limit, resumes ~14:05", "Resuming: checking Claude limit…" or
    /// "Holding new runs: Claude at 91%, resets ~14:05". Times are local, with the date when not today.
    public static func usageLimitLine(_ limit: StateSnapshot.UsageLimit, now: Date, timeZone: TimeZone) -> String {
        let provider = providerName(limit.provider)
        switch limit.phase {
        case .paused:
            return "Paused: \(provider) limit" + approximateTime(", resumes", limit.resumeAt, now: now, timeZone: timeZone)
        case .canary:
            return "Resuming: checking \(provider) limit…"
        case .headroom:
            let used = limit.utilization.map { " at \(Int(($0 * 100).rounded()))%" } ?? ""
            return "Holding new runs: \(provider)\(used)" + approximateTime(", resets", limit.resetsAt, now: now, timeZone: timeZone)
        }
    }

    /// The limit a hold is on, as Symphony's dashboards name it: "Claude 5-hour limit".
    public static func limitName(_ limit: StateSnapshot.UsageLimit) -> String {
        let window: String
        switch limit.window {
        case "five_hour"?:
            window = "5-hour limit"
        case "seven_day"?:
            window = "weekly limit"
        case "seven_day_opus"?:
            window = "weekly Opus limit"
        case "seven_day_sonnet"?:
            window = "weekly Sonnet limit"
        case let other?:
            window = "\(other) limit"
        case nil:
            window = "usage limit"
        }
        return "\(providerName(limit.provider)) \(window)"
    }

    /// How people name a provider: "Claude" for `anthropic`.
    public static func providerName(_ provider: String) -> String {
        switch provider {
        case "anthropic":
            return "Claude"
        case "openai":
            return "Codex"
        case "openrouter":
            return "OpenRouter"
        default:
            return provider
        }
    }

    /// For example ", resumes ~14:05", or "" without a time.
    static func approximateTime(_ prefix: String, _ date: Date?, now: Date, timeZone: TimeZone) -> String {
        guard let date else { return "" }
        return "\(prefix) ~\(clockTime(date, now: now, timeZone: timeZone, dateFormat: "MMM d HH:mm"))"
    }

    /// "14:05" on the day of `now`, otherwise `dateFormat`, for example "Oct 4 14:05".
    private static func clockTime(_ date: Date, now: Date, timeZone: TimeZone, dateFormat: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : dateFormat
        return formatter.string(from: date)
    }

    private static func statusWord(_ status: SymphonyStatus) -> String {
        switch status {
        case .stopped:
            return "stopped"
        case .starting:
            return "starting…"
        case let .running(snapshot, external) where !snapshot.usageLimits.isEmpty:
            return external ? "paused (external)" : "paused"
        case let .running(_, external):
            return external ? "running (external)" : "running"
        case let .paused(_, external):
            return external ? "paused (external)" : "paused"
        case .error:
            return "error"
        }
    }

    /// Titles of the menu items that open Symphony's dashboard in the browser, its terminal dashboard in
    /// Terminal, and its log.
    public static let openDashboardTitle = "Open Dashboard"
    public static let openTerminalDashboardTitle = "Open Dashboard in Terminal"
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

    /// Heading of the forced tickets, shown only while there are some.
    public static let forcedTitle = "Forced"

    /// Title of the menu item that asks for a ticket to force, and its title while the request is under way.
    public static let forceTitle = "Force a ticket…"
    public static func forcingTitle(_ identifier: String) -> String { "Forcing \(identifier)…" }

    /// Text of the prompt Force a ticket… shows, and its buttons.
    public static let forcePromptTitle = "Force a ticket"
    public static let forcePromptMessage = """
        Enter a Linear identifier, for example TP-123. Symphony adds its force label, so the ticket skips the \
        dispatch limits. It still waits for its blockers, a pause and usage limits, and its reviews still apply.
        """
    public static let forcePromptButton = "Force"
    public static let forcePromptPlaceholder = "TP-123"

    /// Force is offered while Symphony answers, whether or not dispatch is paused: a forced ticket waits out a pause.
    public static func canForce(_ status: SymphonyStatus) -> Bool {
        switch status {
        case .running, .paused:
            return true
        case .stopped, .starting, .error:
            return false
        }
    }

    /// The identifier typed into the prompt, nil when nothing was.
    public static func forceIdentifier(_ input: String) -> String? {
        let identifier = input.trimmingWhitespace()
        return identifier.isEmpty ? nil : identifier
    }

    /// The forced tickets the menu lists, none while Symphony doesn't answer.
    public static func forcedTickets(_ status: SymphonyStatus) -> [StateSnapshot.ForcedTicket] {
        switch status {
        case let .running(snapshot, _), let .paused(snapshot, _):
            return snapshot.forced
        case .stopped, .starting, .error:
            return []
        }
    }

    /// One forced ticket, for example "⚡ TP-123 · implementation · running · forced 3h 5m", or
    /// "⚡ TP-100 → TP-101 · waiting for a human · forced 3d 2h · stale" for a forced parent past the stale age.
    public static func forcedLine(_ ticket: StateSnapshot.ForcedTicket) -> String {
        let name = ticket.part.map { "\(ticket.identifier) → \($0)" } ?? ticket.identifier
        let parts = [
            "⚡ \(name)",
            ticket.summary ?? ticket.state,
            ticket.forcedForSeconds.map { "forced \(durationLabel($0))" },
            ticket.stale ? "stale" : nil,
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// Title of the action on a forced ticket's row that removes its force label.
    public static func stopForcingTitle(_ identifier: String) -> String { "Stop forcing \(identifier)" }

    /// A duration in its two largest units, as Symphony's dashboards show it: "45s", "12m", "3h 5m", "2d 4h".
    public static func durationLabel(_ seconds: Int) -> String {
        switch seconds {
        case ..<60:
            return "\(max(seconds, 0))s"
        case ..<3_600:
            return "\(seconds / 60)m"
        case ..<86_400:
            return "\(seconds / 3_600)h \(seconds % 3_600 / 60)m"
        default:
            return "\(seconds / 86_400)d \(seconds % 86_400 / 3_600)h"
        }
    }

    /// Title of the menu item that restarts Symphony gracefully, and its title while a restart is under way.
    public static let restartTitle = "Restart Symphony"
    public static let restartingTitle = "Restarting Symphony…"

    /// Shown while a restart waits for agent runs: after the timeout, stop without waiting any longer.
    public static let restartNowTitle = "Restart Now Anyway"

    /// Shown while a restart waits for agent runs: stop waiting and resume the dispatch the restart paused.
    public static let cancelRestartTitle = "Cancel Restart"

    /// Restart is offered for a Symphony the app started that answers; an external one is left alone.
    public static func canRestart(_ status: SymphonyStatus) -> Bool {
        switch status {
        case let .running(_, external), let .paused(_, external):
            return !external
        case .stopped, .starting, .error:
            return false
        }
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
