import AppKit
import SymphonyBarCore

/// The Mac opens a question's file location (TP-1386): an HTML file in the default browser (the app that opens web
/// links, even when another app is the default for `.html`), anything else shown in Finder.
extension NSWorkspace: FileLocationWorkspace {
    public func openInBrowser(_ url: URL) {
        guard let web = URL(string: "https://example.com"), let browser = urlForApplication(toOpen: web) else {
            open(url)
            return
        }
        open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
    }

    public func revealInFinder(_ url: URL) {
        activateFileViewerSelecting([url])
    }
}
