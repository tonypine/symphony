import SwiftUI
import SymphonyBarCore

// Factory › Providers (TP-1534), as the catalog draws it (`providersPage`, `.ini.prov`): the providers as List cards
// in a column on the left, In use then Not in use, and beside them the picked provider's page: its id and Pause or
// Resume, its name, its state as a Situation line, then its Usage as one-line Progress meters and its facts as a
// Key-value list, each block drawn only when it has content. Built from the shared List card, Button, Progress meter,
// Key-value list, Status dot and titled panel (TP-1530).

/// What the page asks of whoever holds it.
public struct ProvidersPageActions {
    /// Picks the provider whose page shows, by id.
    public var select: (String) -> Void
    /// Sends Pause or Resume.
    public var send: (ControlAction) -> Void

    public init(select: @escaping (String) -> Void, send: @escaping (ControlAction) -> Void) {
        self.select = select
        self.send = send
    }

    /// Actions that do nothing, for a still picture.
    public static var none: ProvidersPageActions { ProvidersPageActions(select: { _ in }, send: { _ in }) }
}

/// The page: the list and the picked provider's page, each scrolling on its own.
public struct ProvidersPageView: View {
    let page: ProvidersPage
    let selection: String?
    let actions: ProvidersPageActions
    /// A control is on its way: the button waits for its answer.
    let sending: Bool
    /// Snapshots draw both columns unscrolled, at their whole height: a picture renderer draws a scroll view empty.
    let scrolls: Bool

    public init(
        page: ProvidersPage, selection: String?, actions: ProvidersPageActions, sending: Bool = false, scrolls: Bool = true
    ) {
        self.page = page
        self.selection = selection
        self.actions = actions
        self.sending = sending
        self.scrolls = scrolls
    }

    public var body: some View {
        let tokens = DesignTokens.ProvidersPage.self
        HStack(alignment: .top, spacing: tokens.columnGap) {
            column { list }
                .frame(width: tokens.listWidth)
            column {
                if let detail = page.detail(selection) {
                    ProviderDetailView(detail: detail, actions: actions, sending: sending)
                        .frame(maxWidth: tokens.mainMaxWidth, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.top, tokens.top)
        .padding(.horizontal, tokens.sides)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let padded = content().padding(.bottom, DesignTokens.ProvidersPage.bottom)
        if scrolls {
            ScrollView { padded.frame(maxWidth: .infinity, alignment: .topLeading) }
                .scrollClipDisabled()
        } else {
            padded
        }
    }

    private var list: some View {
        let tokens = DesignTokens.ProvidersPage.self
        let picked = page.selected(selection)?.id
        return VStack(alignment: .leading, spacing: tokens.groupGap) {
            ForEach(page.sections) { section in
                VStack(alignment: .leading, spacing: ZoneTitle.gap) {
                    ZoneTitle(section.title)
                    VStack(alignment: .leading, spacing: tokens.cardGap) {
                        ForEach(section.cards) { card in
                            ListCard(
                                ListCardContent(
                                    title: card.title, fact: card.fact, status: card.status, statusLine: card.statusLine, live: card.live
                                ),
                                selected: card.id == picked,
                                action: { actions.select(card.id) }
                            )
                        }
                    }
                }
            }
        }
        .onMoveCommand { direction in
            let step = direction == .up ? -1 : direction == .down ? 1 : 0
            guard step != 0, let id = page.id(after: selection, step: step) else { return }
            actions.select(id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SymphonyView.providers.title)
    }
}

/// The picked provider's page: its head, then Usage when Symphony reads its windows, then Access.
struct ProviderDetailView: View {
    let detail: ProvidersPage.Detail
    let actions: ProvidersPageActions
    var sending = false

    var body: some View {
        let tokens = DesignTokens.ProvidersPage.self
        VStack(alignment: .leading, spacing: tokens.blockGap) {
            head
                .padding(.bottom, tokens.headBottom)
            if !detail.usage.isEmpty {
                TitledPanel(title: ProvidersPage.usageTitle, spacing: tokens.meterGap) {
                    ForEach(detail.usage) { meter in
                        ProgressMeter(line: meter.label, percent: meter.percent, resets: meter.resets)
                    }
                }
            }
            if !detail.facts.isEmpty {
                TitledPanel(title: ProvidersPage.accessTitle) {
                    KeyValueList {
                        ForEach(detail.facts) { fact in
                            KeyValueRow(fact.label, text: fact.value)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(detail.name)
    }

    private var head: some View {
        let tokens = DesignTokens.ProvidersPage.self
        return VStack(alignment: .leading, spacing: tokens.headGap) {
            HStack(spacing: DesignTokens.Space.s3) {
                Text(detail.id)
                    .textStyle(.secondary)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                if let move = detail.move, let action = detail.action {
                    Button(move.title) { if !sending { actions.send(action) } }
                        .directorButton(move == .resume ? .primary : .secondary, size: tokens.control, glyph: move.glyph)
                        .accessibilityLabel("\(move.title) \(detail.name)")
                }
            }
            .frame(minHeight: tokens.idLineHeight)
            Text(detail.name)
                .textStyle(.title)
                .foregroundStyle(DesignTokens.TextColor.primary.color)
                .accessibilityAddTraits(.isHeader)
            ProviderSituationLine(state: detail.state)
        }
    }
}

/// The catalog's Situation line (`situation()`, `.situation`) as a provider's page draws it: the status glyph and the
/// word in the status's colour, the cause, and what waits on it in the secondary colour, wrapping at the reading
/// measure. The app's own `SituationLine` reads a ticket's situation kinds; a provider's states are the catalog's
/// roles (Available, Paused, Limit reached, Not in use), so the line is drawn here from the status. VoiceOver reads
/// it as one sentence.
struct ProviderSituationLine: View {
    let state: ProvidersPage.State

    var body: some View {
        let tokens = DesignTokens.ProvidersPage.self
        HStack(alignment: .firstTextBaseline, spacing: tokens.situationGap) {
            Image(systemName: state.status.symbol)
                .resizable()
                .scaledToFit()
                .frame(width: tokens.glyph, height: tokens.glyph)
                .foregroundStyle(state.status.tint)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + tokens.glyph / 4 }
            Text(state.word)
                .fontWeight(.semibold)
                .foregroundStyle(state.status.text)
                .fixedSize()
            reading
                .frame(maxWidth: DesignTokens.Measure.reading, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textStyle(.body)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.spoken)
    }

    /// The cause, then what waits on it in the secondary colour.
    private var reading: Text {
        let cause = Text(state.cause).foregroundStyle(DesignTokens.TextColor.primary.color)
        guard let waits = state.waits else { return cause }
        return Text("\(cause) \(Text(waits).foregroundStyle(DesignTokens.TextColor.secondary.color))")
    }
}
