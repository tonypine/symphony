import Foundation

/// Sends an HTTP request; `URLSessionUpdateTransport` in the app, a stub in tests.
public protocol UpdateTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Sends update checks with a session that keeps no HTTP cache, so `ETag` handling stays with `UpdateChecker`.
public struct URLSessionUpdateTransport: UpdateTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// The running app's build, compared with a release's `version.json` `build`.
public struct AppBuild: Equatable {
    /// `CFBundleVersion`, 0 when it is missing or not a number.
    public var build: Int
    /// True for a build without the embedded Symphony binary, such as a local `make` build.
    public var isDevelopment: Bool

    public init(build: Int, isDevelopment: Bool) {
        self.build = build
        self.isDevelopment = isDevelopment
    }

    /// Reads the build from an Info.plist dictionary; releases embed Symphony at `Contents/Resources/symphony`.
    public init(infoDictionary: [String: Any]?, hasEmbeddedSymphony: Bool) {
        let version = (infoDictionary?["CFBundleVersion"] as? String)?.trimmingWhitespace()
        self.init(build: version.flatMap { Int($0) } ?? 0, isDevelopment: !hasEmbeddedSymphony)
    }
}

/// A published release whose assets the app can update from.
public struct Release: Equatable {
    /// For example `0.0.1.42`.
    public var version: String
    public var build: Int
    /// The release body, as written by `scripts/release/package.sh`.
    public var notes: String
    public var pageURL: URL
    /// Number of changes since the previous release, when known.
    public var changes: Int?

    public init(version: String, build: Int, notes: String, pageURL: URL, changes: Int?) {
        self.version = version
        self.build = build
        self.notes = notes
        self.pageURL = pageURL
        self.changes = changes
    }
}

/// The outcome of one update check.
public enum UpdateCheckResult: Equatable {
    /// The latest release is newer than the running build.
    case available(Release)
    /// The running build is the latest release, or newer.
    case upToDate(Release)
    /// The check failed; the message says why, for a check started by hand.
    case failed(String)
}

/// Checks GitHub for the latest Symphony release. Unauthenticated, with `If-None-Match` so an unchanged
/// release costs no rate limit.
public final class UpdateChecker {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/tonypine/symphony/releases/latest")!
    /// How often the app checks in the background.
    public static let interval: TimeInterval = 6 * 60 * 60
    public static let timeout: TimeInterval = 30
    /// Name of the release asset that holds the version and build.
    public static let versionAsset = "version.json"

    private let transport: UpdateTransport
    private let url: URL
    private let userAgent: String
    /// The last release response's `ETag` and the release it described, reused on 304 Not Modified.
    private var cached: (etag: String, release: Release)?

    public init(
        transport: UpdateTransport = URLSessionUpdateTransport(),
        url: URL = UpdateChecker.latestReleaseURL,
        userAgent: String = "Symphony-macOS"
    ) {
        self.transport = transport
        self.url = url
        self.userAgent = userAgent
    }

    /// Fetches the latest release and compares its build with `current`.
    public func check(current: AppBuild) async -> UpdateCheckResult {
        switch await latestRelease() {
        case let .success(release):
            return release.build > current.build ? .available(release) : .upToDate(release)
        case let .failure(failure):
            return .failed(failure.message)
        }
    }

