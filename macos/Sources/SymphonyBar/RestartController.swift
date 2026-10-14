import Foundation
import SymphonyBarCore

/// Carries out a graceful restart: feeds `RestartMachine` its events and performs the effects it asks for.
@MainActor
final class RestartController {
    /// Called after every change, so the menu follows.
    var onChange: (() -> Void)?

    private(set) var machine = RestartMachine()
    private let runner: SymphonyRunner
    private let poller: StatusPoller
    /// Called once when an update's drain ends: `stopped` is true when Symphony stopped for the swap, and
    /// `pausedByUpdate` when the drain paused dispatch.
    private var updateFinished: ((_ stopped: Bool, _ pausedByUpdate: Bool) -> Void)?

    init(runner: SymphonyRunner, poller: StatusPoller) {
        self.runner = runner
        self.poller = poller
    }

    /// Restarts the app's Symphony. `alreadyPaused` is whether dispatch is paused now, so a pause the user made
    /// survives.
    func restart(alreadyPaused: Bool) {
        perform(
            machine.begin(
                alreadyPaused: alreadyPaused,
                runsTimeout: TimeInterval(runner.restartTimeoutMinutes * 60),
                logPath: runner.logPath
            )
        )
    }

    /// Drains Symphony for an update like a restart, but stops it instead of starting it again. symphony.yml is
    /// checked with the running Symphony, not the new one: see `RestartMachine`. `finished` is called once the
    /// drain stops Symphony or ends early. `kind` decides how it waits for agent runs: see `UpdateKind`. Its pause
    /// names `version`, the version it installs.
    func drainForUpdate(
        alreadyPaused: Bool,
        kind: UpdateKind,
        version: String,
        finished: @escaping (_ stopped: Bool, _ pausedByUpdate: Bool) -> Void
    ) {
        guard !machine.isRestarting else { return }
        updateFinished = finished
        perform(
            machine.begin(
                alreadyPaused: alreadyPaused,
                purpose: kind.drainPurpose,
                updatingTo: version,
                runsTimeout: kind.runsTimeout(restartTimeout: TimeInterval(runner.restartTimeoutMinutes * 60)),
                logPath: runner.logPath,
                alerts: !kind.isAutomatic
            )
        )
    }

    func handle(_ event: RestartMachine.Event) {
        guard machine.isRestarting else { return }
        perform(machine.handle(event))
    }

    private func perform(_ effects: [RestartMachine.Effect]) {
        onChange?()
        for effect in effects {
            switch effect {
            case .checkConfig:
                checkConfig()
            case let .send(action):
                let stateRoot = runner.stateRoot
                Task {
                    let result = await AppStores.current.sendControl(action, stateRoot: stateRoot)
                    handle(.controlFinished(action, result))
                    poller.pollNow()
                }
            case .pollNow:
                poller.pollNow()
            case .stop:
                // The exit comes back through `handle(.exited)`.
                runner.stop()
            case .start:
                runner.start { [weak self] error in
                    self?.handle(.startFinished(error: error?.localizedDescription))
                }
            case let .alert(title, message):
                // Shown after this turn, so the restart's state is settled before the modal alert runs.
                DispatchQueue.main.async { SymphonyRunner.showAlert(title: title, body: message) }
            case .stopped:
                break
            }
        }
        if !machine.isRestarting, let finished = updateFinished {
            updateFinished = nil
            finished(effects.contains(.stopped), machine.pausedByRestart)
        }
    }

    private func checkConfig() {
        runner.checkLaunch { [weak self] launch in
            switch launch {
            case let .success(launch):
                let log = ConfigCheck.qaLog(AppStores.current.qaMode)
                Task { self?.handle(.configChecked(await ConfigCheck.run(launch, log: log))) }
            case let .failure(error):
                self?.handle(.configChecked(.failed(error.localizedDescription)))
            }
        }
    }
}
