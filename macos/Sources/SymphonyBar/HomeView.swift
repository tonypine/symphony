import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// What Home's controls do (TP-1609).
struct HomeActions {
    /// A slot card's move: Answer…, Message… or Stop.
    var slotMove: (HomeSlotMove) -> Void = { _ in }
    /// Start on a queue row, by identifier.
    var start: (String) -> Void = { _ in }
    /// A queue row dropped into a gap of the list (TP-1610): the row, its index and the gap.
    var move: (HomeRead.Row, Int, Int) -> Void = { _, _, _ in }
    /// A queue row dropped on a slot (TP-1610): its identifier and the slot, from 1.
    var startOnSlot: (String, Int) -> Void = { _, _ in }
    /// The slot count control.
    var setSlots: (Int) -> Void = { _ in }
    /// A saved view picked above the queue, nil for every ticket.
    var pick: (String?) -> Void = { _ in }
    /// The rows on screen changed: their pages are read.
    var show: (Range<Int>) -> Void = { _ in }
    /// A click on a row opens the ticket's page.
    var openTicket: (String) -> Void = { _ in }
    /// Dismisses the line that says why a move didn't go through.
    var dismissNotice: () -> Void = {}
}

/// Home, the window to Symphony's queue (TP-1609, `docs/design/prototypes/home-queue/`): two sections on one 32 pt
/// gutter. In progress, one card per slot (an empty slot an outline reading "Slot N") with the slot count control beside
/// its title; then Queue, the saved views of the Tickets page as pills and every ticket that holds no slot in its stored
/// order with its position number. The list is virtual: it is as tall as all its rows, and only the rows on screen are
/// drawn, their pages read as they come on screen. Once the cards scroll out of view, a strip with one line per slot
/// stays on top, its columns over the queue's columns.
///
/// A queue row is dragged (TP-1610) onto a gap of the list, which moves it there, or onto a slot card or a strip line,
/// which starts it on that slot. The pointer and every target's frame are taken in the scroll view's own space, so the
/// gap under the pointer is worked out from the list's top and the row pitch whatever rows are drawn, and the strip's
/// lines, pinned over the list, win over the rows beneath them. Near the top or the bottom edge the list scrolls.
struct HomeView: View {
    @ObservedObject var model: HomeQueueModel
    /// The Tickets page's saved views.
    let views: [TicketView]
    /// What holds the whole factory, one line each above the sections (TP-1515).
    let notices: [String]
    /// Symphony's clock, which the cards' times are measured against.
    let reference: Date
    let actions: HomeActions

    @State private var scrollTop: Double = 0
    @State private var viewport: Double = 0
    @State private var listTop: Double = 0
    @State private var cardsBottom: Double = 0
    /// The scroll view's content width: its own width less a shown scroller, so the strip spans what the rows span.
    @State private var contentWidth: Double = 0
    /// The row being dragged, nil while none is.
    @State private var drag: HomeDrag?
    /// The drop targets' frames in the scroll view's space: the slot cards and the strip's lines by slot, and the list.
    @State private var cardFrames: [Int: CGRect] = [:]
    @State private var stripFrames: [Int: CGRect] = [:]
    @State private var listFrame: CGRect?
    @State private var scrollPosition = ScrollPosition(edge: .top)
    /// The content offset, and the offsets it can take, which a drag at an edge scrolls between.
    @State private var offset: Double = 0
    @State private var offsets: ClosedRange<Double> = 0...0

    private static let space = "home-content"
    static let viewportSpace = "home-viewport"

