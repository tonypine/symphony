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

    init(runner: SymphonyRunner, poller: StatusPoller) {
        self.runner = runner
        self.poller = poller
    }

    /// Restarts the app's Symphony. `alreadyPaused` is whether dispatch is paused now, so a pause the user made
    /// survives. The updater passes `symphonyBinary` to check and start a different Symphony binary.
    func restart(alreadyPaused: Bool, symphonyBinary: String? = nil) {
        perform(
            machine.begin(
                alreadyPaused: alreadyPaused,
                symphonyBinary: symphonyBinary,
                runsTimeout: TimeInterval(runner.restartTimeoutMinutes * 60),
                logPath: runner.logPath
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
            case let .checkConfig(symphonyBinary):
                checkConfig(symphonyBinary: symphonyBinary)
            case let .send(action):
                let stateRoot = runner.stateRoot
                Task {
                    let result = await ControlAPI.send(action, stateRoot: stateRoot)
                    handle(.controlFinished(action, result))
                    poller.pollNow()
                }
            case .pollNow:
                poller.pollNow()
            case .stop:
                // The exit comes back through `handle(.exited)`.
                runner.stop()
            case let .start(symphonyBinary):
                do {
                    try runner.start(symphonyBinary: symphonyBinary)
                    handle(.startFinished(error: nil))
                } catch {
                    handle(.startFinished(error: error.localizedDescription))
                }
            case let .alert(title, message):
                // Shown after this turn, so the restart's state is settled before the modal alert runs.
                DispatchQueue.main.async { SymphonyRunner.showAlert(title: title, body: message) }
            }
        }
    }

    private func checkConfig(symphonyBinary: String?) {
        let launch: ChildLaunch
        do {
            launch = try runner.checkLaunch(symphonyBinary: symphonyBinary)
        } catch {
            handle(.configChecked(.failed(error.localizedDescription)))
            return
        }
        Task {
            handle(.configChecked(await ConfigCheck.run(launch)))
        }
    }
}
