import Foundation

/// Where a Linear link opens: in the Linear desktop app when one is installed, so Open in Linear doesn't start
/// the browser just to hand the link on to the app.
public enum LinearLink {
    /// The scheme the Linear desktop app registers. It takes the web link's path: `linear://<workspace>/issue/<ID>`.
    public static let desktopScheme = "linear"

    /// Host of Linear's web app. Other hosts (`api.linear.app`, `uploads.linear.app`) are not pages the app opens.
    static let webHost = "linear.app"

    /// The desktop app's link for a Linear web link, with its path, query and fragment; nil for any other URL.
    public static func desktopURL(for url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.host?.lowercased() == webHost
        else { return nil }
        var link = desktopScheme + "://" + components.percentEncodedPath.drop(while: { $0 == "/" })
        if let query = components.percentEncodedQuery { link += "?" + query }
        if let fragment = components.percentEncodedFragment { link += "#" + fragment }
        return URL(string: link)
    }

    /// The URL to open for `url`: the desktop app's link when `url` is a Linear web link and an app handles it,
    /// else `url` itself.
    public static func target(for url: URL, desktopAppHandles: (URL) -> Bool) -> URL {
        guard let desktop = desktopURL(for: url), desktopAppHandles(desktop) else { return url }
        return desktop
    }
}
