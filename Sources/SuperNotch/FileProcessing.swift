import SwiftUI
import AppKit
import AVFoundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers

@MainActor final class FileProcessingModel: ObservableObject {
    @Published var busy = false
    @Published var progress: Double = 0
    @Published var message = "Choose a tool to create a new, processed copy."
    @Published var videoPreset = "Medium"
    @Published var videoFormat = "MP4"
    @Published var dpi = 120.0
    @Published var jpegQuality = 0.7
    @Published var maxDimension = 1600.0
    @Published var output: URL?
    private var exporter: AVAssetExportSession?
    private var progressTask: Task<Void, Never>?
    private var task: Task<Void, Never>?

    func cancel() { exporter?.cancelExport(); task?.cancel(); message = "Cancelling…" }
    func video() {
        choose(types: [.movie], multiple: false) { [self] urls in
            guard let source = urls.first else { return }
            let type: UTType = videoFormat == "MOV" ? .quickTimeMovie : .mpeg4Movie
            destination(source: source, suffix: "-compressed", type: type) { [self] target in
                begin("Preparing video export…")
                task = Task {
                    do {
                        let asset = AVURLAsset(url: source)
                        let preset: String
                        switch videoPreset { case "Small": preset = AVAssetExportPresetLowQuality; case "High": preset = AVAssetExportPresetHighestQuality; case "1080p": preset = AVAssetExportPreset1920x1080; default: preset = AVAssetExportPresetMediumQuality }
                        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw ProcessingError.unsupportedVideo }
                        exporter = session
                        let fileType: AVFileType = videoFormat == "MOV" ? .mov : .mp4
                        guard session.supportedFileTypes.contains(fileType) else { throw ProcessingError.unsupportedVideo }
                        // Export to a new staging file so failed/cancelled exports never damage an existing destination.
                        let staging = target.deletingLastPathComponent().appendingPathComponent(".supernotch-\(UUID().uuidString).\(target.pathExtension)")
                        defer { try? FileManager.default.removeItem(at: staging) }
                        session.outputURL = staging; session.outputFileType = fileType; session.shouldOptimizeForNetworkUse = true
                        let estimate = session.estimatedOutputFileLength
                        let sizeDescription = estimate > 0 ? " Estimated output: " + ByteCountFormatter.string(fromByteCount: estimate, countStyle: .file) + "; actual size may differ." : " Final size depends on the source; this encoder has no size estimate."
                        message = "Exporting with \(videoPreset.lowercased()) quality." + sizeDescription
                        progressTask = Task { [weak self] in
                            while !Task.isCancelled {
                                self?.progress = Double(session.progress)
                                try? await Task.sleep(nanoseconds: 250_000_000)
                            }
                        }
                        await session.export()
                        try Task.checkCancellation()
                        guard session.status == .completed else { throw session.error ?? ProcessingError.cancelled }
                        if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: staging) }
                        else { try FileManager.default.moveItem(at: staging, to: target) }
                        finish(target, source: source)
                    } catch { fail(error) }
                    progressTask?.cancel(); progressTask = nil; exporter = nil
                }
            }
        }
    }
    func pdf() {
        choose(types: [.pdf], multiple: false) { [self] urls in
            guard let source = urls.first else { return }
            destination(source: source, suffix: "-rasterized", type: .pdf) { [self] target in
                begin("Rendering PDF pages…")
                let resolution = dpi; let quality = jpegQuality
                task = Task {
                    do {
                        let worker = Task.detached(priority: .userInitiated) { [self] in
                            try await ProcessingTransforms.rasterPDF(source: source, target: target, dpi: resolution, quality: quality) { fraction in
                                await MainActor.run { self.progress = fraction }
                            }
                        }
                        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                        try Task.checkCancellation(); finish(target, source: source)
                    } catch { fail(error) }
                }
            }
        }
    }
    func images() {
        choose(types: [.image], multiple: true) { [self] urls in
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "Choose output folder"
            panel.begin { [self] response in
                guard response == .OK, let directory = panel.url else { return }
                begin("Resizing \(urls.count) images…")
                let maximum = Int(maxDimension)
                task = Task {
                    var successes: [URL] = []; var errors: [String] = []
                    for (index, source) in urls.enumerated() {
                        if Task.isCancelled { break }
                        let target = ProcessingTransforms.uniqueOutput(in: directory, name: source.deletingPathExtension().lastPathComponent + "-\(maximum)px", extension: "png")
                        do {
                            try await Task.detached(priority: .userInitiated) { try ProcessingTransforms.resize(source: source, target: target, maximum: maximum) }.value
                            successes.append(target)
                        } catch { errors.append("\(source.lastPathComponent): \(error.localizedDescription)") }
                        progress = Double(index + 1) / Double(urls.count)
                    }
                    FileShelfStore.shared.add(urls: successes); output = successes.last; busy = false
                    message = "Saved \(successes.count) of \(urls.count) images." + (Task.isCancelled ? " Processing cancelled." : "") + (errors.isEmpty ? "" : "\n" + errors.joined(separator: "\n"))
                }
            }
        }
    }
    private func begin(_ text: String) { busy = true; progress = 0; message = text }
    private func fail(_ error: Error) { busy = false; message = error is CancellationError ? "Processing cancelled." : error.localizedDescription }
    private func finish(_ target: URL, source: URL) {
        busy = false; progress = 1; output = target; FileShelfStore.shared.add(urls: [target])
        let before = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let after = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let formatter = ByteCountFormatter()
        message = "Saved \(formatter.string(fromByteCount: Int64(after))) (source: \(formatter.string(fromByteCount: Int64(before))))." + (after > before ? " This output is larger; try lower quality or resolution." : "")
    }
    private func choose(types: [UTType], multiple: Bool, completion: @escaping ([URL]) -> Void) {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = types; panel.allowsMultipleSelection = multiple; panel.canChooseDirectories = false
        panel.begin { response in if response == .OK { completion(panel.urls) } }
    }
    private func destination(source: URL, suffix: String, type: UTType, completion: @escaping (URL) -> Void) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [type]; panel.canCreateDirectories = true
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + suffix + "." + (type.preferredFilenameExtension ?? "dat")
        panel.begin { [self] response in
            guard response == .OK, let target = panel.url else { return }
            guard source.resolvingSymlinksInPath().standardizedFileURL != target.resolvingSymlinksInPath().standardizedFileURL else { message = "Choose a new filename to preserve the original."; return }
            completion(target)
        }
    }
}

