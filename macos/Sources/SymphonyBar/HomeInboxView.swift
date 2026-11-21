import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

// TP-1454: the Inbox's drawer and the window's status bar. Home's top, the Inbox's items answered in place, gave way
// to Home's two lists (TP-1499): what needs the Director is the rows there that carry a button.

/// The Inbox's drawer: the window's inspector on Home and on a ticket page, holding the review of the item selected,
/// or a peek (N4) opened from its chips, whose Close returns to the review.
struct InboxDrawerPresenter: ViewModifier {
    @ObservedObject var model: SymphonyWindowModel

    func body(content: Content) -> some View {
        content.inspector(isPresented: $model.inboxDrawerShown) {
            InboxDrawer(model: model)
                .inspectorColumnWidth(
                    min: PeekPresentation.minInspectorWidth,
                    ideal: HomeInbox.drawerIdealWidth,
                    max: HomeInbox.drawerMaxWidth
                )
        }
    }
}

/// The drawer's content: the peek while one is open, else the review of the selected item, with Close.
struct InboxDrawer: View {
    @ObservedObject var model: SymphonyWindowModel

    var body: some View {
        if model.peek.isShown {
            PeekView(model: model)
        } else if let list = model.inboxList, let item = list.selection(model.inboxSelection) {
            VStack(spacing: 0) {
                InboxDrawerHeader(title: HomeInbox.drawerTitle, close: { model.inboxDrawerShown = false })
                Divider()
                ScrollView {
                    InboxReviewBody(
                        item: item,
                        picks: model.picks(for: item.id),
                        pick: { model.pick($0, decision: $1, itemID: item.id) },
                        writeIn: { model.writeIn($0, decision: $1, itemID: item.id) },
                        perform: { model.perform($0, on: item) },
                        // A Question on Symphony itself opens no ticket page.
                        openTicket: { if !item.isSubject { model.openTicket(item.identifier) } },
                        openMention: model.openPeek,
                        openMentionDirectly: model.openMentionDirectly,
                        narrow: true,
                        now: model.overviewState?.generatedAt ?? Date(),
                        evidence: WatcherEvidence(item: item, watch: model.watchState.watches[item.identifier]),
                        state: model.overviewState?.snapshot
                    )
                }
                .modifier(RememberedScroll(offset: model.inboxScroll[item.id], remember: { model.inboxScroll[item.id] = $0 }))
                // A new item starts at its own top, with its own picks.
                .id(item.id)
                .questionKeys({ item.optionIndex(forKey: $0) }) { model.pick($0, decision: 0, itemID: item.id) }
            }
        } else {
            VStack(spacing: 0) {
                InboxDrawerHeader(title: HomeInbox.drawerTitle, close: { model.inboxDrawerShown = false })
                Divider()
                if model.inboxList != nil {
                    InboxEmpty(hiddenLine: model.inboxList?.hiddenLine)
                } else {
                    EmptyState(title: "Reading the Inbox…", symbol: SymphonyView.inbox.symbol, showsSpinner: true)
                }
            }
        }
    }
}

/// The drawer's title and its Close (Esc).
struct InboxDrawerHeader: View {
    let title: String
    let close: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            Text(title)
                .font(DesignTokens.TypeStyle.heading.font)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: DesignTokens.Space.s2)
            Button(action: close) { Label(PeekNavigation.closeTitle, systemImage: "xmark") }
                .labelStyle(.iconOnly)
                .directorButton(.quiet, size: .small)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
        }
        .padding(.horizontal, DesignTokens.Space.s4)
        .padding(.vertical, DesignTokens.Space.s2)
    }
}

/// C17: the Inbox's consequence sheets, from Home's rows, the drawer and the ticket page's Question.
struct InboxSheetPresenter: ViewModifier {
    @ObservedObject var model: SymphonyWindowModel

    func body(content: Content) -> some View {
        content.sheet(item: $model.inboxSheet) { sheet in
            ConsequenceSheetView(
                sheet: sheet,
                working: model.inboxMoveInFlight,
                error: model.inboxMoveError,
                cancel: model.cancelSheet,
                confirm: { reason in model.confirm(sheet, reason: reason) }
            )
            .pointerButtons()
        }
    }
}

// MARK: - The status line

/// The window's status line (TP-1498): the dispatch control, then what is in progress, queued and needs the Director,
/// the build and the connection.
struct WindowStatusBar: View {
    @ObservedObject var model: SymphonyWindowModel
    @ObservedObject var client: LiveAPIClient
    /// When the last state arrived, for the health line's help: the status line alone draws again each poll (TP-1480).
    @ObservedObject var heartbeat: StateHeartbeat

    init(model: SymphonyWindowModel, client: LiveAPIClient) {
        self.model = model
        self.client = client
        heartbeat = client.heartbeat
    }

    var body: some View {
        StatusLine(model.healthLine, onAction: { model.onAction($0) }) {
            DispatchControlButton(model: model, client: client)
        }
    }
}
