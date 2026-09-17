import SwiftUI
import AppKit
import Network
import UniformTypeIdentifiers
import Darwin

struct LocalShareFile: Identifiable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
}

@MainActor final class LocalSharingModel: ObservableObject {
    @Published var files: [LocalShareFile] = []
    @Published var running = false
    @Published var starting = false
    @Published var localNetwork = false
    @Published var baseURL = ""
    @Published var status = "Select files to share for up to one hour."
    @Published var expiry: Date?
    private var server: LocalFileHTTPServer?
    deinit { server?.stop() }
    func choose() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.files = panel.urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.map { LocalShareFile(url: $0) }
        }
    }
    func start() {
        guard !files.isEmpty, !starting, !running else { return }
        starting = true
        let host = localNetwork ? LocalShareNetwork.lanIPv4() : "127.0.0.1"
        guard let host else { starting = false; status = "No private LAN IPv4 address found. Connect to Wi-Fi or Ethernet, or use this Mac only."; return }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let routes = Dictionary(uniqueKeysWithValues: files.map { ("/\(token)/\($0.id.uuidString)", $0.url) })
        do {
            let service = try LocalFileHTTPServer(routes: routes, bindHost: host) { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    switch event {
                    case .ready(let port): self.starting = false; self.running = true; self.baseURL = "http://\(host):\(port)/\(token)"; self.expiry = Date().addingTimeInterval(3600); self.status = self.localNetwork ? "Sharing on your local network. Keep this Mac awake." : "Sharing on this Mac only."
                    case .download(let name): self.status = "Downloaded \(name)"
                    case .stopped: self.starting = false; self.running = false; self.baseURL = ""; self.expiry = nil; self.status = "Sharing stopped. Previous links no longer work."
                    case .failure(let message): self.starting = false; self.running = false; self.status = message
                    }
                }
            }
            server = service; service.start()
        } catch { starting = false; status = error.localizedDescription }
    }
    func stop() { server?.stop(); server = nil }
    func link(_ file: LocalShareFile) -> String { baseURL + "/" + file.id.uuidString }
    func copy(_ file: LocalShareFile) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link(file), forType: .string) }
}

enum LocalShareNetwork {
    static func lanIPv4() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        var candidates: [String] = []
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  interface.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: hostname)
                if isPrivateIPv4(ip) { candidates.append(ip) }
            }
        }
        return candidates.first
    }
    static func isPrivateIPv4(_ text: String) -> Bool {
        let numbers = text.split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 4, numbers.allSatisfy({ (0...255).contains($0) }) else { return false }
        return numbers[0] == 10 || (numbers[0] == 192 && numbers[1] == 168) || (numbers[0] == 172 && (16...31).contains(numbers[1])) || (numbers[0] == 169 && numbers[1] == 254) || numbers[0] == 127
    }
}

