import CryptoKit
import XCTest
@testable import SymphonyBarCore

/// Serves downloads from files keyed by URL.
final class StubUpdateDownloader: UpdateDownloader {
    var files: [URL: Data] = [:]

    func download(_ url: URL, to destination: URL) async throws {
        guard let data = files[url] else { throw URLError(.fileDoesNotExist) }
        try data.write(to: destination)
    }
}

/// Answers code signature checks from canned values keyed by app folder name.
struct StubCodeSignatureChecker: CodeSignatureChecker {
    var verifyError: UpdateError?
    var leafHashes: [String: Data?] = [:]

    func verify(appAt url: URL) throws {
        if let verifyError { throw verifyError }
    }

    func leafCertificateHash(appAt url: URL) throws -> Data? {
        leafHashes[url.lastPathComponent] ?? nil
    }
}

final class UpdateInstallerTests: XCTestCase {
    private let download = "https://github.com/tonypine/symphony/releases/download/v0.0.1.43"
    private let identifier = "com.tonypine.symphony.bar"
    private let certificate = Data(SHA256.hash(data: Data("Symphony certificate".utf8)))
    private let signingKey = TestMinisignKey()
    private var root: URL!
    private var zip = Data()

    override func setUpWithError() throws {
        root = uniqueTemporaryDirectory("update-installer")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        zip = try makeZip()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var release: Release {
        Release(
            version: "0.0.1.43",
            build: 43,
            notes: "",
            pageURL: URL(string: "https://github.com/tonypine/symphony/releases/tag/v0.0.1.43")!,
            changes: 1,
            assets: ReleaseAssets(
                zipName: "Symphony-0.0.1.43.zip",
                zip: URL(string: "\(download)/Symphony-0.0.1.43.zip")!,
                checksum: URL(string: "\(download)/Symphony-0.0.1.43.zip.sha256")!,
                signature: URL(string: "\(download)/Symphony-0.0.1.43.zip.minisig")!
            )
        )
    }

    /// A zipped Symphony.app, made with `ditto` like `scripts/release/package.sh` does.
    private func makeZip(identifier: String? = nil, build: String = "43", embedded: Bool = true) throws -> Data {
        let source = root.appendingPathComponent("source-\(UUID().uuidString)/Symphony.app")
        let resources = source.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier ?? self.identifier, "CFBundleVersion": build]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: source.appendingPathComponent("Contents/Info.plist"))
        if embedded {
            let binary = resources.appendingPathComponent("symphony")
            try Data("#!/bin/sh\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        let output = root.appendingPathComponent("\(UUID().uuidString).zip")
        let (status, message) = UpdateTool.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", source.path, output.path])
        XCTAssertEqual(status, 0, message)
        return try Data(contentsOf: output)
    }

    private func checksumFile(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "  Symphony-0.0.1.43.zip\n"
    }

    /// Serves `zip` with its checksum and signature unless the caller replaces them.
    private func downloader(zip: Data? = nil, checksum: String? = nil, signature: String? = nil) throws -> StubUpdateDownloader {
        let zip = zip ?? self.zip
        let downloader = StubUpdateDownloader()
        downloader.files[release.assets!.zip] = zip
        downloader.files[release.assets!.checksum] = Data((checksum ?? checksumFile(zip)).utf8)
        downloader.files[release.assets!.signature!] = Data((try signature ?? signingKey.sign(zip)).utf8)
        return downloader
    }

    private func installer(
        downloader: StubUpdateDownloader,
        signatures: StubCodeSignatureChecker? = nil,
        publicKey: MinisignPublicKey?? = nil
    ) throws -> UpdateInstaller {
        UpdateInstaller(
            downloader: downloader,
            signatures: signatures ?? StubCodeSignatureChecker(leafHashes: ["Running.app": certificate, "Symphony.app": certificate]),
            publicKey: try publicKey ?? signingKey.publicKey(),
            runningApp: root.appendingPathComponent("Applications/Running.app"),
            currentBuild: 42,
            bundleIdentifier: identifier,
            cacheDirectory: root.appendingPathComponent("cache")
        )
    }

    private func assertRefused(
        _ installer: UpdateInstaller,
        release: Release? = nil,
        with expected: UpdateError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let prepared = try await installer.prepare(release ?? self.release)
            XCTFail("expected \(expected), prepared \(prepared)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? UpdateError, expected, file: file, line: line)
        }
    }

    func testPreparesAVerifiedUpdate() async throws {
        let installer = try installer(downloader: downloader())

        let prepared = try await installer.prepare(release)

        let staged = root.appendingPathComponent("cache/updates/0.0.1.43/app/Symphony.app")
        XCTAssertEqual(prepared.appURL.standardizedFileURL.path, staged.standardizedFileURL.path)
        XCTAssertEqual(prepared.symphonyBinary, prepared.appURL.appendingPathComponent("Contents/Resources/symphony").path)
        XCTAssertEqual(prepared.release, release)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: prepared.symphonyBinary))

