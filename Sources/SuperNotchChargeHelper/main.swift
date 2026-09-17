import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import ChargeLimitCore

// SuperNotch charge helper. Installed as a root launch daemon because only
// root may write the SMC keys that pause charging and set the MagSafe light.
//
//   daemon               Enforce the charge limit (launchd runs this).
//   probe                Print which charge controls this Mac supports. No root needed.
//   restore              Re-enable charging and return the light to macOS.
//   write-launchd-plist  Install the launch daemon property list.
//   version              Print the helper version.

func log(_ message: String) {
    FileHandle.standardError.write(Data("[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n".utf8))
}

func makeController() -> ChargingController? {
    guard let smc = try? SMCConnection() else { return nil }
    return try? ChargingController(smc: smc)
}

func restoreDefaults() {
    guard let controller = makeController() else { return }
    do {
        try controller.setAdapterDisabled(false)
        try controller.setChargingInhibited(false)
        try controller.setLED(.system)
    } catch {
        log("Could not restore charging: \(error)")
    }
}

struct BatteryReading {
    var present = false
    var percent: Int?
    var adapterConnected = false
}

func readBattery() -> BatteryReading {
    var reading = BatteryReading()
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return reading }
    if let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
        reading.adapterConnected = type == kIOPSACPowerValue
    }
    guard let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return reading }
    for source in sources {
        guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
              let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.intValue,
              let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.intValue, maximum > 0 else { continue }
        reading.present = true
        reading.percent = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
    }
    return reading
}

/// Reads the user-owned settings file defensively: no symlinks, regular files only, small size.
func readConfiguration() -> ChargeLimitConfiguration {
    var directoryInfo = stat()
    guard lstat(ChargeLimitPaths.settingsDirectory, &directoryInfo) == 0,
          (directoryInfo.st_mode & S_IFMT) == S_IFDIR else { return .disabled }
    let descriptor = open(ChargeLimitPaths.configurationFile, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { return .disabled }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var fileInfo = stat()
    guard fstat(descriptor, &fileInfo) == 0,
          (fileInfo.st_mode & S_IFMT) == S_IFREG,
          fileInfo.st_size <= 16_384,
          let data = try? handle.read(upToCount: 16_384),
          let configuration = try? JSONDecoder().decode(ChargeLimitConfiguration.self, from: data) else { return .disabled }
    return configuration
}

/// Finished one-shot requests, kept in the root-owned state directory so a
/// discharge or top-up never repeats after a restart.
struct RequestState: Codable {
    var dischargeFinishedFor: Date?
    var topUpFinishedFor: Date?

    static func load() -> RequestState {
        guard let data = FileManager.default.contents(atPath: ChargeLimitPaths.requestStateFile),
              let state = try? JSONDecoder().decode(RequestState.self, from: data) else { return RequestState() }
        return state
    }

    func save() {
        guard isRootOwnedDirectory(ChargeLimitPaths.stateDirectory), let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: URL(fileURLWithPath: ChargeLimitPaths.requestStateFile), options: .atomic)
    }
}

func isRootOwnedDirectory(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == 0
}

// iokit_common_msg() values; the C macros are not imported into Swift.
let powerMessageCanSystemSleep: UInt32 = 0xE000_0270
let powerMessageSystemWillSleep: UInt32 = 0xE000_0280
let powerMessageSystemHasPoweredOn: UInt32 = 0xE000_0300

final class ChargeLimitDaemon {
    static let shared = ChargeLimitDaemon()

    private var controller: ChargingController?
    private var pausedForSleep = false
    private var configuration = ChargeLimitConfiguration.disabled
    private var lastError: String?
    private var lastLED: MagSafeLED?
    private var requests = RequestState.load()
    private var lastAction = ChargeLimitAction.normal
    /// When the adapter was switched off, to confirm macOS actually moved to battery power.
    private var adapterDisabledAt: Date?
    private var sleepAssertion: IOPMAssertionID = 0
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var sources: [DispatchSourceProtocol] = []
    private var settingsWatch: DispatchSourceFileSystemObject?

