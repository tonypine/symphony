import AppKit
import SwiftUI
import SymphonyBarCore

/// Owns the single Symphony window (DD1). While it is open the app is a regular app, with a Dock icon, a ⌘-Tab entry
/// and its main menu; once it closes the app is back in the menu bar only (DD2). Its frame and view come back after
/// a close and a relaunch.
@MainActor
final class SymphonyWindowController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    static let windowTitle = "Symphony"
    /// The window's frame, in the app's defaults so QA mode keeps it under the QA root.
    private let frame = WindowFrameStore(name: "SymphonyMainWindow", defaults: AppStores.current.defaults)
    /// The app's defaults key for the view shown last.
    private static let viewKey = "SymphonyWindowView"

    let client: LiveAPIClient
    /// The app's version, shown in the sidebar footer while Symphony doesn't say its own.
    var appVersion = ""
    /// Symphony's state directory, for the control URL Diagnostics shows.
    var stateRoot: () -> URL = { StateRoot.locate(environment: AppStores.current.environment) }
    var onAction: (WindowState.Action) -> Void = { _ in }
    /// Opens the Repos window; with a repo key, on that repo's Review sheet.
    var openRepos: (String?) -> Void = { _ in }
    var canOpenLogs: () -> Bool = { false }
    /// Called once a control request from the window was answered, so the menu follows too.
    var afterControl: () -> Void = {}
    /// The app's own build, for Setup's build warning.
    var appBuild = AppBuild(build: 0, isDevelopment: true)
    /// The app's secrets, for the `symphony check` a Setup settings fix runs.
    var secrets: SecretsReader?

    private var window: NSWindow?
    private var model: SymphonyWindowModel?
    /// The transcript windows (D4), which stay open after the main window closes.
    private lazy var transcripts: TranscriptWindows = {
        let transcripts = TranscriptWindows(client: client)
        transcripts.reference = { [weak self] in
            self?.client.stateJSON.flatMap(OverviewState.decode)?.generatedAt ?? Date()
        }
        return transcripts
    }()
    private var state = WindowState.stopped
    private var paused = false
    private var updateHold: UpdateHold?

    init(client: LiveAPIClient) {
        self.client = client
    }

    var isOpen: Bool { window != nil }

    /// What waits on the Director, shown on the Dock icon while the window is open (the app has no Dock icon
    /// otherwise); nil clears it.
    var dockBadge: Int? {
        didSet { showDockBadge() }
    }

    private func showDockBadge() {
        NSApp.dockTile.badgeLabel = window == nil ? nil : dockBadge.map(String.init)
    }

    /// Opens the window on `view`.
    func show(view: SymphonyView) {
        show()
        model?.show(view)
    }

    /// SU12: opens the window on the Setup page, with the first launch's welcome line when `welcome` is given.
    func showSetup(welcome: String?) {
        show(view: .setup)
        model?.setupWelcome = welcome
    }

    /// Opens the window on the Inbox, with the item of issue id `id` selected when it is listed.
    func showInbox(selecting id: String?) {
        show()
        model?.showInbox(selecting: id)
    }

    /// Opens the window on the Inbox item of issue id `id` with its `move` sheet: nothing changes until the sheet's
    /// button is pressed.
    func showInbox(selecting id: String, opening move: InboxMove) {
        show()
        model?.showInbox(selecting: id, opening: move)
    }

    /// Opens the window with the Pause Dispatch sheet: nothing pauses until its button is pressed.
    func showPauseSheet() {
        show()
        model?.openPauseSheet()
    }

    /// Opens the window with the Force a Ticket sheet.
    func showForceSheet() {
        show()
        model?.openForceSheet()
    }

    /// Opens the window, or brings it to the front.
    func show() {
        if window == nil {
            let saved = AppStores.current.defaults.object(forKey: Self.viewKey) as? String
            let model = SymphonyWindowModel(client: client, selection: Sidebar().restoredView(saved: saved))
            model.state = state
            model.paused = paused
            model.updateHold = updateHold
            model.appVersion = appVersion
            model.apiURL = { [weak self] in self.flatMap { StateRoot.controlURL(in: $0.stateRoot(), fallback: AppStores.current.apiFallback) } }
            model.canOpenLogs = { [weak self] in self?.canOpenLogs() ?? false }
            model.onSelect = { view in AppStores.current.defaults.set(view.rawValue, forKey: Self.viewKey) }
            model.onAction = { [weak self] action in self?.onAction(action) }
            model.onOpenRepos = { [weak self] key in self?.openRepos(key) }
            model.scope = OverviewScope.load(from: AppStores.current.defaults)
            model.onScopeChange = { scope in scope.save(to: AppStores.current.defaults) }
            model.onControl = { [weak self] action in
                guard let self else { return .done }
                let result = await AppStores.current.sendControl(action, stateRoot: stateRoot())
                afterControl()
                return result
            }
            model.onCheckNow = { [weak self] identifier in
                guard let self else { return .failed("") }
                return await WatchCheck.send(
                    identifier, stateRoot: stateRoot(), fallback: AppStores.current.apiFallback, transport: AppStores.current.apiTransport
                )
            }
            model.onOpenURL = { url in URLOpener.open(url) }
            model.appBuild = appBuild
            model.configPath = { AppStores.current.settingsStore().loadSettings().configPath }
            model.onSetupRequest = { [weak self] fix in
                guard let self else { return .failed("") }
                let result = await SetupAPI.send(
                    fix: fix, stateRoot: stateRoot(), fallback: AppStores.current.apiFallback, transport: AppStores.current.apiTransport
                )
                afterControl()
                return result
            }
            model.onCheckConfig = { [weak self] path in
                guard let secrets = self?.secrets else { return .failed("The app's secrets aren't available to run symphony check.") }
                return await ReposWindowController.configCheck(path, secrets: secrets)
            }
            model.onOpenTranscript = { [weak self] identifier, repoKey, newWindow in
                self?.transcripts.open(identifier: identifier, repoKey: repoKey, newWindow: newWindow)
            }
            self.model = model

            let hostingController = NSHostingController(
                rootView: SymphonyWindowView(model: model).environment(\.openURL, URLOpener.action)
            )
            // SwiftUI's toolbar goes in the window's; the window keeps its own title.
            hostingController.sceneBridgingOptions = [.toolbars]
            // The window keeps the size the user set: the content's minimum never widens it, `contentMinSize` bounds it.
            hostingController.sizingOptions = []
            let window = NSWindow(contentViewController: hostingController)
            window.title = Self.windowTitle
            window.titleVisibility = .hidden
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: DesignTokens.Layout.windowWidth, height: DesignTokens.Layout.windowHeight))
            window.contentMinSize = NSSize(
                width: DesignTokens.Layout.minWindowWidth,
                height: DesignTokens.Layout.minWindowHeight
            )
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.restoreFrame(from: frame)
            self.window = window
        }

        NSApp.setActivationPolicy(.regular)
        showDockBadge()
        SymphonyRunner.activateApp()
        window?.makeKeyAndOrderFront(nil)
        // Puts the window in front even if the system still declined to activate the app.
        window?.orderFrontRegardless()
        client.isVisible = true
    }

    /// Called after each status poll and child process event.
    func update(status: SymphonyStatus, configPath: String) {
        let next = WindowState(status: status, hasConfig: WindowState.hasConfig(path: configPath))
        if case .paused = status { paused = true } else { paused = false }
        // Fresh values as soon as Symphony answers, rather than at the next poll.
        if next == .connected, state != .connected { client.refresh() }
        state = next
        model?.state = next
        model?.paused = paused
    }

    /// Called after each change to the update under way: nil once none is.
    func update(updateHold: UpdateHold?) {
        guard updateHold != self.updateHold else { return }
        self.updateHold = updateHold
        model?.updateHold = updateHold
    }

    // MARK: View menu

    /// The main menu's View items: one per sidebar view on ⌘1–⌘8, Back and Forward on ⌘[ and ⌘], and Refresh on ⌘R.
    func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        let sidebar = Sidebar()
        for view in sidebar.views {
            let item = NSMenuItem(title: view.title, action: #selector(selectView(_:)), keyEquivalent: "")
            if let number = sidebar.shortcut(for: view) { item.keyEquivalent = String(number) }
            item.representedObject = view.rawValue
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let back = NSMenuItem(title: NavigationHistory.backTitle, action: #selector(goBack(_:)), keyEquivalent: "[")
        back.target = self
        menu.addItem(back)
        let forward = NSMenuItem(title: NavigationHistory.forwardTitle, action: #selector(goForward(_:)), keyEquivalent: "]")
        forward.target = self
        menu.addItem(forward)
        menu.addItem(.separator())
        let find = NSMenuItem(title: "Search Tickets", action: #selector(searchTickets(_:)), keyEquivalent: "f")
        find.target = self
        menu.addItem(find)
        let inspector = NSMenuItem(title: "Show Inspector", action: #selector(toggleInspector(_:)), keyEquivalent: "i")
        inspector.keyEquivalentModifierMask = [.command, .option]
        inspector.target = self
        menu.addItem(inspector)
        let force = NSMenuItem(title: DispatchControl.forceTitle, action: #selector(forceTicket(_:)), keyEquivalent: "F")
        force.keyEquivalentModifierMask = [.command, .shift]
        force.target = self
        menu.addItem(force)
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refresh(_:)), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        return menu
    }

    @objc private func selectView(_ sender: NSMenuItem) {
        guard let view = (sender.representedObject as? String).flatMap(SymphonyView.init(rawValue:)) else { return }
        model?.show(view)
    }

    @objc private func refresh(_ sender: Any?) {
        if let model { model.refresh() } else { client.refresh() }
    }

    @objc private func searchTickets(_ sender: Any?) {
        model?.searchTickets()
    }

    @objc private func toggleInspector(_ sender: Any?) {
        model?.toggleInspector()
    }

    @objc private func forceTicket(_ sender: Any?) {
        model?.openForceSheet()
    }

    @objc private func goBack(_ sender: Any?) {
        model?.goBack()
    }

    @objc private func goForward(_ sender: Any?) {
        model?.goForward()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard window?.isKeyWindow == true else { return false }
        switch menuItem.action {
        case #selector(goBack(_:)): return model?.canGoBack ?? false
        case #selector(goForward(_:)): return model?.history.canGoForward ?? false
        case #selector(toggleInspector(_:)):
            menuItem.title = model?.inspectorTitle ?? "Show Inspector"
            return model?.hasInspector ?? false
        case #selector(forceTicket(_:)): return model?.dispatchControl.canForce ?? false
        case #selector(searchTickets(_:)):
            menuItem.title = model?.searchTitle ?? "Search Tickets"
            return true
        default: return true
        }
    }

    // MARK: NSWindowDelegate

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        client.isVisible = window.occlusionState.contains(.visible)
    }

    func windowDidMove(_ notification: Notification) {
        window?.saveFrame(to: frame, after: notification)
    }

    func windowDidResize(_ notification: Notification) {
        window?.saveFrame(to: frame, after: notification)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        window?.saveFrame(to: frame, after: notification)
    }

    func windowWillClose(_ notification: Notification) {
        window?.saveFrame(to: frame, after: notification)
        window = nil
        model = nil
        client.isVisible = false
        showDockBadge()
        NSApp.setActivationPolicy(.accessory)
    }
}
