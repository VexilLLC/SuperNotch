import SwiftUI
import CoreAudio
import AudioToolbox

struct AudioOutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let transport: String
}

@MainActor final class AudioDevicesStore: ObservableObject {
    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published private(set) var selected: AudioDeviceID = 0
    @Published private(set) var volume: Float = 0
    @Published private(set) var muted = false
    @Published private(set) var volumeAvailable = false
    @Published private(set) var muteAvailable = false
    @Published var message = ""
    private var timer: Timer?
    private var volumeChannels: [AudioObjectPropertyElement] = []
    private var muteChannels: [AudioObjectPropertyElement] = []
    func start() {
        refresh(); guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    func stop() { timer?.invalidate(); timer = nil }
    func refresh() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { message = "Could not read audio devices."; return }
        guard size > 0 else { devices = []; selected = 0; volumeAvailable = false; muteAvailable = false; return }
        var identifiers = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let result = identifiers.withUnsafeMutableBytes { bytes in AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, bytes.baseAddress!) }
        guard result == noErr else { message = "Could not enumerate audio devices (\(result))."; return }
        devices = identifiers.compactMap { identifier in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(identifier, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: CFString = "Audio device" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            let _ = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(identifier, &nameAddress, 0, nil, &nameSize, $0) }
            var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0; var transportSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(identifier, &transportAddress, 0, nil, &transportSize, &transport)
            let kind: String
            switch transport {
            case kAudioDeviceTransportTypeBuiltIn: kind = "Built-in"
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: kind = "Bluetooth"
            case kAudioDeviceTransportTypeUSB: kind = "USB"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: kind = "Display"
            case kAudioDeviceTransportTypeAirPlay: kind = "AirPlay"
            case kAudioDeviceTransportTypeVirtual: kind = "Virtual"
            case kAudioDeviceTransportTypeAggregate: kind = "Aggregate"
            default: kind = "Audio output"
            }
            return AudioOutputDevice(id: identifier, name: name as String, transport: kind)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var defaultAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var identifier: AudioDeviceID = 0; var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, 0, nil, &defaultSize, &identifier) == noErr { selected = identifier }
        updateControls()
    }
    private func supportedChannels(_ selector: AudioObjectPropertySelector) -> [AudioObjectPropertyElement] {
        // Master channel is preferred; otherwise use the device's first stereo pair.
        var supported: [AudioObjectPropertyElement] = []
        for channel: AudioObjectPropertyElement in [0, 1, 2] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: channel)
            var settable: DarwinBoolean = false
            if AudioObjectHasProperty(selected, &address), AudioObjectIsPropertySettable(selected, &address, &settable) == noErr, settable.boolValue {
                if channel == 0 { return [0] }; supported.append(channel)
            }
        }
        return supported
    }
    private func updateControls() {
        guard selected != 0 else { volumeAvailable = false; muteAvailable = false; return }
        volumeChannels = supportedChannels(kAudioDevicePropertyVolumeScalar)
        muteChannels = supportedChannels(kAudioDevicePropertyMute)
        var values: [Float] = []
        for channel in volumeChannels {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: channel)
            var value: Float32 = 0; var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(selected, &address, 0, nil, &size, &value) == noErr { values.append(value) }
        }
        volumeAvailable = !values.isEmpty
        if !values.isEmpty { volume = values.reduce(0, +) / Float(values.count) }
        var muteValues: [Bool] = []
        for channel in muteChannels {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: channel)
            var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(selected, &address, 0, nil, &size, &value) == noErr { muteValues.append(value != 0) }
        }
        muteAvailable = !muteValues.isEmpty; muted = !muteValues.isEmpty && muteValues.allSatisfy { $0 }
    }
    func select(_ identifier: AudioDeviceID) {
        guard devices.contains(where: { $0.id == identifier }) else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = identifier
        let result = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        message = result == noErr ? "" : "Could not switch audio output (\(result)). The device may have disconnected."
        refresh()
    }
    func setVolume(_ value: Float) {
        guard volumeAvailable else { return }
        var value = max(0, min(1, value)); var failed = false
        for channel in volumeChannels {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: channel)
            if AudioObjectSetPropertyData(selected, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) != noErr { failed = true }
        }
        volume = value
        if failed { message = "The output device rejected a volume change."; updateControls() }
    }
    func toggleMute() {
        guard muteAvailable else { return }
        var value: UInt32 = muted ? 0 : 1; var failed = false
        for channel in muteChannels {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: channel)
            if AudioObjectSetPropertyData(selected, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) != noErr { failed = true }
        }
        if failed { message = "The output device rejected a mute change." }; updateControls()
    }
}

struct AudioDevicesView: View {
    @StateObject private var store = AudioDevicesStore()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label("Audio Output", systemImage: "hifispeaker.fill").font(.headline); Spacer(); Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh audio devices") }
            Text("Choose where your Mac plays audio.").font(.caption).foregroundStyle(.secondary)
            if store.devices.isEmpty { Text("No audio outputs are currently available.").foregroundStyle(.secondary).padding(.vertical) }
            else {
                VStack(spacing: 6) {
                    ForEach(store.devices) { device in
                        Button { store.select(device.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: device.transport == "Bluetooth" ? "headphones" : "speaker.wave.2").font(.system(size: 19)).foregroundStyle(store.selected == device.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)).frame(width: 26)
                                VStack(alignment: .leading, spacing: 3) { Text(device.name).font(.subheadline.weight(.medium)); Text(device.transport).font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                if store.selected == device.id { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint) }
                            }.rowStyle(selected: store.selected == device.id).contentShape(RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
                Divider()
                HStack {
                    Button { store.toggleMute() } label: { Image(systemName: store.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 24) }.disabled(!store.muteAvailable).help(store.muteAvailable ? "Toggle output mute" : "This output has no software mute control")
                    Slider(value: Binding(get: { store.volume }, set: { store.setVolume($0) }), in: 0...1).disabled(!store.volumeAvailable).accessibilityLabel("System output volume")
                    Text(store.volumeAvailable ? "\(Int(store.volume * 100))%" : "—").font(.caption.monospacedDigit()).frame(width: 36)
                }
                if !store.volumeAvailable { Text("This output uses hardware or app-specific volume controls.").font(.caption).foregroundStyle(.secondary) }
            }
            if !store.message.isEmpty { Text(store.message).font(.caption).foregroundStyle(.orange) }
        }.padding(20).onAppear { store.start() }.onDisappear { store.stop() }
    }
}
