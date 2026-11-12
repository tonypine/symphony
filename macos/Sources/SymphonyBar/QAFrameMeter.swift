import AppKit
import QuartzCore
import SymphonyBarCore

/// QA mode only: counts the frames the main thread let through while a test scrolls (TP-1491's ticket page scroll
/// test). SIGUSR1 starts a display link on the main run loop, in every mode so a scroll's event tracking does not stop
/// it; SIGUSR2 stops it and writes what `FrameMeter` found to `frames.json` under the QA root. Outside QA mode the app
/// installs neither signal handler and runs no display link; in QA mode nothing ticks until a test sends SIGUSR1.
@MainActor
final class QAFrameMeter: NSObject {
    /// The meter while the app runs in QA mode, nil otherwise.
    static private(set) var shared: QAFrameMeter?

    private let file: URL
    private var sources: [DispatchSourceSignal] = []
    private var link: CADisplayLink?
    private var meter = FrameMeter()

    /// Installs the signal handlers when the app is in QA mode; outside it the app handles neither signal.
    static func startIfQAMode() {
        guard shared == nil, let qaMode = AppStores.current.qaMode else { return }
        let meter = QAFrameMeter(file: qaMode.framesFile)
        shared = meter
        meter.listen()
    }

    private init(file: URL) {
        self.file = file
    }

    private func listen() {
        for number in [SIGUSR1, SIGUSR2] {
            // The source replaces the signal's default action, which would end the app.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    if number == SIGUSR1 { self?.begin() } else { self?.end() }
                }
            }
            source.resume()
            sources.append(source)
        }
    }

    /// SIGUSR1: starts counting from nothing, and removes the last count so a test never reads a stale one.
    private func begin() {
        link?.invalidate()
        try? FileManager.default.removeItem(at: file)
        meter = FrameMeter()
        guard let screen = NSApp.windows.first(where: \.isVisible)?.screen ?? NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        meter.record(link.timestamp, frame: link.targetTimestamp - link.timestamp)
    }

    /// SIGUSR2: stops counting and writes the count.
    private func end() {
        link?.invalidate()
        link = nil
        guard let data = try? meter.json() else { return }
        try? data.write(to: file, options: .atomic)
    }
}
