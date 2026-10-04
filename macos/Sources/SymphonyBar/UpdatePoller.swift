import AppKit
import SymphonyBarCore

/// Checks GitHub for a newer Symphony at launch, every 6 hours, and when Check for Updates is chosen.
@MainActor
final class UpdatePoller {
    /// Called after each check; `manual` is true for a check started from the menu.
    var onResult: ((UpdateCheckResult, _ manual: Bool) -> Void)?

    let current = AppBuild(
        infoDictionary: Bundle.main.infoDictionary,
        hasEmbeddedSymphony: Bundle.main.url(forResource: "symphony", withExtension: nil) != nil
    )
    private(set) var isChecking = false

    private let checker = UpdateChecker(url: AppStores.current.updateURL)
    private var timer: Timer?

    func start() {
        check(manual: false)
    }

    func check(manual: Bool) {
        guard !isChecking else { return }
        isChecking = true
        timer?.invalidate()
        Task {
            let result = await checker.check(current: current)
            isChecking = false
            schedule()
            onResult?(result, manual)
        }
    }

    private func schedule() {
        let interval = UpdateChecker.interval
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            MainActor.assumeIsolated { self.check(manual: false) }
        }
        timer.tolerance = interval / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Shows the release notes in an alert with scrollable text, with a button that opens the release page.
    static func showReleaseNotes(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = UpdateMenu.releaseNotesHeading(release)
        alert.addButton(withTitle: UpdateMenu.openReleasePageTitle)
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
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.pageURL)
        }
    }
}
