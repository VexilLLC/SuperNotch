// Composes the README hero from the surfaces captured by ShowcaseDriver.
//
//   swift ComposeHero.swift --shots <dir> --out <file.png>
//
// Every pixel of app content comes from a real capture of a showcase instance;
// only the desktop behind it is drawn here.

import AppKit
import Foundation

let canvas = CGSize(width: 2560, height: 1440)
let menuBarHeight: CGFloat = 64

// MARK: - Arguments

var shotsDirectory = URL(fileURLWithPath: "docs/images/showcase")
var outputURL = URL(fileURLWithPath: "docs/images/hero.png")
var arguments = Array(CommandLine.arguments.dropFirst())
while let flag = arguments.first {
    arguments.removeFirst()
    switch flag {
    case "--shots": shotsDirectory = URL(fileURLWithPath: arguments.removeFirst())
    case "--out": outputURL = URL(fileURLWithPath: arguments.removeFirst())
    default:
        FileHandle.standardError.write(Data("unknown argument \(flag)\n".utf8))
        exit(2)
    }
}

func shot(_ name: String) -> NSImage? {
    let url = shotsDirectory.appendingPathComponent(name)
    guard let image = NSImage(contentsOf: url) else {
        FileHandle.standardError.write(Data("missing capture \(url.lastPathComponent)\n".utf8))
        return nil
    }
    return image
}

/// Rects are authored from the top-left; AppKit draws from the bottom-left.
func rect(top: CGFloat, left: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
    NSRect(x: left, y: canvas.height - top - height, width: width, height: height)
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// MARK: - Scene

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas.width),
    pixelsHigh: Int(canvas.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let context = NSGraphicsContext.current!.cgContext

let full = NSRect(origin: .zero, size: canvas)

// Desktop gradient.
NSGradient(colors: [color(0x070912), color(0x131038), color(0x241541)])?
    .draw(in: full, angle: 72)

/// A soft radial wash, used to light the wallpaper behind the app surfaces.
func glow(center: CGPoint, radius: CGFloat, hex: UInt32, alpha: CGFloat) {
    let colors = [color(hex, alpha: alpha).cgColor, color(hex, alpha: 0).cgColor] as CFArray
    guard let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors,
        locations: [0, 1]
    ) else { return }
    let point = CGPoint(x: center.x, y: canvas.height - center.y)
    context.drawRadialGradient(gradient, startCenter: point, startRadius: 0, endCenter: point, endRadius: radius, options: [])
}

glow(center: CGPoint(x: 1280, y: 120), radius: 1000, hex: 0x5B6BFF, alpha: 0.34)
glow(center: CGPoint(x: 2180, y: 980), radius: 900, hex: 0xE0519B, alpha: 0.20)
glow(center: CGPoint(x: 320, y: 1180), radius: 820, hex: 0x2FB8C6, alpha: 0.16)

// Menu bar.
color(0xFFFFFF, alpha: 0.07).setFill()
rect(top: 0, left: 0, width: canvas.width, height: menuBarHeight).fill()

func drawMenuBarText() {
    let menus: [(String, NSFont.Weight)] = [
        ("Finder", .bold), ("File", .regular), ("Edit", .regular),
        ("View", .regular), ("Go", .regular), ("Window", .regular), ("Help", .regular)
    ]
    var x: CGFloat = 52
    for (title, weight) in menus {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 25, weight: weight),
            .foregroundColor: color(0xFFFFFF, alpha: 0.88)
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: rect(top: 18, left: x, width: size.width, height: size.height).origin, withAttributes: attributes)
        x += size.width + 34
    }

    let clock = "Thu 9:41"
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 25, weight: .regular),
        .foregroundColor: color(0xFFFFFF, alpha: 0.88)
    ]
    let size = (clock as NSString).size(withAttributes: attributes)
    (clock as NSString).draw(at: rect(top: 18, left: canvas.width - size.width - 52, width: size.width, height: size.height).origin, withAttributes: attributes)
}
drawMenuBarText()

/// Draws a captured window with rounded corners and a cast shadow.
func drawWindow(_ image: NSImage, top: CGFloat, left: CGFloat, width: CGFloat, radius: CGFloat = 28) {
    let scale = width / image.size.width
    let height = image.size.height * scale
    let frame = rect(top: top, left: left, width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, alpha: 0.62)
    shadow.shadowBlurRadius = 70
    shadow.shadowOffset = NSSize(width: 0, height: -26)
    shadow.set()
    color(0x0B0D14).setFill()
    NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).addClip()
    image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    color(0xFFFFFF, alpha: 0.10).setStroke()
    let border = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
    border.lineWidth = 1.5
    border.stroke()
}

// The workspace sits behind, bleeding off the bottom edge.
if let workspace = shot("workspace-overview.png") {
    drawWindow(workspace, top: 596, left: 1168, width: 1290)
}

// The command palette floats in front of it.
if let palette = shot("palette.png") {
    drawWindow(palette, top: 706, left: 108, width: 1010, radius: 22)
}

// The island crowns the scene, hanging from the notch.
if let island = shot("island-home.png") {
    let scale: CGFloat = 1.2
    let size = CGSize(width: island.size.width * scale, height: island.size.height * scale)
    let frame = rect(top: 0, left: (canvas.width - size.width) / 2, width: size.width, height: size.height)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, alpha: 0.55)
    shadow.shadowBlurRadius = 60
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.set()
    island.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try data.write(to: outputURL)
print("wrote \(outputURL.path)")
