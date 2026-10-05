import Foundation

/// How the app installs a newer release. Only Manual installs anything yet: the automatic modes are saved and
/// shown, and a later version makes them install.
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

    /// What the mode does, under the picker. The automatic modes say what they will do, and that they don't yet.
    public var explanation: String {
        switch self {
        case .manual:
            return "Symphony checks for a new release every 6 hours and shows it in the menu. You install it with "
                + "Update to vX."
        case .whenIdle:
            return "Will install a new release by itself once no agent runs are active. "
                + UpdateMode.notActiveYet
        case .atTime:
            return "Will install a new release by itself each day at this time, waiting for agent runs like "
                + "Update to vX. " + UpdateMode.notActiveYet
        }
    }

    private static let notActiveYet = "Not active yet: until a later version turns it on, install updates from the menu."
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

    /// For example "03:00".
    public var label: String {
        String(format: "%02d:%02d", hour, minute)
    }
}
