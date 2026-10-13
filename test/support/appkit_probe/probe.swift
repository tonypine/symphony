// A minimal AppKit program: an `NSApplication` with one `NSWindow` titled "TP-479 probe", which
// quits after 5 seconds. `probe crash` traps (`fatalError`) once the window is up instead, so a
// control run shows what a crash looks like. A background timer ends it after 10 seconds in case
// AppKit hangs without a window server: with `crash` it traps too, so a crash run always crashes.
// It prints "TP-479 probe started" to stderr before it touches AppKit, so the test can tell a run
// that reached AppKit from one the sandbox never started.
//
// The `appkit_dialog` test runs it on a disposable macOS runner only. Never run it on the host: its
// window, and its "quit unexpectedly" dialog when it crashes, land on the operator's screen.
import AppKit

let crash = CommandLine.arguments.dropFirst().first == "crash"
FileHandle.standardError.write(Data("TP-479 probe started\n".utf8))

DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
  if crash { fatalError("TP-479 crash after a hang") }

  exit(3)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let window = NSWindow(
  contentRect: NSRect(x: 200, y: 200, width: 320, height: 200),
  styleMask: [.titled, .closable],
  backing: .buffered,
  defer: false
)
window.title = "TP-479 probe"
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
  if crash { fatalError("TP-479 control crash") }

  app.terminate(nil)
}

app.run()

if crash { fatalError("TP-479 crash after the run loop ended") }
