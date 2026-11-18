import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

// Factory › Runs (TP-1538) in the window: the page reads `symphony.yml` when it opens, loads the models each provider
// offers, and Save writes the changes once `symphony check` passes on the whole file (`RunsEditor.save`).

extension SymphonyWindowModel {
    /// The file Settings names, or nil while none is set.
    var runsFile: SymphonyConfigFile? { SymphonyConfigFile(settingsPath: configPath()) }

    /// Reads the file as the page opens. Changes not saved stay; the model lists load once.
    func openRuns() {
        runsPage.read(runsFile)
        if runsPage.editor != nil { loadRunModelListsIfNeeded() }
    }

    /// OpenRouter's models from its models API and OpenCode Go's from `opencode models`, each once.
    private func loadRunModelListsIfNeeded() {
        guard !runsPage.listsRequested else { return }
        runsPage.listsRequested = true
        let lists = runsPage.lists
        if lists.openRouter == nil {
            Task {
                let models = await OpenRouterClient(baseURL: AppStores.current.openRouterBaseURL).models()
                runsPage.lists.openRouter = models
            }
        }
        if lists.openCodeGo == nil {
            let command = runsPage.editor?.profiles[.opencode].command
            let launch = OpenCodeModels.launch(
                command: command, environment: AppStores.current.environment, workingDirectory: NSHomeDirectory()
            )
            Task {
                let models = await OpenCodeModels.load(launch)
                runsPage.lists.openCodeGo = models
            }
        }
    }

    /// Save: writes the changes once `symphony check` passes; a refused save keeps every change and says why.
    func saveRuns() {
        guard let file = runsFile, let editor = runsPage.beginSave() else { return }
        let check = onCheckConfig
        Task {
            let outcome = await editor.save(to: file, checkingWith: check)
            runsPage.finishSave(outcome)
            guard case .saved = outcome else { return }
            try? await Task.sleep(for: .seconds(DesignTokens.SaveBar.savedFor))
            runsPage.clearSaved()
        }
    }

    var runsActions: RunsPageActions {
        RunsPageActions(
            show: { [weak self] in self?.runsPage.show($0) },
            pick: { [weak self] kind, line, field, value in self?.runsPage.pick(field, of: line, kind: kind, to: value) },
            useDefaults: { [weak self] in self?.runsPage.useDefaults($0) },
            addFallback: { [weak self] in self?.runsPage.addFallback($0) },
            remove: { [weak self] kind, line in self?.runsPage.remove(line, of: kind) },
            reorder: { [weak self] kind, order in self?.runsPage.reorder(kind, to: order) },
            revert: { [weak self] in self?.runsPage.revert() },
            save: { [weak self] in self?.saveRuns() },
            setCommand: { [weak self] harness, command in self?.runsPage.setCommand(command, of: harness) },
            pickSmallModel: { [weak self] harness, provider, value in self?.runsPage.pickSmallModel(value, of: harness, on: provider) }
        )
    }
}

/// The page, or the state while the file is read or couldn't be.
struct RunsContent: View {
    @ObservedObject var model: SymphonyWindowModel

    var body: some View {
        Group {
            if model.runsPage.editor != nil {
                // Each line whose provider is paused or held says so, from the state Symphony served last (TP-1534).
                RunsPageView(page: model.runsPage.showing(model.overviewState?.snapshot.providers), actions: model.runsActions)
            } else if let error = model.runsPage.loadError {
                EmptyState(title: error, symbol: SymphonyView.runs.symbol, actions: [(RunsPage.readAgain, { model.openRuns() })])
            } else {
                EmptyState(title: RunsPage.reading, symbol: SymphonyView.runs.symbol, showsSpinner: true)
            }
        }
        .onAppear { model.openRuns() }
    }
}
