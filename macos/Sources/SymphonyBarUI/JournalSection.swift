import SwiftUI
import SymphonyBarCore

// The Journal's list (TP-1459): the catalog's Timeline column at the desktop width, at most 780 pt, its days newest
// first under the Timeline's separator, each event drawn by the Timeline entry with its ticket's chip over what
// happened, and Show Earlier under the oldest day while the read has earlier pages. A row opens its ticket's page at
// that event; one on Symphony's own stream opens nothing.
//
// Reports (23/26 to 25/26) have no row yet. Their slot is `reports(for:)`: a period's report pins at the top of the
// day its period ends on, above that day's events, and draws nothing until those tickets fill it.

public struct JournalSection: View {
    let model: JournalModel
    let clock: (Date) -> String
    let open: (JournalRow) -> Void
    let showEarlier: () -> Void
    /// Show Earlier's read is on its way: the button waits.
    let readingEarlier: Bool

    public init(
        model: JournalModel, calendar: Calendar = .current, readingEarlier: Bool = false, open: @escaping (JournalRow) -> Void = { _ in },
        showEarlier: @escaping () -> Void = {}
    ) {
        self.model = model
        clock = TimelineModel.clock(calendar)
        self.readingEarlier = readingEarlier
        self.open = open
        self.showEarlier = showEarlier
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            ForEach(model.days) { day in
                DaySeparator(title: day.title, label: day.accessibilityLabel)
                reports(for: day)
                ForEach(day.rows) { row in
                    TimelineEntryRow(entry: row.entry, time: clock(row.entry.at), selected: false, ticket: Self.chip(row)) {
                        if row.focus != nil { open(row) }
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
        .frame(maxWidth: TimelineSection.maxWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.title)
    }

    public static let title = "Journal"

    /// The reports pinned at the top of `day`, the day their period ends on: none until 23/26 to 25/26 write them.
    @ViewBuilder
    private func reports(for day: JournalDay) -> some View {
        EmptyView()
    }

    static func chip(_ row: JournalRow) -> TimelineTicketChip {
        TimelineTicketChip(identifier: row.chipIdentifier, title: row.ticket.title, opens: row.focus != nil)
    }
}
