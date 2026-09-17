import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Single root for everything SuperNotch persists outside `UserDefaults`.
///
/// A showcase run is redirected into a throwaway container so generating
/// documentation screenshots never reads, writes, or deletes real user data.
enum SuperNotchStorage {
    static var baseDirectory: URL {
        if Showcase.isActive { return Showcase.containerURL }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SuperNotch", isDirectory: true)
    }
}

/// Deterministic demo content for documentation screenshots.
///
/// Enabled only by `SUPERNOTCH_SHOWCASE=1`, and inert in every normal launch.
/// `scripts/capture-showcase.sh` additionally runs a copy of the bundle under a
/// separate identifier, so the showcase instance also gets its own `UserDefaults`
/// domain and never disturbs the installed app's preferences.
enum Showcase {
    static let isActive = ProcessInfo.processInfo.environment["SUPERNOTCH_SHOWCASE"] == "1"

    /// Throwaway container replacing `~/Library/Application Support/SuperNotch`.
    static let containerURL: URL = {
        let override = ProcessInfo.processInfo.environment["SUPERNOTCH_SHOWCASE_CONTAINER"]
        let url = override.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SuperNotchShowcase", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static var sampleFilesURL: URL { containerURL.appendingPathComponent("SampleFiles", isDirectory: true) }

    /// Fictional track shown by the island's player.
    static let trackTitle = "Midnight Transit"
    static let trackArtist = "Neon Arcade"
    static let trackElapsed: Double = 71
    static let trackDuration: Double = 214

    // MARK: - Lifecycle

    /// Wipes the container and writes everything the stores read at init.
    /// Must run before any store touches disk.
    static func prepare() {
        guard isActive else { return }
        try? FileManager.default.removeItem(at: containerURL)
        try? FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sampleFilesURL, withIntermediateDirectories: true)
        writeSampleFiles()
        writeClipboardHistory()
    }

    /// Seeds the state that only exists in memory once the app is running.
    @MainActor static func activate() {
        guard isActive else { return }
        FileShelfStore.shared.createBasket(name: "Design")
        FileShelfStore.shared.createBasket(name: "Invoices")
        FileShelfStore.shared.selectBasket(ShelfBasket.mainID)
        FileShelfStore.shared.add(urls: sampleShelfURLs())
        MediaController.shared.applyShowcaseTrack(
            title: trackTitle,
            artist: trackArtist,
            artwork: artwork(),
            elapsed: trackElapsed,
            duration: trackDuration
        )
        for note in sampleNotes.reversed() { ProductivityStore.shared.saveNote(note) }
        listenForCommands()
    }

    // MARK: - Capture control

    /// Name the capture driver posts on, so screenshots do not depend on
    /// synthetic clicks landing on the right pixel.
    static let commandNotification = Notification.Name("com.vexil.supernotch.showcase.command")

    @MainActor private static func listenForCommands() {
        DistributedNotificationCenter.default().addObserver(
            forName: commandNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let command = note.object as? String else { return }
            MainActor.assumeIsolated { run(command) }
        }
    }

    @MainActor private static func run(_ command: String) {
        let parts = command.split(separator: ".").map(String.init)
        switch parts.first {
        case "island":
            guard parts.count > 1 else { return }
            if parts[1] == "collapse" { AppDelegate.shared?.setExpanded(false); return }
            if let tab = Int(parts[1]) { AppState.shared.islandTab = tab }
            AppDelegate.shared?.setExpanded(true)
        case "palette":
            CommandPaletteController.shared.show()
            if parts.count > 1, parts[1] == "clipboard" { CommandPaletteStore.shared.enterClipboard() }
        case "workspace":
            if parts.count > 1, let page = AppState.Page.allCases.first(where: { $0.rawValue.lowercased().replacingOccurrences(of: " ", with: "") == parts[1].lowercased() }) {
                AppState.shared.page = page
            }
            AppDelegate.shared?.openWorkspace()
        case "quit":
            NSApp.terminate(nil)
        default:
            break
        }
    }

    // MARK: - Sample files

