import AppKit
import SwiftUI
import SymphonyBarCore

/// Shows an open menu (`MenuSession`, drawn by `MenuList`) on screen, as a menu behaves: in a borderless panel over
/// its window, under its control and moved in to stay on the screen, with the keys going to it while the window keeps
/// its focus. Up and Down move, Return picks, Escape closes, letters jump; a click outside the menu, the window losing
/// focus or the app going to the back closes it. The panel and its items exist only while the menu is open, so a page
/// of menu buttons builds no menu up front. VoiceOver reads the panel as a menu and each item as a menu item. A list
/// taller than the screen is cut to it and scrolls, so its first items stay reachable.
@MainActor
public final class MenuPresenter {
    /// The menu open now: one at a time.
    public private(set) static weak var current: MenuPresenter?

    let session: MenuSession
    private var panels: [ObjectIdentifier: MenuPanel] = [:]
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private weak var window: NSWindow?
    private let screen: CGRect
    private let minWidth: Double
    private var retained: MenuPresenter?

    /// Room around the list for its shadow, inside the panel.
    static let shadowRoom: CGFloat = 40

    /// Opens `items` from `view`'s control, lined up with its `alignment` edge, at least `minWidth` wide, with
    /// `highlighted` lit (a pop-up's current choice). `onClose` runs once when it closes, before a pick's move.
    /// Nil when the view is in no window.
    @discardableResult
    public static func open(
        _ items: [MenuItem], from view: NSView, alignment: MenuNavigation.Alignment = .leading,
        minWidth: Double = DesignTokens.Menu.minWidth, highlighted: Int? = nil, label: String, onClose: @escaping () -> Void
    ) -> MenuPresenter? {
        current?.session.close()
        guard let window = view.window, let screen = window.screen ?? NSScreen.main else { return nil }
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        let presenter = MenuPresenter(
            session: MenuSession(items: items, highlighted: highlighted), window: window, screen: screen.visibleFrame, minWidth: minWidth
        )
        presenter.show(anchor: anchor, alignment: alignment, label: label, onClose: onClose)
        return presenter
    }

    private init(session: MenuSession, window: NSWindow, screen: CGRect, minWidth: Double) {
        self.session = session
        self.window = window
        self.screen = screen
        self.minWidth = minWidth
    }