    var body: some View {
        let range = HomeQueuePager.visibleRange(scrollTop: scrollTop, listTop: listTop, viewport: viewport, count: model.pager.count)
        let numberWidth = QueueRow.numberWidth(widest: model.pager.widestNumber(in: range))
        let pinned = HomeStrip.pinned(scrollTop: scrollTop, cardsBottom: cardsBottom) && !model.cards.isEmpty
        let target = dropTarget(pinned: pinned)
        let dragging = HomeDragging(
            drag: drag, target: target, moved: { row, index, start, point in moved(row, index: index, start: start, to: point) },
            dropped: { row, index, point in drop(row, from: index, at: point, pinned: pinned) }, cancelled: { drag = nil }
        )
        ScrollView {
            HomePageContent(
                model: model, views: views, notices: notices, reference: reference, actions: actions, range: range, numberWidth: numberWidth,
                space: Self.space, cardsBottom: { cardsBottom = $0 }, listTop: { listTop = $0 }, dragging: dragging,
                cardFrame: { cardFrames[$0] = $1 }, listFrame: { listFrame = $0 }
            )
            .onGeometryChange(for: Double.self) { $0.size.width } action: { contentWidth = $0 }
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: [Double].self) { [$0.contentOffset.y + $0.contentInsets.top, $0.containerSize.height] } action: { _, value in
            scrollTop = value[0]
            viewport = value[1]
        }
        .onScrollGeometryChange(for: ClosedRange<Double>.self) { geometry in
            let top = -Double(geometry.contentInsets.top)
            return top...max(top, Double(geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height))
        } action: { _, value in offsets = value }
        .onScrollGeometryChange(for: Double.self) { Double($0.contentOffset.y) } action: { _, value in offset = value }
        // The scroll geometry reports only a change, never its first value: the view's own height, reported from the
        // first layout, gives the rows on screen before any scroll.
        .onGeometryChange(for: Double.self) { $0.size.height } action: { viewport = $0 }
        .overlay(alignment: .topLeading) {
            if pinned {
                // On the content's width, not the scroll view's: a shown scroller takes its width from the content's
                // right, and the strip's lines end where the rows and the cards end.
                HomeStrip(
                    cards: model.cards, reference: reference, numberWidth: numberWidth, dropSlot: target?.slot, lineFrame: { stripFrames[$0] = $1 }
                )
                .frame(width: contentWidth > 0 ? contentWidth : nil)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay(alignment: .topLeading) { lifted(numberWidth: numberWidth, gap: target?.gap) }
        .coordinateSpace(.named(Self.viewportSpace))
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                HomeNotice(text: notice, dismiss: actions.dismissNotice)
                    .padding(DesignTokens.Space.s3)
            }
        }
        .onChange(of: range, initial: true) { _, range in actions.show(range) }
        .task(id: scrollDirection(pinned: pinned)) { await autoscroll(scrollDirection(pinned: pinned)) }
    }

    /// What the dragged row is over now.
    private func dropTarget(pinned: Bool) -> HomeQueueDrag.Target? {
        drag.flatMap { target(at: $0.location, pinned: pinned) }
    }

    /// What a drop at `point` lands on: the strip's lines only while it shows, and only the slots Home shows.
    private func target(at point: CGPoint, pinned: Bool) -> HomeQueueDrag.Target? {
        let slots = Set(model.cards.map(\.number))
        let strip = pinned ? stripFrames.filter { slots.contains($0.key) } : [:]
        let cards = cardFrames.filter { slots.contains($0.key) }
        let target = HomeQueueDrag.target(at: point, strip: strip, cards: cards, list: listFrame, count: model.pager.count)
        // A gap inside an epic's sub-tickets is not a top-level row's place: the line and the drop go past them.
        if case let .gap(gap)? = target { return .gap(HomeQueueDrag.snap(gap, in: model.pager)) }
        return target
    }

    /// The pointer moved during the drag of `row`, at `index`, that started at `start`: the first move picks the row up,
    /// keeping where on it the pointer took it.
    private func moved(_ row: HomeRead.Row, index: Int, start: CGPoint, to point: CGPoint) {
        if drag == nil {
            let top = (listFrame?.minY ?? 0) + Double(index) * HomeQueuePager.pitch
            drag = HomeDrag(row: row, index: index, location: point, grab: start.y - top)
        } else {
            drag?.location = point
        }
    }

    /// A drop at `point`: onto a slot starts the row there, into a gap moves it; anywhere else changes nothing.
    private func drop(_ row: HomeRead.Row, from index: Int, at point: CGPoint, pinned: Bool) {
        drag = nil
        switch target(at: point, pinned: pinned) {
        case let .slot(slot)?: actions.startOnSlot(row.identifier, slot)
        case let .gap(gap)?: actions.move(row, index, gap)
        case nil: break
        }
    }

