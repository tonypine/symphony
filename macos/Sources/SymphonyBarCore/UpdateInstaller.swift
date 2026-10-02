import CryptoKit
import Foundation
import Security

/// Why an update was refused. Each message completes "Symphony wasn't updated: …".
public enum UpdateError: Error, Equatable, LocalizedError {
    case noAssets
    case unsigned
    case noPublicKey
    case download(String)
    case checksumUnreadable
    case checksumMismatch(expected: String, actual: String)
    case signature(MinisignError)
    case unzip(String)
    case appMissing
    case wrongApp(String)
    case notNewer(build: Int, current: Int)
    case codeSignature(String)
    /// The running app is signed ad hoc, so there is no signer to compare the update's with.
    case runningAppUnsigned
    case signerMismatch
    case helper(String)

    public var errorDescription: String? {
        switch self {
        case .noAssets:
            return "the release has no app to download."
        case .unsigned:
            return "the release has no minisign signature, so it can't be verified."
        case .noPublicKey:
            return "this build has no update signing key, so the download can't be verified."
        case let .download(name):
            return "couldn't download \(name)."
        case .checksumUnreadable:
            return "the SHA-256 file couldn't be read."
        case let .checksumMismatch(expected, actual):
            return "the download's SHA-256 is \(actual), not \(expected) as published. It may have been tampered with."
        case let .signature(error):
            return "the minisign check failed: \(error.localizedDescription). The download may have been tampered with."
        case let .unzip(output):
            return "couldn't unzip the download: \(output)"
        case .appMissing:
            return "the download holds no Symphony.app with an embedded Symphony."
        case let .wrongApp(identifier):
            return "the download is \(identifier), not Symphony."
        case let .notNewer(build, current):
            return "the download is build \(build), not newer than the running build \(current)."
        case let .codeSignature(output):
            return "the new app's code signature isn't valid: \(output)"
        case .runningAppUnsigned:
            return "this Symphony is signed ad hoc, so the update's signer can't be checked. Install the release by hand."
        case .signerMismatch:
            return "the new app isn't signed with the same certificate as this one."
        case let .helper(reason):
            return "couldn't start the update helper: \(reason)"
        }
    }
}

/// Downloads a URL to a file; `URLSessionUpdateDownloader` in the app, a stub in tests.
public protocol UpdateDownloader {
    func download(_ url: URL, to destination: URL) async throws
}

public struct URLSessionUpdateDownloader: UpdateDownloader {
    /// Seconds a stalled download may go without data.
    public static let timeout: TimeInterval = 120

    private let session: URLSession
    private let userAgent: String

    public init(userAgent: String = "Symphony-macOS") {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = Self.timeout
        session = URLSession(configuration: configuration)
        self.userAgent = userAgent
    }

    public func download(_ url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (file, response) = try await session.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw URLError(.badServerResponse)
        }
        try FileManager.default.moveItem(at: file, to: destination)
    }
}

/// Checks code signatures; `SystemCodeSignatureChecker` in the app, a stub in tests.
public protocol CodeSignatureChecker {
    /// Throws `UpdateError.codeSignature` unless `codesign --verify --strict` accepts the app.
    func verify(appAt url: URL) throws
    /// The SHA-256 of the app's leaf signing certificate, nil when it is signed ad hoc.
    func leafCertificateHash(appAt url: URL) throws -> Data?
}

public struct SystemCodeSignatureChecker: CodeSignatureChecker {
    public init() {}

    public func verify(appAt url: URL) throws {
        let (status, output) = UpdateTool.run("/usr/bin/codesign", ["--verify", "--strict", url.path])
        guard status == 0 else { throw UpdateError.codeSignature(output.isEmpty ? "codesign exited with \(status)" : output) }
    }

    public func leafCertificateHash(appAt url: URL) throws -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.codeSignature("couldn't read the signature of \(url.lastPathComponent)")
        }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
            let information = information as? [String: Any]
        else { throw UpdateError.codeSignature("couldn't read the signer of \(url.lastPathComponent)") }
        guard let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate],
            let leaf = certificates.first
        else { return nil }
        return Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
    }
}

/// A downloaded and verified app, ready to replace the running one.
public struct PreparedUpdate: Equatable {
    public var release: Release
    /// The new Symphony.app, in the cache folder.
    public var appURL: URL
    /// Its embedded Symphony, used to check symphony.yml before the swap.
    public var symphonyBinary: String

    public init(release: Release, appURL: URL, symphonyBinary: String) {
        self.release = release
        self.appURL = appURL
        self.symphonyBinary = symphonyBinary
    }
}

/// Downloads a release and checks it: SHA-256, minisign signature, `codesign --verify --strict`, and the same
/// signing certificate as the running app.
public final class UpdateInstaller {
    /// Subfolder of the cache folder where releases are downloaded and unzipped.
    public static let stagingFolder = "updates"

    private let downloader: UpdateDownloader
    private let signatures: CodeSignatureChecker
    private let publicKey: MinisignPublicKey?
    private let runningApp: URL
    private let currentBuild: Int
    private let bundleIdentifier: String
    private let cacheDirectory: URL
    private let fileManager = FileManager.default

