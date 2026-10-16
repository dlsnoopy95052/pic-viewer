import Cocoa
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// MARK: - Supported formats

enum Formats {
    /// Every extension ImageIO knows about, plus a few extras (svg/pdf/raw) that NSImage can try.
    static let extensions: Set<String> = {
        var set = Set<String>()
        for id in (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [] {
            if let type = UTType(id) {
                set.formUnion(type.tags[.filenameExtension] ?? [])
            }
        }
        set.formUnion(["jpg", "jpeg", "png", "gif", "tif", "tiff", "bmp", "heic", "heif", "webp",
                       "ico", "icns", "psd", "avif", "jp2", "svg", "pdf",
                       "dng", "cr2", "cr3", "nef", "arw", "orf", "raf", "rw2"])
        return set
    }()

    static func isImage(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    static func imagesInFolder(of url: URL) -> [URL] {
        let dir = url.deletingLastPathComponent()
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items.filter(isImage).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }
}

// MARK: - Image canvas (fit / zoom / pan)

final class ImageCanvas: NSView {
    var image: NSImage? {
        didSet {
            if !preserveView { zoom = nil; offset = .zero; quarterTurns = 0; cropRect = nil; drawPoints = [] }
            needsDisplay = true
        }
    }
    private var preserveView = false
    /// Swap the picture without touching zoom / pan / rotation (live adjustment preview).
    func replaceImage(_ new: NSImage) {
        preserveView = true; image = new; preserveView = false
    }

    // Crop selection (view coordinates). Only meaningful while quarterTurns == 0.
    var cropMode = false {
        didSet {
            cropRect = nil; cropStart = nil; needsDisplay = true
            if cropMode { tool = .none }
            window?.invalidateCursorRects(for: self)
            onCropModeChange?()
        }
    }
    private(set) var cropRect: NSRect?
    private var cropStart: NSPoint?
    var onCropModeChange: (() -> Void)?
    var onEscape: (() -> Void)?

    // Annotation drawing (points are in image points, origin bottom-left).
    var tool: AnnotationTool = .none {
        didSet {
            if tool != .none { cropMode = false }
            drawPoints = []
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            onToolChange?()
        }
    }
    var annotationColor = NSColor.systemRed
    var annotationWidth: CGFloat = 4
    private var drawPoints: [NSPoint] = []
    var onShape: ((AnnotationShape) -> Void)?
    var onText: ((NSPoint) -> Void)?
    var onToolChange: (() -> Void)?

    private func toImage(_ p: NSPoint) -> NSPoint {
        let ir = imageRect, s = image?.size ?? .zero
        guard ir.width > 0, ir.height > 0 else { return .zero }
        return NSPoint(x: (p.x - ir.minX) / ir.width * s.width, y: (p.y - ir.minY) / ir.height * s.height)
    }

    override func resetCursorRects() {
        if tool != .none || cropMode { addCursorRect(bounds, cursor: .crosshair) }
    }

    private var imageRect: NSRect {
        guard let image else { return .zero }
        let k = zoom ?? fitScale
        let w = image.size.width * k, h = image.size.height * k
        return NSRect(x: bounds.midX - w / 2 + offset.x, y: bounds.midY - h / 2 + offset.y, width: w, height: h)
    }

    /// The selection in image points (origin bottom-left), or nil.
    var cropRectInImage: NSRect? {
        guard let image, let r = cropRect, r.width > 2, r.height > 2 else { return nil }
        let ir = imageRect
        guard ir.width > 0, ir.height > 0 else { return nil }
        let kx = image.size.width / ir.width, ky = image.size.height / ir.height
        return NSRect(x: (r.minX - ir.minX) * kx, y: (r.minY - ir.minY) * ky,
                      width: r.width * kx, height: r.height * ky)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
    /// Clockwise quarter turns applied to the view of the image (not to the file).
    private(set) var quarterTurns = 0
    var onDrop: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    func rotate(by turns: Int) {
        cropMode = false
        tool = .none
        quarterTurns = ((quarterTurns + turns) % 4 + 4) % 4
        offset = .zero
        needsDisplay = true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard let url = urls?.first else { return false }
        onDrop?(url)
        return true
    }
    /// nil means "fit to window".
    private(set) var zoom: CGFloat?
    private var offset = CGPoint.zero

    override var acceptsFirstResponder: Bool { true }

    private var fitScale: CGFloat {
        guard let raw = image?.size, raw.width > 0, raw.height > 0 else { return 1 }
        let s = quarterTurns % 2 == 1 ? NSSize(width: raw.height, height: raw.width) : raw
        return min(1, bounds.width / s.width, bounds.height / s.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.11, alpha: 1).setFill()
        bounds.fill()
        guard let image else { return }
        let scale = zoom ?? fitScale
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: bounds.midX + offset.x, y: bounds.midY + offset.y)
        ctx.rotate(by: -CGFloat(quarterTurns) * .pi / 2)
        let rect = NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.high.rawValue])
        ctx.restoreGState()

        if cropMode {
            let path = NSBezierPath(rect: bounds)
            if let r = cropRect { path.append(NSBezierPath(rect: r)) }
            path.windingRule = .evenOdd
            NSColor(white: 0, alpha: 0.5).setFill()
            path.fill()
            if let r = cropRect {
                NSColor.white.setStroke()
                let b = NSBezierPath(rect: r)
                b.lineWidth = 1
                b.setLineDash([5, 3], count: 2, phase: 0)
                b.stroke()
            }
        }

        if tool != .none, drawPoints.count >= 2 {
            let ir = imageRect
            let k = ir.width / image.size.width
            let shape = AnnotationShape(tool: tool, points: drawPoints,
                                        width: annotationWidth * ImageEdit.strokeScale(image.size))
            let path = ImageEdit.path(for: shape, headScale: k) {
                NSPoint(x: ir.minX + $0.x * k, y: ir.minY + $0.y * k)
            }
            path.lineWidth = shape.width * k
            annotationColor.setStroke()
            path.stroke()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    func fit() { zoom = nil; offset = .zero; needsDisplay = true }

    /// The image with the current rotation baked in (for printing / copying).
    var rotatedImage: NSImage? {
        guard let image else { return nil }
        let t = quarterTurns
        if t == 0 { return image }
        let s = image.size
        let out = t % 2 == 1 ? NSSize(width: s.height, height: s.width) : s
        return ImageEdit.rasterize(image, outSize: out) { ctx, src, out, cg in
            ctx.translateBy(x: out.width / 2, y: out.height / 2)
            ctx.rotate(by: -CGFloat(t) * .pi / 2)
            ctx.draw(cg, in: CGRect(x: -src.width / 2, y: -src.height / 2, width: src.width, height: src.height))
        } ?? image
    }
    func actualSize() { zoom = 1; offset = .zero; needsDisplay = true }

    func zoomBy(_ factor: CGFloat) {
        let current = zoom ?? fitScale
        zoom = min(max(current * factor, 0.02), 32)
        cropRect = nil
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) { zoomBy(1 + event.magnification) }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            zoomBy(exp(event.scrollingDeltaY * 0.02))
        } else if zoom != nil {
            offset.x += event.scrollingDeltaX
            offset.y -= event.scrollingDeltaY
            cropRect = nil
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard tool != .none, drawPoints.count >= 2, let image else { return }
        let shape = AnnotationShape(tool: tool, points: drawPoints,
                                    width: annotationWidth * ImageEdit.strokeScale(image.size))
        drawPoints = []
        needsDisplay = true
        onShape?(shape)
    }

    override func mouseDragged(with event: NSEvent) {
        if tool != .none, !drawPoints.isEmpty, tool != .text {
            let p = toImage(convert(event.locationInWindow, from: nil))
            if tool == .pen { drawPoints.append(p) } else { drawPoints = [drawPoints[0], p] }
            needsDisplay = true
            return
        }
        if cropMode, let start = cropStart {
            let p = convert(event.locationInWindow, from: nil)
            cropRect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y),
                              width: abs(p.x - start.x), height: abs(p.y - start.y))
                .intersection(imageRect)
            needsDisplay = true
            return
        }
        guard zoom != nil else { return }
        offset.x += event.deltaX
        offset.y -= event.deltaY
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if tool != .none, image != nil {
            let p = toImage(convert(event.locationInWindow, from: nil))
            if tool == .text { onText?(p) } else { drawPoints = [p] }
            return
        }
        if cropMode {
            cropStart = convert(event.locationInWindow, from: nil)
            cropRect = nil
            needsDisplay = true
            return
        }
        if event.clickCount == 2 {
            if zoom == nil { actualSize() } else { fit() }
        }
    }
}