    private func show(anchor: CGRect, alignment: MenuNavigation.Alignment, label: String, onClose: @escaping () -> Void) {
        retained = self
        Self.current = self
        wire(session)
        session.onClose = { [weak self] in
            self?.tearDown()
            onClose()
        }
        let panel = makePanel(session, label: label)
        let frame = MenuNavigation.frame(size: panel.listSize, anchor: anchor, visible: screen, alignment: alignment)
        place(panel, list: frame)
        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            guard let self else { return event }
            nonisolated(unsafe) let pressed = event
            let passes: Bool = MainActor.assumeIsolated { self.passes(pressed) }
            return passes ? event : nil
        }
        let kinds: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        monitor = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: handler)
        let center = NotificationCenter.default
        let close: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.session.close() }
        }
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: close),
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main, using: close),
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: close),
        ]
        NSAccessibility.post(element: panel.host, notification: NSAccessibility.Notification(rawValue: "AXMenuOpened"))
        panel.host.announce(session.highlighted)
    }

    /// Hands the session's submenus and highlight to the panels.
    private func wire(_ session: MenuSession) {
        session.onSubmenu = { [weak self, weak session] child, index in
            guard let self, let session else { return }
            if let child {
                self.wire(child)
                self.showSubmenu(child, of: session, at: index)
            } else if let shown = self.panels.values.first(where: { $0.session.parent === session }) {
                self.remove(shown)
            }
        }
        session.onHighlight = { [weak self, weak session] index in
            guard let self, let session, let panel = self.panels[ObjectIdentifier(session)] else { return }
            panel.host.announce(index)
        }
    }

    private func makePanel(_ session: MenuSession, label: String) -> MenuPanel {
        let panel = MenuPanel(session: session, minWidth: minWidth, maxHeight: MenuNavigation.maxHeight(visible: screen), label: label)
        panels[ObjectIdentifier(session)] = panel
        return panel
    }

    private func place(_ panel: MenuPanel, list: CGRect) {
        panel.setFrame(list.insetBy(dx: -Self.shadowRoom, dy: -Self.shadowRoom), display: false)
        window?.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }

    private func showSubmenu(_ child: MenuSession, of session: MenuSession, at index: Int) {
        guard let parent = panels[ObjectIdentifier(session)] else { return }
        let list = parent.listFrame
        let top = MenuNavigation.tops(of: session.lines)[index] - parent.host.scrollOffset
        let item = CGRect(
            x: list.minX, y: list.maxY - top - DesignTokens.Menu.itemHeight, width: list.width, height: DesignTokens.Menu.itemHeight
        )
        let panel = makePanel(child, label: session.items[index].title)
        place(panel, list: MenuNavigation.submenuFrame(size: panel.listSize, item: item, visible: screen))
    }

    private func remove(_ panel: MenuPanel) {
        for other in panels.values where other.session.parent === panel.session { remove(other) }
        panels[ObjectIdentifier(panel.session)] = nil
        window?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func tearDown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        for panel in panels.values {
            window?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panels = [:]
        if Self.current === self { Self.current = nil }
        retained = nil
    }

    // MARK: - Events

    /// A key goes to the menu; a click inside it goes on to its item, one outside closes it and goes nowhere.
    /// True when the event goes on to the app.
    private func passes(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            if event.modifierFlags.contains(.command) {
                session.close()
                return true
            }
            guard let key = Self.key(event) else { return true }
            return !session.handle(key)
        case .scrollWheel:
            if !inside(NSEvent.mouseLocation) { session.close() }
            return true
        default:
            if inside(NSEvent.mouseLocation) { return true }
            session.close()
            return false
        }
    }

    private func inside(_ point: CGPoint) -> Bool {
        panels.values.contains { $0.listFrame.contains(point) }
    }

    /// The menu key a key press is, if any.
    static func key(_ event: NSEvent) -> MenuKey? {
        if let key = key(code: event.keyCode) { return key }
        guard let text = event.charactersIgnoringModifiers, let scalar = text.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar), scalar.value < 0xF700 else { return nil }
        return .text(text)
    }

    /// The arrows, Home, End, Page Up and Down, Return, Enter, Space and Escape.
    static func key(code: UInt16) -> MenuKey? {
        switch code {
        case 126: .up
        case 125: .down
        case 123: .left
        case 124: .right
        case 115, 116: .home
        case 119, 121: .end
        case 36, 76, 49: .pick
        case 53: .escape
        default: nil
        }
    }
}

/// The borderless panel an open menu is drawn in: over its window, never key, so the window keeps its focus.
final class MenuPanel: NSPanel {
    let session: MenuSession
    let host: MenuHostingView
    /// The list's size, without the room for its shadow.
    let listSize: CGSize

