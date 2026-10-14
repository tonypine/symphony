import Foundation

/// When the app checks for a newer release in the background, and what the last check found, kept free of AppKit so
/// it can be unit tested with an injected clock. `UpdatePoller` re-arms its timer with `interval` after each check and
/// each settings change.
///
/// - Automatically when released checks every `releaseCheckMinutes`; the other modes every 6 hours.
/// - `override`, from `SYMPHONY_BAR_UPDATE_CHECK_INTERVAL` in QA mode, replaces that in every mode.
/// - After a failed check, such as GitHub's rate limit, it waits 6 hours until a check succeeds, so the app doesn't
///   pile up requests against the limit. A check chosen by hand counts too.
public struct UpdateCheckSchedule: Equatable {
    /// The result of a finished check and when it finished.
    public struct Outcome: Equatable {
        public var result: UpdateCheckResult
        public var at: Date

        public init(_ result: UpdateCheckResult, at: Date) {
            self.result = result
            self.at = at
        }
    }

    public private(set) var mode: UpdateMode
    /// Within `AppSettings.releaseCheckMinutesRange`.
    public private(set) var releaseCheckMinutes: Int
    /// Seconds between checks in every mode, for tests and QA; nil to follow the mode and the setting.
    public let override: TimeInterval?
    /// True from a failed check until a check succeeds.
    public private(set) var backingOff = false
    /// True from the start of a check until its result.
    public private(set) var isChecking = false
    /// The last finished check, nil before the first.
    public private(set) var last: Outcome?

    public init(mode: UpdateMode, releaseCheckMinutes: Int, override: TimeInterval? = nil) {
        self.mode = mode
        self.releaseCheckMinutes = AppSettings.clampedReleaseCheckMinutes(releaseCheckMinutes)
        self.override = override
    }

    /// How long until the next background check.
    public var interval: TimeInterval {
        if backingOff { return UpdateChecker.interval }
        return override ?? UpdateChecker.interval(for: mode, releaseCheckMinutes: releaseCheckMinutes)
    }

    /// Takes saved settings. True when the app should check now: the mode became Automatically when released, or
    /// its minutes changed while it is chosen. Either way the app re-arms its timer with the new `interval`.
    public mutating func configure(mode: UpdateMode, releaseCheckMinutes: Int) -> Bool {
        let minutes = AppSettings.clampedReleaseCheckMinutes(releaseCheckMinutes)
        let checkNow = mode == .onRelease && (self.mode != .onRelease || self.releaseCheckMinutes != minutes)
        self.mode = mode
        self.releaseCheckMinutes = minutes
        return checkNow
    }

    public mutating func began() {
        isChecking = true
    }

    /// Records a check's result: a failure backs off to 6 hours, a success ends the back-off.
    public mutating func finished(_ result: UpdateCheckResult, at date: Date) {
        isChecking = false
        last = Outcome(result, at: date)
        if case .failed = result {
            backingOff = true
        } else {
            backingOff = false
        }
    }

    /// The line under Check for releases every N minutes in Settings (S1a–S1c). The view shows a spinner beside it
    /// while `isChecking`. `now` and `calendar` place the check in time.
    public func settingsLine(now: Date, calendar: Calendar) -> String {
        if isChecking { return Self.checkingLine }
        guard let last else { return Self.notCheckedLine }
        switch last.result {
        case let .upToDate(release):
            return "● Checked \(Self.ago(last.at, now: now)): v\(release.version) is the newest release."
        case let .available(release):
            return "● Checked \(Self.ago(last.at, now: now)): v\(release.version) is available."
        case let .failed(message):
            let time = TimeOfDay(date: last.at, calendar: calendar).label
            return "▲ Couldn't check at \(time): \(UpdateChecker.failureReason(message)). "
                + "Next check in \(Self.hours(UpdateChecker.interval))."
        }
    }

    /// The disabled line under Check for Updates… in Automatically when released after a check found nothing new
    /// (S2a), for example "Up to date: v0.0.1.42, checked 2 min ago"; nil otherwise.
    public func menuLine(now: Date) -> String? {
        guard mode == .onRelease, let last, case let .upToDate(release) = last.result else { return nil }
        return "Up to date: v\(release.version), checked \(Self.ago(last.at, now: now))"
    }

    public static let checkingLine = "Checking for a new release…"
    public static let notCheckedLine = "Not checked yet."
    /// Settings' footer note in Automatically when released.
    public static let rateLimitNote = "Checks that find nothing new don't count against GitHub's rate limit."

    /// Shown once in place of the last-check line after a typed value was moved into range (S1d), for example
    /// "Between 1 and 60 minutes. 0 was changed to 1."
    public static func clampedLine(typed: Int, to minutes: Int) -> String {
        let range = AppSettings.releaseCheckMinutesRange
        return "Between \(range.lowerBound) and \(range.upperBound) minutes. \(typed) was changed to \(minutes)."
    }

    /// "just now" under a minute, otherwise for example "2 min ago".
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        return seconds < 60 ? "just now" : "\(Overview.duration(seconds)) ago"
    }

    /// For example "6 hours" or "1 hour".
    static func hours(_ interval: TimeInterval) -> String {
        let hours = Int(interval / 3_600)
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }
}
