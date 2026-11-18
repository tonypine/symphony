import AppKit
import SwiftUI
import SymphonyBarCore

// The catalog's window bar (`.win-bar`, `winToolbar` in `docs/design/catalog/stories.js`, TP-1496): the bar the
// Director draws at the top of the page column in place of the system toolbar.

/// What the window bar shows: the same controls on every page, only the breadcrumb and Work's switch following it.
public struct WindowBarControls: Equatable {
    public var sidebarShown: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var breadcrumb: WindowBreadcrumb
    /// What needs the Director: the Inbox's count, none hidden.
    public var inboxCount: Int
    /// The Inbox's drawer is open where the window is: its button shows on.
    public var inboxShown: Bool
    /// The hint Find a ticket shows while it is empty: ⌘F, or ⌥⌘F on a page whose own search ⌘F reaches (TP-1497).
    public var findShortcut: String

    public init(
        sidebarShown: Bool = true, canGoBack: Bool = false, canGoForward: Bool = false, breadcrumb: WindowBreadcrumb,
        inboxCount: Int = 0, inboxShown: Bool = false, findShortcut: String = WindowBarText.findShortcut
    ) {
        self.sidebarShown = sidebarShown
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.breadcrumb = breadcrumb
        self.inboxCount = inboxCount
        self.inboxShown = inboxShown
        self.findShortcut = findShortcut
    }
}

/// What the window bar's controls do.
public struct WindowBarActions {
    public var toggleSidebar: () -> Void
    public var goBack: () -> Void
    public var goForward: () -> Void
    /// A breadcrumb link: the place it names.
    public var go: (Crumb) -> Void
    /// Return in Find a ticket.
    public var find: () -> Void
    public var inbox: () -> Void
    public var refresh: () -> Void

    public init(
        toggleSidebar: @escaping () -> Void = {}, goBack: @escaping () -> Void = {}, goForward: @escaping () -> Void = {},
        go: @escaping (Crumb) -> Void = { _ in }, find: @escaping () -> Void = {}, inbox: @escaping () -> Void = {},
        refresh: @escaping () -> Void = {}
    ) {
        self.toggleSidebar = toggleSidebar
        self.goBack = goBack
        self.goForward = goForward
        self.go = go
        self.find = find
        self.inbox = inbox
        self.refresh = refresh
    }
}

/// The window's bar: 44 pt of glass over the top of the page, which scrolls under it, with a hairline under it. Left to
/// right: show or hide the sidebar; Back and Forward, off with nowhere to go; a hairline; the breadcrumb; Work's switch
/// when it is given; then at the right Find a ticket (the small search field, 232 pt), the Inbox with the count of what
/// needs the Director, and Refresh. The window drags by it, and a double-click on it does what one on a title bar does.
/// VoiceOver reads it as one group, "Toolbar", in that order, which is also the keyboard's.
public struct WindowBar<Switch: View, Results: View>: View {
    let controls: WindowBarControls
    let actions: WindowBarActions
    @Binding var findText: String
    var findFocus: FocusState<Bool>.Binding?
    var findRequest: Binding<Bool>?
    var findDrawnAs: DesignTokens.Field.State?
    var hoveredCrumb: Int?
    let workSwitch: Switch?
    let findResults: Results
    @Environment(\.offscreenSnapshot) private var offscreenSnapshot
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// A bar with Work's `workSwitch` after the breadcrumb, when given, and `findResults` under Find a ticket.
    /// `findDrawnAs` and `hoveredCrumb` draw the field and a link in a state, for the gallery.
    public init(
        _ controls: WindowBarControls, actions: WindowBarActions, findText: Binding<String>, findFocus: FocusState<Bool>.Binding? = nil,
        findRequest: Binding<Bool>? = nil, findDrawnAs: DesignTokens.Field.State? = nil, hoveredCrumb: Int? = nil,
        workSwitch: Switch?, @ViewBuilder findResults: () -> Results
    ) {
        self.controls = controls
        self.actions = actions
        _findText = findText
        self.findFocus = findFocus
        self.findRequest = findRequest
        self.findDrawnAs = findDrawnAs
        self.hoveredCrumb = hoveredCrumb
        self.workSwitch = workSwitch
        self.findResults = findResults()
    }

