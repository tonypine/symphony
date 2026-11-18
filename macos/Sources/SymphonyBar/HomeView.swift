import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// What Home's rows do.
struct HomeActions {
    /// A click on a ticket's row, or Return on it, opens the ticket's page, by identifier.
    var openTicket: (String) -> Void = { _ in }
    /// A click on an epic's row, or Return on it, opens Initiatives on the epic, by issue id.
    var openEpic: (String) -> Void = { _ in }
    /// A row's button, or Space on its row: the move the read names (Answer, Unblock), through the ticket page's path.
    var perform: (HomeLists.Row) -> Void = { _ in }
}

/// Home in a scroll view, laid out for the width it gets (TP-1499).
struct HomeView: View {
    let lists: HomeLists
    let actions: HomeActions

    var body: some View {
        ScrollView {
            HomeBody(lists: lists, actions: actions)
        }
    }
}

/// Home (TP-1499, `docs/design/director-window-and-home.md` § Home): two tree lists and nothing else, "In progress"
/// (an epic's tickets one step in under its row) and "Queue" (a ticket one step in under the ticket it waits on, past
/// two steps folded into a pill), each with its title in the sentence style and left out when it has no entry. The
/// arrow keys walk the rows of both lists in order, Return opens the row, Space presses its button, Right and Left
/// open and fold a branch. Outside the scroll view, so it also renders offscreen.
struct HomeBody: View {
    let lists: HomeLists
    let actions: HomeActions
    /// The queue's chains opened by their pill, kept while the page is open.
    @State private var opened: Set<String>
    @State private var progressSelection: TreeKey<String>?
    @State private var queueSelection: TreeKey<String>?
    @State private var progressFocused = false
    @State private var queueFocused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `opened` and `selection` draw a chain open and a row picked at first, for a snapshot.
    init(lists: HomeLists, actions: HomeActions = HomeActions(), opened: Set<String> = [], selection: TreeKey<String>? = nil) {
        self.lists = lists
        self.actions = actions
        _opened = State(initialValue: opened)
        let inProgress = selection.map { key in TreeLines.lines(lists.progress).contains { $0.key == key } } ?? false
        _progressSelection = State(initialValue: inProgress ? selection : nil)
        _queueSelection = State(initialValue: inProgress ? nil : selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !lists.progress.isEmpty {
                title(HomeLists.progressTitle)
                TreeList(
                    lists.progress, foldDepth: nil, opened: .constant([]), selection: $progressSelection, open: open,
                    leave: { offset in if offset > 0 { enterQueue(last: false) } }, focus: $progressFocused
                ) { id, state in
                    rowView(id, state: state)
                }
                .onKeyPress(.space) { press(progressSelection) }
            }
            if !lists.queue.isEmpty {
                title(HomeLists.queueTitle)
                    .padding(.top, lists.progress.isEmpty ? 0 : DesignTokens.Space.s8)
                TreeList(
                    lists.queue, opened: $opened, selection: $queueSelection, open: open,
                    leave: { offset in if offset < 0 { enterProgress() } }, focus: $queueFocused
                ) { id, state in
                    rowView(id, state: state)
                }
                .onKeyPress(.space) { press(queueSelection) }
            }
        }
        .padding(DesignTokens.Space.s6)
        .frame(maxWidth: DesignTokens.Layout.homeMaxWidth, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
        // A row the read moves goes to its new place with the catalog's enter motion; the rows around it stay put.
        .animation(DesignTokens.Motion.entering(reduceMotion: reduceMotion).map(Self.animation), value: lists)
    }

    private static func animation(_ timing: DesignTokens.Motion.Timing) -> Animation {
        switch timing {
        case let .spring(duration, bounce): .spring(duration: duration, bounce: bounce)
        case let .eased(duration): .easeInOut(duration: duration)
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .textStyle(.sentence)
            .foregroundStyle(DesignTokens.TextColor.primary.color)
            .padding(.leading, DesignTokens.Space.s3)
            .padding(.bottom, DesignTokens.Space.s3)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func rowView(_ id: String, state: TreeRowState) -> some View {
        if let row = lists.row(id) {
            HomeRow(row: row, state: state, open: { open(id) }, perform: { actions.perform(row) })
        }
    }

    /// A row opens its ticket's page, or an epic's row Initiatives on the epic.
    private func open(_ id: String) {
        guard let row = lists.row(id) else { return }
        if row.isEpic {
            if let issueID = row.issueID { actions.openEpic(issueID) }
        } else {
            actions.openTicket(row.identifier)
        }
    }

    /// Space on a row with a button presses it.
    private func press(_ key: TreeKey<String>?) -> KeyPress.Result {
        guard case let .row(id)? = key, let row = lists.row(id), let move = row.move, move.reason == nil else { return .ignored }
        actions.perform(row)
        return .handled
    }

    /// Down past In progress's last row: the queue's first line, with the keyboard.
    private func enterQueue(last: Bool) {
        guard !lists.queue.isEmpty else { return }
        queueSelection = TreeLines.end(TreeLines.lines(lists.queue, foldDepth: DesignTokens.Tree.foldDepth, opened: opened), last: last)
        progressSelection = nil
        queueFocused = true
    }

    /// Up past the queue's first line: In progress's last row, with the keyboard.
    private func enterProgress() {
        guard !lists.progress.isEmpty else { return }
        progressSelection = TreeLines.end(TreeLines.lines(lists.progress), last: true)
        queueSelection = nil
        progressFocused = true
    }
}

/// One row of Home (the catalog's `homeRow`, `epicRow`): one line, 34 pt. The state glyph (the live dot while a run
/// works), the identifier, the title cut with an ellipsis; at the right the ticket a queue root comes after, its epic as
/// a chip, the situation as a small badge, the move when the ticket needs the Director, and how long, in one column.
/// An epic's row carries its progress strip and "4 of 9" instead.
struct HomeRow: View {
    let row: HomeLists.Row
    var state = TreeRowState(selected: false, focused: false)
    var open: () -> Void = {}
    var perform: () -> Void = {}

    var body: some View {
        Row(
            row.title, identifier: row.identifier, lead: lead, value: row.value, valueWidth: DesignTokens.Row.homeValueWidth,
            selected: state.selected, focused: state.focused, open: open, opensOnClick: true
        ) {
            if let after = row.after {
                HStack(spacing: DesignTokens.Space.s1) {
                    Image(systemName: "arrow.right")
                        .font(DesignTokens.TypeStyle.caption.font)
                        .foregroundStyle(DesignTokens.TextColor.tertiary.color)
                    RowValue(after)
                }
                .help(HomeLists.Row.afterHelp(after))
            }
            if let epic = row.epic { Chip(epic, kind: .epic) }
            if let strip = row.strip {
                ProgressStrip(strip, label: row.value).frame(width: DesignTokens.ProgressStrip.compactWidth)
            }
            if let badge = row.badge { Badge(status: badge.status, word: badge.word, size: .small) }
            if let move = row.move {
                Button(move.title, action: perform)
                    .directorButton(.primary, size: .small, disabledReason: move.reason)
            }
        }
        .help(row.isEpic ? "Open \(row.identifier) in Initiatives" : "Open \(row.identifier)")
    }

    private var lead: RowLead {
        switch row.lead {
        case .live: .dot(.working, live: true)
        case let .status(status): .status(status)
        case .waiting: .glyph("clock", DesignTokens.TextColor.secondary)
        case .epic: .glyph(SymphonyView.initiatives.symbol, DesignTokens.TextColor.secondary)
        }
    }
}

// MARK: - C11: meters

struct MeterView: View {
    let meter: Overview.Meter

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.label).font(DesignTokens.TypeStyle.body.font)
                Spacer(minLength: DesignTokens.Space.s2)
                Text(meter.value)
                    .font(DesignTokens.TypeStyle.secondary.font)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            if let fraction = meter.fraction {
                MeterBar(fraction: fraction, tint: tint)
            }
            if let note = meter.note {
                Text(note)
                    .font(DesignTokens.TypeStyle.caption.font)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meter.accessibilityLabel + (meter.note.map { ", \($0)" } ?? ""))
    }

    private var tint: Color {
        switch meter.level {
        case .normal: DesignTokens.ColorToken.accent.color
        case .near: DesignTokens.Status.you.tint
        case .atLimit: DesignTokens.Status.problem.tint
        }
    }
}

/// A meter's bar: the fill carries the level, on a track that is a light step of the same hue (design system §3.3).
/// Drawn rather than a `Gauge`, whose AppKit control doesn't render offscreen.
struct MeterBar: View {
    let fraction: Double
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.2))
                Capsule()
                    .fill(tint)
                    .frame(width: max(proxy.size.width * fraction, fraction > 0 ? proxy.size.height : 0))
            }
        }
        .frame(height: 6)
        .animation(reduceMotion ? nil : .standard, value: fraction)
        .accessibilityHidden(true)
    }
}
