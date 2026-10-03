import SymphonyBarCore

extension AppStores {
    /// The app's stores, picked once from its environment: QA mode when `SYMPHONY_BAR_QA_ROOT` is set.
    static let current = AppStores()
}
