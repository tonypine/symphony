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
// would use its grants on any app) fails. Each command prints one JSON object on
// stdout and exits 0, or prints `{"error": {"code", "message"}}` and exits 1.
//
//   permissions
//   windows <pid>
//   screenshot <pid> <window id> <png path>
//   ax-tree <pid> <max-depth> <max-nodes> <role or ""> <text or "">
//   ax-press <pid> <path> <action>
//   ax-set-value <pid> <path> <value>
//
// Opened with no arguments (by hand, from Finder or `open`), it asks for both
// permissions, so that it is listed in System Settings.

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
    node["value"] = text(attribute(element, kAXValueAttribute as String))
    node["description"] = text(attribute(element, kAXDescriptionAttribute as String))
    node["identifier"] = text(attribute(element, kAXIdentifierAttribute as String))

    if let enabled = attribute(element, kAXEnabledAttribute as String) as? Bool, !enabled {
        node["enabled"] = false
    }

    if let focused = attribute(element, kAXFocusedAttribute as String) as? Bool, focused {
        node["focused"] = true
    }

    if let origin = point(attribute(element, kAXPositionAttribute as String)),
       let extent = size(attribute(element, kAXSizeAttribute as String)) {
        node["frame"] = ["x": Int(origin.x), "y": Int(origin.y), "w": Int(extent.width), "h": Int(extent.height)]
    }

    return node
}

func matches(_ node: [String: Any], role: String, needle: String) -> Bool {
    if !role.isEmpty, (node["role"] as? String) != role { return false }
    if needle.isEmpty { return true }

    return ["title", "value", "description", "identifier"].contains { key in
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

// -- server ---------------------------------------------------------------------

let pidCommands: Set<String> = ["windows", "screenshot", "ax-tree", "ax-press", "ax-set-value"]
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

case let command? where pidCommands.contains(command) && !startedByServingHelper():
    fail("not_allowed", "The helper runs \(command) only for Symphony, through serve.")

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
    let element = resolve(application(pid), args[2])
    let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, args[3] as CFString)
    if result != .success { axFailure(result, "setting AXValue") }
    emit(["ok": true, "element": describe(element, path: args[2])])

default:
    fail("usage", "Unknown command or wrong number of arguments.")
}
