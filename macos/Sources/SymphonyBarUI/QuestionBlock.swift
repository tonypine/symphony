import AppKit
import SwiftUI
import SymphonyBarCore

// The catalog's Question block and Decision sheet (`docs/design/director-ticket-page.md` §4): a Question as the
// Director answers it, in the Inbox's review (C15), on the ticket page and on Home, the same way everywhere. The block
// is the callout (N5), what happened (N6), the option cards (N7) with their trade-off tags (N8), the own-words card
// and its field (N11), and a Send that repeats the picked answer; the sheet holds every open Question of a ticket with
// one Send at its foot.

// MARK: - Question block

/// One Question: its callout, what happened and what waits, what the watcher found (`evidence`, the Inbox's S16), the
/// option cards and the own-words card, the steps of an older request, and with `send` a Send under them. Picking the
/// own-words card unfolds its field and puts the keyboard in it.
public struct QuestionBlock<Evidence: View>: View {
    let action: InboxReview.Action
    var picks: DecisionPicks
    /// The Question's index in `picks`: 0 for a request, its place for a plan's or the sheet's Questions.
    var index: Int
    var pick: (Int) -> Void
    var writeIn: (String) -> Void
    /// True when the Question can be answered here: its cards are picked, and the own-words card follows them.
    var answerable: Bool
    var narrow: Bool
    /// The callout's kicker: "Your decision", or "Question 1 of 2" in the sheet.
    var kicker: String?
    /// True when the number keys pick: the Options card says so and each card shows its key.
    var showsKeys: Bool
    /// Sends the answer; nil where Send lives elsewhere (the Inbox's toolbar, the decision sheet's foot).
    var send: (() -> Void)?
    /// Takes the first card's focus, as the decision sheet does when it opens.
    var firstAnswerFocus: FocusState<Bool>.Binding?
    let evidence: Evidence
    @FocusState private var writeInFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        action: InboxReview.Action,
        picks: DecisionPicks = DecisionPicks(),
        index: Int = 0,
        pick: @escaping (Int) -> Void = { _ in },
        writeIn: @escaping (String) -> Void = { _ in },
        answerable: Bool = true,
        narrow: Bool = false,
        kicker: String? = nil,
        showsKeys: Bool = true,
        send: (() -> Void)? = nil,
        firstAnswerFocus: FocusState<Bool>.Binding? = nil,
        @ViewBuilder evidence: () -> Evidence
    ) {
        self.action = action
        self.picks = picks
        self.index = index
        self.pick = pick
        self.writeIn = writeIn
        self.answerable = answerable
        self.narrow = narrow
        self.kicker = kicker
        self.showsKeys = showsKeys
        self.send = send
        self.firstAnswerFocus = firstAnswerFocus
        self.evidence = evidence()
    }

    private var writeInPicked: Bool { answerable && action.isWriteIn(picks, decision: index) }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
            if let question = action.question {
                if action.options.isEmpty {
                    Card(title: "Question") { ChipText(text: question) }
                } else {
                    QuestionCallout(question: question, kicker: kicker)
                }
            }
            StoryCard(paragraphs: action.whyParagraphs, ifUnanswered: action.ifUnanswered)
            evidence
            if !action.options.isEmpty {
                Card(title: "Options", hint: answerable && showsKeys && !narrow ? action.keyHint : nil) {
                    OptionCardList(
                        title: "Options",
                        cards: OptionCard.cards(for: action, writeIn: answerable),
                        selected: answerable ? action.pickedIndex(picks, decision: index) : nil,
                        selectable: answerable,
                        narrow: narrow,
                        showsKeys: answerable && showsKeys,
                        firstFocus: firstAnswerFocus,
                        choose: pick
                    )
                    if writeInPicked {
                        WriteInField(initialText: picks.writeIns[index] ?? "", commit: writeIn, focused: $writeInFocused)
                            .id(WriteInField.scrollID)
                            .transition(.opacity)
                    }
                }
                // The own-words field unfolds on the fold's spring; under Reduce Motion it is there at once.
                .animation(.motion(.fold, reduceMotion: reduceMotion), value: writeInPicked)
                // Picking the own-words card, by a click or its number key, puts the keyboard in its field.
                .onChange(of: writeInPicked) { _, picked in writeInFocused = picked }
                if answerable, let send {
                    QuestionSendArea(send: QuestionSend(question: action, decision: index, picks: picks), action: send)
                }
            }
            if !action.steps.isEmpty {
                Card(title: "Steps") {
                    VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                        ForEach(Array(action.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                                Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                                ChipText(text: step)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }
}

extension QuestionBlock where Evidence == EmptyView {
    public init(
        action: InboxReview.Action,
        picks: DecisionPicks = DecisionPicks(),
        index: Int = 0,
        pick: @escaping (Int) -> Void = { _ in },
        writeIn: @escaping (String) -> Void = { _ in },
        answerable: Bool = true,
        narrow: Bool = false,
        kicker: String? = nil,
        showsKeys: Bool = true,
        send: (() -> Void)? = nil,
        firstAnswerFocus: FocusState<Bool>.Binding? = nil
    ) {
        self.init(
            action: action, picks: picks, index: index, pick: pick, writeIn: writeIn, answerable: answerable, narrow: narrow,
            kicker: kicker, showsKeys: showsKeys, send: send, firstAnswerFocus: firstAnswerFocus
        ) { EmptyView() }
    }
}

/// The type sizes of the Question's parts.
public enum DecisionType {
    /// N5's question.
    public static let questionFont = NSFont.systemFont(ofSize: 16, weight: .semibold)
    /// N7's label.
    public static let optionLabel = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
    /// N8's text.
    public static let tag = Font.system(size: 12)
    public static let tagFont = NSFont.systemFont(ofSize: 12)
}

/// N5: the Question under the title, labelled "Your decision" (or its place in the sheet), on `surface.raised` tinted
/// with `status.you` and a leading bar.
public struct QuestionCallout: View {
    let question: String
    var kicker: String?

    public init(question: String, kicker: String? = nil) {
        self.question = question
        self.kicker = kicker
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            Text(kicker ?? "Your decision")
                .textCase(.uppercase)
                .font(DesignTokens.TypeStyle.label.font)
                .foregroundStyle(DesignTokens.Status.you.tint)
            ChipText(text: question, font: DecisionType.questionFont)
        }
        .padding(.vertical, DesignTokens.Space.s3)
        .padding(.horizontal, DesignTokens.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            DesignTokens.Surface.raised.color
            DesignTokens.Status.you.tint.opacity(0.10)
        }
        .overlay(alignment: .leading) {
            DesignTokens.Status.you.tint.frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous))
        // Its chips are links inside the question, so the callout contains them rather than reading as one.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

/// N6: what happened, in at most two paragraphs, and what waits if nobody answers. Nothing is drawn without either.
public struct StoryCard: View {
    let paragraphs: [String]
    let ifUnanswered: String?

    public init(paragraphs: [String], ifUnanswered: String?) {
        self.paragraphs = paragraphs
        self.ifUnanswered = ifUnanswered
    }

    public var body: some View {
        if !paragraphs.isEmpty || ifUnanswered != nil {
            Card(title: "What happened") {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        ChipText(text: paragraph)
                    }
                    if let ifUnanswered {
                        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(DesignTokens.Status.you.tint)
                                .accessibilityHidden(true)
                            ChipText(text: ifUnanswered, lead: "If you don't answer:")
                        }
                    }
                }
                .font(DesignTokens.TypeStyle.body.font)
            }
        }
    }
}

