import SwiftUI
import SymphonyBarCore

// Factory › Providers (TP-1534), as the catalog draws it (`providersPage`, `.ini.prov`): the providers as List cards
// in a column on the left, In use then Not in use, and beside them the picked provider's page: its id and Pause or
// Resume, its name, its state as a Situation line, then its Usage as one-line Progress meters and its facts as a
// Key-value list, each block drawn only when it has content. Built from the shared List card, Button, Progress meter,
// Key-value list, Status dot and titled panel (TP-1530). A provider set up with an API key (TP-1540) has a Key
// block between its head and Usage: the key in the Text field's secure form, Test connection, Enable or Disable and
// Remove Key on one line, and the test's result as a one-line Situation line under it. A provider whose usage Symphony
// reads (TP-1535) has "Stop new runs at" and its pop-up on one line under its meters, after a separator (`.use-set`),
// and each meter's stop mark at that reserve.

/// What the page asks of whoever holds it.
public struct ProvidersPageActions {
    /// Picks the provider whose page shows, by id.
    public var select: (String) -> Void
    /// Sends Pause or Resume.
    public var send: (ControlAction) -> Void
    /// The Director types in a provider's key field: the provider's id and the text.
    public var editKey: (String, String) -> Void
    /// Test connection on a provider's key.
    public var testKey: (String) -> Void
    /// Enable (true) or Disable (false) a provider.
    public var setEnabled: (String, Bool) -> Void
    /// Remove Key on a provider.
    public var removeKey: (String) -> Void
    /// "Stop new runs at" on a provider: its id and the share in whole percent, nil for no reserve.
    public var setReserve: (String, Int?) -> Void

    public init(
        select: @escaping (String) -> Void, send: @escaping (ControlAction) -> Void,
        editKey: @escaping (String, String) -> Void = { _, _ in }, testKey: @escaping (String) -> Void = { _ in },
        setEnabled: @escaping (String, Bool) -> Void = { _, _ in }, removeKey: @escaping (String) -> Void = { _ in },
        setReserve: @escaping (String, Int?) -> Void = { _, _ in }
    ) {
        self.select = select
        self.send = send
        self.editKey = editKey
        self.testKey = testKey
        self.setEnabled = setEnabled
        self.removeKey = removeKey
        self.setReserve = setReserve
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

/// The picked provider's page: its head, then its Key block when it takes a key, then Usage when Symphony reads its
/// windows, then Access.
struct ProviderDetailView: View {
    let detail: ProvidersPage.Detail
    let actions: ProvidersPageActions
    var sending = false

    var body: some View {
        let tokens = DesignTokens.ProvidersPage.self
        VStack(alignment: .leading, spacing: tokens.blockGap) {
            head
                .padding(.bottom, tokens.headBottom)
            if let key = detail.key {
                ProviderKeyBlock(id: detail.id, name: detail.name, key: key, actions: actions)
            }
            if !detail.usage.isEmpty || detail.reserve != nil {
                TitledPanel(title: ProvidersPage.usageTitle, spacing: tokens.meterGap) {
                    ForEach(detail.usage) { meter in
                        ProgressMeter(line: meter.label, percent: meter.percent, stop: meter.stop, resets: meter.resets)
                    }
                    if let reserve = detail.reserve {
                        ProviderReserveRow(id: detail.id, name: detail.name, reserve: reserve, ruled: !detail.usage.isEmpty, actions: actions)
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

/// The Key block (TP-1540): the key masked, Test connection while the field holds a key and no test runs, then Enable once a test passed or Disable while the
/// provider is on, and Remove Key while a key is stored, on one line; under it the test's result on one line, or the
/// test's spinner while it runs.
struct ProviderKeyBlock: View {
    let id: String
    let name: String
    let key: ProvidersPage.KeyBlock
    let actions: ProvidersPageActions

    var body: some View {
        let tokens = DesignTokens.ProvidersPage.self
        TitledPanel(title: ProvidersPage.keyTitle, spacing: tokens.meterGap) {
            HStack(spacing: DesignTokens.Space.s3) {
                DirectorTextField(
                    nil, text: Binding(get: { key.text }, set: { actions.editKey(id, $0) }), placeholder: key.variable,
                    size: tokens.control, mono: true, secure: true, onSubmit: { if key.canTest { actions.testKey(id) } }
                )
                .accessibilityLabel("\(name) key")
                if key.canTest {
                    Button(ProvidersPage.testTitle) { actions.testKey(id) }
                        .directorButton(.secondary, size: tokens.control)
                        .fixedSize()
                }
                if let on = key.toggle {
                    Button(on ? ProvidersPage.enableTitle : ProvidersPage.disableTitle) { actions.setEnabled(id, on) }
                        .directorButton(on ? .primary : .secondary, size: tokens.control)
                        .fixedSize()
                        .accessibilityLabel("\(on ? ProvidersPage.enableTitle : ProvidersPage.disableTitle) \(name)")
                }
                if key.stored {
                    Button(ProvidersPage.removeKeyTitle) { actions.removeKey(id) }
                        .directorButton(.secondary, size: tokens.control)
                        .fixedSize()
                }
            }
            if key.testing {
                ProgressView().controlSize(.small)
            } else if let result = key.result {
                ProviderSituationLine(state: ProvidersPage.state(result), oneLine: true)
            }
        }
    }
}

/// "Stop new runs at" (TP-1535, `.use-set`): the word in the secondary colour and a small pop-up of shares, then No
/// reserve, on one line under the meters and a separator. Picking one saves it to `symphony.yml` once `symphony check`
/// passes; the pop-up waits while a save is on its way.
struct ProviderReserveRow: View {
    let id: String
    let name: String
    let reserve: ProvidersPage.ReserveControl
    /// Meters stand above it: a separator parts them.
    var ruled = true
    let actions: ProvidersPageActions

    var body: some View {
        let tokens = DesignTokens.ProvidersPage.self
        VStack(alignment: .leading, spacing: tokens.reserveTop) {
            if ruled { HairlineDivider() }
            HStack(spacing: tokens.reserveGap) {
                Text(ProvidersPage.reserveTitle)
                    .textStyle(.secondary)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .fixedSize()
                PopUp(
                    nil,
                    selection: Binding(get: { reserve.percent }, set: { if !reserve.saving { actions.setReserve(id, $0) } }),
                    choices: reserve.choices.map { PopUpChoice(Int?.some($0), ProvidersPage.ReserveControl.title($0)) }
                        + [PopUpChoice(Int?.none, ProviderReserve.noneTitle, separatorBefore: true)],
                    size: tokens.reserveControl,
                    accessibilityLabel: "\(ProvidersPage.reserveTitle), \(name)"
                )
                .fixedSize()
                if reserve.saving {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
            }
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
    /// On one line, cut short at its end: a key test's result.
    var oneLine = false

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
                .lineLimit(oneLine ? 1 : nil)
                .truncationMode(.tail)
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
