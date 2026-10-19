// Symphony QA driver helper, the executable of `SymphonyQADriver.app`.
//
// It runs on the host for the Auto Review QA tools (`SymphonyElixir.QaDriver`).
// Screen Recording and Accessibility are granted to this app only, never to
// Symphony.app: macOS gives every process an app spawns that app's grants, and
// Symphony.app spawns the coding agents. Symphony launches the helper through
// LaunchServices (`open -a`), so the helper is its own responsible process and
// nothing Symphony spawns inherits its grants.
//
//   serve <socket> <owner pid>
//
// listens on a Unix socket and answers only the owner (the Symphony process that
// launched it), and exits when the owner does. The socket must be
// `qa-<owner pid>.sock` in the run directory, `~/Library/Application
// Support/symphony/qa-driver/run`, which must be a `0700` directory of this
// user, and Symphony must have left `qa-<owner pid>.owner` there first. Agent
// sandboxes cannot write that directory, so an agent cannot name itself, or a
// process it starts, the owner, even one it moved out of Symphony's process
// tree. The owner must also be a BEAM that no other BEAM started.
// Each connection sends one JSON line `{"args": [...]}` and gets back
// `{"status", "output"}`: the result of running one of the commands below in a
// child of the helper, which keeps the helper's grants. Commands that take a PID only run for a process that descends
// from the owner, so the helper never reads or drives the operator's other apps.
// The commands that take a PID refuse to run unless a serving helper started
// them, so opening the helper through LaunchServices with one of them (which
// would use its grants on any app) fails; only the copy Symphony compiles on a
// separate QA host (`auto_review.worker_host`) runs them directly. Each command prints one JSON object on
// stdout and exits 0, or prints `{"error": {"code", "message"}}` and exits 1.
//
//   permissions
//   windows <pid>
//   screenshot <pid> <window id> <png path>
//   ax-tree <pid> <max-depth> <max-nodes> <role or ""> <text or "">
//   ax-press <pid> <path> <action>
//   ax-set-value <pid> <path> <value>
//   ax-resize <pid> <window path or ""> <width> <height>
//   ax-ping <pid>
//   ax-select <pid> <path>
//   click <pid> <path> <clicks>
//   hover <pid> <path or x,y>
//   context-menu <pid> <path or x,y>
//   key <pid> <key> <modifiers, comma-separated, or "">
//
// `ax-set-value` types into a text field the way a person does (see
// `enterText`), and sets `AXValue` directly only on other controls.
// `ax-resize` sizes a window for the playbook's wide pass (see `resizeWindow`)
// and `ax-ping` tells a hung app from a busy one; both use the Accessibility
// grant like the other `ax-` commands. `ax-select` selects a table or outline
// row, which answers no AXPress, and `click` and `key` send mouse and key
// events to the app's PID alone (see `selectRow`, `click` and `pressKey`).
// `click`, `hover` and `context-menu` move the real pointer to the target first
// (see `movePointer`), only once the app's own window is in front there.
//
// Opened with no arguments (by hand, from Finder or `open`), it asks for both
// permissions, so that it is listed in System Settings.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let visitLimit = 5000
let textLimit = 200

func emit(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func fail(_ code: String, _ message: String) -> Never {
    emit(["error": ["code": code, "message": message]])
    exit(1)
}

func pidArgument(_ value: String) -> pid_t {
    guard let pid = Int32(value), pid > 0 else { fail("invalid_pid", "PID must be a positive integer.") }
    return pid
}

func requireAccessibility() {
    if !AXIsProcessTrusted() {
        fail("accessibility_permission_missing", "The Symphony host process has no Accessibility permission.")
    }
}

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return result == .success ? value : nil
}

func text(_ value: AnyObject?) -> String? {
    switch value {
    case let string as String:
        return string.isEmpty ? nil : String(string.prefix(textLimit))
    case let number as NSNumber:
        return number.stringValue
    default:
        return nil
    }
}

func point(_ value: AnyObject?) -> CGPoint? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
}

func size(_ value: AnyObject?) -> CGSize? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func describe(_ element: AXUIElement, path: String) -> [String: Any] {
    var node: [String: Any] = ["path": path]
    node["role"] = text(attribute(element, kAXRoleAttribute as String))
    node["subrole"] = text(attribute(element, kAXSubroleAttribute as String))
    node["title"] = text(attribute(element, kAXTitleAttribute as String))
    // A secure field's value never leaves the helper, not even as bullets.
    if node["subrole"] as? String != kAXSecureTextFieldSubrole as String {
        node["value"] = text(attribute(element, kAXValueAttribute as String))
    }
    node["description"] = text(attribute(element, kAXDescriptionAttribute as String))
    // The tooltip's text (SwiftUI `.help`, AppKit `toolTip`), read without hovering.
    node["help"] = text(attribute(element, kAXHelpAttribute as String))
    node["identifier"] = text(attribute(element, kAXIdentifierAttribute as String))

    if let enabled = attribute(element, kAXEnabledAttribute as String) as? Bool, !enabled {
        node["enabled"] = false
    }

    if let focused = attribute(element, kAXFocusedAttribute as String) as? Bool, focused {
        node["focused"] = true
    }

    if let selected = attribute(element, kAXSelectedAttribute as String) as? Bool, selected {
        node["selected"] = true
    }

    node["frame"] = frame(element)
    return node
}

func frame(_ element: AXUIElement) -> [String: Int]? {
    guard let origin = point(attribute(element, kAXPositionAttribute as String)),
          let extent = size(attribute(element, kAXSizeAttribute as String)) else { return nil }
    return ["x": Int(origin.x), "y": Int(origin.y), "w": Int(extent.width), "h": Int(extent.height)]
}

func matches(_ node: [String: Any], role: String, needle: String) -> Bool {
    if !role.isEmpty, (node["role"] as? String) != role { return false }
    if needle.isEmpty { return true }

    return ["title", "value", "description", "help", "identifier"].contains { key in
        (node[key] as? String)?.localizedCaseInsensitiveContains(needle) ?? false
    }
}

