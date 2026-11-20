import AppKit
import SwiftUI
import SymphonyBarCore
import UniformTypeIdentifiers

// The image viewer: a screenshot large, in a window of its own, with every other image of its set a key away. A header
// that says the image and holds the controls, the image fitted to the window (zoomed and panned on request), and, for a
// set, a filmstrip of its images. Its rules (the set, the moves, the zoom steps) live in `ImageViewerModel`.

/// What the viewer's controls are called, as their help text and VoiceOver say them.
enum ImageViewerText {
    static let previous = "Previous image"
    static let next = "Next image"
    static let zoomOut = "Zoom out"
    static let zoomIn = "Zoom in"
    static let fit = "Fit to window"
    static let actualSize = "Actual size"
    static let copy = "Copy image"
    static let save = "Save…"
    static let close = "Close"
    static func image(_ label: String) -> String { "Screenshot \(label)" }
    static func filmstripImage(_ label: String, counter: String) -> String { "Screenshot \(label), \(counter)" }
}

/// An image read and decoded once: kept by artifact id, whose bytes never change.
struct ImageViewerPicture {
    let image: NSImage
    /// The image's size in pixels, which is not its size in points on a display of more than one pixel to the point.
    let pixels: CGSize
    let data: Data

    private final class Box {
        let picture: ImageViewerPicture
        init(_ picture: ImageViewerPicture) { self.picture = picture }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = ArtifactImages.capacity
        return cache
    }()

    /// The picture `data` holds, or nil when it holds none.
    static func read(_ data: Data, id: String) -> ImageViewerPicture? {
        if let kept = cache.object(forKey: id as NSString) { return kept.picture }
        guard let image = NSImage(data: data) else { return nil }
        var pixels = image.size
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Double, let height = properties[kCGImagePropertyPixelHeight] as? Double {
            pixels = CGSize(width: width, height: height)
        }
        let picture = ImageViewerPicture(image: image, pixels: pixels, data: data)
        cache.setObject(Box(picture), forKey: id as NSString)
        return picture
    }

    func copyToPasteboard() {
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([image])
    }

    /// Asks where to save it and writes it there as a PNG.
    @MainActor
    func save(label: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ImageViewerModel.suggestedFileName(label: label)
        let data = data
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
            else { return }
            try? png.write(to: url)
        }
    }
}

// MARK: - The window's state

/// What the viewer window shows: the model of the set on view, and the images it reads. One session serves the one
/// viewer window; opening another image replaces the model.
@MainActor
public final class ImageViewerSession: ObservableObject {
    @Published public var model: ImageViewerModel
    public private(set) var images: ArtifactImages

    public init(images: ArtifactImages, model: ImageViewerModel = ImageViewerModel(images: [])) {
        self.images = images
        self.model = model
    }

    /// Shows `current` of `set`.
    public func show(_ set: [TicketScreenshot], current: TicketScreenshot, images: ArtifactImages) {
        self.images = images
        model = ImageViewerModel(images: set, current: current)
    }
}

/// Opens the viewer on an image of a set. The app gives it to every view that draws screenshots; where none is given
/// (a snapshot), a thumbnail has nothing to open.
public struct OpenImageViewerAction {
    let handler: (_ set: [TicketScreenshot], _ current: TicketScreenshot, _ images: ArtifactImages) -> Void

    public init(_ handler: @escaping (_ set: [TicketScreenshot], _ current: TicketScreenshot, _ images: ArtifactImages) -> Void) {
        self.handler = handler
    }

    public func callAsFunction(_ set: [TicketScreenshot], current: TicketScreenshot, images: ArtifactImages) {
        handler(set, current, images)
    }
}

public extension EnvironmentValues {
    @Entry var openImageViewer: OpenImageViewerAction?
}

// MARK: - The viewer

/// The viewer window's content, on its session.
public struct ImageViewerView: View {
    @ObservedObject var session: ImageViewerSession
    let close: () -> Void

    public init(session: ImageViewerSession, close: @escaping () -> Void) {
        self.session = session
        self.close = close
    }

