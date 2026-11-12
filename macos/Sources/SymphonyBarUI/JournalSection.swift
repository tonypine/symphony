import SwiftUI
import SymphonyBarCore

// The Journal's list (TP-1459): the catalog's Timeline column at the desktop width, at most 780 pt, its days newest
// first under the Timeline's separator, each event drawn by the Timeline entry with its ticket's chip over what
// happened, and Show Earlier under the oldest day while the read has earlier pages. A row opens its ticket's page at
// that event; one on Symphony's own stream opens nothing.
//
// Reports (TP-1462) sit among the events at the end of their period, each drawn by `report`, the card its caller
// builds; a new one enters with the timeline's motion. The events a citation names are lit while the pointer is on it
// (`highlighted`).

public struct JournalSection<Report: View>: View {
    let model: JournalModel
    let clock: (Date) -> String
    let open: (JournalRow) -> Void
    let showEarlier: () -> Void
    /// Show Earlier's read is on its way: the button waits.
    let readingEarlier: Bool
    /// The events a report's citation under the pointer names: their rows are lit.
    let highlighted: Set<String>
    let report: (JournalReportCard) -> Report
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        model: JournalModel, calendar: Calendar = .current, readingEarlier: Bool = false, highlighted: Set<String> = [],
        open: @escaping (JournalRow) -> Void = { _ in }, showEarlier: @escaping () -> Void = {},
        @ViewBuilder report: @escaping (JournalReportCard) -> Report
    ) {
        self.model = model
        clock = TimelineModel.clock(calendar)
        self.readingEarlier = readingEarlier
        self.highlighted = highlighted
        self.open = open
        self.showEarlier = showEarlier
        self.report = report
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            ForEach(model.days) { day in
                DaySeparator(title: day.title, label: day.accessibilityLabel)
                ForEach(day.items) { item in
                    switch item {
                    case let .event(row):
                        TimelineEntryRow(entry: row.entry, time: clock(row.entry.at), selected: highlighted.contains(row.id), ticket: Self.chip(row)) {
                            if row.focus != nil { open(row) }
                        }
                        .id(Self.rowID(row.id))
                    case let .report(card):
                        report(card)
                            .padding(.vertical, DesignTokens.Space.s2)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            if model.canShowEarlier {
                Button(action: showEarlier) {
                    if readingEarlier {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(JournalModel.showEarlier)
                    }
                }
                .directorButton(.secondary, size: .small)
                .disabled(readingEarlier)
                .padding(.leading, TimelineSection.timeColumn + DesignTokens.Space.s2)
                .padding(.vertical, DesignTokens.Space.s3)
                .help("Read the 200 events before these")
            }
        }
        // A report that comes in slides in where it pins, as an entry does on the timeline.
        .animation(reduceMotion ? nil : .standard, value: model.reports.map(\.id))
        .frame(maxWidth: TimelineSection.maxWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.title)
    }

    public static var title: String { "Journal" }

    /// The scroll id of event `id`'s row: a report's citation of an event no ticket page holds scrolls the list to it.
    public static func rowID(_ id: String) -> String { "event:" + id }

    /// The column of times the rows keep, which a report's card starts after: its time sits in it.
    public static var timeColumn: CGFloat { TimelineSection.timeColumn }

    static func chip(_ row: JournalRow) -> TimelineTicketChip {
        TimelineTicketChip(identifier: row.chipIdentifier, title: row.ticket.title, opens: row.focus != nil)
    }
}

extension JournalSection where Report == EmptyView {
    /// The list without reports.
    public init(
        model: JournalModel, calendar: Calendar = .current, readingEarlier: Bool = false, open: @escaping (JournalRow) -> Void = { _ in },
        showEarlier: @escaping () -> Void = {}
    ) {
        self.init(model: model, calendar: calendar, readingEarlier: readingEarlier, open: open, showEarlier: showEarlier) { _ in EmptyView() }
    }
}
