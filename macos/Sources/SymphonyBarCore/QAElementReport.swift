import Foundation

/// QA mode's element report (TP-1677): the named elements on screen, each with its stable name, its frame and the
/// frames of its named parts, and the state the app holds exactly (the page shown, the ticket open, which named
/// elements are selected or focused). QA's driver reads it (`qa_elements`, `qa_scroll_to`, `qa_measure_elements`,
/// `qa_wait_check`), so a QA session takes names, sizes and alignments from the app, not from pictures. Frames are in
/// screen points from the top left of the main display, as the accessibility tree's frames and `qa_click`'s points are.
///
/// Only a QA-mode launch writes it: `QAMode.elementsReport(pid:)`, rewritten atomically after each change. A normal
/// launch records no frames and writes nothing.
public struct QAElementReport: Codable, Equatable, Sendable {
    /// The version of the report's shape; the driver reads version 1.
    public static let version = 1

    /// A rectangle in screen points, from the top left of the main display.
    public struct Rect: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var w: Double
        public var h: Double

        public init(x: Double, y: Double, w: Double, h: Double) {
            self.x = Self.rounded(x)
            self.y = Self.rounded(y)
            self.w = Self.rounded(w)
            self.h = Self.rounded(h)
        }

        /// To a hundredth of a point: enough for any alignment, short in the file.
        static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }
    }

    /// A named element: its frame, whether any of it shows (in its window and not scrolled out), whether all of it
    /// shows, the part of it that shows, and its parts. Two views with the same name are told apart by their place:
    /// the first from the top left keeps the name, the next ones take `#2`, `#3` (`queue-row-TP-1#2`).
    public struct Element: Codable, Equatable, Sendable {
        public var name: String
        public var frame: Rect
        public var visible: Bool
        /// All of it shows: no edge is cut by the scroll area or the window that holds it.
        public var fullyVisible: Bool
        /// The part of `frame` that shows, nil when none does.
        public var shown: Rect?
        /// The window it is in, by `Window.number`.
        public var window: Int?
        public var selected: Bool
        public var focused: Bool
        /// The frames of its named parts (a row's `identifier`, `title`), by part name.
        public var parts: [String: Rect]

        public init(
            name: String, frame: Rect, visible: Bool, fullyVisible: Bool? = nil, shown: Rect? = nil, window: Int?, selected: Bool,
            focused: Bool, parts: [String: Rect]
        ) {
            self.name = name
            self.frame = frame
            self.visible = visible
            self.fullyVisible = fullyVisible ?? visible
            self.shown = shown ?? (visible ? frame : nil)
            self.window = window
            self.selected = selected
            self.focused = focused
            self.parts = parts
        }
    }

    /// A window that holds named elements.
    public struct Window: Codable, Equatable, Sendable {
        public var number: Int
        public var title: String
        public var frame: Rect
        public var key: Bool

        public init(number: Int, title: String, frame: Rect, key: Bool) {
            self.number = number
            self.title = title
            self.frame = frame
            self.key = key
        }
    }

    /// What the app holds exactly and QA used to judge by eye.
    public struct State: Codable, Equatable, Sendable {
        /// The window's page by its name (`overview`), nil before the window opened.
        public var page: String?
        /// The page's title as the sidebar says it (`Home`).
        public var pageTitle: String?
        /// The ticket whose page is open over the page, nil for none.
        public var ticket: String?
        /// The named elements drawn selected, and those holding the keyboard focus.
        public var selected: [String]
        public var focused: [String]

        public init(page: String? = nil, pageTitle: String? = nil, ticket: String? = nil, selected: [String] = [], focused: [String] = []) {
            self.page = page
            self.pageTitle = pageTitle
            self.ticket = ticket
            self.selected = selected
            self.focused = focused
        }
    }

    public var version: Int
    /// When the app wrote it, ISO 8601.
    public var at: String
    public var pid: Int32
    public var windows: [Window]
    public var state: State
    public var elements: [Element]
    /// The naming scheme, so a session reads the names without searching the code.
    public var names: [QAElementNames.Entry]

    public init(at: Date, pid: Int32, windows: [Window], state: State, elements: [Element], names: [QAElementNames.Entry] = QAElementNames.scheme) {
        version = Self.version
        self.at = ISO8601DateFormatter().string(from: at)
        self.pid = pid
        self.windows = windows
        self.state = state
        self.elements = elements
        self.names = names
    }

    /// The report as the file holds it: snake_case keys, sorted.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decoded(_ data: Data) throws -> QAElementReport {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(QAElementReport.self, from: data)
    }
}

