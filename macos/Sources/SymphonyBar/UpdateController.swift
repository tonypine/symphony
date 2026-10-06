import AppKit
import SymphonyBarCore

/// Installs an update: downloads and verifies the release, then hands over to the update helper, which swaps the
/// app once it quits and relaunches it. The app drains and stops Symphony between the two.
@MainActor
final class UpdateController {
    /// Called after every change, so the menu follows.
    var onChange: (() -> Void)?

    /// The release being downloaded and verified.
    private(set) var preparing: Release?
    /// The verified update, while Symphony drains before the swap.
    private(set) var prepared: PreparedUpdate?
    /// Why the last update failed, shown in the menu until the next one.
    private(set) var error: String?
    /// True while the update under way was started by the app itself: its failures show in the menu only.
    private var automatic = false
    /// What the last update's health check did, such as a rollback that failed, shown in the menu until the next
    /// update.
    var notice: String? {
        didSet { onChange?() }
    }
    /// The rollback that put this build back, shown in the menu until the next update.
    var rolledBack: RollbackRecord? {
        didSet { onChange?() }
    }

    let pending = PendingUpdateStore(defaults: AppStores.current.defaults)
    /// The builds Skip This Version recorded, which the menu shows as skipped rather than available.
    let skips = SkippedReleaseStore(defaults: AppStores.current.defaults)
    /// What a rollback records for the build it puts back.
    let rollbacks = RollbackStore(defaults: AppStores.current.defaults)
    /// The update that passed its health check, for the menu line that says what changed.
    let lastUpdates = LastUpdateStore(defaults: AppStores.current.defaults)
    let cacheDirectory: URL
    private let current: AppBuild
    private let publicKey: MinisignPublicKey?
    private let installer: UpdateInstaller
    private let app = Bundle.main.bundleURL

    init(current: AppBuild) {
        self.current = current
        let identifier = Bundle.main.bundleIdentifier ?? "com.tonypine.symphony.bar"
        cacheDirectory = AppStores.current.updateCacheDirectory
            ?? UpdateInstaller.defaultCacheDirectory(bundleIdentifier: identifier)
        publicKey = (Bundle.main.object(forInfoDictionaryKey: UpdateHelper.publicKeyInfoKey) as? String)
            .flatMap { try? MinisignPublicKey($0) }
        installer = UpdateInstaller(
            publicKey: publicKey,
            runningApp: app,
            currentBuild: current.build,
            bundleIdentifier: identifier,
            cacheDirectory: cacheDirectory
        )
    }

    var isUpdating: Bool { preparing != nil || prepared != nil }

    /// The line under the update items: progress while downloading, why the last update failed, or what its health
    /// check did.
    var menuLine: String? {
        preparing.map(UpdateMenu.preparingLine) ?? error ?? notice
    }

    /// The helper's log, with `~` for the home folder.
    var helperLogPath: String {
        (cacheDirectory.appendingPathComponent(UpdateHelper.logName).path as NSString).abbreviatingWithTildeInPath
    }

    /// The helper's log for a rollback, with `~` for the home folder.
    var rollbackLogPath: String {
        (cacheDirectory.appendingPathComponent(UpdateHelper.rollbackLogName).path as NSString)
            .abbreviatingWithTildeInPath
    }

    /// Why Update is off, nil when it is available.
    func blocker(developmentMode: Bool) -> String? {
        let files = FileManager.default
        let writable = files.isWritableFile(atPath: app.deletingLastPathComponent().path) && files.isWritableFile(atPath: app.path)
        return UpdateEligibility.blocker(
            build: current,
            developmentMode: developmentMode,
            hasPublicKey: publicKey != nil,
            appLocationWritable: writable
        )
    }

    /// Downloads and verifies `release`, then calls `ready` with it. A failure is shown in the menu, and in an alert
    /// unless the update is `automatic`.
    func prepare(_ release: Release, automatic: Bool = false, ready: @escaping (PreparedUpdate) -> Void) {
        guard !isUpdating else { return }
        error = nil
        notice = nil
        rolledBack = nil
        self.automatic = automatic
        preparing = release
        onChange?()
        Task {
            do {
                let update = try await installer.prepare(release)
                preparing = nil
                prepared = update
                onChange?()
                ready(update)
            } catch {
                preparing = nil
                fail(error.localizedDescription)
            }
        }
    }

    /// The drain didn't stop Symphony, so the update is called off; the restart machine said why.
    func cancel() {
        prepared = nil
        automatic = false
        installer.removeStaging()
        onChange?()
    }

