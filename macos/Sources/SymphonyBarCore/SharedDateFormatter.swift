import Foundation

/// The date formatters the app's pages share: one per pattern, locale, calendar and time zone, made the first time it
/// is asked for and kept. Making a `DateFormatter` costs far more than using one, so no page makes one per row or per
/// redraw (the ticket page's timeline formats a time for every event).
public enum SharedDateFormatter {
    public static let posix = Locale(identifier: "en_US_POSIX")
    public static let british = Locale(identifier: "en_GB")

    /// `date` in `format`, a fixed pattern such as "HH:mm"; with `template`, a template the locale orders ("MMMd").
    /// The time zone is `timeZone`, else `calendar`'s.
    public static func string(
        _ date: Date, format: String, template: Bool = false, locale: Locale = posix,
        calendar: Calendar = Calendar(identifier: .gregorian), timeZone: TimeZone? = nil
    ) -> String {
        let key = Key(format: format, template: template, locale: locale, calendar: calendar, timeZone: timeZone ?? calendar.timeZone)
        return cache.string(date, key)
    }

    private struct Key: Hashable {
        let format: String
        let template: Bool
        let locale: Locale
        let calendar: Calendar
        let timeZone: TimeZone
    }

    /// The formatters by key; formatting happens under the lock, so a formatter is never used by two threads at once.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var formatters: [Key: DateFormatter] = [:]

        func string(_ date: Date, _ key: Key) -> String {
            lock.withLock {
                if let formatter = formatters[key] { return formatter.string(from: date) }
                let formatter = DateFormatter()
                formatter.locale = key.locale
                formatter.calendar = key.calendar
                formatter.timeZone = key.timeZone
                if key.template {
                    formatter.setLocalizedDateFormatFromTemplate(key.format)
                } else {
                    formatter.dateFormat = key.format
                }
                formatters[key] = formatter
                return formatter.string(from: date)
            }
        }
    }

    private static let cache = Cache()
}
