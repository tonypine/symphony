// The Component Gallery: the app's shared components and screens, each shown with every one of its variations
// together on one board, drawn by the app's own views from made-up inputs or a committed fixture. It is the app's
// counterpart of the HTML catalog: the same isolation, the real views, and live, so a board's controls can be hovered,
// pressed and reached with Tab. The entries are in Entries.swift; their variations in main.swift and *Stories.swift.
//
//   SymphonyGallery                       the window: the entries on the left, the picked one's board on the right
//   SymphonyGallery --open <entry>        the window, on that entry (`--dark` for the dark appearance)
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
    window.center()
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    app.run()
}

/// An entry's board: each variation under its name, one below the other.
struct GalleryBoard: View {
    let variations: [GalleryVariation]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(variations) { variation in
                VStack(alignment: .leading, spacing: 8) {
                    Text(variation.id)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    variation.view
                }
            }
        }
        .padding(32)
    }
}

/// Draws the entry's board to files: still, at twice its size, in light and in dark. A board taller or wider than a
/// picture is worth reading is cut between variations into a few pictures.
@MainActor
func shoot(_ entry: GalleryEntry, into folder: URL) {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let limit = CGSize(width: 2700, height: 2400)
    var pages: [[GalleryVariation]] = []
    var height: CGFloat = 0
    var lastAlone = false
    for variation in variations(of: entry) {
        let size = NSHostingView(rootView: variation.view).fittingSize
        // A variation as large as a screen gets a picture to itself.
        let alone = size.width > limit.width / 2 || size.height > limit.height / 2
        if pages.isEmpty || alone || lastAlone || height + size.height > limit.height {
            pages.append([variation])
            height = size.height
        } else {
            pages[pages.count - 1].append(variation)
            height += size.height + 60
        }
        lastAlone = alone
    }
    for (index, page) in pages.enumerated() {
        for (scheme, suffix) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            let board = GalleryBoard(variations: page)
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

/// The window: the entries on the left, the picked one's board on the right in the appearance chosen.
struct GalleryView: View {
    @State private var picked: String?
    @State private var dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

    init(first: String?) {
        _picked = State(initialValue: first ?? galleryEntries.first?.id)
    }

    private var entry: GalleryEntry? { galleryEntries.first { $0.id == picked } }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $picked) {
                ForEach([GalleryEntry.Kind.component, .screen], id: \.self) { kind in
                    Section(kind == .component ? "Components" : "Screens") {
                        ForEach(galleryEntries.filter { $0.kind == kind }, id: \.id) { entry in
                            Text(entry.title).tag(Optional(entry.id))
                        }
                    }
                }
            }
            .accessibilityLabel("Entries")
            .frame(width: 300)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(entry?.title ?? "No entry picked")
                        .font(.headline)
                        .accessibilityIdentifier("gallery.entry")
                    if let entry {
                        Text("\(variations(of: entry).count) variations")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Appearance", selection: $dark) {
                        Text("Light").tag(false)
                        Text("Dark").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Appearance")
                }
                .padding(8)
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    if let entry {
                        GalleryBoard(variations: variations(of: entry))
                            .id(entry.id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DesignTokens.Surface.window.color)
                .environment(\.colorScheme, dark ? .dark : .light)
            }
        }
        .onChange(of: dark, initial: true) { _, dark in
            // AppKit-backed pieces (menus, text views, the focus ring) follow the app's appearance, not the environment.
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        }
    }
}
