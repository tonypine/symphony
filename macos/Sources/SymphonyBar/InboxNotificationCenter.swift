import AppKit
import SymphonyBarCore
import UserNotifications

/// Posts the Inbox's notifications (D14, C22): one per new item or problem, grouped by kind, with Open, and no
/// sound. Permission is asked the first time one is due. In scripted QA mode they are recorded instead.
@MainActor
final class InboxNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let categoryID = "symphony.inbox"
    nonisolated static let openActionID = "symphony.inbox.open"
    nonisolated static let openTitle = "Open"
    nonisolated private static let issueKey = "issueID"

    /// Open chosen on a notification: the Inbox item's issue id, nil for a problem.
    var onOpen: (String?) -> Void = { _ in }

    private let defaults: KeyValueStore
    private var notifier: InboxNotifier
    private var registered = false

    init(defaults: KeyValueStore) {
        self.defaults = defaults
        notifier = InboxNotifier.load(from: defaults)
    }

    /// Notifies what is new in `state` since the last poll.
    func update(_ state: OverviewState, now: Date = Date()) {
        let before = notifier
        let notices = notifier.notices(
            waiting: state.snapshot.waitingOnYou,
            problems: Overview.problems(state, now: now),
            preferences: NotificationPreferences.load(from: defaults),
            inboxRead: state.snapshot.inboxRead
        )
        if notifier != before { notifier.save(to: defaults) }
        notices.forEach(post)
    }

    private func post(_ notice: InboxNotice) {
        if let script = QAScriptDriver.shared {
            script.record(alertTitle: notice.title, message: notice.body)
            return
        }
        // UNUserNotificationCenter needs an app bundle; `swift run` has none.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        registerIfNeeded(center)
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = nil
        content.categoryIdentifier = Self.categoryID
        content.threadIdentifier = notice.kind.rawValue
        if let issueID = notice.issueID { content.userInfo = [Self.issueKey: issueID] }
        let request = UNNotificationRequest(identifier: notice.key, content: content, trigger: nil)
        Task {
            // The system asks only the first time; later calls answer with the choice made.
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            try? await center.add(request)
        }
    }

    private func registerIfNeeded(_ center: UNUserNotificationCenter) {
        guard !registered else { return }
        registered = true
        center.delegate = self
        let open = UNNotificationAction(identifier: Self.openActionID, title: Self.openTitle, options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.categoryID, actions: [open], intentIdentifiers: [])])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let issueID = response.notification.request.content.userInfo[Self.issueKey] as? String
        let opens = [Self.openActionID, UNNotificationDefaultActionIdentifier].contains(response.actionIdentifier)
        Task { @MainActor in
            if opens { self.onOpen(issueID) }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