// MARK: - Option cards

/// A decision's N7 cards stacked, one radio group for VoiceOver: each option reads "Option 1 of 3, its label,
/// recommended, selected", then its effect and its tags.
public struct OptionCardList: View {
    /// The group's name for VoiceOver.
    let title: String
    let cards: [OptionCard]
    let selected: Int?
    let selectable: Bool
    var narrow: Bool
    /// True when the number keys pick: each card shows its key.
    var showsKeys: Bool
    /// Takes the first card's focus.
    var firstFocus: FocusState<Bool>.Binding?
    let choose: (Int) -> Void

    public init(
        title: String,
        cards: [OptionCard],
        selected: Int?,
        selectable: Bool,
        narrow: Bool = false,
        showsKeys: Bool = false,
        firstFocus: FocusState<Bool>.Binding? = nil,
        choose: @escaping (Int) -> Void
    ) {
        self.title = title
        self.cards = cards
        self.selected = selected
        self.selectable = selectable
        self.narrow = narrow
        self.showsKeys = showsKeys
        self.firstFocus = firstFocus
        self.choose = choose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            ForEach(cards) { card in
                OptionCardView(
                    card: card, selected: card.index == selected, selectable: selectable, narrow: narrow, showsKey: showsKeys && !narrow,
                    focus: card.index == 0 ? firstFocus : nil
                ) {
                    choose(card.index)
                }
            }
        }
        .accessibilityRepresentation {
            Picker(title, selection: Binding(get: { selected ?? -1 }, set: choose)) {
                ForEach(cards) { card in
                    Text(card.accessibilityLabel(selected: card.index == selected)).tag(card.index)
                }
            }
            .pickerStyle(.radioGroup)
            .disabled(!selectable)
        }
    }
}