    /// Which way the list scrolls under the drag: toward the edge the pointer is near.
    private func scrollDirection(pinned: Bool) -> Int {
        // Over a slot (a card, or a strip line under the strip's top edge) the list holds still, so the slot stays put.
        guard let drag, dropTarget(pinned: pinned)?.slot == nil else { return 0 }
        let top = pinned ? (stripFrames.values.map(\.maxY).max() ?? 0) : 0
        return HomeQueueDrag.scrollDirection(y: drag.location.y, top: top, viewport: viewport)
    }

    /// Scrolls the list a step at a time toward `direction` while the drag stays at that edge.
    private func autoscroll(_ direction: Int) async {
        guard direction != 0 else { return }
        while !Task.isCancelled {
            let next = min(max(offset + HomeQueueDrag.scrollStep * Double(direction), offsets.lowerBound), offsets.upperBound)
            guard next != offset else { return }
            scrollPosition.scrollTo(y: next)
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    /// The dragged row, lifted under the pointer over the list's column, and the line in the `gap` it would land in,
    /// drawn over the lifted row (`.drop-line` stands above the rows, and the row is lifted right over the gap).
    @ViewBuilder private func lifted(numberWidth: CGFloat, gap: Int?) -> some View {
        if let drag, let listFrame {
            ZStack(alignment: .topLeading) {
                QueueRow(HomeQueueCards.row(drag.row), numberWidth: numberWidth, look: .dragged)
                    .frame(width: listFrame.width)
                    .offset(x: listFrame.minX, y: drag.location.y - drag.grab)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                if let gap {
                    QueueDropLine()
                        .frame(width: listFrame.width)
                        .offset(x: listFrame.minX, y: listFrame.minY + HomeQueueDrag.lineY(gap))
                }
            }
        }
    }
}

/// A queue row being dragged (TP-1610): the row as it was picked up and its index, the pointer in the scroll view's
/// space, and how far below the row's top the pointer took it.
struct HomeDrag: Equatable {
    var row: HomeRead.Row
    var index: Int
    var location: CGPoint
    var grab: Double
}

/// The drag as the list sees it: the row dragged and what it is over, and the calls that report a move of the pointer
/// (the row, its index, where the drag started and where the pointer is), a drop and a cancelled drag.
struct HomeDragging {
    var drag: HomeDrag?
    var target: HomeQueueDrag.Target?
    var moved: (HomeRead.Row, Int, CGPoint, CGPoint) -> Void = { _, _, _, _ in }
    var dropped: (HomeRead.Row, Int, CGPoint) -> Void = { _, _, _ in }
    var cancelled: () -> Void = {}
}

extension HomeQueueDrag.Target {
    /// The slot it is, nil for a gap.
    var slot: Int? {
        if case let .slot(slot) = self { return slot }
        return nil
    }

    /// The gap it is, nil for a slot.
    var gap: Int? {
        if case let .gap(gap) = self { return gap }
        return nil
    }
}

/// Home's two sections, outside the scroll view so they also render offscreen: the rows of `range` drawn, the cards'
/// bottom and the list's top reported in the coordinate space `space`.
struct HomePageContent: View {
    @ObservedObject var model: HomeQueueModel
    let views: [TicketView]
    let notices: [String]
    let reference: Date
    let actions: HomeActions
    let range: Range<Int>
    let numberWidth: CGFloat
    var space = "home-content"
    var cardsBottom: (Double) -> Void = { _ in }
    var listTop: (Double) -> Void = { _ in }
    var dragging = HomeDragging()
    /// A slot card's frame in the scroll view's space, by slot.
    var cardFrame: (Int, CGRect) -> Void = { _, _ in }
    /// The list's frame in the scroll view's space.
    var listFrame: (CGRect) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(notices, id: \.self) { HomeNoticeLine(text: $0) }
            progress
                .onGeometryChange(for: Double.self) { $0.frame(in: .named(space)).maxY } action: { cardsBottom($0) }
            queueHead
            HomeQueueList(
                pager: model.pager, range: range, numberWidth: numberWidth, start: actions.start, open: actions.openTicket, dragging: dragging
            )
                .onGeometryChange(for: Double.self) { $0.frame(in: .named(space)).minY } action: { listTop($0) }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(HomeView.viewportSpace)) } action: { listFrame($0) }
        }
        .padding(.horizontal, DesignTokens.HomeQueue.gutter)
        .padding(.top, DesignTokens.HomeQueue.pageTop)
        .padding(.bottom, DesignTokens.HomeQueue.pageBottom)
        .frame(maxWidth: DesignTokens.Layout.homeMaxWidth, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
        .coordinateSpace(.named(space))
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignTokens.HomeQueue.headGap) {
                HomeSectionTitle(text: HomeQueueModel.progressTitle)
                Spacer(minLength: 0)
                SlotCountControl(count: Binding(get: { model.slotCount }, set: { actions.setSlots($0) }))
            }
            .frame(height: DesignTokens.HomeQueue.headHeight)
            .padding(.bottom, DesignTokens.HomeQueue.headBottom)
            VStack(spacing: DesignTokens.HomeQueue.cardsGap) {
                ForEach(model.cards) { slot in
                    SlotCard(
                        slot: slot.number, ticket: slot.ticket.map { HomeQueueCards.card($0, epic: slot.epic, reference: reference) },
                        dropTarget: dragging.target?.slot == slot.number
                    ) { action in
                        if let ticket = slot.ticket { actions.slotMove(HomeQueueCards.move(action, ticket)) }
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(HomeView.viewportSpace)) } action: { cardFrame(slot.number, $0) }
                }
            }
        }
    }

    private var queueHead: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignTokens.HomeQueue.headGap) {
                HomeSectionTitle(text: HomeQueueModel.queueTitle)
                Spacer(minLength: 0)
            }
            .frame(height: DesignTokens.HomeQueue.headHeight)
            .padding(.bottom, DesignTokens.HomeQueue.headBottom)
            HomeViewPills(views: views, picked: model.view, count: model.pager.count, total: model.pager.total, pick: actions.pick)
                .padding(.bottom, DesignTokens.HomeQueue.viewsBottom)
        }
        .padding(.top, DesignTokens.HomeQueue.queueTop)
    }
}

