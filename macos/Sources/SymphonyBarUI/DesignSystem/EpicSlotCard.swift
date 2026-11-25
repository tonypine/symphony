import SwiftUI
import SymphonyBarCore

// The Home queue's epic slot card (TP-1646, `docs/design/prototypes/home-queue/` part "An epic slot card",
// `.eslot`, `.epic-band`, `.b-done`, `.dlist` and `.ulist` in page.css, `shots/epic-card-*-2x.png`): when the ticket in
// a slot is a sub-ticket, its epic wraps the card. The frame stands 4 pt around the ordinary slot card at the left,
// right and bottom, on half the card's surface with a separator edge. Above the card, the band: a chevron, the epic's
// flag, its identifier and title, then the progress bar with "7 of 14 done" as one button, and the time the epic has
// held the slot. The band opens what is still to come below the card (the epic's open sub-tickets as queue rows,
// numbered on from the done count, with Start and drag and drop among them); the done count opens what is done above
// the card (done rows with the pull request and when, oldest at the top). The two are independent; each list shows six
// rows and scrolls inside itself, the done list from its most recent rows. The band's rows share one set of columns:
// the number cell under the band's chevron, the lead under its flag, the identifier under its identifier.

/// What an epic slot card says about its epic.
public struct EpicSlotCardModel: Equatable {
    public var identifier: String
    public var title: String
    /// Its sub-tickets done and in all.
    public var done: Int
    public var total: Int
    /// How long the epic has held the slot: "3 d".
    public var since: String
    /// Its done sub-tickets, oldest first, as done rows with the pull request and when.
    public var doneRows: [DoneRowModel]
    /// Its open sub-tickets but the one in work, in queue order, numbered on from the done count.
    public var upcoming: [QueueRowModel]

    public init(
        identifier: String, title: String, done: Int, total: Int, since: String, doneRows: [DoneRowModel] = [], upcoming: [QueueRowModel] = []
    ) {
        self.identifier = identifier
        self.title = title
        self.done = done
        self.total = total
        self.since = since
        self.doneRows = doneRows
        self.upcoming = upcoming
    }

    /// "7 of 14 done".
    public var doneText: String { DesignTokens.HomeQueue.doneCount(done: done, total: total) }

    /// The share done, from 0 to 1.
    public var fraction: Double { DesignTokens.HomeQueue.checksFraction(proved: done, total: total) }

    /// "3 d in the slot".
    public var sinceText: String { "\(since) in the slot" }

    /// The epic's time in the slot in the band's short form (README "An epic slot card": "3 d in the slot"): whole days
    /// as "3 d", under a day as the design system's durations ("1 h 5 min", "14 min", "14 s"). Home and the Gallery
    /// both write it here, so the two cannot drift.
    public static func slotTime(_ seconds: Int) -> String {
        let seconds = max(seconds, 0)
        return seconds < 86_400 ? Overview.duration(seconds) : "\(seconds / 86_400) d"
    }

    /// The widest number the card's rows show: the last to come, or the one in work's.
    public var widestNumber: Int { max(done + 1 + upcoming.count, 1) }
}

public struct EpicSlotCard: View {
    let slot: Int
    let epic: EpicSlotCardModel
    let ticket: SlotCardModel
    let showsUpcoming: Bool
    let showsDone: Bool
    let dropTarget: Bool
    let doneHovered: Bool?
    let hoveredRow: Int?
    let onAction: (SlotCardModel.Action) -> Void
    let onToggleUpcoming: () -> Void
    let onToggleDone: () -> Void
    let onStart: (String) -> Void
    let onMove: (Int, Int) -> Void
    let onOpen: ((String) -> Void)?

    @Environment(\.offscreenSnapshot) private var offscreenSnapshot
    @State private var donePointer = false
    @State private var drag: Drag?

