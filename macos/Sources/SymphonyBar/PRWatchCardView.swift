import SwiftUI
import SymphonyBarCore

/// S15: the ticket page's PR and CI card (C10): the status as symbol and word with the one-line reason, who acts next,
/// what clears it and since when, the facts, the watcher's last actions and the card's buttons.
struct PRWatchCardView: View {
    let card: PRWatchCard
    /// True while a Check Now is on its way.
    var checking = false
    var perform: (PRWatchCard.Button) -> Void = { _ in }

    var body: some View {
        Card(title: PRWatchCard.title) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                summary
                if !card.competitors.isEmpty { competitors }
                facts
                if !card.actions.isEmpty { actions }
                buttons
            }
        }
    }

    /// The status, the line, the warning, who acts next and when it was read: one element for VoiceOver.
    private var summary: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                StatusBadge(status: card.status, word: card.word).fixedSize()
                Text(card.headline)
                    .font(DesignTokens.TypeStyle.rowTitle.font)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let warning = card.warning {
                Label(warning.prefix(1).uppercased() + warning.dropFirst(), systemImage: DesignTokens.Status.problem.symbol)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(DesignTokens.Status.problem.tint)
            }
            let next = [[card.next, card.clears].compactMap { $0 }.joined(separator: ", "), card.age].compactMap { $0 }.filter { !$0.isEmpty }
            if !next.isEmpty {
                Text(next.joined(separator: " · "))
                    .font(DesignTokens.TypeStyle.body.font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let updated = card.updated {
                Text(updated)
                    .font(DesignTokens.TypeStyle.callout.font)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilityLabel)
        .help(card.help ?? "")
    }

    /// Two or more competing pull requests, each with the files it shares.
    private var competitors: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            ForEach(Array(card.competitors.enumerated()), id: \.offset) { _, competitor in
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                    Text(competitor.name).font(DesignTokens.TypeStyle.rowTitle.font)
                    Text(competitor.files.joined(separator: ", "))
                        .font(DesignTokens.TypeStyle.mono.font)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(competitor.name) changes \(competitor.files.joined(separator: ", "))")
            }
        }
    }

    private var facts: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DesignTokens.Space.s4, verticalSpacing: DesignTokens.Space.s2) {
            ForEach(Array(card.facts.enumerated()), id: \.offset) { _, fact in
                GridRow {
                    Text(fact.label)
                        .font(DesignTokens.TypeStyle.body.font)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    // The PR opens from Open PR below; its row stays text.
                    Text(fact.value)
                        .font(DesignTokens.TypeStyle.body.font)
                        .monospacedDigit()
                        .textSelection(.enabled)
                        .help(fact.help ?? fact.url?.absoluteString ?? "")
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// The watcher's last actions, newest first.
    private var actions: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            Text("Last actions")
                .font(DesignTokens.TypeStyle.label.font)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(card.actions) { row in
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                    Text(row.timeText)
                        .font(DesignTokens.TypeStyle.callout.font)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 88, alignment: .leading)
                    Text(row.text).font(DesignTokens.TypeStyle.body.font)
                    Spacer(minLength: DesignTokens.Space.s2)
                    if let source = row.source {
                        Text(source)
                            .font(DesignTokens.TypeStyle.callout.font)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.accessibilityLabel)
                .help(row.help ?? "")
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            ForEach(card.buttons, id: \.self) { button in
                Button(button.title) { perform(button) }
                    .disabled(button == .checkNow && checking)
                    .help(help(button))
            }
            if checking {
                ProgressView().controlSize(.small).accessibilityLabel("Checking")
            }
        }
        .fixedSize()
    }

    private func help(_ button: PRWatchCard.Button) -> String {
        switch button {
        case .checkNow: "Have Symphony read the pull request and decide now"
        case let .openPR(url), let .openPullRequest(_, url): url.absoluteString
        case .openInInbox: "Show the decision in the Inbox"
        case let .openTicket(identifier): "Open \(identifier)'s page"
        }
    }
}