/// A section's title, in the sentence style.
struct HomeSectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .textStyle(.sentence)
            .foregroundStyle(DesignTokens.TextColor.primary.color)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The virtual list (`.vlist`): as tall as every row the filter keeps, drawing only `range`, each row at its index
/// times the pitch. A row whose page is not read yet is left blank until it is. While a row is dragged (TP-1610) it stays
/// drawn in its place, dimmed, even once it scrolls out of `range` (its gesture lives on it); `HomeView` draws the line
/// in the gap it would land in, over the lifted row. With a saved view picked no row is dragged.
struct HomeQueueList: View {
    let pager: HomeQueuePager
    let range: Range<Int>
    let numberWidth: CGFloat
    var start: (String) -> Void = { _ in }
    var open: (String) -> Void = { _ in }
    var dragging = HomeDragging()
    @GestureState private var active = false

    /// The indexes drawn: the rows on screen and the one dragged.
    static func drawn(_ range: Range<Int>, dragged: Int?) -> [Int] {
        guard let dragged, !range.contains(dragged) else { return Array(range) }
        return Array(range) + [dragged]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Self.drawn(range, dragged: dragging.drag?.index), id: \.self) { index in
                let dragged = dragging.drag?.index == index ? dragging.drag?.row : nil
                if let row = dragged ?? pager.row(at: index) {
                    let movable = HomeQueueDrag.canDrag(row, at: index, in: pager)
                    QueueRow(
                        HomeQueueCards.row(row), numberWidth: numberWidth, reorderable: movable, picked: dragged != nil
                    ) { start(row.identifier) }
                    .gesture(dragGesture(row, index: index, movable: movable))
                    .offset(y: Double(index) * HomeQueuePager.pitch)
                }
            }
        }
        .onChange(of: active) { _, active in
            // A drag the system cancelled ends with no drop.
            if !active, dragging.drag != nil { dragging.cancelled() }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: pager.height, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(HomeQueueModel.queueTitle)
    }

    /// The drag of `row` at `index`, in the scroll view's space: each move reports the pointer, and the end drops it. The
    /// gesture is on every row, and one that may not be `movable` (a saved view is picked, an epic with its sub-tickets)
    /// reports nothing, so no mask changes when the view does.
    private func dragGesture(_ row: HomeRead.Row, index: Int, movable: Bool) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(HomeView.viewportSpace))
            .updating($active) { _, active, _ in active = movable }
            .onChanged { value in if movable { dragging.moved(row, index, value.startLocation, value.location) } }
            .onEnded { value in if movable { dragging.dropped(row, index, value.location) } }
    }
}

