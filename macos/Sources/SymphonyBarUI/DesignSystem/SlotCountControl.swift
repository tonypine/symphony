import SwiftUI
import SymphonyBarCore

// The Home queue's slot count control (TP-1608, `.slots-ctl` in `docs/design/prototypes/home-queue/page.css`): how many
// slots the factory runs, from 1 to 6, beside the In progress title. A capsule on the content surface with a strong
// ring: minus, "3 slots", plus. A button at its end of the range is off and faded. VoiceOver reads it as one
// adjustable element: "Slots, 3 slots", and Up and Down step it.

public struct SlotCountControl: View {
    @Binding var count: Int

    public init(count: Binding<Int>) {
        _count = count
    }

    /// The values the control takes.
    public static let range = DesignTokens.HomeQueue.slots

    /// "3 slots".
    public var word: String { DesignTokens.HomeQueue.slotsWord(count) }

    /// Whether a step of `step` from `count` moves it: never past 1 or 6.
    public static func canStep(_ count: Int, by step: Int) -> Bool {
        DesignTokens.HomeQueue.slots(count, step: step) != count
    }

    /// Moves the count by `step`, kept inside the range.
    public func step(_ step: Int) {
        count = DesignTokens.HomeQueue.slots(count, step: step)
    }

    public var body: some View {
        let queue = DesignTokens.HomeQueue.self
        HStack(spacing: 0) {
            stepButton("minus", help: "Fewer slots", step: -1)
            Text(word)
                .textStyle(.label)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(DesignTokens.TextColor.primary.color)
                .frame(minWidth: queue.countValueWidth)
            stepButton("plus", help: "More slots", step: 1)
        }
        .padding(.horizontal, queue.countInset)
        .frame(height: DesignTokens.Control.small.height)
        .background(DesignTokens.Surface.content.color, in: Capsule())
        .overlay(Capsule().strokeBorder(DesignTokens.Surface.strong.color))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Slots")
        .accessibilityValue(word)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
    }

    private func stepButton(_ symbol: String, help: String, step: Int) -> some View {
        let on = Self.canStep(count, by: step)
        return Button { self.step(step) } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(SlotCountButtonStyle(on: on))
        .disabled(!on)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A step of the slot count: the glyph in the secondary colour; under the pointer primary on the hover surface; faded
/// when off.
private struct SlotCountButtonStyle: ButtonStyle {
    let on: Bool

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, on: on)
    }

    private struct Face: View {
        let configuration: Configuration
        let on: Bool
        @State private var hovered = false

        var body: some View {
            let queue = DesignTokens.HomeQueue.self
            let lit = on && (hovered || configuration.isPressed)
            configuration.label
                .font(DesignTokens.TypeStyle.font(size: queue.countGlyph, weight: DesignTokens.TypeStyle.label.weight))
                .foregroundStyle((lit ? DesignTokens.TextColor.primary : DesignTokens.TextColor.secondary).color)
                .frame(width: queue.countButtonWidth, height: queue.countButtonHeight)
                .background {
                    if lit {
                        Capsule().fill((configuration.isPressed ? DesignTokens.StateSurface.pressed : DesignTokens.StateSurface.hover).fill)
                    }
                }
                .opacity(on ? 1 : queue.countOffOpacity)
                .contentShape(Capsule())
                .onHover { hovered = $0 }
                .buttonPointer(enabled: on)
        }
    }
}