/// One option card, live: a button whose face follows the pointer, the press and keyboard focus. A card that can't be
/// picked is its face at rest.
private struct OptionCardView: View {
    let card: OptionCard
    let selected: Bool
    let selectable: Bool
    let narrow: Bool
    let showsKey: Bool
    let focus: FocusState<Bool>.Binding?
    let choose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if selectable {
            let button = Button(action: choose) { Text(card.label) }
                .buttonStyle(OptionCardButtonStyle(card: card, selected: selected, narrow: narrow, showsKey: showsKey))
                .focusEffectDisabled()
            if let focus {
                button.focused(focus)
            } else {
                button
            }
        } else {
            OptionCardFace(card: card, state: .rest, selectable: false, narrow: narrow, showsKey: showsKey, reduceMotion: reduceMotion)
        }
    }
}

private struct OptionCardButtonStyle: ButtonStyle {
    let card: OptionCard
    let selected: Bool
    let narrow: Bool
    let showsKey: Bool

    func makeBody(configuration: Configuration) -> some View {
        Live(card: card, selected: selected, narrow: narrow, showsKey: showsKey, pressed: configuration.isPressed)
    }

    private struct Live: View {
        let card: OptionCard
        let selected: Bool
        let narrow: Bool
        let showsKey: Bool
        let pressed: Bool
        @State private var hovered = false
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            OptionCardFace(
                card: card,
                state: DesignTokens.Interaction(hovered: hovered, pressed: pressed, selected: selected, focused: isFocused),
                selectable: true,
                narrow: narrow,
                showsKey: showsKey,
                reduceMotion: reduceMotion
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous))
            .onHover { hovered = $0 }
        }
    }
}

/// N7's face in one state: a radio, the label on the first line with its Recommended badge and key, the effect under
/// the label, its trade-off tags (N8), and on the recommended card why. Under the pointer it lifts a point on the lift
/// spring and its radio rings in accent; pressed it settles to 99 %; picked it takes the accent ring and tint and its
/// radio fills with a bounce; with keyboard focus the focus ring follows its corners. Reduce Motion keeps it still.
public struct OptionCardFace: View {
    let card: OptionCard
    let state: DesignTokens.Interaction
    let selectable: Bool
    let narrow: Bool
    let showsKey: Bool
    let reduceMotion: Bool