/// The stable names QA walks the Director by, in one place: each view takes its name from here, and the report lists
/// the scheme, so the playbook and a QA session read the names without searching the code. A name is also the
/// element's accessibility identifier.
public enum QAElementNames {
    /// One name or pattern of the scheme and what it names. `<ticket>` is a ticket identifier (`TP-12`), `<slot>` a
    /// slot's number from 1, `<n>` a place from 1, `<title>`, `<label>`, `<id>` and `<column>` a title, a label, an id
    /// or a column's id in lower case with dashes.
    public struct Entry: Codable, Equatable, Sendable {
        public var pattern: String
        public var what: String
        public var parts: [String]

        public init(_ pattern: String, _ what: String, parts: [String] = []) {
            self.pattern = pattern
            self.what = what
            self.parts = parts
        }
    }

    public static func queueRow(_ ticket: String) -> String { "queue-row-\(ticket)" }
    public static func doneRow(_ ticket: String) -> String { "done-row-\(ticket)" }
    public static let queueDropLine = "queue-drop-line"
    public static let queueDoneCount = "queue-done-count"
    public static let recentlyDoneHead = "recently-done-head"
    public static let recentlyDoneRange = "recently-done-range"
    public static func slotCard(_ slot: Int) -> String { "slot-card-\(slot)" }
    public static func slotLine(_ slot: Int) -> String { "slot-line-\(slot)" }
    public static func epicSlotCard(_ slot: Int) -> String { "epic-slot-card-\(slot)" }
    public static func epicSlotBand(_ slot: Int) -> String { "epic-slot-band-\(slot)" }
    public static func epicSlotDoneCount(_ slot: Int) -> String { "epic-slot-done-count-\(slot)" }
    public static func epicSlotUpcoming(_ slot: Int) -> String { "epic-slot-upcoming-\(slot)" }
    public static func epicSlotDone(_ slot: Int) -> String { "epic-slot-done-\(slot)" }
    /// A row of the window's sidebar by its title, in lower case with dashes: `sidebar-home`, `sidebar-work`.
    public static func sidebar(_ title: String) -> String { "sidebar-" + slug(title) }
    /// A row of a page's own section list (Settings' sections) by its title: `section-notifications`.
    public static func section(_ title: String) -> String { "section-" + slug(title) }

    // The Inbox (Home's drawer).
    public static let inboxDrawer = "inbox-drawer"
    public static func inboxReview(_ ticket: String) -> String { "inbox-review-\(ticket)" }
    public static func inboxAction(_ title: String) -> String { "inbox-action-" + slug(title) }
    /// A Question block (a decision to answer) by its place from 1, in the Inbox, on the ticket page or the Journal.
    public static func decision(_ number: Int) -> String { "decision-\(number)" }

    // The ticket page.
    public static let ticketHead = "ticket-head"
    public static let ticketDecisionsLine = "ticket-decisions-line"
    public static let ticketDecisions = "ticket-decisions"
    public static let ticketPlan = "ticket-plan"
    public static let ticketBrief = "ticket-brief"
    public static let ticketLifecycle = "ticket-lifecycle"
    public static let ticketTimeline = "ticket-timeline"
    public static let ticketPullRequest = "ticket-pull-request"
    public static let ticketConnected = "ticket-connected"
    public static let ticketDecided = "ticket-decided"
    /// A run's step on the ticket page by its title: `step-write-the-code`.
    public static func step(_ title: String) -> String { "step-" + slug(title) }

    // Work › Tickets, Initiatives, Providers, Settings.
    public static func ticketsRow(_ ticket: String) -> String { "tickets-row-\(ticket)" }
    public static func initiativeCard(_ ticket: String) -> String { "initiative-card-\(ticket)" }
    public static let initiativeHead = "initiative-head"
    public static func initiativeRow(_ ticket: String) -> String { "initiative-row-\(ticket)" }
    public static func providerCard(_ id: String) -> String { "provider-card-" + slug(id) }
    public static let providerHead = "provider-head"
    public static func settingsGroup(_ title: String) -> String { "settings-group-" + slug(title) }
    public static func settingsRow(_ label: String) -> String { "settings-row-" + slug(label) }

    /// `title` in lower case, its words joined by dashes: "Runs & Fallbacks" is `runs-fallbacks`.
    public static func slug(_ title: String) -> String {
        title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
    }

    /// The queue row's parts, as `QueueRow.Part` names them.
    public static let queueRowParts = ["number", "handle", "elbow", "lead", "identifier", "title", "doneCount", "dependencies", "marks", "repo", "start"]
    public static let doneRowParts = ["identifier", "title"]

