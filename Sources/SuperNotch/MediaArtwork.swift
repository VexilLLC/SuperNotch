import AppKit
import Foundation
import ImageIO
import SwiftUI

/// Loads artwork through the media player's own scripting dictionary.
///
/// Music exposes the original artwork bytes directly. Spotify exposes the
/// cover URL, which is fetched asynchronously after the script call returns.
enum MediaArtworkLoader {
    private static let maximumImageBytes = 10 * 1024 * 1024
    private static let networkTimeout: TimeInterval = 8

    private static let imageSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = networkTimeout
        configuration.timeoutIntervalForResource = networkTimeout
        configuration.waitsForConnectivity = false
        configuration.urlCache = URLCache(memoryCapacity: 2 * 1024 * 1024, diskCapacity: 32 * 1024 * 1024)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()

    static func load(source: String, trackID: String) async -> NSImage? {
        switch source {
        case "Music":
            await loadMusicArtwork(trackID: trackID)
        case "Spotify":
            await loadSpotifyArtwork(trackID: trackID)
        default:
            nil
        }
    }

    private static func loadMusicArtwork(trackID: String) async -> NSImage? {
        let expectedID = appleScriptString(trackID)
        let identityCheck = trackID.isEmpty ? "" : """
                if (id of t as text) is not "\(expectedID)" then return missing value
        """
        let result = await MediaController.scriptData("""
        tell application "Music"
            set t to current track
            \(identityCheck)
            if (count of artworks of t) is 0 then return missing value
            return raw data of artwork 1 of t
        end tell
        """)

        guard result.1 == nil, let data = result.0, !data.isEmpty, data.count <= maximumImageBytes else {
            return nil
        }
        return await decodeData(data)
    }

    private static func loadSpotifyArtwork(trackID: String) async -> NSImage? {
        let expectedID = appleScriptString(trackID)
        let identityCheck = trackID.isEmpty ? "" : """
                if (id of t as text) is not "\(expectedID)" then return ""
        """
        let result = await MediaController.script("""
        tell application "Spotify"
            set t to current track
            \(identityCheck)
            return artwork url of t
        end tell
        """)

        guard result.1 == nil,
              let url = URL(string: result.0.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return await fetch(url: url)
    }

    private static func fetch(url: URL) async -> NSImage? {
        await withTaskGroup(of: NSImage?.self) { group in
            group.addTask {
                do {
                    try Task.checkCancellation()
                    var request = URLRequest(url: url)
                    request.timeoutInterval = networkTimeout
                    request.cachePolicy = .returnCacheDataElseLoad
                    let (bytes, response) = try await imageSession.bytes(for: request)
                    try Task.checkCancellation()
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode),
                          http.expectedContentLength < 0 || http.expectedContentLength <= Int64(maximumImageBytes) else {
                        return nil
                    }
                    var data = Data()
                    data.reserveCapacity(min(maximumImageBytes, max(0, Int(http.expectedContentLength))))
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard data.count < maximumImageBytes else { return nil }
                        data.append(byte)
                    }
                    return await decodeData(data)
                } catch {
                    return nil
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(networkTimeout * 1_000_000_000))
                } catch {
                    return nil
                }
                return nil
            }

            let image = await group.next() ?? nil
            group.cancelAll()
            return image
        }
    }

    static func decodeData(_ data: Data) async -> NSImage? {
        guard !data.isEmpty, data.count <= maximumImageBytes else {
            return nil
        }
        return await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }.value
    }

    private static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// A deterministic decoded-byte budget shared by automatic and scripted artwork.
/// Originals are never retained; a 512 px cover is enough for the 220 pt Retina player.
@MainActor
final class MediaArtworkCache {
    private struct Entry { let image: NSImage; let cost: Int }
    private var entries: [String: Entry] = [:]
    private var recency: [String] = []
    private(set) var totalCost = 0
    let costLimit: Int

    init(costLimit: Int = 4 * 1024 * 1024) { self.costLimit = max(0, costLimit) }

    func image(for key: String) -> NSImage? {
        guard let entry = entries[key] else { return nil }
        recency.removeAll { $0 == key }
        recency.append(key)
        return entry.image
    }

    func insert(_ image: NSImage, for key: String) {
        if let old = entries.removeValue(forKey: key) { totalCost -= old.cost }
        recency.removeAll { $0 == key }
        let cost = image.representations.reduce(0) { total, rep in
            let bytes = (rep as? NSBitmapImageRep).map { $0.bytesPerRow * $0.pixelsHigh }
                ?? (max(1, rep.pixelsWide) * max(1, rep.pixelsHigh) * 4)
            return total + bytes
        }
        guard cost > 0, cost <= costLimit else { return }
        while totalCost + cost > costLimit || entries.count >= 6 {
            guard let oldest = recency.first else { break }
            recency.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) { totalCost -= removed.cost }
        }
        entries[key] = Entry(image: image, cost: cost)
        recency.append(key)
        totalCost += cost
    }
}

struct MediaArtworkView: View {
    @ObservedObject private var media = MediaController.shared
    let size: CGFloat
    let cornerRadius: CGFloat
    let showsAppBadge: Bool

    init(size: CGFloat, cornerRadius: CGFloat, showsAppBadge: Bool = false) {
        self.size = size
        self.cornerRadius = cornerRadius
        self.showsAppBadge = showsAppBadge
    }

    var body: some View {
        ZStack {
            if let artwork = media.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                LinearGradient(
                    colors: [.indigo.opacity(0.6), .purple.opacity(0.3), .black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.36, weight: .light))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            // The source app, such as the browser playing a video.
            if showsAppBadge, let icon = media.appIcon {
                Image(nsImage: icon).resizable().frame(width: size * 0.36, height: size * 0.36)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: size * 0.1, y: size * 0.1)
                    .help(media.appName.map { "Playing in \($0)" } ?? "")
                    .accessibilityLabel(media.appName.map { "Playing in \($0)" } ?? "Source app")
            }
        }
    }
}