    public init(card: OptionCard, state: DesignTokens.Interaction, selectable: Bool = true, narrow: Bool = false, showsKey: Bool = false, reduceMotion: Bool = false) {
        self.card = card
        self.state = state
        self.selectable = selectable
        self.narrow = narrow
        self.showsKey = showsKey
        self.reduceMotion = reduceMotion
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
        let selected = state.selected
        let raised = state.hovered && !state.pressed
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
            if selectable {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected || state.hovered ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    // The radio fills with a bounce when the card is picked; under Reduce Motion it just fills.
                    .symbolEffect(.bounce, value: selected && !reduceMotion)
            }
            // The effect, tags and reason stack under the label, at its leading edge.
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
                    ChipText(text: card.label, font: DecisionType.optionLabel, selectable: false)
                    if card.recommended && !narrow { RecommendedBadge() }
                    Spacer(minLength: DesignTokens.Space.s2)
                    if showsKey { KeyHint(number: card.number) }
                }
                if card.recommended && narrow { RecommendedBadge() }
                if let effect = card.effect {
                    ChipText(text: effect, color: .secondaryLabelColor, selectable: false)
                }
                if !card.tradeoffs.isEmpty {
                    VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                        ForEach(Array(card.tradeoffs.enumerated()), id: \.offset) { _, tradeoff in
                            TradeoffTag(tradeoff: tradeoff)
                        }
                    }
                    .padding(.top, DesignTokens.Space.s1 / 2)
                }
                if let reason = card.reason {
                    ChipText(text: reason, lead: OptionCard.reasonLead, font: DesignTokens.TypeStyle.callout.nsFont, selectable: false)
                        .padding(.horizontal, DesignTokens.Space.s2)
                        .padding(.vertical, DesignTokens.Space.s1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.mark, style: .continuous))
                        .padding(.top, DesignTokens.Space.s1)
                }
            }
        }
        .padding(DesignTokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.07)) : AnyShapeStyle(DesignTokens.Surface.content.color), in: shape)
        .overlay(
            shape.strokeBorder(
                selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(DesignTokens.Surface.separator.color),
                lineWidth: selected ? DesignTokens.Selection.cardRingWidth : 1
            )
        )
        .contentShape(shape)
        // Only a lifted card casts a shadow, so a card at rest draws as it always has.
        .shadow(color: raised ? Color(nsColor: .shadowColor).opacity(0.16) : .clear, radius: raised ? 8 : 0, y: raised ? 3 : 0)
        .focusRing(state.showsFocusRing, shape)
        .scaleEffect(DesignTokens.Motion.scale(DesignTokens.Motion.cardPressScale, pressed: state.pressed, reduceMotion: reduceMotion))
        .offset(y: -DesignTokens.Motion.lift(hovered: raised, reduceMotion: reduceMotion))
        .animation(.motion(.lift, reduceMotion: reduceMotion), value: state)
    }
}

/// N11's field, under the own-words card once it is picked: a `TextEditor` three lines tall that grows with the text
/// to eight, then scrolls, over the hint that says how the agent reads it. The editor types into the field's own draft,
/// handed to `commit` on each change: bound straight to the window model, a redraw between fast keystrokes put an
/// older text back and lost what was typed. While a sheet covers the window (Send Decision, a peek) the text is a
/// `Text`, which dims with the window as the editor's AppKit view doesn't, and the editor gets the keyboard back after.
public struct WriteInField: View {
    @State private var text: String
    var commit: (String) -> Void
    var focused: FocusState<Bool>.Binding
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot
    @State private var covered = false
    /// Whether the editor had the keyboard before the sheet came up: taking the editor out takes its focus.
    @State private var hadFocus = false

