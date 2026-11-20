import CoreGraphics
import XCTest
@testable import SymphonyBarCore

final class ImageViewerModelTests: XCTestCase {
    private func shot(_ id: String) -> TicketScreenshot {
        TicketScreenshot(id: id, label: id, path: "api/v1/artifacts/\(id)", available: true)
    }

    private func viewer(count: Int = 5, current: Int = 0) -> ImageViewerModel {
        ImageViewerModel(images: (1...count).map { shot("shot-\($0)") }, currentIndex: current)
    }

    // MARK: - The set

    func testItOpensOnTheImageItWasGivenWithItsSiblings() {
        let images = (1...5).map { shot("shot-\($0)") }
        let model = ImageViewerModel(images: images, current: images[1])
        XCTAssertEqual(model.currentIndex, 1)
        XCTAssertEqual(model.currentImage, images[1])
        XCTAssertEqual(model.images, images)
        XCTAssertEqual(model.counterText, "2 of 5")
        XCTAssertEqual(ImageViewerModel(images: images, current: shot("elsewhere")).currentIndex, 0)
    }

    func testTheStartIndexStaysInsideTheSet() {
        XCTAssertEqual(viewer(current: 9).currentIndex, 4)
        XCTAssertEqual(viewer(current: -3).currentIndex, 0)
        let empty = ImageViewerModel(images: [])
        XCTAssertNil(empty.currentImage)
        XCTAssertFalse(empty.canGoToNext)
        XCTAssertFalse(empty.canGoToPrevious)
    }

    func testASingleImageIsASetOfOneWithNowhereToGo() {
        let single = viewer(count: 1)
        XCTAssertFalse(single.isSet)
        XCTAssertFalse(single.canGoToPrevious)
        XCTAssertFalse(single.canGoToNext)
        XCTAssertTrue(viewer().isSet)
    }

    func testItMovesOneImageAtATimeAndStopsAtBothEnds() {
        var model = viewer(count: 3)
        XCTAssertFalse(model.canGoToPrevious)
        model.goToPrevious()
        XCTAssertEqual(model.currentIndex, 0)
        model.goToNext()
        model.goToNext()
        XCTAssertEqual(model.currentIndex, 2)
        XCTAssertFalse(model.canGoToNext)
        XCTAssertTrue(model.canGoToPrevious)
        model.goToNext()
        XCTAssertEqual(model.currentIndex, 2, "no wrap-around")
        model.goToPrevious()
        XCTAssertEqual(model.currentIndex, 1)
    }

    func testSelectingAnImageOutsideTheSetChangesNothing() {
        var model = viewer(count: 3, current: 1)
        model.select(3)
        model.select(-1)
        XCTAssertEqual(model.currentIndex, 1)
        model.select(0)
        XCTAssertEqual(model.counterText, "1 of 3")
    }

    func testMovingToAnotherImageGoesBackToFitted() {
        var model = viewer()
        model.setZoom(2, fitted: 0.5)
        model.goToNext()
        XCTAssertEqual(model.zoom, .fitted)
        model.showActualSize()
        model.select(4)
        XCTAssertEqual(model.zoom, .fitted)
        model.showActualSize()
        model.select(4)
        XCTAssertEqual(model.zoom, .fixed(1), "selecting the current image is not a move")
    }

    // MARK: - Zoom

