import Combine
import Foundation

/// The ticket page as the window stores it (TP-1479): the page and its Timeline, built once from one set of sources.
/// Reading it builds nothing; the toolbar's title and the feed's repo are fields of it.
public struct TicketPageModel: Equatable {
    public var page: TicketPage
    public var timeline: TimelineModel

    public var identifier: String { page.identifier }
    public var title: String? { page.title }
    public var repoKey: String? { page.repoKey }

    public init(page: TicketPage, timeline: TimelineModel) {
        self.page = page
        self.timeline = timeline
    }

    /// The page and its Timeline from `key`'s sources, measured against `now` and laid out in `calendar`'s days.
    public static func build(_ key: TicketPageKey, now: Date = Date(), calendar: Calendar = .current) -> TicketPageModel {
        let page = TicketPage(identifier: key.identifier, sources: key.sources, now: now, timeZone: calendar.timeZone)
        return TicketPageModel(page: page, timeline: page.timelineModel(calendar: calendar))
    }
}

/// What a page is built from: the ticket and its sources, with the state cut to the parts the page reads. Two keys
/// that compare equal build the same page, so the second builds nothing.
public struct TicketPageKey: Equatable {
    public var identifier: String
    public var sources: TicketPage.Sources

    /// `sources` as the page reads them: the state cut to `identifier`'s parts (`TicketPage.stateSlice`).
    public init(identifier: String, sources: TicketPage.Sources) {
        self.identifier = identifier
        var sources = sources
        sources.state = sources.state.flatMap { TicketPage.stateSlice($0, identifier: identifier) }
        self.sources = sources
    }
}

extension TicketPage {
    /// The page's Timeline: its history with the run now's step, lines and tokens so far, and the marks.
    public func timelineModel(calendar: Calendar) -> TimelineModel {
        TimelineModel.build(
            history ?? TicketEventsPayload(), runNow: runNow, liveTokens: runTokens, reference: reference, calendar: calendar,
            lookedAt: marksRead?.lookedAt
        )
    }

    /// The state's lists the page reads, cut to the ticket's own entries.
    static let sliceLists = [
        "running", "retrying", "watching", "waiting_on_you", "slot_waiting", "dispatch_skipped", "blocked",
        "shipped_today", "forced", "run_history", "issues",
    ]
    /// The state's blocks the page reads whole: the budget, the QA passes, the epic lanes, the phases and the
    /// watcher's rate limit.
    static let sliceBlocks = ["budget", "qa", "epic_lanes", "phases", "rate_limit"]

    /// The parts of the state payload the page of `identifier` reads, as sorted JSON: its own entries in each list and
    /// the blocks it reads whole, without `generated_at` or any other ticket. A poll that changes only the time or
    /// another ticket gives the same bytes, so the page isn't built again (TP-1479). The page then measures against
    /// when it was built. Nil when the state isn't a JSON object.
    public static func stateSlice(_ data: Data, identifier: String) -> Data? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var slice: [String: Any] = [:]
        for key in sliceLists {
            guard let list = object[key] as? [Any] else { continue }
            slice[key] = list.filter { element in
                guard let entry = element as? [String: Any] else { return false }
                return [entry["issue_identifier"], entry["identifier"]].contains { $0 as? String == identifier }
            }
        }
        for key in sliceBlocks {
            if let block = object[key] { slice[key] = block }
        }
        return try? JSONSerialization.data(withJSONObject: slice, options: [.sortedKeys])
    }
}

/// Builds the shown ticket's page off the main actor when its sources changed, and publishes it once (TP-1479). Sources
/// that cut to the same key as the page shown, or the one being built, build nothing.
@MainActor
public final class TicketPageBuilder: ObservableObject {
    /// The page last built, for the ticket last asked for; nil before its first build and on a sidebar view.
    @Published public private(set) var model: TicketPageModel?
    /// How many pages it built, for the tests.
    public private(set) var builds = 0

    private let build: @Sendable (TicketPageKey) -> TicketPageModel
    /// Counts the updates, so a slow cut never overtakes a newer one.
    private var updates = 0
    /// The key of the newest update, the one the page should show.
    private var wanted: TicketPageKey?
    private var building: TicketPageKey?
    private var built: TicketPageKey?

    public init(build: @escaping @Sendable (TicketPageKey) -> TicketPageModel = { TicketPageModel.build($0) }) {
        self.build = build
    }

    /// The page of `identifier` from `sources`: cut and compared off the main actor, built there only when the cut
    /// differs from the page shown, and published once built unless a newer update asked for another. Nil leaves the
    /// page: the model is cleared at once.
    public func update(identifier: String?, sources: TicketPage.Sources) async {
        updates += 1
        let update = updates
        guard let identifier else {
            wanted = nil
            built = nil
            if model != nil { model = nil }
            return
        }
        let key = await Task.detached(priority: .userInitiated) { TicketPageKey(identifier: identifier, sources: sources) }.value
        guard update == updates else { return }
        wanted = key
        guard key != built, key != building else { return }
        building = key
        builds += 1
        let build = build
        let model = await Task.detached(priority: .userInitiated) { build(key) }.value
        if building == key { building = nil }
        guard wanted == key else { return }
        built = key
        self.model = model
    }
}
