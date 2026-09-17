import Dispatch
import AppKit
import XCTest
@testable import SuperNotch

final class FileThumbnailTests: XCTestCase {
    func testCompletionGateCancellationBeforeInstallResumesContinuation() async {
        let gate = FileThumbnailCompletionGate<Int?>(cancellationValue: nil)
        let value: Int? = await withCheckedContinuation { continuation in
            gate.cancel()
            XCTAssertFalse(gate.install(continuation))
        }

        XCTAssertNil(value)
    }

    func testCompletionGateIgnoresDuplicateCompletionAndCancelRace() async {
        let gate = FileThumbnailCompletionGate<Int?>(cancellationValue: nil)
        let value: Int? = await withCheckedContinuation { continuation in
            XCTAssertTrue(gate.install(continuation))
            XCTAssertTrue(gate.begin())

            DispatchQueue.concurrentPerform(iterations: 32) { index in
                if index.isMultiple(of: 2) {
                    gate.finish(index)
                } else {
                    gate.cancel()
                }
            }

            // Exercise duplicate callback/cancellation attempts after the
            // concurrent winner has resumed the continuation.
            gate.finish(1000)
            gate.cancel()
        }

        XCTAssertTrue(value == nil || (0..<32).contains(value!))
    }

    @MainActor
    func testImageThumbnailLoaderReturnsBoundedRasterPreview() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repositoryFixture = repositoryRoot.appendingPathComponent("build/icon1024.png")
        let fixture: URL
        let temporaryDirectory: URL?

        if FileManager.default.fileExists(atPath: repositoryFixture.path) {
            // Use the real project asset when present. The helper only reads
            // this file; it never changes the build directory.
            fixture = repositoryFixture
            temporaryDirectory = nil
        } else {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 1024,
                pixelsHigh: 768,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ))
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            fixture = directory.appendingPathComponent("fixture.png")
            try data.write(to: fixture)
            temporaryDirectory = directory
        }
        defer {
            if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        }

        let loadedImage = await FileThumbnailLoader.loadImageThumbnail(for: fixture)
        let image = try XCTUnwrap(loadedImage)
        let representation = try XCTUnwrap(image.representations.max {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        })
        XCTAssertGreaterThan(representation.pixelsWide, 128)
        XCTAssertGreaterThan(representation.pixelsHigh, 128)
        XCTAssertLessThanOrEqual(representation.pixelsWide, 320)
        XCTAssertLessThanOrEqual(representation.pixelsHigh, 320)
        XCTAssertEqual(max(representation.pixelsWide, representation.pixelsHigh), 320)
    }
}