    @MainActor
    init(session: MenuSession, minWidth: Double, maxHeight: Double, label: String) {
        self.session = session
        let room = MenuPresenter.shadowRoom
        let relay = MenuScrollRelay()
        let list = MenuSessionList(session: session, minWidth: minWidth, maxHeight: maxHeight) { relay.host?.scroll(to: $0) }
        host = MenuHostingView(rootView: AnyView(list.padding(room)), session: session, label: label)
        relay.host = host
        let fitting = host.fittingSize
        listSize = CGSize(width: fitting.width - 2 * room, height: fitting.height - 2 * room)
        super.init(contentRect: CGRect(origin: .zero, size: fitting), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        animationBehavior = .none
        contentView = host
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a coder") }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The list's frame on screen, without the room for its shadow.
    var listFrame: CGRect { frame.insetBy(dx: MenuPresenter.shadowRoom, dy: MenuPresenter.shadowRoom) }
}

/// Hands a scrolling list's offset to its panel's view, made after the list.
@MainActor
final class MenuScrollRelay {
    weak var host: MenuHostingView?
}

/// The menu's view: a menu to VoiceOver, its items menu items that a press picks, and the first click on it counts.
final class MenuHostingView: NSHostingView<AnyView> {
    private weak var session: MenuSession?
    private var label = ""
    private lazy var elements: [MenuItemElement] = makeElements()
    /// How far a list cut to the screen is scrolled from its top.
    private(set) var scrollOffset: Double = 0

    @MainActor
    init(rootView: AnyView, session: MenuSession, label: String) {
        self.session = session
        self.label = label
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init(rootView _: AnyView) { fatalError("use init(rootView:session:label:)") }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a coder") }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .menu }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityChildren() -> [Any]? { elements }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        elements.first { NSPointInRect(point, $0.accessibilityFrame()) } ?? self
    }

    /// The list scrolled to `offset` from its top: the items' frames move with it.
    func scroll(to offset: Double) {
        scrollOffset = offset
        place(elements)
    }

    /// Tells VoiceOver which item is lit.
    func announce(_ index: Int?) {
        for element in elements { element.setAccessibilitySelected(element.index == index) }
        if let index, let element = elements.first(where: { $0.index == index }) {
            NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
        }
    }

    private func makeElements() -> [MenuItemElement] {
        guard let session else { return [] }
        let elements: [MenuItemElement] = session.items.enumerated().compactMap { index, item in
            guard !item.isSeparator else { return nil }
            let element = MenuItemElement(index: index) { [weak session] in session?.pick(index) }
            element.setAccessibilityRole(.menuItem)
            element.setAccessibilityLabel(item.accessibilityText)
            element.setAccessibilityEnabled(item.enabled)
            element.setAccessibilityParent(self)
            if let reason = item.disabledReason { element.setAccessibilityHelp(reason) }
            return element
        }
        place(elements)
        return elements
    }

    /// Each item's frame: its top in the list less how far the list is scrolled, so an item scrolled out of the list
    /// sits outside it.
    private func place(_ elements: [MenuItemElement]) {
        guard let session else { return }
        let menu = DesignTokens.Menu.self
        let room = MenuPresenter.shadowRoom
        let tops = MenuNavigation.tops(of: session.lines)
        for element in elements {
            let fromTop = room + tops[element.index] - scrollOffset
            let y = isFlipped ? fromTop : bounds.height - fromTop - menu.itemHeight
            element.setAccessibilityFrameInParentSpace(CGRect(
                x: room + menu.padding, y: y, width: max(bounds.width - 2 * (room + menu.padding), 0), height: menu.itemHeight
            ))
        }
    }
}

/// One item of an open menu as VoiceOver sees it: a press picks it.
final class MenuItemElement: NSAccessibilityElement {
    let index: Int
    private let press: () -> Void

    init(index: Int, press: @escaping () -> Void) {
        self.index = index
        self.press = press
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}

/// Keeps a control's AppKit view, so a menu opens from where the control is on screen.
final class MenuAnchorBox {
    weak var view: NSView?
}

/// What VoiceOver reads for a menu control, and what its press does.
struct MenuAnchorAccess {
    var role: NSAccessibility.Role
    var label: String
    var value: String?
    var help: String?
    var enabled: Bool
    var expanded: Bool
    var press: () -> Void
}

/// The control's place on screen, and the control to VoiceOver: a pop-up button or a menu button. Clicks pass
/// through it to the control's face.
final class MenuAnchorView: NSView {
    var access: MenuAnchorAccess?

    override func hitTest(_: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { access != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { access?.role }
    override func accessibilityLabel() -> String? { access?.label }
    override func accessibilityValue() -> Any? { access?.value }
    override func accessibilityHelp() -> String? { access?.help }
    override func isAccessibilityEnabled() -> Bool { access?.enabled ?? false }
    override func isAccessibilityExpanded() -> Bool { access?.expanded ?? false }

    override func accessibilityPerformPress() -> Bool {
        guard let access, access.enabled else { return false }
        access.press()
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool { accessibilityPerformPress() }
}

struct MenuAnchor: NSViewRepresentable {
    let box: MenuAnchorBox
    var access: MenuAnchorAccess?

    func makeNSView(context _: Context) -> MenuAnchorView {
        let view = MenuAnchorView()
        view.access = access
        box.view = view
        return view
    }

    func updateNSView(_ view: MenuAnchorView, context _: Context) {
        view.access = access
        box.view = view
    }
}
