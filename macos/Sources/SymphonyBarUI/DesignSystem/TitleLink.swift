import SwiftUI
import SymphonyBarCore

// A ticket's title that opens the ticket's page (TP-1647): on Home's slot cards, the epic slot card's band and every
// row. The title keeps its colour, size and weight; under the pointer it is underlined in its own colour and the
// pointer is the pointing hand (decided by the person on 2026-11-24). Only the title is the target, so the card's and
// the row's own controls, an epic row's fold and a drag that starts on the row keep working: the click is a tap, which
// a press that moves gives up to the row's drag.

/// What a title link does and how it is drawn, which the tests read.
public enum TitleLink {
    /// Whether the title is underlined: only while the pointer is over it (or a story draws it so).
    public static func underlined(hovered: Bool) -> Bool { hovered }

    /// Whether the pointer over the title is the pointing hand: always, as over any control that can be pressed.
    public static var hand: Bool { ButtonPointer.hand(enabled: true) }

    /// The pointer over the title: the pointing hand.
    public static var pointer: PointerStyle? { ButtonPointer.style(enabled: hand) }

    /// The VoiceOver action that opens the ticket's page: "Open TP-1619".
    public static func actionTitle(_ identifier: String) -> String { "Open \(identifier)" }
}

extension View {
    /// Makes this title the way into the page of the ticket `identifier`: a click calls `open` with it, the pointer
    /// over it is the pointing hand and the title is underlined while the pointer is over it; VoiceOver gets an "Open
    /// <identifier>" action. `hovered` draws the hover still, for a story; nil follows the pointer. With no `open` the
    /// title is drawn as it is, and takes no click.
    public func titleLink(_ identifier: String, hovered: Bool? = nil, open: ((String) -> Void)?) -> some View {
        modifier(TitleLinkModifier(open: open.map { open -> () -> Void in { open(identifier) } }, identifier: identifier, hovered: hovered))
    }
}

extension View {
    /// The VoiceOver action that opens the page of the ticket `identifier`, on an element that hides its children (the
    /// title's own action does not reach it); nothing without `open`.
    public func openTicketAction(_ identifier: String, open: ((String) -> Void)?) -> some View {
        modifier(OpenTicketAction(identifier: identifier, open: open))
    }
}

private struct OpenTicketAction: ViewModifier {
    let identifier: String
    let open: ((String) -> Void)?

    func body(content: Content) -> some View {
        if let open {
            content.accessibilityAction(named: Text(TitleLink.actionTitle(identifier))) { open(identifier) }
        } else {
            content
        }
    }
}

private struct TitleLinkModifier: ViewModifier {
    let open: (() -> Void)?
    let identifier: String
    let hovered: Bool?
    @State private var pointer = false

    func body(content: Content) -> some View {
        if let open {
            content
                .underline(TitleLink.underlined(hovered: hovered ?? pointer))
                .contentShape(Rectangle())
                .onHover { pointer = $0 }
                .buttonPointer(enabled: TitleLink.hand)
                // A tap, not a button: a press that moves is the row's drag, and only a press let go in place opens.
                .onTapGesture(perform: open)
                .accessibilityAction(named: Text(TitleLink.actionTitle(identifier)), open)
        } else {
            content.underline(TitleLink.underlined(hovered: hovered ?? false))
        }
    }
}
