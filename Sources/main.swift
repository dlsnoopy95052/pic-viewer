import Carbon.HIToolbox
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
            if !preserveView {
                zoom = nil; offset = .zero; quarterTurns = 0; cropRect = nil; drawPoints = []
                annotations = []; selected = nil
            }
            baseCG = image.flatMap { ImageEdit.cgImage($0) }
            needsDisplay = true
        }
    }
    private var preserveView = false
    private var baseCG: CGImage?
    private var baseInfo: (cg: CGImage, size: NSSize)? {
        guard let cg = baseCG, let image else { return nil }
        return (cg, image.size)
    }
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
            if tool != .none { cropMode = false; selected = nil }
            drawPoints = []
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            onToolChange?()
        }
    }
    var annotationColor = NSColor.systemRed
    var annotationWidth: CGFloat = 4
    var annotationBackground: NSColor?
    var annotationFont = ""
    var annotationBold = true
    var annotationItalic = false
    private var drawPoints: [NSPoint] = []
    var onShape: ((Annotation) -> Void)?
    var onText: ((NSPoint) -> Void)?
    var onToolChange: (() -> Void)?

    // Placed annotations, selection and in-progress move / resize.
    var annotations: [Annotation] = [] { didSet { needsDisplay = true } }
    var selected: Int? {
        didSet { needsDisplay = true; onSelectionChange?() }
    }
    var onSelectionChange: (() -> Void)?
    /// Called once, right before an interactive change mutates `annotations` (push undo here).
    var onBeginChange: (() -> Void)?
    var onEditText: ((Int) -> Void)?
    private enum Drag { case none, move(NSPoint), handle(Int), rotate, width }
    private var drag = Drag.none
    private var dragStarted = false

    private func annotationIndex(at p: NSPoint) -> Int? {
        let k = zoom ?? fitScale
        let tol = 7 / max(k, 0.0001)
        for i in annotations.indices.reversed() {
            if ImageEdit.distance(from: p, to: annotations[i]) <= max(annotations[i].width / 2, tol) { return i }
        }
        return nil
    }

    private func handleIndex(at p: NSPoint) -> Int? {
        guard let i = selected, annotations.indices.contains(i), annotations[i].tool.hasHandles else { return nil }
        let a = annotations[i]
        let tol = 9 / max(zoom ?? fitScale, 0.0001)
        let c = ImageEdit.center(of: a)
        return a.points.firstIndex {
            let w = ImageEdit.rotated($0, about: c, by: a.angle)
            return hypot(w.x - p.x, w.y - p.y) <= tol
        }
    }

    /// Where the selected annotation's rotation knob sits, in image points.
    private func rotationKnob(for a: Annotation) -> NSPoint {
        let k = max(zoom ?? fitScale, 0.0001)
        let b = ImageEdit.bounds(of: a)
        let c = ImageEdit.center(of: a)
        return ImageEdit.rotated(NSPoint(x: c.x, y: b.maxY + 26 / k), about: c, by: a.angle)
    }

    /// The middle of what's currently on screen, in image points (clamped to the picture).
    func visibleCenterInImage() -> NSPoint? {
        guard let image else { return nil }
        let q = toImage(NSPoint(x: bounds.midX, y: bounds.midY))
        return NSPoint(x: min(max(q.x, 0), image.size.width), y: min(max(q.y, 0), image.size.height))
    }

    private func isOnWidthHandle(_ p: NSPoint) -> Bool {
        guard let i = selected, annotations.indices.contains(i), annotations[i].tool == .text else { return false }
        let q = ImageEdit.widthHandle(for: annotations[i])
        return hypot(q.x - p.x, q.y - p.y) <= 9 / max(zoom ?? fitScale, 0.0001)
    }

    private func isOnRotationKnob(_ p: NSPoint) -> Bool {
        guard let i = selected, annotations.indices.contains(i), annotations[i].tool.canRotate else { return false }
        let k = max(zoom ?? fitScale, 0.0001)
        let q = rotationKnob(for: annotations[i])
        return hypot(q.x - p.x, q.y - p.y) <= 9 / k
    }

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
        if event.keyCode == 53 {
            onEscape?()
        } else if event.keyCode == 51 || event.keyCode == 117, let i = selected, annotations.indices.contains(i) {
            onBeginChange?()
            annotations.remove(at: i)
            selected = nil
        } else {
            super.keyDown(with: event)
        }
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
        selected = nil
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
        let iw = image.size.width, ih = image.size.height
        for a in annotations {
            ImageEdit.draw(a, k: scale, base: baseInfo) {
                NSPoint(x: ($0.x - iw / 2) * scale, y: ($0.y - ih / 2) * scale)
            }
        }
        ctx.restoreGState()

        if let i = selected, quarterTurns == 0, annotations.indices.contains(i) {
            let a = annotations[i]
            let ir = imageRect
            func v(_ q: NSPoint) -> NSPoint { NSPoint(x: ir.minX + q.x * scale, y: ir.minY + q.y * scale) }
            let b = ImageEdit.bounds(of: a)
            let vr = NSRect(origin: v(b.origin), size: NSSize(width: b.width * scale, height: b.height * scale))
                .insetBy(dx: -4, dy: -4)
            NSGraphicsContext.saveGraphicsState()
            if a.angle != 0 { ImageEdit.concatRotation(a.angle, about: v(ImageEdit.center(of: a))) }
            let box = NSBezierPath(rect: vr)
            box.lineWidth = 1
            box.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            box.stroke()
            if a.tool.canRotate {
                let top = NSPoint(x: vr.midX, y: vr.maxY)
                let knob = NSPoint(x: vr.midX, y: vr.maxY + 22)
                let stem = NSBezierPath()
                stem.move(to: top); stem.line(to: knob)
                stem.lineWidth = 1
                stem.stroke()
                let dot = NSBezierPath(ovalIn: NSRect(x: knob.x - 5, y: knob.y - 5, width: 10, height: 10))
                NSColor.white.setFill(); dot.fill()
                NSColor.controlAccentColor.setStroke(); dot.lineWidth = 1.5; dot.stroke()
            }
            if a.tool == .text {
                let r = ImageEdit.textRect(a)
                let c = v(NSPoint(x: r.maxX, y: r.midY))
                let h = NSBezierPath(rect: NSRect(x: c.x - 3, y: c.y - 8, width: 6, height: 16))
                NSColor.white.setFill(); h.fill()
                NSColor.controlAccentColor.setStroke(); h.lineWidth = 1.5; h.stroke()
            }
            if a.tool.hasHandles {
                for q in a.points {
                    let c = v(q)
                    let h = NSBezierPath(rect: NSRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
                    NSColor.white.setFill(); h.fill()
                    NSColor.controlAccentColor.setStroke(); h.lineWidth = 1.5; h.stroke()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }

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
            let shape = Annotation(tool: tool, points: drawPoints,
                                   width: annotationWidth * ImageEdit.strokeScale(image.size),
                                   color: annotationColor)
            ImageEdit.draw(shape, k: k, base: baseInfo) { NSPoint(x: ir.minX + $0.x * k, y: ir.minY + $0.y * k) }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    func fit() { zoom = nil; offset = .zero; needsDisplay = true }

    /// The image with the current rotation baked in (for printing / copying).
    var flattenedImage: NSImage? {
        guard let image else { return nil }
        return annotations.isEmpty ? image : (ImageEdit.renderAll(annotations, onto: image) ?? image)
    }

    var rotatedImage: NSImage? {
        guard let image = flattenedImage else { return nil }
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
        drag = .none
        dragStarted = false
        guard tool != .none, drawPoints.count >= 2, let image else { drawPoints = []; return }
        let shape = Annotation(tool: tool, points: drawPoints,
                               width: annotationWidth * ImageEdit.strokeScale(image.size),
                               color: annotationColor)
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
        if let i = selected, annotations.indices.contains(i) {
            let p = toImage(convert(event.locationInWindow, from: nil))
            switch drag {
            case .move(let last):
                if !dragStarted { onBeginChange?(); dragStarted = true }
                let dx = p.x - last.x, dy = p.y - last.y
                annotations[i].points = annotations[i].points.map { NSPoint(x: $0.x + dx, y: $0.y + dy) }
                drag = .move(p)
                return
            case .handle(let h):
                if !dragStarted { onBeginChange?(); dragStarted = true }
                var a = annotations[i]
                guard a.points.count == 2 else { return }
                // Keep the opposite corner fixed in the picture, even when rotated.
                let j = 1 - h
                let opp = ImageEdit.rotated(a.points[j], about: ImageEdit.center(of: a), by: a.angle)
                var target = p
                if a.tool == .image, let img = a.image, img.size.height > 0 {
                    // Pictures keep their proportions while resizing.
                    let aspect = img.size.width / img.size.height
                    let dx = p.x - opp.x, dy = p.y - opp.y
                    let lx = dx * cos(a.angle) + dy * sin(a.angle)
                    let ly = -dx * sin(a.angle) + dy * cos(a.angle)
                    var w = abs(lx), hh = abs(ly)
                    if w > hh * aspect { hh = w / aspect } else { w = hh * aspect }
                    let sx: CGFloat = lx < 0 ? -1 : 1, sy: CGFloat = ly < 0 ? -1 : 1
                    let nx = sx * w, ny = sy * hh
                    target = NSPoint(x: opp.x + nx * cos(a.angle) - ny * sin(a.angle),
                                     y: opp.y + nx * sin(a.angle) + ny * cos(a.angle))
                }
                let c = NSPoint(x: (target.x + opp.x) / 2, y: (target.y + opp.y) / 2)
                a.points[h] = ImageEdit.rotated(target, about: c, by: -a.angle)
                a.points[j] = ImageEdit.rotated(opp, about: c, by: -a.angle)
                annotations[i] = a
                return
            case .width:
                if !dragStarted { onBeginChange?(); dragStarted = true }
                ImageEdit.setWrapWidth(&annotations[i], mouse: p)
                return
            case .rotate:
                if !dragStarted { onBeginChange?(); dragStarted = true }
                let c = ImageEdit.center(of: annotations[i])
                var angle = atan2(p.y - c.y, p.x - c.x) - .pi / 2
                if event.modifierFlags.contains(.shift) {
                    let step = CGFloat.pi / 12
                    angle = (angle / step).rounded() * step
                }
                annotations[i].angle = angle
                return
            case .none: break
            }
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
        if image != nil, quarterTurns == 0, !annotations.isEmpty {
            let p = toImage(convert(event.locationInWindow, from: nil))
            if isOnWidthHandle(p), let i = selected {
                if event.clickCount == 2 {
                    onBeginChange?()
                    annotations[i].boxWidth = nil     // double-click: back to no wrapping
                } else {
                    drag = .width
                }
                return
            }
            if isOnRotationKnob(p) {
                drag = .rotate
                return
            }
            if let h = handleIndex(at: p) {
                drag = .handle(h)
                return
            }
            if let hit = annotationIndex(at: p) {
                selected = hit
                if event.clickCount == 2, annotations[hit].tool == .text {
                    onEditText?(hit)
                } else {
                    drag = .move(p)
                }
                return
            }
            selected = nil
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
    case none, line, arrow, rect, ellipse, pen, text, mosaic, image

    /// Two-point shapes whose end points can be dragged.
    var hasHandles: Bool { [.line, .arrow, .rect, .ellipse, .mosaic, .image].contains(self) }

    /// Shapes that get a rotation knob (lines and arrows already point anywhere via their end points).
    var canRotate: Bool { [.rect, .ellipse, .text, .image].contains(self) }
}

/// A mark drawn over the picture. Points are in image points, origin bottom-left.
/// It stays editable (move / resize / restyle / delete) until the picture is flattened.
struct Annotation {
    var tool: AnnotationTool
    var points: [NSPoint]
    var width: CGFloat
    var color: NSColor
    var text = ""
    var fontSize: CGFloat = 0
    /// Radians, counter-clockwise, about the annotation's center (rect / ellipse / text only).
    var angle: CGFloat = 0
    /// Text only: wrap width of the text area in image points (nil = no wrapping) and fill behind it.
    var boxWidth: CGFloat?
    var background: NSColor?
    /// Font family ("" = system font) and traits.
    var fontName = ""
    var bold = true
    var italic = false
    /// Pasted picture (tool == .image); points are two opposite corners.
    var image: NSImage?
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

    static func path(for shape: Annotation, headScale: CGFloat,
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
        case .rect, .mosaic, .image: path.appendRect(box)
        case .ellipse: path.appendOval(in: box)
        case .pen:
            path.move(to: a)
            pts.dropFirst().forEach { path.line(to: $0) }
        case .text, .none: break
        }
        return path
    }

    static func font(for a: Annotation) -> NSFont {
        let fm = NSFontManager.shared
        var f = a.fontName.isEmpty
            ? NSFont.systemFont(ofSize: a.fontSize)
            : (fm.font(withFamily: a.fontName, traits: [], weight: 5, size: a.fontSize)
               ?? NSFont.systemFont(ofSize: a.fontSize))
        if a.bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
        if a.italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    private static func attributed(for a: Annotation) -> NSAttributedString {
        NSAttributedString(string: a.text, attributes: [.font: font(for: a), .foregroundColor: a.color])
    }

    /// Text layout in image points: padding, text area size and the attributed string.
    static func textLayout(_ a: Annotation) -> (pad: CGFloat, size: NSSize, str: NSAttributedString) {
        let str = attributed(for: a)
        let r = str.boundingRect(with: NSSize(width: a.boxWidth ?? 100_000, height: 100_000),
                                 options: [.usesLineFragmentOrigin])
        return (a.fontSize * 0.25, NSSize(width: a.boxWidth ?? ceil(r.width) + 2, height: ceil(r.height)), str)
    }

    /// Text box (including padding) in image points; the anchor point is its top-left.
    static func textRect(_ a: Annotation) -> NSRect {
        guard let p = a.points.first else { return .zero }
        let l = textLayout(a)
        let w = l.size.width + 2 * l.pad, h = l.size.height + 2 * l.pad
        return NSRect(x: p.x, y: p.y - h, width: w, height: h)
    }

    /// Wrap-width handle (right edge, vertically centered), in image points, rotation applied.
    static func widthHandle(for a: Annotation) -> NSPoint {
        let r = textRect(a)
        return rotated(NSPoint(x: r.maxX, y: r.midY), about: center(of: a), by: a.angle)
    }

    /// Set the wrap width from a mouse position, keeping the box's top-left corner fixed in the picture.
    static func setWrapWidth(_ a: inout Annotation, mouse m: NSPoint) {
        guard let p0 = a.points.first else { return }
        let top = rotated(p0, about: center(of: a), by: a.angle)
        let along = (m.x - top.x) * cos(a.angle) + (m.y - top.y) * sin(a.angle)
        a.boxWidth = max(along - 2 * a.fontSize * 0.25, a.fontSize)
        let r = textRect(a)                      // size under the new width, at the old anchor
        let d = NSPoint(x: r.width / 2, y: -r.height / 2)
        let rd = rotated(NSPoint(x: d.x, y: d.y), about: .zero, by: a.angle)
        a.points[0] = NSPoint(x: top.x - d.x + rd.x, y: top.y - d.y + rd.y)
    }

    static func bounds(of a: Annotation) -> NSRect {
        if a.tool == .text { return textRect(a) }
        let xs = a.points.map(\.x), ys = a.points.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .zero }
        return NSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).insetBy(dx: -a.width / 2, dy: -a.width / 2)
    }

    static func center(of a: Annotation) -> NSPoint {
        let r = bounds(of: a)
        return NSPoint(x: r.midX, y: r.midY)
    }

    static func rotated(_ p: NSPoint, about c: NSPoint, by angle: CGFloat) -> NSPoint {
        let dx = p.x - c.x, dy = p.y - c.y
        return NSPoint(x: c.x + dx * cos(angle) - dy * sin(angle), y: c.y + dx * sin(angle) + dy * cos(angle))
    }

    /// Rotates subsequent drawing about `c` in the current graphics context.
    static func concatRotation(_ angle: CGFloat, about c: NSPoint) {
        let t = NSAffineTransform()
        t.translateX(by: c.x, yBy: c.y)
        t.rotate(byRadians: angle)
        t.translateX(by: -c.x, yBy: -c.y)
        t.concat()
    }

    /// Draws into the current graphics context. `k` converts image points to drawing units.
    static func draw(_ a: Annotation, k: CGFloat, base: (cg: CGImage, size: NSSize)? = nil,
                     map: (NSPoint) -> NSPoint) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if a.tool == .mosaic {
            if let base { drawMosaic(a, base: base, map: map) }
            return
        }
        if a.angle != 0 { concatRotation(a.angle, about: map(center(of: a))) }
        if a.tool == .image {
            guard let img = a.image, a.points.count == 2 else { return }
            let p0 = map(a.points[0]), p1 = map(a.points[1])
            NSGraphicsContext.current?.imageInterpolation = .high
            img.draw(in: NSRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                                width: abs(p1.x - p0.x), height: abs(p1.y - p0.y)),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        if a.tool == .text {
            guard let p = a.points.first else { return }
            let o = map(p)
            let t = NSAffineTransform()
            t.translateX(by: o.x, yBy: o.y)
            t.scale(by: k)
            t.concat()
            let l = textLayout(a)
            let w = l.size.width + 2 * l.pad, h = l.size.height + 2 * l.pad
            if let bg = a.background {
                bg.setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: -h, width: w, height: h),
                             xRadius: l.pad, yRadius: l.pad).fill()
            }
            l.str.draw(with: NSRect(x: l.pad, y: -h + l.pad, width: l.size.width, height: l.size.height),
                       options: [.usesLineFragmentOrigin])
        } else {
            let path = path(for: a, headScale: k, map: map)
            path.lineWidth = a.width * k
            a.color.setStroke()
            path.stroke()
        }
    }

    /// Pixelates the part of the picture under the annotation. Block size follows the width setting.
    static func drawMosaic(_ a: Annotation, base: (cg: CGImage, size: NSSize), map: (NSPoint) -> NSPoint) {
        guard let ctx = NSGraphicsContext.current?.cgContext, a.points.count == 2,
              base.size.width > 0, base.size.height > 0 else { return }
        let (p, q) = (a.points[0], a.points[1])
        let box = NSRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(p.x - q.x), height: abs(p.y - q.y))
        let r = box.intersection(NSRect(origin: .zero, size: base.size))
        guard r.width >= 1, r.height >= 1 else { return }
        let k = CGFloat(base.cg.width) / base.size.width
        let px = CGRect(x: r.minX * k, y: (base.size.height - r.maxY) * k,
                        width: r.width * k, height: r.height * k).integral
        guard let crop = base.cg.cropping(to: px) else { return }
        let block = max(2, a.width * 3)
        let sw = max(1, Int((r.width / block).rounded(.up))), sh = max(1, Int((r.height / block).rounded(.up)))
        guard let small = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        small.interpolationQuality = .high
        small.draw(crop, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let tiny = small.makeImage() else { return }
        let a0 = map(r.origin), a1 = map(NSPoint(x: r.maxX, y: r.maxY))
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.draw(tiny, in: CGRect(x: min(a0.x, a1.x), y: min(a0.y, a1.y),
                                  width: abs(a1.x - a0.x), height: abs(a1.y - a0.y)))
        ctx.restoreGState()
    }

    /// Smallest distance (image points) from `p` to the annotation's outline.
    static func distance(from point: NSPoint, to a: Annotation) -> CGFloat {
        if a.tool == .image { return bounds(of: a).contains(rotated(point, about: center(of: a), by: -a.angle)) ? 0 : .greatestFiniteMagnitude }
        if a.tool == .mosaic { return bounds(of: a).contains(point) ? 0 : .greatestFiniteMagnitude }
        let p = a.angle == 0 ? point : rotated(point, about: center(of: a), by: -a.angle)
        if a.tool == .text { return textRect(a).contains(p) ? 0 : .greatestFiniteMagnitude }
        let flat = path(for: a, headScale: 1) { $0 }.flattened
        var best = CGFloat.greatestFiniteMagnitude
        var cur = NSPoint.zero
        var pts = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<flat.elementCount {
            switch flat.element(at: i, associatedPoints: &pts) {
            case .moveTo: cur = pts[0]
            case .lineTo:
                best = min(best, segmentDistance(p, cur, pts[0]))
                cur = pts[0]
            default: break
            }
        }
        return best
    }

    private static func segmentDistance(_ p: NSPoint, _ a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func renderAll(_ annotations: [Annotation], onto image: NSImage) -> NSImage? {
        rasterize(image) { ctx, s, _, cg in
            ctx.draw(cg, in: CGRect(origin: .zero, size: s))
            withGraphics(ctx) {
                for a in annotations { draw(a, k: 1, base: (cg, s)) { $0 } }
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
    private let bgWell = NSColorWell()
    private let bgLabel = NSTextField(labelWithString: "Bg")
    private let noBgButton = NSButton()
    private let textBar = NSStackView()
    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let boldButton = NSButton()
    private let italicButton = NSButton()
    private var capturing = false
    private var hotKeyRef: EventHotKeyRef?
    private var copyCaptures: Bool {
        get { UserDefaults.standard.bool(forKey: "copyCaptures") }
        set { UserDefaults.standard.set(newValue, forKey: "copyCaptures") }
    }
    private var undoStack: [(image: NSImage?, annotations: [Annotation])] = []
    private var lastUndoWasStyle = false
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
        UserDefaults.standard.register(defaults: ["copyCaptures": true])
        registerCaptureHotKey()
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
            if files.isEmpty { window.makeKeyAndOrderFront(nil) }   // empty window; ⌘O or drop a file
        }
    }

    /// Stay running with no window so the global capture hot key keeps working; quit with ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        window.makeKeyAndOrderFront(nil)
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { open(url) }
    }

    // MARK: Window

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Picture Viewer"
        window.minSize = NSSize(width: 1040, height: 280)
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
            tool("camera.viewfinder", "Capture a screen area (⌥⌘4)", #selector(captureArea)),
            tool("rotate.left", "Rotate left (⌘[)", #selector(rotateLeft)),
            tool("rotate.right", "Rotate right (⌘])", #selector(rotateRight)),
            tool("minus.magnifyingglass", "Zoom out (⌘-)", #selector(zoomOut)),
            tool("plus.magnifyingglass", "Zoom in (⌘+)", #selector(zoomIn)),
            tool("arrow.up.left.and.down.right.magnifyingglass", "Fit to window (⌘0)", #selector(fitToWindow)),
            slideshowButton, infoButton, thumbsButton,
            tool("doc.on.doc", "Copy image (⌘C)", #selector(copyImage)),
            tool("doc.on.clipboard", "Paste picture (⌘V)", #selector(pasteImage)),
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
            self?.canvas.selected = nil
        }

        let toolDefs: [(AnnotationTool, String, String)] = [
            (.line, "line.diagonal", "Line"), (.arrow, "arrow.up.right", "Arrow"),
            (.rect, "rectangle", "Rectangle"), (.ellipse, "circle", "Circle / ellipse"),
            (.pen, "pencil.tip", "Freehand pen"), (.text, "textformat", "Text"),
            (.mosaic, "squareshape.split.3x3", "Mosaic (pixelate an area; width sets block size)"),
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
        widthPopup.toolTip = "Line width / text size / mosaic block size"
        widthPopup.target = self
        widthPopup.action = #selector(styleChanged)
        bgWell.color = .clear
        bgWell.target = self
        bgWell.action = #selector(styleChanged)
        bgWell.toolTip = "Text background color"
        bgWell.widthAnchor.constraint(equalToConstant: 32).isActive = true
        bgWell.heightAnchor.constraint(equalToConstant: 22).isActive = true
        bgLabel.font = .systemFont(ofSize: 11)
        bgLabel.textColor = NSColor(white: 1, alpha: 0.85)
        noBgButton.image = NSImage(systemSymbolName: "circle.slash", accessibilityDescription: "No background")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        noBgButton.isBordered = false
        noBgButton.imagePosition = .imageOnly
        noBgButton.contentTintColor = NSColor(white: 1, alpha: 0.85)
        noBgButton.toolTip = "No text background"
        noBgButton.target = self
        noBgButton.action = #selector(clearBackground)
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

        // Text-only options, in their own bar under the annotation tools.
        let wanted = ["Helvetica Neue", "Arial", "Times New Roman", "Georgia", "Verdana",
                      "Courier New", "Menlo", "Marker Felt", "Impact"]
        let available = Set(NSFontManager.shared.availableFontFamilies)
        fontPopup.addItems(withTitles: ["System"] + wanted.filter(available.contains))
        fontPopup.controlSize = .small
        fontPopup.font = .systemFont(ofSize: 11)
        fontPopup.toolTip = "Font"
        fontPopup.target = self
        fontPopup.action = #selector(styleChanged)
        for (b, symbol, tip) in [(boldButton, "bold", "Bold"), (italicButton, "italic", "Italic")] {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            b.setButtonType(.toggle)
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.toolTip = tip
            b.target = self
            b.action = #selector(styleChanged)
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        }
        boldButton.state = .on
        textBar.setViews([fontPopup, boldButton, italicButton, bgLabel, bgWell, noBgButton], in: .leading)
        textBar.spacing = 6
        textBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        textBar.wantsLayer = true
        textBar.layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        textBar.layer?.cornerRadius = 10
        textBar.isHidden = true
        textBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(textBar)
        textBar.topAnchor.constraint(equalTo: annotBar.bottomAnchor, constant: 6).isActive = true
        textBar.trailingAnchor.constraint(equalTo: annotBar.trailingAnchor).isActive = true
        updateFontButtonTints()

        canvas.onToolChange = { [weak self] in
            guard let self else { return }
            self.updateBackgroundControls()
            for (t, b) in self.toolButtons {
                b.contentTintColor = self.canvas.tool == t ? .controlAccentColor : NSColor(white: 1, alpha: 0.85)
            }
        }
        canvas.onShape = { [weak self] shape in
            guard let self else { return }
            self.pushUndo()
            self.canvas.annotations.append(shape)
            self.canvas.tool = .none
            self.canvas.selected = self.canvas.annotations.count - 1
        }
        canvas.onBeginChange = { [weak self] in self?.pushUndo() }
        canvas.onEditText = { [weak self] i in self?.editText(i) }
        canvas.onSelectionChange = { [weak self] in
            self?.syncStyleToSelection()
            self?.updateBackgroundControls()
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard confirmDiscard() else { return false }
        // Closing the last window quits the app, which would ask again.
        edited = false
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        confirmDiscard() ? .terminateNow : .terminateCancel
    }

    private func pushUndo(style: Bool = false) {
        if style && lastUndoWasStyle { return }
        lastUndoWasStyle = style
        undoStack.append((currentImage, canvas.annotations))
        edited = true
        updateTitle()
    }

    /// `new` replaces the picture and must already include any annotations (they are cleared).
    private func applyEdit(_ new: NSImage, keepView: Bool = false) {
        pushUndo()
        currentImage = new
        if keepView { canvas.replaceImage(new) } else { canvas.image = new }
        canvas.annotations = []
        canvas.selected = nil
        updateTitle()
        updateInfo()
    }

    /// Burn annotations and view rotation into the working image.
    private func flatten() {
        if canvas.quarterTurns != 0 || !canvas.annotations.isEmpty, let r = canvas.rotatedImage { applyEdit(r) }
    }

    /// Rotation can't be edited around, so bake it (and any annotations) before drawing tools.
    private func bakeRotation() {
        if canvas.quarterTurns != 0 { flatten() }
    }

    @objc func undoEdit() {
        guard let prev = undoStack.popLast(), let img = prev.image else { NSSound.beep(); return }
        lastUndoWasStyle = false
        currentImage = img
        if canvas.image?.size == img.size { canvas.replaceImage(img) } else { canvas.image = img }
        canvas.annotations = prev.annotations
        canvas.selected = nil
        edited = !undoStack.isEmpty
        updateTitle()
        updateInfo()
    }

    @objc func flipHorizontal() { flip(horizontal: true) }
    @objc func flipVertical() { flip(horizontal: false) }

    private func flip(horizontal: Bool) {
        flatten()
        guard let img = currentImage else { return }
        applyEdit(ImageEdit.flip(img, horizontal: horizontal), keepView: true)
    }

    @objc func cropAction() {
        guard currentImage != nil else { NSSound.beep(); return }
        if !canvas.cropMode {
            flatten()
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

    /// The background controls only matter for text.
    private func updateBackgroundControls() {
        var show = canvas.tool == .text
        if let i = canvas.selected, canvas.annotations.indices.contains(i) {
            show = show || canvas.annotations[i].tool == .text
        }
        textBar.isHidden = !show
    }

    private func updateFontButtonTints() {
        for b in [boldButton, italicButton] {
            b.contentTintColor = b.state == .on ? .controlAccentColor : NSColor(white: 1, alpha: 0.85)
        }
    }

    @objc private func clearBackground() {
        bgWell.color = .clear
        styleChanged()
    }

    @objc private func styleChanged() {
        canvas.annotationBackground = bgWell.color.alphaComponent > 0 ? bgWell.color : nil
        canvas.annotationFont = fontPopup.indexOfSelectedItem > 0 ? fontPopup.titleOfSelectedItem ?? "" : ""
        canvas.annotationBold = boldButton.state == .on
        canvas.annotationItalic = italicButton.state == .on
        updateFontButtonTints()
        canvas.annotationColor = colorWell.color
        canvas.annotationWidth = widthValues[max(0, widthPopup.indexOfSelectedItem)]
        guard let i = canvas.selected, canvas.annotations.indices.contains(i), let img = currentImage,
              canvas.annotations[i].tool != .image else { return }
        pushUndo(style: true)
        let scale = ImageEdit.strokeScale(img.size)
        canvas.annotations[i].color = canvas.annotationColor
        canvas.annotations[i].width = canvas.annotationWidth * scale
        if canvas.annotations[i].tool == .text {
            canvas.annotations[i].fontSize = canvas.annotationWidth * 6 * scale
            canvas.annotations[i].background = canvas.annotationBackground
            canvas.annotations[i].fontName = canvas.annotationFont
            canvas.annotations[i].bold = canvas.annotationBold
            canvas.annotations[i].italic = canvas.annotationItalic
        }
    }

    /// Show the selected annotation's color / width in the style controls.
    private func syncStyleToSelection() {
        lastUndoWasStyle = false
        guard let i = canvas.selected, canvas.annotations.indices.contains(i), let img = currentImage else { return }
        let a = canvas.annotations[i]
        let w = (a.tool == .text ? a.fontSize / 6 : a.width) / ImageEdit.strokeScale(img.size)
        let nearest = widthValues.indices.min { abs(widthValues[$0] - w) < abs(widthValues[$1] - w) } ?? 1
        colorWell.color = a.color
        widthPopup.selectItem(at: nearest)
        canvas.annotationColor = a.color
        canvas.annotationWidth = widthValues[nearest]
        if a.tool == .text {
            bgWell.color = a.background ?? .clear
            canvas.annotationBackground = a.background
            fontPopup.selectItem(withTitle: a.fontName.isEmpty ? "System" : a.fontName)
            boldButton.state = a.bold ? .on : .off
            italicButton.state = a.italic ? .on : .off
            canvas.annotationFont = a.fontName
            canvas.annotationBold = a.bold
            canvas.annotationItalic = a.italic
            updateFontButtonTints()
        }
    }

    private func promptText(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Press Return for a new line."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.string = initial
        scroll.documentView = textView
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = textView
        guard alert.runModal() == .alertFirstButtonReturn, !textView.string.isEmpty else { return nil }
        return textView.string
    }

    private func addText(at point: NSPoint) {
        guard let img = currentImage, let text = promptText(title: "Add text", initial: "") else {
            canvas.tool = .none
            return
        }
        pushUndo()
        let scale = ImageEdit.strokeScale(img.size)
        canvas.annotations.append(Annotation(tool: .text, points: [point], width: canvas.annotationWidth * scale,
                                             color: canvas.annotationColor, text: text,
                                             fontSize: canvas.annotationWidth * 6 * scale,
                                             background: canvas.annotationBackground,
                                             fontName: canvas.annotationFont,
                                             bold: canvas.annotationBold, italic: canvas.annotationItalic))
        canvas.tool = .none
        canvas.selected = canvas.annotations.count - 1
    }

    private func editText(_ index: Int) {
        guard canvas.annotations.indices.contains(index),
              let text = promptText(title: "Edit text", initial: canvas.annotations[index].text),
              text != canvas.annotations[index].text else { return }
        pushUndo()
        canvas.annotations[index].text = text
    }

    @objc func showAdjust() {
        guard currentImage != nil else { NSSound.beep(); return }
        canvas.cropMode = false
        canvas.tool = .none
        flatten()
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
        // Pasted pictures only exist in a temp folder, so "Save" means "Save a Copy".
        guard ImageEdit.writableExtensions.contains(url.pathExtension.lowercased()), !isPasted(url) else {
            return saveCopy()
        }
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
        if isPasted(src) {
            panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            panel.nameFieldStringValue = src.deletingPathExtension().lastPathComponent + "." + ext
        } else {
            panel.directoryURL = src.deletingLastPathComponent()
            panel.nameFieldStringValue = src.deletingPathExtension().lastPathComponent + " edited." + ext
        }
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

    private static let pasteFolder = "PictureViewerPastes"

    private func isPasted(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == Self.pasteFolder
    }

    /// ⌘V: open a copied file, or an image copied from anywhere (screenshot, browser, another app).
    @objc func pasteImage() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let u = urls.first, FileManager.default.fileExists(atPath: u.path) {
            open(u)
            return
        }
        guard let img = NSImage(pasteboard: pb) else { NSSound.beep(); return }
        if currentImage != nil {
            addPastedImage(img)       // lands on top of the open picture as a movable, resizable layer
            return
        }
        guard let data = ImageEdit.encode(img, as: "png") else { NSSound.beep(); return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(Self.pasteFolder)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = dir.appendingPathComponent("Pasted \(fmt.string(from: Date())).png")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url)
            open(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func addPastedImage(_ img: NSImage) {
        canvas.cropMode = false
        canvas.tool = .none
        bakeRotation()
        guard let base = currentImage, img.size.width > 0, img.size.height > 0 else { return }
        // Start at a sensible size: never larger than 60% of the picture underneath.
        let k = min(1, base.size.width * 0.6 / img.size.width, base.size.height * 0.6 / img.size.height)
        let w = img.size.width * k, h = img.size.height * k
        let c = canvas.visibleCenterInImage() ?? NSPoint(x: base.size.width / 2, y: base.size.height / 2)
        pushUndo()
        canvas.annotations.append(Annotation(
            tool: .image,
            points: [NSPoint(x: c.x - w / 2, y: c.y - h / 2), NSPoint(x: c.x + w / 2, y: c.y + h / 2)],
            width: 0, color: .clear, image: img))
        canvas.selected = canvas.annotations.count - 1
    }

    /// Global ⌥⌘4, works while another app is in front (Carbon hot keys need no extra permission).
    private func registerCaptureHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.captureArea() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x50565748), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_4), UInt32(cmdKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    @objc func toggleCopyCaptures() { copyCaptures.toggle() }

    @objc func captureArea() {
        guard !capturing else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            let alert = NSAlert()
            alert.messageText = "Screen Recording permission needed"
            alert.informativeText = "Allow Picture Viewer in System Settings → Privacy & Security → Screen Recording, then reopen the app and try again."
            alert.runModal()
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PictureViewerCaptures")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = dir.appendingPathComponent("Capture \(fmt.string(from: Date())).png")

        if slideshowTimer != nil { toggleSlideshow() }
        capturing = true
        window.orderOut(nil)                    // keep our own window out of the shot
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-i", "-s", "-x", "-t", "png", url.path]   // area selection only, no sound
            task.terminationHandler = { _ in
                DispatchQueue.main.async {
                    self.capturing = false
                    self.window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    // No file means the selection was cancelled (Esc).
                    guard FileManager.default.fileExists(atPath: url.path) else { return }
                    if self.copyCaptures, let img = NSImage(contentsOf: url) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([img])
                    }
                    self.open(url)
                }
            }
            do { try task.run() } catch {
                capturing = false
                window.makeKeyAndOrderFront(nil)
                NSSound.beep()
            }
        }
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
        case #selector(pasteImage):
            let pb = NSPasteboard.general
            return NSImage.canInit(with: pb)
                || pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        case #selector(toggleCopyCaptures):
            item.state = copyCaptures ? .on : .off
            return true
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
        add(file, "Capture Screen Area", #selector(captureArea), "4", [.command, .option])
        add(file, "Copy Captures to Clipboard", #selector(toggleCopyCaptures))
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
        add(edit, "Paste", #selector(pasteImage), "v")
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
