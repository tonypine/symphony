import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// What Home's controls do (TP-1609).
struct HomeActions {
    /// A slot card's move: Answer…, Message… or Stop.
    var slotMove: (HomeSlotMove) -> Void = { _ in }
    /// Start on a queue row, by identifier.
    var start: (String) -> Void = { _ in }
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

    private static let space = "home-content"

    var body: some View {
        let range = HomeQueuePager.visibleRange(scrollTop: scrollTop, listTop: listTop, viewport: viewport, count: model.pager.count)
        let numberWidth = QueueRow.numberWidth(widest: model.pager.widestNumber(in: range))
        ScrollView {
            HomePageContent(
                model: model, views: views, notices: notices, reference: reference, actions: actions, range: range, numberWidth: numberWidth,
                space: Self.space, cardsBottom: { cardsBottom = $0 }, listTop: { listTop = $0 }
            )
        }
        .onScrollGeometryChange(for: [Double].self) { [$0.contentOffset.y + $0.contentInsets.top, $0.containerSize.height] } action: { _, value in
            scrollTop = value[0]
            viewport = value[1]
        }
        .overlay(alignment: .top) {
            if HomeStrip.pinned(scrollTop: scrollTop, cardsBottom: cardsBottom), !model.cards.isEmpty {
                HomeStrip(cards: model.cards, reference: reference, numberWidth: numberWidth)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                HomeNotice(text: notice, dismiss: actions.dismissNotice)
                    .padding(DesignTokens.Space.s3)
            }
        }
        .onChange(of: range, initial: true) { _, range in actions.show(range) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(notices, id: \.self) { HomeNoticeLine(text: $0) }
            progress
                .onGeometryChange(for: Double.self) { $0.frame(in: .named(space)).maxY } action: { cardsBottom($0) }
            queueHead
            HomeQueueList(pager: model.pager, range: range, numberWidth: numberWidth, start: actions.start, open: actions.openTicket)
                .onGeometryChange(for: Double.self) { $0.frame(in: .named(space)).minY } action: { listTop($0) }
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
                    SlotCard(slot: slot.number, ticket: slot.ticket.map { HomeQueueCards.card($0, epic: slot.epic, reference: reference) }) { action in
                        if let ticket = slot.ticket { actions.slotMove(HomeQueueCards.move(action, ticket)) }
                    }
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
/// times the pitch. A row whose page is not read yet is left blank until it is.
struct HomeQueueList: View {
    let pager: HomeQueuePager
    let range: Range<Int>
    let numberWidth: CGFloat
    var start: (String) -> Void = { _ in }
    var open: (String) -> Void = { _ in }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array(range), id: \.self) { index in
                if let row = pager.row(at: index) {
                    QueueRow(HomeQueueCards.row(row), numberWidth: numberWidth) { start(row.identifier) }
                        .offset(y: Double(index) * HomeQueuePager.pitch)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: pager.height, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(HomeQueueModel.queueTitle)
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

    /// Whether the strip shows: once the cards' bottom has scrolled above the top of the view.
    static func pinned(scrollTop: Double, cardsBottom: Double) -> Bool { cardsBottom > 0 && scrollTop > cardsBottom }

    var body: some View {
        VStack(spacing: DesignTokens.HomeQueue.stripGap) {
            ForEach(cards) { slot in
                SlotStripLine(
                    slot: slot.number, ticket: slot.ticket.map { HomeQueueCards.card($0, epic: slot.epic, reference: reference) },
                    numberWidth: numberWidth
                )
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
