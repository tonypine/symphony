import Foundation
import SymphonyBarCore

extension AppStores {
    /// The app's stores, picked once from its environment: QA mode when `SYMPHONY_BAR_QA_ROOT` is set.
    static let current = AppStores()

    /// Sends a control action to Symphony, or to the API fixtures when they answer.
    func sendControl(_ action: ControlAction, stateRoot: URL) async -> ControlResult {
        await ControlAPI.send(action, stateRoot: stateRoot, fallback: apiFallback, token: apiToken, transport: apiTransport)
    }

    /// Asks Symphony, or the API fixtures when they answer, for its repos.
    func fetchRepos(stateRoot: URL) async -> ReposPoll {
        await ReposAPI.fetch(stateRoot: stateRoot, fallback: apiFallback, transport: apiTransport)
    }
}
