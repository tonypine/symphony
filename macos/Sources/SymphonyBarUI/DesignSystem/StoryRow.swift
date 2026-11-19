import SwiftUI
import SymphonyBarCore

/// The catalog's story row (`.story-row`, TP-1500): one sub-ticket of an epic's story on one 36 pt line. Its number in
/// the chain, its mark, its identifier and title, then at the right what matters for its state (`trail`) and an
/// arrow. A landed or waiting one sets its title secondary (`quiet`), a canceled one strikes it. A row being worked on
/// (`current`) sits on the working tint with a ring of the working colour, its number and title stronger, and holds
/// its situation under its title (`under`). It shows hover and the focus ring; a click or Return calls `open`, and
/// it takes keyboard focus, so Tab walks a story's rows. VoiceOver reads it as one button named by `label`.
public struct StoryRow<Under: View, Trail: View>: View {
    let number: Int?
    let mark: RowLead
    let identifier: String
    let title: String
    let quiet: Bool
    let struck: Bool
    let current: Bool
    let label: String
    let state: DesignTokens.Interaction?
    let open: () -> Void
    let under: Under
    let trail: Trail

    @State private var hovered = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        number: Int?, mark: RowLead, identifier: String, title: String, quiet: Bool = false, struck: Bool = false,
        current: Bool = false, label: String, state: DesignTokens.Interaction? = nil, open: @escaping () -> Void,
        @ViewBuilder under: () -> Under, @ViewBuilder trail: () -> Trail
    ) {
        self.number = number
        self.mark = mark
        self.identifier = identifier
        self.title = title
        self.quiet = quiet
        self.struck = struck
        self.current = current
        self.label = label
        self.state = state
        self.open = open
        self.under = under()
        self.trail = trail()
    }

    var shown: DesignTokens.Interaction { state ?? DesignTokens.Interaction(hovered: hovered, focused: focused) }

    public var body: some View {
        let state = shown
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
        let inset = current ? DesignTokens.StoryRow.currentVerticalInset : DesignTokens.StoryRow.verticalInset
        HStack(alignment: current ? .top : .center, spacing: DesignTokens.StoryRow.gap) {
            Text(number.map(String.init) ?? "")
                .font(DesignTokens.TypeStyle.font(
                    size: DesignTokens.TypeStyle.secondary.size,
                    weight: current ? DesignTokens.StoryRow.currentNumberWeight : DesignTokens.StoryRow.numberWeight
                ))
                .monospacedDigit()
                .foregroundStyle((current ? DesignTokens.ColorToken.statusWorkingText : DesignTokens.TextColor.tertiary).color)
                .frame(width: DesignTokens.StoryRow.numberWidth, alignment: .trailing)
            RowLeadMark(lead: mark, glyphSize: DesignTokens.StoryRow.markGlyph)
                .frame(width: DesignTokens.StoryRow.markSize, height: DesignTokens.StoryRow.markSize)
            VStack(alignment: .leading, spacing: DesignTokens.StoryRow.lineGap) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Row.itemGap) {
                    Text(identifier)
                        .textStyle(.rowTitle)
                        .monospacedDigit()
                        .fixedSize()
                        .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    Text(title)
                        .font(DesignTokens.TypeStyle.font(
                            size: DesignTokens.TypeStyle.rowTitle.size,
                            weight: current ? DesignTokens.StoryRow.currentTitleWeight : DesignTokens.Row.titleWeight
                        ))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .strikethrough(struck)
                        .foregroundStyle((quiet ? DesignTokens.TextColor.secondary : DesignTokens.TextColor.primary).color)
                }
                under
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: DesignTokens.StoryRow.gap) { trail }
                .textStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(DesignTokens.TextColor.secondary.color)
                .fixedSize()
                .frame(height: current ? DesignTokens.StoryRow.markSize : nil)
            Image(systemName: "chevron.right")
                .font(DesignTokens.TypeStyle.font(size: DesignTokens.StoryRow.arrowSize, weight: DesignTokens.Row.titleWeight))
                .foregroundStyle(DesignTokens.TextColor.tertiary.color)
                .frame(height: current ? DesignTokens.StoryRow.markSize : nil)
                .accessibilityHidden(true)
        }
        .padding(.vertical, inset)
        .padding(.leading, DesignTokens.StoryRow.leadingInset)
        .padding(.trailing, DesignTokens.StoryRow.trailingInset)
        .frame(maxWidth: .infinity, minHeight: DesignTokens.StoryRow.height, alignment: .leading)
        .background {
            if current {
                shape.fill(DesignTokens.ColorToken.tintWorking.color)
                    .overlay {
                        shape.strokeBorder(
                            DesignTokens.Status.working.tint.opacity(DesignTokens.StoryRow.currentRingOpacity),
                            lineWidth: DesignTokens.StoryRow.currentRingWidth
                        )
                    }
            } else if state.hovered {
                shape.fill(DesignTokens.ColorToken.surfaceHover.color)
            }
        }
        .focusRing(state.showsFocusRing, shape, offset: 0)
        .animation(.motion(.fast, reduceMotion: reduceMotion), value: state)
        .contentShape(shape)
        .onHover { hovered = $0 }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onTapGesture { open() }
        .onKeyPress(.return) {
            open()
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { open() }
    }
}

extension StoryRow where Under == EmptyView {
    /// A row with nothing under its title.
    public init(
        number: Int?, mark: RowLead, identifier: String, title: String, quiet: Bool = false, struck: Bool = false,
        current: Bool = false, label: String, state: DesignTokens.Interaction? = nil, open: @escaping () -> Void,
        @ViewBuilder trail: () -> Trail
    ) {
        self.init(
            number: number, mark: mark, identifier: identifier, title: title, quiet: quiet, struck: struck, current: current,
            label: label, state: state, open: open, under: { EmptyView() }, trail: trail
        )
    }
}

/// The catalog's story fold (`.story-more`, TP-1500): one line under the story's rows that unfolds the rest in place
/// ("20 more wait in line, in this order") and folds them again, in the accent's text with its chevron.
public struct StoryFold: View {
    let title: String
    let open: Bool
    let toggle: () -> Void

    @State private var hovered = false
    @FocusState private var focused: Bool

    public init(_ title: String, open: Bool, toggle: @escaping () -> Void) {
        self.title = title
        self.open = open
        self.toggle = toggle
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Control.small.radius, style: .continuous)
        HStack(spacing: DesignTokens.Space.s2) {
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(DesignTokens.TypeStyle.font(size: DesignTokens.StoryRow.arrowSize, weight: DesignTokens.Row.titleWeight))
                .accessibilityHidden(true)
            Text(title).font(DesignTokens.TypeStyle.font(size: DesignTokens.TypeStyle.label.size, weight: DesignTokens.Row.titleWeight))
        }
        .foregroundStyle(DesignTokens.ColorToken.accentText.color)
        .padding(.vertical, DesignTokens.StoryRow.foldVerticalInset)
        .padding(.horizontal, DesignTokens.StoryRow.foldHorizontalInset)
        .background { if hovered { shape.fill(DesignTokens.ColorToken.accentTint.color) } }
        .focusRing(focused, shape)
        .contentShape(shape)
        .onHover { hovered = $0 }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onTapGesture { toggle() }
        .onKeyPress(.return) {
            toggle()
            return .handled
        }
        .onKeyPress(.space) {
            toggle()
            return .handled
        }
        .padding(.leading, DesignTokens.StoryRow.foldLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
    }
}
