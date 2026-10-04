import Foundation

/// Scripted QA mode (`SYMPHONY_BAR_QA_SCRIPTED=1` with `SYMPHONY_BAR_QA_ROOT`), for end-to-end tests that drive the
/// app without Accessibility access:
///
/// - a test presses a menu item by writing its title to a file in `<QA root>/commands/`. The app takes the files in
///   name order, deletes each one, and presses the visible item with that title the way a click would: only when it
///   is enabled. An item in a visible item's submenu counts as visible. The lines after the title answer a text
///   prompt the press shows, such as Force a ticket…;
/// - the app keeps `<QA root>/status.json` current: its process, build, the Symphony it runs, every visible menu item
///   (submenu items after the item they open from) with whether it is enabled, the alerts it would have shown and the
///   presses it handled;
/// - alerts are recorded in `status.json` instead of shown, and confirmations are answered yes.
public enum QAScript {
    public static let commandsFolder = "commands"
    public static let statusFileName = "status.json"

    /// A menu press a test asked for.
    public struct Command: Equatable {
        /// The file the test wrote; the app deletes it once read.
        public let file: URL
        /// The title of the menu item to press.
        public let title: String
        /// The answer to a text prompt the press shows, nil when the file holds only the title.
        public let input: String?

        public init(file: URL, title: String, input: String? = nil) {
            self.file = file
            self.title = title
            self.input = input
        }

        /// The command in a file's contents: the title on the first line, the prompt's answer on the lines after.
        public init(file: URL, contents: String) {
            let text = contents.trimmingWhitespace()
            let lines = text.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            let input = lines.count > 1 ? String(lines[1]).trimmingWhitespace() : ""
            self.init(
                file: file,
                title: lines.first.map { String($0).trimmingWhitespace() } ?? "",
                input: input.isEmpty ? nil : input
            )
        }
    }

    /// The commands waiting in `folder`, by file name. Names starting with `.` are skipped, so a test can write a
    /// command under a hidden name and rename it once complete.
    public static func pendingCommands(in folder: URL) -> [Command] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().compactMap { name in
            let file = folder.appendingPathComponent(name)
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return Command(file: file, contents: contents)
        }
    }

    /// What became of a press.
    public enum PressResult: String, Codable, Equatable {
        case pressed
        /// The item is there but disabled, so nothing happened, as for a click.
        case disabled
        /// No visible menu item has that title.
        case missing
    }

    public struct MenuItem: Codable, Equatable {
        public var title: String
        public var enabled: Bool

        public init(title: String, enabled: Bool) {
            self.title = title
            self.enabled = enabled
        }
    }

    public struct Alert: Codable, Equatable {
        public var title: String
        public var message: String

        public init(title: String, message: String) {
            self.title = title
            self.message = message
        }
    }

    public struct Press: Codable, Equatable {
        /// The command file's name.
        public var command: String
        public var title: String
        public var result: PressResult

        public init(command: String, title: String, result: PressResult) {
            self.command = command
            self.title = title
            self.result = result
        }
    }

    /// The contents of `status.json`.
    public struct Status: Codable, Equatable {
        public var pid: Int32
        /// `CFBundleShortVersionString`.
        public var version: String
        /// `CFBundleVersion`.
        public var build: Int
        public var appPath: String
        /// The Symphony the app started, nil while it runs none.
        public var symphonyPID: Int32?
        public var menu: [MenuItem]
        public var alerts: [Alert]
        public var presses: [Press]

        public init(
            pid: Int32,
            version: String,
            build: Int,
            appPath: String,
            symphonyPID: Int32?,
            menu: [MenuItem],
            alerts: [Alert],
            presses: [Press]
        ) {
            self.pid = pid
            self.version = version
            self.build = build
            self.appPath = appPath
            self.symphonyPID = symphonyPID
            self.menu = menu
            self.alerts = alerts
            self.presses = presses
        }

        enum CodingKeys: String, CodingKey {
            case pid, version, build, menu, alerts, presses
            case appPath = "app_path"
            case symphonyPID = "symphony_pid"
        }

        /// Writes `symphony_pid` as `null` while no Symphony runs, rather than leaving it out.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pid, forKey: .pid)
            try container.encode(version, forKey: .version)
            try container.encode(build, forKey: .build)
            try container.encode(appPath, forKey: .appPath)
            try container.encode(symphonyPID, forKey: .symphonyPID)
            try container.encode(menu, forKey: .menu)
            try container.encode(alerts, forKey: .alerts)
            try container.encode(presses, forKey: .presses)
        }
    }

    /// The JSON written to `status.json`, with sorted keys.
    public static func encode(_ status: Status) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(status)
    }

    /// Replaces `file` with `status`, so a test never reads half of it.
    public static func write(_ status: Status, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeReplacing(file, with: encode(status), permissions: 0o644)
    }
}

extension QAMode {
    public var commandsFolder: URL { root.appendingPathComponent(QAScript.commandsFolder, isDirectory: true) }
    public var statusFile: URL { root.appendingPathComponent(QAScript.statusFileName) }
}