    /// The card of slot `slot` held by `epic`, around the slot card of `ticket`, the sub-ticket in work. `showsUpcoming`
    /// and `showsDone` open the two lists; `doneHovered` and `hoveredRow` (an index of what is to come) draw the done
    /// count's and a row's hover still, for a story; nil follows the pointer. The band calls `onToggleUpcoming`, the done
    /// count `onToggleDone`, Start on a row to come `onStart` with its identifier, and a drop in that list `onMove` with
    /// the row's index and the gap it landed in. A click on a title calls `onOpen` with its ticket (TP-1647): the epic's
    /// title in the band opens the epic, the card's the sub-ticket in work, and each row's its own ticket; the rest of the
    /// band still opens what is to come.
    public init(
        slot: Int, epic: EpicSlotCardModel, ticket: SlotCardModel, showsUpcoming: Bool = false, showsDone: Bool = false,
        dropTarget: Bool = false, doneHovered: Bool? = nil, hoveredRow: Int? = nil,
        onAction: @escaping (SlotCardModel.Action) -> Void = { _ in }, onToggleUpcoming: @escaping () -> Void = {},
        onToggleDone: @escaping () -> Void = {}, onStart: @escaping (String) -> Void = { _ in },
        onMove: @escaping (Int, Int) -> Void = { _, _ in }, onOpen: ((String) -> Void)? = nil
    ) {
        self.slot = slot
        self.epic = epic
        self.ticket = ticket
        self.showsUpcoming = showsUpcoming
        self.showsDone = showsDone
        self.dropTarget = dropTarget
        self.doneHovered = doneHovered
        self.hoveredRow = hoveredRow
        self.onAction = onAction
        self.onToggleUpcoming = onToggleUpcoming
        self.onToggleDone = onToggleDone
        self.onStart = onStart
        self.onMove = onMove
        self.onOpen = onOpen
    }

    /// A row to come being dragged: its index, the pointer's height in the list, and how far below the row's top the
    /// pointer took it.
    struct Drag: Equatable {
        var index: Int
        var y: Double
        var grab: Double
    }

    /// A list's height for `rows` rows: at most six on the queue's pitch (216 pt), the rest scrolled inside it.
    public static func listHeight(rows: Int) -> Double {
        Double(min(max(rows, 0), DesignTokens.HomeQueue.epicListRows)) * HomeQueuePager.pitch
    }

    /// Where the done list opens: at its end, its most recent rows next to the card.
    public static let doneAnchor = UnitPoint.bottom

    /// The done rows an offscreen snapshot draws, where no scroll view draws: the six the live list opens at, its most
    /// recent, oldest at the top.
    public static func doneShown<Row>(_ rows: [Row]) -> ArraySlice<Row> { rows.suffix(DesignTokens.HomeQueue.epicListRows) }

    /// The rows to come an offscreen snapshot draws: the first six, as the live list opens.
    public static func upcomingShown<Row>(_ rows: [Row]) -> ArraySlice<Row> { rows.prefix(DesignTokens.HomeQueue.epicListRows) }

    /// Whether the done count stands lifted, on the pressed surface: while its list shows, and under the pointer.
    public static func doneLifted(showing: Bool, hovered: Bool) -> Bool { showing || hovered }

    /// The gap a drag in a list of `count` rows lands in for the pointer at `y` below the list's top; nil when it would
    /// leave the row at `from` where it is.
    public static func gap(y: Double, from: Int, count: Int) -> Int? {
        let gap = HomeQueueDrag.gap(y: y, count: count)
        return gap == from || gap == from + 1 ? nil : gap
    }

    /// The card's label: its slot, its epic and the sub-ticket in work.
    public static func accessibilityLabel(_ slot: Int, epic: EpicSlotCardModel, ticket: String) -> String {
        "\(SlotCard.emptyLabel(slot)): \(epic.identifier), \(epic.doneText), \(ticket) in work"
    }

    /// The band as VoiceOver reads it.
    public static func bandLabel(_ epic: EpicSlotCardModel) -> String {
        "\(epic.identifier), \(epic.title), \(epic.sinceText)"
    }

    /// The band's action, as VoiceOver names it.
    public static func upcomingTitle(open: Bool) -> String { open ? "Hide what is to come" : "Show what is to come" }

    /// The identifiers a window test finds the parts by.
    public static func identifier(_ slot: Int) -> String { QAElementNames.epicSlotCard(slot) }
    public static func bandIdentifier(_ slot: Int) -> String { QAElementNames.epicSlotBand(slot) }
    public static func doneCountIdentifier(_ slot: Int) -> String { QAElementNames.epicSlotDoneCount(slot) }
    public static func upcomingIdentifier(_ slot: Int) -> String { QAElementNames.epicSlotUpcoming(slot) }
    public static func doneListIdentifier(_ slot: Int) -> String { QAElementNames.epicSlotDone(slot) }

