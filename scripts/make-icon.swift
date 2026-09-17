import AppKit
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let outer = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 190, yRadius: 190)
NSGradient(colors: [NSColor(deviceRed: 0.20, green: 0.52, blue: 1, alpha: 1), NSColor(deviceRed: 0.39, green: 0.25, blue: 0.84, alpha: 1)])!.draw(in: outer, angle: -65)
NSColor.white.withAlphaComponent(0.92).setStroke()
let screen = NSBezierPath(roundedRect: NSRect(x: 234, y: 292, width: 556, height: 440), xRadius: 70, yRadius: 70)
screen.lineWidth = 30; screen.stroke()
NSColor.white.withAlphaComponent(0.94).setFill()
NSBezierPath(roundedRect: NSRect(x: 378, y: 650, width: 268, height: 90), xRadius: 32, yRadius: 32).fill()
NSColor.white.withAlphaComponent(0.20).setFill()
NSBezierPath(roundedRect: NSRect(x: 275, y: 330, width: 474, height: 242), xRadius: 35, yRadius: 35).fill()
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
