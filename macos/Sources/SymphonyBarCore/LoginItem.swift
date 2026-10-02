import ServiceManagement

/// Whether macOS opens the app at login, mirroring `SMAppService.Status`.
public enum LoginItemStatus: Equatable {
    case notRegistered
    case enabled
    /// Registered, but the user must allow it in System Settings → General → Login Items.
    case requiresApproval
    case notFound
}

/// The app's login item, so tests can swap out `SMAppService`.
public protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// The app itself as a login item, through `SMAppService.mainApp`.
public final class MainAppLoginItem: LoginItemService {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        case .notRegistered:
            return .notRegistered
        @unknown default:
            return .notRegistered
        }
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    /// Opens System Settings → General → Login Items.
    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Pure rules for the Launch at Login toggle.
public enum LoginItem {
    /// Title of the toggle in Settings.
    public static let toggleTitle = "Launch at Login"

    /// The toggle is on while the app is registered, including while macOS waits for the user to allow it.
    public static func isOn(_ status: LoginItemStatus) -> Bool {
        switch status {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        }
    }

    /// Text shown under the toggle, or nil when there is nothing to say.
    public static func note(_ status: LoginItemStatus) -> String? {
        guard status == .requiresApproval else { return nil }
        return "Allow Symphony in System Settings → General → Login Items to open it at login."
    }

    /// Registers or unregisters the app so the login item matches `on`. Does nothing when it already does.
    public static func apply(_ on: Bool, to service: LoginItemService) throws {
        guard on != isOn(service.status) else { return }
        if on {
            try service.register()
        } else {
            try service.unregister()
        }
    }
}