final class TreeWalk {
    let maxDepth: Int
    let maxNodes: Int
    var emitted = 0
    var visited = 0
    var truncated = false

    init(maxDepth: Int, maxNodes: Int) {
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
    }

    func tree(_ element: AXUIElement, path: String, depth: Int) -> [String: Any]? {
        if emitted >= maxNodes {
            truncated = true
            return nil
        }

        emitted += 1
        var node = describe(element, path: path)
        let kids = children(element)

        if depth >= maxDepth {
            if !kids.isEmpty {
                node["children_count"] = kids.count
                truncated = true
            }
            return node
        }

        let nested = kids.enumerated().compactMap { index, child in
            tree(child, path: childPath(path, index), depth: depth + 1)
        }

        if !nested.isEmpty { node["children"] = nested }
        return node
    }

    func search(_ element: AXUIElement, path: String, depth: Int, role: String, needle: String, into found: inout [[String: Any]]) {
        if visited >= visitLimit || found.count >= maxNodes {
            truncated = true
            return
        }

        visited += 1
        let node = describe(element, path: path)
        if !path.isEmpty, matches(node, role: role, needle: needle) { found.append(node) }
        if depth >= maxDepth { return }

        for (index, child) in children(element).enumerated() {
            search(child, path: childPath(path, index), depth: depth + 1, role: role, needle: needle, into: &found)
        }
    }
}

func childPath(_ path: String, _ index: Int) -> String {
    path.isEmpty ? String(index) : "\(path).\(index)"
}

func resolve(_ app: AXUIElement, _ path: String) -> AXUIElement {
    var element = app

    for part in path.split(separator: ".") {
        guard let index = Int(part) else { fail("invalid_element_path", "Element paths look like 0.2.1.") }
        let kids = children(element)
        guard index >= 0, index < kids.count else {
            fail("element_not_found", "No element at path \(path); read qa_ax_tree again, the window may have changed.")
        }
        element = kids[index]
    }

    return element
}

func application(_ pid: pid_t) -> AXUIElement {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 3.0)
    return app
}

func axFailure(_ result: AXError, _ verb: String) -> Never {
    switch result {
    case .apiDisabled:
        fail("accessibility_permission_missing", "The Symphony host process has no Accessibility permission.")
    case .actionUnsupported, .attributeUnsupported:
        fail("unsupported", "The element does not support \(verb).")
    case .illegalArgument:
        fail("invalid_value", "The element rejected the value for \(verb).")
    default:
        fail("ax_error", "\(verb) failed with AXError \(result.rawValue).")
    }
}

func ownedWindows(_ pid: pid_t) -> [[String: Any]] {
    let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []

    return list.compactMap { info in
        guard (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
              let id = info[kCGWindowNumber as String] as? Int else { return nil }

        let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]

        return [
            "id": id,
            "title": info[kCGWindowName as String] as? String ?? "",
            "layer": info[kCGWindowLayer as String] as? Int ?? 0,
            "onscreen": info[kCGWindowIsOnscreen as String] as? Bool ?? false,
            "frame": [
                "x": (bounds["X"] as? NSNumber)?.intValue ?? 0,
                "y": (bounds["Y"] as? NSNumber)?.intValue ?? 0,
                "w": (bounds["Width"] as? NSNumber)?.intValue ?? 0,
                "h": (bounds["Height"] as? NSNumber)?.intValue ?? 0
            ]
        ]
    }
}

func windows(_ pid: pid_t) {
    emit(["windows": ownedWindows(pid)])
}

func screenshot(_ pid: pid_t, _ windowArgument: String, _ path: String) {
    guard let window = Int(windowArgument), ownedWindows(pid).contains(where: { $0["id"] as? Int == window }) else {
        fail("window_not_found", "Window \(windowArgument) does not belong to process \(pid).")
    }
    guard path.hasPrefix("/"), !FileManager.default.fileExists(atPath: path) else {
        fail("invalid_path", "The screenshot path must be absolute and must not exist yet.")
    }

    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(window), path]
    capture.standardOutput = FileHandle.nullDevice
    capture.standardError = FileHandle.nullDevice

    do { try capture.run() } catch { fail("screenshot_failed", "screencapture could not start: \(error).") }
    capture.waitUntilExit()

    if capture.terminationStatus != 0 || !FileManager.default.fileExists(atPath: path) {
        fail("screenshot_failed", "screencapture could not capture window \(window).")
    }

    emit(["ok": true])
}

// -- text entry -----------------------------------------------------------------

// Setting `AXValue` on a text field changes what it shows but sends no editing
// notification, so a SwiftUI binding never sees the value and the app saves the
// old one. Text fields get the value typed in instead: focus the field, select
// its text, type over it with key events and commit with Tab. Return would also
// commit, but it presses a form's default button (Save) too.
let textRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String]
let singleLineRoles: Set<String> = [kAXTextFieldRole as String, kAXComboBoxRole as String]
let keyTab: CGKeyCode = 48
let keyDelete: CGKeyCode = 51
let keyDownArrow: CGKeyCode = 125
let keyUpArrow: CGKeyCode = 126
// `CGEventKeyboardSetUnicodeString` keeps at most 20 UTF-16 units per event.
let unicodeChunk = 20
let keyPause: useconds_t = 2_000
// A private source, so keys the operator holds down never mix into the events.
let keySource = CGEventSource(stateID: .privateState)

// Events go to the app's PID only, never to whatever app is frontmost.
func postKey(_ pid: pid_t, _ code: CGKeyCode, flags: CGEventFlags = [], text: [UniChar] = []) {
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: keySource, virtualKey: code, keyDown: down) else {
            fail("typing_failed", "Could not create a key event.")
        }
        event.flags = flags
        if !text.isEmpty { event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text) }
        event.postToPid(pid)
        usleep(keyPause)
    }
}

