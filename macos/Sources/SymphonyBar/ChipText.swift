import AppKit
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

extension EnvironmentValues {
    /// The `references` of the Inbox item whose text a `ChipText` shows.
    var mentionReferences: [String: Reference] {
        get { self[MentionReferencesKey.self] }
        set { self[MentionReferencesKey.self] = newValue }
    }

    /// A click on a chip: its peek (N4) on the decision screen.
    var openMention: OpenMentionAction {
        get { self[OpenMentionKey.self] }
        set { self[OpenMentionKey.self] = newValue }
    }

    /// ⌘-click or ⌘Return on a chip: the ticket's page (D3), or the pull request on GitHub; nil opens it as a click.
    var openMentionDirectly: OpenMentionAction? {
        get { self[OpenMentionDirectlyKey.self] }
        set { self[OpenMentionDirectlyKey.self] = newValue }
    }
}

private struct MentionReferencesKey: EnvironmentKey {
    static let defaultValue: [String: Reference] = [:]
}

private struct OpenMentionKey: EnvironmentKey {
    static let defaultValue = OpenMentionAction { _ in }
}

private struct OpenMentionDirectlyKey: EnvironmentKey {
    static let defaultValue: OpenMentionAction? = nil
}

/// What a click on a chip opens, as `OpenURLAction` is for a link.
struct OpenMentionAction {
    let handler: (Mention) -> Void

    func callAsFunction(_ mention: Mention) { handler(mention) }
}

/// A paragraph of an Inbox item's text in native Mac text, each ticket and pull request it mentions a chip (N1) with
/// a popover (N2, N3): one `ChipTextView` that wraps in its pane like a `Text` (DD-5). The mentions are found by the
/// item's `references`, which the review puts in the environment.
struct ChipText: View {
    let text: String
    /// A bold lead before the text: "If you don't answer:".
    var lead: String?
    var font: NSFont = DesignTokens.TypeStyle.body.nsFont
    var color: NSColor = .labelColor
    /// False in a control: the text can't be selected and a click outside a chip goes to the control.
    var selectable = true
    @Environment(\.mentionReferences) private var references
    /// `ImageRenderer` can't draw an AppKit view, so a snapshot shows the text view drawn into an image, offscreen.
    @Environment(\.offscreenSnapshot) private var rendersImage

    var body: some View {
        let content = ChipTextContent(text, references: references, lead: lead)
        let style = ChipTextStyle(font: font, color: color, selectable: selectable)
        // An AppKit view gives SwiftUI no text baselines, so they come from TextKit's line for the font.
        let baseline = ChipTextView.baseline(of: font)
        Group {
            if rendersImage {
                ChipTextImage(content: content, style: style)
            } else {
                ChipTextRepresentable(content: content, style: style)
                    // In a control (an option card) the control reads for its text.
                    .accessibilityHidden(!selectable)
            }
        }
        .alignmentGuide(.firstTextBaseline) { _ in baseline.ascent }
        .alignmentGuide(.lastTextBaseline) { dimensions in dimensions.height - baseline.descent }
    }

    /// What ⌘-click on a chip opens, past the peek, until the pull request page (TP-961): a ticket Symphony sees opens
    /// its page, anything else its link.
    static func open(_ mention: Mention, openTicket: (String) -> Void, openURL: (URL) -> Void) {
        if mention.kind == .ticket, !mention.isMissing {
            openTicket(mention.key)
        } else if let url = mention.reference.url {
            openURL(url)
        }
    }
}

/// The live paragraph: the text view, sized by SwiftUI's proposal.
private struct ChipTextRepresentable: NSViewRepresentable {
    let content: ChipTextContent
    let style: ChipTextStyle

    final class Coordinator {
        var openURL: (URL) -> Void = { _ in }
        lazy var popover = ChipPopover { [unowned self] mention in
            let controller = NSHostingController(rootView: ReferencePopoverView(popover: ReferencePopover(mention), openURL: { self.openURL($0) }))
            controller.sizingOptions = .preferredContentSize
            return controller
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ChipTextView {
        let view = ChipTextView(content: content, style: style)
        view.popover = context.coordinator.popover
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: ChipTextView, context: Context) {
        view.update(content: content, style: style)
        let openURL = context.environment.openURL
        context.coordinator.openURL = { openURL($0) }
        view.openURL = { openURL($0) }
        let openMention = context.environment.openMention
        view.openMention = { openMention($0) }
        view.openMentionDirectly = context.environment.openMentionDirectly.map { direct in { direct($0) } }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ChipTextView, context: Context) -> CGSize? {
        view.fittingSize(width: proposal.width)
    }
}

/// The paragraph in a snapshot: the text view draws itself into an image at the width SwiftUI gives it.
private struct ChipTextImage: View {
    let content: ChipTextContent
    let style: ChipTextStyle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let view = ChipTextView(content: content, style: style)
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        return ChipTextSizing(view: view) {
            Canvas { context, size in
                context.draw(Image(nsImage: view.image(width: size.width)), in: CGRect(origin: .zero, size: size))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(content.source)
    }
}

/// Sizes its one subview as the text view sizes the paragraph.
private struct ChipTextSizing: Layout {
    let view: ChipTextView

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        view.fittingSize(width: proposal.width)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
