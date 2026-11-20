import CoreGraphics
import Foundation

/// The image viewer's state and rules: the set of images it was opened on, which one is current, and how far it is
/// zoomed. Pure: it holds no image, no view and no window, so every rule is tested without them.
///
/// A zoom is how many screen pixels one image pixel takes: 1 is the image at its actual size, 0.5 half of it. Zooming
/// starts fitted to the viewport, and any move to another image goes back to fitted.
public struct ImageViewerModel: Equatable {
    /// How the current image is scaled.
    public enum Zoom: Equatable {
        /// As large as the viewport holds it whole, never past its actual size.
        case fitted
        case fixed(Double)
    }

    /// The zoom steps the buttons and keys walk through, smallest first: 25, 33, 50, 67, 100, 150, 200, 300 and 400 %.
    public static let zoomSteps: [Double] = [0.25, 0.33, 0.5, 0.67, 1, 1.5, 2, 3, 4]
    public static var largestZoom: Double { zoomSteps[zoomSteps.count - 1] }
    /// Two zooms closer than this are the same one.
    static let sameZoomTolerance = 0.0005

    public let images: [TicketScreenshot]
    public private(set) var currentIndex: Int
    public private(set) var zoom: Zoom = .fitted

    /// A viewer on `images`, current on `currentIndex` (kept inside the set).
    public init(images: [TicketScreenshot], currentIndex: Int = 0) {
        self.images = images
        self.currentIndex = images.isEmpty ? 0 : min(max(currentIndex, 0), images.count - 1)
    }

    /// A viewer on `images`, current on `image`, or on the first when it is not among them.
    public init(images: [TicketScreenshot], current image: TicketScreenshot) {
        self.init(images: images, currentIndex: images.firstIndex(of: image) ?? 0)
    }

    /// A viewer with `zoom` already set, for the gallery's zoomed-in variation.
    public init(images: [TicketScreenshot], currentIndex: Int = 0, zoom: Zoom) {
        self.init(images: images, currentIndex: currentIndex)
        self.zoom = zoom
    }

    // MARK: - The set

    public var currentImage: TicketScreenshot? { images.indices.contains(currentIndex) ? images[currentIndex] : nil }

    /// More than one image: the buttons, the counter and the filmstrip show only then.
    public var isSet: Bool { images.count > 1 }

    /// "2 of 5".
    public var counterText: String { "\(currentIndex + 1) of \(images.count)" }

    public var canGoToPrevious: Bool { currentIndex > 0 }
    public var canGoToNext: Bool { currentIndex < images.count - 1 }

    public mutating func goToPrevious() { select(currentIndex - 1) }
    public mutating func goToNext() { select(currentIndex + 1) }

    /// Makes `index` current, when it is in the set and not the current one; the zoom goes back to fitted.
    public mutating func select(_ index: Int) {
        guard images.indices.contains(index), index != currentIndex else { return }
        currentIndex = index
        zoom = .fitted
    }

    // MARK: - Zoom

    /// The zoom that holds the whole image in the viewport, both in points, on a display of `scaleFactor` pixels to
    /// the point; an image smaller than the viewport is not enlarged.
    public static func fittedZoom(imagePixels: CGSize, viewport: CGSize, scaleFactor: Double) -> Double {
        guard imagePixels.width > 0, imagePixels.height > 0, viewport.width > 0, viewport.height > 0, scaleFactor > 0 else { return 1 }
        let widthZoom = Double(viewport.width) * scaleFactor / Double(imagePixels.width)
        let heightZoom = Double(viewport.height) * scaleFactor / Double(imagePixels.height)
        return min(widthZoom, heightZoom, 1)
    }

    /// The zoom now: the fitted one, or the one set.
    public func effectiveZoom(fitted: Double) -> Double {
        switch zoom {
        case .fitted: fitted
        case let .fixed(value): Self.clamp(value, fitted: fitted)
        }
    }

    /// The smallest zoom allowed: the lowest step, or the fitted zoom when the image needs less to fit.
    public static func smallestZoom(fitted: Double) -> Double { min(zoomSteps[0], fitted) }

    public static func clamp(_ value: Double, fitted: Double) -> Double {
        min(max(value, smallestZoom(fitted: fitted)), largestZoom)
    }

    public func canZoomIn(fitted: Double) -> Bool { effectiveZoom(fitted: fitted) < Self.largestZoom - Self.sameZoomTolerance }

    public func canZoomOut(fitted: Double) -> Bool {
        effectiveZoom(fitted: fitted) > Self.smallestZoom(fitted: fitted) + Self.sameZoomTolerance
    }

    /// The next step above the zoom now, or the largest.
    public mutating func zoomIn(fitted: Double) {
        let now = effectiveZoom(fitted: fitted)
        zoom = .fixed(Self.zoomSteps.first { $0 > now + Self.sameZoomTolerance } ?? Self.largestZoom)
    }

    /// The next step below the zoom now, or the smallest.
    public mutating func zoomOut(fitted: Double) {
        let now = effectiveZoom(fitted: fitted)
        zoom = .fixed(Self.zoomSteps.last { $0 < now - Self.sameZoomTolerance } ?? Self.smallestZoom(fitted: fitted))
    }

    /// Any zoom, such as a pinch's or a scroll wheel's, kept between the smallest and the largest.
    public mutating func setZoom(_ value: Double, fitted: Double) {
        zoom = .fixed(Self.clamp(value, fitted: fitted))
    }

    public mutating func fit() { zoom = .fitted }

    /// One image pixel on one screen pixel: 100 %.
    public mutating func showActualSize() { zoom = .fixed(1) }

    /// Double-click: fitted goes to actual size, anything else goes back to fitted.
    public mutating func toggleFittedAndActualSize() {
        if zoom == .fitted {
            showActualSize()
        } else {
            fit()
        }
    }

    /// The size the image takes on screen, in points: its pixels at the zoom, over the display's scale factor.
    public static func displaySize(imagePixels: CGSize, zoom: Double, scaleFactor: Double) -> CGSize {
        guard scaleFactor > 0 else { return .zero }
        return CGSize(width: imagePixels.width * zoom / scaleFactor, height: imagePixels.height * zoom / scaleFactor)
    }

    // MARK: - Words

    /// "62 %".
    public static func percentText(_ zoom: Double) -> String { "\(Int((zoom * 100).rounded())) %" }

    /// "2800 × 1800".
    public static func pixelSizeText(_ pixels: CGSize) -> String { "\(Int(pixels.width)) × \(Int(pixels.height))" }

    /// The name Save… offers: the label, without the characters a file name cannot hold.
    public static func suggestedFileName(label: String) -> String {
        let name = label.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Screenshot" : name
    }
}
