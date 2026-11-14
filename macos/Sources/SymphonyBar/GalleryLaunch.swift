import Foundation

/// QA's way into the Component Gallery (`Gallery/`, `make gallery`). The gallery is a program of its own, kept out of
/// the app; a QA build carries it at `Contents/Helpers/SymphonyGallery`. QA's `qa_launch_app` starts only the app,
/// with the fixture folder it names, so the folder `Tests/Fixtures/gallery` is the request: it holds a file named
/// `gallery`, and the app, launched on it, runs the gallery in its own place, with the arguments the app was given.
/// The process keeps its pid, so QA's tools drive the gallery's window as they would the app's.
enum GalleryLaunch {
    static let marker = "gallery"
    static let helper = "Contents/Helpers/SymphonyGallery"

    /// The gallery to run in the app's place, or nil: QA's fixture folder holds the marker and this bundle carries
    /// the gallery.
    static func executable(
        environment: [String: String], bundle: URL, exists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> String? {
        guard let fixtures = environment["SYMPHONY_BAR_QA_API_FIXTURES"], !fixtures.isEmpty,
            exists(URL(fileURLWithPath: fixtures).appendingPathComponent(marker).path)
        else { return nil }
        let path = bundle.appendingPathComponent(helper).path
        return exists(path) ? path : nil
    }

    /// Replaces this process with the gallery when QA asked for it; returns when it did not, or the gallery could
    /// not start.
    /// The app's own arguments go to the gallery, so a launch names the entry it opens on (`--open button`,
    /// `--variation`, `--width`, `--dark`).
    static func runIfAsked() {
        guard let path = executable(environment: ProcessInfo.processInfo.environment, bundle: Bundle.main.bundleURL) else { return }
        var arguments: [UnsafeMutablePointer<CChar>?] = ([path] + CommandLine.arguments.dropFirst()).map { strdup($0) } + [nil]
        execv(path, &arguments)
    }
}
