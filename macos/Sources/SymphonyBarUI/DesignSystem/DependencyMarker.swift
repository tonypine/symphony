import SwiftUI
import SymphonyBarCore

// The dependency marker (TP-1645, `.q-after` in `docs/design/prototypes/home-queue/page.css`): in a queue row's trail, in
// quiet text, an arrow and the identifier of the ticket it waits for ("→ TP-976"), and for one that needs a release the
// word after it ("→ TP-1590 released"). A dependency that is met has no marker.

/// What a dependency marker says: the ticket waited for, and whether it waits for it to be done or released.
public struct DependencyMarkerModel: Equatable, Identifiable {
    public enum Kind: String, CaseIterable, Equatable {
        case done, released
    }

    public var identifier: String
    public var kind: Kind

    public var id: String { identifier }

    public init(identifier: String, kind: Kind = .done) {
        self.identifier = identifier
        self.kind = kind
    }

    /// The words after the arrow: "TP-976", "TP-1590 released".
    public var text: String { kind == .released ? "\(identifier) released" : identifier }

    /// The tooltip: "Starts when TP-976 is done".
    public var help: String { "Starts when \(identifier) is \(kind.rawValue)" }

    /// What VoiceOver says: "waits for TP-976", "waits for TP-1590 to be released".
    public var accessibilityLabel: String {
        kind == .released ? "waits for \(identifier) to be released" : "waits for \(identifier)"
    }
}

public struct DependencyMarker: View {
    let marker: DependencyMarkerModel

    public init(_ marker: DependencyMarkerModel) {
        self.marker = marker
    }

    public var body: some View {
        let queue = DesignTokens.HomeQueue.self
        HStack(spacing: DesignTokens.Space.s1) {
            Image(systemName: queue.afterSymbol)
                .font(DesignTokens.TypeStyle.font(size: queue.afterGlyph, weight: DesignTokens.TypeStyle.label.weight))
            Text(marker.text).textStyle(.secondary).monospacedDigit().lineLimit(1)
        }
        .foregroundStyle(DesignTokens.TextColor.tertiary.color)
        .fixedSize()
        .help(marker.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(marker.accessibilityLabel)
    }
}