    public var body: some View {
        ImageViewerBody(model: $session.model, images: session.images, close: close)
    }
}

/// The viewer drawn whole and still, at `size`, without its window: what a snapshot renders (the gallery). Its
/// image is drawn where the viewer would draw it, cut to the canvas, with no scroll view.
public struct ImageViewerPage: View {
    let model: ImageViewerModel
    let images: ArtifactImages
    let size: CGSize

    public init(model: ImageViewerModel, images: ArtifactImages, size: CGSize) {
        self.model = model
        self.images = images
        self.size = size
    }

    public var body: some View {
        ImageViewerBody(model: .constant(model), images: images, canvasSize: ImageViewerBody.canvasSize(in: size, isSet: model.isSet), close: {})
            .frame(width: size.width, height: size.height)
    }
}

struct ImageViewerBody: View {
    @Binding var model: ImageViewerModel
    @ObservedObject var images: ArtifactImages
    /// The canvas' size when it is fixed (a snapshot); nil in a window, where the canvas takes what the window leaves.
    var canvasSize: CGSize?
    let close: () -> Void

    @State private var measuredViewport = CGSize.zero
    @Environment(\.displayScale) private var displayScale

    static let thumbnailSize = CGSize(width: 96, height: 60)
    static let controlSize = DesignTokens.Control.small

    static var headerHeight: Double { controlSize.height + 2 * DesignTokens.Space.s3 }
    static var filmstripHeight: Double { thumbnailSize.height + 2 * DesignTokens.Space.s2 }

    /// The canvas inside a viewer of `size`: what is left under the header and over the filmstrip, and their lines.
    static func canvasSize(in size: CGSize, isSet: Bool) -> CGSize {
        let chrome = headerHeight + HairlineDivider.thickness + (isSet ? filmstripHeight + HairlineDivider.thickness : 0)
        return CGSize(width: size.width, height: size.height - chrome)
    }

    init(model: Binding<ImageViewerModel>, images: ArtifactImages, canvasSize: CGSize? = nil, close: @escaping () -> Void) {
        _model = model
        self.images = images
        self.canvasSize = canvasSize
        self.close = close
    }

    private var viewport: CGSize { canvasSize ?? measuredViewport }

    private var picture: ImageViewerPicture? {
        guard let shot = model.currentImage, case let .loaded(data) = images.image(shot) else { return nil }
        return ImageViewerPicture.read(data, id: shot.id)
    }

    private var fittedZoom: Double {
        guard let picture else { return 1 }
        return ImageViewerModel.fittedZoom(imagePixels: picture.pixels, viewport: viewport, scaleFactor: Double(displayScale))
    }

