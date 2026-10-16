import AppKit
import SymphonyBarCore

// Top-level code runs on the main thread; say so, since AppDelegate is main-actor isolated.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Info.plist sets LSUIElement too; this keeps the Dock icon hidden when the binary runs outside the bundle.
    app.setActivationPolicy(.accessory)
    // QA mode can launch the app light or dark whatever the Mac's appearance, which QA never switches.
    switch AppStores.current.qaMode?.appearance {
    case .light: app.appearance = NSAppearance(named: .aqua)
    case .dark: app.appearance = NSAppearance(named: .darkAqua)
    case nil: break
    }
    app.run()
}