        installer.removeStaging()
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.stagingDirectory.path))
    }

    func testChecksumMismatchIsRefused() async throws {
        let other = String(repeating: "0", count: 64)
        let installer = try installer(downloader: downloader(checksum: "\(other)  Symphony-0.0.1.43.zip\n"))

        let actual = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        await assertRefused(installer, with: .checksumMismatch(expected: other, actual: actual))
    }

    func testTamperedZipIsRefusedByItsChecksum() async throws {
        var tampered = zip
        tampered[tampered.count / 2] ^= 0xff
        let downloader = try downloader()
        downloader.files[release.assets!.zip] = tampered

        do {
            _ = try await installer(downloader: downloader).prepare(release)
            XCTFail("a tampered zip was accepted")
        } catch let UpdateError.checksumMismatch(expected, _) {
            XCTAssertEqual(checksumFile(zip).prefix(64), Substring(expected))
        }
    }

    func testUnreadableChecksumIsRefused() async throws {
        await assertRefused(try installer(downloader: downloader(checksum: "not a checksum")), with: .checksumUnreadable)
    }

    func testBadSignatureIsRefused() async throws {
        let signature = try signingKey.sign(Data("another zip".utf8))

        await assertRefused(try installer(downloader: downloader(signature: signature)), with: .signature(.badSignature))
    }

    func testWrongSignerIsRefused() async throws {
        let impostor = TestMinisignKey()
        let expected = try signingKey.publicKey().keyIDString
        let found = try impostor.publicKey().keyIDString

        await assertRefused(
            try installer(downloader: downloader(signature: impostor.sign(zip))),
            with: .signature(.wrongKey(expected: expected, found: found))
        )
    }

    func testMalformedSignatureIsRefused() async throws {
        await assertRefused(try installer(downloader: downloader(signature: "garbage")), with: .signature(.malformedSignature))
    }

    func testIdentityMismatchIsRefused() async throws {
        let other = Data(SHA256.hash(data: Data("another certificate".utf8)))
        let signatures = StubCodeSignatureChecker(leafHashes: ["Running.app": certificate, "Symphony.app": other])

        await assertRefused(try installer(downloader: downloader(), signatures: signatures), with: .signerMismatch)
    }

    func testAdHocUpdateIsRefused() async throws {
        let signatures = StubCodeSignatureChecker(leafHashes: ["Running.app": certificate])

        await assertRefused(try installer(downloader: downloader(), signatures: signatures), with: .signerMismatch)
    }

    func testAdHocRunningAppCantCheckTheSigner() async throws {
        let signatures = StubCodeSignatureChecker(leafHashes: ["Symphony.app": certificate])

        await assertRefused(try installer(downloader: downloader(), signatures: signatures), with: .runningAppUnsigned)
    }

    func testInvalidCodeSignatureIsRefused() async throws {
        let signatures = StubCodeSignatureChecker(verifyError: .codeSignature("a sealed resource is missing or invalid"))

        await assertRefused(
            try installer(downloader: downloader(), signatures: signatures),
            with: .codeSignature("a sealed resource is missing or invalid")
        )
    }

    func testOtherAppIsRefused() async throws {
        let other = try makeZip(identifier: "com.example.other")

        await assertRefused(try installer(downloader: downloader(zip: other)), with: .wrongApp("com.example.other"))
    }

    func testOlderBuildIsRefused() async throws {
        let older = try makeZip(build: "41")

        await assertRefused(try installer(downloader: downloader(zip: older)), with: .notNewer(build: 41, current: 42))
    }

    func testAppWithoutEmbeddedSymphonyIsRefused() async throws {
        let bare = try makeZip(embedded: false)

        await assertRefused(try installer(downloader: downloader(zip: bare)), with: .appMissing)
    }

    func testDownloadThatIsNotAZipIsRefused() async throws {
        let notZip = Data("not a zip".utf8)
        let installer = try installer(downloader: downloader(zip: notZip, signature: signingKey.sign(notZip)))

        do {
            _ = try await installer.prepare(release)
            XCTFail("a non-zip was accepted")
        } catch {
            guard case .unzip = error as? UpdateError else { return XCTFail("expected an unzip error, got \(error)") }
        }
    }

    func testFailedDownloadIsRefused() async throws {
        let downloader = try downloader()
        downloader.files[release.assets!.signature!] = nil

        await assertRefused(try installer(downloader: downloader), with: .download("Symphony-0.0.1.43.zip.minisig"))
    }

    func testUnsignedReleaseOrMissingKeyIsRefused() async throws {
        var unsigned = release
        unsigned.assets?.signature = nil
        await assertRefused(try installer(downloader: downloader()), release: unsigned, with: .unsigned)

        var bare = release
        bare.assets = nil
        await assertRefused(try installer(downloader: downloader()), release: bare, with: .noAssets)

        await assertRefused(try installer(downloader: downloader(), publicKey: .some(nil)), with: .noPublicKey)
    }

    func testSignerCheck() {
        XCTAssertNoThrow(try UpdateInstaller.checkSigner(running: certificate, candidate: certificate))
        XCTAssertThrowsError(try UpdateInstaller.checkSigner(running: certificate, candidate: Data([1]))) {
            XCTAssertEqual($0 as? UpdateError, .signerMismatch)
        }
        XCTAssertThrowsError(try UpdateInstaller.checkSigner(running: nil, candidate: nil)) {
            XCTAssertEqual($0 as? UpdateError, .runningAppUnsigned)
        }
    }

    func testErrorMessagesSayWhy() {
        XCTAssertEqual(
            UpdateError.checksumMismatch(expected: "aa", actual: "bb").localizedDescription,
            "the download's SHA-256 is bb, not aa as published. It may have been tampered with."
        )
        XCTAssertEqual(
            UpdateError.signature(.wrongKey(expected: "AA", found: "BB")).localizedDescription,
            "the minisign check failed: the signature is from key BB, not the Symphony key AA. The download may have been tampered with."
        )
        XCTAssertEqual(
            UpdateError.signerMismatch.localizedDescription,
            "the new app isn't signed with the same certificate as this one."
        )
    }

    func testDefaultCacheDirectoryIsUnderCaches() {
        let directory = UpdateInstaller.defaultCacheDirectory(bundleIdentifier: identifier)

        XCTAssertEqual(directory.lastPathComponent, identifier)
        XCTAssertEqual(directory.deletingLastPathComponent().lastPathComponent, "Caches")
    }
}
