import Foundation

/// A ticket or pull request open in the peek (N4): the mention as written and what Symphony resolved it to, so a page
/// shows the same thing however it was reached, from a chip in the review or one inside the peek.
public struct PeekEntry: Hashable, Identifiable {
    public var key: String
    public var kind: Mention.Kind
    public var reference: Reference

    public init(key: String, kind: Mention.Kind, reference: Reference) {
        self.key = key
        self.kind = kind
        self.reference = reference
    }

    public init(_ mention: Mention) {
        self.init(key: mention.key, kind: mention.kind, reference: mention.reference)
    }

    public var id: String { key }

    /// The ticket's identifier, nil for a pull request or a ticket Symphony can't see.
    public var ticketIdentifier: String? {
        if case let .ticket(ticket) = reference { return ticket.identifier }
        return nil
    }

    /// The peek's title: "TP-891", "#448".
    public var title: String {
        if case let .pullRequest(pullRequest) = reference { return "#\(pullRequest.number)" }
        return ticketIdentifier ?? key
    }
}

/// N4's navigation: the pages the peek shows, the first one opened from the review and the others pushed by following
/// a chip inside it. Closing keeps the pages, so the toolbar's inspector toggle shows them again; the review's picks
/// and scroll position live elsewhere and never change here.
public struct PeekNavigation: Equatable {
    public static let backTitle = "Back"
    public static let closeTitle = "Close"
    public static let toggleTitle = "Peek"

    /// The pages, the one shown last.
    public private(set) var pages: [PeekEntry] = []
    /// Whether the peek shows: false once closed, with its pages kept.
    public private(set) var isShown = false

    public init() {}

    public var current: PeekEntry? { pages.last }
    public var root: PeekEntry? { pages.first }
    public var canGoBack: Bool { isShown && pages.count > 1 }

    /// A chip in the review: the peek shows `entry` alone.
    public mutating func open(_ entry: PeekEntry) {
        pages = [entry]
        isShown = true
    }

    /// A chip inside the peek: `entry` goes on top. Following the page shown changes nothing.
    public mutating func push(_ entry: PeekEntry) {
        guard isShown, !pages.isEmpty else { return open(entry) }
        guard entry != current else { return }
        pages.append(entry)
    }

    /// The back arrow and ⌘[: the page before. False when there is none, so ⌘[ goes on to the window's history.
    @discardableResult
    public mutating func goBack() -> Bool {
        guard canGoBack else { return false }
        pages.removeLast()
        return true
    }

    /// Esc, Close, or the toolbar's toggle.
    public mutating func close() {
        isShown = false
    }

    /// The toolbar's inspector toggle: closes the peek, or shows its pages again.
    public mutating func toggle() {
        if isShown { close() } else if !pages.isEmpty { isShown = true }
    }

    /// Whether the toggle has anything to show.
    public var canToggle: Bool { isShown || !pages.isEmpty }
}

/// The peeked tickets whose `/api/v1/:issue_identifier` is on its way, by identifier: a ticket opened or pushed while
/// another's read is in flight is read at once, and a ticket is never read twice at the same time.
public struct PeekReads: Equatable {
    public private(set) var inFlight: Set<String> = []

    public init() {}

    /// The ticket to read now: the page shown, when the peek shows it, Symphony answers and its read isn't on its
    /// way. Marks it in flight until `finish`.
    public mutating func start(_ peek: PeekNavigation, countsKnown: Bool) -> String? {
        guard peek.isShown, countsKnown, let identifier = peek.current?.ticketIdentifier,
              !inFlight.contains(identifier) else { return nil }
        inFlight.insert(identifier)
        return identifier
    }

    /// `identifier`'s read answered.
    public mutating func finish(_ identifier: String) {
        inFlight.remove(identifier)
    }
}

/// Where the peek shows: the window's inspector column beside the review, or a sheet over the window when the detail
/// would be too narrow with the inspector open.
public enum PeekPresentation: Equatable {
    case inspector
    case sheet

