// The design sheet (TP-1482): each design reference beside the native page drawn from the matching fixture, at the
// same size. `make design-sheet` runs this program twice around `Tests/DesignSheet/capture.py`:
//
// 1. `DESIGN_SHEET_PHASE=plan` writes `<sheet>/shots.json`, the references to draw: the ticket page prototype's three
//    moments, and the catalog's Window stories for the ticket page, Home, Initiatives and Tickets, at the laptop's and
//    the desktop's widths, in light and dark; then the catalog's Chip stories, and its Button, Icon button and Inline
//    refusal stories, in light and dark.
// 2. capture.py draws each reference into `<sheet>/reference/<id>.png` and its size in points into
//    `<sheet>/references.json`.
// 3. `DESIGN_SHEET_PHASE=compose` draws the native page at each reference's size, puts the two side by side in
//    `<sheet>/<id>.png` and lists them in `<sheet>/index.html`; the Button page, `<sheet>/button.html`, lists the
//    Button, Icon button and Inline refusal stories alone.
//
// It is evidence, not a gate: nothing here compares pixels.
import AppKit
import ImageIO
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI
import UniformTypeIdentifiers

/// One row of the sheet: a design reference, where a browser finds it, and the native page drawn beside it.
struct SheetShot {
    let id: String
    let title: String
    /// The reference's link, relative to the repository's root (`docs/design/…`).
    let link: String
    /// The element whose box is the reference: the prototype's window, or the page inside the catalog's window.
    let selector: String
    /// The reference's size in points as designed; capture.py measures the size it really drew.
    let width: CGFloat
    let height: CGFloat
    let theme: String
    let native: String
    let draw: @MainActor (CGFloat, CGFloat) -> AnyView
}

let sheetRepo = here.appendingPathComponent("../../..").standardizedFileURL

/// The ticket page of `identifier` `width` wide, its first `height` points: the window as it opens.
@MainActor
func sheetTicketPage(_ identifier: String, width: CGFloat, height: CGFloat) -> AnyView {
    let page = ticketPageRead(identifier)
    return AnyView(
        TicketPageBody(
            page: page, questions: TicketPage.questions(of: identifier, in: ticketPageInbox.items), width: width,
            transcripts: StepTranscripts { _ in .unreachable }, note: TicketNoteComposer(identifier: identifier),
            decisions: ticketPageDecisions(identifier), scroll: TicketPageScroll(viewport: height),
            calendar: timelineCalendar
        )
        .frame(width: width, height: height, alignment: .top)
        .clipped()
        .background(DesignTokens.Surface.content.color)
    )
}

/// `view`, a page drawn in a window `width` plus the sidebar wide, as its first `width` × `height` points.
@MainActor
func sheetWindowPage(_ view: some View, width: CGFloat, height: CGFloat) -> AnyView {
    AnyView(view.frame(width: width, height: height, alignment: .topLeading).clipped().windowBackdrop())
}

let sheetSizes: [(name: String, title: String, page: CGSize, window: CGSize)] = [
    ("laptop", "Laptop", CGSize(width: 1180, height: 820), CGSize(width: 1440, height: 900)),
    ("desktop", "Desktop", CGSize(width: 2200, height: 1360), CGSize(width: 2460, height: 1360)),
]

/// A chip of `kind` at the leading edge of a cell `width` × `height`.
func sheetChip(_ text: String, kind: Chip.Kind) -> @MainActor (CGFloat, CGFloat) -> AnyView {
    { width, height in AnyView(Chip(text, kind: kind).frame(width: width, height: height, alignment: .leading)) }
}

