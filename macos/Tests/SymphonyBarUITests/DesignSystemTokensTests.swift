import AppKit
import SwiftUI
import XCTest
@testable import SymphonyBarCore
@testable import SymphonyBarUI

/// The catalog's tokens as AppKit and SwiftUI draw them: a colour resolves to its value for the appearance, Increase
/// Contrast included; a text style is the catalog's size and weight; the measure is CSS's `ch`.
final class DesignSystemTokensTests: XCTestCase {
    func testAColourResolvesForEachAppearance() throws {
        let token = DesignTokens.ColorToken.surfaceWindow.values
        XCTAssertEqual(token.value(matching: .aqua), DesignTokens.RGBA(hex: 0xF2F2F6))
        XCTAssertEqual(token.value(matching: .darkAqua), DesignTokens.RGBA(hex: 0x121216))
        XCTAssertEqual(token.value(matching: .accessibilityHighContrastAqua), DesignTokens.RGBA(hex: 0xECECF2))
        XCTAssertEqual(token.value(matching: .accessibilityHighContrastDarkAqua), DesignTokens.RGBA(hex: 0x0A0A0D))
        for (name, expected) in [(NSAppearance.Name.aqua, token.standard.light), (.darkAqua, token.standard.dark)] {
            let appearance = try XCTUnwrap(NSAppearance(named: name), name.rawValue)
            XCTAssertEqual(token.value(for: appearance), expected, name.rawValue)
            var drawn: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                drawn = DesignTokens.ColorToken.surfaceWindow.nsColor.usingColorSpace(.sRGB)
            }
            let color = try XCTUnwrap(drawn)
            XCTAssertEqual(Int((color.redComponent * 255).rounded()), Int(expected.red), name.rawValue)
            XCTAssertEqual(Int((color.greenComponent * 255).rounded()), Int(expected.green), name.rawValue)
            XCTAssertEqual(Int((color.blueComponent * 255).rounded()), Int(expected.blue), name.rawValue)
        }
    }

    func testATokenIsOneColourWhereverItIsRead() {
        XCTAssertTrue(DesignTokens.ColorToken.accent.nsColor === DesignTokens.ColorToken.accent.nsColor)
        XCTAssertEqual(DesignTokens.ColorToken.accent.color, DesignTokens.ColorToken.accent.color)
        XCTAssertEqual(DesignTokens.StateSurface.selected.fill, DesignTokens.ColorToken.accentTint.color)
        XCTAssertEqual(DesignTokens.Status.done.badgeFill, DesignTokens.ColorToken.tintDone.color)
        XCTAssertEqual(DesignTokens.Status.done.text, DesignTokens.ColorToken.statusDoneText.color)
    }

    func testATextStyleIsTheCatalogsSizeAndWeight() {
        for style in DesignTokens.TypeStyle.allCases {
            let font = style.nsFont(scale: 1)
            XCTAssertEqual(Double(font.pointSize), style.size, "\(style)")
            XCTAssertEqual(font.isFixedPitch, style.family == .mono, "\(style)")
        }
        XCTAssertEqual(Double(DesignTokens.TypeStyle.body.nsFont(scale: 1.5).pointSize), 19.5)
        // At the system's own text size, the styles are the catalog's.
        XCTAssertEqual(DesignTokens.TypeStyle.textScale, Double(NSFont.preferredFont(forTextStyle: .body).pointSize) / 13)
        let heavier = DesignTokens.TypeStyle.title.nsFont(scale: 1)
        let lighter = DesignTokens.TypeStyle.body.nsFont(scale: 1)
        XCTAssertGreaterThan(Self.weight(of: heavier), Self.weight(of: lighter))
    }

    func testTheMeasureIsCharactersOfTheFontsZero() {
        let zero = ("0" as NSString).size(withAttributes: [.font: DesignTokens.TypeStyle.body.nsFont]).width
        XCTAssertEqual(DesignTokens.Measure.reading, 68 * Double(zero), accuracy: 1e-6)
        XCTAssertEqual(DesignTokens.Measure.width(52), 52 * Double(zero), accuracy: 1e-6)
        XCTAssertGreaterThan(DesignTokens.Measure.width(for: .reading), DesignTokens.Measure.reading)
    }

    private static func weight(of font: NSFont) -> Double {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
    }
}