    /// The inspector column's width (N4): 320 to 400 pt.
    public static let minInspectorWidth: Double = 320
    public static let idealInspectorWidth: Double = 340
    public static let maxInspectorWidth: Double = 400
    /// Under this, the decision's review beside the inspector is too narrow to read.
    public static let minDetailWidth: Double = DesignTokens.Layout.narrowReviewWidth

    /// The presentation for an Inbox `inboxWidth` wide (its list column, a divider and the review), measured with the
    /// inspector open when `inspectorShown`. The review left beside the inspector decides. While the inspector is
    /// closed its widest column is assumed, so a peek that turned into a sheet stays one until the window is wide
    /// enough for the inspector at any width, and never flips back and forth.
    public static func choose(inboxWidth: Double, inspectorShown: Bool) -> PeekPresentation {
        let review = inboxWidth - DesignTokens.Layout.listColumnWidth - 1
        let besideInspector = inspectorShown ? review : review - maxInspectorWidth
        return besideInspector < minDetailWidth ? .sheet : .inspector
    }
}

/// What the peek reads beside the entry's own reference: the Inbox (a ticket waiting on the Director brings where it
/// sits and its review brief), the Initiatives (a plan's sub-tickets, a sub-ticket's parent), Symphony's state and the
/// ticket page's endpoint, `/api/v1/:issue_identifier`.
public struct PeekSources: Equatable {
    public var inbox: [InboxItem]
    public var initiatives: [Initiative]
    public var state: Data?
    /// The peeked ticket's `/api/v1/:issue_identifier`; nil when it answered 404 or wasn't read yet.
    public var issue: Data?

    public init(inbox: [InboxItem] = [], initiatives: [Initiative] = [], state: Data? = nil, issue: Data? = nil) {
        self.inbox = inbox
        self.initiatives = initiatives
        self.state = state
        self.issue = issue
    }
}

/// N4 for a ticket: N2's head, then for a ticket Symphony tracks **Now**, **Connected** and its review brief's
/// headline; for one it doesn't, the reference's own facts. Every ticket and pull request it names is written as a
/// mention ("TP-880 (Remove the Supervisor check)"), so the app draws it as a chip that pushes its own page.
public struct TicketPeek: Equatable {
    /// Now: the stage and how long it has been there, what it waits on, its pull request.
    public struct Now: Equatable {
        /// "Code Review · for 1 h".
        public var stage: String?
        /// "Waiting on you", "Waiting on a blocker: TP-892".
        public var waitingOn: String?
        /// "PR #446 · checks running".
        public var pullRequest: String?
    }

    /// N10: the parent and how far along its sub-tickets are, each one's status in landing order.
    public struct Parent: Equatable {
        public var text: String
        public var done: Int?
        public var total: Int?
        public var children: [DesignTokens.Status]

        /// "4 of 7 done", nil when the parent's sub-tickets aren't known.
        public var progress: String? {
            guard let done, let total, total > 0 else { return nil }
            return "\(done) of \(total) done"
        }
    }

    /// One connected ticket: its mention and its stage.
    public struct Row: Equatable {
        public var text: String
        public var state: String?
    }

    /// Connected: where the ticket sits among the others.
    public struct Connected: Equatable {
        public var parent: Parent?
        public var subTickets: [Row]
        public var blockedBy: [Row]
        public var blocks: [Row]
        public var related: [Row]

        public var isEmpty: Bool {
            parent == nil && subTickets.isEmpty && blockedBy.isEmpty && blocks.isEmpty && related.isEmpty
        }

        /// The groups with a ticket in them, in reading order, under their labels.
        public var groups: [(label: String, rows: [Row])] {
            [("Sub-tickets", subTickets), ("Blocked by", blockedBy), ("Blocks", blocks), ("Related", related)]
                .filter { !$0.rows.isEmpty }
        }
    }

    public static let nowTitle = "Now"
    public static let connectedTitle = "Connected"
    public static let headlineTitle = "Latest review brief"
    public static let openTicketPageTitle = "Open Ticket Page"
    public static let openInLinearTitle = "Open in Linear"