    /// The height of one line of `type.body`.
    private static let lineHeight = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: NSFont.systemFontSize))
    /// The text view's own inset on each side of a line.
    private static let inset: CGFloat = 5
    /// The field's id in the review's scroll view, which scrolls to it once it is picked.
    public static let scrollID = "write-in"

    public init(initialText: String, commit: @escaping (String) -> Void, focused: FocusState<Bool>.Binding) {
        _text = State(initialValue: initialText)
        self.commit = commit
        self.focused = focused
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            // A hidden copy of the text sizes the editor: at least three lines, at most eight.
            Text(text.isEmpty || text.hasSuffix("\n") ? text + " " : text)
                .font(DesignTokens.TypeStyle.body.font)
                .lineLimit(8)
                .padding(.horizontal, Self.inset)
                .frame(maxWidth: .infinity, minHeight: Self.lineHeight * 3, alignment: .topLeading)
                .hidden()
                .overlay(alignment: .topLeading) {
                    if offscreenSnapshot || covered {
                        Text(text).font(DesignTokens.TypeStyle.body.font).padding(.horizontal, Self.inset)
                    } else {
                        editor
                    }
                }
                .padding(DesignTokens.Space.s2)
                .background(DesignTokens.Surface.content.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1)
                )
            Text(OptionCard.writeInHint)
                .font(DesignTokens.TypeStyle.callout.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
        .sheetCover($covered)
        .onChange(of: focused.wrappedValue) { _, isFocused in
            if !covered { hadFocus = isFocused }
        }
        .onChange(of: covered) { _, covered in
            guard !covered, hadFocus else { return }
            // Once the editor is back in the field.
            DispatchQueue.main.async { focused.wrappedValue = true }
        }
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(DesignTokens.TypeStyle.body.font)
            .scrollContentBackground(.hidden)
            .onChange(of: text) { _, text in commit(text) }
            .focused(focused)
            .accessibilityLabel(OptionCard.writeInLabel)
            .accessibilityHint(OptionCard.writeInHint)
    }
}

/// The word "Recommended" in an accent capsule.
public struct RecommendedBadge: View {
    public init() {}

    public var body: some View {
        Text("Recommended")
            .font(DesignTokens.TypeStyle.label.font)
            .padding(.horizontal, DesignTokens.Space.s2)
            .background(Color.accentColor.opacity(0.18), in: Capsule())
            .fixedSize()
    }
}

/// The number key that picks an option, as a key cap.
private struct KeyHint: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(DesignTokens.TypeStyle.caption.font.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 18, minHeight: 18)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.mark, style: .continuous)
                    .strokeBorder(DesignTokens.Surface.separator.color)
            )
            .help("Press \(number) to pick this option")
    }
}

/// N8: what an option gains, costs or risks, as its symbol and words; the text wraps.
private struct TradeoffTag: View {
    let tradeoff: InboxReview.Action.Tradeoff

    var body: some View {
        Label {
            ChipText(text: tradeoff.text, font: DecisionType.tagFont, selectable: false)
        } icon: {
            Image(systemName: tradeoff.kind.symbol).foregroundStyle(tradeoff.kind.status.tint)
        }
        .font(DecisionType.tag)
        .labelStyle(.titleAndIcon)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tradeoff.kind.word): \(tradeoff.text)")
    }
}

// MARK: - Send

/// The Send of a Question block or of the decision sheet, at its trailing edge: the picked answer it repeats ("Your
/// answer"), or how many are answered, the reason it is off while there is nothing to send, and the large primary
/// button.
public struct QuestionSendArea: View {
    let send: QuestionSend
    let action: () -> Void

