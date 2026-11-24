import Foundation

/// Home's Recently done (TP-1644, `docs/design/prototypes/home-queue/README.md`, section Recently done): the tickets that
/// finished in the picked range, most recent first, as the Home read gives them, with both ranges' counts. Its first
/// page comes with each read of Home's first page, so a ticket that finishes shows at the top at the engine's next
/// `event: queue`; later pages are read as the person scrolls inside the section. The range and the fold are the
/// person's, remembered across relaunches (`RecentlyDoneChoices`).
public struct RecentlyDoneList: Equatable {
    public static let title = "Recently done"
    /// The entries a page asks for.
    public static let pageSize = 50
    /// The most a read gives at once.
    public static let maxLimit = 500
    /// The rows the section shows before it scrolls inside itself.
    public static let visibleRows = 6

    /// The range picked.
    public private(set) var range: HomeRead.DoneRange
    /// Whether the section is open; folded, only its head shows.
    public var open: Bool
    /// What finished today and in the last 7 days.
    public private(set) var today = 0
    public private(set) var week = 0
    /// The picked range's entries read so far, most recent first.
    public private(set) var entries: [HomeRead.DoneEntry] = []
    /// The next page's offset, nil once every entry is read.
    public private(set) var nextOffset: Int?

    public init(range: HomeRead.DoneRange = .today, open: Bool = true) {
        self.range = range
        self.open = open
    }

    public init(_ choices: RecentlyDoneChoices) {
        self.init(range: choices.range, open: choices.open)
    }

    /// The choices as stored.
    public var choices: RecentlyDoneChoices { RecentlyDoneChoices(range: range, open: open) }

    /// The picked range's count.
    public var count: Int { range == .today ? today : week }
    /// The count beside the title: the picked range's, nil at 0.
    public var countText: String? { count > 0 ? DesignTokens.HomeQueue.number(count) : nil }
    /// Whether the section is drawn at all: something finished in the last 7 days.
    public var drawn: Bool { week > 0 }
    /// Whether rows show under the head: open, with entries in the range.
    public var showsRows: Bool { open && !entries.isEmpty }

    /// The first page a read of Home asks for: as many entries as are read already, so a read again keeps what the
    /// person scrolled to, and at least a page.
    public var firstPage: HomeRead.DonePage {
        HomeRead.DonePage(range: range, offset: 0, limit: min(max(entries.count, Self.pageSize), Self.maxLimit))
    }

    /// The page after the entries read, nil once every one is.
    public var nextPage: HomeRead.DonePage? {
        nextOffset.map { HomeRead.DonePage(range: range, offset: $0, limit: Self.pageSize) }
    }

    /// Picks `range`: its entries are read again from the first.
    public mutating func pick(_ range: HomeRead.DoneRange) {
        guard range != self.range else { return }
        self.range = range
        entries = []
        nextOffset = nil
    }

    /// Takes what a read gave: the counts always; the entries only for the range picked (a read sent before the pick
    /// changed is dropped). The first page replaces the entries, a later one follows those before it.
    public mutating func take(_ done: HomeRead.RecentlyDone) {
        today = done.today
        week = done.week
        guard done.range == range else { return }
        if done.offset == 0 {
            entries = done.entries
        } else {
            guard done.offset <= entries.count else { return }
            entries = Array(entries.prefix(done.offset)) + done.entries
        }
        nextOffset = done.nextOffset
    }
}

/// The range and the fold of Recently done as the app remembers them (TP-1644): in the app's own store, so they last
/// across relaunches, and in QA's store under QA. The defaults are Today and open.
public struct RecentlyDoneChoices: Equatable {
    public enum Key {
        public static let range = "home.recentlyDone.range"
        public static let open = "home.recentlyDone.open"
    }

    public var range: HomeRead.DoneRange
    public var open: Bool

    public init(range: HomeRead.DoneRange = .today, open: Bool = true) {
        self.range = range
        self.open = open
    }

    /// The choices `defaults` holds, the defaults for any it lacks.
    public static func load(from defaults: KeyValueStore) -> RecentlyDoneChoices {
        RecentlyDoneChoices(
            range: (defaults.object(forKey: Key.range) as? String).flatMap(HomeRead.DoneRange.init(rawValue:)) ?? .today,
            open: defaults.object(forKey: Key.open) as? Bool ?? true
        )
    }

    public func save(to defaults: KeyValueStore) {
        defaults.set(range.rawValue, forKey: Key.range)
        defaults.set(open, forKey: Key.open)
    }
}

/// When a ticket finished, as a done row says it (`.drow .when`): "20 min ago" within the hour, "3 h ago" earlier the
/// same day, "yesterday" the day before, then the day ("Sat").
public enum DoneWhen {
    public static func text(_ date: Date?, now: Date, timeZone: TimeZone = .current) -> String {
        guard let date else { return "" }
        let seconds = max(now.timeIntervalSince(date), 0)
        if seconds < 3600 { return "\(max(Int(seconds / 60), 1)) min ago" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600)) h ago" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }
}
