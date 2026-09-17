import AppKit

/// AppKit supplies large multi-representation icons. Flattening them once prevents every list
/// update from retaining and redrawing full application/file icon resources for a 12–22 pt view.
@MainActor
enum SmallIconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()

    static func applicationIcon(for bundleIdentifier: String) -> NSImage? {
        let key = "app:\(bundleIdentifier)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        return cachedRaster(NSWorkspace.shared.icon(forFile: url.path), key: key, pixels: 24)
    }

    static func fileIcon(for path: String, pixels: Int = 44) -> NSImage {
        let key = "file:\(pixels):\(path)" as NSString
        if let image = cache.object(forKey: key) { return image }
        return cachedRaster(NSWorkspace.shared.icon(forFile: path), key: key, pixels: pixels)
    }

    private static func cachedRaster(_ source: NSImage, key: NSString, pixels: Int) -> NSImage {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return source }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        source.draw(
            in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.addRepresentation(representation)
        cache.setObject(image, forKey: key, cost: representation.bytesPerRow * pixels)
        return image
    }
}
