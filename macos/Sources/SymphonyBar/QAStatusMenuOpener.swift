import AppKit
import SymphonyBarCore

/// QA mode only: opens the status item's menu on screen when QA asks (`QAStatusMenuRequest`), so a QA pass can
/// screenshot it. See `QAStatusMenuRequest` for why the request is a file rather than an Accessibility press.
@MainActor
final class QAStatusMenuOpener {
    /// The opener while the app runs in QA mode, nil otherwise.
    static private(set) var shared: QAStatusMenuOpener?

    /// How often the opener looks for a request.
    static let interval: TimeInterval = 0.25

    private let request: QAStatusMenuRequest
    private let item: NSStatusItem
    private var menuOpen = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// Starts the opener when the app is in QA mode; outside it the app watches for no request.
    static func startIfQAMode(item: NSStatusItem) {
        guard shared == nil, let request = QAStatusMenuRequest(qaMode: AppStores.current.qaMode) else { return }
        let opener = QAStatusMenuOpener(request: request, item: item)
        shared = opener
        opener.start()
    }

    private init(request: QAStatusMenuRequest, item: NSStatusItem) {
        self.request = request
        self.item = item
    }

    private func start() {
        if let menu = item.menu {
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: menu, queue: .main) { _ in
                    MainActor.assumeIsolated { self.menuOpen = true }
                },
                center.addObserver(forName: NSMenu.didEndTrackingNotification, object: menu, queue: .main) { _ in
                    MainActor.assumeIsolated { self.menuOpen = false }
                },
            ]
        }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        // Common modes, so a request that comes while the menu is open is taken, and dropped, rather than reopening
        // the menu after it closes.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard request.take(), !menuOpen, let button = item.button else { return }
        // Opening the menu runs its tracking loop until it closes, so it runs after this timer returns, from the
        // default mode, as a click on the item does.
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated { button.performClick(nil) }
        }
    }
}
