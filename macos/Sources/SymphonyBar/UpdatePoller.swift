import AppKit
import SymphonyBarCore

/// Checks GitHub for a newer Symphony at launch, on the interval `UpdateCheckSchedule` gives, when Check for Updates
/// or Check Now is chosen, and once when Symphony reports a newer release on a status poll.
@MainActor
final class UpdatePoller: ObservableObject {
    /// Called after each check; `manual` is true for a check started from the menu or Settings.
    var onResult: ((UpdateCheckResult, _ manual: Bool) -> Void)?

    let current = AppBuild(
        infoDictionary: Bundle.main.infoDictionary,
        hasEmbeddedSymphony: Bundle.main.url(forResource: "symphony", withExtension: nil) != nil
    )
    /// The interval and the last check, which Settings and the menu show.
    @Published private(set) var schedule: UpdateCheckSchedule

    var isChecking: Bool { schedule.isChecking }

    private let checker = UpdateChecker(url: AppStores.current.updateURL)
    private var timer: Timer?

    init() {
        let settings = AppStores.current.settingsStore().loadSettings()
        schedule = UpdateCheckSchedule(
            mode: settings.updateMode,
            releaseCheckMinutes: settings.releaseCheckMinutes,
            override: AppStores.current.updateCheckInterval
        )
    }

    func start() {
        check(manual: false)
    }

    /// Takes saved settings without a relaunch: checks now when the mode became Automatically when released or its
    /// minutes changed, and otherwise re-arms the timer with the new interval.
    func configure(_ settings: AppSettings) {
        let interval = schedule.interval
        if schedule.configure(mode: settings.updateMode, releaseCheckMinutes: settings.releaseCheckMinutes) {
            check(manual: false)
        } else if !isChecking, schedule.interval != interval {
            arm()
        }
    }

    /// Takes the release Symphony reported on a status poll: checks at once when it is newer than this build and no
    /// check started for it yet, so a new release costs one GitHub request and the timer stays the safety net.
    func reported(_ release: ReportedRelease?) {
        guard schedule.checksAtOnce(for: release, running: current, now: Date()) else { return }
        check(manual: false, reported: release)
    }

    func check(manual: Bool, reported: ReportedRelease? = nil) {
        guard !isChecking else { return }
        schedule.began(reported: reported)
        timer?.invalidate()
        Task {
            let result = await checker.check(current: current)
            schedule.finished(result, at: Date())
            arm()
            onResult?(result, manual)
        }
    }

    private func arm() {
        timer?.invalidate()
        let interval = schedule.interval
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            MainActor.assumeIsolated { self.check(manual: false) }
        }
        timer.tolerance = interval / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Shows the release notes in an alert with scrollable text, with a button that opens the release page. A
    /// `message`, as after a rollback, shows above the notes, with a button that opens the README's rollback steps.
    /// Scripted QA mode records the window, `message` above the notes, instead of showing it.
    static func showReleaseNotes(_ release: Release, message: String? = nil) {
        if let script = QAScriptDriver.shared {
            let text = [message, release.notes].compactMap { $0 }.joined(separator: "\n\n")
            script.record(alertTitle: UpdateMenu.releaseNotesHeading(release), message: text)
            return
        }
        let alert = NSAlert()
        alert.messageText = UpdateMenu.releaseNotesHeading(release)
        alert.addButton(withTitle: UpdateMenu.openReleasePageTitle)
        if let message {
            alert.informativeText = message
            alert.addButton(withTitle: UpdateMenu.rollbackStepsTitle)
        }
        alert.addButton(withTitle: "Close")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.contentView.bounds)
        text.autoresizingMask = [.width]
        text.isEditable = false
        text.isSelectable = true
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        text.string = release.notes
        scroll.documentView = text
        alert.accessoryView = scroll

        SymphonyRunner.activateApp()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.pageURL)
        case .alertSecondButtonReturn where message != nil:
            NSWorkspace.shared.open(UpdateMenu.rollbackStepsURL)
        default:
            break
        }
    }
}
