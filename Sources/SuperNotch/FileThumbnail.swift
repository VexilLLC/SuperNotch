import AppKit
import Foundation
import ImageIO
import QuickLookThumbnailing
import SwiftUI

/// A small, cache-backed Quick Look thumbnail that falls back to the file's
/// native Finder icon while the thumbnail is being generated.
@MainActor
struct FileThumbnailView: View {
    let url: URL
    let size: CGFloat

    @State private var thumbnail: NSImage?

    private var cacheKey: FileThumbnailCacheKey {
        FileThumbnailLoader.cacheKey(for: url, size: requestedPointSize)
    }

    private var requestedPointSize: CGFloat {
        guard size.isFinite else { return 1 }
        return min(max(size, 1), FileThumbnailLoader.maximumPointSize)
    }

    var body: some View {
        Image(nsImage: thumbnail ?? nativeIcon)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityLabel(Text(url.lastPathComponent))
            // SwiftUI cancels this task when the view disappears or its id
            // changes. The loader also cancels the underlying QL request.
            .task(id: cacheKey) {
                thumbnail = nil
                let requestedURL = url
                let requestedKey = cacheKey
                guard let image = await FileThumbnailLoader.thumbnail(
                    for: requestedURL,
                    size: requestedPointSize,
                    cacheKey: requestedKey
                ) else { return }
                guard !Task.isCancelled else { return }
                thumbnail = image
            }
    }

    private var nativeIcon: NSImage {
        SmallIconCache.fileIcon(for: url.path, pixels: Int(requestedPointSize * 2))
    }
}

@MainActor
enum FileThumbnailLoader {
    static let maximumPointSize: CGFloat = 160
    private static let thumbnailScale: CGFloat = 2

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    static func cacheKey(for url: URL, size: CGFloat) -> FileThumbnailCacheKey {
        let standardizedURL = url.standardizedFileURL
        let values = try? standardizedURL.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey
        ])
        return FileThumbnailCacheKey(
            standardizedPath: standardizedURL.path,
            modificationDate: values?.contentModificationDate,
            fileSize: values?.fileSize,
            requestedSize: size
        )
    }

    static func thumbnail(
        for url: URL,
        size: CGFloat,
        cacheKey: FileThumbnailCacheKey
    ) async -> NSImage? {
        let key = cacheKey.nsCacheKey
        if let cached = cache.object(forKey: key) {
            return cached
        }

        // ImageIO reliably handles common raster formats even when Quick Look
        // only returns a generic file icon. It also lets us cap decoded image
        // memory before falling back to Quick Look for document formats.
        if let image = await loadImageThumbnail(for: url) {
            guard !Task.isCancelled else { return nil }
            cache.setObject(image, forKey: key, cost: imageCost(image))
            return image
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url.standardizedFileURL,
            size: CGSize(width: size, height: size),
            scale: thumbnailScale,
            representationTypes: [.thumbnail, .icon]
        )
        let completionGate = FileThumbnailCompletionGate<NSImage?>(cancellationValue: nil)

        let image: NSImage? = await withTaskCancellationHandler(operation: {
            guard !Task.isCancelled else {
                completionGate.cancel()
                return nil
            }
            return await withCheckedContinuation { continuation in
                guard completionGate.install(continuation), completionGate.begin() else { return }
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                    completionGate.finish(representation?.nsImage)
                }
            }
        }, onCancel: {
            completionGate.cancel()
            Task { @MainActor in
                QLThumbnailGenerator.shared.cancel(request)
            }
        })

        guard !Task.isCancelled, let image else { return nil }
        cache.setObject(image, forKey: key, cost: imageCost(image))
        return image
    }

    /// Creates a bounded thumbnail for raster image formats using ImageIO.
    /// This work runs off the main actor so large source files cannot block
    /// SwiftUI layout or interaction. A nil result means Quick Look should be
    /// tried next (or the caller should keep showing the native file icon).
    static func loadImageThumbnail(for url: URL) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let standardizedURL = url.standardizedFileURL
        let maximumPixelSize = Self.maximumPixelSize
        let thumbnailScale = Self.thumbnailScale
        let worker = Task.detached(priority: .utility) { () -> NSImage? in
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithURL(standardizedURL as CFURL, nil),
                  CGImageSourceGetCount(source) > 0 else {
                return nil
            }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  cgImage.width > 0,
                  cgImage.height > 0,
                  cgImage.width <= maximumPixelSize,
                  cgImage.height <= maximumPixelSize else {
                return nil
            }
            guard !Task.isCancelled else { return nil }
            return NSImage(
                cgImage: cgImage,
                size: NSSize(
                    width: CGFloat(cgImage.width) / thumbnailScale,
                    height: CGFloat(cgImage.height) / thumbnailScale
                )
            )
        }
        let image: NSImage? = await withTaskCancellationHandler(operation: {
            await worker.value
        }, onCancel: {
            worker.cancel()
        })
        guard !Task.isCancelled else { return nil }
        return image
    }

    private static let maximumPixelSize = 320

    private static func imageCost(_ image: NSImage) -> Int {
        var total = 0
        for representation in image.representations {
            let width = max(1, representation.pixelsWide)
            let height = max(1, representation.pixelsHigh)
            let (pixels, pixelsOverflowed) = width.multipliedReportingOverflow(by: height)
            let (bytes, bytesOverflowed) = pixels.multipliedReportingOverflow(by: 4)
            let (newTotal, totalOverflowed) = total.addingReportingOverflow(bytes)
            if pixelsOverflowed || bytesOverflowed || totalOverflowed { return .max }
            total = newTotal
        }
        return max(1, total)
    }
}