// Splits on Unicode scalars, so no surrogate pair is cut in two.
func unicodeChunks(_ value: String) -> [[UniChar]] {
    var chunks: [[UniChar]] = []
    var current: [UniChar] = []

    for scalar in value.unicodeScalars {
        let units = Array(String(scalar).utf16)
        if current.count + units.count > unicodeChunk {
            chunks.append(current)
            current = []
        }
        current += units
    }

    if !current.isEmpty { chunks.append(current) }
    return chunks
}

func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)

    while !condition() {
        if Date() >= deadline { return false }
        usleep(20_000)
    }

    return true
}

func characterCount(_ element: AXUIElement) -> Int? {
    if let count = attribute(element, kAXNumberOfCharactersAttribute as String) as? Int { return count }
    return (attribute(element, kAXValueAttribute as String) as? String)?.utf16.count
}

func setFlag(_ element: AXUIElement, _ name: String) -> AXError {
    AXUIElementSetAttributeValue(element, name as CFString, kCFBooleanTrue)
}

// Selects the field's text, so typing replaces it.
func selectAll(_ pid: pid_t, _ element: AXUIElement) {
    guard let count = characterCount(element), count > 0 else { return }
    var range = CFRange(location: 0, length: count)

    if let all = AXValueCreate(.cfRange, &range),
       AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, all) == .success {
        return
    }

    // A menu bar app has no Edit menu, so Cmd-A may do nothing; these are text
    // key bindings: move to the end, then select back to the start.
    let arrow: CGEventFlags = [.maskSecondaryFn, .maskNumericPad]
    postKey(pid, keyDownArrow, flags: arrow.union(.maskCommand))
    postKey(pid, keyUpArrow, flags: arrow.union([.maskCommand, .maskShift]))
}

func enterText(_ app: AXUIElement, _ pid: pid_t, _ element: AXUIElement, role: String, path: String, value: String) {
    let secure = (attribute(element, kAXSubroleAttribute as String) as? String) == kAXSecureTextFieldSubrole as String

    if singleLineRoles.contains(role), value.contains(where: { $0 == "\t" || $0.isNewline }) {
        fail("invalid_value", "A single-line text field cannot take a tab or line break: typing one moves focus or presses the default button.")
    }

    // Key events reach only the key window of the active app.
    if (attribute(app, kAXFrontmostAttribute as String) as? Bool) != true { _ = setFlag(app, kAXFrontmostAttribute as String) }
    if let window = attribute(element, kAXWindowAttribute as String), CFGetTypeID(window) == AXUIElementGetTypeID() {
        _ = setFlag(window as! AXUIElement, kAXMainAttribute as String)
    }

    let focused = setFlag(element, kAXFocusedAttribute as String)
    if focused != .success { axFailure(focused, "focusing the field") }

    guard waitUntil(2, { (attribute(element, kAXFocusedAttribute as String) as? Bool) == true }) else {
        fail("not_focused", "The field did not take keyboard focus. Raise its window with qa_ax_press and AXRaise, then try again.")
    }

    selectAll(pid, element)
    if value.isEmpty { postKey(pid, keyDelete) }
    for chunk in unicodeChunks(value) { postKey(pid, 0, text: chunk) }

    // Check the typed text landed before committing it; a secure field is
    // checked by length only.
    let expected = value.utf16.count
    let landed = waitUntil(2) {
        secure ? characterCount(element).map { $0 == expected } ?? true
            : (attribute(element, kAXValueAttribute as String) as? String ?? "") == value
    }

    guard landed else {
        let shown = characterCount(element).map(String.init) ?? "unknown"
        fail("text_not_entered", "After typing, the field holds \(shown) characters, not the \(expected) typed. The app may have lost focus or changed the text.")
    }

    if singleLineRoles.contains(role) {
        postKey(pid, keyTab)
        usleep(100_000)
    }

    emit(["ok": true, "typed": true, "element": describe(element, path: path)])
}

// -- wide pass --------------------------------------------------------------------

// An app counts as hung when it leaves an accessibility request unanswered this long.
let hangTimeout: Float = 10

