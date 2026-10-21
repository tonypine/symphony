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

    /// ⌘-click or ⌘Return on a chip: the ticket's page (D3) or the pull request's (D15) (`MentionTarget`); nil opens it
    /// as a click.
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
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot
    /// True while the window has a sheet over it: the paragraph is drawn as that image too, so it dims with the window.
    @State private var covered = false

    var body: some View {
        if let content = ChipTextContent.chips(text, references: references, lead: lead) {
            let style = ChipTextStyle(font: font, color: color, selectable: selectable)
            // An AppKit view gives SwiftUI no text baselines, so they come from TextKit's line for the font.
            let baseline = ChipTextView.baseline(of: font)
            // One view whatever the paragraph draws: on a `Group` the sheet reader would go to each branch, and a new
            // reader with each change of branch.
            ZStack(alignment: .topLeading) {
                if offscreenSnapshot {
                    ChipTextImage(content: content, style: style)
                } else if covered && !selectable {
                    // A control's text under a sheet: with no AppKit view in the control, what the control draws over
                    // it (a picked option card's stroke) dims with the window too. The control reads for its text.
                    ChipTextImage(content: content, style: style)
                        .accessibilityHidden(true)
                } else {
                    // Under a sheet the text view stays and draws nothing, so assistive apps read the window as they do
                    // without one, and the image under it dims with the window.
                    ChipTextRepresentable(content: content, style: style, drawsText: !covered)
                        // In a control (an option card) the control reads for its text.
                        .accessibilityHidden(!selectable)
                        .background(alignment: .topLeading) {
                            if covered {
                                ChipTextImage(content: content, style: style)
                                    .accessibilityHidden(true)
                            }
                        }
                }
            }
            .sheetCover($covered)
            .alignmentGuide(.firstTextBaseline) { _ in baseline.ascent }
            .alignmentGuide(.lastTextBaseline) { dimensions in dimensions.height - baseline.descent }
        } else {
            PlainText(text: text, lead: lead, font: font, color: color, selectable: selectable)
        }
    }
}

/// A paragraph without `references`, as the Inbox drew it before chips: a wrapping `Text`, its lead bold.
private struct PlainText: View {
    let text: String
    let lead: String?
    let font: NSFont
    let color: NSColor
    let selectable: Bool

    var body: some View {
        let words = lead.map { Text("\(Text($0).bold()) \(text)") } ?? Text(text)
        let paragraph = words
            .font(Font(font as CTFont))
            .foregroundStyle(Color(nsColor: color))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        if selectable {
            paragraph.textSelection(.enabled)
        } else {
            paragraph
        }
    }
}

/// The live paragraph: the text view, sized by SwiftUI's proposal.
private struct ChipTextRepresentable: NSViewRepresentable {
    let content: ChipTextContent
    let style: ChipTextStyle
    /// False under a sheet (`ChipTextView.drawsText`).
    var drawsText = true

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
        view.drawsText = drawsText
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

/// The paragraph in a snapshot, or under a sheet: the text view draws itself into an image at the width SwiftUI
/// gives it.
private struct ChipTextImage: View {
    let content: ChipTextContent
    let style: ChipTextStyle
    @Environment(\.colorScheme) private var colorScheme
    /// One text view for as long as the image shows.
    @State private var source = ChipTextImageSource()

    var body: some View {
        let view = source.view(content: content, style: style, appearance: colorScheme == .dark ? .darkAqua : .aqua)
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

extension View {
    /// Keeps `covered` true while the view's window has a sheet over it (N4's peek, C17). SwiftUI dims the window behind
    /// a sheet in its own drawing, which an AppKit view draws above, so an AppKit view is drawn by SwiftUI meanwhile.
    func sheetCover(_ covered: Binding<Bool>) -> some View {
        modifier(SheetCoverModifier(covered: covered))
    }
}

/// The reader is an AppKit view of no size: SwiftUI lifts what it draws over an AppKit view above its own drawing,
/// so one the size of the content would put that content above the window's dimming. A snapshot has no window, and
/// `ImageRenderer` draws an AppKit view as a placeholder, so it goes without.
private struct SheetCoverModifier: ViewModifier {
    @Binding var covered: Bool
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot

    func body(content: Content) -> some View {
        if offscreenSnapshot {
            content
        } else {
            content.background(alignment: .topLeading) {
                SheetCoverReader(covered: $covered)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct SheetCoverReader: NSViewRepresentable {
    @Binding var covered: Bool

    func makeNSView(context: Context) -> SheetCoverView {
        SheetCoverView()
    }

    func updateNSView(_ view: SheetCoverView, context: Context) {
        let covered = $covered
        // The window can report its sheet while SwiftUI updates its views, so the state changes after.
        view.cover.changed = { value in DispatchQueue.main.async { covered.wrappedValue = value } }
        // A reader not in its window yet knows of no sheet: it says once it gets there.
        if view.cover.watching, view.cover.covered != covered.wrappedValue {
            view.cover.changed(view.cover.covered)
        }
    }
}
