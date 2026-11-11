import Foundation

// The ticket page at laptop width (TP-1448): the catalog's Page layout (`docs/design/director-ticket-page.md` §2 and
// §5) assembled from the components. The header runs across the page; under it the decisions line; then the
// Lifecycle section on top of the Timeline section in the main column, with the facts rail beside them at 340 pt.
// From 1600 pt on (TP-1449) the desktop's: the moves on the identifier's line, the decisions as a 600 pt column on the
// far right, the rail at 440 pt, the main column fluid beside them, up to 1040 pt when nothing waits on the person.

/// The page's sizes at the laptop width (§5): a 1440 × 900 window gives about 1180 pt of content beside the sidebar.
public enum TicketPageLayout {
    /// The laptop window the page is laid out for (the `functional` viewport).
    public static let laptopWindowWidth: Double = 1440
    public static let laptopWindowHeight: Double = 900
    /// The page's margin and the gap between its zones (the catalog's `--space-6`).
    public static let gap: Double = DesignTokens.Space.s6
    /// The facts rail beside the main column, fixed at the laptop width.
    public static let railWidth: Double = 340
    /// Under this width the main column has too little room beside the rail, and the rail goes under it instead.
    public static let mainColumnMinWidth: Double = 460

    /// The width the main column gets in a page `width` wide: what is left beside the rail and the gaps, or the whole
    /// width (less the margins) once the rail goes under it.
    public static func mainColumnWidth(page width: Double) -> Double {
        let inner = max(0, width - 2 * gap)
        return railBeside(page: width) ? inner - gap - railWidth : inner
    }

    /// Whether the rail sits beside the main column in a page `width` wide.
    public static func railBeside(page width: Double) -> Bool {
        width - 2 * gap >= mainColumnMinWidth + gap + railWidth
    }

    /// The page's width in a laptop window, beside the sidebar.
    public static var laptopPageWidth: Double { laptopWindowWidth - DesignTokens.Layout.sidebarWidth }

    // MARK: The desktop width (TP-1449)

    /// The container query (§5, the catalog's breakpoint): from this page width on, the header, the decisions and the
    /// columns take the desktop arrangement; under it the laptop's.
    public static let breakpoint: Double = 1600
    /// A 1440p display gives about 2200 × 1360 pt of content (the `optimize` viewport).
    public static let desktopPageWidth: Double = 2200
    public static let desktopPageHeight: Double = 1360
    /// The facts rail at the desktop width.
    public static let desktopRailWidth: Double = 440
    /// The decisions column on the far right, always open while a Question waits.
    public static let decisionsColumnWidth: Double = DecisionSheetLayout.desktopWidth
    /// The main column's widest when nothing waits on the person: the page's columns are centred instead.
    public static let mainColumnMaxWidth: Double = 1040
    /// The gap between the desktop's columns (the catalog's `--space-8`).
    public static let desktopColumnGap: Double = DesignTokens.Space.s8
    /// The decisions column never gets shorter than this, however small the window.
    public static let decisionsColumnMinHeight: Double = 320

    /// Whether a page `width` wide takes the desktop arrangement.
    public static func isDesktop(page width: Double) -> Bool {
        width >= breakpoint
    }

    /// How a page `width` wide lays its columns out, with the decisions column when `decisions` (a Question waits).
    public struct Arrangement: Equatable {
        public var desktop: Bool
        /// The rail sits beside the main column; false only on a laptop page too narrow for both.
        public var railBeside: Bool
        public var railWidth: Double
        /// The decisions column's width on a desktop while a Question waits; nil when there is none on the page.
        public var decisionsWidth: Double?
        public var mainWidth: Double
        /// The gap between columns.
        public var columnGap: Double
        /// The width the header and the columns span together, centred in the page when narrower than it.
        public var contentWidth: Double
    }

    public static func arrangement(page width: Double, decisions: Bool) -> Arrangement {
        let inner = max(0, width - 2 * gap)
        guard isDesktop(page: width) else {
            let beside = railBeside(page: width)
            return Arrangement(
                desktop: false, railBeside: beside, railWidth: railWidth, decisionsWidth: nil,
                mainWidth: mainColumnWidth(page: width), columnGap: gap, contentWidth: inner
            )
        }
        let columnGap = desktopColumnGap
        if decisions {
            return Arrangement(
                desktop: true, railBeside: true, railWidth: desktopRailWidth, decisionsWidth: decisionsColumnWidth,
                mainWidth: inner - 2 * columnGap - desktopRailWidth - decisionsColumnWidth, columnGap: columnGap, contentWidth: inner
            )
        }
        let main = min(mainColumnMaxWidth, inner - columnGap - desktopRailWidth)
        return Arrangement(
            desktop: true, railBeside: true, railWidth: desktopRailWidth, decisionsWidth: nil,
            mainWidth: main, columnGap: columnGap, contentWidth: main + columnGap + desktopRailWidth
        )
    }

    // MARK: Sticky columns (§5, Scrolling)

