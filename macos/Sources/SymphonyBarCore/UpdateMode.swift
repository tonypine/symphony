import Foundation

/// How the app installs a newer release. The automatic modes install through `AutoUpdater`.
public enum UpdateMode: String, CaseIterable, Identifiable {
    /// The menu shows a newer release; you install it with Update to vX.
    case manual
    case whenIdle
    case atTime

    public var id: String { rawValue }

    /// The picker's label for the mode.
    public var title: String {
        switch self {
        case .manual: return "Manual"
        case .whenIdle: return "Automatically when idle"
        case .atTime: return "Automatically at a set time"
        }
    }

    /// What the mode does, under the picker.
    public var explanation: String {
        switch self {
        case .manual:
            return "Symphony checks for a new release every 6 hours and shows it in the menu. You install it with "
                + "Update to vX."
        case .whenIdle:
            return "Symphony installs a new release by itself as soon as no agent runs are active. It never pauses "
                + "dispatch or interrupts a run to get there. " + UpdateMode.skipNote
        case .atTime:
            return "Each day at this time Symphony checks for a new release and installs it: it pauses dispatch, "
                + "waits for agent runs to finish, updates, and resumes dispatch. If the runs outlast the restart "
                + "timeout it resumes dispatch and tries again the next day. " + UpdateMode.skipNote
        }
    }

    private static let skipNote = "A release you skip is never installed by itself."
}

/// A time of day, to the minute, in the Mac's time zone.
public struct TimeOfDay: Equatable {
    public static let minutesPerDay = 24 * 60

    /// When Automatically at a set time installs until you pick another time.
    public static let defaultUpdateTime = TimeOfDay(hour: 3, minute: 0)

    /// Minutes since midnight, 0 to 1439.
    public let minutesSinceMidnight: Int

    /// Nil unless `minutesSinceMidnight` is 0 to 1439.
    public init?(minutesSinceMidnight: Int) {
        guard (0..<Self.minutesPerDay).contains(minutesSinceMidnight) else { return nil }
        self.minutesSinceMidnight = minutesSinceMidnight
    }

    /// `hour` is 0 to 23 and `minute` 0 to 59; other values wrap around the day.
    public init(hour: Int, minute: Int) {
        let minutes = (hour * 60 + minute) % Self.minutesPerDay
        minutesSinceMidnight = minutes < 0 ? minutes + Self.minutesPerDay : minutes
    }

    /// The hour and minute of `date` in `calendar`'s time zone.
    public init(date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }

    public var hour: Int { minutesSinceMidnight / 60 }
    public var minute: Int { minutesSinceMidnight % 60 }

    /// This time on the day of `day`, for a time picker. `day` itself when the day has no such time, as when
    /// clocks skip it.
    public func date(on day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    /// The first time after `now` that the clock shows this time in `calendar`'s time zone: today's if it is still
    /// ahead, otherwise tomorrow's. On a day the clocks skip it, the first moment after the gap.
    public func nextDate(after now: Date, calendar: Calendar) -> Date {
        let parts = DateComponents(hour: hour, minute: minute, second: 0)
        return calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(TimeInterval(Self.minutesPerDay * 60))
    }

    /// For example "03:00".
    public var label: String {
        String(format: "%02d:%02d", hour, minute)
    }
}