    func run() -> Never {
        controller = makeController()
        guard controller != nil else {
            writeStatus(inhibited: false, battery: readBattery(), error: "This Mac does not expose charge control to software.")
            log("No supported charge control keys; exiting.")
            exit(0)
        }

        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in self?.shutdown() }
            source.resume()
            sources.append(source)
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.evaluate() }
        timer.resume()
        sources.append(timer)

        installPowerSourceNotification()
        installSleepNotification()
        watchSettings()
        evaluate()
        CFRunLoopRun()
        exit(0)
    }

    func evaluate() {
        guard let controller else { return }
        configuration = readConfiguration()
        if settingsWatch == nil { watchSettings() }
        let battery = readBattery()
        // While we hold the adapter off, trust that the charger is still attached;
        // otherwise a reading that drops with the adapter could flip it back on each cycle.
        let pluggedIn = adapterDisabledAt != nil || (controller.isPluggedIn() ?? battery.adapterConnected)
        lastError = nil

        let currentlyInhibited = (try? controller.isChargingInhibited()) ?? false
        let currentlyAdapterDisabled = (try? controller.isAdapterDisabled()) ?? false

        var action: ChargeLimitAction
        if !battery.present {
            action = .normal
            pausedForSleep = false
        } else if pausedForSleep {
            // Sleep is imminent or in progress: never leave the adapter off.
            action = .normal
            action.inhibitCharging = configuration.enabled
        } else {
            action = ChargeLimitPolicy.decide(
                configuration: configuration,
                batteryPercent: battery.percent,
                pluggedIn: pluggedIn,
                currentlyInhibited: currentlyInhibited,
                dischargeActive: ChargeLimitPolicy.isRequestActive(configuration.dischargeRequestedAt, finishedFor: requests.dischargeFinishedFor),
                topUpActive: ChargeLimitPolicy.isRequestActive(configuration.topUpRequestedAt, finishedFor: requests.topUpFinishedFor),
                supportsAdapterControl: controller.supportsAdapterControl
            )
        }
        if !configuration.enabled { pausedForSleep = false }

        if action.dischargeFinished || action.topUpFinished {
            if action.dischargeFinished { requests.dischargeFinishedFor = configuration.dischargeRequestedAt }
            if action.topUpFinished { requests.topUpFinishedFor = configuration.topUpRequestedAt }
            requests.save()
        }

        applyAdapter(disabled: action.disableAdapter, current: currentlyAdapterDisabled, battery: battery, controller: controller)

        var inhibited = action.inhibitCharging
        do {
            if inhibited != currentlyInhibited { try controller.setChargingInhibited(inhibited) }
        } catch {
            lastError = "Could not change charging: \(error)"
            inhibited = currentlyInhibited
        }

        let holdingOnAdapter = inhibited && !action.discharging && !pausedForSleep
        let led = ChargeLimitPolicy.led(configuration: configuration, inhibited: holdingOnAdapter, adapterConnected: pluggedIn)
        // While macOS owns the light, ACLC reads back its own colour, so only
        // compare against the SMC when we are holding the light green.
        let needsLEDWrite = led != lastLED || (led == .green && (try? controller.led()) != .green)
        if controller.supportsLED, needsLEDWrite {
            do {
                try controller.setLED(led)
                lastLED = led
            } catch {
                lastError = "Could not set the MagSafe light: \(error)"
            }
        }

        // Keep an idle Mac awake while it works toward a target on the charger; the display still sleeps.
        let chargingTowardTarget = configuration.enabled && !configuration.chargesDuringSleep && pluggedIn && !inhibited
            && (action.toppingUp || (battery.percent ?? 100) < configuration.limit)
        setPreventsIdleSleep(!pausedForSleep && (chargingTowardTarget || (action.discharging && pluggedIn)))

        lastAction = action
        writeStatus(inhibited: inhibited, battery: battery, error: lastError)
    }

    /// Switches the adapter and confirms macOS actually moved to battery power.
    /// If it did not, the next supported key is tried; with none left, discharge stops.
    private func applyAdapter(disabled: Bool, current: Bool, battery: BatteryReading, controller: ChargingController) {
        do {
            if !disabled {
                adapterDisabledAt = nil
                if current { try controller.setAdapterDisabled(false) }
                return
            }
            if !current || adapterDisabledAt == nil {
                try controller.setAdapterDisabled(true)
                adapterDisabledAt = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.evaluate() }
                return
            }
            if battery.adapterConnected, let since = adapterDisabledAt, Date().timeIntervalSince(since) > 10 {
                try controller.setAdapterDisabled(false)
                if controller.fallBackToNextAdapterKey() {
                    log("Adapter key had no effect; trying \(controller.adapterKeys.first?.rawValue ?? "none").")
                    try controller.setAdapterDisabled(true)
                    adapterDisabledAt = Date()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.evaluate() }
                } else {
                    adapterDisabledAt = nil
                    requests.dischargeFinishedFor = configuration.dischargeRequestedAt
                    requests.save()
                    lastError = "This Mac did not switch to battery power, so discharging was stopped."
                }
            }
        } catch {
            try? controller.setAdapterDisabled(false)
            adapterDisabledAt = nil
            lastError = "Could not switch the power adapter: \(error)"
        }
    }

    private func shutdown() {
        setPreventsIdleSleep(false)
        restoreDefaults()
        writeStatus(inhibited: false, battery: readBattery(), error: nil, enabledOverride: false)
        exit(0)
    }

    // MARK: Sleep

    fileprivate func systemWillSleep() {
        guard let controller else { return }
        // Never sleep with the adapter off: the battery would drain unattended.
        if (try? controller.isAdapterDisabled()) == true {
            try? controller.setAdapterDisabled(false)
            adapterDisabledAt = nil
            pausedForSleep = true
        }
        guard readBattery().present else { return }
        let configuration = readConfiguration()
        let inhibited = (try? controller.isChargingInhibited()) ?? false
        guard ChargeLimitPolicy.shouldPauseForSleep(configuration: configuration, currentlyInhibited: inhibited) else { return }
        do {
            try controller.setChargingInhibited(true)
            try? controller.setLED(.system)
            lastLED = .system
            pausedForSleep = true
            writeStatus(inhibited: true, battery: readBattery(), error: nil)
        } catch {
            log("Could not pause charging for sleep: \(error)")
        }
    }

    fileprivate func systemDidWake() {
        pausedForSleep = false
        evaluate()
    }

    fileprivate func allowPowerChange(_ argument: UnsafeMutableRawPointer?) {
        IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    }

    private func installSleepNotification() {
        rootPort = IORegisterForSystemPower(nil, &notifyPort, { _, _, messageType, argument in
            let daemon = ChargeLimitDaemon.shared
            switch messageType {
            case powerMessageCanSystemSleep:
                daemon.allowPowerChange(argument)
            case powerMessageSystemWillSleep:
                daemon.systemWillSleep()
                daemon.allowPowerChange(argument)
            case powerMessageSystemHasPoweredOn:
                daemon.systemDidWake()
            default:
                break
            }
        }, &notifier)
        if rootPort != 0, let notifyPort {
            CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .defaultMode)
        }
    }

    private func setPreventsIdleSleep(_ prevent: Bool) {
        if prevent, sleepAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "SuperNotch is charging to your charge limit" as CFString,
                &sleepAssertion
            )
        } else if !prevent, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }

    // MARK: Change sources

    private func installPowerSourceNotification() {
        guard let source = IOPSNotificationCreateRunLoopSource({ _ in
            ChargeLimitDaemon.shared.evaluate()
        }, nil)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    /// Settings are replaced atomically, which changes the directory entry.
    private func watchSettings() {
        settingsWatch?.cancel()
        settingsWatch = nil
        let descriptor = open(ChargeLimitPaths.settingsDirectory, O_EVTONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            // Coalesce bursts from slider drags.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.evaluate() }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                self?.settingsWatch?.cancel()
                self?.settingsWatch = nil
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        settingsWatch = source
    }

    // MARK: Status

    private func writeStatus(inhibited: Bool, battery: BatteryReading, error: String?, enabledOverride: Bool? = nil) {
        // Only write into the root-owned state directory, never through a symlink.
        guard isRootOwnedDirectory(ChargeLimitPaths.stateDirectory) else { return }
        let status = ChargeLimitStatus(
            scheme: controller?.scheme,
            supportsLED: controller?.supportsLED ?? false,
            supportsDischarge: controller?.supportsAdapterControl ?? false,
            enabled: enabledOverride ?? configuration.enabled,
            limit: configuration.limit,
            chargingInhibited: inhibited,
            adapterDisabled: (try? controller?.isAdapterDisabled()) ?? false,
            discharging: enabledOverride == false ? false : lastAction.discharging,
            toppingUp: enabledOverride == false ? false : lastAction.toppingUp,
            pausedForSleep: pausedForSleep,
            batteryPercent: battery.percent,
            adapterConnected: controller?.isPluggedIn() ?? battery.adapterConnected,
            lastError: error
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(status) else { return }
        let url = URL(fileURLWithPath: ChargeLimitPaths.statusFile)
        do {
            try data.write(to: url, options: .atomic)
            chmod(ChargeLimitPaths.statusFile, 0o644)
        } catch {
            log("Could not write status: \(error)")
        }
    }
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "daemon":
    guard getuid() == 0 else { log("The daemon must run as root."); exit(1) }
    ChargeLimitDaemon.shared.run()
case "probe":
    guard let controller = makeController() else { print("{}"); exit(2) }
    print("{\"scheme\":\"\(controller.scheme.rawValue)\",\"supportsLED\":\(controller.supportsLED)}")
case "restore":
    guard getuid() == 0 else { log("restore must run as root."); exit(1) }
    restoreDefaults()
case "write-launchd-plist":
    guard getuid() == 0 else { log("write-launchd-plist must run as root."); exit(1) }
    do {
        try ChargeLimitPaths.launchDaemonPlistData().write(to: URL(fileURLWithPath: ChargeLimitPaths.launchDaemonPlist), options: .atomic)
        chown(ChargeLimitPaths.launchDaemonPlist, 0, 0)
        chmod(ChargeLimitPaths.launchDaemonPlist, 0o644)
    } catch {
        log("Could not write launch daemon: \(error)")
        exit(1)
    }
case "version":
    print(ChargeLimitPaths.helperVersion)
default:
    log("usage: SuperNotchChargeHelper daemon | probe | restore | write-launchd-plist | version")
    exit(64)
}
