import AppKit
import SwiftUI

// The working marks' breathing (the live dot's halo, the live step's bar), drawn by Core Animation instead of a
// SwiftUI animation (TP-1466). A `repeatForever` SwiftUI animation, or a symbol effect, updates the view graph on every
// frame, and each update makes the hosting view lay its whole content out again: on the ticket page of a working run
// that kept the main thread busy forever, so accessibility reads timed out and the keys went unanswered while the page
// looked fine. A layer's animation runs in the render server and lays nothing out.

/// A shape that breathes: a circle or a capsule filling its frame in `color`, its opacity or its scale going between
/// `from` and `to` and back. It draws nothing SwiftUI must lay out again, and assistive apps skip it.
public struct Breathing: View {
    public enum Change: Equatable {
        /// The shape grows and shrinks about its centre, from `from` to `to` times its frame.
        case scale
        /// The shape fades, from `from` to `to` opacity.
        case opacity
    }

    let color: Color
    let change: Change
    let from: Double
    let to: Double
    let duration: Double

    public init(color: Color, change: Change, from: Double, to: Double, duration: Double) {
        self.color = color
        self.change = change
        self.from = from
        self.to = to
        self.duration = duration
    }

    public var body: some View {
        BreathingRepresentable(look: BreathingLook(color: NSColor(color), change: change, from: from, to: to, duration: duration))
            .accessibilityHidden(true)
    }
}

/// What the layer draws and how it moves.
struct BreathingLook: Equatable {
    var color: NSColor
    var change: Breathing.Change
    var from: Double
    var to: Double
    var duration: Double
}

private struct BreathingRepresentable: NSViewRepresentable {
    let look: BreathingLook

    func makeNSView(context: Context) -> BreathingView {
        BreathingView(look: look)
    }

    func updateNSView(_ view: BreathingView, context: Context) {
        view.look = look
    }
}

/// The layer-backed view under `Breathing`: one shape layer the size of the view, its animation added again whenever
/// the layer lost it (a view taken out of its window and put back loses its layer's animations).
final class BreathingView: NSView {
    /// The key of the shape's animation.
    static let animationKey = "breathing"

    let shape = CALayer()

    var look: BreathingLook {
        didSet {
            guard look != oldValue else { return }
            shape.removeAnimation(forKey: Self.animationKey)
            needsDisplay = true
            breathe()
        }
    }

    init(look: BreathingLook) {
        self.look = look
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
        // The halo grows past the dot's frame.
        clipsToBounds = false
        layer?.masksToBounds = false
        layer?.addSublayer(shape)
        needsDisplay = true
        breathe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    override var isFlipped: Bool { true }

    /// The colour resolved in the view's appearance, so a dynamic colour follows light and dark.
    override func updateLayer() {
        var color = look.color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = self.look.color.cgColor }
        shape.backgroundColor = color
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        breathe()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Adds the shape's animation unless it has it: the property's resting value is `from`, so the shape still looks
    /// right between a lost animation and the next.
    func breathe() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch look.change {
        case .scale:
            shape.opacity = 1
            shape.transform = CATransform3DMakeScale(look.from, look.from, 1)
        case .opacity:
            shape.opacity = Float(look.from)
            shape.transform = CATransform3DIdentity
        }
        CATransaction.commit()
        guard shape.animation(forKey: Self.animationKey) == nil else { return }
        let animation = CABasicAnimation(keyPath: look.change == .scale ? "transform.scale" : "opacity")
        animation.fromValue = look.from
        animation.toValue = look.to
        animation.duration = look.duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = false
        shape.add(animation, forKey: Self.animationKey)
    }
}