func element(_ value: AnyObject?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func mainWindow(_ app: AXUIElement) -> AXUIElement? {
    element(attribute(app, kAXMainWindowAttribute as String))
        ?? element(attribute(app, kAXFocusedWindowAttribute as String))
        ?? (attribute(app, kAXWindowsAttribute as String) as? [AXUIElement])?.first
}

func settable(_ element: AXUIElement, _ name: String) -> Bool {
    var result: DarwinBoolean = false
    return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
}

func setGeometry(_ element: AXUIElement, _ name: String, _ type: AXValueType, _ value: UnsafeRawPointer) -> AXError {
    guard let wrapped = AXValueCreate(type, value) else { return .illegalArgument }
    return AXUIElementSetAttributeValue(element, name as CFString, wrapped)
}

// Moves the window to the top left of the screen's usable area (below the menu
// bar, beside the Dock), then sizes it to the request, or to that area when it
// is smaller. A window whose `AXSize` can't be set gets its zoom button pressed
// instead, which fills the usable area. Reports what the window ended up as,
// with the screen and its usable area, so the caller can tell a small screen
// from an app that keeps its window small.
func resizeWindow(_ pid: pid_t, _ path: String, width: Double, height: Double) {
    let app = application(pid)
    let window: AXUIElement

    if path.isEmpty {
        guard let main = mainWindow(app) else { fail("no_window", "The app has no window to resize. Open its main window first.") }
        window = main
    } else {
        window = resolve(app, path)
        guard (attribute(window, kAXRoleAttribute as String) as? String) == kAXWindowRole as String else {
            fail("not_a_window", "The element at \(path) is not a window (AXWindow).")
        }
    }

    guard let screen = NSScreen.screens.first else { fail("no_screen", "The QA host has no screen.") }
    // AppKit measures from the bottom left of the primary screen, accessibility from its top left.
    let usable = screen.visibleFrame
    var origin = CGPoint(x: usable.minX, y: screen.frame.maxY - usable.maxY)
    var target = CGSize(width: min(width, usable.width), height: min(height, usable.height))
    var method = "AXSize"

    _ = setGeometry(window, kAXPositionAttribute as String, .cgPoint, &origin)

    if !(settable(window, kAXSizeAttribute as String) && setGeometry(window, kAXSizeAttribute as String, .cgSize, &target) == .success) {
        guard let zoom = element(attribute(window, kAXZoomButtonAttribute as String)),
              AXUIElementPerformAction(zoom, kAXPressAction as CFString) == .success else {
            fail("not_resizable", "The window has a fixed size: neither AXSize nor its zoom button resized it.")
        }
        method = "zoom"
    }

    _ = waitUntil(2) {
        size(attribute(window, kAXSizeAttribute as String)).map { abs($0.width - target.width) < 1 && abs($0.height - target.height) < 1 } ?? false
    }

    emit([
        "ok": true,
        "method": method,
        "window": frame(window) ?? [:],
        "screen": ["w": Int(screen.frame.width), "h": Int(screen.frame.height)],
        "visible": ["x": Int(origin.x), "y": Int(origin.y), "w": Int(usable.width), "h": Int(usable.height)],
        "requested": ["w": Int(width), "h": Int(height)]
    ])
}

// Any attribute read goes to the app's main thread, so one left unanswered for
// `hangTimeout` means the app is hung. An app with no windows still answers.
func ping(_ pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, hangTimeout)
    var value: AnyObject?
    let started = Date()
    let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)

    switch result {
    case .success, .noValue, .attributeUnsupported:
        emit(["ok": true, "responding": true, "ms": Int(Date().timeIntervalSince(started) * 1000)])
    case .cannotComplete:
        fail("app_not_responding", "The app did not answer an accessibility request within \(Int(hangTimeout)) seconds.")
    default:
        axFailure(result, "reading the app's windows")
    }
}

// -- rows, clicks and keys ----------------------------------------------------------

