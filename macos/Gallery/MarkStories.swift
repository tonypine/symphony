// The shared hairline divider and priority mark (TP-1485), each drawn by its shared component, each a variation of
// its own. Neither has a story of its own in the catalog: the divider is its `.ident-sep` and `.rail-sep`, the mark
// its `.prio`, both on the ticket page's header (`#sections/window/ticket-page-laptop`).
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// A vertical hairline between two words, as the header and the moves row draw it.
@MainActor
func dividerBetween(_ length: CGFloat) -> AnyView {
    AnyView(
        HStack(spacing: DesignTokens.Space.s2) {
            Text("Before").textStyle(.label)
            HairlineDivider(.vertical, length: length).padding(.horizontal, DesignTokens.Space.s1)
            Text("After").textStyle(.label)
        }
        .foregroundStyle(DesignTokens.TextColor.secondary.color)
    )
}

/// A horizontal hairline across, between two lines of text.
@MainActor
func dividerAcross() -> AnyView {
    AnyView(
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            Text("Above").textStyle(.label)
            HairlineDivider()
            Text("Below").textStyle(.label)
        }
        .foregroundStyle(DesignTokens.TextColor.secondary.color)
    )
}

/// The priority mark after the identifier line's hairline, with a label chip, as the header draws it.
@MainActor
func priorityOnIdentifierLine() -> AnyView {
    AnyView(
        HStack(spacing: DesignTokens.Space.s2) {
            Text("TP-1463").font(DesignTokens.TypeStyle.label.font).foregroundStyle(.secondary)
            HairlineDivider(.vertical, length: 14).padding(.horizontal, DesignTokens.Space.s1)
            PriorityMark("Urgent")
            Chip("design", kind: .label(.working))
        }
    )
}

/// Every story of the two entries.
@MainActor
let markStories: [ComponentStory] = [
    ComponentStory(component: "hairline-divider", id: "vertical-14", title: "Hairline divider", width: 160, height: 24, draw: { dividerBetween(14) }),
    ComponentStory(component: "hairline-divider", id: "vertical-20", title: "Hairline divider", width: 160, height: 28, draw: { dividerBetween(20) }),
    ComponentStory(component: "hairline-divider", id: "horizontal", title: "Hairline divider", width: 200, height: 56, draw: { dividerAcross() }),
    ComponentStory(component: "priority-mark", id: "urgent", title: "Priority mark", width: 120, height: 24, draw: { AnyView(PriorityMark("Urgent")) }),
    ComponentStory(component: "priority-mark", id: "low", title: "Priority mark", width: 120, height: 24, draw: { AnyView(PriorityMark("Low")) }),
    ComponentStory(component: "priority-mark", id: "on-the-identifier-line", title: "Priority mark", width: 280, height: 24, draw: {
        priorityOnIdentifierLine()
    }),
]