    public init(send: QuestionSend, action: @escaping () -> Void) {
        self.send = send
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: DesignTokens.Space.s2) {
            if let answer = send.answer {
                line("Your answer", answer)
            } else if send.total > 1 {
                line("Answered", "\(send.answered) of \(send.total)")
            }
            if let refusal = send.refusal {
                Refusal(reason: refusal)
            }
            Button(send.title, action: action)
                .directorButton(.primary, size: .large)
                .disabled(!send.enabled)
                .help(send.refusal ?? send.title)
                .accessibilityHint(send.refusal ?? "")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s2) {
            Text(label).foregroundStyle(.secondary)
            Text(value).bold().lineLimit(2)
        }
        .font(DesignTokens.TypeStyle.callout.font)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Keys

/// The number keys of a Question: 1 to 4 (to 9) pick its options while the keyboard is not in a text field.
public enum QuestionKeys {
    /// The option a key press picks: `optionIndex` of its one character, with no modifier held and the keyboard
    /// outside a text field (`typing`); nil otherwise, so the key goes on to whatever has the keyboard.
    public static func option(for characters: String, modifiers: EventModifiers, typing: Bool, optionIndex: (Character) -> Int?) -> Int? {
        guard modifiers.isEmpty, !typing, characters.count == 1, let key = characters.first else { return nil }
        return optionIndex(key)
    }
}

extension View {
    /// Number keys pick the option `optionIndex` finds for them, handed to `pick`, while the keyboard is in this view
    /// and not in a text field; in a field they type.
    public func questionKeys(_ optionIndex: @escaping (Character) -> Int?, pick: @escaping (Int) -> Void) -> some View {
        onKeyPress(characters: .decimalDigits, phases: .down) { press in
            let typing = NSApp?.keyWindow?.firstResponder is NSText
            guard let option = QuestionKeys.option(for: press.characters, modifiers: press.modifiers, typing: typing, optionIndex: optionIndex) else {
                return .ignored
            }
            pick(option)
            return .handled
        }
    }
}

// MARK: - Decision sheet

/// Every open Question of a ticket: a header with the count and, on a laptop, a close button; the Questions one under
/// the other, scrolling on their own; and one Send at the foot that sends every answered one. When it opens the
/// keyboard goes to the first answer; with one Question its number keys pick.
public struct DecisionSheet: View {
    let questions: [InboxReview.Action]
    let picks: DecisionPicks
    /// The ticket's identifier and title under the header's title.
    var subtitle: String?
    /// Picks option (first) in Question (second).
    let pick: (Int, Int) -> Void
    /// Keeps a Question's own words: (text, Question).
    let writeIn: (String, Int) -> Void
    let send: () -> Void
    /// Closes the sheet; nil for the desktop's column, which stays open and has no close button.
    var close: (() -> Void)?
    var narrow: Bool
    /// Why Send stays off whatever is picked (the ticket page's sheet, until answering from it lands); nil when the
    /// picks decide.
    var sendOff: String?
    @FocusState private var firstAnswer: Bool
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    public init(
        questions: [InboxReview.Action],
        picks: DecisionPicks,
        subtitle: String? = nil,
        pick: @escaping (Int, Int) -> Void,
        writeIn: @escaping (String, Int) -> Void = { _, _ in },
        send: @escaping () -> Void,
        close: (() -> Void)? = nil,
        narrow: Bool = false,
        sendOff: String? = nil
    ) {
        self.questions = questions
        self.picks = picks
        self.subtitle = subtitle
        self.pick = pick
        self.writeIn = writeIn
        self.send = send
        self.close = close
        self.narrow = narrow
        self.sendOff = sendOff
    }

