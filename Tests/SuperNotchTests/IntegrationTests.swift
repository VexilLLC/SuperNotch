import XCTest
import Foundation
@testable import SuperNotch

private final class SharePortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: UInt16?
    var value: UInt16? { get { lock.lock(); defer { lock.unlock() }; return storage } set { lock.lock(); storage = newValue; lock.unlock() } }
}

final class IntegrationTests: XCTestCase {
    func testLocalShareStreamsOnlyExplicitRoutes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("test.dat")
        let contents = Data((0..<1_100_000).map { UInt8($0 % 251) })
        try contents.write(to: file)
        let ready = expectation(description: "Local server starts")
        let port = SharePortBox()
        let server = try LocalFileHTTPServer(routes: ["/opaque-token/test": file], bindHost: "127.0.0.1") { event in
            if case .ready(let number) = event { port.value = number; ready.fulfill() }
        }
        server.start(); defer { server.stop() }
        await fulfillment(of: [ready], timeout: 5)
        let number = try XCTUnwrap(port.value)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let base = "http://127.0.0.1:\(number)"
        let (bytes, response) = try await session.data(from: URL(string: base + "/opaque-token/test")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(bytes, contents)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff")
        let (_, denied) = try await session.data(from: URL(string: base + "/not-selected")!)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 404)
        var post = URLRequest(url: URL(string: base + "/opaque-token/test")!); post.httpMethod = "POST"
        let (_, unsupported) = try await session.data(for: post)
        XCTAssertEqual((unsupported as? HTTPURLResponse)?.statusCode, 405)
    }

    @MainActor func testVaultConflictsAndAgentValidation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = folder.appendingPathComponent("note.md")
        try "Original".write(to: note, atomically: true, encoding: .utf8)
        let model = IntegrationsModel(agentURL: folder.appendingPathComponent("agents.json"))
        model.loadVault(folder); XCTAssertEqual(model.notes.count, 1)
        model.selectNote(note); model.noteText = "Edited"; model.saveNote()
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "Edited")
        model.noteText = "Unsaved edit"
        try "External edit".write(to: note, atomically: true, encoding: .utf8)
        model.saveNote()
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "External edit")
        XCTAssertTrue(model.isDirty)
        model.selectNote(note, discardChanges: true); XCTAssertFalse(model.isDirty)
        let document = IntegrationAgentDocument(version: 1, agents: [.init(id: "test", name: "Tests", status: "working", message: nil, progress: 0.5, updatedAt: "2026-09-15T12:00:00.123Z")])
        try JSONEncoder().encode(document).write(to: model.agentURL)
        model.readAgents(); XCTAssertEqual(model.agents.count, 1)
        try "{}".write(to: model.agentURL, atomically: true, encoding: .utf8)
        model.readAgents(); XCTAssertNotNil(model.agentMessage)
    }
}
