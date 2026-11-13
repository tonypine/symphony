// The Component Gallery: the app's shared components and screens, each shown with every one of its variations
// together on one board, drawn by the app's own views from made-up inputs or a committed fixture. It is the app's
// counterpart of the HTML catalog: the same isolation, the real views, and live, so a board's controls can be hovered,
// pressed and reached with Tab. The entries are in Entries.swift; their variations in main.swift and *Stories.swift.
//
//   SymphonyGallery                       the window: the entries on the left, the picked one's board on the right
//   SymphonyGallery --open <entry>        the window, on that entry (`--dark` for the dark appearance). It fills the
//                                         screen, over the menu bar and the Dock; `--window` keeps it a window
//   SymphonyGallery --entries             the entries, as JSON: id, title, kind, variations, the files each shows
//   SymphonyGallery --affected            the entries a change is a reason to look at, as JSON; the changed files'
//                                         repository paths come one per line on standard input
//   SymphonyGallery --shot <entry> --out <dir>
//                                         draws the entry's board to `<dir>/<entry>-<n>-<light|dark>.png`, without a
//                                         window: one picture when the board is small, a few when it is tall or wide
//   SymphonyGallery --check               fails, saying why, when the entries and the variations disagree
//
// QA reaches it through the app: `qa_launch_app` on the fixture folder `macos/Tests/Fixtures/gallery` starts the
// gallery in the app's place (Sources/SymphonyBar/GalleryLaunch.swift), so QA's tools drive it as they drive the app.
// No picture is committed: one is drawn when somebody needs to look.
import AppKit
import ImageIO
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI
import UniformTypeIdentifiers

/// One variation of an entry: its name (`button-primary-hover`) and the view it draws.
struct GalleryVariation: Identifiable {
    let id: String
    let view: AnyView
}

@MainActor var galleryVariations: [GalleryVariation] = []

/// Names one variation. They are listed once per appearance, as they were when each was a picture; the gallery keeps
/// the first listing and draws either appearance itself.
@MainActor
func render(_ view: some View, _ scheme: ColorScheme, to name: String) {
    guard scheme == .light else { return }
    galleryVariations.append(GalleryVariation(id: name.replacingOccurrences(of: "-light.png", with: ""), view: AnyView(view)))
}

@MainActor
func variations(of entry: GalleryEntry) -> [GalleryVariation] { galleryVariations.filter { entry.owns($0.id) } }

private func json(_ value: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    return String(data: data, encoding: .utf8)!
}

@MainActor
func runGallery() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    func value(after flag: String) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }
    func entry(_ id: String) -> GalleryEntry {
        guard let found = galleryEntries.first(where: { $0.id == id }) else {
            FileHandle.standardError.write("No entry is named \(id). The entries: \(galleryEntries.map(\.id).joined(separator: ", "))\n".data(using: .utf8)!)
            exit(2)
        }
        return found
    }
    if arguments.contains("--entries") {
        print(json([
            "entries": galleryEntries.map { entry in
                ["id": entry.id, "title": entry.title, "kind": entry.kind.rawValue, "variations": variations(of: entry).map(\.id), "files": entry.files]
            },
            "foundation": galleryFoundation,
        ]))
        return
    }
    if arguments.contains("--affected") {
        var paths: [String] = []
        while let line = readLine() { paths.append(line.trimmingCharacters(in: .whitespaces)) }
        let affected = galleryAffected(by: paths)
        print(json(["all": affected.all, "entries": affected.entries]))
        return
    }
    if arguments.contains("--check") {
        let shared = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../Sources/SymphonyBarUI")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: shared.path)) ?? []).filter { $0.hasSuffix(".swift") }.sorted()
        let problems = galleryProblems(variations: galleryVariations.map(\.id), sharedFiles: files)
        for problem in problems { print(problem) }
        print(problems.isEmpty ? "gallery: \(galleryEntries.count) entries, \(galleryVariations.count) variations, every shared file shown" : "gallery: \(problems.count) problem(s)")
        exit(problems.isEmpty ? 0 : 1)
    }
    if let id = value(after: "--shot") {
        guard let out = value(after: "--out") else { fatalError("--shot needs --out <dir>") }
        shoot(entry(id), into: URL(fileURLWithPath: out))
        return
    }
    let first = value(after: "--open").map { entry($0).id }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    if arguments.contains("--dark") { app.appearance = NSAppearance(named: .darkAqua) }
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    window.title = "Component Gallery"
    window.contentView = NSHostingView(rootView: GalleryView(first: first))
    // The whole screen, with no menu bar and no Dock over it: nothing but the gallery is in a picture of the screen.
    // `--window` keeps an ordinary window, for a person working beside it.
    if arguments.contains("--window") {
        window.center()
    } else {
        app.presentationOptions = [.hideDock, .hideMenuBar]
        if let screen = NSScreen.main { window.setFrame(screen.frame, display: true) }
    }
    window.makeKeyAndOrderFront(nil)
    // The screen's size can change while the gallery is open (a VM's display mode): it keeps filling it.
    if !arguments.contains("--window") {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let screen = NSScreen.main { window.setFrame(screen.frame, display: true) } }
        }
    }
    app.activate(ignoringOtherApps: true)
    app.run()
}