    public var body: some View {
        let bar = DesignTokens.WindowBar.self
        HStack(spacing: bar.gap) {
            IconButton(bar.sidebarSymbol, help: WindowBarText.sidebar(shown: controls.sidebarShown), size: bar.control, action: actions.toggleSidebar)
            HStack(spacing: bar.navGap) {
                IconButton(bar.backSymbol, help: WindowBarText.back, size: bar.control, action: actions.goBack)
                    .disabled(!controls.canGoBack)
                IconButton(bar.forwardSymbol, help: WindowBarText.forward, size: bar.control, action: actions.goForward)
                    .disabled(!controls.canGoForward)
            }
            HairlineDivider(.vertical, length: bar.separatorHeight)
                .padding(.horizontal, bar.separatorInset)
                .accessibilityHidden(true)
            Breadcrumb(controls.breadcrumb, hovered: hoveredCrumb, go: actions.go)
                .layoutPriority(1)
            if let workSwitch {
                workSwitch.padding(.leading, bar.switchLeading)
            }
            Spacer(minLength: 0)
            find
            inbox
            IconButton(bar.refreshSymbol, help: WindowBarText.refresh, size: bar.control, action: actions.refresh)
        }
        .padding(.leading, bar.leading(sidebarShown: controls.sidebarShown))
        .padding(.trailing, bar.trailingPadding)
        .frame(maxWidth: .infinity)
        .frame(height: bar.height)
        .background { background }
        .overlay(alignment: .bottom) { HairlineDivider().accessibilityHidden(true) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(WindowBarText.toolbarLabel)
    }

    /// Find a ticket, with what it found under it.
    private var find: some View {
        let bar = DesignTokens.WindowBar.self
        return SearchField(
            WindowBarText.findPlaceholder, text: $findText, shortcut: controls.findShortcut, size: .small,
            focused: findFocus, focusRequest: findRequest, drawnAs: findDrawnAs, onSubmit: actions.find
        )
        .frame(width: bar.searchWidth)
        .overlay(alignment: .topLeading) {
            findResults
                .frame(width: bar.searchWidth, alignment: .leading)
                .offset(y: DesignTokens.Control.small.height + bar.findGap)
        }
    }

    /// The Inbox's icon button, on while its drawer is open, with its count over the corner.
    private var inbox: some View {
        let bar = DesignTokens.WindowBar.self
        return IconButton(
            bar.inboxSymbol, help: WindowBarText.inbox(needYou: controls.inboxCount), size: bar.control,
            isOn: Binding(get: { controls.inboxShown }, set: { _ in actions.inbox() })
        )
        .overlay(alignment: .topTrailing) {
            CountBadge(controls.inboxCount, role: .you)
                .offset(x: -bar.countTrailing, y: bar.countTop)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// The glass, solid under Reduce Transparency and offscreen, which draws no material; and the area that drags
    /// the window.
    @ViewBuilder private var background: some View {
        let glass = DesignTokens.WindowBar.glass
        if offscreenSnapshot || reduceTransparency {
            Rectangle().fill(glass.solid.color)
        } else {
            Rectangle().fill(glass.fill.color)
                .background(.ultraThinMaterial)
                .overlay { WindowDragArea().accessibilityHidden(true) }
        }
    }
}

extension WindowBar where Switch == EmptyView {
    /// A bar without Work's switch.
    public init(
        _ controls: WindowBarControls, actions: WindowBarActions, findText: Binding<String>, findFocus: FocusState<Bool>.Binding? = nil,
        findRequest: Binding<Bool>? = nil, findDrawnAs: DesignTokens.Field.State? = nil, hoveredCrumb: Int? = nil,
        @ViewBuilder findResults: () -> Results
    ) {
        self.init(
            controls, actions: actions, findText: findText, findFocus: findFocus, findRequest: findRequest, findDrawnAs: findDrawnAs,
            hoveredCrumb: hoveredCrumb, workSwitch: nil, findResults: findResults
        )
    }
}

/// The bar's empty room as a title bar: a press drags the window, a double-click does what the system's setting says
/// a double-click on a title bar does (zoom, minimize or nothing).
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else {
                window.performDrag(with: event)
                return
            }
            switch TitleBarDoubleClick.action(preference: UserDefaults.standard.string(forKey: TitleBarDoubleClick.preferenceKey)) {
            case .zoom: window.zoom(nil)
            case .minimize: window.miniaturize(nil)
            case .nothing: break
            }
        }
    }
}