    public var identifier: String
    /// N2's head: identifier · repo with the stage badge, the title and the summary. Its facts are the reference's,
    /// for a ticket Symphony doesn't track.
    public var head: ReferencePopover.Ticket
    /// Whether Symphony tracks the ticket: it waits on the Director, the state lists it, or its endpoint answers.
    public var isTracked: Bool
    public var now: Now?
    public var connected: Connected?
    public var headline: String?
    public var linearURL: URL?
    /// Every mention the peek's text holds, for its chips.
    public var references: [String: Reference]

    public init(
        _ ticket: Reference.Ticket,
        references known: [String: Reference] = [:],
        sources: PeekSources = PeekSources(),
        now date: Date = Date()
    ) {
        let identifier = ticket.identifier
        let item = sources.inbox.first { $0.identifier == identifier }
        let page = TicketPage(identifier: identifier, sources: TicketPage.Sources(state: sources.state, issue: sources.issue), now: date)
        let status = sources.issue.flatMap { try? JSONDecoder().decode(IssueStatus.self, from: $0) }?.status
        let tracked = item != nil || page.phase != .unknown || status.map { $0 != "untracked" } ?? false
        var references = Self.references(known: known, inbox: sources.inbox)
        references[identifier] = references[identifier] ?? .ticket(ticket)

        self.identifier = identifier
        isTracked = tracked
        linearURL = ticket.url ?? item?.url ?? page.url
        let state = ticket.state ?? item?.state
        let base = ReferencePopover.Ticket(
            identifier: identifier, repoKey: ticket.repoKey ?? item?.repoKey ?? page.repoKey,
            badge: state.map { ReferencePopover.Badge(status: ReferencePopover.status(state: $0, waitingOn: ticket.waitingOn), word: $0) },
            title: ticket.title ?? item?.title ?? page.title, summary: ticket.summary, facts: []
        )

        // The pull request, as a mention whose chip finds it.
        let number = ticket.pullRequest?.number ?? item?.context?.pullRequest?.number
            ?? page.facts.first { $0.label == "Pull request" }?.url.flatMap(Self.pullRequestNumber)
        let pullRequest = number.map { number -> String in
            let key = "PR #\(number)"
            if references[key] == nil {
                let url = ticket.pullRequest?.url ?? item?.context?.pullRequest?.url
                references[key] = references["#\(number)"] ?? .missing(url: url)
            }
            let checks = ticket.pullRequest?.checks ?? item?.context?.pullRequest?.checks
            return ([key] + [checks?.words].compactMap { $0 }).joined(separator: " · ")
        }

        guard tracked else {
            var facts: [ReferencePopover.Fact] = []
            if let parent = ticket.parent {
                facts.append(.init(label: "Part of", value: Self.mention(parent.identifier, parent.title)))
                references[parent.identifier] = references[parent.identifier] ?? Self.ticket(parent.identifier, title: parent.title)
            }
            if let pullRequest { facts.append(.init(label: "Work", value: pullRequest)) }
            if let waitingOn = ticket.waitingOn { facts.append(.init(label: "Waiting on", value: waitingOn)) }
            head = base
            head.facts = facts
            now = nil
            connected = nil
            headline = nil
            self.references = references
            return
        }
        head = base

        // Now.
        let since = item?.waitingSeconds.map(Overview.duration) ?? page.now?.runningTime
        let stage = (state ?? page.facts.first { $0.label == "State" }?.value).map { stage in
            ([stage] + [since.map { "for \($0)" }].compactMap { $0 }).joined(separator: " · ")
        }
        let waitingOn: String? = if let waiting = ticket.waitingOn ?? (item != nil ? "you" : nil) {
            "Waiting on \(waiting)"
        } else if page.phase != .unknown {
            page.phaseSentence
        } else {
            nil
        }
        now = Now(stage: stage, waitingOn: waitingOn, pullRequest: pullRequest)

        // Connected.
        let context = item?.context
        let initiative = sources.initiatives.first { $0.identifier == identifier }
        let parentInitiative = sources.initiatives.first { $0.subTickets.contains { $0.identifier == identifier } }
        let asSubTicket = parentInitiative?.subTickets.first { $0.identifier == identifier }
        func row(_ identifier: String, title: String?, state: String?, url: URL? = nil) -> Row {
            references[identifier] = references[identifier] ?? Self.ticket(identifier, title: title, state: state, url: url)
            return Row(text: Self.mention(identifier, title), state: state)
        }

        var parent: Parent?
        if let known = context?.parent {
            parent = Parent(
                text: row(known.identifier, title: known.title, state: nil).text, done: known.done, total: known.total,
                children: known.children.map(Self.status(stateType:))
            )
        } else if let parentInitiative {
            parent = Parent(
                text: row(parentInitiative.identifier, title: parentInitiative.title, state: parentInitiative.state, url: parentInitiative.url).text,
                done: parentInitiative.doneCount, total: parentInitiative.subTickets.count,
                children: parentInitiative.subTickets.map(\.waits.stage.status)
            )
        } else if let known = ticket.parent {
            parent = Parent(text: row(known.identifier, title: known.title, state: nil).text, children: [])
        }

        let subTickets: [Row] = if let plan = item?.review.subTickets, !plan.isEmpty {
            plan.map { row($0.identifier, title: $0.title, state: $0.state, url: $0.url) }
        } else {
            (initiative?.subTickets ?? []).map { row($0.identifier, title: $0.title, state: $0.state, url: $0.url) }
        }
        let blockedBy: [Row] = if let known = context?.blockedBy, !known.isEmpty {
            known.map { row($0.identifier, title: $0.title, state: $0.state) }
        } else {
            (asSubTicket?.blockedBy ?? []).map { blocker in
                let sibling = parentInitiative?.subTickets.first { $0.identifier == blocker }
                return row(blocker, title: sibling?.title, state: sibling?.state, url: sibling?.url)
            }
        }
        let connected = Connected(
            parent: parent,
            subTickets: subTickets,
            blockedBy: blockedBy,
            blocks: (context?.blocks ?? []).map { row($0.identifier, title: $0.title, state: $0.state) },
            related: (context?.related ?? []).map { row($0.identifier, title: $0.title, state: $0.state) }
        )
        self.connected = connected.isEmpty ? nil : connected
        if case let .parsed(brief)? = item?.review.brief, let line = brief.headline?.trimmingWhitespace(), !line.isEmpty {
            headline = line
        } else {
            headline = nil
        }
        self.references = references
    }

