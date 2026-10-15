import Cocoa

// Usage: make-icon <output.png>  — draws a 1024x1024 app icon.
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824pt rounded square centered in 1024.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.current!.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.white.setFill()
tilePath.fill()
NSGraphicsContext.current!.restoreGraphicsState()

NSGradient(colors: [NSColor(red: 0.22, green: 0.28, blue: 0.40, alpha: 1),
                    NSColor(red: 0.08, green: 0.10, blue: 0.17, alpha: 1)])!
    .draw(in: tilePath, angle: -90)

// Photo (white border like a print), slightly rotated.
let t = NSAffineTransform()
t.translateX(by: 512, yBy: 512)
t.rotate(byDegrees: -6)
t.translateX(by: -512, yBy: -512)
t.concat()

let photo = NSRect(x: 232, y: 262, width: 560, height: 500)
NSGraphicsContext.current!.saveGraphicsState()
let ps = NSShadow()
ps.shadowColor = NSColor(white: 0, alpha: 0.4)
ps.shadowBlurRadius = 30
ps.shadowOffset = NSSize(width: 0, height: -14)
ps.set()
NSColor(white: 0.97, alpha: 1).setFill()
NSBezierPath(roundedRect: photo, xRadius: 22, yRadius: 22).fill()
NSGraphicsContext.current!.restoreGraphicsState()

let inner = photo.insetBy(dx: 34, dy: 34)
let innerPath = NSBezierPath(roundedRect: inner, xRadius: 8, yRadius: 8)
NSGradient(colors: [NSColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1),
                    NSColor(red: 0.80, green: 0.92, blue: 1.0, alpha: 1)])!
    .draw(in: innerPath, angle: -90)

NSGraphicsContext.current!.saveGraphicsState()
innerPath.addClip()
// Sun
NSColor(red: 1.0, green: 0.82, blue: 0.25, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: inner.maxX - 170, y: inner.maxY - 150, width: 90, height: 90)).fill()
// Far mountain
let m1 = NSBezierPath()
m1.move(to: NSPoint(x: inner.minX, y: inner.minY))
m1.line(to: NSPoint(x: inner.minX, y: inner.minY + 130))
m1.line(to: NSPoint(x: inner.minX + 150, y: inner.minY + 260))
m1.line(to: NSPoint(x: inner.minX + 290, y: inner.minY + 120))
m1.line(to: NSPoint(x: inner.minX + 380, y: inner.minY + 190))
m1.line(to: NSPoint(x: inner.maxX, y: inner.minY + 90))
m1.line(to: NSPoint(x: inner.maxX, y: inner.minY))
m1.close()
NSColor(red: 0.36, green: 0.55, blue: 0.62, alpha: 1).setFill()
m1.fill()
// Near hill
let m2 = NSBezierPath()
m2.move(to: NSPoint(x: inner.minX, y: inner.minY))
m2.line(to: NSPoint(x: inner.minX, y: inner.minY + 50))
m2.curve(to: NSPoint(x: inner.maxX, y: inner.minY + 40),
         controlPoint1: NSPoint(x: inner.minX + 150, y: inner.minY + 150),
         controlPoint2: NSPoint(x: inner.midX + 120, y: inner.minY - 20))
m2.line(to: NSPoint(x: inner.maxX, y: inner.minY))
m2.close()
NSColor(red: 0.22, green: 0.55, blue: 0.38, alpha: 1).setFill()
m2.fill()
NSGraphicsContext.current!.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