/// Every row: the prototype's moments first, then the catalog's Window stories, then its chips.
@MainActor
func sheetShots() -> [SheetShot] {
    var shots: [SheetShot] = []
    for theme in ["light", "dark"] {
        for size in sheetSizes {
            for (identifier, moment, title) in [("TP-1244", "running", "Running"), ("TP-1245", "waiting", "Waiting on you"), ("TP-1246", "shipped", "Shipped")] {
                shots.append(SheetShot(
                    id: "prototype-\(moment)-\(size.name)-\(theme)", title: "Ticket page prototype · \(title) · \(size.title) · \(theme)",
                    link: "docs/design/prototypes/ticket-page/index.html#moment=\(moment)&width=\(size.name)&theme=\(theme)&fit=off",
                    selector: "#window", width: size.page.width, height: size.page.height, theme: theme,
                    native: "\(identifier) from the ticket-page fixture"
                ) { sheetTicketPage(identifier, width: $0, height: $1) })
            }
            let sidebar = DesignTokens.Layout.sidebarWidth
            let stories: [(String, String, String, @MainActor (CGFloat, CGFloat) -> AnyView)] = [
                ("ticket-page", "Ticket page", size.name == "laptop" ? "TP-1244 (running) from the ticket-page fixture" : "TP-1245 (waiting on you) from the ticket-page fixture", { w, h in
                    sheetTicketPage(size.name == "laptop" ? "TP-1244" : "TP-1245", width: w, height: h)
                }),
                ("home", "Home", "the home fixture", { w, h in sheetWindowPage(homeBoard("home", window: w + sidebar), width: w, height: h) }),
                ("initiatives", "Initiatives", "TP-1381 from the initiative-story fixture", { w, h in
                    sheetWindowPage(initiativeStory("TP-1381", window: w + sidebar), width: w, height: h)
                }),
                ("tickets", "Tickets", "the tickets fixture", { w, h in
                    sheetWindowPage(ticketsTable(window: w + sidebar, drawer: size.name == "desktop"), width: w, height: h)
                }),
            ]
            for (story, title, native, draw) in stories {
                shots.append(SheetShot(
                    id: "window-\(story)-\(size.name)-\(theme)", title: "Catalog › Window › \(title), \(size.name) · \(theme)",
                    link: "docs/design/catalog/index.html#sections/window/\(story)-\(size.name)",
                    selector: ".win-body", width: size.window.width, height: size.window.height, theme: theme, native: native, draw: draw
                ))
            }
        }
        // The catalog's Chip stories beside the chip (TP-1484).
        for story in chipStories {
            shots.append(SheetShot(
                id: "chip-\(story.id)-\(theme)", title: "Catalog › Components › Chip › \(story.id) · \(theme)",
                link: "docs/design/catalog/index.html#components/chip/\(story.id)",
                selector: ".stage-inner .chip", width: 120, height: 24, theme: theme, native: "Chip(\(story.text))",
                draw: sheetChip(story.text, kind: story.kind)
            ))
        }
        // The catalog's Button, Icon button and Inline refusal stories beside the shared components (TP-1505).
        for story in componentStories {
            shots.append(SheetShot(
                id: "\(story.component)-\(story.id)-\(theme)", title: "Catalog › Components › \(story.title) › \(story.id) · \(theme)",
                link: "docs/design/catalog/index.html#components/\(story.component)/\(story.id)",
                selector: ".stage-inner > :first-child", width: story.width, height: story.height, theme: theme,
                native: "the shared \(story.title.lowercased())"
            ) { width, height in AnyView(story.draw().frame(width: width, height: height, alignment: .topLeading)) })
        }
    }
    return shots
}

/// The rows of the Button page: the catalog's Button, Icon button and Inline refusal stories.
func isButtonPageShot(_ id: String) -> Bool {
    ["button-", "icon-button-", "inline-refusal-"].contains { id.hasPrefix($0) }
}

/// Writes the references capture.py draws.
@MainActor
func planDesignSheet(_ sheet: URL) {
    let shots = sheetShots().map { shot -> [String: Any] in
        [
            "id": shot.id, "url": sheetRepo.appendingPathComponent(shot.link).absoluteString.replacingOccurrences(of: "%23", with: "#"),
            "selector": shot.selector, "width": shot.width, "height": shot.height, "theme": shot.theme,
        ]
    }
    try! FileManager.default.createDirectory(at: sheet, withIntermediateDirectories: true)
    let data = try! JSONSerialization.data(withJSONObject: shots, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: sheet.appendingPathComponent("shots.json"))
    print("wrote \(sheet.appendingPathComponent("shots.json").path): \(shots.count) references")
}

/// One side-by-side image: the reference on the left, the native page on the right, each in a cell of the same size.
@MainActor
func sheetPair(_ shot: SheetShot, reference: NSImage?, size: CGSize) -> some View {
    let label = { (text: String, detail: String) in
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(width: size.width, alignment: .leading)
    }
    let cell = { (content: AnyView) in
        content
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
    }
    return VStack(alignment: .leading, spacing: 12) {
        Text(shot.title).font(.system(size: 20, weight: .bold))
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                label("Design", shot.link)
                cell(reference.map { image in
                    AnyView(Image(nsImage: image).resizable().frame(width: size.width, height: size.height))
                } ?? AnyView(Text("No reference drawn: run capture.py").frame(maxWidth: .infinity, maxHeight: .infinity)))
            }
            VStack(alignment: .leading, spacing: 8) {
                label("App", shot.native)
                cell(shot.draw(size.width, size.height))
            }
        }
    }
    .padding(24)
    .background(Color(nsColor: .windowBackgroundColor))
}

