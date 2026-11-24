import SwiftUI
import SymphonyBarCore

/// Home's Recently done section (TP-1644, `.pq-recent` in `docs/design/prototypes/home-queue/`), above In progress on
/// the page's gutter: the head, then the picked range's done rows with every cell, most recent first. Six rows show
/// (216 pt) and the rest scroll inside the section; the last row coming into view asks for the next page. The section
/// is not drawn when nothing finished in the last 7 days; with the range empty it keeps its head alone, without a
/// count; folded, only the head shows.
public struct HomeRecentlyDone: View {
    let list: RecentlyDoneList
    /// Symphony's clock, which when each ticket finished is told against.
    let reference: Date
    let pick: (HomeRead.DoneRange) -> Void
    let toggle: () -> Void
    let more: () -> Void
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot
    /// The zone "yesterday" and the day are told in: the Mac's, or a story's.
    @Environment(\.timeZone) private var timeZone

    public init(
        list: RecentlyDoneList, reference: Date, pick: @escaping (HomeRead.DoneRange) -> Void = { _ in },
        toggle: @escaping () -> Void = {}, more: @escaping () -> Void = {}
    ) {
        self.list = list
        self.reference = reference
        self.pick = pick
        self.toggle = toggle
        self.more = more
    }

    /// The rows' height: every row up to six on the queue's pitch, the last without the gap after it.
    public static func listHeight(rows: Int) -> Double {
        let queue = DesignTokens.HomeQueue.self
        let shown = min(max(rows, 0), queue.recentRows)
        guard shown > 0 else { return 0 }
        return Double(shown) * (queue.rowHeight + queue.doneRowGap) - queue.doneRowGap
    }

    public var body: some View {
        if list.drawn {
            VStack(alignment: .leading, spacing: 0) {
                RecentlyDoneHead(range: Binding(get: { list.range }, set: pick), count: list.countText, open: list.open, toggle: toggle)
                if list.showsRows {
                    rows
                        .frame(height: Self.listHeight(rows: list.entries.count), alignment: .top)
                        .padding(.top, DesignTokens.HomeQueue.headBottom)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(RecentlyDoneList.title)
                }
            }
            .padding(.bottom, DesignTokens.HomeQueue.recentBottom)
        }
    }

    @ViewBuilder private var rows: some View {
        let gap = DesignTokens.HomeQueue.doneRowGap
        if offscreenSnapshot {
            // A scroll view draws nothing offscreen: the rows on show, clipped to the list.
            VStack(spacing: gap) {
                ForEach(list.entries.prefix(DesignTokens.HomeQueue.recentRows)) { row($0) }
            }
            .clipped()
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: gap) {
                    ForEach(list.entries) { entry in
                        row(entry).onAppear { if entry.id == list.entries.last?.id { more() } }
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
    }

    private func row(_ entry: HomeRead.DoneEntry) -> some View {
        DoneRow(HomeQueueCards.done(entry, reference: reference, timeZone: timeZone), cells: .all)
    }
}
