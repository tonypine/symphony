// Prints the windows on screen, one per line: owner name, owner pid and layer, tab-separated.
// CoreGraphics only, no AppKit: it lists windows without opening one. The `appkit_dialog` test runs
// it on a disposable macOS runner to see the probe's window and any crash dialog.
import CoreGraphics

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

for window in windows {
  let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
  let pid = window[kCGWindowOwnerPID as String] as? Int ?? 0
  let layer = window[kCGWindowLayer as String] as? Int ?? 0
  print("\(owner)\t\(pid)\t\(layer)")
}