/// Cells placed left to right, wrapping at `width`: a board of small things fills its width instead of running down
/// one column.
struct FlowLayout: Layout {
    let width: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in arrange(subviews).points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + row), points)
    }
}

/// An entry's board: every variation in a cell under its name, the cells side by side and wrapping at `width`.
struct GalleryBoard: View {
    let entry: GalleryEntry
    let variations: [GalleryVariation]
    let width: CGFloat

    var body: some View {
        FlowLayout(width: width, spacing: DesignTokens.Space.s5) {
            ForEach(variations) { variation in
                VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                    Text(name(variation))
                        .textStyle(.label)
                        .foregroundStyle(DesignTokens.TextColor.tertiary.color)
                    variation.view
                }
                .padding(DesignTokens.Space.s4)
                .background(DesignTokens.Surface.content.color, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous).strokeBorder(DesignTokens.Surface.separator.color))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(name(variation))
            }
        }
        .padding(DesignTokens.Space.s8)
    }

    /// The variation's name without its entry's prefix: `button-primary-hover` reads "primary hover".
    private func name(_ variation: GalleryVariation) -> String {
        let prefix = entry.prefixes.filter { variation.id.hasPrefix($0) }.max { $0.count < $1.count } ?? ""
        let rest = variation.id.dropFirst(prefix.count).replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? variation.id.replacingOccurrences(of: "-", with: " ") : rest
    }
}

/// Draws the entry's board to files: still, at twice its size, in light and in dark. A board taller or wider than a
/// picture is worth reading is cut between variations into a few pictures.
@MainActor
func shoot(_ entry: GalleryEntry, into folder: URL) {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // A picture an agent can read whole: the cells wrap at this width, and a board taller than this is cut between
    // cells into the next picture. A variation wider than it (a screen) gets a picture to itself.
    let limit = CGSize(width: 1600, height: 2000)
    let spacing = DesignTokens.Space.s5
    var pages: [[GalleryVariation]] = []
    var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
    var lastAlone = false
    for variation in variations(of: entry) {
        var size = NSHostingView(rootView: variation.view).fittingSize
        size.width += 2 * DesignTokens.Space.s4
        size.height += 2 * DesignTokens.Space.s4 + 22
        let alone = size.width > limit.width
        if x > 0, x + size.width > limit.width {
            x = 0
            y += row + spacing
            row = 0
        }
        if pages.isEmpty || alone || lastAlone || y + size.height > limit.height {
            pages.append([])
            x = 0
            y = 0
            row = 0
        }
        pages[pages.count - 1].append(variation)
        x += size.width + spacing
        row = max(row, size.height)
        lastAlone = alone
    }
    for (index, page) in pages.enumerated() {
        for (scheme, suffix) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            let board = GalleryBoard(entry: entry, variations: page, width: limit.width)
                .background(DesignTokens.Surface.window.color)
                .environment(\.colorScheme, scheme)
                .environment(\.offscreenSnapshot, true)
            let renderer = ImageRenderer(content: board)
            renderer.scale = 2
            let url = folder.appendingPathComponent("\(entry.id)-\(index + 1)-\(suffix).png")
            guard let image = renderer.cgImage,
                let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { fatalError("Could not draw \(entry.id)") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(url.path)") }
            print(url.path)
        }
    }
}

/// The window, laid out as the design catalog is: the entries in a panel on the left, a bar with the appearance on
/// top, and the picked entry's board on the stage.
struct GalleryView: View {
    @State private var picked: String?
    @State private var dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

    init(first: String?) {
        _picked = State(initialValue: first ?? galleryEntries.first?.id)
    }

