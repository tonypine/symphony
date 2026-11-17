// Where the gallery reads the committed fixtures its stories are drawn from, and the shared files `--check` lists.
//
// In a checkout that is the source tree itself, found from this file's place in it (`#filePath`). A built gallery
// that travels without the checkout (the QA build, a test's copy) carries a copy of what it reads, staged by
// `make gallery-resources` into a folder named `GalleryResources` beside the helper or in the bundle's Resources
// (`Contents/Resources/GalleryResources` for the helper at `Contents/Helpers/SymphonyGallery`). The copy keeps the
// checkout's layout (`macos/Tests/Fixtures/…`, `test/fixtures/api/…`, `macos/Sources/SymphonyBarUI/…`), so every story
// reads the same path under either root. A copy, when there is one, wins: a build that carries one reads nothing else.
import Foundation

enum GalleryFiles {
    static let folder = "GalleryResources"

    /// The checkout's root as the gallery reads it: the copy beside `executable` or in its bundle's Resources, else
    /// `source`.
    static func root(executable: URL, source: URL, exists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> URL {
        let directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        let copies = [
            directory.appendingPathComponent(folder),
            directory.deletingLastPathComponent().appendingPathComponent("Resources").appendingPathComponent(folder),
        ]
        return copies.first(where: { exists($0.path) }) ?? source
    }
}

/// The root every story's fixture is read under (see `GalleryFiles`).
let galleryRoot = GalleryFiles.root(
    executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
    source: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
)
/// The gallery's own folder under that root (`macos/Gallery`): the stories name their fixtures from here.
let galleryFolder = galleryRoot.appendingPathComponent("macos/Gallery")
