import SwiftUI
import SymphonyBarCore

// The catalog's Searchable pop-up (`components/searchable-pop-up`, `.pick-list`; TP-1530): the Pop-up for a choice
// among more values than fit a glance, such as a provider's models. Its open list is the app's own menu with a
// search field on top (`MenuSession` with a `MenuSearch`), never a stock combo box.

/// The catalog's Searchable pop-up: the Pop-up's small face showing the picked value (in the mono face for an
/// identifier, in the tertiary colour while it comes from a default), opening a list whose search field has the
/// keyboard. Typing narrows the list to the choices that hold what is typed, the arrows move through it, Return picks
/// and Escape closes it, keeping the value. The value is always one of the list's: nothing typed becomes a value.
/// When nothing matches, one line says so in the list's place. While `disabledReason` is set it is off, and the
/// reason shows under it.
public struct SearchablePopUp<Value: Hashable>: View {
    let label: String?
    @Binding var selection: Value
    let choices: [PopUpChoice<Value>]
    let search: MenuSearch
    var mono: Bool
    var inherited: Bool
    var disabledReason: String?
    var drawnOpen: DrawnOpen?

    /// The list drawn open under the face, still, for a snapshot: what is typed in its field and the choice lit.
    public struct DrawnOpen: Equatable {
        public var query: String
        public var highlighted: Value?

        public init(query: String = "", highlighted: Value? = nil) {
            self.query = query
            self.highlighted = highlighted
        }
    }

    /// `noun` names what is chosen in the field ("Find a model") and when nothing matches ("No model matches …").
    /// `mono` draws the values in the mono face; `inherited` draws the value in the tertiary colour, as one that
    /// comes from a default; choosing makes it the entry's own, which is the caller's to record.
    public init(
        _ label: String?, selection: Binding<Value>, choices: [PopUpChoice<Value>], noun: String, mono: Bool = false,
        inherited: Bool = false, disabledReason: String? = nil, drawnOpen: DrawnOpen? = nil
    ) {
        self.label = label
        _selection = selection
        self.choices = choices
        search = MenuSearch(noun: noun)
        self.mono = mono
        self.inherited = inherited
        self.disabledReason = disabledReason
        self.drawnOpen = drawnOpen
    }

    /// The choices as the open list's items, the current one ticked and lit. A searchable list has no separators.
    func menu() -> (items: [MenuItem], highlighted: Int?) {
        let binding = $selection
        let items = choices.map { choice in
            let value = choice.value
            return MenuItem(choice.title, checked: choice.value == selection, disabledReason: choice.disabledReason) { binding.wrappedValue = value }
        }
        return (items, choices.firstIndex { $0.value == selection })
    }

    /// The list as a still picture: the choices `open.query` keeps, with `open.highlighted` lit.
    func drawnList(_ open: DrawnOpen) -> MenuList {
        let kept = choices.filter { MenuSearch.matches($0.title, query: open.query) }
        let items = kept.map { MenuItem($0.title, checked: $0.value == selection, disabledReason: $0.disabledReason) {} }
        let lit = open.highlighted.flatMap { value in kept.firstIndex { $0.value == value } }
        return MenuList(items: items, highlighted: lit, search: search, query: open.query)
    }

    private var shown: String { choices.first { $0.value == selection }?.title ?? "" }

    public var body: some View {
        let control = DesignTokens.SearchableList.control
        let trigger = MenuTrigger(
            content: .popUp(label: label, value: shown), size: control, quiet: false, monoValue: mono, inheritedValue: inherited,
            search: search, alignment: .leading, label: label ?? shown, drawnOpen: drawnOpen != nil && disabledReason == nil,
            role: .popUpButton, spokenValue: shown, reason: disabledReason, items: menu
        )
        return VStack(alignment: .leading, spacing: DesignTokens.Menu.gap) {
            trigger.disabledReason(disabledReason)
            if let drawnOpen, disabledReason == nil {
                drawnList(drawnOpen)
            }
        }
    }
}

/// The search field at the top of a searchable list, as the catalog draws it focused: the sunken capsule lifted to
/// the content colour with the accent edge and halo, the search glyph, then what is typed with the caret after it,
/// or the placeholder after the caret while nothing is. The list's panel never takes the keyboard from its window,
/// so the field is drawn and its letters come through the open list (`MenuSession.find`).
struct SearchQueryFace: View {
    let placeholder: String
    let query: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = DesignTokens.SearchableList.control
        HStack(spacing: DesignTokens.Field.itemGap) {
            Image(systemName: DesignTokens.Field.searchSymbol)
                .font(DesignTokens.TypeStyle.font(size: DesignTokens.Field.searchGlyph, weight: DesignTokens.TypeStyle.label.weight))
                .foregroundStyle(DesignTokens.TextColor.secondary.color)
                .accessibilityHidden(true)
            HStack(spacing: 0) {
                if !query.isEmpty {
                    Text(query).foregroundStyle(DesignTokens.TextColor.primary.color)
                }
                Rectangle()
                    .fill(DesignTokens.ColorToken.accent.color)
                    .frame(width: 1, height: size.fontSize + 2)
                    .accessibilityHidden(true)
                if query.isEmpty {
                    Text(placeholder).foregroundStyle(DesignTokens.TextColor.tertiary.color)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(size.inputFont)
        .padding(.leading, size.padding * DesignTokens.Field.searchLeadingScale)
        .padding(.trailing, size.padding * DesignTokens.Field.searchTrailingScale)
        .frame(height: size.height)
        .modifier(FieldSurface(shape: Capsule(), kind: .search, state: .focused, reduceMotion: reduceMotion))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(placeholder)
        .accessibilityValue(query)
    }
}