    /// Send under the Questions: the picks' answer, off with `sendOff` when it is set.
    private var sheetSend: QuestionSend {
        var send = QuestionSend(questions: questions, picks: picks)
        if let sendOff { send.refusal = sendOff }
        return send
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // `ImageRenderer` draws no scroll view's content, so a snapshot lays the Questions out from the top.
            if offscreenSnapshot {
                questionList.frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped().layoutPriority(-1)
            } else {
                ScrollView { questionList }
            }
            Divider()
            QuestionSendArea(send: sheetSend, action: send)
                .padding(DesignTokens.Space.s4)
        }
        .frame(maxHeight: .infinity)
        .background(DesignTokens.Surface.window.color)
        .modifier(SheetKeys(questions: questions, pick: pick))
        .onAppear {
            // The keyboard goes to the first answer once the sheet is laid out.
            guard !offscreenSnapshot else { return }
            DispatchQueue.main.async { firstAnswer = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your decisions")
    }

    private var questionList: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s5) {
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                if index > 0 { Divider() }
                QuestionBlock(
                    action: question,
                    picks: picks,
                    index: index,
                    pick: { pick($0, index) },
                    writeIn: { writeIn($0, index) },
                    narrow: narrow,
                    kicker: DecisionSheetLayout.kicker(index: index, count: questions.count),
                    showsKeys: questions.count == 1,
                    firstAnswerFocus: index == 0 ? $firstAnswer : nil
                )
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Question \(index + 1)")
            }
        }
        .padding(DesignTokens.Space.s4)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.s3) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(DesignTokens.Status.you.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(DecisionSheetLayout.title(count: questions.count))
                    .font(DesignTokens.TypeStyle.section.font)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(DesignTokens.TypeStyle.callout.font)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: DesignTokens.Space.s2)
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark")
                }
                .directorButton(.quiet, size: .small)
                .help("Close (Esc)")
                .accessibilityLabel("Close")
            }
        }
        .padding(DesignTokens.Space.s4)
    }
}

/// With one Question in the sheet its number keys pick; with more, which Question a key would answer is unclear, so
/// they don't (the catalog shows no key hints there).
private struct SheetKeys: ViewModifier {
    let questions: [InboxReview.Action]
    let pick: (Int, Int) -> Void

    func body(content: Content) -> some View {
        if questions.count == 1, let question = questions.first {
            content.questionKeys({ question.optionIndex(forKey: $0) }, pick: { pick($0, 0) })
        } else {
            content
        }
    }
}

extension View {
    /// Presents `sheet` as the laptop's decision sheet: `width` wide on the right, over the page dimmed behind it. It
    /// slides in from the right on `motion.sheet` while the page dims on `motion.standard`; Escape or a click on the
    /// dimmed page closes it, and the keyboard goes back to `returnFocus` (the Answer that opened it). Under Reduce
    /// Motion it appears and leaves at once, without sliding.
    public func decisionSheet<Sheet: View>(
        isPresented: Binding<Bool>,
        width: Double = DecisionSheetLayout.laptopWidth,
        returnFocus: FocusState<Bool>.Binding? = nil,
        @ViewBuilder sheet: () -> Sheet
    ) -> some View {
        modifier(DecisionSheetLayer(isPresented: isPresented, width: width, returnFocus: returnFocus, sheet: sheet()))
    }
}

private struct DecisionSheetLayer<Sheet: View>: ViewModifier {
    @Binding var isPresented: Bool
    let width: Double
    let returnFocus: FocusState<Bool>.Binding?
    let sheet: Sheet
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                ZStack(alignment: .trailing) {
                    if isPresented {
                        Color.black.opacity(DecisionSheetLayout.scrimOpacity)
                            .contentShape(Rectangle())
                            .onTapGesture { isPresented = false }
                            .transition(.opacity.animation(.motion(.standard, reduceMotion: reduceMotion)))
                            .accessibilityHidden(true)
                        sheet
                            .frame(width: width)
                            .frame(maxHeight: .infinity)
                            .shadow(color: Color(nsColor: .shadowColor).opacity(0.22), radius: 24, x: -4)
                            .transition(reduceMotion ? .opacity : .move(edge: .trailing))
                            .onExitCommand { isPresented = false }
                            .accessibilityAddTraits(.isModal)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .animation(.motion(.sheet, reduceMotion: reduceMotion), value: isPresented)
            }
            .onChange(of: isPresented) { _, presented in
                guard !presented, let returnFocus else { return }
                // Once the sheet has left, the keyboard goes back to what opened it.
                DispatchQueue.main.async { returnFocus.wrappedValue = true }
            }
    }
}
