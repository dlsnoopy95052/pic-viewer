import Cocoa
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
        didSet { zoom = nil; offset = .zero; needsDisplay = true }
    }
    /// nil means "fit to window".
    private(set) var zoom: CGFloat?
    private var offset = CGPoint.zero

    override var acceptsFirstResponder: Bool { true }

    private var fitScale: CGFloat {
        guard let s = image?.size, s.width > 0, s.height > 0 else { return 1 }
        return min(1, bounds.width / s.width, bounds.height / s.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.11, alpha: 1).setFill()
        bounds.fill()
        guard let image else { return }
        let scale = zoom ?? fitScale
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(x: bounds.midX - size.width / 2 + offset.x,
                          y: bounds.midY - size.height / 2 + offset.y,
                          width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    func fit() { zoom = nil; offset = .zero; needsDisplay = true }
    func actualSize() { zoom = 1; offset = .zero; needsDisplay = true }

    func zoomBy(_ factor: CGFloat) {
        let current = zoom ?? fitScale
        zoom = min(max(current * factor, 0.02), 32)
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) { zoomBy(1 + event.magnification) }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            zoomBy(exp(event.scrollingDeltaY * 0.02))
        } else if zoom != nil {
            offset.x += event.scrollingDeltaX
            offset.y -= event.scrollingDeltaY
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard zoom != nil else { return }
        offset.x += event.deltaX
        offset.y -= event.deltaY
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            if zoom == nil { actualSize() } else { fit() }
        }
    }
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
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
        window.minSize = NSSize(width: 360, height: 280)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("MainWindow")

        let content = NSView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        configure(prevButton, symbol: "chevron.left.circle.fill", action: #selector(previous))
        configure(nextButton, symbol: "chevron.right.circle.fill", action: #selector(next))
        for b in [prevButton, nextButton] {
            content.addSubview(b)
            b.centerYAnchor.constraint(equalTo: content.centerYAnchor).isActive = true
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
        show()
    }

    private func show() {
        guard files.indices.contains(index) else { return }
        let url = files[index]
        currentImage = NSImage(contentsOf: url)
        canvas.image = currentImage

        var title = "\(url.lastPathComponent)  —  \(index + 1) / \(files.count)"
        if let rep = currentImage?.representations.first {
            let w = rep.pixelsWide, h = rep.pixelsHigh
            if w > 0, h > 0 { title += "  —  \(w)×\(h)" }
        } else {
            title += "  —  (cannot open)"
        }
        window.title = title
        window.representedURL = url
        prevButton.isEnabled = index > 0
        nextButton.isEnabled = index < files.count - 1
        prevButton.alphaValue = prevButton.isEnabled ? 1 : 0.25
        nextButton.alphaValue = nextButton.isEnabled ? 1 : 0.25
    }

    @objc func previous() { if index > 0 { index -= 1; show() } }
    @objc func next() { if index < files.count - 1 { index += 1; show() } }
    @objc func first() { index = 0; show() }
    @objc func last() { index = max(0, files.count - 1); show() }
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
                show()
            }
        }
    }

    // MARK: Printing

    @objc func pageSetup() {
        NSPageLayout().runModal(with: printInfo)
    }

    @objc func printImage() {
        guard let image = currentImage else { NSSound.beep(); return }
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
        case #selector(printImage), #selector(fitToWindow), #selector(actualSize),
             #selector(zoomIn), #selector(zoomOut), #selector(moveToTrash), #selector(revealInFinder):
            return currentImage != nil || item.action == #selector(moveToTrash) && !files.isEmpty
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
        add(app, "Hide Picture Viewer", #selector(NSApplication.hide(_:)), "h")
        app.addItem(.separator())
        add(app, "Quit Picture Viewer", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu("File")
        add(file, "Open…", #selector(openPanel), "o")
        file.addItem(.separator())
        add(file, "Page Setup…", #selector(pageSetup), "p", [.command, .shift])
        add(file, "Print…", #selector(printImage), "p")
        file.addItem(.separator())
        add(file, "Show in Finder", #selector(revealInFinder), "r")
        add(file, "Move to Trash", #selector(moveToTrash), "\u{8}")
        file.addItem(.separator())
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w")

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
