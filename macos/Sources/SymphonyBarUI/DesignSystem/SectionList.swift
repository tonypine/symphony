import SwiftUI
import SymphonyBarCore

// An in-page section list (TP-1574): a page's sections down its side (Settings' Symphony, Notifications, Updates…),
// one current, drawn with the window sidebar's rows (`SidebarRow`, `DesignTokens.Sidebar`) without the window's chrome:
// no room for the window's buttons, no hairline, no folded form. Its measures are `DesignTokens.SectionList`'s.

/// The sections of a page, one current: the current row carries the accent tint with accent text at 600 (the pressed
/// grey while the window is not in front), the others show hover, pressed and the keyboard's focus ring. A click on a
/// section makes it the current one: `select` is called with it, and the page shows it. The arrow keys move the
/// keyboard through the rows and Space picks the one it is on. VoiceOver reads the group "Sections", whose value is the
/// current section. A `current` the list does not hold shows the first section as current.
public struct SectionList<ID: Hashable>: View {
    let entries: [SidebarEntry<ID>]
    let current: ID?
    let windowActive: Bool?
    let drawn: [ID: DesignTokens.Interaction]
    let select: (ID) -> Void

    @FocusState private var focus: ID?
    @ObservedObject private var modality = InputModality.shared
    @Environment(\.appearsActive) private var appearsActive

    /// `windowActive` and `drawn` (a row's state) draw it still, for the gallery; by default it follows the window and
    /// the pointer.
    public init(
        _ entries: [SidebarEntry<ID>], current: ID?, windowActive: Bool? = nil, drawn: [ID: DesignTokens.Interaction] = [:],
        select: @escaping (ID) -> Void
    ) {
        self.entries = entries
        self.current = current
        self.windowActive = windowActive
        self.drawn = drawn
        self.select = select
    }

    private var ids: [ID] { entries.map(\.id) }

    public var body: some View {
        let tokens = DesignTokens.SectionList.self
        let active = windowActive ?? appearsActive
        let shown = tokens.current(ids, current: current)
        VStack(alignment: .leading, spacing: tokens.rowGap) {
            ForEach(entries) { entry in
                SidebarRow(
                    entry: entry, current: entry.id == shown, collapsed: false, windowActive: active,
                    focused: Sidebar<ID>.showsRing(focus == entry.id, byKeyboard: modality.keyboard, windowActive: active),
                    drawn: drawn[entry.id]
                ) {
                    pick(entry.id)
                }
                .focused($focus, equals: entry.id)
            }
        }
        .padding(tokens.inset)
        .frame(width: tokens.width, alignment: .topLeading)
        .onMoveCommand { direction in
            switch direction {
            case .up: focus = tokens.moved(ids, from: focus ?? shown, down: false)
            case .down: focus = tokens.moved(ids, from: focus ?? shown, down: true)
            default: break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tokens.label)
        .accessibilityValue(tokens.spoken(current: entries.first { $0.id == shown }?.title))
    }

    private func pick(_ id: ID) {
        guard let next = DesignTokens.SectionList.picking(id, in: ids, current: current) else { return }
        select(next)
    }
}
