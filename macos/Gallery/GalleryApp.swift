// The Component Gallery: the app's shared components, and the sections and pages built from them, each in the cases
// its ticket thought through (main.swift and the *Stories.swift files), shown one at a time in a window. It is the
// app's own counterpart of the HTML catalog: the same isolation, drawn by the real views, and live, so a story can be
// hovered, pressed and reached with Tab.
//
//   SymphonyGallery                     the window: stories on the left, the picked one on the right
//   SymphonyGallery --story <id>        the window, opened on that story
//   SymphonyGallery --list              prints every story's id
//   SymphonyGallery --shot <pattern> --out <dir>
//                                       draws the stories whose id matches the shell pattern (`button-*`), in light and
//                                       in dark, as `<dir>/<id>-<light|dark>.png`, without opening a window
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

/// One story: its id (`button-primary-hover`) and the view it draws.
struct GalleryStory: Identifiable {
    let id: String
    let view: AnyView

    /// The component or page the story belongs to: its id's first word.
    var group: String { id.split(separator: "-").first.map(String.init) ?? id }
}

@MainActor var galleryStories: [GalleryStory] = []

/// Names one story. The stories are listed once per appearance, as they were when each was a picture; the gallery
/// keeps the first listing and draws either appearance itself.
@MainActor
func render(_ view: some View, _ scheme: ColorScheme, to name: String) {
    guard scheme == .light else { return }
    galleryStories.append(GalleryStory(id: name.replacingOccurrences(of: "-light.png", with: ""), view: AnyView(view)))
}

@MainActor
func runGallery() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    func value(after flag: String) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }
    if arguments.contains("--list") {
        for story in galleryStories { print(story.id) }
        return
    }
    if let pattern = value(after: "--shot") {
        guard let out = value(after: "--out") else { fatalError("--shot needs --out <dir>") }
        shoot(pattern, into: URL(fileURLWithPath: out))
        return
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    window.title = "Component Gallery"
    window.contentView = NSHostingView(rootView: GalleryView(stories: galleryStories, first: value(after: "--story")))
    window.center()
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    app.run()
}

/// Draws the stories matching `pattern` to files, as the snapshots were drawn: still, at twice their size.
@MainActor
func shoot(_ pattern: String, into folder: URL) {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let matching = galleryStories.filter { fnmatch(pattern, $0.id, 0) == 0 }
    guard !matching.isEmpty else { fatalError("No story matches \(pattern); --list names them") }
    for story in matching {
        for (scheme, suffix) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            let renderer = ImageRenderer(content: story.view.environment(\.colorScheme, scheme).environment(\.offscreenSnapshot, true))
            renderer.scale = 2
            let url = folder.appendingPathComponent("\(story.id)-\(suffix).png")
            guard let image = renderer.cgImage,
                let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { fatalError("Could not draw \(story.id)") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(url.path)") }
            print("wrote \(url.path)")
        }
    }
}

/// The window: the stories by component on the left, the picked one on the right in the appearance chosen.
struct GalleryView: View {
    let stories: [GalleryStory]
    @State private var picked: String?
    @State private var search = ""
    @State private var dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

    init(stories: [GalleryStory], first: String?) {
        self.stories = stories
        _picked = State(initialValue: first ?? stories.first?.id)
    }

    private var shown: [(group: String, stories: [GalleryStory])] {
        let matching = stories.filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) }
        var groups: [(group: String, stories: [GalleryStory])] = []
        for story in matching {
            if let index = groups.firstIndex(where: { $0.group == story.group }) {
                groups[index].stories.append(story)
            } else {
                groups.append((story.group, [story]))
            }
        }
        return groups
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("Find a story", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                    .accessibilityLabel("Find a story")
                List(selection: $picked) {
                    ForEach(shown, id: \.group) { group in
                        Section(group.group) {
                            ForEach(group.stories) { story in
                                Text(story.id).tag(Optional(story.id))
                            }
                        }
                    }
                }
                .accessibilityLabel("Stories")
            }
            .frame(width: 320)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(picked ?? "No story picked")
                        .font(.headline)
                        .accessibilityIdentifier("gallery.story")
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
                    if let story = stories.first(where: { $0.id == picked }) {
                        story.view
                            .id(story.id)
                            .padding(32)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("Stage")
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
