import SwiftUI
import SymphonyBarCore

// The Home queue's slot card (TP-1608, `docs/design/prototypes/home-queue/`: `.slot`, `.slot-head`, `.slot-body` and
// `.mslot` in page.css): one card per slot at the top of Home. A one-line header (the status dot, the identifier, the
// title, the epic chip, the time in the slot, then Answer… only when it waits on the person, Message… and Stop), then
// three labelled columns on shared rows, so each row sits level across the card: Status (about half the card: the
// ticket page's stage stepper, the token line, the status pill with its sentence), Plan (its summary on three lines,
// the checks bar, the next open check) and Pull request (its number, size and branch, CI, review). A slot with no
// ticket is an outline reading "Slot N"; folded, a slot is one strip line.

/// What a slot card says about the ticket in its slot.
public struct SlotCardModel: Equatable {
    /// A fact about the pull request (its CI, its review): a status dot and its words.
    public struct Fact: Equatable {
        public var status: DesignTokens.Status
        public var text: String

        public init(_ status: DesignTokens.Status, _ text: String) {
            self.status = status
            self.text = text
        }
    }

    public struct PullRequest: Equatable {
        /// "#1041".
        public var number: String
        /// "38 files · +1,412 −986".
        public var size: String
        /// "auto/TP-1576 into main".
        public var branch: String
        public var ci: Fact
        public var review: Fact

        public init(number: String, size: String, branch: String, ci: Fact, review: Fact) {
            self.number = number
            self.size = size
            self.branch = branch
            self.ci = ci
            self.review = review
        }
    }

    public var identifier: String
    public var title: String
    /// The epic it belongs to, for the chip; nil for a ticket on its own.
    public var epic: String?
    /// Its state: working, waiting on the person, or needing attention.
    public var status: DesignTokens.Status
    /// The stage it is in, from 0 (Coding) to 4 (Done).
    public var stage: Int
    /// "2 h 40 min".
    public var since: String
    /// The status pill's word ("QA", "Waiting on you") and its sentence.
    public var word: String
    public var sentence: String
    public var tokens: [TokenLine.Stage]
    public var tokenTotal: Int
    public var tokenCap: Int?
    public var plan: String
    public var proved: Int
    public var checks: Int
    /// The next open check; nil once every check is proved.
    public var next: String?
    /// Its pull request; nil before one is opened.
    public var pullRequest: PullRequest?

    public init(
        identifier: String, title: String, epic: String? = nil, status: DesignTokens.Status, stage: Int, since: String, word: String,
        sentence: String, tokens: [TokenLine.Stage], tokenTotal: Int, tokenCap: Int?, plan: String, proved: Int, checks: Int,
        next: String?, pullRequest: PullRequest?
    ) {
        self.identifier = identifier
        self.title = title
        self.epic = epic
        self.status = status
        self.stage = stage
        self.since = since
        self.word = word
        self.sentence = sentence
        self.tokens = tokens
        self.tokenTotal = tokenTotal
        self.tokenCap = tokenCap
        self.plan = plan
        self.proved = proved
        self.checks = checks
        self.next = next
        self.pullRequest = pullRequest
    }

    /// The five stages, as the ticket page names them.
    public static let stageNames: [(id: String, name: String)] = [
        ("coding", "Coding"), ("code_review", "Code Review"), ("qa", "QA"), ("merging", "Merging"), ("done", "Done"),
    ]

    /// The current stage's word: "Now" while it works, "Waiting on you", or "Needs attention".
    public var currentWord: String {
        switch status {
        case .you: "Waiting on you"
        case .problem: "Needs attention"
        default: "Now"
        }
    }

    /// The stepper's stages, each with its word alone and no visits or time: Passed before the current stage, the
    /// current one in its status's colour, Not yet after it.
    public var stages: [LifecycleModel.Stage] {
        let current = min(max(stage, 0), Self.stageNames.count - 1)
        let now = (word: currentWord, status: status)
        return Self.stageNames.enumerated().map { index, named in
            let (state, word, tint): (TicketLifecycle.StageState, String, DesignTokens.Status) =
                index < current ? (.passed, "Passed", .done) : index == current ? (.current, now.word, now.status) : (.notYet, "Not yet", .idle)
            return LifecycleModel.Stage(
                id: named.id, title: named.name, state: state, word: word, line: word, status: tint,
                accessibilityLabel: "\(named.name), \(word.lowercased())"
            )
        }
    }