// MARK: - Thumbnail strip

final class ThumbCell: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var isCurrent = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    override var intrinsicContentSize: NSSize { NSSize(width: 84, height: 64) }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 3, dy: 3)
        NSColor(white: 0.2, alpha: 1).setFill()
        box.fill()
        if let image {
            let s = image.size
            let k = min(box.width / s.width, box.height / s.height)
            let r = NSRect(x: box.midX - s.width * k / 2, y: box.midY - s.height * k / 2,
                           width: s.width * k, height: s.height * k)
            image.draw(in: r)
        }
        if isCurrent {
            NSColor.controlAccentColor.setStroke()
            let p = NSBezierPath(rect: box.insetBy(dx: 1, dy: 1))
            p.lineWidth = 3
            p.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class ThumbnailStrip: NSScrollView {
    var onSelect: ((Int) -> Void)?
    private let stack = NSStackView()
    private var cells: [ThumbCell] = []
    private var generation = 0
    private var current = -1
    private static let queue = DispatchQueue(label: "thumbnails", qos: .utility, attributes: .concurrent)

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasHorizontalScroller = true
        hasVerticalScroller = false
        drawsBackground = true
        backgroundColor = NSColor(white: 0.07, alpha: 1)
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        documentView = stack
    }
    required init?(coder: NSCoder) { fatalError() }

    func load(_ urls: [URL], selected: Int) {
        generation += 1
        let gen = generation
        cells.forEach { $0.removeFromSuperview() }
        cells = urls.enumerated().map { i, _ in
            let c = ThumbCell()
            c.onClick = { [weak self] in self?.onSelect?(i) }
            stack.addArrangedSubview(c)
            return c
        }
        stack.frame.size = NSSize(width: CGFloat(cells.count) * 84 + 8, height: 64)
        select(selected)
        for (i, url) in urls.enumerated() {
            Self.queue.async { [weak self] in
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 160] as CFDictionary)
                else { return }
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                DispatchQueue.main.async {
                    guard let self, self.generation == gen, self.cells.indices.contains(i) else { return }
                    self.cells[i].image = img
                }
            }
        }
    }

    func select(_ i: Int) {
        if cells.indices.contains(current) { cells[current].isCurrent = false }
        current = i
        guard cells.indices.contains(i) else { return }
        cells[i].isCurrent = true
        cells[i].scrollToVisible(cells[i].bounds.insetBy(dx: -80, dy: 0))
    }
}

// MARK: - Image metadata

