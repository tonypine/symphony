import AppKit

// Top-level code runs on the main thread; say so, since AppDelegate is main-actor isolated.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Info.plist sets LSUIElement too; this keeps the Dock icon hidden when the binary runs outside the bundle.
    app.setActivationPolicy(.accessory)
    app.run()
}