/// Coordinates the Quick Look callback and task cancellation so a suspended
/// continuation is resumed exactly once, even when cancellation wins a race
/// with a callback or happens before the continuation is installed.
final class FileThumbnailCompletionGate<Value>: @unchecked Sendable {
    private enum State {
        case waiting
        case started
        case cancelled
        case finished
    }

    private let lock = NSLock()
    private let cancellationValue: Value
    private var state = State.waiting
    private var continuation: CheckedContinuation<Value, Never>?

    init(cancellationValue: Value) {
        self.cancellationValue = cancellationValue
    }

    /// Installs the continuation. If cancellation already won, this resumes
    /// it immediately and returns false so the caller does not start a QL
    /// request that can no longer be observed.
    @discardableResult
    func install(_ continuation: CheckedContinuation<Value, Never>) -> Bool {
        lock.lock()
        guard state == .waiting else {
            lock.unlock()
            continuation.resume(returning: cancellationValue)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    /// Claims the right to start the underlying request. Cancellation that
    /// arrives before this point prevents generation entirely.
    @discardableResult
    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .waiting else { return false }
        state = .started
        return true
    }

    func finish(_ value: Value) {
        let continuation = takeContinuation(for: .finished, onlyIfActive: true)
        continuation?.resume(returning: value)
    }

    func cancel() {
        let continuation = takeContinuation(for: .cancelled, onlyIfActive: true)
        continuation?.resume(returning: cancellationValue)
    }

    private func takeContinuation(for nextState: State, onlyIfActive: Bool) -> CheckedContinuation<Value, Never>? {
        lock.lock()
        defer { lock.unlock() }
        if onlyIfActive && (state == .cancelled || state == .finished) { return nil }
        state = nextState
        let continuation = self.continuation
        self.continuation = nil
        return continuation
    }
}

struct FileThumbnailCacheKey: Hashable, Sendable {
    let standardizedPath: String
    let modificationDate: Date?
    let fileSize: Int?
    let requestedSize: CGFloat

    var nsCacheKey: NSString {
        let dateBits = modificationDate?.timeIntervalSinceReferenceDate.bitPattern.description ?? "nil"
        let fileSize = fileSize.map(String.init) ?? "nil"
        let sizeBits = requestedSize.bitPattern.description
        return NSString(string: "\(standardizedPath)\u{1F}\(dateBits)\u{1F}\(fileSize)\u{1F}\(sizeBits)")
    }
}