enum ImageInfo {
    static func lines(for url: URL, pixelSize: (Int, Int)?) -> [String] {
        var out = [url.lastPathComponent]
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let bytes = attrs?[.size] as? Int64 {
            out.append("Size: " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        if let (w, h) = pixelSize { out.append("Dimensions: \(w) × \(h) px") }
        if let date = attrs?[.modificationDate] as? Date {
            out.append("Modified: " + date.formatted(date: .abbreviated, time: .shortened))
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return out }
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let camera = [tiff[kCGImagePropertyTIFFMake], tiff[kCGImagePropertyTIFFModel]]
            .compactMap { $0 as? String }.joined(separator: " ")
        if !camera.isEmpty { out.append("Camera: " + camera) }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String { out.append("Lens: " + lens) }
        var shot: [String] = []
        if let f = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue { shot.append(String(format: "ƒ/%.1f", f)) }
        if let t = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue, t > 0 {
            shot.append(t < 1 ? "1/\(Int((1 / t).rounded())) s" : String(format: "%.1f s", t))
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first { shot.append("ISO \(iso)") }
        if let fl = (exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue {
            shot.append(String(format: "%.0f mm", fl))
        }
        if !shot.isEmpty { out.append(shot.joined(separator: "  ")) }
        if let d = exif[kCGImagePropertyExifDateTimeOriginal] as? String { out.append("Taken: " + d) }
        return out
    }
}

// MARK: - Editing operations

enum AnnotationTool: Int {
    case none, line, arrow, rect, ellipse, pen, text
}

struct AnnotationShape {
    var tool: AnnotationTool
    var points: [NSPoint]
    var width: CGFloat
}

enum ImageEdit {
    private static let ciContext = CIContext()

    static func cgImage(_ image: NSImage) -> CGImage? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Renders at the source's full pixel resolution (not the point size).
    static func rasterize(_ image: NSImage, outSize: NSSize? = nil,
                          _ draw: (CGContext, NSSize, NSSize, CGImage) -> Void) -> NSImage? {
        guard let cg = cgImage(image), image.size.width > 0 else { return nil }
        let k = CGFloat(cg.width) / image.size.width
        let out = outSize ?? image.size
        let w = max(1, Int((out.width * k).rounded())), h = max(1, Int((out.height * k).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: k, y: k)
        draw(ctx, image.size, out, cg)
        guard let result = ctx.makeImage() else { return nil }
        return NSImage(cgImage: result, size: out)
    }

    static func flip(_ image: NSImage, horizontal: Bool) -> NSImage {
        rasterize(image) { ctx, s, _, cg in
            if horizontal {
                ctx.translateBy(x: s.width, y: 0); ctx.scaleBy(x: -1, y: 1)
            } else {
                ctx.translateBy(x: 0, y: s.height); ctx.scaleBy(x: 1, y: -1)
            }
            ctx.draw(cg, in: CGRect(origin: .zero, size: s))
        } ?? image
    }

    /// Stroke width / font size multiplier so marks look similar on small and huge pictures.
    static func strokeScale(_ size: NSSize) -> CGFloat { max(1, max(size.width, size.height) / 800) }

    static func path(for shape: AnnotationShape, headScale: CGFloat,
                     map: (NSPoint) -> NSPoint) -> NSBezierPath {
        let pts = shape.points.map(map)
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        guard let a = pts.first, let b = pts.last else { return path }
        let box = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        switch shape.tool {
        case .line:
            path.move(to: a); path.line(to: b)
        case .arrow:
            path.move(to: a); path.line(to: b)
            let angle = atan2(b.y - a.y, b.x - a.x)
            let len = shape.width * 4 * headScale + 6 * headScale
            for d in [CGFloat.pi * 5 / 6, -CGFloat.pi * 5 / 6] {
                path.move(to: b)
                path.line(to: NSPoint(x: b.x + len * cos(angle + d), y: b.y + len * sin(angle + d)))
            }
        case .rect: path.appendRect(box)
        case .ellipse: path.appendOval(in: box)
        case .pen:
            path.move(to: a)
            pts.dropFirst().forEach { path.line(to: $0) }
        case .text, .none: break
        }
        return path
    }

    static func render(_ shape: AnnotationShape, color: NSColor, onto image: NSImage) -> NSImage? {
        rasterize(image) { ctx, s, _, cg in
            ctx.draw(cg, in: CGRect(origin: .zero, size: s))
            withGraphics(ctx) {
                let p = path(for: shape, headScale: 1) { $0 }
                p.lineWidth = shape.width
                color.setStroke()
                p.stroke()
            }
        }
    }

    static func renderText(_ text: String, at point: NSPoint, color: NSColor, fontSize: CGFloat,
                           onto image: NSImage) -> NSImage? {
        rasterize(image) { ctx, s, _, cg in
            ctx.draw(cg, in: CGRect(origin: .zero, size: s))
            withGraphics(ctx) {
                let str = NSAttributedString(string: text, attributes: [
                    .font: NSFont.boldSystemFont(ofSize: fontSize), .foregroundColor: color])
                let box = str.boundingRect(with: NSSize(width: 100_000, height: 100_000),
                                           options: [.usesLineFragmentOrigin])
                str.draw(with: NSRect(x: point.x, y: point.y - box.height, width: box.width + 4, height: box.height),
                         options: [.usesLineFragmentOrigin])
            }
        }
    }

    private static func withGraphics(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// `rect` is in image points, origin bottom-left.
    static func crop(_ image: NSImage, to rect: NSRect) -> NSImage? {
        guard let cg = cgImage(image), image.size.width > 0 else { return nil }
        let k = CGFloat(cg.width) / image.size.width
        let px = CGRect(x: rect.minX * k, y: (image.size.height - rect.maxY) * k,
                        width: rect.width * k, height: rect.height * k).integral
        guard let out = cg.cropping(to: px) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: CGFloat(out.width) / k, height: CGFloat(out.height) / k))
    }

    static func adjust(_ image: NSImage, brightness: Double, contrast: Double, saturation: Double) -> NSImage? {
        guard let cg = cgImage(image), let f = CIFilter(name: "CIColorControls") else { return nil }
        f.setValue(CIImage(cgImage: cg), forKey: kCIInputImageKey)
        f.setValue(brightness, forKey: kCIInputBrightnessKey)
        f.setValue(contrast, forKey: kCIInputContrastKey)
        f.setValue(saturation, forKey: kCIInputSaturationKey)
        guard let out = f.outputImage, let res = ciContext.createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: res, size: image.size)
    }

    static let writableExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff"]

    static func encode(_ image: NSImage, as ext: String) -> Data? {
        guard let cg = cgImage(image) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        switch ext.lowercased() {
        case "jpg", "jpeg": return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        case "tif", "tiff": return rep.representation(using: .tiff, properties: [:])
        default: return rep.representation(using: .png, properties: [:])
        }
    }
}

/// Popover content: three sliders with live preview.
final class AdjustController: NSViewController {
    var onChange: ((Double, Double, Double) -> Void)?
    var onApply: ((Double, Double, Double) -> Void)?
    private let brightness = NSSlider(value: 0, minValue: -0.5, maxValue: 0.5, target: nil, action: nil)
    private let contrast = NSSlider(value: 1, minValue: 0.5, maxValue: 1.5, target: nil, action: nil)
    private let saturation = NSSlider(value: 1, minValue: 0, maxValue: 2, target: nil, action: nil)

    private var values: (Double, Double, Double) {
        (brightness.doubleValue, contrast.doubleValue, saturation.doubleValue)
    }

    override func loadView() {
        func row(_ title: String, _ slider: NSSlider) -> NSStackView {
            slider.target = self
            slider.action = #selector(changed)
            slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
            let label = NSTextField(labelWithString: title)
            label.widthAnchor.constraint(equalToConstant: 70).isActive = true
            return NSStackView(views: [label, slider])
        }
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetValues))
        let apply = NSButton(title: "Apply", target: self, action: #selector(apply))
        apply.keyEquivalent = "\r"
        let buttons = NSStackView(views: [reset, apply])
        let stack = NSStackView(views: [row("Brightness", brightness), row("Contrast", contrast),
                                        row("Saturation", saturation), buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.frame.size = stack.fittingSize
        view = stack
    }

    @objc private func changed() { let v = values; onChange?(v.0, v.1, v.2) }
    @objc private func resetValues() {
        brightness.doubleValue = 0; contrast.doubleValue = 1; saturation.doubleValue = 1
        changed()
    }
    @objc private func apply() { let v = values; onApply?(v.0, v.1, v.2) }
}

// MARK: - Printing

enum PrintScaleMode: Int, CaseIterable {
    case shrinkToFit, fitToPage, actualSize, fillPage

    var title: String {
        switch self {
        case .shrinkToFit: return "Shrink to Fit (only if too large)"
        case .fitToPage: return "Fit to Page (enlarge if needed)"
        case .actualSize: return "Actual Size"
        case .fillPage: return "Fill Page (crop edges)"
        }
    }
}

final class PrintSettings {
    var mode: PrintScaleMode = .shrinkToFit
    var centered = true
}

/// The view that gets printed (and previewed). It re-reads the print info every time
/// the panel changes paper, orientation or our accessory options.
final class PrintView: NSView {
    private let image: NSImage
    private let settings: PrintSettings

    init(image: NSImage, settings: PrintSettings) {
        self.image = image
        self.settings = settings
        super.init(frame: NSRect(x: 0, y: 0, width: 540, height: 720))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: 1)
        if let pi = NSPrintOperation.current?.printInfo {
            frame = NSRect(x: 0, y: 0,
                           width: pi.paperSize.width - pi.leftMargin - pi.rightMargin,
                           height: pi.paperSize.height - pi.topMargin - pi.bottomMargin)
        }
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect { bounds }

    override func draw(_ dirtyRect: NSRect) {
        let s = image.size
        let b = bounds.size
        guard s.width > 0, s.height > 0 else { return }
        let fit = min(b.width / s.width, b.height / s.height)
        let scale: CGFloat
        switch settings.mode {
        case .shrinkToFit: scale = min(1, fit)
        case .fitToPage: scale = fit
        case .actualSize: scale = 1
        case .fillPage: scale = max(b.width / s.width, b.height / s.height)
        }
        let size = NSSize(width: s.width * scale, height: s.height * scale)
        let origin = settings.centered
            ? NSPoint(x: (b.width - size.width) / 2, y: (b.height - size.height) / 2)
            : NSPoint(x: 0, y: b.height - size.height)
        NSBezierPath(rect: bounds).addClip()
        image.draw(in: NSRect(origin: origin, size: size), from: .zero, operation: .sourceOver,
                   fraction: 1, respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }
}

/// Extra controls shown inside the system print panel. Changing them refreshes the preview.
final class PrintOptionsController: NSViewController, NSPrintPanelAccessorizing {
    let settings: PrintSettings
    @objc dynamic var modeIndex: Int
    @objc dynamic var centered: Bool

    init(settings: PrintSettings) {
        self.settings = settings
        modeIndex = settings.mode.rawValue
        centered = settings.centered
        super.init(nibName: nil, bundle: nil)
        title = "Picture"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let label = NSTextField(labelWithString: "Scaling:")
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: PrintScaleMode.allCases.map(\.title))
        popup.selectItem(at: modeIndex)
        popup.target = self
        popup.action = #selector(modeChanged(_:))

        let check = NSButton(checkboxWithTitle: "Center on page", target: self, action: #selector(centerChanged(_:)))
        check.state = centered ? .on : .off

        let row = NSStackView(views: [label, popup])
        row.spacing = 8
        let stack = NSStackView(views: [row, check])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.frame.size = stack.fittingSize
        view = stack
    }

    @objc private func modeChanged(_ sender: NSPopUpButton) {
        modeIndex = sender.indexOfSelectedItem
        settings.mode = PrintScaleMode(rawValue: modeIndex) ?? .shrinkToFit
    }

    @objc private func centerChanged(_ sender: NSButton) {
        centered = sender.state == .on
        settings.centered = centered
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> {
        ["modeIndex", "centered"]
    }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        [[.itemName: "Scaling", .itemDescription: settings.mode.title],
         [.itemName: "Centered", .itemDescription: settings.centered ? "Yes" : "No"]]
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, NSPopoverDelegate {
    private var window: NSWindow!
    private let canvas = ImageCanvas()
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let printSettings = PrintSettings()
    private var printInfo: NSPrintInfo = {
        let pi = NSPrintInfo.shared.copy() as! NSPrintInfo
        pi.leftMargin = 18; pi.rightMargin = 18; pi.topMargin = 18; pi.bottomMargin = 18
        pi.isHorizontallyCentered = false
        pi.isVerticallyCentered = false
        return pi
    }()

    private var files: [URL] = []
    private var index = 0
    private var currentImage: NSImage?

    private let strip = ThumbnailStrip()
    private var stripHeight: NSLayoutConstraint!
    private let infoBox = NSStackView()
    private let infoLabel = NSTextField(labelWithString: "")
    private var slideshowTimer: Timer?
    private var showStrip = false
    private var showInfo = false
    private let toolbar = NSStackView()
    private let editBar = NSStackView()
    private var cropButton: NSButton!
    private let annotBar = NSStackView()
    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private let colorWell = NSColorWell()
    private let widthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let widthValues: [CGFloat] = [2, 4, 7, 12]
    private var undoStack: [NSImage] = []
    private var edited = false
    private var adjustBase: NSImage?
    private var adjustApplied = false
    private var adjustPopover: NSPopover?
    private var adjustButton: NSButton!
    private var slideshowButton: NSButton!
    private var infoButton: NSButton!
    private var thumbsButton: NSButton!

    // MARK: Launch

    private var didSetUp = false

    /// Build UI once. Called from willFinishLaunching *and* from open(_:), because
    /// Finder's "open file" event can arrive before didFinishLaunching.
    private func setUpIfNeeded() {
        guard !didSetUp else { return }
        didSetUp = true
        buildMenu()
        buildWindow()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        setUpIfNeeded()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [self] in
            if files.isEmpty { openPanel() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { open(url) }
    }

    // MARK: Window

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Picture Viewer"
        window.minSize = NSSize(width: 960, height: 280)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("MainWindow")

        let content = NSView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.onDrop = { [weak self] url in self?.open(url) }
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.isHidden = true
        strip.onSelect = { [weak self] i in
            guard let self, self.files.indices.contains(i) else { return }
            self.goTo(i)
        }
        content.addSubview(canvas)
        content.addSubview(strip)
        stripHeight = strip.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: strip.topAnchor),
            strip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stripHeight,
        ])

        infoLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        infoLabel.textColor = .white
        infoBox.addArrangedSubview(infoLabel)
        infoBox.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        infoBox.wantsLayer = true
        infoBox.layer?.backgroundColor = NSColor(white: 0, alpha: 0.7).cgColor
        infoBox.layer?.cornerRadius = 8
        infoBox.isHidden = true
        infoBox.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(infoBox)
        infoBox.topAnchor.constraint(equalTo: content.topAnchor, constant: 56).isActive = true
        infoBox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12).isActive = true

        func tool(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton()
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.contentTintColor = NSColor(white: 1, alpha: 0.85)
            b.toolTip = tip
            b.target = self
            b.action = action
            b.focusRingType = .none
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
            b.heightAnchor.constraint(equalToConstant: 28).isActive = true
            return b
        }
        slideshowButton = tool("play.fill", "Start slideshow (Space)", #selector(toggleSlideshow))
        infoButton = tool("info.circle", "Show info (I)", #selector(toggleInfo))
        thumbsButton = tool("square.grid.3x1.below.line.grid.1x2", "Show thumbnails (T)", #selector(toggleThumbnails))
        toolbar.setViews([
            tool("rotate.left", "Rotate left (⌘[)", #selector(rotateLeft)),
            tool("rotate.right", "Rotate right (⌘])", #selector(rotateRight)),
            tool("minus.magnifyingglass", "Zoom out (⌘-)", #selector(zoomOut)),
            tool("plus.magnifyingglass", "Zoom in (⌘+)", #selector(zoomIn)),
            tool("arrow.up.left.and.down.right.magnifyingglass", "Fit to window (⌘0)", #selector(fitToWindow)),
            slideshowButton, infoButton, thumbsButton,
            tool("doc.on.doc", "Copy image (⌘C)", #selector(copyImage)),
            tool("pencil", "Rename (⌘E)", #selector(renameFile)),
            tool("trash", "Move to Trash (⌘⌫)", #selector(moveToTrash)),
        ], in: .leading)
        toolbar.spacing = 2
        toolbar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        toolbar.layer?.cornerRadius = 10
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(toolbar)
        toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 12).isActive = true
        toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12).isActive = true

        cropButton = tool("crop", "Crop: drag a region, then click again to apply (⌘K)", #selector(cropAction))
        adjustButton = tool("slider.horizontal.3", "Adjust brightness / contrast / saturation", #selector(showAdjust))
        editBar.setViews([
            cropButton,
            tool("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip horizontally", #selector(flipHorizontal)),
            tool("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip vertically", #selector(flipVertical)),
            adjustButton,
            tool("arrow.uturn.backward", "Undo (⌘Z)", #selector(undoEdit)),
            tool("square.and.arrow.down", "Save (⌘S)", #selector(saveImage)),
            tool("square.and.arrow.down.on.square", "Save a copy… (⇧⌘S)", #selector(saveCopy)),
        ], in: .leading)
        editBar.spacing = 2
        editBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        editBar.wantsLayer = true
        editBar.layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        editBar.layer?.cornerRadius = 10
        editBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(editBar)
        editBar.topAnchor.constraint(equalTo: toolbar.topAnchor).isActive = true
        editBar.trailingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: -8).isActive = true
        canvas.onCropModeChange = { [weak self] in
            guard let self else { return }
            self.cropButton.contentTintColor = self.canvas.cropMode
                ? .controlAccentColor : NSColor(white: 1, alpha: 0.85)
        }
        canvas.onEscape = { [weak self] in
            self?.canvas.cropMode = false
            self?.canvas.tool = .none
        }

        let toolDefs: [(AnnotationTool, String, String)] = [
            (.line, "line.diagonal", "Line"), (.arrow, "arrow.up.right", "Arrow"),
            (.rect, "rectangle", "Rectangle"), (.ellipse, "circle", "Circle / ellipse"),
            (.pen, "pencil.tip", "Freehand pen"), (.text, "textformat", "Text"),
        ]
        var annotViews: [NSView] = []
        for (t, symbol, name) in toolDefs {
            let b = tool(symbol, name + " (click again to turn off)", #selector(selectTool(_:)))
            b.tag = t.rawValue
            toolButtons[t] = b
            annotViews.append(b)
        }
        colorWell.color = .systemRed
        colorWell.target = self
        colorWell.action = #selector(styleChanged)
        colorWell.toolTip = "Annotation color"
        colorWell.widthAnchor.constraint(equalToConstant: 32).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 22).isActive = true
        widthPopup.addItems(withTitles: ["Thin", "Medium", "Thick", "Heavy"])
        widthPopup.selectItem(at: 1)
        widthPopup.controlSize = .small
        widthPopup.font = .systemFont(ofSize: 11)
        widthPopup.toolTip = "Line width / text size"
        widthPopup.target = self
        widthPopup.action = #selector(styleChanged)
        annotViews += [colorWell, widthPopup]
        annotBar.setViews(annotViews, in: .leading)
        annotBar.spacing = 4
        annotBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        annotBar.wantsLayer = true
        annotBar.layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        annotBar.layer?.cornerRadius = 10
        annotBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(annotBar)
        annotBar.topAnchor.constraint(equalTo: toolbar.topAnchor).isActive = true
        annotBar.trailingAnchor.constraint(equalTo: editBar.leadingAnchor, constant: -8).isActive = true
        canvas.onToolChange = { [weak self] in
            guard let self else { return }
            for (t, b) in self.toolButtons {
                b.contentTintColor = self.canvas.tool == t ? .controlAccentColor : NSColor(white: 1, alpha: 0.85)
            }
        }
        canvas.onShape = { [weak self] shape in
            guard let self, let img = self.currentImage,
                  let out = ImageEdit.render(shape, color: self.canvas.annotationColor, onto: img) else { return }
            self.applyEdit(out, keepView: true)
        }
        canvas.onText = { [weak self] p in self?.addText(at: p) }
        styleChanged()

        configure(prevButton, symbol: "chevron.left.circle.fill", action: #selector(previous))
        configure(nextButton, symbol: "chevron.right.circle.fill", action: #selector(next))
        for b in [prevButton, nextButton] {
            content.addSubview(b)
            b.centerYAnchor.constraint(equalTo: canvas.centerYAnchor).isActive = true
        }
        prevButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14).isActive = true
        nextButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14).isActive = true

        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    private func configure(_ button: NSButton, symbol: String, action: Selector) {
        let config = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = NSColor(white: 1, alpha: 0.75)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.focusRingType = .none
    }

    // MARK: Opening / navigation

    @objc func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url { open(url) }
        else if files.isEmpty { NSApp.terminate(nil) }
    }

    private func open(_ url: URL) {
        setUpIfNeeded()
        guard confirmDiscard() else { return }
        edited = false
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            guard let first = items.filter(Formats.isImage).sorted(by: {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }).first else {
                NSSound.beep(); return
            }
            return open(first)
        }
        files = Formats.imagesInFolder(of: url)
        if !files.contains(url) { files.append(url) }
        index = files.firstIndex(of: url) ?? 0
        reloadStrip()
        show()
    }

    private func reloadStrip() {
        if showStrip { strip.load(files, selected: index) }
    }

    private func show() {
        guard files.indices.contains(index) else { return }
        let url = files[index]
        currentImage = NSImage(contentsOf: url)
        canvas.image = currentImage

        undoStack = []
        edited = false
        canvas.cropMode = false
        updateTitle()
        window.representedURL = url
        prevButton.isEnabled = index > 0
        nextButton.isEnabled = index < files.count - 1
        prevButton.alphaValue = prevButton.isEnabled ? 1 : 0.25
        nextButton.alphaValue = nextButton.isEnabled ? 1 : 0.25
        strip.select(index)
        updateInfo()
    }

    private func updateTitle() {
        guard files.indices.contains(index) else { return }
        var title = "\(files[index].lastPathComponent)  —  \(index + 1) / \(files.count)"
        if let rep = currentImage?.representations.first {
            let w = rep.pixelsWide, h = rep.pixelsHigh
            if w > 0, h > 0 { title += "  —  \(w)×\(h)" }
        } else {
            title += "  —  (cannot open)"
        }
        if edited { title += "  —  edited" }
        window.title = title
        window.isDocumentEdited = edited
    }

    // MARK: Editing

    private func confirmDiscard() -> Bool {
        guard edited else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved edits?"
        alert.informativeText = "This picture has changes that have not been saved."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmDiscard() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        confirmDiscard() ? .terminateNow : .terminateCancel
    }

    private func applyEdit(_ new: NSImage, keepView: Bool = false) {
        if let cur = currentImage { undoStack.append(cur) }
        currentImage = new
        if keepView { canvas.replaceImage(new) } else { canvas.image = new }
        edited = true
        updateTitle()
        updateInfo()
    }

    /// Make the current view rotation permanent in the working image.
    private func bakeRotation() {
        if canvas.quarterTurns != 0, let r = canvas.rotatedImage { applyEdit(r) }
    }

    @objc func undoEdit() {
        guard let prev = undoStack.popLast() else { NSSound.beep(); return }
        currentImage = prev
        canvas.image = prev
        edited = !undoStack.isEmpty
        updateTitle()
        updateInfo()
    }

    @objc func flipHorizontal() { flip(horizontal: true) }
    @objc func flipVertical() { flip(horizontal: false) }

    private func flip(horizontal: Bool) {
        bakeRotation()
        guard let img = currentImage else { return }
        applyEdit(ImageEdit.flip(img, horizontal: horizontal), keepView: true)
    }

    @objc func cropAction() {
        guard currentImage != nil else { NSSound.beep(); return }
        if !canvas.cropMode {
            bakeRotation()
            canvas.cropMode = true
        } else if let r = canvas.cropRectInImage, let img = currentImage, let out = ImageEdit.crop(img, to: r) {
            canvas.cropMode = false
            applyEdit(out)
        } else {
            canvas.cropMode = false
        }
    }

    @objc func selectTool(_ sender: NSButton) {
        guard currentImage != nil, let t = AnnotationTool(rawValue: sender.tag) else { NSSound.beep(); return }
        if canvas.tool == t { canvas.tool = .none; return }
        canvas.cropMode = false
        bakeRotation()
        canvas.tool = t
    }

    @objc private func styleChanged() {
        canvas.annotationColor = colorWell.color
        canvas.annotationWidth = widthValues[max(0, widthPopup.indexOfSelectedItem)]
    }

    private func addText(at point: NSPoint) {
        guard let img = currentImage else { return }
        let alert = NSAlert()
        alert.messageText = "Add text"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        let size = canvas.annotationWidth * 6 * ImageEdit.strokeScale(img.size)
        if let out = ImageEdit.renderText(field.stringValue, at: point, color: canvas.annotationColor,
                                          fontSize: size, onto: img) {
            applyEdit(out, keepView: true)
        }
    }

    @objc func showAdjust() {
        guard currentImage != nil else { NSSound.beep(); return }
        canvas.cropMode = false
        canvas.tool = .none
        bakeRotation()
        guard let base = currentImage else { return }
        adjustBase = base
        adjustApplied = false
        let controller = AdjustController()
        controller.onChange = { [weak self] b, c, s in
            guard let self, let base = self.adjustBase,
                  let out = ImageEdit.adjust(base, brightness: b, contrast: c, saturation: s) else { return }
            self.canvas.replaceImage(out)
        }
        controller.onApply = { [weak self] b, c, s in
            guard let self, let base = self.adjustBase else { return }
            self.adjustApplied = true
            self.adjustPopover?.close()
            if let out = ImageEdit.adjust(base, brightness: b, contrast: c, saturation: s) {
                self.applyEdit(out, keepView: true)
            }
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.delegate = self
        adjustPopover = popover
        popover.show(relativeTo: adjustButton.bounds, of: adjustButton, preferredEdge: .maxY)
    }

    func popoverDidClose(_ notification: Notification) {
        if !adjustApplied, let cur = currentImage { canvas.replaceImage(cur) }
        adjustPopover = nil
    }

    @objc func saveImage() {
        guard files.indices.contains(index), let img = canvas.rotatedImage else { return }
        let url = files[index]
        guard ImageEdit.writableExtensions.contains(url.pathExtension.lowercased()) else { return saveCopy() }
        let alert = NSAlert()
        alert.messageText = "Overwrite \"\(url.lastPathComponent)\"?"
        alert.informativeText = "The original file will be replaced. Use Save a Copy to keep it."
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let data = ImageEdit.encode(img, as: url.pathExtension) else { NSSound.beep(); return }
        do {
            try data.write(to: url, options: .atomic)
            edited = false
            reloadStrip()
            show()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func saveCopy() {
        guard files.indices.contains(index), let img = canvas.rotatedImage else { NSSound.beep(); return }
        let src = files[index]
        let ext = ImageEdit.writableExtensions.contains(src.pathExtension.lowercased())
            ? src.pathExtension.lowercased() : "png"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.directoryURL = src.deletingLastPathComponent()
        panel.nameFieldStringValue = src.deletingPathExtension().lastPathComponent + " edited." + ext
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        guard let data = ImageEdit.encode(img, as: dest.pathExtension) else { NSSound.beep(); return }
        do {
            try data.write(to: dest, options: .atomic)
            edited = false
            open(dest)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func updateInfo() {
        guard showInfo, files.indices.contains(index) else { return }
        let rep = currentImage?.representations.first
        let px = rep.flatMap { $0.pixelsWide > 0 && $0.pixelsHigh > 0 ? ($0.pixelsWide, $0.pixelsHigh) : nil }
        infoLabel.stringValue = ImageInfo.lines(for: files[index], pixelSize: px).joined(separator: "\n")
    }

    // MARK: Rotate / slideshow / panels / rename / copy

    @objc func showAbout() {
        let built = Bundle.main.object(forInfoDictionaryKey: "PVBuildDate") as? String ?? "unknown"
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Picture Viewer",
            .applicationVersion: "Built \(built)",
            .version: "",
        ])
    }

    @objc func rotateLeft() { canvas.rotate(by: -1) }
    @objc func rotateRight() { canvas.rotate(by: 1) }

    @objc func toggleInfo() {
        showInfo.toggle()
        infoBox.isHidden = !showInfo
        infoButton.contentTintColor = showInfo ? .controlAccentColor : NSColor(white: 1, alpha: 0.85)
        updateInfo()
    }

    @objc func toggleThumbnails() {
        showStrip.toggle()
        strip.isHidden = !showStrip
        stripHeight.constant = showStrip ? 72 : 0
        thumbsButton.contentTintColor = showStrip ? .controlAccentColor : NSColor(white: 1, alpha: 0.85)
        if showStrip { strip.load(files, selected: index) }
    }

    @objc func toggleSlideshow() {
        if let t = slideshowTimer {
            t.invalidate(); slideshowTimer = nil
            slideshowButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            slideshowButton.toolTip = "Start slideshow (Space)"
        } else {
            guard files.count > 1 else { NSSound.beep(); return }
            slideshowTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                guard let self, !self.edited else { return }
                self.index = (self.index + 1) % self.files.count
                self.show()
            }
            slideshowButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            slideshowButton.toolTip = "Stop slideshow (Space)"
        }
    }

    @objc func copyImage() {
        guard let image = canvas.rotatedImage else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    @objc func renameFile() {
        guard files.indices.contains(index) else { return }
        let url = files[index]
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: url.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != url.lastPathComponent, !name.contains("/") else { return }
        let dest = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            files[index] = dest
            reloadStrip()
            show()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func goTo(_ i: Int) {
        guard files.indices.contains(i), i != index, confirmDiscard() else { return }
        index = i
        show()
    }

    @objc func previous() { goTo(index - 1) }
    @objc func next() { goTo(index + 1) }
    @objc func first() { goTo(0) }
    @objc func last() { goTo(files.count - 1) }
    @objc func fitToWindow() { canvas.fit() }
    @objc func actualSize() { canvas.actualSize() }
    @objc func zoomIn() { canvas.zoomBy(1.25) }
    @objc func zoomOut() { canvas.zoomBy(0.8) }

    @objc func revealInFinder() {
        guard files.indices.contains(index) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([files[index]])
    }

    @objc func moveToTrash() {
        guard files.indices.contains(index) else { return }
        let url = files[index]
        NSWorkspace.shared.recycle([url]) { [self] _, error in
            guard error == nil else { NSSound.beep(); return }
            files.remove(at: index)
            if files.isEmpty {
                currentImage = nil; canvas.image = nil; window.title = "Picture Viewer"
                prevButton.isEnabled = false; nextButton.isEnabled = false
            } else {
                index = min(index, files.count - 1)
                reloadStrip()
                show()
            }
        }
    }

    // MARK: Printing

    @objc func pageSetup() {
        NSPageLayout().runModal(with: printInfo)
    }

    @objc func printImage() {
        guard let image = canvas.rotatedImage else { NSSound.beep(); return }
        // Pick the orientation that suits the picture; the user can still change it in the panel.
        printInfo.orientation = image.size.width > image.size.height ? .landscape : .portrait

        let view = PrintView(image: image, settings: printSettings)
        let op = NSPrintOperation(view: view, printInfo: printInfo)
        op.jobTitle = files[index].lastPathComponent
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.printPanel.options.formUnion([.showsPreview, .showsPaperSize, .showsOrientation])
        op.printPanel.addAccessoryController(PrintOptionsController(settings: printSettings))
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: Menu

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(previous): return index > 0
        case #selector(next): return index < files.count - 1
        case #selector(toggleSlideshow):
            item.title = slideshowTimer == nil ? "Start Slideshow" : "Stop Slideshow"
            return files.count > 1
        case #selector(toggleInfo):
            item.state = showInfo ? .on : .off
            return true
        case #selector(toggleThumbnails):
            item.state = showStrip ? .on : .off
            return true
        case #selector(renameFile), #selector(moveToTrash), #selector(revealInFinder):
            return !files.isEmpty
        case #selector(printImage), #selector(fitToWindow), #selector(actualSize),
             #selector(zoomIn), #selector(zoomOut), #selector(rotateLeft), #selector(rotateRight),
             #selector(copyImage), #selector(flipHorizontal), #selector(flipVertical),
             #selector(cropAction), #selector(showAdjust), #selector(saveImage), #selector(saveCopy):
            return currentImage != nil
        case #selector(undoEdit):
            return !undoStack.isEmpty
        default: return true
        }
    }

    private func buildMenu() {
        let main = NSMenu()
        func add(_ menu: NSMenu, _ title: String, _ sel: Selector?, _ key: String = "",
                 _ mods: NSEvent.ModifierFlags = .command) {
            let item = menu.addItem(withTitle: title, action: sel, keyEquivalent: key)
            item.keyEquivalentModifierMask = key.isEmpty ? [] : mods
            if sel != nil, sel != #selector(NSApplication.terminate(_:)),
               sel != #selector(NSWindow.performClose(_:)),
               sel != #selector(NSApplication.hide(_:)),
               sel != #selector(NSWindow.toggleFullScreen(_:)),
               sel != #selector(NSWindow.performMiniaturize(_:)) {
                item.target = self
            }
        }
        func submenu(_ title: String) -> NSMenu {
            let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            main.setSubmenu(m, for: item)
            return m
        }
        let arrow = { (c: Int) in String(UnicodeScalar(c)!) }

        let app = submenu("Picture Viewer")
        add(app, "About Picture Viewer", #selector(showAbout))
        app.addItem(.separator())
        add(app, "Hide Picture Viewer", #selector(NSApplication.hide(_:)), "h")
        app.addItem(.separator())
        add(app, "Quit Picture Viewer", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu("File")
        add(file, "Open…", #selector(openPanel), "o")
        file.addItem(.separator())
        add(file, "Page Setup…", #selector(pageSetup), "p", [.command, .shift])
        add(file, "Print…", #selector(printImage), "p")
        file.addItem(.separator())
        add(file, "Save…", #selector(saveImage), "s")
        add(file, "Save a Copy…", #selector(saveCopy), "s", [.command, .shift])
        add(file, "Rename…", #selector(renameFile), "e")
        add(file, "Show in Finder", #selector(revealInFinder), "r")
        add(file, "Move to Trash", #selector(moveToTrash), "\u{8}")
        file.addItem(.separator())
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w")

        let edit = submenu("Edit")
        add(edit, "Undo", #selector(undoEdit), "z")
        edit.addItem(.separator())
        add(edit, "Copy", #selector(copyImage), "c")
        edit.addItem(.separator())
        add(edit, "Crop", #selector(cropAction), "k")
        add(edit, "Flip Horizontally", #selector(flipHorizontal))
        add(edit, "Flip Vertically", #selector(flipVertical))
        add(edit, "Adjust Colors…", #selector(showAdjust))

        let view = submenu("View")
        add(view, "Previous Picture", #selector(previous), arrow(NSLeftArrowFunctionKey), [])
        add(view, "Next Picture", #selector(next), arrow(NSRightArrowFunctionKey), [])
        add(view, "First Picture", #selector(first), arrow(NSHomeFunctionKey), [])
        add(view, "Last Picture", #selector(last), arrow(NSEndFunctionKey), [])
        view.addItem(.separator())
        add(view, "Fit to Window", #selector(fitToWindow), "0")
        add(view, "Actual Size", #selector(actualSize), "1")
        add(view, "Zoom In", #selector(zoomIn), "+")
        add(view, "Zoom Out", #selector(zoomOut), "-")
        view.addItem(.separator())
        add(view, "Rotate Left", #selector(rotateLeft), "[")
        add(view, "Rotate Right", #selector(rotateRight), "]")
        view.addItem(.separator())
        add(view, "Show Info", #selector(toggleInfo), "i")
        add(view, "Show Thumbnails", #selector(toggleThumbnails), "t")
        add(view, "Start Slideshow", #selector(toggleSlideshow), " ", [])
        view.addItem(.separator())
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        let win = submenu("Window")
        add(win, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