    /// A move on the card.
    public enum Action: String, CaseIterable, Equatable {
        case answer = "Answer…"
        case message = "Message…"
        case stop = "Stop"
    }

    /// The header's moves: Answer… only while it waits on the person, then Message… and Stop.
    public var actions: [Action] { status == .you ? [.answer, .message, .stop] : [.message, .stop] }
}

/// The card of slot `slot` (from 1): its ticket, or an outline reading "Slot N" when it holds none.
public struct SlotCard: View {
    /// The columns' labels, left to right.
    public static let columns = ["Status", "Plan", "Pull request"]

    let slot: Int
    let ticket: SlotCardModel?
    let dropTarget: Bool
    let onAction: (SlotCardModel.Action) -> Void

    /// The card, drawn as the target under a dragged row while `dropTarget` (TP-1610).
    public init(slot: Int, ticket: SlotCardModel?, dropTarget: Bool = false, onAction: @escaping (SlotCardModel.Action) -> Void = { _ in }) {
        self.slot = slot
        self.ticket = ticket
        self.dropTarget = dropTarget
        self.onAction = onAction
    }

    /// "Slot 3".
    public static func emptyLabel(_ slot: Int) -> String { "Slot \(slot)" }

    public var body: some View {
        if let ticket {
            card(ticket)
        } else {
            EmptySlot(
                slot: slot, height: DesignTokens.HomeQueue.emptyHeight, radius: DesignTokens.Radius.card, dropTarget: dropTarget,
                identifier: SlotDropTarget.cardIdentifier(slot)
            )
        }
    }

    /// The ticket page's stepper, with the card's stages: each tile as wide as its own name and word, so the five
    /// stand side by side in the Status column, about half the card.
    static func stepper(_ ticket: SlotCardModel) -> StageStrip { StageStrip(stages: ticket.stages, fit: .content) }

