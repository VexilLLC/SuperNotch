import SwiftUI
import AppKit

struct IntegrationAgentEvent: Codable, Identifiable {
    let id: String
    let name: String
    let status: String
    let message: String?
    let progress: Double?
    let updatedAt: String
}
struct IntegrationAgentDocument: Codable { let version: Int; let agents: [IntegrationAgentEvent] }
struct IntegrationCity: Decodable, Identifiable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double
    let country: String?
    let admin1: String?
    var label: String { [name, admin1, country].compactMap { $0 }.joined(separator: ", ") }
}
struct IntegrationGeocoding: Decodable { let results: [IntegrationCity]? }
struct IntegrationWeather: Decodable {
    struct Current: Decodable { let time: String; let temperature_2m: Double; let relative_humidity_2m: Double; let weather_code: Int; let wind_speed_10m: Double }
    struct Daily: Decodable { let time: [String]; let temperature_2m_max: [Double]; let temperature_2m_min: [Double] }
    let current: Current
    let daily: Daily
    let timezone: String
}

@MainActor final class IntegrationsModel: ObservableObject {
    static let shared = IntegrationsModel()
    @Published var vault: URL?
    @Published var notes: [URL] = []
    @Published var noteSearch = ""
    @Published var selectedNote: URL?
    @Published var noteText = ""
    @Published var noteMessage: String?
    @Published var cityQuery = ""
    @Published var cities: [IntegrationCity] = []
    @Published var selectedCity: IntegrationCity?
    @Published var weather: IntegrationWeather?
    @Published var weatherLoading = false
    @Published var weatherMessage: String?
    @Published var agents: [IntegrationAgentEvent] = []
    @Published var agentMessage: String?
    private var originalData: Data?
    private var originalText = ""
    private var scopeActive = false
    private var agentData: Data?
    var isDirty: Bool { selectedNote != nil && noteText != originalText }
    let agentURL: URL
    init(agentURL: URL? = nil) { self.agentURL = agentURL ?? SuperNotchStorage.baseDirectory.appendingPathComponent("agents.json") }
    var visibleNotes: [URL] { notes.filter { noteSearch.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(noteSearch) } }
    func chooseVault() {
        guard !isDirty else { noteMessage = "Save or reload the current note before changing vaults."; return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = "Open Vault"; panel.message = "Choose your Obsidian vault or a folder of Markdown notes."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.loadVault(url) }
        }
    }
    func loadVault(_ url: URL) {
        guard !isDirty else { return }
        if scopeActive { vault?.stopAccessingSecurityScopedResource() }
        scopeActive = url.startAccessingSecurityScopedResource()
        vault = url.resolvingSymlinksInPath().standardizedFileURL
        selectedNote = nil; noteText = ""; originalText = ""; originalData = nil
        refreshNotes()
    }
    func refreshNotes() {
        guard let vault else { return }
        notes = []
        guard let enumerator = FileManager.default.enumerator(at: vault, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { noteMessage = "Could not read this vault."; return }
        for case let url as URL in enumerator {
            guard notes.count < 3000 else { noteMessage = "Showing the first 3,000 Markdown notes."; break }
            guard url.pathExtension.lowercased() == "md", insideVault(url), (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            notes.append(url)
        }
        notes.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    private func insideVault(_ url: URL) -> Bool {
        guard let vault else { return false }
        return url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(vault.path + "/")
    }
    func selectNote(_ url: URL, discardChanges: Bool = false) {
        guard !isDirty || discardChanges else { noteMessage = "Save or reload your current note before switching."; return }
        guard insideVault(url) else { noteMessage = "This note points outside the selected vault."; return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 2_000_000 else { noteMessage = "This note exceeds the 2 MB editor limit."; return }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else { noteMessage = "This note is not UTF-8 text."; return }
            selectedNote = url; originalData = data; originalText = text; noteText = text; noteMessage = nil
        } catch { noteMessage = error.localizedDescription }
    }
    func saveNote() {
        guard let url = selectedNote, let originalData, insideVault(url) else { return }
        let newData = Data(noteText.utf8)
        guard newData.count <= 2_000_000 else { noteMessage = "This note exceeds the 2 MB editor limit."; return }
        var coordinationError: NSError?
        var saveError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                guard insideVault(coordinatedURL) else { throw NSError(domain: "SuperNotchNotes", code: 1, userInfo: [NSLocalizedDescriptionKey: "The note now points outside this vault."]) }
                let currentData = try Data(contentsOf: coordinatedURL)
                guard currentData == originalData else { throw NSError(domain: "SuperNotchNotes", code: 2, userInfo: [NSLocalizedDescriptionKey: "This note changed in another app. Copy your edits before reloading the disk version."]) }
                try newData.write(to: coordinatedURL, options: .atomic)
            } catch { saveError = error }
        }
        if let error = saveError ?? coordinationError { noteMessage = error.localizedDescription }
        else { self.originalData = newData; originalText = noteText; noteMessage = "Saved to your vault." }
    }
    private func request<T: Decodable>(_ url: URL, type: T.Type) async throws -> T {
        var request = URLRequest(url: url); request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(type, from: data)
    }
    func findCities() async {
        let query = cityQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, !weatherLoading else { return }
        weatherLoading = true; weatherMessage = nil; cities = []; weather = nil; selectedCity = nil
        defer { weatherLoading = false }
        var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        url.queryItems = [URLQueryItem(name: "name", value: query), URLQueryItem(name: "count", value: "5"), URLQueryItem(name: "language", value: "en"), URLQueryItem(name: "format", value: "json")]
        do {
            cities = try await request(url.url!, type: IntegrationGeocoding.self).results ?? []
            if cities.isEmpty { weatherMessage = "No matching cities. Try a nearby city or another spelling." }
        } catch { weatherMessage = "Could not find cities: \(error.localizedDescription)" }
    }
    func loadWeather(_ city: IntegrationCity) async {
        guard !weatherLoading else { return }
        weatherLoading = true; weatherMessage = nil; weather = nil; selectedCity = city
        defer { weatherLoading = false }
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [URLQueryItem(name: "latitude", value: String(city.latitude)), URLQueryItem(name: "longitude", value: String(city.longitude)), URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m"), URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"), URLQueryItem(name: "timezone", value: "auto"), URLQueryItem(name: "forecast_days", value: "3")]
        do { weather = try await request(url.url!, type: IntegrationWeather.self) }
        catch { weatherMessage = "Could not load weather: \(error.localizedDescription)" }
    }
    func readAgents() {
        guard FileManager.default.fileExists(atPath: agentURL.path) else { agents = []; agentMessage = nil; agentData = nil; return }
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: agentURL.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= 1_000_000 else { throw NSError(domain: "SuperNotchAgents", code: 1, userInfo: [NSLocalizedDescriptionKey: "Agent event file exceeds 1 MB."]) }
            let data = try Data(contentsOf: agentURL)
            guard data != agentData else { return }
            let document = try JSONDecoder().decode(IntegrationAgentDocument.self, from: data)
            guard document.version == 1, document.agents.count <= 100, Set(document.agents.map(\.id)).count == document.agents.count, document.agents.allSatisfy({ ["working", "waiting", "completed", "failed", "idle"].contains($0.status) && ($0.progress == nil || (0...1).contains($0.progress!)) && Self.eventDate($0.updatedAt) != nil }) else { throw NSError(domain: "SuperNotchAgents", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid agent schema: use version 1, unique IDs, supported status, progress 0–1 and ISO-8601 updatedAt."]) }
            agentData = data; agents = document.agents; agentMessage = nil
        } catch { agentMessage = error.localizedDescription }
    }
    static func eventDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
    static func weatherLabel(_ code: Int) -> (String, String) {
        switch code { case 0: return ("Clear sky", "sun.max.fill"); case 1...3: return ("Partly cloudy", "cloud.sun.fill"); case 45, 48: return ("Fog", "cloud.fog.fill"); case 51...67: return ("Rain", "cloud.rain.fill"); case 71...77, 85, 86: return ("Snow", "cloud.snow.fill"); case 80...82: return ("Rain showers", "cloud.heavyrain.fill"); case 95...99: return ("Thunderstorms", "cloud.bolt.rain.fill"); default: return ("Weather conditions", "cloud.fill") }
    }
}

