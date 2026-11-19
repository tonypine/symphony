import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

// Factory › Providers (TP-1534) in the window: the page is drawn from the state's `providers`, Pause and Resume go to
// the control API, and the state read after the answer is what the page shows next. The Key blocks (TP-1540) read and
// write the provider keys and the enabled set in the app's secrets; a change to what Symphony is launched with restarts
// it, as Settings does, since Symphony reads its secrets only at start.

extension SymphonyWindowModel {
    /// The page from the last state Symphony served, on Symphony's clock, with the app's provider keys.
    var providersPage: ProvidersPage {
        ProvidersPage(
            providers: overviewState?.snapshot.providers, now: overviewState?.generatedAt ?? Date(), keys: providerKeys,
            keyEditor: providerKeyEditor
        )
    }

    var providersActions: ProvidersPageActions {
        ProvidersPageActions(
            select: { [weak self] in self?.providerSelection = $0 },
            send: { [weak self] in self?.send($0) },
            editKey: { [weak self] id, text in self?.editProviderKey(id, text) },
            testKey: { [weak self] in self?.testProviderKey($0) },
            setEnabled: { [weak self] id, on in self?.setProviderEnabled(id, on) },
            removeKey: { [weak self] in self?.removeProviderKey($0) }
        )
    }

    /// Reads the provider keys off the main thread with the app's secrets reader, so a Keychain prompt while the
    /// secrets move can't freeze the window.
    func loadProviderKeys(with reader: SecretsReader?) {
        let reader = reader ?? SecretsReader(load: AppStores.current.settingsStore().loadSecrets)
        reader.read { [weak self] result in
            switch result {
            case .success(let secrets): self?.providerKeys = secrets.providers
            case .failure(let error): SymphonyRunner.showAlert(title: "Could not read the provider keys", body: "\(error)")
            }
        }
    }

    func editProviderKey(_ id: String, _ text: String) {
        guard let keys = providerKeys else { return }
        providerKeyEditor.edit(id, to: text, keys: keys)
    }

    /// Test connection: a pass keeps the key; the enabled set doesn't change.
    func testProviderKey(_ id: String) {
        guard let keys = providerKeys, let key = providerKeyEditor.beginTest(id, keys: keys) else { return }
        Task {
            let check = ProviderKeyCheck(
                openRouter: OpenRouterClient(baseURL: AppStores.current.openRouterBaseURL),
                openCodeGo: OpenCodeGoClient(baseURL: AppStores.current.openCodeGoBaseURL)
            )
            let result = await check.test(key, provider: id)
            guard let current = providerKeys else { return }
            if let kept = providerKeyEditor.finishTest(id, key: key, result: result, keys: current) { storeProviderKeys(kept) }
        }
    }

    func setProviderEnabled(_ id: String, _ on: Bool) {
        guard let keys = providerKeys else { return }
        if on, !providerKeyEditor.canEnable(id, keys: keys) { return }
        storeProviderKeys(keys.enabling(id, on))
    }

    func removeProviderKey(_ id: String) {
        guard let keys = providerKeys else { return }
        storeProviderKeys(providerKeyEditor.removeKey(id, keys: keys))
    }

    /// Writes `keys` over those read and shows them; restarts Symphony when what it is launched with changed.
    private func storeProviderKeys(_ keys: ProviderKeys) {
        guard let old = providerKeys else { return }
        do {
            try AppStores.current.settingsStore().saveProviderKeys(keys, over: old)
        } catch {
            SymphonyRunner.showAlert(title: "Could not save the provider keys", body: "\(error)")
            return
        }
        providerKeys = keys
        if keys.environment != old.environment { onRestartSymphony() }
    }
}

/// The page, or why there is none.
struct ProvidersContent: View {
    @ObservedObject var model: SymphonyWindowModel

    var body: some View {
        let page = model.providersPage
        if page.providers == nil {
            EmptyState(title: EndpointPlaceholder.updateSymphony, symbol: EndpointPlaceholder.updateSymbol)
        } else if page.ordered.isEmpty {
            EmptyState(title: ProvidersPage.emptyTitle, symbol: SymphonyView.providers.symbol)
        } else {
            ProvidersPageView(
                page: page, selection: model.providerSelection, actions: model.providersActions, sending: model.controlInFlight != nil
            )
        }
    }
}
