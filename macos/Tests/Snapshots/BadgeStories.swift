// The catalog's Badge, Count badge, Status dot and Keyboard hint stories (TP-1506), each drawn by the shared
// components under the id the catalog gives the story (`docs/design/catalog/stories.js`). The snapshots write
// `<component>-<story>-<light|dark>.png`; the design sheet puts each beside the catalog's story.
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// The catalog's roles in its order (`ROLES` in `stories.js`), each with the story's name and the catalog's word.
let catalogRoles: [(status: DesignTokens.Status, story: String, word: String)] = [
    (.you, "waiting-on-you", "Waiting on you"), (.working, "working", "Working"), (.problem, "needs-attention", "Needs attention"),
    (.done, "done", "Done"), (.idle, "paused", "Paused"), (.forced, "forced", "Forced"),
]

/// The count badge as the catalog's story draws it: the Inbox's glyph and name, then its count.
@MainActor
func inboxCount(_ count: Int, role: DesignTokens.Status? = nil) -> AnyView {
    AnyView(
        HStack(spacing: DesignTokens.StatusDot.labelGap) {
            Image(systemName: "tray").font(DesignTokens.TypeStyle.body.font).foregroundStyle(DesignTokens.TextColor.secondary.color)
            Text("Inbox").textStyle(.body).foregroundStyle(DesignTokens.TextColor.primary.color)
            CountBadge(count, role: role)
        }
        .accessibilityElement(children: .combine)
    )
}

/// A status dot beside its word, as `.dot-label` draws it (the catalog's stories use the 10 pt dot).
@MainActor
func labelledDot(_ status: DesignTokens.Status, _ word: String, live: Bool = false) -> AnyView {
    AnyView(
        HStack(spacing: DesignTokens.StatusDot.labelGap) {
            StatusDot(status, size: .large, live: live)
            Text(word).textStyle(.body).foregroundStyle(DesignTokens.TextColor.primary.color)
        }
    )
}

/// The keyboard hint in a menu, as the catalog's story draws it: two items, the second under the pointer, each with
/// its shortcut plain at the trailing edge.
@MainActor
func menuWithHints() -> AnyView {
    func item(_ title: String, _ keys: String, highlighted: Bool) -> some View {
        HStack(spacing: DesignTokens.Space.s2) {
            Image(systemName: "checkmark").font(DesignTokens.TypeStyle.secondary.font).opacity(0)
            Text(title).textStyle(.body)
            Spacer(minLength: DesignTokens.Space.s4)
            KeyboardHint(keys, plain: true, highlighted: highlighted)
        }
        .foregroundStyle(highlighted ? DesignTokens.TextColor.onAccent.color : DesignTokens.TextColor.primary.color)
        .padding(.horizontal, DesignTokens.Space.s2)
        .frame(height: DesignTokens.Control.medium.height - DesignTokens.Space.s1)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.mark, style: .continuous).fill(DesignTokens.ColorToken.accent.color)
            }
        }
    }
    return AnyView(
        VStack(alignment: .leading, spacing: 0) {
            item("Force a Ticket…", "⌘ ⇧ F", highlighted: false)
            item("Open in Linear", "⌘ L", highlighted: true)
        }
        .padding(DesignTokens.Space.s1)
        .frame(width: 260)
        .glassBackground(.thick, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous))
    )
}

/// The keyboard hint on an option card: the number that picks it, at the card's trailing edge.
@MainActor
func optionWithHint() -> AnyView {
    AnyView(
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.s3) {
            Image(systemName: "circle").foregroundStyle(DesignTokens.TextColor.secondary.color)
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                Text("Approve the catalog").textStyle(.rowTitle)
                Text("TP-1382 lands.").textStyle(.secondary).foregroundStyle(DesignTokens.TextColor.secondary.color)
            }
            Spacer(minLength: DesignTokens.Space.s2)
            KeyboardHint("1")
        }
        .padding(DesignTokens.Space.s4)
        .frame(width: 520, alignment: .leading)
        .background(DesignTokens.Surface.content.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous).strokeBorder(DesignTokens.Surface.separator.color))
    )
}

/// A badge on a selected row (the catalog's Row › Selected): white at 20 % on the accent fill.
@MainActor
func badgeOnASelectedRow() -> AnyView {
    AnyView(
        Badge(status: .you, selected: true).background(DesignTokens.ColorToken.accent.color)
    )
}

/// Every story of the four entries, in the catalog's order, then the badge on a selected row.
@MainActor
let badgeStories: [ComponentStory] = {
    func badge(_ id: String, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "badge", id: id, title: "Badge", width: 160, height: 24, draw: draw)
    }
    func count(_ id: String, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "count-badge", id: id, title: "Count badge", width: 160, height: 20, draw: draw)
    }
    func dot(_ id: String, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "status-dot", id: id, title: "Status dot", width: 160, height: 20, draw: draw)
    }
    func hint(_ id: String, width: CGFloat = 120, height: CGFloat = 20, _ draw: @escaping @MainActor () -> AnyView) -> ComponentStory {
        ComponentStory(component: "keyboard-hint", id: id, title: "Keyboard hint", width: width, height: height, draw: draw)
    }
    var stories = catalogRoles.map { role in badge(role.story) { AnyView(Badge(status: role.status, word: role.word)) } }
    stories += [
        badge("small") { AnyView(Badge(status: .working, size: .small)) },
        badge("large") { AnyView(Badge(status: .problem, word: "Checks failed", size: .large)) },
        badge("recommended") { AnyView(Badge.recommended()) },
        count("waiting-on-you") { inboxCount(4, role: .you) },
        count("problems") { inboxCount(2, role: .problem) },
        count("over-99") { inboxCount(128, role: .you) },
        count("quiet") { inboxCount(12) },
        count("zero") { inboxCount(0, role: .you) },
    ]
    stories += catalogRoles.map { role in dot(role.story) { labelledDot(role.status, role.word) } }
    stories += [
        dot("working-live") { labelledDot(.working, "3 working", live: true) },
        hint("combination") { AnyView(KeyboardHint("⌘ ⇧ F")) },
        hint("single-key") { AnyView(KeyboardHint("1")) },
        hint("plain") { AnyView(KeyboardHint("⌘ ⇧ F", plain: true)) },
        hint("in-a-menu", width: 268, height: 64) { menuWithHints() },
        hint("on-an-option", width: 520, height: 72) { optionWithHint() },
        ComponentStory(
            component: "badge", id: "on-a-selected-row", title: "Badge", width: 160, height: 20, draw: { badgeOnASelectedRow() },
            reference: (address: "row/selected", selector: ".stage-inner .row .badge")
        ),
    ]
    return stories
}()
