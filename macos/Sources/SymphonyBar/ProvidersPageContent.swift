import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

// Factory › Providers (TP-1534) in the window: the page is drawn from the state's `providers`, Pause and Resume go to
// the control API, and the state read after the answer is what the page shows next.

extension SymphonyWindowModel {
    /// The page from the last state Symphony served, on Symphony's clock.
    var providersPage: ProvidersPage {
        ProvidersPage(providers: overviewState?.snapshot.providers, now: overviewState?.generatedAt ?? Date())
    }

    var providersActions: ProvidersPageActions {
        ProvidersPageActions(
            select: { [weak self] in self?.providerSelection = $0 },
            send: { [weak self] in self?.send($0) }
        )
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