    /// How far down a sticky column moves inside its row so it stays in view as the page scrolls. The page has scrolled
    /// `scroll` in a `viewport` tall; the row starts at `top` in the page and is `room` tall; the column is `height`
    /// tall. A column shorter than the window sticks `inset` under the window's top; a taller one scrolls with the page
    /// until its foot is `inset` above the window's bottom, and stays there. It never leaves its row.
    public static func stickyOffset(scroll: Double, viewport: Double, top: Double, height: Double, room: Double, inset: Double = gap) -> Double {
        let underTop = scroll + inset - top
        let footInView = scroll + viewport - inset - top - height
        return max(0, min(underTop, footInView, room - height))
    }

    /// The desktop's decisions column in the window: how far down its row it moves and how tall it is, so its header
    /// and Send are always in view. Its top follows the row until the row reaches `inset` under the window's top, then
    /// stays there; its foot stays `inset` above the window's bottom.
    public static func decisionsColumn(scroll: Double, viewport: Double, top: Double, room: Double, inset: Double = gap) -> (offset: Double, height: Double) {
        let screenTop = max(inset, top - scroll)
        let height = max(decisionsColumnMinHeight, viewport - inset - screenTop)
        let offset = max(0, min(scroll + screenTop - top, room - height))
        return (offset, height)
    }

    /// The room the decisions column keeps in its row on a page that doesn't scroll yet: its height before the page
    /// scrolls, so a short page still holds it without growing as it scrolls.
    public static func decisionsColumnRoom(viewport: Double, top: Double, inset: Double = gap) -> Double {
        decisionsColumn(scroll: 0, viewport: viewport, top: top, room: .infinity, inset: inset).height
    }
}

/// The decisions line under the ticket page's header (§2, question 1): "A question waits on you" with the first
/// Question's title and Answer, which opens the decision sheet; or one quiet line saying nothing needs you, in the
/// same place and the same height, so the page never jumps when a Question comes or goes.
public struct DecisionsLine: Equatable {
    /// How many Questions wait on the person.
    public var count: Int
    public var title: String
    /// The first open Question's title, or what the quiet line says under its title.
    public var detail: String
    /// Why Answer can't open the sheet yet (the Questions' options are read from the Inbox); nil when it can.
    public var answerReason: String?

    public static let quietTitle = "Nothing needs you"
    public static let quietDetail = "No question waits on your answer on this ticket."
    public static let answerTitle = "Answer…"
    /// Answer's reason while Symphony says a Question is open and the Inbox holds none of it yet.
    public static let readingReason = "Reading the question from the Inbox…"
    /// The decision sheet's Send until answering from the ticket page lands: the Inbox answers it meanwhile.
    public static let sendLaterReason = "Answer it in the Inbox for now: sending from the ticket page comes next."

    /// The line from the ticket's open Questions as Symphony names them (`open_questions`) and the ones the Inbox
    /// holds with their options (`questions`); either may lag the other, so the larger count is the one shown.
    public init(openQuestions: [String], questions: [InboxReview.Action]) {
        count = max(openQuestions.count, questions.count)
        guard count > 0 else {
            title = Self.quietTitle
            detail = Self.quietDetail
            answerReason = nil
            return
        }
        title = count == 1 ? "A question waits on you" : "\(count) questions wait on you"
        detail = questions.lazy.compactMap { $0.title ?? $0.question }.first ?? openQuestions.first ?? ""
        answerReason = questions.isEmpty ? Self.readingReason : nil
    }

    /// True while a Question waits: the line takes the Waiting on you tint and offers Answer.
    public var waiting: Bool { count > 0 }

    /// What VoiceOver reads for the line.
    public var accessibilityLabel: String {
        waiting ? "\(title): \(detail)" : title
    }
}

extension TicketPage {
    /// The open Questions of ticket `identifier` the Inbox holds, each with its options, in the Inbox's order.
    public static func questions(of identifier: String, in items: [InboxItem]) -> [InboxReview.Action] {
        items.filter { $0.identifier == identifier && $0.isDecision }.compactMap(\.review.action)
    }

    /// The header's title: the state's, else the ticket read's.
    public var headerTitle: String? {
        title ?? detailsRead?.ticket?.title
    }

    /// The header's epic chip: the epic the ticket read connects it to, else the plan the state's lanes name.
    public var epicChip: String? {
        if let epic = factsRead?.connected?.epic {
            return [epic.identifier, epic.title].compactMap { $0 }.joined(separator: " ")
        }
        return initiative
    }

    /// The decision sheet's subtitle: "TP-1245 · The paused line's times".
    public var sheetSubtitle: String {
        [identifier, headerTitle].compactMap { $0 }.joined(separator: " · ")
    }

    /// The Move to… sheet for the phase `state` the Action rail names, from the state's phases; nil for a phase the
    /// state doesn't list or the one the ticket is in.
    public func moveSheet(to state: String) -> MoveSheet? {
        guard let entry = moveMenu?.entries.first(where: { $0.name.caseInsensitiveCompare(state) == .orderedSame }) else { return nil }
        return moveMenu?.sheet(for: entry)
    }
}