    /// Calls the update off, saying why in the menu, and in an alert unless the update is automatic.
    func fail(_ reason: String) {
        prepared = nil
        installer.removeStaging()
        error = "\(UpdateMenu.failedTitle): \(reason)"
        onChange?()
        guard !automatic else {
            automatic = false
            return
        }
        let body = reason.prefix(1).uppercased() + reason.dropFirst()
        // Shown after this turn, so the menu is settled before the modal alert runs.
        DispatchQueue.main.async { SymphonyRunner.showAlert(title: UpdateMenu.failedTitle, body: body) }
    }

    /// Records what the relaunched app must do and starts the helper, which waits for this app to quit. The caller
    /// quits next. Throws an `UpdateError` when the helper can't start; nothing is recorded then.
    func handOff(_ update: PreparedUpdate, symphonyStopped: Bool, resumeDispatch: Bool) throws {
        let files = FileManager.default
        guard let bundled = Bundle.main.url(forResource: UpdateHelper.resourceName, withExtension: nil) else {
            throw UpdateError.helper("\(UpdateHelper.resourceName) is missing from the app")
        }
        // Run a copy, so moving the app doesn't move the script from under the helper.
        let script = cacheDirectory.appendingPathComponent(UpdateHelper.resourceName)
        let log = cacheDirectory.appendingPathComponent(UpdateHelper.logName)
        do {
            try? files.removeItem(at: script)
            try? files.removeItem(at: log)
            try files.copyItem(at: bundled, to: script)
        } catch {
            throw UpdateError.helper(error.localizedDescription)
        }

        pending.save(
            PendingUpdate(
                fromBuild: current.build,
                toBuild: update.release.build,
                version: update.release.version,
                startSymphony: symphonyStopped,
                resumeDispatch: resumeDispatch,
                details: ReleaseDetails(update.release),
                automatic: automatic
            )
        )
        let launch = ChildLaunch(
            executable: "/bin/sh",
            arguments: UpdateHelper.arguments(
                script: script,
                pid: ProcessInfo.processInfo.processIdentifier,
                currentApp: app,
                newApp: update.appURL
            ),
            workingDirectory: cacheDirectory.path,
            environment: AppStores.current.updateHelperEnvironment
        )
        do {
            try ChildProcess.spawnDetached(launch, logURL: log)
        } catch {
            pending.clear()
            throw UpdateError.helper(error.localizedDescription)
        }
    }

    /// The file number of this app's bundle, which tells a failed rollback swap from a reinstall of the failed build.
    var bundleFileNumber: Int? {
        RollbackRecord.bundleFileNumber(app)
    }

    /// True when `Symphony (previous).app` is next to the app, so a rollback has something to put back.
    var hasPreviousApp: Bool {
        FileManager.default.fileExists(atPath: UpdateHelper.previousAppURL(for: app).path)
    }

    /// Pins the build that failed its health check, so it isn't installed by itself again.
    func pin(_ record: RollbackRecord) {
        skips.record(SkippedRelease(build: record.build, version: record.version, reason: .rolledBack))
    }

    /// Puts `Symphony (previous).app` back after this build failed its health check: pins this build, records
    /// `record` for the restored app, and starts the helper, which swaps the apps once this app quits and relaunches
    /// the previous one. The caller stops Symphony first and quits next. Returns why it couldn't, nil when the helper
    /// started; the pin stays either way.
    func rollBack(_ record: RollbackRecord) -> RollbackProblem? {
        pin(record)
        guard hasPreviousApp else { return .noPreviousApp }
        let files = FileManager.default
        guard let bundled = Bundle.main.url(forResource: UpdateHelper.resourceName, withExtension: nil) else {
            return .helper("\(UpdateHelper.resourceName) is missing from the app")
        }
        let script = cacheDirectory.appendingPathComponent(UpdateHelper.resourceName)
        let log = cacheDirectory.appendingPathComponent(UpdateHelper.rollbackLogName)
        do {
            try files.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? files.removeItem(at: script)
            try? files.removeItem(at: log)
            try files.copyItem(at: bundled, to: script)
        } catch {
            return .helper(error.localizedDescription)
        }

        rollbacks.save(record)
        let launch = ChildLaunch(
            executable: "/bin/sh",
            arguments: UpdateHelper.rollbackArguments(
                script: script,
                pid: ProcessInfo.processInfo.processIdentifier,
                currentApp: app
            ),
            workingDirectory: cacheDirectory.path,
            environment: AppStores.current.updateHelperEnvironment
        )
        do {
            try ChildProcess.spawnDetached(launch, logURL: log)
        } catch {
            rollbacks.clear()
            return .helper(error.localizedDescription)
        }
        return nil
    }

    /// Removes what the last update downloaded, once the relaunched app runs.
    func removeDownloads() {
        installer.removeStaging()
    }
}