/// The saved views above the queue (`.pq-filters`, `.fview`): "All tickets" and each saved view of the Tickets page,
/// the picked one pressed on the accent's tint; a pill's count is its rows, known for All tickets and the one picked.
struct HomeViewPills: View {
    let views: [TicketView]
    let picked: String?
    let count: Int
    let total: Int
    let pick: (String?) -> Void

    var body: some View {
        HStack(spacing: DesignTokens.HomeQueue.viewsGap) {
            pill(HomeQueueModel.allTitle, id: nil, count: total)
            ForEach(views) { view in
                pill(view.name, id: view.id, count: picked == view.id ? count : nil)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved views")
    }

    private func pill(_ title: String, id: String?, count: Int?) -> some View {
        Button { pick(id) } label: {
            HStack(spacing: DesignTokens.HomeQueue.viewPillGap) {
                Text(title)
                if let count {
                    Text(DesignTokens.HomeQueue.number(count))
                        .monospacedDigit()
                        .foregroundStyle(DesignTokens.TextColor.secondary.color)
                }
            }
        }
        .directorButton(.quiet, size: .small, selected: picked == id)
    }
}

/// The strip that stays on top once the cards scroll away (`.pq-mini`): one line per slot on thick glass, the empty
/// ones included, each line's columns over the queue's.
struct HomeStrip: View {
    let cards: [HomeRead.Slot]
    let reference: Date
    let numberWidth: CGFloat
    /// The slot under a dragged row (TP-1610), drawn as its target.
    var dropSlot: Int?
    /// A line's frame in the scroll view's space, by slot: each line is a drop target.
    var lineFrame: (Int, CGRect) -> Void = { _, _ in }

    /// Whether the strip shows: once the cards' bottom has scrolled above the top of the view.
    static func pinned(scrollTop: Double, cardsBottom: Double) -> Bool { cardsBottom > 0 && scrollTop > cardsBottom }

    var body: some View {
        VStack(spacing: DesignTokens.HomeQueue.stripGap) {
            ForEach(cards) { slot in
                SlotStripLine(
                    slot: slot.number, ticket: slot.ticket.map { HomeQueueCards.card($0, epic: slot.epic, reference: reference) },
                    numberWidth: numberWidth, dropTarget: dropSlot == slot.number
                )
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(HomeView.viewportSpace)) } action: { lineFrame(slot.number, $0) }
            }
        }
        .padding(.vertical, DesignTokens.HomeQueue.stripInset)
        .padding(.horizontal, DesignTokens.HomeQueue.gutter)
        .frame(maxWidth: DesignTokens.Layout.homeMaxWidth)
        .frame(maxWidth: .infinity)
        .glassBackground(.thick, in: Rectangle())
        .overlay(alignment: .bottom) { HairlineDivider(.horizontal) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Slots")
    }
}

/// A line of what holds the whole factory (TP-1515), in the Waiting for provider kind's glyph and tint.
struct HomeNoticeLine: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .textStyle(.body)
                .foregroundStyle(DesignTokens.TextColor.primary.color)
                .frame(maxWidth: DesignTokens.Measure.reading, alignment: .leading)
        } icon: {
            DesignTokens.SituationKind.provider.glyph
        }
        .padding(.bottom, DesignTokens.Space.s4)
        .accessibilityElement(children: .combine)
    }
}

/// Why a move from Home didn't go through (`.ptoast`): Symphony's words on thick glass, with × to dismiss it.
struct HomeNotice: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        HStack(spacing: DesignTokens.Space.s2) {
            Text(text)
                .textStyle(.secondary)
                .foregroundStyle(DesignTokens.TextColor.primary.color)
                .fixedSize(horizontal: false, vertical: true)
            IconButton("xmark", help: "Dismiss", size: .small, action: dismiss)
        }
        .padding(.horizontal, DesignTokens.Space.s3)
        .padding(.vertical, DesignTokens.Space.s2)
        .frame(maxWidth: DesignTokens.Measure.reading)
        .glassBackground(.thick, in: shape)
        .elevation(DesignTokens.Elevation.level3, in: shape)
        .accessibilityElement(children: .combine)
    }
}
