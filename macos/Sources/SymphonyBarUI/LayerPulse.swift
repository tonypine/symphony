import AppKit
import SwiftUI

/// A capsule or a circle that pulses on Core Animation's render server (TP-1480): the working step's bar and the
/// working dot's halo on the window's ticket page. A SwiftUI `repeatForever` animation updates the view graph on every
/// frame, and the hosting view lays the whole page out again each time: an untouched page with one running run kept
/// the main thread about 21 % busy. This layer animates without the main thread once it starts.
///
/// It draws only in a window; a snapshot (`ImageRenderer`) draws the shape still instead (`liveDurations` off).
struct LayerPulse: NSViewRepresentable, Equatable {
    enum Shape: Equatable {
        case capsule
        case circle
    }

    /// What pulses: the shape's opacity, or its scale about its centre.
    enum Motion: Equatable {
        case opacity(from: Double, to: Double)
        case scale(from: Double, to: Double)

        var keyPath: String {
            switch self {
            case .opacity: "opacity"
            case .scale: "transform.scale"
            }
        }

        var values: (from: Double, to: Double) {
            switch self {
            case let .opacity(from, to), let .scale(from, to): (from, to)
            }
        }
    }

    let shape: Shape
    let color: Color
    let motion: Motion
    /// One way, in seconds; it runs back as long.
    let duration: Double

    func makeNSView(context: Context) -> LayerPulseView {
        LayerPulseView()
    }

    func updateNSView(_ view: LayerPulseView, context: Context) {
        view.configure(self)
    }

    /// The animation the layer runs, forever, there and back.
    static func animation(_ motion: Motion, duration: Double) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: motion.keyPath)
        animation.fromValue = motion.values.from
        animation.toValue = motion.values.to
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = false
        return animation
    }
}

/// The view under `LayerPulse`: one sublayer centred in its bounds, so a scale grows about the centre.
final class LayerPulseView: NSView {
    static let animationKey = "pulse"
    let shapeLayer = CALayer()
    private(set) var pulse: LayerPulse?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(shapeLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var wantsUpdateLayer: Bool { true }

    /// The colour, resolved in the view's appearance: it follows light and dark.
    override func updateLayer() {
        guard let pulse else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            shapeLayer.backgroundColor = NSColor(pulse.color).cgColor
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        shapeLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        shapeLayer.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.commit()
    }

    /// Clicks go to the view under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A layer leaving the window may drop its animations: it starts again when it comes back.
        if window != nil { startIfNeeded(restart: false) }
    }

    func configure(_ pulse: LayerPulse) {
        let restart = self.pulse.map { $0.motion != pulse.motion || $0.duration != pulse.duration } ?? false
        self.pulse = pulse
        needsDisplay = true
        needsLayout = true
        startIfNeeded(restart: restart)
    }

    private func startIfNeeded(restart: Bool) {
        guard let pulse else { return }
        if restart { shapeLayer.removeAnimation(forKey: Self.animationKey) }
        guard shapeLayer.animation(forKey: Self.animationKey) == nil else { return }
        shapeLayer.add(LayerPulse.animation(pulse.motion, duration: pulse.duration), forKey: Self.animationKey)
    }
}