    private var entry: GalleryEntry? { galleryEntries.first { $0.id == picked } }
    private var panel: RoundedRectangle { RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous) }

    var body: some View {
        HStack(spacing: DesignTokens.Space.s3) {
            sidebar
            VStack(spacing: DesignTokens.Space.s3) {
                bar
                stage
            }
        }
        .padding(DesignTokens.Space.s3)
        .background(DesignTokens.Surface.window.color)
        .environment(\.colorScheme, dark ? .dark : .light)
        .onChange(of: dark, initial: true) { _, dark in
            // AppKit-backed pieces (menus, text views, the focus ring) follow the app's appearance, not the environment.
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignTokens.Space.s3) {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                    .fill(LinearGradient(colors: [DesignTokens.StateSurface.selected.color.color, DesignTokens.Surface.strong.color], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Director gallery").textStyle(.heading).foregroundStyle(DesignTokens.TextColor.primary.color)
                    Text("Components and screens, every variation on one board")
                        .textStyle(.secondary)
                        .foregroundStyle(DesignTokens.TextColor.secondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DesignTokens.Space.s4)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach([GalleryEntry.Kind.component, .screen], id: \.self) { kind in
                        Text(kind == .component ? "COMPONENTS" : "SCREENS")
                            .textStyle(.label)
                            .foregroundStyle(DesignTokens.TextColor.tertiary.color)
                            .padding(.horizontal, DesignTokens.Space.s3)
                            .padding(.top, DesignTokens.Space.s4)
                            .padding(.bottom, DesignTokens.Space.s1)
                        ForEach(galleryEntries.filter { $0.kind == kind }, id: \.id) { entry in
                            Button { picked = entry.id } label: {
                                HStack {
                                    Text(entry.title).textStyle(.body).foregroundStyle(DesignTokens.TextColor.primary.color)
                                    Spacer(minLength: DesignTokens.Space.s2)
                                    Text("\(variations(of: entry).count)").textStyle(.label).foregroundStyle(DesignTokens.TextColor.tertiary.color)
                                }
                                .padding(.horizontal, DesignTokens.Space.s3)
                                .padding(.vertical, 6)
                                .background(
                                    picked == entry.id ? DesignTokens.StateSurface.selected.color.color : .clear,
                                    in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(entry.title)
                            .accessibilityIdentifier("gallery.entry.\(entry.id)")
                            .accessibilityAddTraits(picked == entry.id ? .isSelected : [])
                        }
                    }
                }
                .padding(.horizontal, DesignTokens.Space.s2)
                .padding(.bottom, DesignTokens.Space.s3)
            }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DesignTokens.Surface.content.color, in: panel)
        .overlay(panel.strokeBorder(DesignTokens.Surface.separator.color))
    }

    private var bar: some View {
        HStack(spacing: DesignTokens.Space.s3) {
            Text(entry.map { $0.kind == .component ? "Components" : "Screens" } ?? "")
                .textStyle(.body)
                .foregroundStyle(DesignTokens.TextColor.secondary.color)
            Text("/").textStyle(.body).foregroundStyle(DesignTokens.TextColor.tertiary.color)
            Text(entry?.title ?? "No entry picked")
                .textStyle(.heading)
                .foregroundStyle(DesignTokens.TextColor.primary.color)
                .accessibilityIdentifier("gallery.entry")
            if let entry {
                Text("\(variations(of: entry).count) variations").textStyle(.secondary).foregroundStyle(DesignTokens.TextColor.tertiary.color)
            }
            Spacer()
            Text("Theme").textStyle(.label).foregroundStyle(DesignTokens.TextColor.secondary.color)
            HStack(spacing: 2) {
                ForEach([(false, "Light"), (true, "Dark")], id: \.1) { value, title in
                    Button { dark = value } label: {
                        Text(title)
                            .textStyle(.rowTitle)
                            .foregroundStyle(DesignTokens.TextColor.primary.color)
                            .padding(.horizontal, DesignTokens.Space.s3)
                            .padding(.vertical, 5)
                            .background(dark == value ? DesignTokens.Surface.raised.color : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) theme")
                    .accessibilityAddTraits(dark == value ? .isSelected : [])
                }
            }
            .padding(3)
            .background(DesignTokens.Surface.sunken.color, in: Capsule())
        }
        .padding(.horizontal, DesignTokens.Space.s4)
        .padding(.vertical, DesignTokens.Space.s2)
        .background(DesignTokens.Surface.content.color, in: panel)
        .overlay(panel.strokeBorder(DesignTokens.Surface.separator.color))
    }

    private var stage: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                if let entry {
                    GalleryBoard(entry: entry, variations: variations(of: entry), width: max(geometry.size.width - 2 * DesignTokens.Space.s8, 320))
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                        .id(entry.id)
                }
            }
        }
        .accessibilityLabel("Stage")
    }
}
