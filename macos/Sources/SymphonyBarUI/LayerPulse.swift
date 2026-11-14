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

    /// What pulses: the shape's opacity or its scale about its centre, there and back; or a ring sent out from it.
    enum Motion: Equatable {
        case opacity(from: Double, to: Double)
        case scale(from: Double, to: Double)
        /// The status dot's live ring (TP-1506): over the first `reach` of each period it grows from the shape to
        /// `scale` times it while it fades from `opacity` to clear, then waits for the next period.
        case ring(scale: Double, opacity: Double, reach: Double)
        /// A CSS keyframe breath (`@keyframes { 50% { opacity: to } }`): over one period the opacity goes from full
        /// to `to` and back, each half on the cubic curve `curve` (its four control values), as a browser draws it.
        /// An autoreversed animation would run the curve backwards on the way up, which a keyframe animation doesn't.
        case breathe(to: Double, curve: [Double])
    }

    let shape: Shape
    let color: Color
    let motion: Motion
    /// One way, in seconds; it runs back as long. A ring's and a keyed breath's whole period.
    let duration: Double

    func makeNSView(context: Context) -> LayerPulseView {
        LayerPulseView()
    }

    func updateNSView(_ view: LayerPulseView, context: Context) {
        view.configure(self)
    }

    /// The animation the layer runs, forever: there and back for a breath, once per period for a ring.
    static func animation(_ motion: Motion, duration: Double) -> CAAnimation {
        switch motion {
        case let .opacity(from, to): breath("opacity", from: from, to: to, duration: duration)
        case let .scale(from, to): breath("transform.scale", from: from, to: to, duration: duration)
        case let .ring(scale, opacity, reach): ring(scale: scale, opacity: opacity, reach: reach, period: duration)
        case let .breathe(to, curve): breathe(to: to, curve: curve, period: duration)
        }
    }

    static func breathe(to: Double, curve: [Double], period: Double) -> CAKeyframeAnimation {
        let half = CAMediaTimingFunction(controlPoints: Float(curve[0]), Float(curve[1]), Float(curve[2]), Float(curve[3]))
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        let values: [Double] = [1, to, 1]
        animation.values = values
        animation.keyTimes = [0, 0.5, 1]
        animation.timingFunctions = [half, half]
        animation.duration = period
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }

    static func breath(_ keyPath: String, from: Double, to: Double, duration: Double) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = false
        return animation
    }

    static func ring(scale: Double, opacity: Double, reach: Double, period: Double) -> CAAnimationGroup {
        func track(_ keyPath: String, _ values: [Double]) -> CAKeyframeAnimation {
            let track = CAKeyframeAnimation(keyPath: keyPath)
            track.values = values
            track.keyTimes = [0, NSNumber(value: reach), 1]
            track.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear)]
            track.duration = period
            return track
        }
        let group = CAAnimationGroup()
        group.animations = [track("transform.scale", [1, scale, scale]), track("opacity", [opacity, 0, 0])]
        group.duration = period
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        return group
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