    /// The request for the latest release, with the last `ETag` when there is one.
    public func releaseRequest() -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let etag = cached?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        return request
    }

    private func latestRelease() async -> Result<Release, CheckFailure> {
        guard let (data, response) = try? await transport.send(releaseRequest()) else {
            return .failure(.init("couldn't reach GitHub"))
        }
        switch response.statusCode {
        case 200:
            break
        case 304:
            if let release = cached?.release { return .success(release) }
            return .failure(.init("GitHub answered 304 Not Modified to a first request"))
        case 403, 429:
            return .failure(.init("GitHub's rate limit is reached; try again later"))
        case 404:
            return .failure(.init("no Symphony release is published yet"))
        default:
            return .failure(.init("GitHub answered with HTTP \(response.statusCode)"))
        }

        guard let payload = try? JSONDecoder().decode(ReleasePayload.self, from: data),
            let pageURL = URL(string: payload.htmlUrl)
        else { return .failure(.init("GitHub's latest release couldn't be read")) }
        let assets = Dictionary(payload.assets.map { ($0.name, $0.browserDownloadUrl) }) { first, _ in first }
        let tag = payload.tagName

        guard let versionURL = assets[Self.versionAsset].flatMap(URL.init(string:)) else {
            return .failure(.init("the latest release (\(tag)) has no \(Self.versionAsset)"))
        }
        guard let (versionData, versionResponse) = try? await transport.send(assetRequest(versionURL)) else {
            return .failure(.init("couldn't download \(Self.versionAsset) for \(tag)"))
        }
        guard versionResponse.statusCode == 200,
            let info = try? JSONDecoder().decode(VersionInfo.self, from: versionData)
        else { return .failure(.init("\(Self.versionAsset) for \(tag) couldn't be read")) }
        guard let zip = info.zip, assets[zip] != nil, assets["\(zip).sha256"] != nil else {
            return .failure(.init("the latest release (\(tag)) has no app to download"))
        }

        let notes = payload.body ?? ""
        let release = Release(
            version: info.version,
            build: info.build,
            notes: notes,
            pageURL: pageURL,
            changes: Self.changeCount(notes: notes) ?? info.changes
        )
        if let etag = response.value(forHTTPHeaderField: "ETag") {
            cached = (etag, release)
        }
        return .success(release)
    }

    private func assetRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// The change count from the notes' first line, for example 12 from "12 changes since v0.0.1.41:".
    public static func changeCount(notes: String) -> Int? {
        let firstLine = notes.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let words = firstLine.trimmingWhitespace().split(separator: " ", maxSplits: 2)
        guard words.count >= 2, let count = Int(words[0]) else { return nil }
        let unit = words[1].trimmingCharacters(in: .punctuationCharacters)
        return unit == "change" || unit == "changes" ? count : nil
    }

    private struct CheckFailure: Error {
        let message: String

        init(_ reason: String) {
            message = "Couldn't check for updates: \(reason)"
        }
    }

    private struct ReleasePayload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadUrl = "browser_download_url"
            }
        }

        let tagName: String
        let htmlUrl: String
        let body: String?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case body
            case assets
        }
    }

    private struct VersionInfo: Decodable {
        let version: String
        let build: Int
        let zip: String?
        let changes: Int?
    }
}

/// Menu text for updates.
public enum UpdateMenu {
    public static let checkTitle = "Check for Updates…"
    public static let checkingTitle = "Checking for Updates…"
    public static let releaseNotesTitle = "Release Notes…"
    public static let openReleasePageTitle = "Open Release Page"

    /// For example "Update available: v0.0.1.42 (12 changes)", labelled for a development build.
    public static func availableTitle(_ release: Release, current: AppBuild) -> String {
        var title = "Update available: v\(release.version)"
        switch release.changes {
        case 1?:
            title += " (1 change)"
        case let count?:
            title += " (\(count) changes)"
        case nil:
            break
        }
        if current.isDevelopment { title += " · development build" }
        return title
    }

    /// The line under Check for Updates after a check started by hand, nil when there's none to show.
    public static func manualResultLine(_ result: UpdateCheckResult) -> String? {
        switch result {
        case .available:
            return nil
        case let .upToDate(release):
            return "Symphony is up to date (v\(release.version))"
        case let .failed(message):
            return message
        }
    }

    /// Title of the Release Notes window, for example "Symphony 0.0.1.42".
    public static func releaseNotesHeading(_ release: Release) -> String {
        "Symphony \(release.version)"
    }
}
