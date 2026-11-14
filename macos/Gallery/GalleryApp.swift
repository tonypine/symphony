// The Component Gallery: the app's shared components and screens, drawn by the app's own views from made-up inputs
// or a committed fixture. It is the app's counterpart of the HTML catalog: the same isolation, the real views, and
// live, so controls can be hovered, pressed and reached with Tab. The entries are in Entries.swift; their variations
// in main.swift and *Stories.swift.
//
// A component shows every variation together, on one board. A screen shows one variation at a time, alone on the
// stage: its variations are listed under it, and the picked one is drawn as the app draws it in a window of the width
// picked in the bar (a laptop's, a desktop's, or as wide as the stage), at its true size: nothing is ever scaled.
//
//   SymphonyGallery                       the window: the entries on the left, the picked one on the right
//   SymphonyGallery --open <entry> [--variation <name>] [--width laptop|desktop|<points>]
//                                         the window, on that entry (a screen: on that variation, the first when none
//                                         is named, drawn as a window that wide draws it, or as wide as the stage;
//                                         `--dark` for the dark appearance). It fills the screen, over the menu bar
//                                         and the Dock; `--window` keeps it a window
//   SymphonyGallery --entries             the entries, as JSON: id, title, kind, variations, the files each shows
//   SymphonyGallery --affected            the entries a change is a reason to look at, as JSON; the changed files'
//                                         repository paths come one per line on standard input
//   SymphonyGallery --shot <entry> [--variation <name>] [--width laptop|desktop|<points>] --out <dir>
//                                         draws the entry to files, without a window. A component: its board, as
//                                         `<dir>/<entry>-<n>-<light|dark>.png`, one picture or a few when it is tall.
//                                         A screen: each variation, or the named one, as
//                                         `<dir>/<variation>-<laptop|desktop|points>-<light|dark>.png`, at both
//                                         widths or at the named one; a variation of one size (a sheet) as
//                                         `<dir>/<variation>-<light|dark>.png`
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

/// One variation of an entry: its name (`button-primary-hover`) and the view it draws. A screen's variation that
/// follows its window's width has `sized`, which draws it for a window that wide; `view` is then the laptop's.
struct GalleryVariation: Identifiable {
    let id: String
    let view: AnyView
    var sized: (@MainActor (CGFloat) -> AnyView)?
}

/// The window widths a screen is looked at in.
enum GalleryWidth {
    static let named: [(name: String, points: CGFloat)] = [("laptop", 1440), ("desktop", 2560)]

    /// `laptop`, `desktop` or a number of points; nil for anything else.
    static func points(_ word: String) -> CGFloat? {
        named.first { $0.name == word }?.points ?? Double(word).map { CGFloat($0) }
    }

    static func name(_ points: CGFloat) -> String { named.first { $0.points == points }?.name ?? "\(Int(points))" }
}

@MainActor var galleryVariations: [GalleryVariation] = []

/// Names one variation. They are listed once per appearance, as they were when each was a picture; the gallery keeps
/// the first listing and draws either appearance itself.
@MainActor
func render(_ view: some View, _ scheme: ColorScheme, to name: String) {
    guard scheme == .light else { return }
    galleryVariations.append(GalleryVariation(id: name.replacingOccurrences(of: "-light.png", with: ""), view: AnyView(view)))
}

