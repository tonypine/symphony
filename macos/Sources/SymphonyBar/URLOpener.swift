import AppKit
import SwiftUI
import SymphonyBarCore

/// Opens the links the app's buttons name: a Linear link in the Linear desktop app when it is installed, so the
/// browser doesn't start just to hand it on; any other link, or a Linear link without the app, as before.
enum URLOpener {
    static func open(_ url: URL) {
        NSWorkspace.shared.open(
            LinearLink.target(for: url) { NSWorkspace.shared.urlForApplication(toOpen: $0) != nil }
        )
    }

    /// SwiftUI's `openURL` for a window's root view, so `Link`s and context-menu buttons open links the same way.
    static let action = OpenURLAction { url in
        open(url)
        return .handled
    }
}