// Key events reach only the key window of the active app, and a click on a
// window behind another lands on the one in front, so both bring the app and the
// element's window forward first.
func bringForward(_ app: AXUIElement, _ target: AXUIElement?) {
    if (attribute(app, kAXFrontmostAttribute as String) as? Bool) != true { _ = setFlag(app, kAXFrontmostAttribute as String) }
    if let target, let window = windowOf(target) {
        _ = setFlag(window, kAXMainAttribute as String)
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
    _ = waitUntil(2) { (attribute(app, kAXFrontmostAttribute as String) as? Bool) == true }
}

func windowOf(_ target: AXUIElement) -> AXUIElement? {
    if (attribute(target, kAXRoleAttribute as String) as? String) == kAXWindowRole as String { return target }
    return element(attribute(target, kAXWindowAttribute as String))
}

let tableRoles: Set<String> = [kAXTableRole as String, kAXOutlineRole as String]

// The row itself, or the row a cell or its text sits in.
func enclosingRow(_ start: AXUIElement) -> AXUIElement? {
    var current: AXUIElement? = start

    for _ in 0..<6 {
        guard let candidate = current else { return nil }
        if (attribute(candidate, kAXRoleAttribute as String) as? String) == kAXRowRole as String { return candidate }
        current = element(attribute(candidate, kAXParentAttribute as String))
    }

    return nil
}

func isSelected(_ row: AXUIElement, in table: AXUIElement?) -> Bool {
    if (attribute(row, kAXSelectedAttribute as String) as? Bool) == true { return true }
    let selected = table.flatMap { attribute($0, kAXSelectedRowsAttribute as String) as? [AXUIElement] } ?? []
    return selected.contains { CFEqual($0, row) }
}

// A SwiftUI `Table` row (an `AXRow` of an `AXOutline` or `AXTable`) answers no
// AXPress, so it is selected the accessible way: the table's `AXSelectedRows`
// set to just this row, or else the row's `AXSelected`. The table then takes
// keyboard focus, so a following `key` (Return, an arrow) acts on the selection.
func selectRow(_ pid: pid_t, _ path: String) {
    let app = application(pid)
    guard let row = enclosingRow(resolve(app, path)) else {
        fail("not_a_row", "The element at \(path) is not a table or outline row (AXRow) or inside one.")
    }

    let parent = element(attribute(row, kAXParentAttribute as String))
    let table = parent.flatMap { tableRoles.contains(attribute($0, kAXRoleAttribute as String) as? String ?? "") ? $0 : nil }
    bringForward(app, row)

    var result = AXError.attributeUnsupported
    if let table, settable(table, kAXSelectedRowsAttribute as String) {
        result = AXUIElementSetAttributeValue(table, kAXSelectedRowsAttribute as CFString, [row] as CFArray)
    }
    if result != .success { result = setFlag(row, kAXSelectedAttribute as String) }
    if result != .success { axFailure(result, "selecting the row") }

    guard waitUntil(2, { isSelected(row, in: table) }) else {
        fail("not_selected", "The row did not report itself selected. Try qa_click on it instead.")
    }

    if let table { _ = setFlag(table, kAXFocusedAttribute as String) }
    emit(["ok": true, "selected": true, "element": describe(row, path: path)])
}

func windowNumber(_ window: [String: Any]) -> Int? { window[kCGWindowNumber as String] as? Int }

// The on-screen windows under the point, front-most first, skipping fully transparent ones.
func onScreenWindows(at point: CGPoint) -> [[String: Any]] {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []

    return list.filter { info in
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
        return (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 && rect.contains(point)
    }
}

func ownerPID(_ window: [String: Any]) -> pid_t? { (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) }

// The process that would take a click at the point, as the accessibility hit
// test sees it: the window server skips a window that lets clicks through.
func processUnder(_ point: CGPoint) -> pid_t? {
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
          let hit else { return nil }
    var owner: pid_t = 0
    return AXUIElementGetPid(hit, &owner) == .success ? owner : nil
}

// What covers the app at the point, or nil when the click would reach it. The
// window list also counts an overlay that lets clicks through (another app's
// transparent window over the whole screen) as in front, so it decides only
// when the hit test has no answer.
func coverer(at point: CGPoint, pid: pid_t, windows: [[String: Any]]) -> String? {
    if let owner = processUnder(point) {
        if owner == pid { return nil }
        let name = NSRunningApplication(processIdentifier: owner)?.localizedName ?? "process \(owner)"
        return "\(name) (pid \(owner))"
    }

    guard let front = windows.first, ownerPID(front) != pid else { return nil }
    let owner = front[kCGWindowOwnerName as String] as? String ?? "another app"
    let title = front[kCGWindowName as String] as? String ?? ""
    let layer = front[kCGWindowLayer as String] as? Int ?? 0
    return "\(owner)'s window \"\(title)\" (layer \(layer))"
}

let clickPause: useconds_t = 50_000
// Time the app gets to answer a pointer move (tracking areas, `onHover`) before
// the helper reads its tree.
let pointerPause: useconds_t = 100_000
let settlePause: useconds_t = 150_000
// Nodes the change check reads: enough for a window's controls, few enough to
// read several times a second.
let fingerprintLimit = 1500

// Where the pointer goes: an element's frame centre, or a point on screen in the
// coordinates of `qa_ax_tree`'s frames (top left of the main screen is 0,0).
struct PointerTarget {
    let point: CGPoint
    let element: AXUIElement?
    let path: String
    let label: String
}

func elementTarget(_ target: AXUIElement, _ path: String) -> PointerTarget {
    guard let origin = point(attribute(target, kAXPositionAttribute as String)),
          let extent = size(attribute(target, kAXSizeAttribute as String)), extent.width >= 1, extent.height >= 1 else {
        fail("no_frame", "The element at \(path) has no frame to point at.")
    }

    let centre = CGPoint(x: origin.x + extent.width / 2, y: origin.y + extent.height / 2)
    return PointerTarget(point: centre, element: target, path: path, label: "the element at \(path)")
}

// An element path, or `x,y`.
func pointerTarget(_ app: AXUIElement, _ argument: String) -> PointerTarget {
    let parts = argument.split(separator: ",", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return elementTarget(resolve(app, argument), argument) }
    guard let x = Double(parts[0]), let y = Double(parts[1]) else { fail("invalid_point", "A point looks like 120,340.") }
    return PointerTarget(point: CGPoint(x: x, y: y), element: nil, path: "", label: "point \(argument)")
}

// Brings the app and the target's window forward and returns the number of the
// app's window under the point. Fails when the app has no window on screen
// there or something else would take the pointer, so nothing that follows can
// land on another app.
func reach(_ app: AXUIElement, _ pid: pid_t, _ target: PointerTarget) -> Int {
    bringForward(app, target.element)

    let windows = onScreenWindows(at: target.point)
    guard let window = windows.first(where: { ownerPID($0) == pid }), let number = windowNumber(window) else {
        fail("not_on_screen", "\(capitalized(target.label)) is not on screen; scroll it into view or raise its window.")
    }
    if let blocker = coverer(at: target.point, pid: pid, windows: windows) {
        fail("covered", "\(blocker) covers \(target.label); QA points and clicks only inside the app's own windows.")
    }

    return number
}

func capitalized(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

// Moves the real pointer, as a person's mouse would. The window server keeps
// the pointer's position: hover (tracking areas, SwiftUI `onHover`) follows it,
// and a SwiftUI button or link checks it when the mouse goes up, so a click
// posted away from it does nothing. `reach` has checked that the app's own
// window is in front at the point, so the move reaches no other app.
func movePointer(to point: CGPoint) {
    guard let event = CGEvent(mouseEventSource: keySource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
        fail("pointer_failed", "Could not create a mouse event.")
    }
    event.post(tap: .cghidEventTap)
    usleep(pointerPause)
}

// The app's own element under the point, as the accessibility hit test sees it.
func elementUnder(_ app: AXUIElement, _ point: CGPoint) -> [String: Any]? {
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
    var node = describe(hit, path: "")
    node.removeValue(forKey: "path")
    return node
}

// Mouse events go to the app's PID alone, aimed at its window under the point.
func postMouse(_ pid: pid_t, _ types: [CGEventType], at point: CGPoint, button: CGMouseButton, window: Int, clickState: Int) {
    for type in types {
        guard let event = CGEvent(mouseEventSource: keySource, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            fail("click_failed", "Could not create a mouse event.")
        }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
        event.postToPid(pid)
        usleep(keyPause)
    }
}

// What the app shows, in short: its on-screen windows and, for each element
// outside the menu bar, its role, title, value, description, state and number
// of children. Two equal fingerprints mean nothing the tree reports changed.
func fingerprint(_ app: AXUIElement, _ pid: pid_t) -> String {
    var lines = ownedWindows(pid).filter { $0["onscreen"] as? Bool == true }.map { "window \($0["id"] ?? "") \($0["title"] ?? "")" }
    var visited = 0

    func walk(_ element: AXUIElement, _ depth: Int) {
        guard visited < fingerprintLimit else { return }
        visited += 1
        let role = text(attribute(element, kAXRoleAttribute as String)) ?? ""
        if role == kAXMenuBarRole as String { return }

        let kids = children(element)
        let fields = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXSelectedAttribute, kAXFocusedAttribute, kAXEnabledAttribute]
        lines.append(([String(depth), role, String(kids.count)] + fields.map { text(attribute(element, $0 as String)) ?? "" }).joined(separator: "|"))
        if depth < 40 { kids.forEach { walk($0, depth + 1) } }
    }

    walk(app, 0)
    return lines.joined(separator: "\n")
}

// Reads the fingerprint until two reads in a row agree, for at most `seconds`.
func settle(_ app: AXUIElement, _ pid: pid_t, within seconds: TimeInterval) -> (fingerprint: String, settled: Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    var last = fingerprint(app, pid)

    while Date() < deadline {
        usleep(settlePause)
        let next = fingerprint(app, pid)
        if next == last { return (next, true) }
        last = next
    }

    return (last, false)
}

func actionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}

// Clicks the centre of the element's frame. The pointer moves there first and
// the click goes only to the app's PID, and only when the app's own window is
// on screen at that point and nothing else would take the click there, so a
// covered or off-screen element fails rather than clicking something else.
// When a single click changed nothing the tree or the window list reports and
// the element answers AXPress, it is pressed that way instead, and the result
// says so.
func click(_ pid: pid_t, _ path: String, clicks: Int) {
    let app = application(pid)
    let element = resolve(app, path)
    let target = elementTarget(element, path)
    let window = reach(app, pid, target)
    movePointer(to: target.point)
    let under = elementUnder(app, target.point)
    let before = settle(app, pid, within: 1).fingerprint

    for count in 1...clicks {
        postMouse(pid, [.leftMouseDown, .leftMouseUp], at: target.point, button: .left, window: window, clickState: count)
    }

    usleep(clickPause)
    let changed = waitUntil(1) { fingerprint(app, pid) != before }
    var result: [String: Any] = [
        "ok": true,
        "clicked": ["x": Int(target.point.x), "y": Int(target.point.y)],
        "clicks": clicks,
        "changed": changed,
        "element": describe(element, path: path)
    ]
    result["under_pointer"] = under

    if !changed, clicks == 1, actionNames(element).contains(kAXPressAction as String),
       AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
        result["fallback"] = "AXPress"
        result["note"] = "The click changed nothing in the app's accessibility tree or windows, so qa_click pressed the element with AXPress instead. Read qa_ax_tree to see what the press did."
    }

    emit(result)
}

