import Foundation

/// QA mode's cursor report (TP-1678): the cursor the app set at the pointer and the named element it set it for, so
/// QA's `qa_hover` reads the cursor from the app instead of comparing the system's cursor images. The app's places that
/// set a cursor (the shared button pointer, the text fields, the chips and links, the reorder grab, the not-allowed
/// pointer) record the kind they set over their view; the report names the smallest such view under the pointer. A
/// cursor the app holds that none of them set there, by identity with the system's named cursors, is reported as set
/// outside them (`source` `unrecorded`), so it is found, not guessed.
///
/// Only a QA-mode launch writes it: `QAMode.cursorReport(pid:)`, rewritten atomically when what it says changes. A
/// normal launch records nothing and writes nothing.
public struct QACursorReport: Codable, Equatable, Sendable {
    /// The version of the report's shape; the driver reads version 1.
    public static let version = 1

    /// A cursor kind, by the stable names `qa_hover` returns.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case arrow
        case pointingHand = "pointing_hand"
        case iBeam = "i_beam"
        case verticalIBeam = "vertical_i_beam"
        case openHand = "open_hand"
        case closedHand = "closed_hand"
        case operationNotAllowed = "operation_not_allowed"
        case crosshair
        case contextualMenu = "contextual_menu"
        case dragCopy = "drag_copy"
        case dragLink = "drag_link"
        case disappearingItem = "disappearing_item"
        case resizeLeftRight = "resize_left_right"
        case resizeUpDown = "resize_up_down"
    }

    /// Who set the cursor the report names.
    public enum Source: String, Codable, Sendable {
        /// A recorded place set it over `element`.
        case recorded
        /// Nothing set one: the system's arrow.
        case none
        /// The app holds a cursor no recorded place set at the pointer.
        case unrecorded
    }

    /// What a recorded place set at the pointer: the kind, the named element it set it for (nil when it is in no named
    /// element) and the view's frame on screen.
    public struct Recorded: Codable, Equatable, Sendable {
        public var cursor: Kind
        public var element: String?
        public var frame: QAElementReport.Rect

        public init(cursor: Kind, element: String?, frame: QAElementReport.Rect) {
            self.cursor = cursor
            self.element = element
            self.frame = frame
        }
    }

    /// A point on screen, from the top left of the main display.
    public struct Point: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = QAElementReport.Rect.rounded(x)
            self.y = QAElementReport.Rect.rounded(y)
        }
    }

    public var version: Int
    public var at: String
    public var pid: Int32
    /// Where the pointer was when the app wrote the report.
    public var pointer: Point
    /// The cursor at the pointer.
    public var cursor: Kind
    /// The named element whose recorded place set it, nil when none did.
    public var element: String?
    public var source: Source
    /// What the recorded places set at the pointer, nil when none of them covers it.
    public var recorded: Recorded?
    /// The cursor the app holds, named by identity with the system's named cursors; `unnamed` for another image, nil
    /// when the app holds none.
    public var appCursor: String?

    public init(at: Date, pid: Int32, pointer: Point, recorded: Recorded?, appCursor: String?) {
        version = Self.version
        self.at = ISO8601DateFormatter().string(from: at)
        self.pid = pid
        self.pointer = pointer
        self.recorded = recorded
        self.appCursor = appCursor
        let resolved = Self.resolve(recorded: recorded, appCursor: appCursor)
        cursor = resolved.cursor
        element = resolved.element
        source = resolved.source
    }

    /// The cursor at the pointer from what the recorded places set there and the cursor the app holds: a named cursor
    /// other than the arrow that differs from the recorded one was set outside the recorded places; else the recorded
    /// one; else the arrow, which nothing set. An unnamed cursor (an image of the app's own, or the system's way of
    /// drawing a recorded one) says nothing either way.
    public static func resolve(recorded: Recorded?, appCursor: String?) -> (cursor: Kind, element: String?, source: Source) {
        if let held = appCursor.flatMap(Kind.init(rawValue:)), held != .arrow, held != recorded?.cursor {
            return (held, nil, .unrecorded)
        }
        if let recorded { return (recorded.cursor, recorded.element, .recorded) }
        return (.arrow, nil, .none)
    }

    /// Whether `other` says the same as this report, whenever it was written.
    public func sameAs(_ other: QACursorReport) -> Bool {
        var other = other
        other.at = at
        return other == self
    }

    /// The report as the file holds it: snake_case keys, sorted.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decoded(_ data: Data) throws -> QACursorReport {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(QACursorReport.self, from: data)
    }
}

extension QAMode {
    /// The folder under the QA root the app writes its cursor report into, one file per process.
    public static let cursorFolder = "cursor"

    /// The cursor report of the app with `pid`: `<QA root>/cursor/<pid>.json`.
    public func cursorReport(pid: Int32) -> URL {
        root.appendingPathComponent(Self.cursorFolder, isDirectory: true).appendingPathComponent("\(pid).json")
    }
}

/// Writes the cursor report atomically, only when what it says changed, so the driver never reads half a file.
public final class QACursorReportWriter {
    public let file: URL
    private(set) var last: QACursorReport?

    public init(file: URL) {
        self.file = file
    }

    /// Writes `report` unless the last one written says the same; true when it wrote.
    @discardableResult
    public func write(_ report: QACursorReport) throws -> Bool {
        if let last, last.sameAs(report) { return false }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeReplacing(file, with: report.encoded(), permissions: 0o644)
        last = report
        return true
    }
}
