// Symphony QA driver helper.
//
// Symphony compiles this file once with `swiftc` and runs it on the host for the
// Auto Review QA tools (`SymphonyElixir.QaDriver`). Symphony checks every PID
// before calling it; the helper only reads and drives the process it is given.
// Each command prints one JSON object on stdout and exits 0, or prints
// `{"error": {"code", "message"}}` and exits 1.
//
//   permissions
//   windows <pid>
//   ax-tree <pid> <max-depth> <max-nodes> <role or ""> <text or "">
//   ax-press <pid> <path> <action>
//   ax-set-value <pid> <path> <value>

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

func windows(_ pid: pid_t) {
    let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []

    let owned: [[String: Any]] = list.compactMap { info in
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

    emit(["windows": owned])
}

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "permissions":
    emit(["accessibility": AXIsProcessTrusted(), "screen_recording": CGPreflightScreenCaptureAccess()])

case "windows" where args.count == 2:
    windows(pidArgument(args[1]))

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
