import Foundation

/// When the app checks for a newer release in the background, and what the last check found, kept free of AppKit so
/// it can be unit tested with an injected clock. `UpdatePoller` re-arms its timer with `interval` after each check and
/// each settings change.
///
/// - Automatically when released checks every `releaseCheckMinutes`; the other modes every 6 hours.
/// - `override`, from `SYMPHONY_BAR_UPDATE_CHECK_INTERVAL` in QA mode, replaces that in every mode.
/// - After a check that hit GitHub's rate limit, it waits until GitHub lifts the limit, at most an hour, or the
///   usual interval when that is longer. Any other failed check, such as one that couldn't reach GitHub, retries at
///   the usual interval. A check chosen by hand counts too.
/// - Symphony reports the newest release on each status poll (`ReportedRelease`), so the app hears of one without
///   asking GitHub. A newer one than the app knows starts a check at once, one per release (`checksAtOnce`); the timer
///   is the safety net for when Symphony doesn't report.
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
    /// True from the start of a check until its result.
    public private(set) var isChecking = false
    /// The last finished check, nil before the first.
    public private(set) var last: Outcome?
    /// The tag of the last release Symphony reported that started a check, so a release starts one check at most.
    public private(set) var reportedTag: String?

    public init(mode: UpdateMode, releaseCheckMinutes: Int, override: TimeInterval? = nil) {
        self.mode = mode
        self.releaseCheckMinutes = AppSettings.clampedReleaseCheckMinutes(releaseCheckMinutes)
        self.override = override
    }

    /// How long until the next background check, from the last check.
    public var interval: TimeInterval {
        let usual = override ?? UpdateChecker.interval(for: mode, releaseCheckMinutes: releaseCheckMinutes)
        guard let last, case let .failed(_, retryAt?) = last.result else { return usual }
        return max(usual, retryAt.timeIntervalSince(last.at))
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

    /// A check starts; `reported` is the release Symphony reported that started it, nil for any other check.
    public mutating func began(reported: ReportedRelease? = nil) {
        isChecking = true
        if let reported { reportedTag = reported.tag }
    }

    /// True when the release Symphony reports on a status poll should start a check now: it is newer than the running
    /// build and than the release the last check found, no check started for it yet, and no check runs or waits out
    /// GitHub's rate limit. The check that starts passes it to `began(reported:)`.
    public func checksAtOnce(for release: ReportedRelease?, running: AppBuild, now: Date) -> Bool {
        guard let release, release.tag != reportedTag, !isChecking, !rateLimited(at: now) else { return false }
        return Self.isNewer(release.version, than: running.version)
            && Self.isNewer(release.version, than: lastRelease?.version)
    }

    /// The release the last check found, available or not; nil before one did, or after a check failed.
    private var lastRelease: Release? {
        switch last?.result {
        case let .available(release)?, let .upToDate(release)?: release
        case .failed?, nil: nil
        }
    }

    private func rateLimited(at now: Date) -> Bool {
        guard case let .failed(_, retryAt?)? = last?.result else { return false }
        return now < retryAt
    }

    /// Whether `version` is newer than `known`: by number part by part, as `0.0.1.583` after `0.0.1.42`. A version
    /// that isn't all numbers is newer when it differs, and any version is newer than none.
    static func isNewer(_ version: String, than known: String?) -> Bool {
        guard let known else { return true }
        guard let parts = numbers(version), let knownParts = numbers(known) else { return version != known }
        for index in 0..<max(parts.count, knownParts.count) {
            let part = index < parts.count ? parts[index] : 0
            let knownPart = index < knownParts.count ? knownParts[index] : 0
            if part != knownPart { return part > knownPart }
        }
        return false
    }

    private static func numbers(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        return parts.contains(nil) ? nil : parts.compactMap { $0 }
    }

    /// Records a check's result, which `interval` follows.
    public mutating func finished(_ result: UpdateCheckResult, at date: Date) {
        isChecking = false
        last = Outcome(result, at: date)
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
        case let .failed(message, _):
            let time = TimeOfDay(date: last.at, calendar: calendar).label
            let next = TimeOfDay(date: last.at.addingTimeInterval(interval), calendar: calendar).label
            return "▲ Couldn't check at \(time): \(UpdateChecker.failureReason(message)). Next check at \(next)."
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
    public static let rateLimitNote = "Every check counts against GitHub's limit of \(UpdateChecker.hourlyRateLimit) "
        + "requests an hour from this Mac, which other apps share. After a check hits the limit, the app waits for "
        + "GitHub to reset it, at most an hour."

    /// Shown once in place of the last-check line after a typed value was moved into range (S1d), for example
    /// "Between 2 and 60 minutes. 0 was changed to 2."
    public static func clampedLine(typed: Int, to minutes: Int) -> String {
        let range = AppSettings.releaseCheckMinutesRange
        return "Between \(range.lowerBound) and \(range.upperBound) minutes. \(typed) was changed to \(minutes)."
    }

    /// The minutes to store and the note to show after the field commits `typed` over `current`: a value out of
    /// range is moved into it with `clampedLine`. A commit of the value already stored, such as the field writing
    /// back the moved value, keeps `note`; another value in range clears it.
    public static func committed(_ typed: Int, current: Int, note: String?) -> (minutes: Int, note: String?) {
        let minutes = AppSettings.clampedReleaseCheckMinutes(typed)
        if minutes != typed { return (minutes, clampedLine(typed: typed, to: minutes)) }
        return (minutes, typed == current ? note : nil)
    }

    /// "just now" under a minute, otherwise for example "2 min ago".
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        return seconds < 60 ? "just now" : "\(Overview.duration(seconds)) ago"
    }
}
