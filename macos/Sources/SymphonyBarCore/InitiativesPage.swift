import Foundation

// Work › Initiatives as designed (TP-1500, `docs/design/director-window-and-home.md` § Work: Initiatives): what the
// epic's card at the left and the picked epic's story at the right say, worked out from the epic read and the story,
// so the page only draws it.

extension Initiative {
    /// One entry of the card's legend: a state that is not done, how many sub-tickets are in it, and its word.
    public struct LegendItem: Equatable, Identifiable {
        /// The state's status; nil for the ones that wait.
        public var status: DesignTokens.Status?
        public var count: Int
        /// "1 working", "22 waiting", "1 waits on you", "1 needs a fix".
        public var text: String
        public var id: String { status?.rawValue ?? "waiting" }
    }

    /// The order the card's legend names the states in: the strip's, past done.
    static let legendOrder: [DesignTokens.Status?] = [.problem, .you, .working, nil]

    /// A sub-ticket's segment of the strip: done, else its situation's status (working breathing, waiting on you,
    /// needing a fix), else waiting.
    static func stripItem(_ ticket: SubTicket) -> DesignTokens.ProgressStrip.Item {
        if ticket.waits == .done { return DesignTokens.ProgressStrip.Item(.done) }
        switch ticket.line.kind.status {
        case .working: return DesignTokens.ProgressStrip.Item(.working, live: true)
        case .idle, .forced, .done: return DesignTokens.ProgressStrip.Item(nil)
        case let status: return DesignTokens.ProgressStrip.Item(status)
        }
    }

    /// The card's strip: one segment per sub-ticket in its order, in its situation's status.
    public var cardStripItems: [DesignTokens.ProgressStrip.Item] { subTickets.map(Self.stripItem) }

    /// The card's legend: only what is not done, "1 working · 22 waiting", in the strip's order.
    public var cardLegend: [LegendItem] {
        let items = cardStripItems.filter { $0.status != .done }
        return Self.legendOrder.compactMap { status in
            let count = items.filter { $0.status == status }.count
            return count == 0 ? nil : LegendItem(status: status, count: count, text: "\(count) \(Self.legendWord(status, count: count))")
        }
    }

    static func legendWord(_ status: DesignTokens.Status?, count: Int) -> String {
        switch status {
        case .problem: count == 1 ? "needs a fix" : "need a fix"
        case .you: count == 1 ? "waits on you" : "wait on you"
        case .working: "working"
        default: "waiting"
        }
    }

    /// A finished epic's line in the legend's place: "Landed Mon 9 Nov", "Landed" without a date; nil for one not
    /// finished.
    public func landedLine(calendar: Calendar = .current) -> String? {
        guard group == .done else { return nil }
        return ["Landed", completedAt.map { InitiativeStory.day($0, calendar: calendar) }].compactMap { $0 }.joined(separator: " ")
    }

    /// What VoiceOver reads for the card: "TP-1381, Phase 3b…, 3 of 26 done, 1 working, 22 waiting".
    public func cardAccessibilityLabel(calendar: Calendar = .current) -> String {
        let after = landedLine(calendar: calendar).map { [$0] } ?? cardLegend.map(\.text)
        return ([identifier, title, progress].compactMap { $0 } + after).joined(separator: ", ")
    }
}

extension InitiativeStory {
    static let canceled = "Canceled"

    /// "Tue 10 Nov", in `calendar`'s time zone.
    static func day(_ date: Date, calendar: Calendar) -> String {
        SharedDateFormatter.string(date, format: "EEE d MMM", timeZone: calendar.timeZone)
    }

    /// A row's trail for its mark: when a landed one landed and its pull request, what the next one starts after,
    /// what another waits for (its situation's word when it waits for no sub-ticket), "Canceled"; nil for one being
    /// worked on.
    static func trail(
        _ mark: Mark, landed: Date?, pullRequest: Int?, waitsFor: String?, line: Situation, calendar: Calendar
    ) -> String? {
        switch mark {
        case .done:
            let when = ["Landed", landed.map { day($0, calendar: calendar) }].compactMap { $0 }.joined(separator: " ")
            return [when, pullRequest.map { "PR #\($0)" }].compactMap { $0 }.joined(separator: " · ")
        case .current:
            return nil
        case .next:
            return waitsFor.map { "Next: starts when \($0) lands" } ?? "Next in line"
        case .open:
            return waitsFor.map { "Waits for \($0)" } ?? line.word
        case .canceled:
            return canceled
        }
    }

    // MARK: - The head

