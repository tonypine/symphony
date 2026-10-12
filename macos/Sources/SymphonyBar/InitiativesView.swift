import SwiftUI
import SymphonyBarCore

/// D5: Initiatives, from `/api/v1/initiatives`, under the window's scope.
struct InitiativesContent: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient

    var body: some View {
        if let list = model.initiativesList {
            InitiativesView(
                list: list,
                selection: $model.initiativeSelection,
                actions: InitiativeActions(
                    review: { model.showInbox(selecting: $0) },
                    openTicket: model.openTicket,
                    openURL: model.onOpenURL
                )
            )
        } else if model.initiativesResult == .unsupported {
            EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
        } else {
            EmptyState(title: "Reading the initiatives…", symbol: SymphonyView.initiatives.symbol, showsSpinner: true)
        }
    }
}

struct InitiativeActions {
    /// Review on a sub-ticket that waits on the Director opens its Inbox item, by issue id.
    var review: (String) -> Void = { _ in }
    /// Any other row opens the ticket's page, by identifier.
    var openTicket: (String) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }
}

/// The list grouped as Active, In review and Done recently beside the selected initiative, like the Inbox (P4).
struct InitiativesView: View {
    let list: InitiativesList
    @Binding var selection: String?
    let actions: InitiativeActions

    var body: some View {
        if list.isEmpty {
            ContentUnavailableView {
                Label(InitiativesList.emptyTitle, systemImage: SymphonyView.initiatives.symbol)
            } description: {
                Text(InitiativesList.emptyDescription)
            }
        } else {
            HStack(spacing: 0) {
                ScrollView {
                    InitiativesListRows(list: list, selected: list.selection(selection)?.id, select: { selection = $0 })
                }
                .frame(width: DesignTokens.Layout.listColumnWidth)
                .background(DesignTokens.Surface.content.color)
                Divider()
                if let initiative = list.selection(selection) {
                    ScrollView {
                        InitiativeDetail(initiative: initiative, actions: actions)
                    }
                    .id(initiative.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

/// The groups and their rows, outside the scroll view so they also render offscreen.
struct InitiativesListRows: View {
    let list: InitiativesList
    let selected: String?
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            ForEach(list.sections) { section in
                Text(section.title)
                    .font(DesignTokens.TypeStyle.label.font)
                    .foregroundStyle(.secondary)
                    .padding(.top, DesignTokens.Space.s3)
                    .padding(.horizontal, DesignTokens.Space.s3)
                    .accessibilityAddTraits(.isHeader)
                ForEach(section.initiatives) { initiative in
                    InitiativeRow(initiative: initiative, selected: initiative.id == selected)
                        .contentShape(Rectangle())
                        .onTapGesture { select(initiative.id) }
                        .accessibilityAction { select(initiative.id) }
                }
            }
        }
        .padding(DesignTokens.Space.s2)
    }
}

/// A list row: identifier and title, "4 of 8 done", and the bar with its legend.
private struct InitiativeRow: View {
    let initiative: Initiative
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            HStack(alignment: .firstTextBaseline) {
                Text(initiative.identifier).font(DesignTokens.TypeStyle.rowTitle.font)
                Spacer(minLength: DesignTokens.Space.s2)
                Text(initiative.progress)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let title = initiative.title {
                Text(title).font(DesignTokens.TypeStyle.body.font).lineLimit(1)
            }
            InitiativeBar(initiative: initiative)
            InitiativeLegend(initiative: initiative)
        }
        .padding(DesignTokens.Space.s3)
        .background(
            selected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(Color.clear),
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(initiative.identifier), \(initiative.title ?? ""), \(initiative.barAccessibilityLabel)")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - C12: the progress bar by stage

/// A stacked bar of the sub-tickets by stage, segments split by a 2 pt gap. VoiceOver reads each stage's count.
struct InitiativeBar: View {
    let initiative: Initiative
    var height: CGFloat = 8

    var body: some View {
        let segments = initiative.legend
        let total = max(segments.reduce(0) { $0 + $1.count }, 1)
        GeometryReader { geometry in
            let gaps = CGFloat(max(segments.count - 1, 0)) * 2
            HStack(spacing: 2) {
                if segments.isEmpty {
                    Capsule().fill(DesignTokens.Surface.raised.color)
                } else {
                    ForEach(segments, id: \.stage) { segment in
                        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                            .fill(segment.stage.status.tint.opacity(segment.stage.isLight ? 0.45 : 1))
                            .frame(width: max(0, (geometry.size.width - gaps) * CGFloat(segment.count) / CGFloat(total)))
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue(initiative.barAccessibilityLabel)
    }
}

/// The bar's legend: each stage's symbol, count and word, so the bar never relies on color alone.
struct InitiativeLegend: View {
    let initiative: Initiative

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Space.s3) { items }
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1 / 2) { items }
        }
        .font(DesignTokens.TypeStyle.caption.font)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var items: some View {
        ForEach(initiative.legend, id: \.stage) { item in
            Label {
                Text("\(item.count) \(item.stage.word)").foregroundStyle(.secondary).monospacedDigit()
            } icon: {
                Image(systemName: item.stage.symbol)
                    .foregroundStyle(item.stage.status.tint.opacity(item.stage.isLight ? 0.6 : 1))
            }
            .labelStyle(.titleAndIcon)
            .fixedSize()
        }
    }
}

// MARK: - The detail

/// The selected initiative: its sentence, the bar with its legend, its slot line and its sub-tickets in landing order.
struct InitiativeDetail: View {
    let initiative: Initiative
    let actions: InitiativeActions

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                    Button { actions.openTicket(initiative.identifier) } label: {
                        Text(initiative.identifier).font(DesignTokens.TypeStyle.label.font).foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Open the ticket page")
                    if let title = initiative.title {
                        Text(title).font(DesignTokens.TypeStyle.section.font).accessibilityAddTraits(.isHeader)
                    }
                }
                Spacer()
                if let url = initiative.url {
                    Button("Open in Linear") { actions.openURL(url) }
                }
            }
            Text(initiative.sentence)
                .font(DesignTokens.TypeStyle.sentence.font)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                InitiativeBar(initiative: initiative, height: 12)
                InitiativeLegend(initiative: initiative)
                if let slot = initiative.slot {
                    Label(slot.line, systemImage: "square.stack.3d.up")
                        .font(DesignTokens.TypeStyle.callout.font)
                        .foregroundStyle(.secondary)
                }
            }
            Card(title: "Sub-tickets") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(initiative.subTickets.enumerated()), id: \.element.id) { index, ticket in
                        if index > 0 { Divider() }
                        SubTicketRow(ticket: ticket, actions: actions)
                    }
                    if let final = initiative.finalVerification {
                        if !initiative.subTickets.isEmpty { Divider() }
                        SubTicketRow(ticket: final.ticket, actions: actions, finalLine: final.line)
                    }
                    if initiative.subTickets.isEmpty && initiative.finalVerification == nil {
                        Text("No sub-tickets yet.").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(DesignTokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A sub-ticket: its stage symbol, identifier and title, what it waits on and its blocked-by links; Review when it
/// waits on the Director, else the row opens the ticket page.
private struct SubTicketRow: View {
    let ticket: Initiative.SubTicket
    let actions: InitiativeActions
    /// The final verification's line, in place of what it waits on.
    var finalLine: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            Image(systemName: finalLine == nil ? ticket.waits.stage.symbol : "checkmark.seal")
                .foregroundStyle(ticket.waits.stage.status.tint.opacity(ticket.waits.stage.isLight ? 0.6 : 1))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1 / 2) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                    Text(ticket.identifier).font(DesignTokens.TypeStyle.rowTitle.font)
                    if let title = ticket.title { Text(title).lineLimit(1) }
                }
                HStack(spacing: DesignTokens.Space.s2) {
                    Text(finalLine ?? ticket.waits.line)
                        .foregroundStyle(ticket.waits == .you ? AnyShapeStyle(DesignTokens.Status.you.tint) : AnyShapeStyle(.secondary))
                    if !ticket.blockedBy.isEmpty && ticket.waits != .done {
                        Text("Blocked by").foregroundStyle(.tertiary)
                        ForEach(ticket.blockedBy, id: \.self) { blocker in
                            Button { actions.openTicket(blocker) } label: { Text(blocker).foregroundStyle(Color.accentColor) }
                                .buttonStyle(.plain)
                                .help("Open \(blocker)")
                        }
                    }
                }
                .font(DesignTokens.TypeStyle.callout.font)
            }
            Spacer(minLength: DesignTokens.Space.s2)
            if ticket.waits == .you, let issueID = ticket.issueID {
                Button("Review") { actions.review(issueID) }
                    .buttonStyle(.borderedProminent)
                    .help("Open it in the Inbox")
            } else {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
        }
        .padding(.vertical, DesignTokens.Space.s2)
        .contentShape(Rectangle())
        .onTapGesture { actions.openTicket(ticket.identifier) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(finalLine.map { "\(ticket.identifier), final verification, \($0.lowercased())" } ?? ticket.accessibilityLabel)
        .accessibilityAction(named: "Open Ticket") { actions.openTicket(ticket.identifier) }
    }
}

// MARK: - D1: the Overview's Initiatives card

/// The active initiatives and their progress; a click opens one in Initiatives.
struct InitiativesCard: View {
    let initiatives: [Initiative]
    let open: (String) -> Void
    static let limit = 4

    var body: some View {
        Card(title: SymphonyView.initiatives.title) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                ForEach(initiatives.prefix(Self.limit)) { initiative in
                    Button { open(initiative.id) } label: {
                        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(initiative.identifier).font(DesignTokens.TypeStyle.rowTitle.font)
                                Text(initiative.title ?? "").lineLimit(1).foregroundStyle(.secondary)
                                Spacer(minLength: DesignTokens.Space.s2)
                                Text(initiative.progress).font(DesignTokens.TypeStyle.callout.font).monospacedDigit()
                            }
                            InitiativeBar(initiative: initiative, height: 6)
                            InitiativeLegend(initiative: initiative)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(initiative.identifier) in Initiatives")
                    .accessibilityLabel("\(initiative.identifier), \(initiative.title ?? ""), \(initiative.barAccessibilityLabel)")
                }
                if initiatives.count > Self.limit {
                    Text("\(initiatives.count - Self.limit) more in Initiatives")
                        .font(DesignTokens.TypeStyle.callout.font)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
