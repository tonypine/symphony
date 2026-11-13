// The Component Gallery: the app's shared components and screens, drawn by the app's own views from made-up inputs
// or a committed fixture. It is the app's counterpart of the HTML catalog: the same isolation, the real views, and
// live, so controls can be hovered, pressed and reached with Tab. The entries are in Entries.swift; their variations
// in main.swift and *Stories.swift.
//
// A component shows every variation together, on one board. A screen shows one variation at a time, alone on the
// stage: its variations are listed under it, and the picked one is drawn as wide as the stage lets it be.
//
//   SymphonyGallery                       the window: the entries on the left, the picked one on the right
//   SymphonyGallery --open <entry> [--variation <name>]
//                                         the window, on that entry (a screen: on that variation, the first when none
//                                         is named; `--dark` for the dark appearance). It fills the screen, over the
//                                         menu bar and the Dock; `--window` keeps it a window
//   SymphonyGallery --entries             the entries, as JSON: id, title, kind, variations, the files each shows
//   SymphonyGallery --affected            the entries a change is a reason to look at, as JSON; the changed files'
//                                         repository paths come one per line on standard input
//   SymphonyGallery --shot <entry> [--variation <name>] --out <dir>
//                                         draws the entry to files, without a window. A component: its board, as
//                                         `<dir>/<entry>-<n>-<light|dark>.png`, one picture or a few when it is tall.
//                                         A screen: `<dir>/<variation>-<light|dark>.png` for each variation, or for
//                                         the named one
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
    func variation(_ name: String, of entry: GalleryEntry) -> GalleryVariation {
        let own = variations(of: entry)
        guard let found = own.first(where: { $0.id == name }) else {
            FileHandle.standardError.write("\(entry.id) has no variation named \(name). Its variations: \(own.map(\.id).joined(separator: ", "))\n".data(using: .utf8)!)
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
        shoot(entry(id), only: value(after: "--variation").map { variation($0, of: entry(id)).id }, into: URL(fileURLWithPath: out))
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
    window.contentView = NSHostingView(rootView: GalleryView(first: first, variation: firstVariation))
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
/// drawn one to a picture (`only`: that one), each at its own size.
@MainActor
func shoot(_ entry: GalleryEntry, only: String? = nil, into folder: URL) {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let schemes = [(ColorScheme.light, "light"), (ColorScheme.dark, "dark")]
    let own = variations(of: entry).filter { only == nil || $0.id == only }
    if entry.kind == .screen {
        for variation in own {
            // A screen at a desktop's width is already a large picture: twice the size only when it is narrow.
            let width = NSHostingView(rootView: variation.view).fittingSize.width
            for (scheme, suffix) in schemes {
                write(variation.view.fixedSize(), scheme: scheme, scale: width > 1600 ? 1 : 2, to: folder.appendingPathComponent("\(variation.id)-\(suffix).png"))
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

/// One variation of a screen, alone: at its own size when the stage is as wide, made smaller to fit when it is not
/// (a desktop's width on a laptop's stage). It stays live either way.
struct GalleryScreen: View {
    let variation: GalleryVariation
    let width: CGFloat
    @State private var natural = CGSize.zero

    private var scale: CGFloat { natural.width > width ? width / natural.width : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            if scale < 1 {
                Text("Shown at \(Int((scale * 100).rounded())) %: it is \(Int(natural.width)) points wide")
                    .textStyle(.label)
                    .foregroundStyle(DesignTokens.TextColor.tertiary.color)
            }
            variation.view
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { natural = $0 }
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: natural.width * scale, height: natural.height * scale, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .top)
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

    init(first: String?, variation: String? = nil) {
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
        HStack(spacing: DesignTokens.Space.s3) {
            if showsEntries { sidebar }
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
            // Down only: a board packs into the stage's width, and a screen wider than the stage is made to fit it.
            ScrollView(.vertical) {
                if let entry, let shown {
                    GalleryScreen(variation: shown, width: geometry.size.width)
                        .id(shown.id)
                } else if let entry {
                    GalleryBoard(entry: entry, variations: variations(of: entry), width: max(geometry.size.width - 2 * DesignTokens.Space.s8, 320))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .id(entry.id)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .accessibilityLabel("Stage")
    }
}
