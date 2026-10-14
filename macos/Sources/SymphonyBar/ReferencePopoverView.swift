import SwiftUI
import SymphonyBarCore

/// N2 and N3: a chip's popover, 330 pt wide on the popover's glass. A ticket shows identifier · repo with its stage
/// badge (C7), its title, summary and facts; a pull request its symbol, number and ticket with its review state,
/// title, summary and figures. A mention Symphony can't see says so. The footer says what a click on the chip does
/// and holds the link out.
struct ReferencePopoverView: View {
    let popover: ReferencePopover
    var openURL: (URL) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            switch popover.content {
            case let .ticket(ticket): TicketPopover(ticket: ticket)
            case let .pullRequest(pullRequest): PullRequestPopover(pullRequest: pullRequest)
            case let .missing(line):
                Label(line, systemImage: "eye.slash")
                    .font(DesignTokens.TypeStyle.body.font)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if popover.hint != nil || popover.link != nil {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                    if let hint = popover.hint {
                        Text(hint)
                            .font(DesignTokens.TypeStyle.caption.font)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: DesignTokens.Space.s2)
                    if let link = popover.link {
                        Button(link.title) { openURL(link.url) }
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(DesignTokens.Space.s4)
        .frame(width: ReferencePopover.width, alignment: .leading)
    }
}

/// N2's body.
private struct TicketPopover: View {
    let ticket: ReferencePopover.Ticket

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.s2) {
            Text([ticket.identifier, ticket.repoKey].compactMap { $0 }.joined(separator: " · "))
                .font(DesignTokens.TypeStyle.label.font)
                .foregroundStyle(.secondary)
            Spacer(minLength: DesignTokens.Space.s2)
            if let badge = ticket.badge { StatusBadge(status: badge.status, word: badge.word).fixedSize() }
        }
        if let title = ticket.title {
            Text(title)
                .font(DesignTokens.TypeStyle.rowTitle.font)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let summary = ticket.summary {
            Text(summary)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !ticket.facts.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                ForEach(ticket.facts, id: \.label) { fact in
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
                        Text(fact.label)
                            .foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .leading)
                        Text(fact.value).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(DesignTokens.TypeStyle.callout.font)
        }
    }
}

/// N3's body: no commit hash, branch or file name, only what the Director decides on.
private struct PullRequestPopover: View {
    let pullRequest: ReferencePopover.PullRequest

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.s2) {
            Label(pullRequest.number, systemImage: ReferencePopover.pullRequestSymbol)
                .font(DesignTokens.TypeStyle.rowTitle.font)
            if let forTicket = pullRequest.forTicket {
                Text(forTicket)
                    .font(DesignTokens.TypeStyle.label.font)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignTokens.Space.s2)
            StatusBadge(status: pullRequest.state.status, word: pullRequest.state.word).fixedSize()
        }
        if let title = pullRequest.title {
            Text(title)
                .font(DesignTokens.TypeStyle.rowTitle.font)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let summary = pullRequest.summary {
            Text(summary)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !pullRequest.stats.isEmpty {
            // Two figures a row, so four fit the popover's width.
            Grid(alignment: .leading, horizontalSpacing: DesignTokens.Space.s4, verticalSpacing: DesignTokens.Space.s1) {
                ForEach(Array(stride(from: 0, to: pullRequest.stats.count, by: 2)), id: \.self) { start in
                    GridRow {
                        ForEach(pullRequest.stats[start..<min(start + 2, pullRequest.stats.count)], id: \.label) { stat in
                            StatView(stat: stat)
                        }
                    }
                }
            }
            .font(DesignTokens.TypeStyle.callout.font)
        }
    }
}

/// One of N3's figures: its value and what it counts, or the checks' symbol and words.
private struct StatView: View {
    let stat: ReferencePopover.Stat

    var body: some View {
        HStack(spacing: DesignTokens.Space.s1) {
            if let status = stat.status {
                Image(systemName: status.symbol).foregroundStyle(status.tint)
            }
            if !stat.value.isEmpty { Text(stat.value).monospacedDigit() }
            Text(stat.label).foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stat.accessibilityLabel)
    }
}
