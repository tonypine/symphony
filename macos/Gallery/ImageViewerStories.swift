import AppKit
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

// The image viewer (`ImageViewerPage`): one image, a set of five on its second, an image zoomed in past the viewport, one
// Symphony no longer keeps, and a very long label. The images are drawn here, in code: a gallery has no server to read
// them from.

/// A picture of `size` pixels: a diagonal blend of two hues with a window drawn on it, so two of them are told apart at
/// a glance and its edges and corners show where a zoom cuts it.
private func galleryPicture(hue: Double, size: CGSize) -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return Data() }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let bounds = NSRect(origin: .zero, size: size)
    NSGradient(
        starting: NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1),
        ending: NSColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.55, alpha: 1)
    )?.draw(in: bounds, angle: 315)
    NSColor.white.withAlphaComponent(0.9).setFill()
    let inset = size.width * 0.08
    let window = NSRect(x: inset, y: inset, width: size.width - 2 * inset, height: size.height - 2 * inset)
    NSBezierPath(roundedRect: window, xRadius: size.width * 0.01, yRadius: size.width * 0.01).fill()
    NSColor.black.withAlphaComponent(0.12).setFill()
    NSBezierPath(rect: NSRect(x: window.minX, y: window.maxY - size.height * 0.1, width: window.width, height: size.height * 0.1)).fill()
    for row in 0..<5 {
        NSColor(hue: hue, saturation: 0.5, brightness: 0.7, alpha: 0.5).setFill()
        let y = window.maxY - size.height * (0.2 + 0.12 * Double(row))
        NSBezierPath(rect: NSRect(x: window.minX + size.width * 0.04, y: y, width: window.width * (0.8 - 0.1 * Double(row)), height: size.height * 0.05)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:]) ?? Data()
}

/// The images of a set of `count`, kept where the viewer reads them, and their screenshots; the one at `unavailableIndex`
/// is one Symphony no longer keeps.
@MainActor
private func imageViewerFixture(count: Int, labels: [String]? = nil, unavailableIndex: Int? = nil) -> (shots: [TicketScreenshot], images: ArtifactImages) {
    let images = ArtifactImages { _ in .unreachable }
    let sizes = [CGSize(width: 2800, height: 1800), CGSize(width: 1440, height: 900), CGSize(width: 1100, height: 1500), CGSize(width: 2000, height: 1000), CGSize(width: 800, height: 600)]
    let names = ["Run header at 1440", "Strip at 1440", "Verdict badge after refresh", "Timeline at 1040", "Facts rail"]
    let shots = (0..<count).map { index -> TicketScreenshot in
        let id = "image-viewer-\(index)"
        if index != unavailableIndex { images.keep(galleryPicture(hue: Double(index) * 0.17 + 0.55, size: sizes[index % sizes.count]), for: id) }
        return TicketScreenshot(id: id, label: labels?[index] ?? names[index % names.count], path: "api/v1/artifacts/\(id)", available: index != unavailableIndex)
    }
    return (shots, images)
}

@MainActor
private func imageViewerPage(_ fixture: (shots: [TicketScreenshot], images: ArtifactImages), current: Int = 0, zoom: ImageViewerModel.Zoom = .fitted) -> AnyView {
    AnyView(
        ImageViewerPage(
            model: ImageViewerModel(images: fixture.shots, currentIndex: current, zoom: zoom), images: fixture.images,
            size: CGSize(width: 1100, height: 700)
        )
    )
}

/// The screenshot row at `width`: wide, narrow enough to wrap, and narrow with thirteen so it shows the "+N" tile.
@MainActor
private func thumbnailRow(count: Int, width: CGFloat) -> AnyView {
    let fixture = imageViewerFixture(count: count)
    return AnyView(
        ScreenshotRow(shots: fixture.shots, width: width)
            .frame(width: width, alignment: .leading)
            .padding(DesignTokens.Space.s5)
            .background(DesignTokens.Surface.content.color)
            .environment(\.artifactImages, fixture.images)
    )
}

@MainActor
func thumbnailRowRenders(_ scheme: ColorScheme, suffix: String) {
    render(thumbnailRow(count: 5, width: 780), scheme, to: "thumbnail-row-wide-\(suffix).png")
    render(thumbnailRow(count: 5, width: 280), scheme, to: "thumbnail-row-wraps-\(suffix).png")
    render(thumbnailRow(count: 13, width: 280), scheme, to: "thumbnail-row-more-tile-\(suffix).png")
}

@MainActor
func imageViewerRenders(_ scheme: ColorScheme, suffix: String) {
    render(imageViewerPage(imageViewerFixture(count: 1)), scheme, to: "image-viewer-one-image-\(suffix).png")
    render(imageViewerPage(imageViewerFixture(count: 5), current: 1), scheme, to: "image-viewer-set-of-five-\(suffix).png")
    render(imageViewerPage(imageViewerFixture(count: 5), current: 0, zoom: .fixed(2)), scheme, to: "image-viewer-zoomed-in-\(suffix).png")
    render(imageViewerPage(imageViewerFixture(count: 3, unavailableIndex: 1), current: 1), scheme, to: "image-viewer-unavailable-\(suffix).png")
    let long = "Run header at 1440×900 after the refresh of the Lifecycle bar with the Conductor's segment drawn in the accent beside the Coding run"
    render(imageViewerPage(imageViewerFixture(count: 2, labels: [long, "Strip"])), scheme, to: "image-viewer-long-label-\(suffix).png")
}