    /// "TP-880 (Remove the Supervisor check)": a mention whose chip carries its short name, or the bare identifier.
    static func mention(_ identifier: String, _ title: String?) -> String {
        guard let title = title?.trimmingWhitespace(), !title.isEmpty, title.count <= 80, !title.contains(where: "()\n".contains) else {
            return identifier
        }
        return "\(identifier) (\(title))"
    }

    static func ticket(_ identifier: String, title: String?, state: String? = nil, url: URL? = nil) -> Reference {
        .ticket(Reference.Ticket(identifier: identifier, title: title, state: state, url: url))
    }

    /// Every item's references, so a chip the peek follows keeps what Symphony resolved for any item; `known` (the
    /// review's own) wins.
    static func references(known: [String: Reference], inbox: [InboxItem]) -> [String: Reference] {
        inbox.reduce(into: known) { merged, item in
            merged.merge(item.references) { kept, _ in kept }
        }
    }

    /// A Linear state type ("completed", "started") as N10's segment.
    static func status(stateType: String) -> DesignTokens.Status {
        switch stateType {
        case "completed": .done
        case "started": .working
        default: .idle
        }
    }

    static func pullRequestNumber(_ url: URL) -> Int? {
        guard url.pathComponents.dropLast().last == "pull" else { return nil }
        return Int(url.lastPathComponent)
    }

    private struct IssueStatus: Decodable {
        let status: String?
    }
}

extension Reference.Ticket {
    init(identifier: String, title: String?, state: String? = nil, url: URL? = nil) {
        self.init(
            identifier: identifier, title: title, repoKey: nil, state: state, summary: nil, url: url,
            parent: nil, pullRequest: nil, waitingOn: nil
        )
    }
}