// Moves the pointer over an element's centre or a point and waits for the app
// to settle, so a hover state (a button that shows on hover, a highlight, a
// tooltip's trigger) can be screenshotted. The pointer stays there.
func hover(_ pid: pid_t, _ argument: String) {
    let app = application(pid)
    let target = pointerTarget(app, argument)
    _ = reach(app, pid, target)
    movePointer(to: target.point)
    let settled = settle(app, pid, within: 2).settled

    var result: [String: Any] = [
        "ok": true,
        "hovered": ["x": Int(target.point.x), "y": Int(target.point.y)],
        "settled": settled,
        "note": "The pointer stays here until the next qa_click, qa_hover or qa_context_menu: take qa_screenshot now."
    ]
    result["under_pointer"] = elementUnder(app, target.point)
    if let element = target.element { result["element"] = describe(element, path: target.path) }
    emit(result)
}

// An open menu outside the menu bar (a context menu is a child of the app while
// it shows), with its path. Closed menus have no frame.
func openMenu(_ app: AXUIElement) -> (element: AXUIElement, path: String)? {
    func find(_ element: AXUIElement, _ path: String, _ depth: Int) -> (element: AXUIElement, path: String)? {
        for (index, child) in children(element).enumerated() {
            let role = attribute(child, kAXRoleAttribute as String) as? String
            if role == kAXMenuBarRole as String { continue }
            let path = childPath(path, index)
            if role == kAXMenuRole as String, let size = size(attribute(child, kAXSizeAttribute as String)), size.width > 0, size.height > 0 {
                return (child, path)
            }
            if depth < 3, let found = find(child, path, depth + 1) { return found }
        }
        return nil
    }

    return find(app, "", 0)
}

func menuItems(_ menu: AXUIElement, _ path: String) -> [[String: Any]] {
    children(menu).enumerated().map { index, item in
        var node = describe(item, path: childPath(path, index))
        node["shortcut"] = text(attribute(item, kAXMenuItemCmdCharAttribute as String))
        if children(item).contains(where: { attribute($0, kAXRoleAttribute as String) as? String == kAXMenuRole as String }) {
            node["submenu"] = true
        }
        return node
    }
}

// Right-clicks an element's centre or a point, as a person opens a row's or a
// control's context menu, then lists the menu's items for `qa_ax_press`. The
// pointer moves there first; the click goes to the app's PID alone.
func contextMenu(_ pid: pid_t, _ argument: String) {
    let app = application(pid)
    let target = pointerTarget(app, argument)
    let window = reach(app, pid, target)
    movePointer(to: target.point)
    postMouse(pid, [.rightMouseDown, .rightMouseUp], at: target.point, button: .right, window: window, clickState: 1)

    var found: (element: AXUIElement, path: String)?
    guard waitUntil(2, { found = openMenu(app); return found != nil }), let menu = found else {
        fail("no_menu", "No context menu opened at \(target.label). Try qa_ax_press with action AXShowMenu, or another element.")
    }

    var described = describe(menu.element, path: menu.path)
    described["items"] = menuItems(menu.element, menu.path)
    let popUp = ownedWindows(pid).first { $0["layer"] as? Int == 101 && $0["onscreen"] as? Bool == true }

    var result: [String: Any] = [
        "ok": true,
        "clicked": ["x": Int(target.point.x), "y": Int(target.point.y)],
        "menu": described,
        "note": "Press an item with qa_ax_press on its path, or close the menu with qa_key and key escape. Screenshot it with qa_screenshot and its window_id."
    ]
    result["window_id"] = popUp?["id"]
    emit(result)
}

// US-layout virtual key codes; the event also carries the character, so a key
// equivalent such as ⌘[ matches on any layout.
let namedKeys: [String: CGKeyCode] = [
    "return": 36, "enter": 76, "tab": 48, "space": 49, "escape": 53, "delete": 51, "forward_delete": 117,
    "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "page_up": 116, "page_down": 121
]
let characterKeys: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
    "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
    "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
    "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50
]
let keyText: [String: String] = ["return": "\r", "enter": "\u{3}", "tab": "\t", "space": " ", "escape": "\u{1b}", "delete": "\u{7f}"]
let modifierFlags: [String: CGEventFlags] = ["command": .maskCommand, "shift": .maskShift, "option": .maskAlternate, "control": .maskControl]