    private static func sampleShelfURLs() -> [URL] {
        ["Launch-Poster.png", "Q3-Report.pdf", "IslandSurface.swift", "Roadmap.md", "Brand-Palette.png"]
            .map { sampleFilesURL.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func writeSampleFiles() {
        write(gradientPNG(size: CGSize(width: 1200, height: 800), colors: [.systemIndigo, .systemPink], caption: "LAUNCH"), to: "Launch-Poster.png")
        write(gradientPNG(size: CGSize(width: 900, height: 900), colors: [.systemTeal, .systemBlue], caption: nil), to: "Brand-Palette.png")
        write(reportPDF(), to: "Q3-Report.pdf")
        write(Data(sampleSwiftSource.utf8), to: "IslandSurface.swift")
        write(Data(sampleMarkdown.utf8), to: "Roadmap.md")
    }

    private static func write(_ data: Data?, to name: String) {
        guard let data else { return }
        try? data.write(to: sampleFilesURL.appendingPathComponent(name))
    }

    private static let sampleSwiftSource = """
    import SwiftUI

    /// A notch outline: concave shoulders flare into the menu bar.
    struct NotchShape: Shape {
        var topRadius: CGFloat
        var bottomRadius: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
                control: CGPoint(x: rect.minX + topRadius, y: rect.minY)
            )
            return path
        }
    }
    """

    private static let sampleNotes = [
        "Ship the island widgets page before the demo on Friday.",
        "Ask about the notch geometry on external displays.",
        "Palette extensions: URL actions land first, shell actions behind a toggle."
    ]

    private static let sampleMarkdown = """
    # Roadmap

    - [x] Notch-aware island geometry
    - [x] Clipboard history with tags
    - [ ] Multi-display placement presets
    - [ ] Shareable basket links
    """

    // MARK: - Clipboard

    private static func writeClipboardHistory() {
        let payloads = containerURL.appendingPathComponent("clipboard-payloads-v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: payloads, withIntermediateDirectories: true)

        var entries: [ClipboardEntry] = [
            entry(.text, "func shapeSize(expanded: Bool, tab: Int) -> CGSize", ago: 45,
                  app: "Xcode", bundle: "com.apple.dt.Xcode", tags: ["snippet"]),
            entry(.link, "https://developer.apple.com/documentation/swiftui/shape", ago: 180,
                  app: "Safari", bundle: "com.apple.Safari", pinned: true),
            entry(.text, "#5B8CFF", ago: 320, app: "Figma", bundle: "com.figma.Desktop", tags: ["brand"]),
            entry(.text, "git switch -c feature/island-widgets", ago: 640,
                  app: "Terminal", bundle: "com.apple.Terminal", tags: ["shell"]),
            entry(.richText, "Ship notes — island widgets, clipboard tags, port list", ago: 900,
                  app: "Notes", bundle: "com.apple.Notes"),
            entry(.text, "supernotch://palette?query=focus", ago: 1500,
                  app: "SuperNotch", bundle: "com.vexil.supernotch"),
            entry(.files, "", ago: 2400, app: "Finder", bundle: "com.apple.finder",
                  paths: [sampleFilesURL.appendingPathComponent("Q3-Report.pdf").path]),
            entry(.text, "The island expands on click and accepts file drops.", ago: 3300,
                  app: "Pages", bundle: "com.apple.iWork.Pages")
        ]

        if let image = gradientPNG(size: CGSize(width: 1400, height: 900), colors: [.systemPurple, .systemOrange], caption: nil) {
            let name = "showcase-capture.png"
            try? image.write(to: payloads.appendingPathComponent(name))
            var item = entry(.image, "Screenshot", ago: 1150, app: "Screenshot", bundle: "com.apple.screencaptureui", tags: ["press"])
            item.payloadFileName = name
            item.payloadType = UTType.png.identifier
            item.payloadByteCount = image.count
            item.payloadDigest = ClipboardEntry.digest(for: image)
            item.thumbnail = jpegThumbnail(from: image)
            entries.insert(item, at: 2)
        }

        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: containerURL.appendingPathComponent("clipboard-history.json"))
    }

    private static func entry(
        _ kind: ClipboardEntry.Kind,
        _ text: String,
        ago seconds: TimeInterval,
        app: String,
        bundle: String,
        tags: [String]? = nil,
        pinned: Bool = false,
        paths: [String] = []
    ) -> ClipboardEntry {
        ClipboardEntry(
            id: UUID(),
            createdAt: Date().addingTimeInterval(-seconds),
            kind: kind,
            text: text,
            paths: paths,
            isPinned: pinned,
            tags: tags,
            sourceAppName: app,
            sourceBundleIdentifier: bundle
        )
    }

    // MARK: - Generated artwork

    /// Album art for the fictional track.
    static func artwork() -> NSImage {
        let size = CGSize(width: 600, height: 600)
        let image = NSImage(size: size)
        image.lockFocus()
        drawGradient(in: CGRect(origin: .zero, size: size), colors: [.systemIndigo, .systemPink])
        let text = "NA" as NSString
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        text.draw(
            in: CGRect(x: 0, y: size.height / 2 - 110, width: size.width, height: 220),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 180, weight: .heavy),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92),
                .paragraphStyle: style
            ]
        )
        image.unlockFocus()
        return image
    }

    private static func gradientPNG(size: CGSize, colors: [NSColor], caption: String?) -> Data? {
        let image = NSImage(size: size)
        image.lockFocus()
        drawGradient(in: CGRect(origin: .zero, size: size), colors: colors)
        if let caption {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            (caption as NSString).draw(
                in: CGRect(x: 0, y: size.height / 2 - size.height * 0.12, width: size.width, height: size.height * 0.24),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: size.height * 0.16, weight: .heavy),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.9),
                    .paragraphStyle: style
                ]
            )
        }
        image.unlockFocus()
        return pngData(from: image)
    }

    private static func drawGradient(in rect: CGRect, colors: [NSColor]) {
        NSGradient(colors: colors)?.draw(in: rect, angle: 55)
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func jpegThumbnail(from png: Data) -> Data? {
        guard let image = NSImage(data: png) else { return nil }
        let target = CGSize(width: 160, height: 160 * image.size.height / max(image.size.width, 1))
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: target))
        thumb.unlockFocus()
        guard let tiff = thumb.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    private static func reportPDF() -> Data? {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = bounds
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        context.beginPDFPage(nil)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSColor.white.setFill()
        bounds.fill()
        ("Q3 Report" as NSString).draw(
            at: CGPoint(x: 64, y: bounds.height - 120),
            withAttributes: [.font: NSFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: NSColor.black]
        )
        ("Sample document generated for SuperNotch screenshots." as NSString).draw(
            at: CGPoint(x: 64, y: bounds.height - 160),
            withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.darkGray]
        )
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