/// Names one variation of a screen that follows its window's width: `draw` draws it for a window that wide.
@MainActor
func renderScreen<Content: View>(_ scheme: ColorScheme, to name: String, _ draw: @escaping @MainActor (CGFloat) -> Content) {
    guard scheme == .light else { return }
    galleryVariations.append(GalleryVariation(id: name, view: AnyView(draw(GalleryWidth.named[0].points)), sized: { AnyView(draw($0)) }))
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
    func variation(_ name: String, of entry: GalleryEntry) -> GalleryVariation {
        let own = variations(of: entry)
        guard let found = own.first(where: { $0.id == name }) else {
            FileHandle.standardError.write("\(entry.id) has no variation named \(name). Its variations: \(own.map(\.id).joined(separator: ", "))\n".data(using: .utf8)!)
            exit(2)
        }
        return found
    }
    let width = value(after: "--width").map { word -> CGFloat in
        guard let points = GalleryWidth.points(word) else {
            FileHandle.standardError.write("--width takes laptop, desktop or a number of points, not \(word)\n".data(using: .utf8)!)
            exit(2)
        }
        return points
    }
    if arguments.contains("--entries") {
        print(json([
            "entries": galleryEntries.map { entry in
                [
                    "id": entry.id, "title": entry.title, "kind": entry.kind.rawValue, "variations": variations(of: entry).map(\.id),
                    "follow_width": variations(of: entry).filter { $0.sized != nil }.map(\.id), "files": entry.files,
                ]
            },
            "widths": Dictionary(uniqueKeysWithValues: GalleryWidth.named.map { ($0.name, Int($0.points)) }),
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
        shoot(entry(id), only: value(after: "--variation").map { variation($0, of: entry(id)).id }, width: width, into: URL(fileURLWithPath: out))
        return
    }
    let first = value(after: "--open").map { entry($0).id }
    let firstVariation = first.flatMap { id in value(after: "--variation").map { variation($0, of: entry(id)).id } }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    if arguments.contains("--dark") { app.appearance = NSAppearance(named: .darkAqua) }
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    window.title = "Component Gallery"
    window.contentView = NSHostingView(rootView: GalleryView(first: first, variation: firstVariation, width: width))
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

/// Cells packed as a pinboard packs its cards: each at its own size, in the lowest place it fits, the leftmost of
/// those. Narrow cells sit beside each other and under shorter ones, so a board uses its width whatever its cells'
/// sizes. A cell wider than `width` (a screen) takes a line to itself.
struct PinboardLayout: Layout {
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
        Self.pack(subviews.map { $0.sizeThatFits(.unspecified) }, width: width, spacing: spacing)
    }

    /// The skyline: the top edge of what is placed, as steps from left to right. A cell goes where a run of steps as
    /// wide as it is lies lowest.
    static func pack(_ sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> (size: CGSize, points: [CGPoint]) {
        var skyline: [(x: CGFloat, width: CGFloat, y: CGFloat)] = [(0, max(width, 1), 0)]
        var points: [CGPoint] = []
        var extent = CGSize.zero
        for size in sizes {
            let needed = min(size.width + spacing, max(width, 1))
            var best: (x: CGFloat, y: CGFloat)?
            for (index, step) in skyline.enumerated() where step.x + needed <= max(width, 1) + spacing {
                var y = step.y
                var covered: CGFloat = 0
                var next = index
                while covered < needed, next < skyline.count {
                    y = max(y, skyline[next].y)
                    covered += skyline[next].width
                    next += 1
                }
                if covered >= needed || next == skyline.count, best == nil || y < best!.y { best = (step.x, y) }
            }
            let place = best ?? (0, skyline.map(\.y).max() ?? 0)
            points.append(CGPoint(x: place.x, y: place.y))
            let top = place.y + size.height + spacing
            let right = place.x + needed
            var raised: [(x: CGFloat, width: CGFloat, y: CGFloat)] = []
            for step in skyline {
                let end = step.x + step.width
                if end <= place.x || step.x >= right { raised.append(step); continue }
                if step.x < place.x { raised.append((step.x, place.x - step.x, step.y)) }
                if end > right { raised.append((right, end - right, step.y)) }
            }
            raised.append((place.x, needed, top))
            skyline = raised.sorted { $0.x < $1.x }
            extent.width = max(extent.width, place.x + size.width)
            extent.height = max(extent.height, place.y + size.height)
        }
        return (extent, points)
    }
}

/// A component's board: every variation in a cell under its name, the cells packed into `width`.
struct GalleryBoard: View {
    let entry: GalleryEntry
    let variations: [GalleryVariation]
    let width: CGFloat

    var body: some View {
        PinboardLayout(width: width, spacing: DesignTokens.Space.s5) {
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

    private func name(_ variation: GalleryVariation) -> String { shortName(variation, in: entry) }
}

/// The variation's name without its entry's prefix: `button-primary-hover` reads "primary hover".
func shortName(_ variation: GalleryVariation, in entry: GalleryEntry) -> String {
    let prefix = entry.prefixes.filter { variation.id.hasPrefix($0) }.max { $0.count < $1.count } ?? ""
    let rest = variation.id.dropFirst(prefix.count).replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
    // A component whose cases are one cell (`badge-cases`) is named by the component: two of them share a board.
    if rest == "cases" { return prefix.replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces) }
    return rest.isEmpty ? variation.id.replacingOccurrences(of: "-", with: " ") : rest
}

@MainActor
private func write(_ view: some View, scheme: ColorScheme, scale: CGFloat, to url: URL) {
    let renderer = ImageRenderer(content: view.background(DesignTokens.Surface.window.color).environment(\.colorScheme, scheme).environment(\.offscreenSnapshot, true))
    renderer.scale = scale
    guard let image = renderer.cgImage,
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("Could not draw \(url.lastPathComponent)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(url.path)") }
    print(url.path)
}

/// Draws the entry to files: still, in light and in dark. A component's board is drawn at twice its size, and cut
/// between cells into a few pictures when it is taller than a picture is worth reading. A screen's variations are
/// drawn one to a picture (`only`: that one), each at its true size: one that follows its window's width at `width`,
/// or at the laptop's and at the desktop's.
@MainActor
func shoot(_ entry: GalleryEntry, only: String? = nil, width: CGFloat? = nil, into folder: URL) {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let schemes = [(ColorScheme.light, "light"), (ColorScheme.dark, "dark")]
    let own = variations(of: entry).filter { only == nil || $0.id == only }
    if entry.kind == .screen {
        for variation in own {
            let drawings: [(String, AnyView)] = variation.sized.map { sized in
                (width.map { [$0] } ?? GalleryWidth.named.map(\.points)).map { ("\(variation.id)-\(GalleryWidth.name($0))", sized($0)) }
            } ?? [(variation.id, variation.view)]
            for (name, view) in drawings {
                // A wide screen is already a large picture: twice the size only when it is narrow.
                let scale: CGFloat = NSHostingView(rootView: view).fittingSize.width > 1600 ? 1 : 2
                for (scheme, suffix) in schemes {
                    write(view.fixedSize(), scheme: scheme, scale: scale, to: folder.appendingPathComponent("\(name)-\(suffix).png"))
                }
            }
        }
        return
    }
    let limit = CGSize(width: 1600, height: 2000)
    let spacing = DesignTokens.Space.s5
    let sizes = own.map { variation -> CGSize in
        var size = NSHostingView(rootView: variation.view).fittingSize
        size.width += 2 * DesignTokens.Space.s4
        size.height += 2 * DesignTokens.Space.s4 + 22
        return size
    }
    // Cells go on a page while the page, packed, stays within the limit.
    var pages: [[Int]] = []
    for index in own.indices {
        if let last = pages.last, PinboardLayout.pack((last + [index]).map { sizes[$0] }, width: limit.width, spacing: spacing).size.height <= limit.height {
            pages[pages.count - 1].append(index)
        } else {
            pages.append([index])
        }
    }
    for (index, page) in pages.enumerated() {
        for (scheme, suffix) in schemes {
            write(GalleryBoard(entry: entry, variations: page.map { own[$0] }, width: limit.width), scheme: scheme, scale: 2,
                  to: folder.appendingPathComponent("\(entry.id)-\(index + 1)-\(suffix).png"))
        }
    }
}

/// One variation of a screen, alone, at its true size: as a window `window` wide draws it when it follows its
/// window's width, else at its own size. Narrower than the stage it sits in the middle; wider, the stage scrolls.
struct GalleryScreen: View {
    let variation: GalleryVariation
    let window: CGFloat
    let stage: CGFloat
    /// Told the width it drew at, so the stage scrolls sideways only for a screen wider than it.
    let drawn: (CGFloat) -> Void

    var body: some View {
        (variation.sized?(window) ?? variation.view)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { drawn($0) }
            .frame(minWidth: stage, alignment: .top)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(variation.id)
    }
}

/// The window, laid out as the design catalog is: the entries in a panel on the left, a bar with the appearance on
/// top, and the picked entry's board on the stage.
struct GalleryView: View {
    @State private var picked: String?
    @State private var dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    /// The list of entries. Opened on one entry (`--open`), the gallery starts with the list folded away, so a
    /// picture of the screen is the board and nothing beside it.
    @State private var showsEntries: Bool

    /// The variation shown, when the picked entry is a screen.
    @State private var variation: String?

    /// How wide the screen shown drew.
    @State private var drawn: CGFloat = 0
    /// The window a screen is drawn for: a named width, or nil for one whose page is as wide as the stage.
    @State private var window: CGFloat?

    init(first: String?, variation: String? = nil, width: CGFloat? = nil) {
        _window = State(initialValue: width)
        let picked = first ?? galleryEntries.first?.id
        _picked = State(initialValue: picked)
        _variation = State(initialValue: variation ?? galleryEntries.first { $0.id == picked && $0.kind == .screen }.flatMap { variations(of: $0).first?.id })
        _showsEntries = State(initialValue: first == nil)
    }

    private var entry: GalleryEntry? { galleryEntries.first { $0.id == picked } }
    private var shown: GalleryVariation? { entry.flatMap { entry in variations(of: entry).first { $0.id == variation } } }

    private func pick(_ entry: GalleryEntry) {
        picked = entry.id
        variation = entry.kind == .screen ? variations(of: entry).first?.id : nil
    }

    /// The variation before (`-1`) or after (`1`) the one shown, around the ends.
    private func step(_ by: Int) {
        guard let entry, let at = variations(of: entry).firstIndex(where: { $0.id == variation }) else { return }
        let own = variations(of: entry)
        variation = own[(at + by + own.count) % own.count].id
    }
    private var panel: RoundedRectangle { RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous) }

    var body: some View {
        // A screen's stage runs from edge to edge, so a desktop's window fits a 2560 pt display whole.
        HStack(spacing: 0) {
            if showsEntries { sidebar.padding(.leading, DesignTokens.Space.s3) }
            VStack(spacing: DesignTokens.Space.s3) {
                bar.padding(.horizontal, DesignTokens.Space.s3)
                stage.padding(.horizontal, shown == nil ? DesignTokens.Space.s3 : 0)
            }
        }
        .padding(.vertical, DesignTokens.Space.s3)
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
                            Button { pick(entry) } label: {
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
                            if entry.kind == .screen, picked == entry.id {
                                ForEach(variations(of: entry)) { own in
                                    Button { variation = own.id } label: {
                                        Text(shortName(own, in: entry))
                                            .textStyle(.secondary)
                                            .foregroundStyle((variation == own.id ? DesignTokens.TextColor.primary : DesignTokens.TextColor.secondary).color)
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.leading, DesignTokens.Space.s6)
                                            .padding(.trailing, DesignTokens.Space.s3)
                                            .padding(.vertical, 4)
                                            .background(
                                                variation == own.id ? DesignTokens.Surface.raised.color : .clear,
                                                in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
                                            )
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(own.id)
                                    .accessibilityIdentifier("gallery.variation.\(own.id)")
                                    .accessibilityAddTraits(variation == own.id ? .isSelected : [])
                                }
                            }
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
            Button { showsEntries.toggle() } label: {
                Image(systemName: "sidebar.left")
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .padding(DesignTokens.Space.s1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsEntries ? "Hide the entries" : "Show the entries")
            Text(entry.map { $0.kind == .component ? "Components" : "Screens" } ?? "")
                .textStyle(.body)
                .foregroundStyle(DesignTokens.TextColor.secondary.color)
            Text("/").textStyle(.body).foregroundStyle(DesignTokens.TextColor.tertiary.color)
            Text(entry?.title ?? "No entry picked")
                .textStyle(.heading)
                .foregroundStyle(DesignTokens.TextColor.primary.color)
                .accessibilityIdentifier("gallery.entry")
            if let entry, let shown {
                let own = variations(of: entry)
                Text("/").textStyle(.body).foregroundStyle(DesignTokens.TextColor.tertiary.color)
                Text(shortName(shown, in: entry))
                    .textStyle(.heading)
                    .foregroundStyle(DesignTokens.TextColor.primary.color)
                    .accessibilityIdentifier("gallery.variation")
                Text("\((own.firstIndex { $0.id == shown.id } ?? 0) + 1) of \(own.count)").textStyle(.secondary).foregroundStyle(DesignTokens.TextColor.tertiary.color)
                ForEach([(-1, "chevron.left", "Previous variation"), (1, "chevron.right", "Next variation")], id: \.0) { by, glyph, label in
                    Button { step(by) } label: {
                        Image(systemName: glyph)
                            .foregroundStyle(DesignTokens.TextColor.secondary.color)
                            .padding(DesignTokens.Space.s1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(label)
                }
            } else if let entry {
                Text("\(variations(of: entry).count) variations").textStyle(.secondary).foregroundStyle(DesignTokens.TextColor.tertiary.color)
            }
            Spacer()
            if shown?.sized != nil {
                Text("Window").textStyle(.label).foregroundStyle(DesignTokens.TextColor.secondary.color)
                segments(GalleryWidth.named.map { (Optional($0.points), "\($0.name.capitalized) \(Int($0.points))", "\($0.name.capitalized) window") } + [(nil, "Fill", "Window that fills the stage")], picked: window) { window = $0 }
            }
            Text("Theme").textStyle(.label).foregroundStyle(DesignTokens.TextColor.secondary.color)
            segments([(false, "Light", "Light theme"), (true, "Dark", "Dark theme")], picked: dark) { dark = $0 }
        }
        .padding(.horizontal, DesignTokens.Space.s4)
        .padding(.vertical, DesignTokens.Space.s2)
        .background(DesignTokens.Surface.content.color, in: panel)
        .overlay(panel.strokeBorder(DesignTokens.Surface.separator.color))
    }

    /// A row of choices, one picked: the theme, a screen's window.
    private func segments<Value: Hashable>(_ choices: [(Value, String, String)], picked: Value, pick: @escaping (Value) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(choices, id: \.0) { value, title, label in
                Button { pick(value) } label: {
                    Text(title)
                        .textStyle(.rowTitle)
                        .foregroundStyle(DesignTokens.TextColor.primary.color)
                        .padding(.horizontal, DesignTokens.Space.s3)
                        .padding(.vertical, 5)
                        .background(picked == value ? DesignTokens.Surface.raised.color : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityAddTraits(picked == value ? .isSelected : [])
            }
        }
        .padding(3)
        .background(DesignTokens.Surface.sunken.color, in: Capsule())
    }

    private var stage: some View {
        GeometryReader { geometry in
            // A board packs into the stage's width and scrolls down. A screen scrolls sideways too, while it is wider
            // than the stage.
            ScrollView(shown != nil && drawn > geometry.size.width + 0.5 ? [.horizontal, .vertical] : .vertical) {
                if let shown {
                    GalleryScreen(variation: shown, window: window ?? geometry.size.width + DesignTokens.Layout.sidebarWidth, stage: geometry.size.width) { drawn = $0 }
                        .id(shown.id)
                } else if let entry {
                    GalleryBoard(entry: entry, variations: variations(of: entry), width: max(geometry.size.width - 2 * DesignTokens.Space.s8, 320))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .id(entry.id)
                }
            }
            // A screen's stage has no bar on its side: one that is always drawn (no trackpad) would take its width from
            // the screen, and a window that fills the stage would no longer fit it. The bar along the bottom is there
            // only while the screen is wider than the stage.
            .scrollIndicators(shown == nil ? .automatic : .never, axes: .vertical)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .accessibilityLabel("Stage")
    }
}