func focusedDescription(_ app: AXUIElement, _ name: String) -> [String: Any]? {
    guard let focused = element(attribute(app, name)) else { return nil }
    var node = describe(focused, path: "")
    node.removeValue(forKey: "path")
    return node
}

// Presses one key with its modifiers in the app's focused window: the app comes
// to the front, and the events go to its PID alone.
func pressKey(_ pid: pid_t, _ name: String, _ modifiers: String) {
    var flags: CGEventFlags = []
    for modifier in modifiers.split(separator: ",") {
        guard let flag = modifierFlags[String(modifier)] else { fail("invalid_key", "Unknown modifier \(modifier).") }
        flags.insert(flag)
    }

    let code: CGKeyCode
    var text = keyText[name] ?? ""
    if let named = namedKeys[name] {
        code = named
        if ["left", "right", "down", "up"].contains(name) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        if ["home", "end", "page_up", "page_down", "forward_delete"].contains(name) { flags.insert(.maskSecondaryFn) }
    } else if name.count == 1, let character = name.first, let typed = characterKeys[character] {
        code = typed
        text = flags.contains(.maskShift) ? name.uppercased() : name
    } else {
        fail("invalid_key", "Unknown key \(name).")
    }

    let app = application(pid)
    bringForward(app, nil)
    guard element(attribute(app, kAXFocusedWindowAttribute as String)) != nil else {
        fail("no_window", "The app has no focused window to send the key to. Raise one with qa_ax_press and AXRaise first.")
    }

    postKey(pid, code, flags: flags, text: Array(text.utf16))
    usleep(clickPause)
    emit([
        "ok": true,
        "key": name,
        "modifiers": modifiers.split(separator: ",").map(String.init),
        "window": focusedDescription(app, kAXFocusedWindowAttribute as String) ?? [:],
        "focused": focusedDescription(app, kAXFocusedUIElementAttribute as String) ?? [:]
    ])
}

// -- server ---------------------------------------------------------------------

let pidCommands: Set<String> = ["windows", "screenshot", "ax-tree", "ax-press", "ax-set-value", "ax-resize", "ax-ping", "ax-select", "click", "hover", "context-menu", "key"]
let requestLimit = 64 * 1024
let commandTimeout: TimeInterval = 60
// Symphony waits 15 s for the helper it opens, so an older owner file was left
// by a Symphony that died before its helper read it.
let ownerFileMaxAge: time_t = 30

func parentPID(_ pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

func descends(_ pid: pid_t, from owner: pid_t) -> Bool {
    var current = pid

    for _ in 0..<64 {
        guard let parent = parentPID(current), parent > 1 else { return false }
        if parent == owner { return true }
        current = parent
    }

    return false
}

func executablePath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    return length > 0 ? String(cString: buffer) : nil
}

func isBEAM(_ pid: pid_t) -> Bool {
    executablePath(pid).map { ($0 as NSString).lastPathComponent == "beam.smp" } ?? false
}

// Symphony's BEAM is started by Symphony.app or a terminal. Everything an agent
// runs descends from it (through `erl_child_setup`), so a BEAM an agent starts
// has a BEAM among its ancestors.
func symphonyOwner(_ owner: pid_t) -> Bool {
    guard isBEAM(owner) else { return false }
    var current = owner

    for _ in 0..<64 {
        guard let parent = parentPID(current) else { return false }
        if parent <= 1 { return true }
        if isBEAM(parent) { return false }
        current = parent
    }

    return false
}

func runDirectory() -> String? {
    guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else { return nil }
    return String(cString: home) + "/Library/Application Support/symphony/qa-driver/run"
}

func privateEntry(_ path: String, type: mode_t, maxAge: time_t? = nil) -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0 else { return false }
    let fresh = maxAge.map { time(nil) - info.st_mtimespec.tv_sec <= $0 } ?? true
    return info.st_mode & S_IFMT == type && info.st_uid == getuid() && info.st_mode & 0o077 == 0 && fresh
}

// Symphony leaves `qa-<owner>.owner` in the run directory before it opens the
// helper. Only Symphony can write there, and the helper removes the file, so it
// names one owner once. A stale file, left by a Symphony that died, names no
// one: its PID may since belong to another process.
func claimedBy(_ path: String, owner: pid_t) -> Bool {
    guard let dir = runDirectory(), path == "\(dir)/qa-\(owner).sock", privateEntry(dir, type: S_IFDIR) else { return false }
    let marker = "\(dir)/qa-\(owner).owner"
    return privateEntry(marker, type: S_IFREG, maxAge: ownerFileMaxAge) && unlink(marker) == 0
}

// A one-shot PID command runs only as the child `runCommand` starts, never when
// the helper is opened (by LaunchServices, so its parent is launchd) or run
// directly with one.
func startedByServingHelper() -> Bool {
    let parent = getppid()
    guard parent > 1, let own = executablePath(getpid()) else { return false }
    return executablePath(parent) == own
}

func errorReply(_ code: String, _ message: String) -> [String: Any] {
    let output = (try? JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": message]]))
        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    return ["status": 1, "output": output]
}

// Runs one command as a child of the helper, so it keeps the helper's grants.
func runCommand(_ args: [String], owner: pid_t) -> [String: Any] {
    guard let command = args.first, command == "permissions" || pidCommands.contains(command) else {
        return errorReply("usage", "Unknown command.")
    }

    if pidCommands.contains(command) {
        guard args.count > 1, let pid = Int32(args[1]), pid > 0, descends(pid, from: owner) else {
            return errorReply("pid_not_allowed", "The helper only drives apps Symphony launched.")
        }
    }

    let child = Process()
    let output = Pipe()
    child.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    child.arguments = args
    child.standardOutput = output
    child.standardError = FileHandle.nullDevice

    do { try child.run() } catch { return errorReply("helper_failed", "The helper could not run \(command): \(error).") }

    let timer = DispatchWorkItem { if child.isRunning { child.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + commandTimeout, execute: timer)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    child.waitUntilExit()
    timer.cancel()

    return ["status": Int(child.terminationStatus), "output": String(decoding: data, as: UTF8.self)]
}

func readRequest(_ fd: Int32) -> [String]? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)

    while data.count < requestLimit, !data.contains(UInt8(ascii: "\n")) {
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer[0..<count])
    }

    guard let line = data.split(separator: UInt8(ascii: "\n")).first,
          let request = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
          let args = request["args"] as? [String] else { return nil }

    return args
}