    public init(
        downloader: UpdateDownloader = URLSessionUpdateDownloader(),
        signatures: CodeSignatureChecker = SystemCodeSignatureChecker(),
        publicKey: MinisignPublicKey?,
        runningApp: URL,
        currentBuild: Int,
        bundleIdentifier: String,
        cacheDirectory: URL
    ) {
        self.downloader = downloader
        self.signatures = signatures
        self.publicKey = publicKey
        self.runningApp = runningApp
        self.currentBuild = currentBuild
        self.bundleIdentifier = bundleIdentifier
        self.cacheDirectory = cacheDirectory
    }

    /// `~/Library/Caches/<bundle identifier>`.
    public static func defaultCacheDirectory(bundleIdentifier: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    public var stagingDirectory: URL { cacheDirectory.appendingPathComponent(Self.stagingFolder, isDirectory: true) }

    /// Removes downloaded releases.
    public func removeStaging() {
        try? fileManager.removeItem(at: stagingDirectory)
    }

    /// Downloads `release` into a fresh staging folder and verifies it. Throws an `UpdateError` on any mismatch.
    public func prepare(_ release: Release) async throws -> PreparedUpdate {
        guard let assets = release.assets else { throw UpdateError.noAssets }
        guard let signatureURL = assets.signature else { throw UpdateError.unsigned }
        guard let publicKey else { throw UpdateError.noPublicKey }

        removeStaging()
        let folder = stagingDirectory.appendingPathComponent(release.version, isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw UpdateError.download("\(assets.zipName): \(error.localizedDescription)")
        }

        let zip = folder.appendingPathComponent(assets.zipName)
        let checksum = folder.appendingPathComponent("\(assets.zipName).sha256")
        let signature = folder.appendingPathComponent("\(assets.zipName).minisig")
        for (url, file) in [(assets.zip, zip), (assets.checksum, checksum), (signatureURL, signature)] {
            do {
                try await downloader.download(url, to: file)
            } catch {
                throw UpdateError.download(file.lastPathComponent)
            }
        }

        guard let zipData = try? Data(contentsOf: zip, options: .alwaysMapped) else {
            throw UpdateError.download(assets.zipName)
        }
        try Self.verifyChecksum(zipData, checksumFile: (try? String(contentsOf: checksum, encoding: .utf8)) ?? "")
        try Self.verifySignature(
            zipData,
            signatureFile: (try? String(contentsOf: signature, encoding: .utf8)) ?? "",
            publicKey: publicKey
        )

        let unzipped = folder.appendingPathComponent("app", isDirectory: true)
        let (status, output) = UpdateTool.run("/usr/bin/ditto", ["-x", "-k", zip.path, unzipped.path])
        guard status == 0 else { throw UpdateError.unzip(output.isEmpty ? "ditto exited with \(status)" : output) }

        let app = try findApp(in: unzipped)
        let binary = app.appendingPathComponent("Contents/Resources/\(EmbeddedSymphony.resourceName)")
        guard fileManager.isExecutableFile(atPath: binary.path) else { throw UpdateError.appMissing }
        try checkInfo(of: app)

        try signatures.verify(appAt: app)
        try Self.checkSigner(
            running: try signatures.leafCertificateHash(appAt: runningApp),
            candidate: try signatures.leafCertificateHash(appAt: app)
        )
        return PreparedUpdate(release: release, appURL: app, symphonyBinary: binary.path)
    }

    /// Throws unless the first word of a `shasum -a 256` line is the SHA-256 of `data`.
    public static func verifyChecksum(_ data: Data, checksumFile: String) throws {
        let expected = checksumFile.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
        guard expected.count == 64, expected.allSatisfy(\.isHexDigit) else { throw UpdateError.checksumUnreadable }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw UpdateError.checksumMismatch(expected: expected, actual: actual) }
    }

    /// Throws unless `signatureFile` is a minisign signature of `data` by `publicKey`.
    public static func verifySignature(_ data: Data, signatureFile: String, publicKey: MinisignPublicKey) throws {
        do {
            try Minisign.verify(data, signature: try MinisignSignature(signatureFile), publicKey: publicKey)
        } catch let error as MinisignError {
            throw UpdateError.signature(error)
        }
    }

    /// Throws unless both apps are signed with the same certificate; an ad hoc signature matches nothing.
    public static func checkSigner(running: Data?, candidate: Data?) throws {
        guard let running else { throw UpdateError.runningAppUnsigned }
        guard candidate == running else { throw UpdateError.signerMismatch }
    }

    private func findApp(in folder: URL) throws -> URL {
        let apps = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".app") }
            .sorted()
        guard let name = apps.contains("Symphony.app") ? "Symphony.app" : apps.first else { throw UpdateError.appMissing }
        return folder.appendingPathComponent(name, isDirectory: true)
    }

    /// The new app must be this app, and newer, so an older signed release can't be swapped in.
    private func checkInfo(of app: URL) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw UpdateError.appMissing }
        let identifier = info["CFBundleIdentifier"] as? String ?? ""
        guard identifier == bundleIdentifier else { throw UpdateError.wrongApp(identifier.isEmpty ? "an unnamed app" : identifier) }
        let build = AppBuild(infoDictionary: info, hasEmbeddedSymphony: true).build
        guard build > currentBuild else { throw UpdateError.notNewer(build: build, current: currentBuild) }
    }
}

/// Runs a command-line tool to completion and returns its exit status and trimmed output.
enum UpdateTool {
    static func run(_ executable: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingWhitespace())
    }
}