    /// Every name and pattern, with what it names and its parts.
    public static let scheme: [Entry] = [
        Entry("queue-row-<ticket>", "A row of Home's queue, by its ticket", parts: queueRowParts),
        Entry("done-row-<ticket>", "A row of Home's Recently done list, by its ticket", parts: doneRowParts),
        Entry(queueDropLine, "The line a dragged queue row would land on"),
        Entry(queueDoneCount, "An epic row's done count, which shows or hides its done sub-tickets"),
        Entry(recentlyDoneHead, "The Recently done list's head, which folds it"),
        Entry(recentlyDoneRange, "The Recently done list's range control"),
        Entry("slot-card-<slot>", "A running slot's card on Home", parts: ["lead", "identifier", "title", "marks"]),
        Entry("slot-line-<slot>", "A running slot's line in the slot strip", parts: ["lead", "identifier", "title", "marks"]),
        Entry("epic-slot-card-<slot>", "An epic's running slot card"),
        Entry("epic-slot-band-<slot>", "An epic slot card's band"),
        Entry("epic-slot-done-count-<slot>", "An epic slot card's done count"),
        Entry("epic-slot-upcoming-<slot>", "An epic slot card's upcoming sub-tickets"),
        Entry("epic-slot-done-<slot>", "An epic slot card's done sub-tickets"),
        Entry("sidebar-<title>", "A row of the window's sidebar by its title, such as sidebar-home; selected while it is current"),
        Entry("section-<title>", "A row of a page's section list (Settings' sections) by its title; selected while it is current"),
        Entry(inboxDrawer, "The Inbox drawer beside Home", parts: ["title", "close"]),
        Entry("inbox-review-<ticket>", "The Inbox item the drawer shows, by its ticket", parts: ["header", "badges", "title", "actions"]),
        Entry("inbox-action-<title>", "One of the Inbox item's action buttons by its title, such as inbox-action-send-decision"),
        Entry(
            "decision-<n>", "A decision to answer (a Question block) by its place from 1, in the Inbox, the ticket page or the Journal",
            parts: ["question", "story", "options", "option-<n>", "write-in", "send"]
        ),
        Entry(
            ticketHead, "The ticket page's head",
            parts: ["identifier", "repo", "epic", "priority", "label-<title>", "title", "situation", "moves"]
        ),
        Entry(ticketDecisionsLine, "The ticket page's decisions line (A question waits on you, Answer)"),
        Entry(ticketDecisions, "The ticket page's decisions column beside the page"),
        Entry(ticketPlan, "The ticket page's plan panel"),
        Entry(ticketBrief, "The ticket page's brief panel"),
        Entry(ticketLifecycle, "The ticket page's Lifecycle section"),
        Entry(ticketTimeline, "The ticket page's timeline, its ledger of runs and events", parts: ["title", "composer"]),
        Entry("step-<title>", "A run's step on the ticket page by its title, such as step-write-the-code", parts: ["head"]),
        Entry(ticketPullRequest, "The ticket page's Pull request panel"),
        Entry(ticketConnected, "The ticket page's Connected panel: its epic, sub-tickets and blockers", parts: ["epic", "sub-tickets", "waiting-on", "holding-up"]),
        Entry(ticketDecided, "The ticket page's Decisions panel: what the person answered"),
        Entry("tickets-row-<ticket>", "A row of Work › Tickets' table by its ticket; selected while picked", parts: ["<column>"]),
        Entry("initiative-card-<ticket>", "An epic's card on Initiatives; selected while picked", parts: ["identifier", "progress", "title", "strip"]),
        Entry(initiativeHead, "The picked epic's story head on Initiatives"),
        Entry("initiative-row-<ticket>", "A sub-ticket's row in the picked epic's story", parts: ["number", "mark", "identifier", "title", "trail"]),
        Entry("provider-card-<id>", "A provider's card on Providers; selected while picked"),
        Entry(providerHead, "The picked provider's head", parts: ["id", "move", "name", "situation"]),
        Entry("settings-group-<title>", "A group of settings by its title"),
        Entry("settings-row-<label>", "One setting's row by its label", parts: ["label", "line", "control"]),
    ]
}

extension QAMode {
    /// The folder under the QA root the app writes its element report into, one file per process.
    public static let elementsFolder = "elements"

    /// The element report of the app with `pid`: `<QA root>/elements/<pid>.json`.
    public func elementsReport(pid: Int32) -> URL {
        root.appendingPathComponent(Self.elementsFolder, isDirectory: true).appendingPathComponent("\(pid).json")
    }
}

/// Writes the element report a moment after the last change (`delay`), atomically, so a burst of layout changes (a
/// scroll, an animation) writes once and the driver never reads half a file.
public final class QAElementReportWriter {
    public let file: URL
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private var pending: DispatchWorkItem?

    public init(file: URL, delay: TimeInterval = 0.15, queue: DispatchQueue = .main) {
        self.file = file
        self.delay = delay
        self.queue = queue
    }

    /// Asks for a write: `build` runs on the writer's queue once no other request came for `delay`.
    public func schedule(_ build: @escaping () -> QAElementReport) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                try self.write(build())
            } catch {
                NSLog("Symphony QA: couldn't write \(self.file.path): \(error.localizedDescription)")
            }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    public func write(_ report: QAElementReport) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeReplacing(file, with: report.encoded(), permissions: 0o644)
    }
}