    var body: some View {
        VStack(spacing: 0) {
            ImageViewerHeader(model: $model, picture: picture, fittedZoom: fittedZoom, close: close)
                .frame(height: Self.headerHeight)
            HairlineDivider()
            canvas
            if model.isSet {
                HairlineDivider()
                ImageViewerFilmstrip(model: $model, images: images, scrolls: canvasSize == nil)
                    .frame(height: Self.filmstripHeight)
            }
        }
        .background(DesignTokens.Surface.window.color)
        .background { shortcuts }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var canvas: some View {
        let surface = DesignTokens.Surface.sunken.color
        if let canvasSize {
            ZStack {
                surface
                canvasContent
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .clipped()
        } else {
            ZStack {
                surface
                canvasContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { measuredViewport = $0 })
        }
    }

    @ViewBuilder private var canvasContent: some View {
        if let shot = model.currentImage {
            Group {
                switch images.image(shot) {
                case .loaded:
                    if let picture {
                        ImageViewerCanvas(
                            model: $model, shot: shot, picture: picture, viewport: viewport, fittedZoom: fittedZoom,
                            scaleFactor: Double(displayScale), interactive: canvasSize == nil
                        )
                        .id(model.currentIndex)
                    } else {
                        Self.placeholder(TicketScreenshot.unavailableTitle)
                    }
                case .unavailable:
                    Self.placeholder(TicketScreenshot.unavailableTitle)
                case .loading, .failed:
                    Self.placeholder(nil)
                }
            }
            .onAppear { images.load(shot) }
            .onChange(of: model.currentIndex) { images.load(shot) }
        } else {
            Self.placeholder(nil)
        }
    }

    static func placeholder(_ text: String?) -> some View {
        FindingShot.placeholder(text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The keys no control carries: Space closes, as Quick Look does, and ⌘= zooms in as ⌘+ does on keyboards where
    /// plus is a shifted key.
    private var shortcuts: some View {
        ZStack {
            Button(ImageViewerText.close, action: close)
                .keyboardShortcut(.space, modifiers: [])
            Button(ImageViewerText.zoomIn) { model.zoomIn(fitted: fittedZoom) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(picture == nil || !model.canZoomIn(fitted: fittedZoom))
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

// MARK: - Header

/// One line: the image's label, its pixel size and where it is in the set, and the controls.
private struct ImageViewerHeader: View {
    @Binding var model: ImageViewerModel
    let picture: ImageViewerPicture?
    let fittedZoom: Double
    let close: () -> Void

    private var control: DesignTokens.Control { ImageViewerBody.controlSize }

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.s2) {
            Text(model.currentImage?.label ?? "")
                .textStyle(.heading)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.currentImage?.label ?? "")
                .accessibilityAddTraits(.isHeader)
            if let picture {
                Text(ImageViewerModel.pixelSizeText(picture.pixels))
                    .textStyle(.secondary)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            if model.isSet {
                Text(model.counterText)
                    .textStyle(.secondary)
                    .foregroundStyle(DesignTokens.TextColor.secondary.color)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityLabel(model.counterText)
            }
            Spacer(minLength: DesignTokens.Space.s2)
            if model.isSet {
                IconButton("chevron.left", help: ImageViewerText.previous, size: control, shortcut: KeyboardShortcut(.leftArrow, modifiers: [])) {
                    model.goToPrevious()
                }
                .disabled(!model.canGoToPrevious)
                IconButton("chevron.right", help: ImageViewerText.next, size: control, shortcut: KeyboardShortcut(.rightArrow, modifiers: [])) {
                    model.goToNext()
                }
                .disabled(!model.canGoToNext)
                HairlineDivider(.vertical, length: control.height - DesignTokens.Space.s2)
            }
            zoomControls
            HairlineDivider(.vertical, length: control.height - DesignTokens.Space.s2)
            IconButton("doc.on.doc", help: ImageViewerText.copy, size: control, shortcut: KeyboardShortcut("c", modifiers: .command)) {
                picture?.copyToPasteboard()
            }
            .disabled(picture == nil)
            IconButton("square.and.arrow.down", help: ImageViewerText.save, size: control) {
                picture?.save(label: model.currentImage?.label ?? "")
            }
            .disabled(picture == nil)
            IconButton("xmark", help: ImageViewerText.close, size: control, shortcut: .cancelAction, action: close)
        }
        .padding(.horizontal, DesignTokens.Space.s4)
    }

    private var zoomControls: some View {
        let hasPicture = picture != nil
        return HStack(spacing: DesignTokens.Space.s1) {
            IconButton("minus.magnifyingglass", help: ImageViewerText.zoomOut, size: control, shortcut: KeyboardShortcut("-", modifiers: .command)) {
                model.zoomOut(fitted: fittedZoom)
            }
            .disabled(!hasPicture || !model.canZoomOut(fitted: fittedZoom))
            Text(hasPicture ? ImageViewerModel.percentText(model.effectiveZoom(fitted: fittedZoom)) : "")
                .textStyle(.secondary)
                .foregroundStyle(DesignTokens.TextColor.secondary.color)
                .monospacedDigit()
                .lineLimit(1)
                .frame(minWidth: Self.percentWidth)
                .accessibilityLabel("Zoom")
                .accessibilityValue(hasPicture ? ImageViewerModel.percentText(model.effectiveZoom(fitted: fittedZoom)) : "")
            IconButton("plus.magnifyingglass", help: ImageViewerText.zoomIn, size: control, shortcut: KeyboardShortcut("+", modifiers: .command)) {
                model.zoomIn(fitted: fittedZoom)
            }
            .disabled(!hasPicture || !model.canZoomIn(fitted: fittedZoom))
            IconButton(
                "arrow.up.left.and.down.right.magnifyingglass", help: ImageViewerText.fit, size: control,
                shortcut: KeyboardShortcut("0", modifiers: .command)
            ) { model.fit() }
                .disabled(!hasPicture)
            IconButton("1.magnifyingglass", help: ImageViewerText.actualSize, size: control, shortcut: KeyboardShortcut("1", modifiers: .command)) {
                model.showActualSize()
            }
            .disabled(!hasPicture)
        }
    }

    /// The room "400 %" takes, so the controls around it do not move as the zoom changes.
    private static let percentWidth: Double = 48
}

// MARK: - Canvas

/// The image at its zoom: in a scroll view that pans both ways (scroll, drag) once it is larger than the viewport.
/// Pinch and ⌘-scroll zoom about the pointer, and a double-click toggles fitted and actual size.
private struct ImageViewerCanvas: View {
    @Binding var model: ImageViewerModel
    let shot: TicketScreenshot
    let picture: ImageViewerPicture
    let viewport: CGSize
    let fittedZoom: Double
    let scaleFactor: Double
    let interactive: Bool

    @State private var position = ScrollPosition()
    @State private var offset = CGPoint.zero
    @State private var dragStart: CGPoint?
    @State private var pinchStart: Double?
    /// Where, in the viewport, a zoom keeps the image steady: the pointer's place for a pinch or a ⌘-scroll, else the
    /// middle.
    @State private var focus: CGPoint?
    @State private var settledSize = CGSize.zero

    private var zoom: Double { model.effectiveZoom(fitted: fittedZoom) }

    private var displaySize: CGSize {
        ImageViewerModel.displaySize(imagePixels: picture.pixels, zoom: zoom, scaleFactor: scaleFactor)
    }

    private var image: some View {
        Image(nsImage: picture.image)
            .resizable()
            .interpolation(.high)
            .frame(width: displaySize.width, height: displaySize.height)
            .accessibilityLabel(ImageViewerText.image(shot.label))
            .accessibilityAddTraits(.isImage)
    }

    var body: some View {
        if interactive {
            ScrollView([.horizontal, .vertical]) {
                image
                    .frame(minWidth: viewport.width, minHeight: viewport.height)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.toggleFittedAndActualSize() }
                    .gesture(pan)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGPoint.self, of: { $0.contentOffset }, action: { _, new in offset = new })
            .simultaneousGesture(pinch)
            .background(CommandScrollZoom { factor, point in
                focus = point
                model.setZoom(zoom * factor, fitted: fittedZoom)
            })
            .onAppear { settledSize = displaySize }
            .onChange(of: displaySize) { _, new in keepFocusSteady(to: new) }
        } else {
            image
                .frame(width: viewport.width, height: viewport.height)
        }
    }

    private var pan: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let start = dragStart ?? offset
                dragStart = start
                position.scrollTo(x: max(0, start.x - value.translation.width), y: max(0, start.y - value.translation.height))
            }
            .onEnded { _ in dragStart = nil }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? zoom
                pinchStart = start
                focus = value.startLocation
                model.setZoom(start * value.magnification, fitted: fittedZoom)
            }
            .onEnded { _ in pinchStart = nil }
    }

    /// After the image changed size, scrolls so the point of it that was under the focus still is.
    private func keepFocusSteady(to size: CGSize) {
        let old = settledSize
        settledSize = size
        guard old.width > 0, old.height > 0 else { return }
        let point = focus ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        focus = nil
        let target = CGPoint(
            x: Self.steadyOffset(old: old.width, new: size.width, viewport: viewport.width, offset: offset.x, focus: point.x),
            y: Self.steadyOffset(old: old.height, new: size.height, viewport: viewport.height, offset: offset.y, focus: point.y)
        )
        position.scrollTo(x: target.x, y: target.y)
    }

    /// One axis: the offset that keeps the fraction of the image under `focus` there. The content is the image, or the
    /// viewport when the image is smaller, and then it sits in the middle.
    static func steadyOffset(old: Double, new: Double, viewport: Double, offset: Double, focus: Double) -> Double {
        let oldInset = max(0, (viewport - old) / 2)
        let newInset = max(0, (viewport - new) / 2)
        let fraction = min(max((offset + focus - oldInset) / old, 0), 1)
        return min(max(fraction * new - focus + newInset, 0), max(0, new - viewport))
    }
}

/// ⌘-scroll over the canvas zooms it. SwiftUI has no scroll wheel event, so this watches the window's.
private struct CommandScrollZoom: NSViewRepresentable {
    /// The factor to zoom by, and the pointer's place in the view (top left origin).
    let zoomed: (_ factor: Double, _ point: CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.zoomed = zoomed
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak coordinator = context.coordinator] event in
            coordinator?.handle(event) ?? event
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.zoomed = zoomed
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }

    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var zoomed: (Double, CGPoint) -> Void = { _, _ in }

        /// How much one point of a trackpad's scroll, or one line of a wheel's, zooms.
        private static let preciseSensitivity = 0.01
        private static let wheelSensitivity = 0.05

        func handle(_ event: NSEvent) -> NSEvent? {
            guard event.modifierFlags.contains(.command), let view, event.window === view.window else { return event }
            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) else { return event }
            let topLeft = CGPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
            let sensitivity = event.hasPreciseScrollingDeltas ? Self.preciseSensitivity : Self.wheelSensitivity
            zoomed(exp(Double(event.scrollingDeltaY) * sensitivity), topLeft)
            return nil
        }
    }
}