    public var body: some View {
        let queue = DesignTokens.HomeQueue.self
        let shape = RoundedRectangle(cornerRadius: queue.epicFrameRadius, style: .continuous)
        let numberWidth = QueueRow.numberWidth(widest: epic.widestNumber)
        VStack(spacing: 0) {
            band(numberWidth: numberWidth)
            if showsDone, !epic.doneRows.isEmpty {
                doneList(numberWidth: numberWidth)
                    .padding(.bottom, queue.epicFrameInset)
            }
            SlotCard(slot: slot, ticket: ticket, dropTarget: dropTarget, inEpic: true, onAction: onAction, onOpen: onOpen)
            if showsUpcoming, !epic.upcoming.isEmpty {
                upcomingList(numberWidth: numberWidth)
                    .padding(.top, queue.epicFrameInset)
            }
        }
        .padding(.horizontal, queue.epicFrameInset)
        .padding(.bottom, queue.epicFrameInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Surface.content.color.opacity(queue.epicFrameOpacity), in: shape)
        .overlay(shape.strokeBorder(DesignTokens.Surface.separator.color, lineWidth: queue.epicFrameStroke).allowsHitTesting(false))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilityLabel(slot, epic: epic, ticket: ticket.identifier))
        .qaName(Self.identifier(slot))
    }

    // MARK: - The band

    private func band(numberWidth: CGFloat) -> some View {
        let queue = DesignTokens.HomeQueue.self
        return HStack(spacing: queue.rowPartGap) {
            HStack(spacing: queue.rowPartGap) {
                Image(systemName: QueueEpicChevron.symbol(open: showsUpcoming))
                    .font(DesignTokens.TypeStyle.font(size: queue.chevronGlyph, weight: DesignTokens.TypeStyle.label.weight))
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .frame(width: numberWidth, height: queue.numberHeight)
                Image(systemName: queue.epicFlagSymbol)
                    .font(DesignTokens.TypeStyle.font(size: DesignTokens.Row.leadGlyph, weight: DesignTokens.TypeStyle.label.weight))
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .frame(width: DesignTokens.Row.leadSize, height: DesignTokens.Row.leadSize)
                    .padding(.horizontal, queue.leadMargin)
                HStack(spacing: queue.rowMainGap) {
                    Text(epic.identifier)
                        .textStyle(.rowTitle)
                        .monospacedDigit()
                        .fixedSize()
                        .foregroundStyle(DesignTokens.TextColor.secondary.color)
                        .frame(minWidth: QueueRow.identifierWidth, alignment: .leading)
                    Text(epic.title)
                        .font(DesignTokens.TypeStyle.font(size: DesignTokens.TypeStyle.rowTitle.size, weight: DesignTokens.Row.titleWeight))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(DesignTokens.TextColor.primary.color)
                        // The title's own click wins over the band's: it opens the epic, the rest of the band its list.
                        .titleLink(epic.identifier, open: onOpen)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.bandLabel(epic))
            .accessibilityValue(showsUpcoming ? "Open" : "Closed")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text(Self.upcomingTitle(open: showsUpcoming)), onToggleUpcoming)
            .accessibilityAction { onToggleUpcoming() }
            .openTicketAction(epic.identifier, open: onOpen)
            .qaName(Self.bandIdentifier(slot))
            doneCount
            Text(epic.sinceText)
                .textStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(DesignTokens.TextColor.secondary.color)
                .padding(.leading, queue.epicSinceGap)
        }
        .padding(.leading, queue.rowInset)
        .padding(.trailing, queue.rowInset + queue.epicRowEnd)
        .frame(height: queue.epicBandHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleUpcoming)
        .accessibilityElement(children: .contain)
    }

    /// The bar with "7 of 14 done", one button with a pressed state: it opens and closes what is done, and only that.
    private var doneCount: some View {
        let queue = DesignTokens.HomeQueue.self
        let shape = RoundedRectangle(cornerRadius: queue.epicDoneRadius, style: .continuous)
        let lifted = Self.doneLifted(showing: showsDone, hovered: doneHovered ?? donePointer)
        return HStack(spacing: queue.checksGap) {
            DoneTrack(fraction: epic.fraction, track: (lifted ? DesignTokens.Surface.strong : DesignTokens.StateSurface.pressed.color).color)
                .frame(width: queue.epicBarWidth)
            Text(epic.doneText)
                .textStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle((lifted ? DesignTokens.TextColor.primary : DesignTokens.TextColor.secondary).color)
        }
        .padding(.horizontal, queue.epicDoneInsetX)
        .frame(height: queue.epicDoneHeight)
        .background { if lifted { shape.fill(DesignTokens.StateSurface.pressed.fill) } }
        .padding(.horizontal, -queue.epicDoneInsetX)
        .contentShape(shape)
        .onHover { donePointer = $0 }
        .buttonPointer()
        // The count's own click: it does not reach the band's.
        .onTapGesture(perform: onToggleDone)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(epic.doneText)
        .accessibilityValue(showsDone ? "Shown" : "Hidden")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onToggleDone() }
        .qaName(Self.doneCountIdentifier(slot))
    }

    // MARK: - The lists

    /// What is done, above the card: done rows with the pull request and when, oldest at the top, opened at the end.
    private func doneList(numberWidth: CGFloat) -> some View {
        let queue = DesignTokens.HomeQueue.self
        let rows = VStack(spacing: queue.doneRowGap) {
            ForEach(offscreenSnapshot ? Array(Self.doneShown(epic.doneRows)) : epic.doneRows) { row in
                DoneRow(
                    row, cells: .slotCard, nesting: DoneRow.Nesting(numberCell: numberWidth, depth: 0, end: queue.epicRowEnd), onOpen: onOpen
                )
            }
        }
        return Group {
            // `ImageRenderer` draws no scroll view's content: a snapshot draws the rows the live list opens at.
            if offscreenSnapshot {
                rows.frame(maxHeight: .infinity, alignment: .bottom).clipped()
            } else {
                ScrollView(.vertical) { rows }.defaultScrollAnchor(Self.doneAnchor)
            }
        }
        .frame(height: Self.listHeight(rows: epic.doneRows.count))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Done sub-tickets of \(epic.identifier)")
        .qaName(Self.doneListIdentifier(slot))
    }

    private static let listSpace = "epic-slot-upcoming"

    /// What is still to come, below the card: queue rows in queue order, each with its number, dependency markers, and
    /// under the pointer its drag handle and Start. A row dragged among them shows the line in the gap it lands in.
    private func upcomingList(numberWidth: CGFloat) -> some View {
        let queue = DesignTokens.HomeQueue.self
        let rows = epic.upcoming
        let gap = drag.flatMap { Self.gap(y: $0.y, from: $0.index, count: rows.count) }
        if offscreenSnapshot {
            // `ImageRenderer` draws no scroll view's content: a snapshot draws the rows the live list opens at.
            return AnyView(
                VStack(spacing: queue.doneRowGap) {
                    ForEach(Array(Self.upcomingShown(Array(rows.enumerated()))), id: \.element.id) { index, row in
                        QueueRow(row, numberWidth: numberWidth, look: hoveredRow == index ? .hover : nil, end: queue.epicRowEnd, onOpen: onOpen)
                    }
                }
                .frame(height: Self.listHeight(rows: rows.count), alignment: .top)
                .clipped()
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Sub-tickets to come of \(epic.identifier)")
                .qaName(Self.upcomingIdentifier(slot))
            )
        }
        return AnyView(ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: queue.doneRowGap) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        QueueRow(
                            row, numberWidth: numberWidth, look: hoveredRow == index ? .hover : nil, picked: drag?.index == index,
                            end: queue.epicRowEnd, onStart: { onStart(row.identifier) }, onOpen: onOpen
                        )
                        .gesture(dragGesture(index, count: rows.count))
                    }
                }
                if let drag, rows.indices.contains(drag.index) {
                    QueueRow(rows[drag.index], numberWidth: numberWidth, look: .dragged, end: queue.epicRowEnd)
                        .offset(y: drag.y - drag.grab)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    if let gap {
                        QueueDropLine().offset(y: HomeQueueDrag.lineY(gap))
                    }
                }
            }
            .coordinateSpace(.named(Self.listSpace))
        }
        .frame(height: Self.listHeight(rows: rows.count))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sub-tickets to come of \(epic.identifier)")
        .qaName(Self.upcomingIdentifier(slot)))
    }

    /// The drag of the row at `index` in the list's own space: each move follows the pointer, the end drops it.
    private func dragGesture(_ index: Int, count: Int) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.listSpace))
            .onChanged { value in
                if drag == nil {
                    drag = Drag(index: index, y: value.location.y, grab: value.startLocation.y - Double(index) * HomeQueuePager.pitch)
                } else {
                    drag?.y = value.location.y
                }
            }
            .onEnded { value in
                drag = nil
                if let gap = Self.gap(y: value.location.y, from: index, count: count) { onMove(index, gap) }
            }
    }
}
