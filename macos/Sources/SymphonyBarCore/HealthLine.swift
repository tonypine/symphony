import Foundation

/// The window's status bar (TP-1454): the factory's health in one line beside the dispatch control. The control says
/// whether dispatch is on; the line after it says which build of Symphony runs and whether Symphony answers. The
/// runners join it when Phase 7 adds them.
public struct HealthLine: Equatable {
    /// One part of the line: its words, and the status token of the dot before them, nil for none.
    public struct Part: Equatable {
        public var text: String
        public var status: DesignTokens.Status?
        /// The pointer's help: the time of the last update for the connection.
        public var help: String?

        public init(text: String, status: DesignTokens.Status? = nil, help: String? = nil) {
            self.text = text
            self.status = status
            self.help = help
        }
    }

    /// The status line's counts (TP-1498), from Home's read of the dispatch order: what is in progress, in the queue
    /// and needs the Director. Nil while that read is unavailable, and the line shows none of them.
    public struct Counts: Equatable {
        public var inProgress: Int
        public var queued: Int
        public var needYou: Int

        public init(inProgress: Int, queued: Int, needYou: Int) {
            self.inProgress = inProgress
            self.queued = queued
            self.needYou = needYou
        }

        /// Home's board: its working, CI and build groups are in progress, its slot group is the queue. `needYou` is the
        /// Inbox's count, the one the sidebar's Home badge and the window bar's Inbox show, so the three agree. Nil for
        /// a Symphony that serves no dispatch order.
        public init?(board: HomeBoard, needYou: Int) {
            guard board.hasOrder else { return nil }
            func count(_ kinds: Set<DesignTokens.SituationKind>) -> Int {
                board.groups.filter { kinds.contains($0.kind) }.reduce(0) { $0 + $1.count }
            }
            self.init(inProgress: count([.working, .ci, .build]), queued: count([.slot]), needYou: needYou)
        }

        /// "7 in progress", "18 in the queue", "2 need you" (or "1 needs you"), in that order.
        public var texts: [String] {
            ["\(inProgress) in progress", "\(queued) in the queue", "\(needYou) \(needYou == 1 ? "needs" : "need") you"]
        }
    }

    /// What the dispatch control says, for the line's VoiceOver label.
    public var dispatch: String
    /// The counts after the dispatch control; nil without Home's read.
    public var counts: Counts?
    /// "Symphony 0.0.1.866 · a0be0aa", the build that answers; the app's version while none does.
    public var build: Part?
    /// "Answering", or why Symphony doesn't.
    public var connection: Part
    /// False while the counts are Symphony's last answer rather than a current one (TP-1562): they show marked so.
    public var countsCurrent: Bool
    /// What the line offers after the connection while Symphony is late: Open Logs and Restart Symphony.
    public var actions: [WindowState.Action]

    public static let answeringTitle = "Answering"

    /// `build` is Symphony's, from its last state payload; `appVersion` names the app's while Symphony doesn't answer.
    public init(
        window: WindowState,
        dispatch: DispatchControl,
        build: DiagnosticsPayload.Build?,
        appVersion: String,
        lastUpdate: Date?,
        counts: Counts? = nil,
        timeZone: TimeZone = .current
    ) {
        self.dispatch = dispatch.word
        self.counts = counts
        countsCurrent = window.countsCurrent
        actions = window.lineActions
        self.build = Self.buildPart(window: window, build: build, appVersion: appVersion)
        let help = lastUpdate.map { date in
            let formatter = DateFormatter()
            formatter.timeZone = timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "HH:mm:ss"
            return "Updated \(formatter.string(from: date))"
        }
        connection = Part(text: window.connectionLabel ?? Self.answeringTitle, status: window.connectionStatus, help: help)
    }

    private static func buildPart(window: WindowState, build: DiagnosticsPayload.Build?, appVersion: String) -> Part? {
        if window.servesPages, let build, let version = build.version, !version.isEmpty {
            let sha = build.sha.map { String($0.prefix(7)) }.flatMap { $0.isEmpty ? nil : $0 }
            return Part(text: (["Symphony \(version)"] + [sha].compactMap { $0 }).joined(separator: " · "))
        }
        return appVersion.isEmpty ? nil : Part(text: "App \(appVersion)")
    }

    /// The line's parts after the dispatch control, in order.
    public var parts: [Part] { [build].compactMap { $0 } + [connection] }

    /// What VoiceOver reads for the status line: "Dispatch on, 7 in progress, 18 in the queue, 2 need you, Symphony
    /// 0.0.1.866 · a0be0aa, Symphony answering". Counts from Symphony's last answer are read as such.
    public var accessibilityLabel: String {
        let countWords = (self.counts?.texts ?? []) + (self.counts != nil && !countsCurrent ? [Self.notCurrentWords] : [])
        return ([dispatch] + countWords + [build?.text].compactMap { $0 } + [Self.spoken(connection.text)])
            .joined(separator: ", ")
    }

    /// How VoiceOver reads counts that aren't current.
    public static let notCurrentWords = "as of Symphony's last answer"

    /// The connection's words as VoiceOver reads them: "Symphony answering", or a reason that already names Symphony.
    public static func spoken(_ connection: String) -> String {
        connection.hasPrefix("Symphony") ? connection : "Symphony \(connection.lowercased())"
    }
}
