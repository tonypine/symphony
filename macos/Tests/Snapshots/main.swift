// Renders the Inbox review snapshots offscreen with `ImageRenderer`: no `NSApplication`, no window.
// `make snapshots` compiles it with the app's views and writes the PNGs next to it.
import AppKit
import ImageIO
import SwiftUI
import SymphonyBarCore
import UniformTypeIdentifiers

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let fixture = here.appendingPathComponent("../Fixtures/director-app/inbox-decision/api/v1/inbox.json").standardizedFileURL

guard let inbox = InboxPayload.decode(try Data(contentsOf: fixture)),
    let item = inbox.items.first(where: { $0.identifier == "TP-892" }),
    let action = item.review.action
else { fatalError("TP-892 is missing from \(fixture.path)") }

/// TP-892 with the write-in (N11) picked and an answer in it (D2c).
let picks = DecisionPicks(
    picks: [0: action.writeInIndex],
    writeIn: "Leave them to TP-891, and add a note on TP-891 so its run removes the mention too."
)

/// A mention in TP-892's question and story by its key (TP-999 is one Symphony can't see), as its chip finds it.
func mention(_ key: String) -> Mention {
    let text = key == "TP-999" ? "Ask TP-999 first." : [action.question, action.why].compactMap { $0 }.joined(separator: " ")
    guard let found = Mentions.find(in: text, references: item.references).first(where: { $0.key == key }) else {
        fatalError("\(key) is not mentioned in TP-892's text")
    }
    return found
}

/// TP-892 at `width`: the Inbox's narrow pane, or a 1200 pt window's.
@MainActor
func review(width: CGFloat, picks: DecisionPicks = DecisionPicks()) -> some View {
    InboxReviewBody(item: item, picks: picks, perform: { _ in })
        .frame(width: width)
        .background(DesignTokens.Surface.content.color)
}

/// A chip's popover (N2, N3, or a mention Symphony can't see). `ImageRenderer` draws no glass, so it sits on the
/// window's surface.
@MainActor
func popover(_ key: String) -> some View {
    ReferencePopoverView(popover: ReferencePopover(mention(key)))
        .background(DesignTokens.Surface.window.color)
}

@MainActor
func render(_ view: some View, _ scheme: ColorScheme, to name: String) {
    let view = view
        .environment(\.colorScheme, scheme)
        .environment(\.offscreenSnapshot, true)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.cgImage else { fatalError("Could not render \(name)") }
    let url = here.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Could not write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(url.path)") }
    print("wrote \(url.path)")
}

MainActor.assumeIsolated {
    for (scheme, suffix) in [(ColorScheme.light, "light"), (.dark, "dark")] {
        render(review(width: 640, picks: picks), scheme, to: "inbox-write-in-\(suffix).png")
        // Chips inside the question, story and options, wrapping with the text (TP-952).
        render(review(width: 1200), scheme, to: "decision-chips-wide-\(suffix).png")
        render(review(width: 420), scheme, to: "decision-chips-narrow-\(suffix).png")
        render(popover("TP-891"), scheme, to: "ticket-popover-\(suffix).png")
        render(popover("#448"), scheme, to: "pr-popover-\(suffix).png")
        render(popover("TP-999"), scheme, to: "missing-popover-\(suffix).png")
    }
}