// MARK: - Filmstrip

/// The set's images in a row of thumbnails, the current one ringed; a click goes to one. It scrolls to keep the current
/// one in view.
private struct ImageViewerFilmstrip: View {
    @Binding var model: ImageViewerModel
    @ObservedObject var images: ArtifactImages
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var size: CGSize { ImageViewerBody.thumbnailSize }

    /// False in a snapshot, which cannot draw a scroll view: the row is drawn whole, from its leading edge.
    var scrolls = true

    private var row: some View {
        HStack(spacing: DesignTokens.Space.s2) {
            ForEach(model.images.indices, id: \.self) { index in
                thumbnail(index)
            }
        }
        .padding(.horizontal, DesignTokens.Space.s4)
        .padding(.vertical, DesignTokens.Space.s2)
    }

    var body: some View {
        if scrolls { scrollingRow } else { row.frame(maxWidth: .infinity, alignment: .leading) }
    }

    private var scrollingRow: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                row
            }
            .scrollIndicators(.never)
            .onAppear { reader.scrollTo(model.currentIndex, anchor: .center) }
            .onChange(of: model.currentIndex) { _, index in
                withAnimation(.motion(.standard, reduceMotion: reduceMotion)) { reader.scrollTo(index, anchor: .center) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func thumbnail(_ index: Int) -> some View {
        let shot = model.images[index]
        let current = index == model.currentIndex
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.mark, style: .continuous)
        return Button { model.select(index) } label: {
            FindingThumbnail(shot: shot, images: images, size: size)
                .frame(width: size.width, height: size.height)
                .clipShape(shape)
                .overlay(shape.strokeBorder(
                    current ? DesignTokens.Selection.color.color : DesignTokens.Surface.separator.color,
                    lineWidth: current ? DesignTokens.Selection.cardRingWidth : HairlineDivider.thickness
                ))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .animation(.motion(.fast, reduceMotion: reduceMotion), value: current)
        .help(shot.label)
        .id(index)
        .accessibilityLabel(ImageViewerText.filmstripImage(shot.label, counter: "\(index + 1) of \(model.images.count)"))
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}
