import Combine
import Foundation

/// What the ticket page shows from the rest of the window (TP-1480): its open Questions with the Inbox's picks, the
/// chips in its text, the Inbox item Review opens, the event it opened at and the banner under it. The window sets it
/// after any change of its own, and the page draws again only when it differs.
public struct TicketPageContext: Equatable {
    public var questions: [InboxReview.Action]
    public var picks: DecisionPicks
    /// True while an answer is held for Undo or on its way: Send stays off.
    public var sending: Bool
    /// Why Symphony refused the last answer sent from the page.
    public var failure: String?
    public var references: [String: Reference]
    /// The Inbox item the decisions line's Review opens, nil while the Inbox lists none waiting on the Director.
    public var reviewItemID: String?
    public var focus: TimelineFocus?
    public var banner: InboxBanner?

    public init(
        questions: [InboxReview.Action] = [], picks: DecisionPicks = DecisionPicks(), sending: Bool = false, failure: String? = nil,
        references: [String: Reference] = [:], reviewItemID: String? = nil, focus: TimelineFocus? = nil, banner: InboxBanner? = nil
    ) {
        self.questions = questions
        self.picks = picks
        self.sending = sending
        self.failure = failure
        self.references = references
        self.reviewItemID = reviewItemID
        self.focus = focus
        self.banner = banner
    }
}

/// The ticket page's own model (TP-1480): the page observes it instead of the window, so a change elsewhere in the
/// window (the Inbox's count, the Overview, Initiatives) draws nothing on the page, and a change to the ticket draws
/// nothing elsewhere. It publishes the page without its timeline (the header, the Lifecycle card and the facts rail),
/// and the Timeline publishes on its own object, so an event that changes only the timeline draws only the timeline.
/// Each publishes only when what it holds differs.
@MainActor
public final class TicketPageStore: ObservableObject {
    /// The page shown, without its history's events and timeline steps; nil before its first build and on a sidebar
    /// view.
    @Published public private(set) var page: TicketPage?
    /// What the page shows from the rest of the window.
    @Published public private(set) var context = TicketPageContext()
    /// The page's Timeline, on its own object.
    public let timeline = TicketTimelineStore()
    public let builder: TicketPageBuilder
    /// The page and its Timeline as last built, whole: what the window reads (a run for the session reader).
    public private(set) var model: TicketPageModel?
    /// Called once a page was built, after the store took it.
    public var onBuilt: (TicketPageModel?) -> Void = { _ in }
    private var cancellable: AnyCancellable?

    public init(builder: TicketPageBuilder = TicketPageBuilder()) {
        self.builder = builder
        cancellable = builder.$model.dropFirst().sink { [weak self] model in
            guard let self else { return }
            take(model)
            onBuilt(model)
        }
    }

    /// The page of `identifier` from `sources`, built off the main actor when they changed (`TicketPageBuilder`).
    public func update(identifier: String?, sources: TicketPage.Sources) async {
        await builder.update(identifier: identifier, sources: sources)
    }

    /// Sets what the page shows from the rest of the window; the same context publishes nothing.
    public func show(_ context: TicketPageContext) {
        if self.context != context { self.context = context }
    }

    /// Takes a built page: its parts publish only when they differ, the time it was built aside.
    func take(_ model: TicketPageModel?) {
        self.model = model
        let shell = model.map { Self.shell($0.page) }
        if !Self.same(page, shell) { page = shell }
        timeline.show(model?.timeline)
    }

    /// `page` as the header, the Lifecycle card and the facts rail read it: its history's run headers without its
    /// events, and no timeline steps, which the Timeline draws.
    public static func shell(_ page: TicketPage) -> TicketPage {
        var shell = page
        shell.history = page.history?.runsOnly
        shell.timeline = []
        return shell
    }

    /// Whether two pages show the same, whatever moment each measures against.
    static func same(_ lhs: TicketPage?, _ rhs: TicketPage?) -> Bool {
        guard var lhs, let rhs else { return lhs == nil && rhs == nil }
        lhs.reference = rhs.reference
        return lhs == rhs
    }
}

/// The ticket page's Timeline on its own object (TP-1480): only the Timeline section observes it.
@MainActor
public final class TicketTimelineStore: ObservableObject {
    @Published public private(set) var model: TimelineModel?

    public init() {}

    /// Shows `model`; one that differs only in the moment it measures against publishes nothing.
    func show(_ model: TimelineModel?) {
        guard !Self.same(self.model, model) else { return }
        self.model = model
    }

    static func same(_ lhs: TimelineModel?, _ rhs: TimelineModel?) -> Bool {
        guard var lhs, let rhs else { return lhs == nil && rhs == nil }
        lhs.reference = rhs.reference
        return lhs == rhs
    }
}
