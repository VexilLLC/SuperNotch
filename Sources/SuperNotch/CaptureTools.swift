import SwiftUI
import AppKit
import Vision
import PDFKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@MainActor final class CaptureToolsModel: ObservableObject {
    @Published var busy = false
    @Published var status = "Capture, extract, and convert — on your Mac."
    @Published var extractedText = ""
    @Published var format = "PNG"
    @Published var outputURL: URL?

    func captureRegion() {
        guard !busy else { return }
        busy = true; status = "Select a region. Press Escape to cancel."
        let folder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("SuperNotch Captures", isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { finish(error: error); return }
        let destination = folder.appendingPathComponent("Capture-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(5)).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", destination.path]
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                if FileManager.default.fileExists(atPath: destination.path) {
                    FileShelfStore.shared.add(urls: [destination])
                    self?.outputURL = destination
                    self?.status = "Screenshot saved to Pictures and added to your shelf."
                } else { self?.status = "No screenshot saved. The selection was cancelled or screen recording access is unavailable." }
                self?.busy = false
            }
        }
        do { try process.run() } catch { finish(error: error) }
    }
    func extractText() {
        choose(types: [.image, .pdf]) { [weak self] url in
            guard let self else { return }
            self.run("Recognizing text…") {
                let text = try CaptureTransforms.extractText(from: url)
                await MainActor.run { self.extractedText = text; self.status = text.isEmpty ? "No readable text found." : "Extracted \(text.count) characters. Select or copy the text below." }
            }
        }
    }
    func removeBackground() {
        choose(types: [.image]) { [weak self] source in
            guard let self else { return }
            self.saveDestination(source: source, suffix: "-cutout", type: .png) { destination in
                self.run("Separating the foreground…") {
                    try CaptureTransforms.removeBackground(from: source, to: destination)
                    await MainActor.run { self.completed(destination, message: "Transparent PNG saved and added to your shelf.") }
                }
            }
        }
    }
    func convert() {
        choose(types: [.image]) { [weak self] source in
            guard let self else { return }
            let type = CaptureTransforms.outputType(named: self.format)
            self.saveDestination(source: source, suffix: "-converted", type: type) { destination in
                self.run("Converting image…") {
                    try CaptureTransforms.convert(from: source, to: destination, type: type)
                    await MainActor.run { self.completed(destination, message: "Converted image saved and added to your shelf.") }
                }
            }
        }
    }
    private func completed(_ url: URL, message: String) { outputURL = url; status = message; FileShelfStore.shared.add(urls: [url]) }
    private func run(_ message: String, operation: @escaping @Sendable () async throws -> Void) {
        guard !busy else { return }; busy = true; status = message
        Task.detached(priority: .userInitiated) { [self] in
            do {
                try await operation()
                await MainActor.run { self.busy = false }
            } catch {
                await MainActor.run { self.finish(error: error) }
            }
        }
    }
    private func finish(error: Error) { busy = false; status = error.localizedDescription }
    private func choose(types: [UTType], completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = types; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.begin { response in if response == .OK, let url = panel.url { completion(url) } }
    }
    private func saveDestination(source: URL, suffix: String, type: UTType, completion: @escaping (URL) -> Void) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [type]; panel.canCreateDirectories = true
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + suffix + "." + (type.preferredFilenameExtension ?? "png")
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url {
                guard url.resolvingSymlinksInPath().standardizedFileURL != source.resolvingSymlinksInPath().standardizedFileURL else { self?.status = "Choose a different filename to preserve your original."; return }
                completion(url)
            }
        }
    }
}

