import Cocoa

// Usage: icon-from-png <input.png> <output.png>
// Turns artwork drawn on a plain background into a 1024x1024 app icon: finds the colored tile,
// cuts it out with rounded corners, and places it on the macOS icon grid (824pt tile) with a shadow.
let args = CommandLine.arguments
guard args.count == 3, let src = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: args[1]))) else {
    print("usage: icon-from-png <input.png> <output.png>"); exit(1)
}
let w = src.pixelsWide, h = src.pixelsHigh

// Bounding box of strongly saturated pixels = the tile (the background and its soft shadow are nearly white).
var minX = w, maxX = 0, minY = h, maxY = 0
for y in 0..<h { for x in 0..<w {
    guard let c = src.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
    if c.saturationComponent > 0.6 && c.brightnessComponent > 0.3 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
} }
var tileRect = NSRect(x: minX, y: h - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)   // bottom-left origin
tileRect = tileRect.insetBy(dx: 8, dy: 8)   // drop the anti-aliased white rim
print("tile:", tileRect)

let size = 1024
let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
NSGraphicsContext.current?.imageInterpolation = .high

let dest = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: dest, xRadius: 185, yRadius: 185)
NSGraphicsContext.current!.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill()
path.fill()
NSGraphicsContext.current!.restoreGraphicsState()

path.addClip()
let image = NSImage(size: NSSize(width: w, height: h))
image.addRepresentation(src)
image.draw(in: dest, from: tileRect, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