    func testTheFittedZoomHoldsTheWholeImageAndNeverEnlargesIt() {
        let size = CGSize(width: 2800, height: 1800)
        XCTAssertEqual(ImageViewerModel.fittedZoom(imagePixels: size, viewport: CGSize(width: 1400, height: 1400), scaleFactor: 1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ImageViewerModel.fittedZoom(imagePixels: size, viewport: CGSize(width: 2800, height: 600), scaleFactor: 1), 600.0 / 1800, accuracy: 0.0001)
        XCTAssertEqual(ImageViewerModel.fittedZoom(imagePixels: size, viewport: CGSize(width: 1400, height: 900), scaleFactor: 2), 1, accuracy: 0.0001)
        XCTAssertEqual(ImageViewerModel.fittedZoom(imagePixels: CGSize(width: 100, height: 80), viewport: CGSize(width: 1000, height: 800), scaleFactor: 1), 1)
    }

    func testTheFittedZoomOfNothingIsActualSize() {
        XCTAssertEqual(ImageViewerModel.fittedZoom(imagePixels: .zero, viewport: CGSize(width: 10, height: 10), scaleFactor: 1), 1)
        XCTAssertEqual(ImageViewerModel.fittedZoom(imagePixels: CGSize(width: 10, height: 10), viewport: .zero, scaleFactor: 1), 1)
        XCTAssertEqual(ImageViewerModel.fittedZoom(imagePixels: CGSize(width: 10, height: 10), viewport: CGSize(width: 5, height: 5), scaleFactor: 0), 1)
    }

    func testItOpensFittedAndShowsTheFittedZoom() {
        let model = viewer()
        XCTAssertEqual(model.zoom, .fitted)
        XCTAssertEqual(model.effectiveZoom(fitted: 0.62), 0.62)
        XCTAssertEqual(ImageViewerModel.percentText(0.62), "62 %")
        XCTAssertEqual(ImageViewerModel.percentText(1), "100 %")
    }

    func testZoomingInWalksTheStepsAboveTheZoomNowAndStopsAtTheLargest() {
        var model = viewer()
        model.zoomIn(fitted: 0.62)
        XCTAssertEqual(model.zoom, .fixed(0.67))
        for expected in [1.0, 1.5, 2, 3, 4] {
            model.zoomIn(fitted: 0.62)
            XCTAssertEqual(model.zoom, .fixed(expected))
        }
        XCTAssertFalse(model.canZoomIn(fitted: 0.62))
        model.zoomIn(fitted: 0.62)
        XCTAssertEqual(model.zoom, .fixed(4))
    }

    func testZoomingOutWalksTheStepsBelowTheZoomNowAndStopsAtTheSmallest() {
        var model = viewer()
        model.zoomOut(fitted: 0.62)
        XCTAssertEqual(model.zoom, .fixed(0.5))
        for expected in [0.33, 0.25] {
            model.zoomOut(fitted: 0.62)
            XCTAssertEqual(model.zoom, .fixed(expected))
        }
        XCTAssertFalse(model.canZoomOut(fitted: 0.62))
        model.zoomOut(fitted: 0.62)
        XCTAssertEqual(model.zoom, .fixed(0.25))
        XCTAssertTrue(model.canZoomIn(fitted: 0.62))
    }

    func testAnImageThatFitsBelowTheSmallestStepCanZoomOutToItsFit() {
        var model = viewer()
        XCTAssertEqual(ImageViewerModel.smallestZoom(fitted: 0.1), 0.1)
        model.showActualSize()
        for _ in 0..<5 { model.zoomOut(fitted: 0.1) }
        XCTAssertEqual(model.zoom, .fixed(0.1))
        XCTAssertFalse(model.canZoomOut(fitted: 0.1))
    }

    func testAnyZoomIsClampedAtBothEnds() {
        var model = viewer()
        model.setZoom(40, fitted: 0.5)
        XCTAssertEqual(model.zoom, .fixed(4))
        model.setZoom(0.01, fitted: 0.5)
        XCTAssertEqual(model.zoom, .fixed(0.25))
        model.setZoom(0.01, fitted: 0.1)
        XCTAssertEqual(model.zoom, .fixed(0.1))
        model.setZoom(1.7, fitted: 0.5)
        XCTAssertEqual(model.effectiveZoom(fitted: 0.5), 1.7)
    }

    func testZoomingInFromBetweenStepsGoesToTheNextOne() {
        var model = viewer()
        model.setZoom(1.7, fitted: 0.5)
        model.zoomIn(fitted: 0.5)
        XCTAssertEqual(model.zoom, .fixed(2))
        model.setZoom(1.7, fitted: 0.5)
        model.zoomOut(fitted: 0.5)
        XCTAssertEqual(model.zoom, .fixed(1.5))
    }

    func testFitGoesBackToTheFittedZoom() {
        var model = viewer()
        model.zoomIn(fitted: 0.5)
        model.fit()
        XCTAssertEqual(model.zoom, .fitted)
        XCTAssertTrue(model.canZoomIn(fitted: 0.5))
        XCTAssertTrue(model.canZoomOut(fitted: 0.5))
    }

    func testActualSizeIsOneImagePixelOnOneScreenPixel() {
        var model = viewer()
        model.showActualSize()
        XCTAssertEqual(model.effectiveZoom(fitted: 0.3), 1)
        let pixels = CGSize(width: 2800, height: 1800)
        XCTAssertEqual(ImageViewerModel.displaySize(imagePixels: pixels, zoom: 1, scaleFactor: 1), pixels)
        XCTAssertEqual(ImageViewerModel.displaySize(imagePixels: pixels, zoom: 1, scaleFactor: 2), CGSize(width: 1400, height: 900))
        XCTAssertEqual(ImageViewerModel.displaySize(imagePixels: pixels, zoom: 0.5, scaleFactor: 2), CGSize(width: 700, height: 450))
        XCTAssertEqual(ImageViewerModel.displaySize(imagePixels: pixels, zoom: 1, scaleFactor: 0), .zero)
    }

    func testDoubleClickTogglesBetweenFittedAndActualSize() {
        var model = viewer()
        model.toggleFittedAndActualSize()
        XCTAssertEqual(model.zoom, .fixed(1))
        model.toggleFittedAndActualSize()
        XCTAssertEqual(model.zoom, .fitted)
        model.setZoom(2, fitted: 0.5)
        model.toggleFittedAndActualSize()
        XCTAssertEqual(model.zoom, .fitted)
    }

    func testAZoomedViewerCanBeBuiltForTheGallery() {
        let model = ImageViewerModel(images: [shot("a")], zoom: .fixed(2))
        XCTAssertEqual(model.effectiveZoom(fitted: 0.5), 2)
    }

    // MARK: - Words

    func testThePixelSizeReadsWidthTimesHeight() {
        XCTAssertEqual(ImageViewerModel.pixelSizeText(CGSize(width: 2800, height: 1800)), "2800 × 1800")
    }

    func testSaveOffersTheLabelAsTheFileName() {
        XCTAssertEqual(ImageViewerModel.suggestedFileName(label: "Run header at 1440×900"), "Run header at 1440×900")
        XCTAssertEqual(ImageViewerModel.suggestedFileName(label: " a/b: c "), "a-b- c")
        XCTAssertEqual(ImageViewerModel.suggestedFileName(label: "  "), "Screenshot")
    }
}