enum CaptureTransforms {
    enum Failure: LocalizedError {
        case invalidImage, emptyPDF, noForeground, cannotWrite
        var errorDescription: String? {
            switch self {
            case .invalidImage: return "This file could not be decoded as an image."
            case .emptyPDF: return "This PDF could not be opened. It may be encrypted or damaged."
            case .noForeground: return "No foreground subject was detected in this image."
            case .cannotWrite: return "The output image could not be saved. Choose a writable location and supported format."
            }
        }
    }
    static func outputType(named name: String) -> UTType {
        switch name { case "JPEG": return .jpeg; case "TIFF": return .tiff; case "HEIC": return .heic; default: return .png }
    }
    static func extractText(from url: URL) throws -> String {
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url) else { throw Failure.emptyPDF }
            var pages: [String] = []
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let embedded = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !embedded.isEmpty { pages.append(embedded); continue }
                let image = page.thumbnail(of: NSSize(width: 2200, height: 2800), for: .mediaBox)
                var rect = CGRect(origin: .zero, size: image.size)
                if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) { pages.append(try recognize(cgImage)) }
            }
            return pages.joined(separator: "\n\n")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true; request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(url: url).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
    }
    private static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true; request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
    }
    static func removeBackground(from source: URL, to destination: URL) throws {
        let handler = VNImageRequestHandler(url: source)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw Failure.noForeground }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false)
        let image = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(image, from: image.extent) else { throw Failure.invalidImage }
        try write(cgImage, to: destination, type: .png)
    }
    static func convert(from source: URL, to destination: URL, type: UTType) throws {
        guard let source = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 32768] as CFDictionary) else { throw Failure.invalidImage }
        if type == .jpeg {
            // JPEG has no alpha channel: flatten transparent pixels on white.
            guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure.invalidImage }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height)); context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let flattened = context.makeImage() else { throw Failure.invalidImage }
            try write(flattened, to: destination, type: type)
        } else { try write(image, to: destination, type: type) }
    }
    private static func write(_ image: CGImage, to url: URL, type: UTType) throws {
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw Failure.cannotWrite }
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw Failure.cannotWrite }
        try (data as Data).write(to: url, options: .atomic)
    }
}

struct CaptureToolsView: View {
    @StateObject private var model = CaptureToolsModel()
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                tool("Region Capture", symbol: "viewfinder", color: .indigo, subtitle: "Select an area and send it to your shelf", action: model.captureRegion)
                tool("Extract Text", symbol: "text.viewfinder", color: .blue, subtitle: "Recognize text in images and PDFs", action: model.extractText)
                tool("Remove Background", symbol: "person.crop.rectangle", color: .pink, subtitle: "Save your subject as a transparent PNG", action: model.removeBackground)
                VStack(alignment: .leading, spacing: 10) {
                    SymbolTile(systemImage: "photo.on.rectangle.angled", color: .orange, size: 30)
                    Text("Convert Image").font(.headline)
                    HStack {
                        Picker("Format", selection: $model.format) { ForEach(["PNG", "JPEG", "TIFF", "HEIC"], id: \.self) { Text($0) } }.labelsHidden().fixedSize()
                        Button("Choose Image…", action: model.convert).disabled(model.busy)
                    }
                }.frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading).cardStyle()
            }
            HStack(alignment: .top, spacing: 8) {
                if model.busy { ProgressView().controlSize(.small) } else { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                Text(model.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let output = model.outputURL {
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: output.path)).resizable().frame(width: 28, height: 28)
                    Text(output.lastPathComponent).lineLimit(1).font(.caption)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                }.rowStyle()
            }
            if !model.extractedText.isEmpty {
                HStack { Text("Recognized Text").font(.headline); Spacer(); Button("Copy Text") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.extractedText, forType: .string) } }
                TextEditor(text: $model.extractedText).font(.body).frame(minHeight: 160).editorStyle()
            }
        }.padding(20).frame(maxWidth: 900, alignment: .leading) }
    }
    private func tool(_ title: String, symbol: String, color: Color, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                SymbolTile(systemImage: symbol, color: color, size: 30)
                Text(title).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }.frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading).cardStyle().contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).disabled(model.busy)
    }
}
