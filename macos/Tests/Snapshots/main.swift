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

@MainActor
func render(_ scheme: ColorScheme, to name: String) {
    let view = InboxReviewBody(item: item, picks: picks, perform: { _ in })
        .frame(width: 640)
        .background(DesignTokens.Surface.content.color)
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
    render(.light, to: "inbox-write-in-light.png")
    render(.dark, to: "inbox-write-in-dark.png")
}