enum ProcessingError: LocalizedError {
    case unsupportedVideo, invalidPDF, invalidImage, writeFailed, cancelled
    var errorDescription: String? {
        switch self {
        case .unsupportedVideo: return "This source cannot be exported with the selected preset and format. Try MOV or a different quality."
        case .invalidPDF: return "This PDF could not be read. It may be encrypted or damaged."
        case .invalidImage: return "The image could not be decoded."
        case .writeFailed: return "The processed file could not be written."
        case .cancelled: return "Export was cancelled."
        }
    }
}

enum ProcessingTransforms {
    static func uniqueOutput(in directory: URL, name: String, extension ext: String) -> URL {
        var index = 0
        var candidate = directory.appendingPathComponent(name + "." + ext)
        while FileManager.default.fileExists(atPath: candidate.path) {
            index += 1; candidate = directory.appendingPathComponent(name + "-\(index)." + ext)
        }
        return candidate
    }
    static func resize(source: URL, target: URL, maximum: Int) throws {
        guard maximum > 0, let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(input, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maximum] as CFDictionary) else { throw ProcessingError.invalidImage }
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ProcessingError.writeFailed }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw ProcessingError.writeFailed }
        try (data as Data).write(to: target, options: .atomic)
    }
    static func rasterPDF(source: URL, target: URL, dpi: Double, quality: Double, progress: @escaping @Sendable (Double) async -> Void) async throws {
        guard let document = PDFDocument(url: source), !document.isLocked, document.pageCount > 0 else { throw ProcessingError.invalidPDF }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw ProcessingError.writeFailed }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            var bounds = page.bounds(for: .mediaBox)
            if page.rotation == 90 || page.rotation == 270 { bounds.size = CGSize(width: bounds.height, height: bounds.width) }
            let scale = max(36, min(300, dpi)) / 72
            let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            let thumbnail = page.thumbnail(of: size, for: .mediaBox)
            var rect = CGRect(origin: .zero, size: thumbnail.size)
            guard let image = thumbnail.cgImage(forProposedRect: &rect, context: nil, hints: nil),
                  let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: max(0.1, min(1, quality))]),
                  let jpegSource = CGImageSourceCreateWithData(jpeg as CFData, nil),
                  let compressed = CGImageSourceCreateImageAtIndex(jpegSource, 0, nil) else { throw ProcessingError.invalidImage }
            var media = CGRect(origin: .zero, size: bounds.size)
            let mediaData = Data(bytes: &media, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox: mediaData] as CFDictionary)
            context.draw(compressed, in: CGRect(origin: .zero, size: bounds.size))
            context.endPDFPage()
            await progress(Double(index + 1) / Double(document.pageCount))
        }
        context.closePDF()
        try Task.checkCancellation()
        try (output as Data).write(to: target, options: .atomic)
    }
}

struct FileProcessingView: View {
    @StateObject private var model = FileProcessingModel()
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Video Conversion", systemImage: "film").font(.headline)
                    HStack {
                        Picker("Quality", selection: $model.videoPreset) { ForEach(["Small", "Medium", "High", "1080p"], id: \.self) { Text($0) } }
                        Picker("Format", selection: $model.videoFormat) { Text("MP4").tag("MP4"); Text("MOV").tag("MOV") }.frame(width: 145)
                    }
                    Text("Size depends on duration, motion, and the source codec. Lower presets usually produce smaller files; an exact target size is not guaranteed.").font(.caption).foregroundStyle(.secondary)
                    Button("Choose Video…", action: model.video)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("PDF Raster Compression", systemImage: "doc.richtext").font(.headline)
                    HStack { Text("Resolution"); Slider(value: $model.dpi, in: 72...200, step: 8); Text("\(Int(model.dpi)) DPI").monospacedDigit().frame(width: 65) }
                    HStack { Text("JPEG quality"); Slider(value: $model.jpegQuality, in: 0.2...0.95, step: 0.05); Text("\(Int(model.jpegQuality * 100))%").monospacedDigit().frame(width: 65) }
                    Text("Creates image-only pages. Searchable text, links, forms, and accessibility structure are lost in the output copy. The original is preserved. Some PDFs may become larger.").font(.caption).foregroundStyle(.orange)
                    Button("Choose PDF…", action: model.pdf)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Batch Image Resize", systemImage: "arrow.down.right.and.arrow.up.left").font(.headline)
                    HStack { Text("Longest edge"); Slider(value: $model.maxDimension, in: 320...3840, step: 80); Text("\(Int(model.maxDimension)) px").monospacedDigit().frame(width: 75) }
                    Text("Keeps proportions and saves PNG copies with unique filenames. Animated images export their first frame.").font(.caption).foregroundStyle(.secondary)
                    Button("Choose Images…", action: model.images)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.busy)
            if model.busy { HStack { ProgressView(value: model.progress); Button("Cancel", action: model.cancel) } }
            Text(model.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let output = model.output { Button("Show Last Output in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) } }
        }.padding(20).frame(maxWidth: 760, alignment: .leading) }
    }
}
