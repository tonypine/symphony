import AppKit
import SymphonyBarCore
import UserNotifications

/// Posts the Inbox's notifications (D14, C22): one per new item or problem, grouped by kind, with Open, and no
/// sound; a pull request whose checks are green also gets Approve and Merge…, which opens the app on its sheet and
/// approves nothing itself. Permission is asked the first time one is due. In scripted QA mode they are recorded
/// instead. It also posts the notification an update Automatically when released posts as it starts (S4c), with
/// Cancel Update, as the app's one notification delegate.
@MainActor
final class InboxNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let categoryID = "symphony.inbox"
    nonisolated static let mergeCategoryID = "symphony.inbox.green-pr"
    nonisolated static let openActionID = "symphony.inbox.open"
    nonisolated static let approveAndMergeActionID = "symphony.inbox.approve-and-merge"
    nonisolated static let updateCategoryID = "symphony.update"
    nonisolated static let cancelUpdateActionID = "symphony.update.cancel"
    nonisolated static let openTitle = "Open"
    nonisolated private static let issueKey = "issueID"

    /// Open chosen on a notification: the Inbox item's issue id, nil for a problem.
    var onOpen: (String?) -> Void = { _ in }
    /// Approve and Merge… chosen on a pull request's notification: the Inbox item's issue id.
    var onApproveAndMerge: (String) -> Void = { _ in }
    /// Cancel Update chosen on the update's start notification.
    var onCancelUpdate: () -> Void = {}

    private let defaults: KeyValueStore
    private var notifier: InboxNotifier
    /// The update's start notification scripted QA mode recorded and the app hasn't withdrawn yet.
    private var recordedUpdateStarted: String?

    init(defaults: KeyValueStore) {
        self.defaults = defaults
        notifier = InboxNotifier.load(from: defaults)
    }

    /// Takes Open on notifications, from earlier runs too, so call it before launch finishes. A scripted QA run and
    /// `swift run` post none.
    func start() {
        if AppStores.current.qaMode?.scripted == true { return }
        // UNUserNotificationCenter needs an app bundle; `swift run` has none.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: Self.openActionID, title: Self.openTitle, options: [.foreground])
        let merge = UNNotificationAction(identifier: Self.approveAndMergeActionID, title: InboxNotice.approveAndMergeTitle, options: [.foreground])
        let cancelUpdate = UNNotificationAction(identifier: Self.cancelUpdateActionID, title: UpdateNotice.cancelUpdateTitle)
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID, actions: [open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.mergeCategoryID, actions: [open, merge], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.updateCategoryID, actions: [cancelUpdate], intentIdentifiers: []),
        ])
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
            // The actions it would offer besides Open, so a script can check them.
            let message = notice.offersApproveAndMerge ? "\(notice.body) · \(InboxNotice.approveAndMergeTitle)" : notice.body
            script.record(alertTitle: notice.title, message: message)
            return
        }
        // UNUserNotificationCenter needs an app bundle; `swift run` has none.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = nil
        content.categoryIdentifier = notice.offersApproveAndMerge ? Self.mergeCategoryID : Self.categoryID
        content.threadIdentifier = notice.kind.rawValue
        if let issueID = notice.issueID { content.userInfo = [Self.issueKey: issueID] }
        let request = UNNotificationRequest(identifier: notice.key, content: content, trigger: nil)
        Task {
            // The system asks only the first time; later calls answer with the choice made.
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            try? await center.add(request)
        }
    }

    /// Posts the update's start notification, with Cancel Update and no sound. Nothing shows in its place when
    /// notifications aren't allowed. Scripted QA mode records it, with its action.
    func postUpdateStarted(_ notice: UpdateNotice) {
        if let script = QAScriptDriver.shared {
            script.record(alertTitle: notice.title, message: notice.messageWithCancelUpdate)
            recordedUpdateStarted = notice.title
            return
        }
        // UNUserNotificationCenter needs an app bundle; `swift run` has none.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = nil
        content.categoryIdentifier = Self.updateCategoryID
        let request = UNNotificationRequest(identifier: UpdateStartNotifier.requestIdentifier, content: content, trigger: nil)
        Task {
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            try? await center.add(request)
        }
    }

    /// Removes the update's start notification from Notification Center, as when the update ends. Scripted QA mode
    /// records the withdrawal of the one it recorded.
    func withdrawUpdateStarted() {
        if let script = QAScriptDriver.shared {
            if let title = recordedUpdateStarted { script.record(withdrawn: title) }
            recordedUpdateStarted = nil
            return
        }
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [UpdateStartNotifier.requestIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [UpdateStartNotifier.requestIdentifier])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let issueID = response.notification.request.content.userInfo[Self.issueKey] as? String
        let action = response.actionIdentifier
        let opens = [Self.openActionID, UNNotificationDefaultActionIdentifier].contains(action)
        Task { @MainActor in
            if action == Self.cancelUpdateActionID {
                self.onCancelUpdate()
            } else if action == Self.approveAndMergeActionID, let issueID {
                self.onApproveAndMerge(issueID)
            } else if opens {
                self.onOpen(issueID)
            }
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
