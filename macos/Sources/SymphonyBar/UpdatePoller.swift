import AppKit
import SymphonyBarCore

/// Checks GitHub for a newer Symphony at launch, on the interval `UpdateCheckSchedule` gives, and when Check for
/// Updates or Check Now is chosen.
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

    func check(manual: Bool) {
        guard !isChecking else { return }
        schedule.began()
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
    static func showReleaseNotes(_ release: Release, message: String? = nil) {
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
