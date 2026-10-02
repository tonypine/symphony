import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Info.plist sets LSUIElement too; this keeps the Dock icon hidden when the binary runs outside the bundle.
app.setActivationPolicy(.accessory)
app.run()
