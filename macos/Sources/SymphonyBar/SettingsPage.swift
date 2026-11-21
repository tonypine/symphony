import Combine
import SwiftUI
import SymphonyBarCore

/// The Settings page of the Symphony window (TP-1575), which was its own window: the form's values, read fresh when the
/// page is first shown, and the section it shows. One form lives while the window is open, so unsaved edits survive a
/// move to another section or another page; Save and Revert read the saved values again, and so does the next window.
@MainActor
final class SettingsPage: ObservableObject {
    private let secrets: SecretsReader
    /// Runs Check Now and gives the last update check, shown under Update mode.
    let updates: UpdatePoller

    /// `secrets` is shared with Start, so Settings and Start can't each put up a Keychain prompt.
    init(secrets: SecretsReader, updates: UpdatePoller) {
        self.secrets = secrets
        self.updates = updates
    }

    /// Called after Save stored changed secrets, so a running Symphony restarts with them.
    var onSecretsChanged: () -> Void = {}

    /// Called after Save stored the settings, so a new update mode or check interval takes effect without a relaunch.
    var onSettingsSaved: (AppSettings) -> Void = { _ in }

    /// Today's tokens from the latest poll, nil while Symphony isn't answering. Shown under Agents.
    var budget: StateSnapshot.Budget? {
        didSet { model?.budget = budget }
    }

    /// Why this copy can't install updates with Development mode on or off, nil when it can. Shown under Update mode.
    var updateBlocker: (_ developmentMode: Bool) -> String? = { _ in nil }

    /// The form shown, nil until the page is first shown in this window.
    @Published private(set) var model: SettingsViewModel?
    /// The section the page shows.
    @Published var section: SettingsSection = .first
    /// The last Save stored everything and nothing was edited since: shown as "Saved.". The next Save (and so a
    /// refused one), an edit, Revert and the window's close clear it.
    @Published private(set) var saved = false
    /// Clears `saved` on the shown form's next edit.
    private var editsWatch: AnyCancellable?

    /// The page shows: the form is read once, and kept with its edits after that.
    func enter() {
        if model == nil { load() }
    }

    /// Revert: the unsaved edits go, and the form shows the saved values again. Nothing while Save runs.
    func revert() {
        guard model?.isSaving != true else { return }
        saved = false
        load()
    }

    /// Saves the form; once everything was stored, the form reads the saved values again and the page says so. A Save
    /// that finishes after the window closed (or after the form was read again) changes nothing on the page, so the next
    /// window still reads fresh values.
    func save() {
        guard let model else { return }
        saved = false
        model.save { [weak self, weak model] in
            guard let self, let model, self.model === model else { return }
            load()
            saved = true
        }
    }

    /// The window closed: its unsaved edits go with it, as they went with the old Settings window, and the next one
    /// opens on the first section.
    func leave() {
        model = nil
        editsWatch = nil
        saved = false
        section = .first
    }

    private func load() {
        let model = SettingsViewModel(secrets: secrets, onSecretsChanged: { [weak self] in self?.onSecretsChanged() })
        model.onSettingsSaved = { [weak self] settings in self?.onSettingsSaved(settings) }
        model.budget = budget
        model.updateBlocker = updateBlocker
        editsWatch = model.edits.sink { [weak self] in
            if self?.saved == true { self?.saved = false }
        }
        self.model = model
    }
}
