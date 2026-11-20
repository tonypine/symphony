import SwiftUI
import SymphonyBarCore

/// Writing to the ticket (`docs/design/director-window-and-home.md`, "Writing to the ticket"; the catalog's `composer`,
/// `.tl-compose`): one box under the Timeline label, above the first entry, the shared Text area at the large control
/// height with the row radius. It grows with its text up to six lines, then scrolls. While it is empty there is nothing
/// else; once it holds text a row under it at the right has the ⌘↩ hint and a small primary Send. ⌘↩ sends and Return
/// adds a line. A refused message stays in the box with the reason under it, in the inline refusal. What is sent comes
/// back as the timeline's newest entry ("You wrote: …").
public struct TimelineComposer: View {
    @ObservedObject var composer: TicketMessageComposer
    let send: () -> Void
    var focus: FocusState<Bool>.Binding?
    var drawnAs: DesignTokens.Field.State?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The most lines the box grows to before it scrolls.
    public static let maxLines = 6
    /// What VoiceOver reads after the box's name.
    public static let hint = "Command-Return sends it. Return adds a line."

    /// `composer` holds the box's text, whether a message is on its way and why the last one wasn't sent; `send` posts
    /// it. `focus` is the box's keyboard focus, for a move that takes the person to it; `drawnAs` draws the box in one
    /// state, for an offscreen render.
    public init(
        composer: TicketMessageComposer, focus: FocusState<Bool>.Binding? = nil, drawnAs: DesignTokens.Field.State? = nil,
        send: @escaping () -> Void
    ) {
        self.composer = composer
        self.focus = focus
        self.drawnAs = drawnAs
        self.send = send
    }

    private var sendable: Bool { composer.hasDraft && !composer.sending }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            TextArea(
                TicketMessageComposer.label, text: $composer.text, placeholder: TicketMessageComposer.placeholder, hint: Self.hint,
                minLines: 1, maxLines: Self.maxLines, minHeight: DesignTokens.Control.large.height, focused: focus, drawnAs: drawnAs,
                send: { if sendable { send() } }
            )
            if let refusal = composer.refusal {
                Refusal(reason: refusal)
                    .accessibilityLabel(TicketMessageComposer.refusalLabel(refusal))
            }
            if composer.hasDraft {
                HStack(spacing: DesignTokens.Space.s3) {
                    Spacer(minLength: 0)
                    KeyboardHint(TicketMessageComposer.shortcut)
                        .accessibilityHidden(true)
                    Button(composer.sending ? TicketMessageComposer.sendingTitle : TicketMessageComposer.sendTitle) { if sendable { send() } }
                        .directorButton(.primary, size: .small)
                        .help(TicketMessageComposer.sendTitle + " (⌘↩)")
                }
                .transition(.opacity)
            }
        }
        .padding(.bottom, DesignTokens.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.motion(.standard, reduceMotion: reduceMotion), value: composer.hasDraft)
    }
}