/// Draws each pair at its reference's size and writes the index.
@MainActor
func composeDesignSheet(_ sheet: URL) {
    let measured = (try? Data(contentsOf: sheet.appendingPathComponent("references.json")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String: Double]] } ?? [:]
    var rows = ""
    var buttonRows = ""
    for shot in sheetShots() {
        let size = measured[shot.id].map { CGSize(width: $0["width"] ?? shot.width, height: $0["height"] ?? shot.height) }
            ?? CGSize(width: shot.width, height: shot.height)
        let reference = NSImage(contentsOf: sheet.appendingPathComponent("reference/\(shot.id).png"))
        reference?.size = size
        renderSheet(sheetPair(shot, reference: reference, size: size), shot.theme == "dark" ? .dark : .light, to: sheet.appendingPathComponent("\(shot.id).png"))
        let row = """
        <section id="\(shot.id)"><h2><a href="#\(shot.id)">\(htmlEscape(shot.title))</a></h2>
        <p>Design: <code>\(htmlEscape(shot.link))</code> · App: \(htmlEscape(shot.native)) · \(Int(size.width)) × \(Int(size.height)) pt\(reference == nil ? " · <b>no reference drawn</b>" : "")</p>
        <a href="\(shot.id).png"><img src="\(shot.id).png" alt="\(htmlEscape(shot.title))" loading="lazy"></a></section>

        """
        rows += row
        if isButtonPageShot(shot.id) { buttonRows += row }
    }
    writeSheetPage(sheet.appendingPathComponent("index.html"), title: "Design sheet", lead: "<p><a href=\"button.html\">The Button page</a>: the Button, Icon button and Inline refusal stories alone.</p>", rows: rows)
    writeSheetPage(sheet.appendingPathComponent("button.html"), title: "Design sheet · Button", lead: "<p><a href=\"index.html\">Every row</a></p>", rows: buttonRows)
}

/// One page of the sheet: its rows under the title.
func writeSheetPage(_ url: URL, title: String, lead: String, rows: String) {
    let html = """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><title>\(title)</title>
    <style>
    body { font: 14px/1.4 -apple-system, system-ui, sans-serif; margin: 24px; color: #1d1d1f; background: #f5f5f7; }
    section { margin: 0 0 40px; } h2 { font-size: 17px; margin: 0 0 4px; } h2 a { color: inherit; text-decoration: none; }
    p { margin: 0 0 8px; color: #6e6e73; } img { width: 100%; height: auto; border: 1px solid #d2d2d7; background: #fff; }
    </style></head><body>
    <h1>\(title)</h1>
    \(lead)
    <p>Each row: the design on the left, the app's page from the matching fixture on the right, at the same size in points. It is evidence, not a gate: nothing here fails on a difference.</p>
    \(rows)</body></html>

    """
    try! html.write(to: url, atomically: true, encoding: .utf8)
    print("wrote \(url.path)")
}

func htmlEscape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

@MainActor
func renderSheet(_ view: some View, _ scheme: ColorScheme, to url: URL) {
    let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme).environment(\.offscreenSnapshot, true))
    renderer.scale = 2
    guard let image = renderer.cgImage else { fatalError("Could not render \(url.lastPathComponent)") }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Could not write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(url.path)") }
    print("wrote \(url.path)")
}

/// Runs a phase of the sheet when `DESIGN_SHEET_PHASE` asks for one, in place of the snapshots.
@MainActor
func runDesignSheetPhase() -> Bool {
    let env = ProcessInfo.processInfo.environment
    guard let phase = env["DESIGN_SHEET_PHASE"] else { return false }
    let sheet = URL(fileURLWithPath: env["DESIGN_SHEET_OUT"] ?? "build/design-sheet").standardizedFileURL
    switch phase {
    case "plan": planDesignSheet(sheet)
    case "compose": composeDesignSheet(sheet)
    default: fatalError("DESIGN_SHEET_PHASE is plan or compose, not \(phase)")
    }
    return true
}