func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if written <= 0 { return }
            offset += written
        }
    }
}

func handle(_ fd: Int32, owner: pid_t) {
    defer { close(fd) }

    var peer: pid_t = 0
    var length = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &length) == 0, peer == owner else { return }

    let reply = readRequest(fd).map { runCommand($0, owner: owner) } ?? errorReply("usage", "Send one JSON line {\"args\": [...]}.")
    var data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
    data.append(UInt8(ascii: "\n"))
    writeAll(fd, data)
}

func ownerAlive(_ owner: pid_t) -> Bool {
    kill(owner, 0) == 0 || errno == EPERM
}

func serve(_ path: String, owner: pid_t) -> Never {
    guard symphonyOwner(owner), claimedBy(path, owner: owner) else {
        fail("owner_not_allowed", "The helper only serves the Symphony process, on its socket in the run directory.")
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)

    guard fd >= 0, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        fail("socket_failed", "Could not create the helper socket at \(path).")
    }

    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }

    unlink(path)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }

    guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
        fail("socket_failed", "Could not listen on the helper socket at \(path).")
    }

    Thread.detachNewThread {
        while ownerAlive(owner) { sleep(2) }
        unlink(path)
        exit(0)
    }

    while true {
        let client = accept(fd, nil, nil)
        if client < 0 { continue }
        DispatchQueue.global().async { handle(client, owner: owner) }
    }
}

func requestPermissions() {
    let accessibility = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    let screenRecording = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    emit(["accessibility": accessibility, "screen_recording": screenRecording])
}

// LaunchServices may add a `-psn_…` argument to an app it opens.
let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }

switch args.first {
case nil:
    requestPermissions()

case "serve" where args.count == 3:
    serve(args[1], owner: pidArgument(args[2]))

case "permissions":
    emit(["accessibility": AXIsProcessTrusted(), "screen_recording": CGPreflightScreenCaptureAccess()])

// The copy compiled on a separate QA host (`-D SYMPHONY_QA_SSH`) holds no grant
// of its own; commands it runs over SSH use the grant on sshd-keygen-wrapper.
#if !SYMPHONY_QA_SSH
case let command? where pidCommands.contains(command) && !startedByServingHelper():
    fail("not_allowed", "The helper runs \(command) only for Symphony, through serve.")
#endif

case "windows" where args.count == 2:
    windows(pidArgument(args[1]))

case "screenshot" where args.count == 4:
    screenshot(pidArgument(args[1]), args[2], args[3])

case "ax-tree" where args.count == 6:
    requireAccessibility()
    let pid = pidArgument(args[1])
    let walk = TreeWalk(maxDepth: Int(args[2]) ?? 12, maxNodes: Int(args[3]) ?? 300)
    let app = application(pid)

    if args[4].isEmpty && args[5].isEmpty {
        emit(["root": walk.tree(app, path: "", depth: 0) ?? [:], "nodes": walk.emitted, "truncated": walk.truncated])
    } else {
        var found: [[String: Any]] = []
        walk.search(app, path: "", depth: 0, role: args[4], needle: args[5], into: &found)
        emit(["matches": found, "nodes": found.count, "truncated": walk.truncated])
    }

case "ax-press" where args.count == 4:
    requireAccessibility()
    let pid = pidArgument(args[1])
    let element = resolve(application(pid), args[2])
    let result = AXUIElementPerformAction(element, args[3] as CFString)
    if result != .success { axFailure(result, args[3]) }
    emit(["ok": true, "element": describe(element, path: args[2])])

case "ax-set-value" where args.count == 4:
    requireAccessibility()
    let pid = pidArgument(args[1])
    let app = application(pid)
    let element = resolve(app, args[2])
    let role = attribute(element, kAXRoleAttribute as String) as? String ?? ""

    if textRoles.contains(role) {
        enterText(app, pid, element, role: role, path: args[2], value: args[3])
    } else {
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, args[3] as CFString)
        if result != .success { axFailure(result, "setting AXValue") }
        emit(["ok": true, "element": describe(element, path: args[2])])
    }

case "ax-resize" where args.count == 5:
    requireAccessibility()
    guard let width = Double(args[3]), let height = Double(args[4]), width >= 1, height >= 1 else {
        fail("invalid_size", "Width and height must be positive numbers of points.")
    }
    resizeWindow(pidArgument(args[1]), args[2], width: width, height: height)

case "ax-ping" where args.count == 2:
    requireAccessibility()
    ping(pidArgument(args[1]))

case "ax-select" where args.count == 3:
    requireAccessibility()
    selectRow(pidArgument(args[1]), args[2])

case "click" where args.count == 4:
    requireAccessibility()
    guard let clicks = Int(args[3]), (1...2).contains(clicks) else { fail("invalid_clicks", "Clicks must be 1 or 2.") }
    click(pidArgument(args[1]), args[2], clicks: clicks)

case "hover" where args.count == 3:
    requireAccessibility()
    hover(pidArgument(args[1]), args[2])

case "context-menu" where args.count == 3:
    requireAccessibility()
    contextMenu(pidArgument(args[1]), args[2])

case "key" where args.count == 4:
    requireAccessibility()
    pressKey(pidArgument(args[1]), args[2], args[3])

default:
    fail("usage", "Unknown command or wrong number of arguments.")
}