    private func card(_ ticket: SlotCardModel) -> some View {
        let queue = DesignTokens.HomeQueue.self
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        return VStack(alignment: .leading, spacing: queue.cardGap) {
            header(ticket)
            SlotColumns {
                ForEach(Self.columns, id: \.self) { ZoneTitle($0) }
                Self.stepper(ticket)
                Text(ticket.plan)
                    .textStyle(.body)
                    .foregroundStyle(DesignTokens.TextColor.primary.color)
                    .lineLimit(queue.planLines)
                    .fixedSize(horizontal: false, vertical: true)
                pullRequestLines(ticket.pullRequest)
                TokenLine(stages: ticket.tokens, total: ticket.tokenTotal, cap: ticket.tokenCap)
                    .frame(minHeight: queue.lineHeight)
                ChecksBar(proved: ticket.proved, total: ticket.checks)
                    .frame(maxWidth: .infinity, minHeight: queue.lineHeight, alignment: .leading)
                fact(ticket.pullRequest?.ci)
                SlotStatusPill(status: ticket.status, word: ticket.word, sentence: ticket.sentence)
                    .frame(maxWidth: .infinity, alignment: .leading)
                nextCheck(ticket.next)
                fact(ticket.pullRequest?.review)
            }
        }
        .padding(.top, queue.cardTopPadding)
        .padding(.horizontal, queue.cardSidePadding)
        .padding(.bottom, queue.cardBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dropTarget(dropTarget, in: shape)
        .background(DesignTokens.Surface.content.color, in: shape)
        .elevation(queue.cardElevation, in: shape)
        .edgeHighlight(shape)
        .accessibilityElement(children: .contain)
        // A card holds its parts (`.contain`), and such an element's value does not reach the tree: its label says it.
        .accessibilityLabel(Self.accessibilityLabel(slot, ticket: ticket.identifier, dropTarget: dropTarget))
        .dropTargetAccessibility(dropTarget, identifier: SlotDropTarget.cardIdentifier(slot))
    }

    /// The card's label: its slot and its ticket, and, under a dragged row, that it is the drop target (TP-1610).
    public static func accessibilityLabel(_ slot: Int, ticket: String, dropTarget: Bool) -> String {
        SlotDropTarget.accessibilityLabel("\(emptyLabel(slot)): \(ticket)", on: dropTarget)
    }

    private func header(_ ticket: SlotCardModel) -> some View {
        let queue = DesignTokens.HomeQueue.self
        return HStack(spacing: queue.headerGap) {
            StatusDot(ticket.status, live: ticket.status == .working)
            Text(ticket.identifier)
                .textStyle(.rowTitle)
                .monospacedDigit()
                .fixedSize()
                .foregroundStyle(DesignTokens.TextColor.secondary.color)
            Text(ticket.title)
                .textStyle(.heading)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(DesignTokens.TextColor.primary.color)
                .accessibilityAddTraits(.isHeader)
            if let epic = ticket.epic {
                Chip(epic, kind: .epic).padding(.leading, DesignTokens.Space.s1)
            }
            Spacer(minLength: queue.headerSpring)
            Text("\(ticket.since) in the slot")
                .textStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(DesignTokens.TextColor.secondary.color)
                .padding(.trailing, DesignTokens.Space.s2)
            ForEach(ticket.actions, id: \.self) { action in
                actionButton(action)
            }
        }
        .frame(height: queue.headerHeight)
    }

    @ViewBuilder private func actionButton(_ action: SlotCardModel.Action) -> some View {
        switch action {
        case .answer:
            Button(action.rawValue) { onAction(action) }.directorButton(.primary, size: .small).fixedSize()
        case .message:
            Button(action.rawValue) { onAction(action) }.directorButton(.secondary, size: .small).fixedSize()
        case .stop:
            IconButton(DesignTokens.HomeQueue.stopSymbol, help: action.rawValue, size: .small) { onAction(action) }
        }
    }

    @ViewBuilder private func pullRequestLines(_ pullRequest: SlotCardModel.PullRequest?) -> some View {
        let queue = DesignTokens.HomeQueue.self
        if let pullRequest {
            VStack(alignment: .leading, spacing: queue.pullRequestGap) {
                HStack(spacing: DesignTokens.Space.s2) {
                    Image(systemName: queue.pullRequestSymbol)
                        .font(DesignTokens.TypeStyle.font(size: queue.pullRequestGlyph - 2, weight: DesignTokens.TypeStyle.label.weight))
                        .foregroundStyle(DesignTokens.TextColor.secondary.color)
                        .frame(width: queue.pullRequestGlyph, height: queue.pullRequestGlyph)
                        .accessibilityHidden(true)
                    Text("PR \(pullRequest.number)")
                        .textStyle(.rowTitle)
                        .monospacedDigit()
                        .foregroundStyle(DesignTokens.TextColor.primary.color)
                }
                .frame(height: queue.lineHeight)
                secondaryLine(pullRequest.size)
                Text(pullRequest.branch)
                    .textStyle(.mono)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(DesignTokens.TextColor.tertiary.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            secondaryLine("Not opened yet").frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func secondaryLine(_ text: String) -> some View {
        Text(text)
            .textStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(DesignTokens.TextColor.secondary.color)
    }

    @ViewBuilder private func fact(_ fact: SlotCardModel.Fact?) -> some View {
        let queue = DesignTokens.HomeQueue.self
        if let fact {
            HStack(spacing: queue.factGap) {
                StatusDot(fact.status, diameter: queue.factDot, live: fact.status == .working)
                    .padding(.horizontal, DesignTokens.Space.s1)
                secondaryLine(fact.text)
            }
            .frame(maxWidth: .infinity, minHeight: queue.lineHeight, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            Color.clear.frame(height: 0)
        }
    }

    @ViewBuilder private func nextCheck(_ next: String?) -> some View {
        let queue = DesignTokens.HomeQueue.self
        if let next {
            HStack(spacing: queue.nextGap) {
                Text("Next").foregroundStyle(DesignTokens.TextColor.tertiary.color).fixedSize()
                Text(next)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
            }
            .textStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: queue.lineHeight, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            Color.clear.frame(height: 0)
        }
    }
}

/// An empty slot: an outline in the separator colour, reading "Slot N" in the label style, tertiary.
struct EmptySlot: View {
    let slot: Int
    let height: Double
    let radius: Double
    var dropTarget = false
    /// Its identifier in the accessibility tree: the card's or the strip line's.
    var identifier: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Text(SlotCard.emptyLabel(slot))
            .textStyle(.label)
            .foregroundStyle(DesignTokens.TextColor.tertiary.color)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay(shape.strokeBorder(DesignTokens.Surface.separator.color))
            .dropTarget(dropTarget, in: shape)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SlotDropTarget.accessibilityLabel("\(SlotCard.emptyLabel(slot)), empty", on: dropTarget))
            .dropTargetAccessibility(dropTarget, identifier: identifier)
    }
}

/// The status pill: the status's glyph and word in its colour on its tint, then the sentence, cut with an ellipsis.
public struct SlotStatusPill: View {
    let status: DesignTokens.Status
    let word: String
    let sentence: String

    public init(status: DesignTokens.Status, word: String, sentence: String) {
        self.status = status
        self.word = word
        self.sentence = sentence
    }

    public var body: some View {
        let queue = DesignTokens.HomeQueue.self
        HStack(spacing: queue.pillGap) {
            Image(systemName: status.symbol)
                .font(DesignTokens.TypeStyle.font(size: queue.pillGlyph - 1, weight: DesignTokens.TypeStyle.label.weight))
                .foregroundStyle(status.tint)
                .frame(width: queue.pillGlyph, height: queue.pillGlyph)
                .accessibilityHidden(true)
            Text(word)
                .fontWeight(.semibold)
                .foregroundStyle(status.text)
                .fixedSize()
            Text(sentence)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(DesignTokens.TextColor.primary.color)
        }
        .textStyle(.body)
        .padding(.leading, queue.pillLeading)
        .padding(.trailing, queue.pillTrailing)
        .frame(minHeight: queue.pillHeight)
        .background(status.badgeFill, in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(word): \(sentence)")
    }
}

/// The card's three columns on shared rows: the subviews row by row, three to a row, each column `columnShares` of the
/// width, inset inside a hairline separator; each row as tall as its tallest cell, so the rows sit level.
struct SlotColumns<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        SlotColumnsLayout { content }
            .background {
                GeometryReader { proxy in
                    ForEach(Array(SlotColumnsLayout.separators(width: proxy.size.width).enumerated()), id: \.offset) { _, x in
                        Rectangle()
                            .fill(DesignTokens.Surface.separator.color)
                            .frame(width: 1, height: proxy.size.height)
                            .offset(x: x)
                    }
                }
                .accessibilityHidden(true)
            }
    }
}

struct SlotColumnsLayout: Layout {
    var shares = DesignTokens.HomeQueue.columnShares
    var inset = DesignTokens.HomeQueue.columnInset
    var rowGap = DesignTokens.HomeQueue.rowGap
    /// The width it takes when offered none: a laptop's card.
    static let idealWidth: CGFloat = 1100

    /// Each column's content: where it starts and how wide it is, in a body `width` wide.
    static func columns(
        width: CGFloat, shares: [Double] = DesignTokens.HomeQueue.columnShares, inset: Double = DesignTokens.HomeQueue.columnInset
    ) -> [(x: CGFloat, width: CGFloat)] {
        let total = shares.reduce(0, +)
        guard total > 0 else { return [] }
        var start: CGFloat = 0
        return shares.enumerated().map { index, share in
            let span = width * CGFloat(share / total)
            let leading = index == 0 ? 0 : CGFloat(inset)
            let trailing = index == shares.count - 1 ? 0 : CGFloat(inset)
            defer { start += span }
            return (start + leading, max(span - leading - trailing, 0))
        }
    }

    /// Where the hairlines between the columns stand.
    static func separators(width: CGFloat, shares: [Double] = DesignTokens.HomeQueue.columnShares) -> [CGFloat] {
        let total = shares.reduce(0, +)
        guard total > 0 else { return [] }
        var start: CGFloat = 0
        return shares.dropLast().map { share in
            start += width * CGFloat(share / total)
            return start
        }
    }

    private func rowHeights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        let columns = Self.columns(width: width, shares: shares, inset: inset)
        guard !columns.isEmpty else { return [] }
        return stride(from: 0, to: subviews.count, by: columns.count).map { first in
            (0..<columns.count).reduce(CGFloat(0)) { tallest, column in
                let index = first + column
                guard index < subviews.count else { return tallest }
                return max(tallest, subviews[index].sizeThatFits(ProposedViewSize(width: columns[column].width, height: nil)).height)
            }
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Self.idealWidth
        let heights = rowHeights(width: width, subviews: subviews)
        return CGSize(width: width, height: heights.reduce(0, +) + CGFloat(rowGap) * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = Self.columns(width: bounds.width, shares: shares, inset: inset)
        var y = bounds.minY
        for (row, height) in rowHeights(width: bounds.width, subviews: subviews).enumerated() {
            for (column, frame) in columns.enumerated() {
                let index = row * columns.count + column
                guard index < subviews.count else { break }
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + frame.x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: frame.width, height: height)
                )
            }
            y += height + CGFloat(rowGap)
        }
    }
}

/// A slot folded into one line, for the strip that stays on top once the cards scroll away: the status dot, the
/// identifier, the title, the state and the time in the slot, on the queue's columns (`numberWidth` is the queue's
/// number cell, so the identifier stands over the queue's). An empty slot reads "Slot N" inside an outline.
public struct SlotStripLine: View {
    let slot: Int
    let ticket: SlotCardModel?
    let numberWidth: CGFloat
    let state: DesignTokens.Interaction?
    let dropTarget: Bool
    @State private var hovered = false
    /// The queue row's probes: the strip line carries them on the same parts, so a test reads both rows' columns.
    @Environment(\.queueRowProbes) private var probes

    /// The line, drawn as the target under a dragged row while `dropTarget` (TP-1610).
    public init(slot: Int, ticket: SlotCardModel?, numberWidth: CGFloat, state: DesignTokens.Interaction? = nil, dropTarget: Bool = false) {
        self.slot = slot
        self.ticket = ticket
        self.numberWidth = numberWidth
        self.state = state
        self.dropTarget = dropTarget
    }

    /// The line's label: what its parts say (the identifier, the title, the state and the time in the slot), and,
    /// under a dragged row, that it is the drop target (TP-1610).
    public static func accessibilityLabel(_ ticket: SlotCardModel, dropTarget: Bool) -> String {
        SlotDropTarget.accessibilityLabel("\(ticket.identifier), \(ticket.title), \(ticket.word), \(ticket.since)", on: dropTarget)
    }

    public var body: some View {
        let queue = DesignTokens.HomeQueue.self
        if let ticket {
            let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
            let shown = state ?? DesignTokens.Interaction(hovered: hovered)
            // The queue row's own cells and gaps (`QueueRow`), so each column stands over the row's: the number's cell
            // left blank, the lead, the identifier and the title one main gap apart, then the trail, whose last cell
            // (the time here, the repo there) is the row's end cell.
            HStack(spacing: queue.rowPartGap) {
                Color.clear.frame(width: numberWidth, height: 1)
                StatusDot(ticket.status, live: ticket.status == .working)
                    .frame(width: DesignTokens.Row.leadSize, height: DesignTokens.Row.leadSize)
                    .padding(.horizontal, queue.leadMargin)
                    .probe(.lead, probes)
                HStack(spacing: queue.rowMainGap) {
                    Text(ticket.identifier)
                        .textStyle(.rowTitle)
                        .monospacedDigit()
                        .fixedSize()
                        .foregroundStyle(DesignTokens.TextColor.secondary.color)
                        .frame(minWidth: QueueRow.identifierWidth, alignment: .leading)
                        .probe(.identifier, probes)
                    Text(ticket.title)
                        .font(DesignTokens.TypeStyle.font(size: DesignTokens.TypeStyle.rowTitle.size, weight: DesignTokens.Row.titleWeight))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(DesignTokens.TextColor.primary.color)
                        .probe(.title, probes)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: queue.rowMainGap) {
                    Badge(status: ticket.status, word: ticket.word, size: .small)
                        .probe(.marks, probes)
                    Text(ticket.since)
                        .textStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(DesignTokens.TextColor.secondary.color)
                        .probe(.repo, probes)
                        .frame(width: queue.endWidth, alignment: .trailing)
                }
                .fixedSize()
            }
            .padding(.horizontal, queue.rowInset)
            .frame(height: queue.stripHeight)
            .frame(maxWidth: .infinity)
            .background { if !dropTarget, let fill = shown.surface { shape.fill(fill.fill) } }
            .dropTarget(dropTarget, in: shape)
            .contentShape(shape)
            .onHover { hovered = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.accessibilityLabel(ticket, dropTarget: dropTarget))
            .dropTargetAccessibility(dropTarget, identifier: SlotDropTarget.lineIdentifier(slot))
        } else {
            EmptySlot(
                slot: slot, height: queue.stripHeight, radius: DesignTokens.Radius.row, dropTarget: dropTarget,
                identifier: SlotDropTarget.lineIdentifier(slot)
            )
        }
    }
}