final class LocalFileHTTPServer: @unchecked Sendable {
    enum Event { case ready(UInt16), download(String), stopped, failure(String) }
    private let queue = DispatchQueue(label: "SuperNotch.LocalSharing")
    private let listener: NWListener
    private let routes: [String: URL]
    private let callback: @Sendable (Event) -> Void
    private var connections: [UUID: NWConnection] = [:]
    private var awaitingHeaders = Set<UUID>()
    private var expiry: DispatchWorkItem?
    private var stopped = false
    init(routes: [String: URL], bindHost: String, callback: @escaping @Sendable (Event) -> Void) throws {
        self.routes = routes; self.callback = callback
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindHost), port: .any)
        parameters.allowLocalEndpointReuse = false
        listener = try NWListener(using: parameters)
    }
    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: if let port = self.listener.port { self.callback(.ready(port.rawValue)) }
            case .failed(let error): self.callback(.failure(error.localizedDescription)); self.shutdown(notify: false)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        let expiry = DispatchWorkItem { [weak self] in self?.shutdown(notify: true) }
        self.expiry = expiry; queue.asyncAfter(deadline: .now() + 3600, execute: expiry)
    }
    func stop() { queue.async { [self] in shutdown(notify: true) } }
    private func shutdown(notify: Bool) {
        guard !stopped else { return }; stopped = true
        expiry?.cancel(); expiry = nil; listener.cancel()
        connections.values.forEach { $0.cancel() }; connections.removeAll()
        if notify { callback(.stopped) }
    }
    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 8 else { connection.cancel(); return }
        // Only private IPv4 peers are accepted, including when a router forwards a port.
        guard case .hostPort(let host, _) = connection.endpoint,
              LocalShareNetwork.isPrivateIPv4(String(describing: host)) else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection; awaitingHeaders.insert(id)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.connections.removeValue(forKey: id); self?.awaitingHeaders.remove(id) }
            if case .cancelled = state { self?.connections.removeValue(forKey: id); self?.awaitingHeaders.remove(id) }
        }
        connection.start(queue: queue)
        receive(connection, id: id, buffer: Data())
        queue.asyncAfter(deadline: .now() + 30) { [weak self, weak connection] in
            guard let self, self.awaitingHeaders.contains(id) else { return }
            connection?.cancel(); self.connections.removeValue(forKey: id)
        }
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return }
            var combined = buffer; if let data { combined.append(data) }
            guard combined.count <= 8192 else { self.respond(connection, code: "431 Request Header Fields Too Large"); return }
            if combined.range(of: Data("\r\n\r\n".utf8)) != nil { self.awaitingHeaders.remove(id); self.serve(connection, request: combined); return }
            if complete || error != nil { connection.cancel(); return }
            self.receive(connection, id: id, buffer: combined)
        }
    }
    private func serve(_ connection: NWConnection, request: Data) {
        guard let text = String(data: request, encoding: .utf8), let first = text.components(separatedBy: "\r\n").first else { respond(connection, code: "400 Bad Request"); return }
        let parts = first.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { respond(connection, code: "405 Method Not Allowed"); return }
        // Exact opaque route lookup only: no path decoding, filesystem joining, or directory serving.
        guard let url = routes[String(parts[1])], let file = try? FileHandle(forReadingFrom: url) else { respond(connection, code: "404 Not Found"); return }
        var info = stat()
        guard fstat(file.fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { try? file.close(); respond(connection, code: "404 Not Found"); return }
        let filename = url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "download"
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(info.st_size)\r\nContent-Disposition: attachment; filename*=UTF-8''\(filename)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            if error != nil { try? file.close(); connection.cancel(); return }
            self?.stream(file, connection: connection, remaining: Int64(info.st_size), name: url.lastPathComponent)
        })
    }
    private func stream(_ file: FileHandle, connection: NWConnection, remaining: Int64, name: String) {
        guard !stopped else { try? file.close(); connection.cancel(); return }
        guard remaining > 0 else { try? file.close(); connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() }); callback(.download(name)); return }
        do {
            guard let data = try file.read(upToCount: Int(min(65536, remaining))), !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if error != nil { try? file.close(); connection.cancel(); return }
                self?.stream(file, connection: connection, remaining: remaining - Int64(data.count), name: name)
            })
        } catch { try? file.close(); connection.cancel() }
    }
    private func respond(_ connection: NWConnection, code: String) {
        let response = "HTTP/1.1 \(code)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

struct LocalSharingView: View {
    @StateObject private var model = LocalSharingModel()
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 14) {
            InlineMessage(text: "Anyone with a link on your local network can download the selected files. Links use HTTP and expire after one hour.")
            Toggle("Allow devices on my local network", isOn: $model.localNetwork).disabled(model.running || model.starting)
            if !model.localNetwork { Text("Currently limited to this Mac (127.0.0.1).").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Choose Files…", action: model.choose).disabled(model.running || model.starting)
                Spacer()
                if model.running || model.starting { Button("Stop Sharing", role: .destructive, action: model.stop) }
                else { Button("Start Sharing", action: model.start).buttonStyle(.borderedProminent).disabled(model.files.isEmpty) }
            }
            if model.files.isEmpty {
                ContentUnavailableView("No Files Selected", systemImage: "doc.badge.arrow.up", description: Text("Choose files to create temporary download links.")).frame(minHeight: 180)
            }
            ForEach(model.files) { file in
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 3) { Text(file.name).lineLimit(1); if model.running { Text(model.link(file)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2) } }
                    Spacer()
                    if model.running { Button("Copy Link") { model.copy(file) } }
                }.cardStyle(padding: 12)
            }
            if model.starting { ProgressView().controlSize(.small) }
            if let expiry = model.expiry { Label("Links expire at \(expiry.formatted(date: .omitted, time: .shortened))", systemImage: "clock").font(.caption).foregroundStyle(.secondary) }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth: 760, alignment: .leading) }
    }
}