    /// The head's sentence: its count, then where the chain stands, which the page sets softer. "3 of 26 done." and
    /// "TP-1441 is being worked on; 22 wait behind it, in order."
    public struct Sentence: Equatable {
        public var lead: String
        public var rest: String?

        public var text: String { [lead, rest].compactMap { $0 }.joined(separator: " ") }
    }

    /// The sub-tickets that take a place in the chain: every row but the canceled ones.
    var chained: [Row] { rows.filter { $0.mark != .canceled } }

    public var sentence: Sentence {
        let chain = chained
        guard !chain.isEmpty else { return Sentence(lead: "No sub-tickets yet.", rest: nil) }
        let done = chain.filter { $0.mark == .done }.count
        let lead = "\(done) of \(chain.count) done."
        if done == chain.count { return Sentence(lead: lead, rest: "Every sub-ticket landed.") }
        let working = currents.map(\.identifier)
        let waiting = chain.filter { $0.mark == .open || $0.mark == .next }.count
        if !working.isEmpty {
            let names = ListFormatter.localizedString(byJoining: working)
            let verb = working.count == 1 ? "is" : "are"
            return Sentence(lead: lead, rest: "\(names) \(verb) being worked on; " + Self.behind(waiting, working.count == 1 ? "it" : "them"))
        }
        if let next = rows.first(where: { $0.mark == .next }) {
            return Sentence(lead: lead, rest: "\(next.identifier) is next; " + Self.behind(waiting - 1, "it"))
        }
        return Sentence(lead: lead, rest: nil)
    }

    /// "22 wait behind it, in order.", "1 waits behind it.", "nothing waits behind them."
    static func behind(_ count: Int, _ pronoun: String) -> String {
        switch count {
        case 0: "nothing waits behind \(pronoun)."
        case 1: "1 waits behind \(pronoun)."
        default: "\(count) wait behind \(pronoun), in order."
        }
    }

    /// The head's strip: one segment per sub-ticket in chain order, the canceled ones left out.
    public var stripItems: [DesignTokens.ProgressStrip.Item] {
        chained.map { row in
            switch row.mark {
            case .done: DesignTokens.ProgressStrip.Item(.done)
            case .current: DesignTokens.ProgressStrip.Item(.working, live: true)
            default: row.ticket.map(Initiative.stripItem) ?? DesignTokens.ProgressStrip.Item(nil)
            }
        }
    }

    /// The line under the strip: "Started Tue 10 Nov · 2 days so far · 14.6M tokens" while the epic runs, "Started Tue
    /// 3 Nov · ran 4 days · 3.1M tokens" once it landed; a part Symphony did not say is left out, and the line is nil
    /// when every part is.
    public static func note(_ initiative: Initiative, reference: Date, calendar: Calendar = .current) -> String? {
        let started = initiative.startedAt
        let end = initiative.group == .done ? initiative.completedAt : reference
        let length = started.flatMap { start in end.map { Overview.duration(Int($0.timeIntervalSince(start))) } }
        let ran = length.map { initiative.group == .done ? "ran \($0)" : "\($0) so far" }
        let tokens = initiative.tokens.flatMap { $0 > 0 ? Overview.tokens($0) + " tokens" : nil }
        let parts = [started.map { "Started " + day($0, calendar: calendar) }, ran, tokens].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - The fold

    /// How many rows show before the fold: through the second open row after the last one being worked on (after the
    /// next when none is). Nil when the rows past it are fewer than two, so a fold never hides one line behind
    /// another.
    public var foldIndex: Int? {
        let anchor = rows.lastIndex { $0.mark == .current } ?? rows.firstIndex { $0.mark == .next }.map { $0 - 1 }
        guard let anchor else { return nil }
        let shown = min(anchor + 3, rows.count)
        return rows.count - shown >= 2 ? shown : nil
    }

    /// The rows the fold hides, nil when there is no fold.
    public var folded: ArraySlice<Row>? { foldIndex.map { rows[$0...] } }

    /// The folded line: "20 more wait in line, in this order", and the canceled ones it hides as well.
    public var foldLine: String? {
        guard let folded else { return nil }
        let waiting = folded.filter { $0.mark != .canceled }.count
        let canceled = folded.count - waiting
        let more: String? = switch waiting {
        case 0: nil
        case 1: "1 more waits in line"
        default: "\(waiting) more wait in line, in this order"
        }
        return [more, canceled > 0 ? "\(canceled) canceled" : nil].compactMap { $0 }.joined(separator: ", and ")
    }

    /// The unfolded line, which folds them again.
    public static let unfoldedLine = "Show only what is near"
}