@MainActor struct IntegrationsView: View {
    @StateObject private var model = IntegrationsModel.shared
    @State private var tab = "Notes"
    init(initialTool: String = "") { _tab = State(initialValue: initialTool == "Weather" ? "Weather" : initialTool == "Agent activities" ? "Agents" : "Notes") }
    @State private var confirmReload = false
    init() {}
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Picker("Integration", selection: $tab) { Text("Markdown Vault").tag("Notes"); Text("Weather").tag("Weather"); Text("Coding Agents").tag("Agents") }.pickerStyle(.segmented).labelsHidden().fixedSize().frame(maxWidth: .infinity)
            switch tab { case "Weather": weatherView; case "Agents": agentView; default: notesView }
        }.padding(20)
    }
    private var notesView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.vault?.lastPathComponent ?? "No vault selected", systemImage: "folder").font(.headline)
                Spacer()
                Button("Open vault…") { model.chooseVault() }.disabled(model.isDirty)
                Button { model.refreshNotes() } label: { Image(systemName: "arrow.clockwise") }.disabled(model.vault == nil)
            }
            if model.vault != nil {
                HStack(alignment: .top, spacing: 12) {
                    VStack {
                        TextField("Find a note", text: $model.noteSearch).textFieldStyle(.roundedBorder)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 5) {
                                ForEach(model.visibleNotes, id: \.path) { url in
                                    Button { model.selectNote(url) } label: { Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(8).background(model.selectedNote == url ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain).disabled(model.isDirty && model.selectedNote != url)
                                }
                            }
                        }
                    }.frame(width: 200)
                    VStack(alignment: .leading, spacing: 10) {
                        if let url = model.selectedNote {
                            HStack { Text(url.lastPathComponent).font(.headline).lineLimit(1); if model.isDirty { Circle().fill(.orange).frame(width: 6, height: 6) }; Spacer(); Button("Reload") { confirmReload = true }; Button("Save") { model.saveNote() }.buttonStyle(.borderedProminent).disabled(!model.isDirty) }
                            TextEditor(text: $model.noteText).font(.system(.body, design: .monospaced)).editorStyle()
                        } else { ContentUnavailableView("Select a note", systemImage: "doc.text", description: Text("Edit UTF-8 Markdown files directly in your selected vault.")) }
                    }
                }
            } else { ContentUnavailableView("Open your Markdown vault", systemImage: "book.closed", description: Text("Choose a local Obsidian vault to browse and edit existing notes.")) }
            if let message = model.noteMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            Text("Local Markdown editor · explicit saves · external changes are checked before saving").font(.caption2).foregroundStyle(.tertiary)
        }.alert("Reload the note from disk?", isPresented: $confirmReload) {
            Button("Cancel", role: .cancel) {}
            Button("Reload", role: .destructive) { if let url = model.selectedNote { model.selectNote(url, discardChanges: true) } }
        } message: { Text("Your unsaved edits will be discarded.") }
    }
    private var weatherView: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                TextField("Enter a city", text: $model.cityQuery).textFieldStyle(.roundedBorder).onSubmit { Task { await model.findCities() } }
                Button("Find city") { Task { await model.findCities() } }.disabled(model.weatherLoading || model.cityQuery.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                if model.weatherLoading { ProgressView().controlSize(.small) }
            }
            Text("Your city search is sent to Open-Meteo only when you choose Find city. Select a result to request its forecast.").font(.caption).foregroundStyle(.secondary)
            if model.weather == nil {
                ForEach(model.cities) { city in Button { Task { await model.loadWeather(city) } } label: { HStack { Image(systemName: "mappin.circle"); Text(city.label); Spacer(); Image(systemName: "chevron.right") }.rowStyle().contentShape(Rectangle()) }.buttonStyle(.plain).disabled(model.weatherLoading) }
            }
            if let weather = model.weather, let city = model.selectedCity {
                let label = IntegrationsModel.weatherLabel(weather.current.weather_code)
                HStack(spacing: 25) {
                    Image(systemName: label.1).font(.system(size: 55)).symbolRenderingMode(.multicolor)
                    VStack(alignment: .leading, spacing: 5) { Text(city.label).font(.headline); Text("\(weather.current.temperature_2m, specifier: "%.0f")°C").font(.system(size: 48, weight: .light, design: .rounded)); Text(label.0).foregroundStyle(.secondary) }
                    Spacer()
                }.cardStyle(padding: 20)
                HStack(spacing: 25) { Label("\(weather.current.relative_humidity_2m, specifier: "%.0f")% humidity", systemImage: "humidity"); Label("\(weather.current.wind_speed_10m, specifier: "%.0f") km/h wind", systemImage: "wind") }.font(.callout)
                ForEach(Array(weather.daily.time.enumerated()), id: \.offset) { index, day in
                    if index < weather.daily.temperature_2m_min.count && index < weather.daily.temperature_2m_max.count {
                        HStack { Text(day); Spacer(); Text("\(weather.daily.temperature_2m_min[index], specifier: "%.0f")°  /  \(weather.daily.temperature_2m_max[index], specifier: "%.0f")°C").foregroundStyle(.secondary) }.rowStyle(padding: 8)
                    }
                }
                Text("Model conditions at \(weather.current.time) · \(weather.timezone)").font(.caption).foregroundStyle(.secondary)
                Button("Refresh forecast") { Task { await model.loadWeather(city) } }.disabled(model.weatherLoading)
            }
            if let message = model.weatherMessage { Text(message).foregroundStyle(.orange).font(.caption) }
            Spacer(minLength: 0)
            Link("Weather data by Open-Meteo · CC BY 4.0", destination: URL(string: "https://open-meteo.com/")!).font(.caption)
        }
    }
    private var agentView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local agent activity").font(.headline)
            Text("Connect a coding tool by writing a JSON snapshot to this file. This view checks it every two seconds while open.").font(.caption).foregroundStyle(.secondary)
            HStack { Text(model.agentURL.path).font(.system(size: 10, design: .monospaced)).textSelection(.enabled); Spacer(); Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.agentURL.path, forType: .string) } }
            ScrollView {
                VStack(spacing: 9) {
                    if model.agents.isEmpty { ContentUnavailableView("No connected agents", systemImage: "terminal", description: Text("Activity appears after your coding tool writes a valid event file.")) }
                    ForEach(model.agents) { agent in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Circle().fill(agent.status == "failed" ? Color.red : agent.status == "completed" ? .green : .accentColor).frame(width: 7, height: 7); Text(agent.name).font(.headline); Spacer(); Text(agent.status.capitalized).font(.caption).foregroundStyle(.secondary) }
                            if let message = agent.message { Text(message).font(.caption).textSelection(.enabled) }
                            if let progress = agent.progress { ProgressView(value: progress) }
                            Text("Reported \(agent.updatedAt)").font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle(padding: 12)
                    }
                }
            }
            if let message = model.agentMessage { Text(message).font(.caption).foregroundStyle(.orange) }
            DisclosureGroup("Integration schema") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Write the full snapshot atomically. Required: version = 1; agents array; unique id, name, status, updatedAt (ISO-8601). Optional: message, progress (0–1). Status: working, waiting, completed, failed, idle. Maximum 100 agents and 1 MB.").font(.caption)
                    Text("{\"version\":1,\"agents\":[]}").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Text("This is a local event interface. It does not connect automatically to Codex, Claude or other tools.").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
        }.task {
            while !Task.isCancelled { model.readAgents(); do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break } }
        }
    }
}
